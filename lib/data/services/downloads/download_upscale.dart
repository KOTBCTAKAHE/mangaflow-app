import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../../models/settings.dart';
import '../upscale_service.dart';

/// Progress of the background upscaling pass (for the service notification).
class UpscaleProgress {
  const UpscaleProgress({required this.mangaTitle, required this.chapterTitle, required this.page, required this.pages, required this.chaptersLeft});
  final String mangaTitle;
  final String chapterTitle;
  final int page;
  final int pages;
  final int chaptersLeft;
}

/// Pref the reader writes with the screen's physical width ("Авто" mode needs it here).
const upscaleTargetWidthPref = 'upscale_target_width';

/// Upscales downloaded chapters inside the download service — so a title queued
/// before bed is downloaded *and* enhanced by morning. Results go next to the pages
/// (see [localHdPath]); the reader picks them up instantly.
class DownloadUpscaler {
  DownloadUpscaler({
    required this.db,
    required this.settings,
    required this.prefs,
    UpscaleBackend? backend,
    this.onProgress,
    this.shouldYield,
  }) : backend = backend ?? ChannelUpscaleBackend();

  final Database db;
  final AppSettings Function() settings;
  final SharedPreferences prefs;
  final UpscaleBackend backend;
  final void Function(UpscaleProgress p)? onProgress;

  /// Checked between pages: return true to stop (e.g. new downloads were queued).
  final Future<bool> Function()? shouldYield;

  bool _stopped = false;
  String? _current;
  int processed = 0;

  bool get enabled {
    final s = settings();
    return s.upscaleDownloads && s.upscaleMode != UpscaleMode.off;
  }

  void stop() {
    _stopped = true;
    final c = _current;
    if (c != null) backend.cancel(c);
  }

  static List<File> _pages(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return const [];
    return d.listSync().whereType<File>().where((f) => !f.path.endsWith('.part')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  static bool _handled(File page, UpscaleQuality q) =>
      File(localHdPath(page.path, q)).existsSync() || File(localHdPath(page.path, q, skipMarker: true)).existsSync();

  /// Chapters (oldest download first) that still have pages to enhance.
  Future<List<Map<String, Object?>>> pendingChapters() async {
    final q = settings().upscaleQuality;
    final rows = await db.query('downloads', where: "status = 'done'", orderBy: 'created_at ASC');
    return [
      for (final r in rows)
        if (_pages(r['dir']! as String).any((p) => !_handled(p, q))) r,
    ];
  }

  /// Runs until everything is enhanced, the feature is off, or [stop]/[shouldYield].
  Future<void> run() async {
    if (!enabled) return;
    var chapters = await pendingChapters();
    while (chapters.isNotEmpty && !_stopped && enabled) {
      final row = chapters.first;
      final s = settings();
      final q = s.upscaleQuality;
      final target = prefs.getInt(upscaleTargetWidthPref) ?? 1080;
      final maxSourceWidth = s.upscaleMode == UpscaleMode.always ? 1800 : (target * 0.95).round();
      final pages = _pages(row['dir']! as String);
      for (var i = 0; i < pages.length && !_stopped; i++) {
        final page = pages[i];
        if (_handled(page, q)) continue;
        if (await shouldYield?.call() ?? false) return;
        onProgress?.call(UpscaleProgress(
          mangaTitle: row['manga_title'] as String? ?? '',
          chapterTitle: row['chapter_title'] as String? ?? '',
          page: i + 1,
          pages: pages.length,
          chaptersLeft: chapters.length,
        ));
        final out = File(localHdPath(page.path, q));
        await out.parent.create(recursive: true);
        final id = 'bg|${page.path}|${q.api}';
        _current = id;
        final r = await backend.run(id: id, input: page.path, output: out.path, quality: q, maxSourceWidth: maxSourceWidth);
        _current = null;
        switch (r.status) {
          case 'ok':
            processed++;
          case 'cancelled':
            return;
          default:
            // skipped (already sharp / too big) or failed: remember, don't retry every night
            await File(localHdPath(page.path, q, skipMarker: true)).writeAsString(r.message ?? r.status);
        }
      }
      chapters = await pendingChapters();
    }
  }
}
