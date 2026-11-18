import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../core/config.dart';
import '../../data/local/daos.dart';
import '../../data/models/library.dart';
import '../../data/models/manga.dart';
import '../../data/models/settings.dart';
import '../../data/repositories/catalog_repository.dart';
import '../../data/repositories/library_repository.dart';
import '../../data/repositories/reading_repository.dart';
import '../../data/services/upscale_service.dart';
import '../../widgets/net_image.dart';

/// A chapter with its resolved pages (network URLs or local files).
class LoadedChapter {
  LoadedChapter(this.chapter, this.index, this.pages);
  final Chapter chapter;

  /// Position in [ReaderController.ordered] (oldest → newest).
  final int index;
  final List<PageRef> pages;
}

/// Image provider for a page: local file for downloaded chapters, cached network otherwise.
ImageProvider pageImageProvider(PageRef p, {int? cacheWidth}) {
  if (p.localPath != null) {
    final file = FileImage(File(p.localPath!));
    return cacheWidth == null ? file : ResizeImage(file, width: cacheWidth);
  }
  return netImage(p.url, decodeWidth: cacheWidth);
}

/// Reader state & business logic, independent of the widgets that render it.
class ReaderController extends ChangeNotifier with WidgetsBindingObserver {
  ReaderController({
    required this.sourceId,
    required this.mangaId,
    required this.startChapterId,
    required this.initialPage,
    required this.catalog,
    required this.reading,
    required this.library,
    required this.prefs,
    required this.settings,
  });

  final String sourceId;
  final String mangaId;
  final String startChapterId;
  final int? initialPage;
  final CatalogRepository catalog;
  final ReadingRepository reading;
  final LibraryRepository library;
  final TitlePrefsDao prefs;
  final AppSettings Function() settings;

  MangaDetails? manga;

  /// Oldest → newest.
  List<Chapter> ordered = const [];

  /// Loaded consecutive chapters. Paged modes keep exactly one; the vertical
  /// mode appends the next chapter for seamless infinite scrolling.
  final List<LoadedChapter> segments = [];

  ReadingMode mode = ReadingMode.vertical;
  bool loading = true;
  bool loadingNext = false;
  Object? error;
  bool uiVisible = true;

  /// Current position.
  int chapterIdx = 0;
  int page = 0;

  /// Bumped when the views must re-anchor (chapter jump, page jump, mode change).
  int anchorVersion = 0;
  int anchorSegment = 0;
  int anchorPage = 0;

  // ---- session tracking (history & stats)
  String? _sessionId;
  DateTime? _sessionStart;
  final _active = Stopwatch();
  final Set<int> _pagesSeen = {};
  Timer? _saveTimer;
  bool _disposed = false;

  LoadedChapter? get current {
    for (final s in segments) {
      if (s.index == chapterIdx) return s;
    }
    return segments.isEmpty ? null : segments.first;
  }

  int get pageCount => current?.pages.length ?? 0;
  Chapter? get nextChapter => chapterIdx + 1 < ordered.length ? ordered[chapterIdx + 1] : null;
  Chapter? get prevChapter => chapterIdx > 0 ? ordered[chapterIdx - 1] : null;

  // ------------------------------------------------------------------ lifecycle
  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      final data = await catalog.title(sourceId, mangaId);
      manga = data.manga;
      ordered = data.chapters.reversed.toList();
      final idx = ordered.indexWhere((c) => c.id == startChapterId);
      chapterIdx = idx < 0 ? 0 : idx;
      mode = await prefs.readingMode(sourceId, mangaId) ??
          settings().defaultReadingMode ??
          ReadingMode.suggestedFor(manga!.kind);
      var startPage = initialPage;
      if (startPage == null) {
        final p = (await reading.progressFor(sourceId, mangaId))[ordered[chapterIdx].id];
        if (p != null && !p.completed) startPage = p.pageIndex;
      }
      await _openAt(chapterIdx, startPage ?? 0);
    } catch (e) {
      error = e;
      loading = false;
      _notify();
    }
  }

  Future<void> retry() async {
    error = null;
    loading = true;
    _notify();
    if (manga == null) {
      await init();
    } else {
      await _openAt(chapterIdx, page);
    }
  }

  Future<LoadedChapter> _load(int idx) async {
    final ch = ordered[idx];
    final pages = await catalog.pages(sourceId, ch.id);
    return LoadedChapter(ch, idx, pages);
  }

  Future<void> _openAt(int idx, int startPage) async {
    loading = true;
    error = null;
    _notify();
    try {
      final seg = await _load(idx);
      await _endSession();
      segments
        ..clear()
        ..add(seg);
      chapterIdx = idx;
      page = startPage.clamp(0, seg.pages.isEmpty ? 0 : seg.pages.length - 1);
      _startSession();
      _reanchor(0, page);
      loading = false;
      _notify();
      _scheduleSave();
    } catch (e) {
      error = e;
      loading = false;
      _notify();
    }
  }

  Future<void> openChapter(int idx, {int page = 0}) async {
    if (idx < 0 || idx >= ordered.length) return;
    await saveNow(markCompleteIfLast: true);
    await _openAt(idx, page);
  }

  Future<void> goNextChapter() async {
    if (nextChapter == null) return;
    await openChapter(chapterIdx + 1);
  }

  Future<void> goPrevChapter() async {
    if (prevChapter == null) return;
    await openChapter(chapterIdx - 1);
  }

  /// Vertical mode: append the following chapter when the user nears the end.
  Future<void> appendNext() async {
    if (loadingNext || segments.isEmpty || !settings().autoNextChapter) return;
    final last = segments.last;
    if (last.index + 1 >= ordered.length) return;
    loadingNext = true;
    _notify();
    try {
      final seg = await _load(last.index + 1);
      // Page lists are tiny; decoded images are bounded by the image cache and
      // the scroll view's cacheExtent, so earlier chapters can stay in the strip.
      segments.add(seg);
    } catch (_) {
      // the end-of-chapter card shows a manual "next" button
    } finally {
      loadingNext = false;
      _notify();
    }
  }

  void _reanchor(int segment, int pageIdx) {
    anchorSegment = segment;
    anchorPage = pageIdx;
    anchorVersion++;
  }

  // ------------------------------------------------------------------ position
  /// Views report the page that is currently on screen.
  void onPageVisible(int chapterIndex, int pageIndex) {
    if (chapterIndex != chapterIdx) {
      // crossed into another chapter in the vertical strip
      unawaited(_switchChapterInPlace(chapterIndex, pageIndex));
      return;
    }
    if (pageIndex == page) return;
    page = pageIndex;
    _pagesSeen.add(pageIndex);
    _notify();
    _scheduleSave();
  }

  Future<void> _switchChapterInPlace(int newIdx, int pageIndex) async {
    final previous = current;
    if (previous != null && newIdx > chapterIdx) {
      page = previous.pages.length - 1;
      await saveNow(markCompleteIfLast: true);
    } else {
      await saveNow();
    }
    await _endSession();
    chapterIdx = newIdx;
    page = pageIndex;
    _startSession();
    _notify();
    _scheduleSave();
  }

  /// Slider / "go to page" in the current chapter.
  void jumpToPage(int pageIndex) {
    final segIdx = segments.indexWhere((s) => s.index == chapterIdx);
    page = pageIndex.clamp(0, pageCount == 0 ? 0 : pageCount - 1);
    _reanchor(segIdx < 0 ? 0 : segIdx, page);
    _notify();
    _scheduleSave();
  }

  Future<void> setMode(ReadingMode m) async {
    if (m == mode) return;
    mode = m;
    if (m.isPaged) autoScrolling = false;
    // paged modes show a single chapter
    if (m.isPaged && segments.length > 1) {
      segments.removeWhere((s) => s.index != chapterIdx);
    }
    final segIdx = segments.indexWhere((s) => s.index == chapterIdx);
    _reanchor(segIdx < 0 ? 0 : segIdx, page);
    _notify();
    await prefs.setReadingMode(sourceId, mangaId, m);
    await library.setReaderSettings(sourceId, mangaId, {'reading_mode': m.api});
  }

  /// AI upscaler for pages (null = off).
  PageUpscaler? upscaler;

  void setUpscaler(PageUpscaler? u) {
    if (identical(u, upscaler)) return;
    upscaler = u;
    _notify();
  }

  /// Webtoon auto-scroll: runs while the overlay is hidden.
  bool autoScrolling = false;

  void setAutoScroll(bool on) {
    autoScrolling = on;
    if (on) uiVisible = false;
    _notify();
  }

  final _steps = StreamController<int>.broadcast();

  /// Page-turn requests from hardware keys: +1 next, -1 previous (reading order).
  Stream<int> get stepRequests => _steps.stream;
  void step(int delta) {
    if (!_disposed) _steps.add(delta);
  }

  void toggleUi([bool? visible]) {
    uiVisible = visible ?? !uiVisible;
    _notify();
  }

  /// Preload the next [n] pages (and the first pages of the next chapter).
  void preload(BuildContext context, {required int cacheWidth}) {
    final seg = current;
    if (seg == null) return;
    final n = settings().preloadPages;
    for (var i = page + 1; i <= page + n && i < seg.pages.length; i++) {
      unawaited(precacheImage(pageImageProvider(seg.pages[i], cacheWidth: cacheWidth), context, onError: (_, __) {}));
    }
  }

  // ------------------------------------------------------------------ persistence
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(AppConfig.progressSaveDebounce, () => unawaited(saveNow()));
  }

  Future<void> saveNow({bool markCompleteIfLast = false}) async {
    _saveTimer?.cancel();
    final m = manga;
    final seg = current;
    if (m == null || seg == null || seg.pages.isEmpty) return;
    final isLast = page >= seg.pages.length - 1;
    await reading.saveProgress(
      manga: m,
      chapter: seg.chapter,
      pageIndex: page,
      pageCount: seg.pages.length,
      completed: isLast || (markCompleteIfLast && page >= seg.pages.length - 2) ? true : null,
    );
  }

  void _startSession() {
    _sessionId = reading.newSessionId();
    _sessionStart = DateTime.now();
    _pagesSeen
      ..clear()
      ..add(page);
    _active
      ..reset()
      ..start();
  }

  Future<void> _endSession() async {
    final id = _sessionId, start = _sessionStart, m = manga, seg = current;
    if (id == null || start == null || m == null || seg == null) return;
    _sessionId = null;
    _active.stop();
    await reading.endSession(
      id: id,
      manga: m,
      chapter: seg.chapter,
      startedAt: start,
      activeSeconds: _active.elapsed.inSeconds,
      pagesRead: _pagesSeen.length,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _active.start();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _active.stop();
        // persist immediately: the process may be killed while in background
        unawaited(saveNow());
        unawaited(_flushSessionKeepOpen());
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// Writes the current session to history without closing it (crash safety).
  Future<void> _flushSessionKeepOpen() async {
    final id = _sessionId, start = _sessionStart, m = manga, seg = current;
    if (id == null || start == null || m == null || seg == null) return;
    await reading.endSession(
      id: id, manga: m, chapter: seg.chapter, startedAt: start,
      activeSeconds: _active.elapsed.inSeconds, pagesRead: _pagesSeen.length);
  }

  Future<void> close() async {
    WidgetsBinding.instance.removeObserver(this);
    await saveNow();
    await _endSession();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    unawaited(_steps.close());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
