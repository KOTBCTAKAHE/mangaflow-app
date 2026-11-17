import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../../core/network/api_exception.dart';
import '../../models/manga.dart';

/// Network state as seen by the engine.
enum NetState { none, metered, unmetered }

/// What the engine needs to know about the network (injectable for tests).
abstract interface class NetworkProbe {
  Future<NetState> check();
}

class EngineSettings {
  const EngineSettings({this.wifiOnly = false, this.imageWidth});
  final bool wifiOnly;
  final int? imageWidth;
}

/// Why [DownloadEngine.run] returned.
enum RunResult { idle, budgetExhausted, stopped, leaseBusy }

/// Error classification drives the retry policy.
class _Transient implements Exception {
  _Transient(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Permanent implements Exception {
  _Permanent(this.message);
  final String message;
  @override
  String toString() => message;
}

class _TokenExpired implements Exception {}

class _Aborted implements Exception {}

/// Resilient chapter downloader designed to be left running overnight.
///
/// * Persistent queue in SQLite; safe to run from the UI isolate, the Android
///   foreground-service isolate or a WorkManager isolate — a lease row
///   guarantees only one runner works at a time.
/// * Transient problems (no network, timeouts, 5xx, 429, source temporarily
///   down) never fail a chapter quickly: it is rescheduled with exponential
///   backoff (1 → 30 min) and the queue moves on to other chapters.
/// * While offline the engine *waits* for the network instead of burning retries.
/// * Pages resume from where they stopped (HTTP Range) and are validated
///   (magic bytes) before being committed atomically.
/// * Expired signed page URLs are refreshed transparently.
class DownloadEngine {
  DownloadEngine({
    required this.db,
    required this.pagesFor,
    required this.http,
    required this.settings,
    required this.net,
    required this.owner,
    this.onProgress,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
  })  : _now = now ?? DateTime.now,
        _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  final Database db;

  /// Fetches the (signed) page list of a chapter from the backend.
  final Future<List<PageRef>> Function(String sourceId, String chapterId, int? width) pagesFor;
  final Dio http;
  final EngineSettings Function() settings;
  final NetworkProbe net;

  /// Unique id of this runner (for the lease).
  final String owner;

  /// Called after every observable change (status, page done, waiting for network).
  final void Function(EngineEvent event)? onProgress;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;

  static const leaseKey = 'download_lease';
  static const stateKey = 'download_state';
  static const leaseTtl = Duration(seconds: 90);
  static const pageParallelism = 3;
  static const pageAttempts = 6;
  static const maxTransientAttempts = 24; // ≈ 10 h of retries with the 30-min cap
  static const maxPermanentAttempts = 3;
  static const idleChunkTimeout = Duration(seconds: 45);

  CancelToken? _cancel;
  bool _stop = false;

  int get _nowMs => _now().toUtc().millisecondsSinceEpoch;

  /// Backoff for the n-th failed attempt of a chapter (1-based): 1, 2, 4, 8, 16, 30, 30… minutes.
  static Duration chapterBackoff(int attempt) => Duration(minutes: min(30, pow(2, max(0, attempt - 1)).toInt()));

  /// Backoff between quick page retries: 2, 4, 8, 16, 30, 30 s (+ jitter).
  Duration _pageBackoff(int attempt) =>
      Duration(milliseconds: min(30000, 2000 * pow(2, attempt).toInt()) + Random().nextInt(700));

  void stop() {
    _stop = true;
    _cancel?.cancel();
  }

  // ------------------------------------------------------------------ lease
  Future<bool> _acquireLease() => db.transaction((txn) async {
        final rows = await txn.query('kv', where: 'key = ?', whereArgs: [leaseKey]);
        if (rows.isNotEmpty) {
          final v = (rows.first['value'] as String?) ?? '';
          final parts = v.split('|');
          final holder = parts.first;
          final until = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
          if (holder != owner && until > _nowMs) return false;
        }
        await txn.insert('kv', {'key': leaseKey, 'value': '$owner|${_nowMs + leaseTtl.inMilliseconds}'},
            conflictAlgorithm: ConflictAlgorithm.replace);
        return true;
      });

  Future<void> _renewLease() => db.insert('kv', {'key': leaseKey, 'value': '$owner|${_nowMs + leaseTtl.inMilliseconds}'},
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> _releaseLease() => db.delete('kv', where: 'key = ? AND value LIKE ?', whereArgs: [leaseKey, '$owner|%']);

  Future<void> _setState(String state) async {
    await db.insert('kv', {'key': stateKey, 'value': state}, conflictAlgorithm: ConflictAlgorithm.replace);
    onProgress?.call(EngineEvent(state: state));
  }

  // ------------------------------------------------------------------ main loop
  /// Processes the queue until it is empty, [budget] runs out or [stop] is called.
  Future<RunResult> run({Duration? budget}) async {
    _stop = false;
    if (!await _acquireLease()) return RunResult.leaseBusy;
    final deadline = budget == null ? null : _now().add(budget);
    try {
      // a previous runner died mid-chapter → back to the queue
      await db.update('downloads', {'status': 'queued'}, where: "status = 'downloading'");
      while (true) {
        if (_stop) return RunResult.stopped;
        if (deadline != null && _now().isAfter(deadline)) return RunResult.budgetExhausted;
        await _renewLease();

        final net = await this.net.check();
        final s = settings();
        if (net == NetState.none || (s.wifiOnly && net != NetState.unmetered)) {
          if (await _pendingCount() == 0) return RunResult.idle;
          await _setState(net == NetState.none ? 'waiting_network' : 'waiting_wifi');
          await _sleep(const Duration(seconds: 15));
          continue;
        }

        final due = await db.query('downloads',
            where: "status IN ('queued','retrying') AND next_attempt_at <= ?",
            whereArgs: [_nowMs],
            orderBy: 'next_attempt_at ASC, created_at ASC',
            limit: 1);
        if (due.isEmpty) {
          final next = await db.rawQuery(
              "SELECT MIN(next_attempt_at) AS t FROM downloads WHERE status IN ('queued','retrying')");
          final t = next.first['t'] as int?;
          if (t == null) {
            await _setState('idle');
            return RunResult.idle;
          }
          await _setState('waiting_retry');
          final wait = Duration(milliseconds: (t - _nowMs).clamp(1000, 60000));
          await _sleep(wait);
          continue;
        }
        await _setState('running');
        await _processChapter(due.first);
      }
    } finally {
      await _releaseLease();
    }
  }

  Future<int> _pendingCount() async =>
      Sqflite.firstIntValue(
          await db.rawQuery("SELECT COUNT(*) FROM downloads WHERE status IN ('queued','retrying','downloading')")) ??
      0;

  // ------------------------------------------------------------------ chapter
  Future<String?> _status(String sourceId, String chapterId) async {
    final r = await db.query('downloads',
        columns: ['status'], where: 'source_id = ? AND chapter_id = ?', whereArgs: [sourceId, chapterId]);
    return r.isEmpty ? null : r.first['status'] as String?;
  }

  Future<void> _update(String sourceId, String chapterId, Map<String, Object?> values) => db.update(
      'downloads', {...values, 'updated_at': _nowMs},
      where: 'source_id = ? AND chapter_id = ?', whereArgs: [sourceId, chapterId]);

  Future<void> _processChapter(Map<String, Object?> row) async {
    final sourceId = row['source_id']! as String;
    final chapterId = row['chapter_id']! as String;
    final dir = Directory(row['dir']! as String);
    final attempts = (row['attempts'] as int?) ?? 0;
    _cancel = CancelToken();
    await _update(sourceId, chapterId, {'status': 'downloading', 'error': null});
    _emit(row, null);

    try {
      var pages = await _pageList(sourceId, chapterId);
      await dir.create(recursive: true);
      await _update(sourceId, chapterId, {'page_count': pages.length});

      var tokenRefreshed = false;
      while (true) {
        try {
          await _downloadPages(row, pages, dir);
          break;
        } on _TokenExpired {
          if (tokenRefreshed) throw _Transient('Ссылки на страницы устарели');
          tokenRefreshed = true;
          pages = await _pageList(sourceId, chapterId);
        }
      }

      final files = _committedFiles(dir);
      if (files.length < pages.length) throw _Transient('Скачано ${files.length} из ${pages.length} страниц');
      final size = files.fold<int>(0, (a, f) => a + f.lengthSync());
      await _update(sourceId, chapterId, {
        'status': 'completed',
        'pages_done': pages.length,
        'size_bytes': size,
        'error': null,
        'attempts': 0,
        'next_attempt_at': 0,
      });
      _emit(row, 'completed');
    } on _Aborted {
      // paused or deleted by the user; nothing to do
      _emit(row, null);
    } on _Permanent catch (e) {
      final n = attempts + 1;
      await _update(sourceId, chapterId, {
        'status': n >= maxPermanentAttempts ? 'failed' : 'retrying',
        'attempts': n,
        'next_attempt_at': _nowMs + const Duration(minutes: 10).inMilliseconds,
        'error': e.message,
      });
      _emit(row, null);
    } on _Transient catch (e) {
      await _scheduleRetry(sourceId, chapterId, attempts, e.message);
      _emit(row, null);
    } catch (e) {
      await _scheduleRetry(sourceId, chapterId, attempts, e.toString());
      _emit(row, null);
    }
  }

  Future<void> _scheduleRetry(String sourceId, String chapterId, int attempts, String message) async {
    if (await _status(sourceId, chapterId) != 'downloading') return; // paused/deleted meanwhile
    final n = attempts + 1;
    await _update(sourceId, chapterId, {
      'status': n >= maxTransientAttempts ? 'failed' : 'retrying',
      'attempts': n,
      'next_attempt_at': _nowMs + chapterBackoff(n).inMilliseconds,
      'error': message,
    });
  }

  void _emit(Map<String, Object?> row, String? status) => onProgress?.call(EngineEvent(
        state: 'running',
        mangaTitle: row['manga_title'] as String?,
        chapterTitle: row['chapter_title'] as String?,
        chapterStatus: status,
      ));

  Future<List<PageRef>> _pageList(String sourceId, String chapterId) async {
    try {
      final pages = await pagesFor(sourceId, chapterId, settings().imageWidth);
      if (pages.isEmpty) throw _Permanent('В главе нет страниц');
      return pages;
    } on ApiException catch (e) {
      throw _classify(e);
    } on DioException catch (e) {
      throw _classify(ApiException.fromDio(e));
    }
  }

  static Exception _classify(ApiException e) {
    const transient = {'offline', 'timeout', 'source_unavailable', 'source_rate_limited', 'rate_limited', 'cancelled'};
    if (transient.contains(e.code) || (e.status ?? 0) >= 500 || e.status == 429) return _Transient(e.userMessage);
    return _Permanent(e.userMessage);
  }

  List<File> _committedFiles(Directory dir) => dir.existsSync()
      ? (dir.listSync().whereType<File>().where((f) => !f.path.endsWith('.part')).toList()
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path))))
      : <File>[];

  // ------------------------------------------------------------------ pages
  Future<void> _downloadPages(Map<String, Object?> row, List<PageRef> pages, Directory dir) async {
    final sourceId = row['source_id']! as String;
    final chapterId = row['chapter_id']! as String;
    final queue = [...pages];
    _cancel = CancelToken(); // fresh token per attempt (a previous round may have cancelled it)
    var done = _committedFiles(dir).length;
    Object? failure;

    Future<void> worker() async {
      while (queue.isNotEmpty && failure == null) {
        if (_stop) throw _Aborted();
        final st = await _status(sourceId, chapterId);
        if (st != 'downloading') throw _Aborted();
        final page = queue.removeAt(0);
        try {
          final wrote = await _fetchPageWithRetry(page, dir.path);
          if (wrote) {
            done++;
            await _update(sourceId, chapterId, {'pages_done': done});
            await _renewLease();
            _emit(row, null);
          }
        } catch (e) {
          failure ??= e;
          _cancel?.cancel();
        }
      }
    }

    try {
      await Future.wait([for (var i = 0; i < pageParallelism; i++) worker()]);
    } catch (e) {
      failure ??= e;
    }
    final f = failure;
    if (f != null) throw f;
  }

  /// Returns true when a new page was written (false if it already existed).
  Future<bool> _fetchPageWithRetry(PageRef page, String dir) async {
    final base = page.index.toString().padLeft(4, '0');
    if (_committedFiles(Directory(dir)).any((f) => p.basenameWithoutExtension(f.path) == base)) return false;

    var attempt = 0;
    while (true) {
      if (_stop) throw _Aborted();
      try {
        await _fetchPage(page.url, dir, base);
        return true;
      } on _TokenExpired {
        rethrow;
      } on _Permanent {
        rethrow;
      } on _Aborted {
        rethrow;
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) throw _Aborted();
        // transient: wait for the network without counting the attempt
        if (await net.check() == NetState.none) {
          await _setState('waiting_network');
          while (await net.check() == NetState.none) {
            if (_stop) throw _Aborted();
            await _renewLease();
            await _sleep(const Duration(seconds: 10));
          }
          await _setState('running');
          continue;
        }
        attempt++;
        if (attempt >= pageAttempts) throw _Transient('Страница ${page.index + 1}: ${_describe(e)}');
        await _sleep(_pageBackoff(attempt));
      }
    }
  }

  static String _describe(Object e) {
    if (e is DioException) return ApiException.fromDio(e).userMessage;
    if (e is TimeoutException) return 'нет данных от сервера';
    if (e is _Transient) return e.message;
    return e.toString();
  }

  /// Streams one page to `<base>.part` (resuming with Range when possible),
  /// validates it and renames it to `<base>.<ext>`.
  Future<void> _fetchPage(String url, String dir, String base) async {
    final part = File(p.join(dir, '$base.part'));
    var have = part.existsSync() ? part.lengthSync() : 0;
    _cancel ??= CancelToken();

    final res = await http.get<ResponseBody>(
      url,
      cancelToken: _cancel,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        validateStatus: (_) => true,
        headers: {if (have > 0) 'Range': 'bytes=$have-'},
      ),
    );
    final status = res.statusCode ?? 0;
    final body = res.data!;

    if (status == 416 && have > 0) {
      // we already have everything
      await body.stream.drain<void>();
    } else if (status == 200 || status == 206) {
      final append = status == 206 && have > 0;
      if (!append) have = 0;
      final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
      try {
        await for (final chunk in body.stream.timeout(idleChunkTimeout)) {
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      final expected = int.tryParse(res.headers.value('content-length') ?? '');
      if (expected != null && part.lengthSync() < have + expected) {
        throw _Transient('обрыв соединения');
      }
    } else {
      final text = await _readSmall(body);
      if ((status == 404 || status == 410) && text.contains('image_token_invalid')) throw _TokenExpired();
      if (status == 429 || status >= 500) throw _Transient('сервер ответил $status');
      throw _Permanent('страница недоступна ($status)');
    }

    final ext = _sniff(part);
    if (ext == null) {
      await part.delete();
      throw _Transient('повреждённое изображение');
    }
    await part.rename(p.join(dir, '$base.$ext'));
  }

  static Future<String> _readSmall(ResponseBody body) async {
    final bytes = <int>[];
    await for (final c in body.stream) {
      bytes.addAll(c);
      if (bytes.length > 4096) break;
    }
    return String.fromCharCodes(bytes);
  }

  /// Validates the file by its magic bytes and returns the extension.
  static String? _sniff(File f) {
    if (!f.existsSync() || f.lengthSync() < 64) return null;
    final raf = f.openSync();
    try {
      final h = raf.readSync(16);
      if (h.length >= 3 && h[0] == 0xFF && h[1] == 0xD8 && h[2] == 0xFF) return 'jpg';
      if (h.length >= 8 && h[0] == 0x89 && h[1] == 0x50 && h[2] == 0x4E && h[3] == 0x47) return 'png';
      if (h.length >= 12 && String.fromCharCodes(h.sublist(0, 4)) == 'RIFF' && String.fromCharCodes(h.sublist(8, 12)) == 'WEBP') {
        return 'webp';
      }
      if (h.length >= 6 && String.fromCharCodes(h.sublist(0, 3)) == 'GIF') return 'gif';
      if (h.length >= 12 && String.fromCharCodes(h.sublist(4, 8)) == 'ftyp') return 'avif';
      return null;
    } finally {
      raf.closeSync();
    }
  }
}

class EngineEvent {
  const EngineEvent({required this.state, this.mangaTitle, this.chapterTitle, this.chapterStatus});
  final String state;
  final String? mangaTitle;
  final String? chapterTitle;
  final String? chapterStatus;
}
