import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../models/manga.dart';
import '../models/settings.dart';

enum UpscaleStatus { idle, queued, running, done, skipped, failed }

@immutable
class UpscaleState {
  const UpscaleState(this.status, {this.file, this.message});
  final UpscaleStatus status;
  final File? file;
  final String? message;

  static const idle = UpscaleState(UpscaleStatus.idle);
  bool get isDone => status == UpscaleStatus.done && file != null;
}

@immutable
class UpscaleOutcome {
  const UpscaleOutcome(this.status, {this.ms = 0, this.message});
  final String status; // ok | skipped | cancelled | error
  final int ms;
  final String? message;

  factory UpscaleOutcome.fromMap(Map<Object?, Object?> m) => UpscaleOutcome(
        m['status'] as String? ?? 'error',
        ms: (m['ms'] as num?)?.toInt() ?? 0,
        message: (m['message'] ?? m['reason']) as String?,
      );
}

/// Native inference (Android: ONNX Runtime, see UpscalePlugin.kt).
abstract class UpscaleBackend {
  Future<UpscaleOutcome> run({
    required String id,
    required String input,
    required String output,
    required UpscaleQuality quality,
    required int maxSourceWidth,
    int maxOutPixels,
  });
  Future<void> cancel(String id);
  Future<void> release();
}

class ChannelUpscaleBackend implements UpscaleBackend {
  static const _ch = MethodChannel('mangaflow/upscale');

  @override
  Future<UpscaleOutcome> run({
    required String id,
    required String input,
    required String output,
    required UpscaleQuality quality,
    required int maxSourceWidth,
    int maxOutPixels = 24000000,
  }) async {
    if (!Platform.isAndroid) return const UpscaleOutcome('skipped', message: 'unsupported_platform');
    try {
      final r = await _ch.invokeMapMethod<Object?, Object?>('upscale', {
        'id': id,
        'input': input,
        'output': output,
        'model': quality.api,
        'maxSourceWidth': maxSourceWidth,
        'maxOutPixels': maxOutPixels,
      });
      return UpscaleOutcome.fromMap(r ?? const {});
    } on MissingPluginException {
      return const UpscaleOutcome('skipped', message: 'unsupported_platform');
    } on PlatformException catch (e) {
      return UpscaleOutcome('error', message: e.message);
    }
  }

  @override
  Future<void> cancel(String id) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('cancel', {'id': id});
    } catch (_) {}
  }

  @override
  Future<void> release() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('release');
    } catch (_) {}
  }
}

class _StateNotifier extends ValueNotifier<UpscaleState> {
  _StateNotifier() : super(UpscaleState.idle);
  bool get listened => hasListeners;
}

class _Job {
  _Job(this.page, this.key, {this.force = false});
  final PageRef page;
  final String key;

  /// Ignore the "already sharp enough" width limit (comparison screen).
  final bool force;
}

/// Queue + disk cache for AI-upscaled pages.
///
/// The reader calls [focus] on every page change: the current page is processed
/// first, then the next few; everything else is dropped from the queue. One page
/// is processed at a time (the model already uses several cores).
class PageUpscaler {
  PageUpscaler({
    required this.backend,
    required Future<Directory> Function() cacheDir,
    Future<File> Function(PageRef page)? sourceFile,
    this.maxCacheBytes = 800 * 1024 * 1024,
  })  : _cacheDir = cacheDir,
        _sourceFile = sourceFile ?? _defaultSource;

  final UpscaleBackend backend;
  final Future<Directory> Function() _cacheDir;
  final Future<File> Function(PageRef page) _sourceFile;
  final int maxCacheBytes;

  UpscaleQuality quality = UpscaleQuality.fast;
  UpscaleMode mode = UpscaleMode.off;

  /// Physical width of the screen; in [UpscaleMode.auto] pages at least this wide are left alone.
  int targetWidth = 1080;

  bool get enabled => mode != UpscaleMode.off;

  /// Nothing queued or running.
  bool get isIdle => !_pumping && _queue.isEmpty;
  int get maxSourceWidth => mode == UpscaleMode.always ? 1800 : (targetWidth * 0.95).round();

  final _states = <String, _StateNotifier>{};
  final _queue = <_Job>[];
  _Job? _running;
  bool _pumping = false;
  bool _disposed = false;
  int _sinceprune = 0;
  String? _preempted;
  Directory? _dir;

  /// Stats for the settings screen.
  int processed = 0;
  int totalMs = 0;

  /// Original image file of a page (downloaded copy, or the image cache).
  static Future<File> sourceFileOf(PageRef p) => _defaultSource(p);

  static Future<File> _defaultSource(PageRef p) async =>
      p.localPath != null ? File(p.localPath!) : DefaultCacheManager().getSingleFile(p.url);

  String keyFor(PageRef p) =>
      sha1.convert(utf8.encode('v1|${quality.api}|${p.stableKey}')).toString().substring(0, 24);

  ValueListenable<UpscaleState> watch(PageRef p) => _notifier(keyFor(p));

  _StateNotifier _notifier(String key) {
    final n = _states[key];
    if (n != null) return n;
    // keep the map bounded (a long reading session touches thousands of pages)
    if (_states.length > 600) {
      final stale = [for (final e in _states.entries) if (!e.value.listened && e.key != _running?.key) e.key];
      for (final k in stale.take(_states.length - 400)) {
        _states.remove(k)?.dispose();
      }
    }
    return _states[key] = _StateNotifier();
  }

  void _set(String key, UpscaleState s) {
    if (_disposed) return;
    _notifier(key).value = s;
  }

  Future<File> _target(String key) async {
    var dir = _dir;
    if (dir == null) {
      final base = await _cacheDir();
      dir = Directory('${base.path}/upscaled');
      await dir.create(recursive: true);
      _dir = dir;
    }
    return File('${dir.path}/$key.jpg');
  }

  /// Current page first, then [ahead] pages after it, then the previous one.
  void focus(List<PageRef> pages, int current, {int ahead = 3}) {
    if (!enabled || pages.isEmpty || _disposed) return;
    final order = <PageRef>[];
    final c = current.clamp(0, pages.length - 1);
    order.add(pages[c]);
    for (var i = 1; i <= ahead && c + i < pages.length; i++) {
      order.add(pages[c + i]);
    }
    if (c > 0) order.add(pages[c - 1]);
    _replaceQueue(order);
  }

  /// Put one page at the front of the queue; [force] also upscales pages that
  /// are already as wide as the screen (used by the before/after comparison).
  void request(PageRef p, {bool force = false}) {
    if (_disposed) return;
    final k = keyFor(p);
    final st = _notifier(k).value.status;
    if (st == UpscaleStatus.done || k == _running?.key) return;
    if (!force && (st == UpscaleStatus.skipped || st == UpscaleStatus.failed)) return;
    _queue.removeWhere((j) => j.key == k);
    _queue.insert(0, _Job(p, k, force: force));
    _set(k, const UpscaleState(UpscaleStatus.queued));
    _pump();
  }

  /// Queue a whole chapter (after whatever is already focused).
  void enqueueAll(List<PageRef> pages) {
    if (!enabled || _disposed) return;
    final queued = {for (final j in _queue) j.key};
    for (final p in pages) {
      final k = keyFor(p);
      if (queued.contains(k) || k == _running?.key) continue;
      final st = _notifier(k).value.status;
      if (st == UpscaleStatus.done || st == UpscaleStatus.skipped) continue;
      _queue.add(_Job(p, k));
      _set(k, const UpscaleState(UpscaleStatus.queued));
    }
    _pump();
  }

  void _replaceQueue(List<PageRef> order) {
    final wanted = <String>{};
    final jobs = <_Job>[];
    final running = _running;
    // The reader moved on: a page still being processed that is no longer the
    // current one is cancelled right away (it goes back into the queue if it's still
    // near), so the page on screen starts immediately.
    if (running != null && order.isNotEmpty && keyFor(order.first) != running.key) {
      _preempted = running.key;
      unawaited(backend.cancel(running.key));
    }
    for (final p in order) {
      final k = keyFor(p);
      if (!wanted.add(k)) continue;
      if (k == running?.key && k != _preempted) continue;
      final st = _notifier(k).value.status;
      if (st == UpscaleStatus.done || st == UpscaleStatus.skipped || st == UpscaleStatus.failed) continue;
      jobs.add(_Job(p, k));
    }
    _preempted = null;
    for (final j in _queue) {
      if (!wanted.contains(j.key)) _set(j.key, UpscaleState.idle);
    }
    _queue
      ..clear()
      ..addAll(jobs);
    for (final j in jobs) {
      _set(j.key, const UpscaleState(UpscaleStatus.queued));
    }
    _pump();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty && !_disposed && enabled) {
        final job = _queue.removeAt(0);
        _running = job;
        await _process(job);
        _running = null;
      }
    } finally {
      _pumping = false;
      _running = null;
    }
  }

  Future<void> _process(_Job job) async {
    try {
      final out = await _target(job.key);
      if (await out.exists()) {
        unawaited(out.setLastModified(DateTime.now()).catchError((Object _) {}));
        _set(job.key, UpscaleState(UpscaleStatus.done, file: out));
        return;
      }
      _set(job.key, const UpscaleState(UpscaleStatus.running));
      final src = await _sourceFile(job.page);
      final r = await backend.run(
        id: job.key,
        input: src.path,
        output: out.path,
        quality: quality,
        maxSourceWidth: job.force ? 1 << 30 : maxSourceWidth,
      );
      switch (r.status) {
        case 'ok':
          processed++;
          totalMs += r.ms;
          _set(job.key, UpscaleState(UpscaleStatus.done, file: out));
          if (++_sinceprune >= 25) {
            _sinceprune = 0;
            unawaited(prune());
          }
        case 'skipped':
          _set(job.key, UpscaleState(UpscaleStatus.skipped, message: r.message));
        case 'cancelled':
          // if it was re-queued after preemption, keep its "queued" state
          if (!_queue.any((j) => j.key == job.key)) _set(job.key, UpscaleState.idle);
        default:
          _set(job.key, UpscaleState(UpscaleStatus.failed, message: r.message));
      }
    } catch (e) {
      _set(job.key, UpscaleState(UpscaleStatus.failed, message: '$e'));
    }
  }

  /// Stop everything (reader closed / feature switched off).
  Future<void> stop() async {
    for (final j in _queue) {
      _set(j.key, UpscaleState.idle);
    }
    _queue.clear();
    final r = _running;
    if (r != null) await backend.cancel(r.key);
    await backend.release();
  }

  Future<int> cacheBytes() async {
    final dir = await _target('x').then((f) => f.parent);
    var total = 0;
    await for (final f in dir.list()) {
      if (f is File) total += await f.length();
    }
    return total;
  }

  Future<void> clearCache() async {
    final dir = await _target('x').then((f) => f.parent);
    await for (final f in dir.list()) {
      if (f is File) await f.delete().catchError((Object _) => f);
    }
    for (final n in _states.values) {
      if (n.value.isDone) n.value = UpscaleState.idle;
    }
  }

  /// Least-recently-used eviction down to [maxCacheBytes].
  Future<void> prune() async {
    final dir = await _target('x').then((f) => f.parent);
    final files = <(File, FileStat)>[];
    await for (final f in dir.list()) {
      if (f is File) files.add((f, await f.stat()));
    }
    var total = files.fold<int>(0, (s, e) => s + e.$2.size);
    if (total <= maxCacheBytes) return;
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final (f, st) in files) {
      if (total <= maxCacheBytes * 0.8) break;
      await f.delete().catchError((Object _) => f);
      total -= st.size;
    }
  }

  void dispose() {
    _disposed = true;
    _queue.clear();
    for (final n in _states.values) {
      n.dispose();
    }
    _states.clear();
  }
}
