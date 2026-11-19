import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../local/daos.dart';
import '../../models/manga.dart';
import '../../models/settings.dart';
import '../download_manager.dart';
import '../upscale_service.dart';
import 'zip.dart';

/// Offline hand-over of downloaded chapters between phones.
///
/// A pack is an ordinary **.cbz** (stored ZIP) — other readers open it as one
/// long chapter — plus a `mangaflow.json` manifest that MangaFlow uses to put
/// every chapter back under its original title:
///
/// ```
/// mangaflow.json          {format, manga, chapters:[{dir, chapter, pages}], cover_b64}
/// c000/0000.jpg ...       pages of the first chapter (AI-enhanced when chosen)
/// c001/0000.webp ...
/// ```
///
/// Plain CBZ/ZIP files from other apps import too (one chapter per folder).
const transferManifestName = 'mangaflow.json';
const transferFormat = 'mangaflow-pack';
const localSourceId = 'local';

const _imageExt = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.avif', '.bmp'};

bool isImageName(String name) => _imageExt.contains(p.extension(name).toLowerCase());

/// "page2" < "page10".
int naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final x = re.allMatches(a.toLowerCase()).toList();
  final y = re.allMatches(b.toLowerCase()).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    final s = x[i].group(0)!, t = y[i].group(0)!;
    final ns = int.tryParse(s), nt = int.tryParse(t);
    final c = ns != null && nt != null ? ns.compareTo(nt) : s.compareTo(t);
    if (c != 0) return c;
  }
  return x.length.compareTo(y.length);
}

String safeFileName(String s) {
  final cleaned = s.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final cut = cleaned.length > 80 ? cleaned.substring(0, 80).trim() : cleaned;
  return cut.isEmpty ? 'MangaFlow' : cut;
}

class ExportChapter {
  const ExportChapter(this.task, {this.chapter});
  final DownloadTask task;

  /// Full chapter info from the title cache (volume, date…), when known.
  final Chapter? chapter;
}

class ExportResult {
  const ExportResult(this.file, this.chapters, this.pages, this.hdPages);
  final File file;
  final int chapters, pages, hdPages;
}

/// What a file contains, before anything is written.
class PackPreview {
  const PackPreview({
    required this.title,
    required this.sourceId,
    required this.mangaId,
    required this.chapters,
    required this.pages,
    required this.bytes,
    required this.alreadyHave,
    required this.isMangaFlowPack,
    this.cover,
  });
  final String title, sourceId, mangaId;
  final List<String> chapters;
  final int pages, bytes, alreadyHave;
  final bool isMangaFlowPack;
  final Uint8List? cover;
}

class ImportResult {
  const ImportResult({
    required this.sourceId,
    required this.mangaId,
    required this.title,
    required this.added,
    required this.skipped,
    this.firstChapterId,
  });
  final String sourceId, mangaId, title;
  final int added, skipped;
  final String? firstChapterId;
}

class _PlannedChapter {
  _PlannedChapter(this.chapter, this.entries);
  final Chapter chapter;
  final List<ZipEntry> entries;
}

class _Plan {
  _Plan(this.manga, this.chapters, {required this.isPack, this.cover});
  final MangaDetails manga;
  final List<_PlannedChapter> chapters;
  final bool isPack;
  final Uint8List? cover;
}

class ChapterTransfer {
  ChapterTransfer({required this.db, required this.rootDir, required this.titleCache});

  final Database db;
  final Future<Directory> Function() rootDir;
  final TitleCacheDao titleCache;

  // ------------------------------------------------------------------ export

  /// Best AI-enhanced copy of [page], if any quality was produced.
  static File? hdFor(String page) {
    for (final q in [UpscaleQuality.max, UpscaleQuality.balanced, UpscaleQuality.fast]) {
      final f = File(localHdPath(page, q));
      if (f.existsSync()) return f;
    }
    return null;
  }

  static List<File> pagesOf(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return const [];
    return d.listSync().whereType<File>().where((f) => isImageName(f.path)).toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  }

  /// Bytes the pack will take (for the "Отправить · 120 МБ" button).
  static int estimate(List<DownloadTask> tasks, {required bool hd}) {
    var total = 0;
    for (final t in tasks) {
      for (final f in pagesOf(t.dir)) {
        final h = hd ? hdFor(f.path) : null;
        total += (h ?? f).lengthSync();
      }
    }
    return total;
  }

  static int hdCount(List<DownloadTask> tasks) {
    var n = 0;
    for (final t in tasks) {
      for (final f in pagesOf(t.dir)) {
        if (hdFor(f.path) != null) n++;
      }
    }
    return n;
  }

  Future<ExportResult> exportPack({
    required MangaDetails manga,
    required List<ExportChapter> chapters,
    required Directory outDir,
    bool hd = true,
    Uint8List? cover,
    void Function(double progress)? onProgress,
  }) async {
    final ordered = [...chapters]..sort((a, b) => (a.task.chapterNumber ?? 0).compareTo(b.task.chapterNumber ?? 0));
    final total = estimate([for (final c in ordered) c.task], hd: hd);
    await outDir.create(recursive: true);
    final label = ordered.length == 1
        ? ordered.first.task.chapterTitle
        : '${ordered.length} гл. ${_num(ordered.first.task.chapterNumber)}–${_num(ordered.last.task.chapterNumber)}';
    final out = File(p.join(outDir.path, '${safeFileName('${manga.title} · $label')}.cbz'));
    final zip = await ZipWriter.create(out.path);
    var done = 0, pages = 0, hdPages = 0;
    final manifestChapters = <Map<String, Object?>>[];
    try {
      for (var i = 0; i < ordered.length; i++) {
        final c = ordered[i];
        final dir = 'c${i.toString().padLeft(3, '0')}';
        final files = pagesOf(c.task.dir);
        for (var j = 0; j < files.length; j++) {
          final h = hd ? hdFor(files[j].path) : null;
          final src = h ?? files[j];
          if (h != null) hdPages++;
          final ext = p.extension(src.path).toLowerCase();
          await zip.addFile('$dir/${j.toString().padLeft(4, '0')}$ext', src, onBytes: (n) {
            done += n;
            if (total > 0) onProgress?.call((done / total).clamp(0, 1).toDouble());
          });
          pages++;
        }
        final ch = c.chapter ??
            Chapter(id: c.task.chapterId, title: c.task.chapterTitle, number: c.task.chapterNumber);
        manifestChapters.add({'dir': dir, 'pages': files.length, 'chapter': ch.toJson()});
      }
      final manifest = {
        'format': transferFormat,
        'version': 1,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'manga': manga.toJson(),
        'chapters': manifestChapters,
        if (cover != null) 'cover_b64': base64Encode(cover),
      };
      await zip.addBytes(transferManifestName, utf8.encode(const JsonEncoder.withIndent(' ').convert(manifest)));
      await zip.close();
    } catch (_) {
      await zip.abort();
      if (out.existsSync()) await out.delete();
      rethrow;
    }
    onProgress?.call(1);
    return ExportResult(out, ordered.length, pages, hdPages);
  }

  static String _num(double? n) => n == null ? '?' : (n == n.roundToDouble() ? n.toInt().toString() : n.toString());

  // ------------------------------------------------------------------ import

  Future<_Plan> _plan(ZipReader zip, String fileName) async {
    final manifestEntry = zip.find(transferManifestName);
    if (manifestEntry != null) {
      final j = jsonDecode(utf8.decode(await zip.read(manifestEntry))) as Map<String, dynamic>;
      if (j['format'] != transferFormat) throw ZipFormatException('неизвестный формат архива');
      final manga = MangaDetails.fromJson((j['manga'] as Map).cast());
      final chapters = <_PlannedChapter>[];
      for (final raw in j['chapters'] as List) {
        final c = (raw as Map).cast<String, dynamic>();
        final dir = '${c['dir']}/';
        final entries = zip.entries.where((e) => e.name.startsWith(dir) && isImageName(e.name)).toList()
          ..sort((a, b) => naturalCompare(a.name, b.name));
        if (entries.isEmpty) continue;
        chapters.add(_PlannedChapter(Chapter.fromJson((c['chapter'] as Map).cast()), entries));
      }
      final b64 = j['cover_b64'] as String?;
      return _Plan(manga, chapters, isPack: true, cover: b64 == null ? null : base64Decode(b64));
    }

    // A foreign CBZ/ZIP: one chapter per folder (or the whole archive).
    final images = zip.entries.where((e) => !e.isDir && isImageName(e.name) && !e.name.contains('__MACOSX')).toList();
    if (images.isEmpty) throw ZipFormatException('в архиве нет страниц');
    final info = zip.find('ComicInfo.xml');
    String? series, number;
    if (info != null && info.size < 1 << 20) {
      final xml = utf8.decode(await zip.read(info), allowMalformed: true);
      String? tag(String t) => RegExp('<$t>([^<]+)</$t>').firstMatch(xml)?.group(1)?.trim();
      series = tag('Series');
      number = tag('Number');
    }
    var title = series ?? p.basenameWithoutExtension(fileName).replaceFirst(RegExp(r'^\d+_'), '');
    title = title.replaceAll('_', ' ').trim();
    if (title.isEmpty) title = 'Файл';
    final groups = <String, List<ZipEntry>>{};
    for (final e in images) {
      groups.putIfAbsent(p.posix.dirname(e.name), () => []).add(e);
    }
    final dirs = groups.keys.toList()..sort(naturalCompare);
    String h(String s) => sha1.convert(utf8.encode(s)).toString().substring(0, 16);
    final mangaId = 'f${h(title)}';
    final chapters = <_PlannedChapter>[];
    for (var i = 0; i < dirs.length; i++) {
      final d = dirs[i];
      final name = d == '.' ? (number != null ? 'Глава $number' : 'Глава 1') : p.posix.basename(d);
      final n = double.tryParse(RegExp(r'(\d+(?:\.\d+)?)').allMatches(name).lastOrNull?.group(1) ?? '') ??
          (dirs.length == 1 ? double.tryParse(number ?? '') : null) ??
          (i + 1).toDouble();
      chapters.add(_PlannedChapter(
        Chapter(id: 'f${h('$title|$d|${groups[d]!.length}')}', title: name, number: n),
        groups[d]!..sort((a, b) => naturalCompare(a.name, b.name)),
      ));
    }
    final manga = MangaDetails(sourceId: localSourceId, sourceName: 'Файлы', id: mangaId, title: title);
    return _Plan(manga, chapters, isPack: false);
  }

  Future<bool> _have(String sourceId, String chapterId) async {
    final r = await db.query('downloads',
        columns: ['status'], where: 'source_id = ? AND chapter_id = ?', whereArgs: [sourceId, chapterId]);
    return r.isNotEmpty && r.first['status'] == 'completed';
  }

  Future<PackPreview> inspect(String path) async {
    final zip = await ZipReader.open(path);
    try {
      final plan = await _plan(zip, p.basename(path));
      var have = 0, pages = 0, bytes = 0;
      for (final c in plan.chapters) {
        if (await _have(plan.manga.sourceId, c.chapter.id)) have++;
        pages += c.entries.length;
        for (final e in c.entries) {
          bytes += e.size;
        }
      }
      Uint8List? cover = plan.cover;
      if (cover == null && plan.chapters.isNotEmpty) {
        final first = plan.chapters.first.entries.first;
        if (first.size < 8 << 20) cover = await zip.read(first);
      }
      return PackPreview(
        title: plan.manga.title,
        sourceId: plan.manga.sourceId,
        mangaId: plan.manga.id,
        chapters: [for (final c in plan.chapters) c.chapter.title],
        pages: pages,
        bytes: bytes,
        alreadyHave: have,
        isMangaFlowPack: plan.isPack,
        cover: cover,
      );
    } finally {
      await zip.close();
    }
  }

  Future<ImportResult> importPack(String path, {void Function(double progress)? onProgress}) async {
    final zip = await ZipReader.open(path);
    try {
      final plan = await _plan(zip, p.basename(path));
      final m = plan.manga;
      final root = (await rootDir()).path;
      var coverUrl = m.coverUrl;
      final coverBytes = plan.cover ??
          (plan.chapters.isNotEmpty && plan.chapters.first.entries.first.size < 8 << 20
              ? await zip.read(plan.chapters.first.entries.first)
              : null);
      if (coverBytes != null) {
        final f = File(p.join(root, 'downloads', m.sourceId, 'covers',
            '${sha1.convert(utf8.encode(m.id)).toString().substring(0, 20)}.img'));
        await f.parent.create(recursive: true);
        await f.writeAsBytes(coverBytes, flush: true);
        coverUrl = f.uri.toString();
      }
      final totalPages = plan.chapters.fold<int>(0, (s, c) => s + c.entries.length);
      var donePages = 0, added = 0, skipped = 0;
      String? firstId;
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      for (var i = 0; i < plan.chapters.length; i++) {
        final c = plan.chapters[i];
        if (await _have(m.sourceId, c.chapter.id)) {
          skipped++;
          donePages += c.entries.length;
          continue;
        }
        final dir = Directory(downloadDirFor(root, m.sourceId, c.chapter.id));
        if (dir.existsSync()) await dir.delete(recursive: true);
        await dir.create(recursive: true);
        var size = 0;
        for (var j = 0; j < c.entries.length; j++) {
          final e = c.entries[j];
          final data = await zip.read(e);
          // our own names only: no path from the archive ever reaches the filesystem
          final ext = p.extension(e.name).toLowerCase();
          await File(p.join(dir.path, '${j.toString().padLeft(4, '0')}$ext')).writeAsBytes(data);
          size += data.length;
          donePages++;
          onProgress?.call(totalPages == 0 ? 1 : donePages / totalPages);
        }
        await db.insert(
          'downloads',
          {
            'source_id': m.sourceId,
            'manga_id': m.id,
            'chapter_id': c.chapter.id,
            'manga_title': m.title,
            'chapter_title': c.chapter.title,
            'chapter_number': c.chapter.number,
            'cover_url': coverUrl,
            'status': 'completed',
            'page_count': c.entries.length,
            'pages_done': c.entries.length,
            'size_bytes': size,
            'dir': dir.path,
            'created_at': now + i,
            'updated_at': now + i,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        added++;
        firstId ??= c.chapter.id;
      }
      await _mergeTitleCache(m, coverUrl, [for (final c in plan.chapters) c.chapter]);
      onProgress?.call(1);
      return ImportResult(
        sourceId: m.sourceId,
        mangaId: m.id,
        title: m.title,
        added: added,
        skipped: skipped,
        firstChapterId: firstId ?? (plan.chapters.isEmpty ? null : plan.chapters.first.chapter.id),
      );
    } finally {
      await zip.close();
    }
  }

  /// The title must open offline: keep what we know, add the imported chapters.
  Future<void> _mergeTitleCache(MangaDetails m, String coverUrl, List<Chapter> chapters) async {
    final existing = (await titleCache.get(m.sourceId, m.id))?.$1;
    final byId = {for (final c in existing?.chapters ?? const <Chapter>[]) c.id: c};
    for (final c in chapters) {
      byId.putIfAbsent(c.id, () => c);
    }
    final merged = byId.values.toList()..sort((a, b) => (b.number ?? 0).compareTo(a.number ?? 0));
    final details = existing?.manga ??
        MangaDetails(
          sourceId: m.sourceId,
          sourceName: m.sourceName,
          id: m.id,
          title: m.title,
          altTitles: m.altTitles,
          coverUrl: m.coverUrl.isNotEmpty && m.sourceId != localSourceId ? m.coverUrl : coverUrl,
          description: m.description,
          genres: m.genres,
          authors: m.authors,
          artists: m.artists,
          status: m.status,
          kind: m.kind,
          webUrl: m.webUrl,
          ageRating: m.ageRating,
        );
    await titleCache.put(TitleData(manga: details, chapters: merged));
  }
}
