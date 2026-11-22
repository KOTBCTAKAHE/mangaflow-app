import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/manga.dart';
import '../../data/models/settings.dart';
import '../../data/services/volume_keys.dart';
import '../../widgets/net_image.dart';
import '../../widgets/states.dart';

/// Ранобэ: text laid out for long reading — book typography, page colours (night, black, sepia,
/// day), one-hand tap zones, a quiet progress line, the next chapter right where the text ends.
class NovelReaderScreen extends ConsumerStatefulWidget {
  const NovelReaderScreen({super.key, required this.sourceId, required this.mangaId, required this.chapterId});
  final String sourceId;
  final String mangaId;
  final String chapterId;

  @override
  ConsumerState<NovelReaderScreen> createState() => _NovelReaderScreenState();
}

class _NovelReaderScreenState extends ConsumerState<NovelReaderScreen> {
  final _scroll = ScrollController();
  MangaDetails? _manga;
  List<Chapter> _ordered = const []; // oldest → newest
  int _idx = 0;
  ChapterText? _text;
  Object? _error;
  bool _ui = true;
  double _progress = 0;
  Timer? _hideTimer;
  Timer? _saveTimer;
  bool _completedSaved = false;
  int _words = 0;

  Chapter? get _chapter => _idx >= 0 && _idx < _ordered.length ? _ordered[_idx] : null;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    final s = ref.read(settingsProvider);
    if (s.keepScreenOn) unawaited(WakelockPlus.enable().catchError((Object _) {}));
    if (s.volumeKeys) {
      unawaited(VolumeKeys.enable((up) {
        final next = s.volumeKeysInverted ? up : !up;
        _page(next ? 1 : -1);
      }));
    }
    unawaited(_init());
  }

  @override
  void dispose() {
    unawaited(_saveNow());
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _scroll.dispose();
    unawaited(VolumeKeys.disable());
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _init() async {
    final catalog = ref.read(catalogRepositoryProvider);
    try {
      var data = await catalog.title(widget.sourceId, widget.mangaId);
      if (!data.chapters.any((c) => c.id == widget.chapterId)) {
        data = await catalog.merged(widget.sourceId, widget.mangaId) ?? data;
      }
      _manga = data.manga;
      _ordered = data.chapters.reversed.toList();
      final i = _ordered.indexWhere((c) => c.id == widget.chapterId);
      await _open(i < 0 ? 0 : i, restore: true);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Loads chapter [i]; [restore] puts the reader back where it stopped last time.
  Future<void> _open(int i, {bool restore = false}) async {
    await _saveNow();
    setState(() {
      _idx = i;
      _text = null;
      _error = null;
      _progress = 0;
      _completedSaved = false;
    });
    final ch = _chapter;
    if (ch == null) return;
    final catalog = ref.read(catalogRepositoryProvider);
    try {
      final t = await catalog.text(widget.sourceId, ch.id);
      if (!mounted || _chapter?.id != ch.id) return;
      setState(() {
        _text = t;
        _words = t.words;
      });
      double? at;
      if (restore) {
        final p = (await ref.read(readingRepositoryProvider).progressFor(widget.sourceId, widget.mangaId))[ch.id];
        if (p != null && !p.completed && p.pageCount > 1) at = p.pageIndex / (p.pageCount - 1);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.jumpTo(at == null ? 0 : (at * _scroll.position.maxScrollExtent).clamp(0, _scroll.position.maxScrollExtent));
        _onScroll();
        _scheduleHide();
      });
      // the next chapters open instantly and work offline
      for (final n in [i + 1, i + 2]) {
        if (n < _ordered.length) unawaited(catalog.text(widget.sourceId, _ordered[n].id).then((_) {}, onError: (Object _) {}));
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final p = max <= 0 ? 1.0 : (_scroll.offset / max).clamp(0.0, 1.0);
    if ((p - _progress).abs() > 0.002) setState(() => _progress = p);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 900), () => unawaited(_saveNow()));
  }

  Future<void> _saveNow() async {
    final m = _manga, ch = _chapter;
    if (m == null || ch == null || _text == null) return;
    final done = _progress >= 0.98;
    if (_completedSaved && done) return;
    _completedSaved = done;
    try {
      await ref.read(readingRepositoryProvider).saveProgress(
            manga: m,
            chapter: ch,
            pageIndex: (_progress * 1000).round(),
            pageCount: 1001,
            completed: done,
          );
    } catch (_) {}
  }

  // ---------------------------------------------------------------- controls
  void _toggleUi([bool? v]) {
    _hideTimer?.cancel();
    setState(() => _ui = v ?? !_ui);
    SystemChrome.setEnabledSystemUIMode(_ui ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && _ui) _toggleUi(false);
    });
  }

  /// One screen down (or up), keeping two lines of the previous screen in sight.
  void _page(int dir) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final step = pos.viewportDimension * 0.86;
    if (dir > 0 && pos.pixels >= pos.maxScrollExtent - 2) {
      if (_idx + 1 < _ordered.length) unawaited(_open(_idx + 1));
      return;
    }
    unawaited(_scroll.animateTo((pos.pixels + dir * step).clamp(0, pos.maxScrollExtent),
        duration: MfMotion.base, curve: MfMotion.standard));
  }

  void _onTap(TapUpDetails d) {
    final h = MediaQuery.sizeOf(context).height;
    final zones = ref.read(settingsProvider).tapZones;
    final y = d.globalPosition.dy;
    if (zones && y > h * 0.7) {
      if (_ui) _toggleUi(false);
      _page(1);
    } else if (zones && y < h * 0.3 && !_ui) {
      _page(-1);
    } else {
      _toggleUi();
    }
  }

  // ---------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(settingsProvider.select((s) => s.novel));
    final th = prefs.theme;
    final overlay = th.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlay.copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: th.background,
        body: Stack(children: [
          Positioned.fill(child: _content(prefs)),
          _TopBar(
            visible: _ui,
            theme: th,
            title: _manga?.title ?? '',
            chapter: _chapter?.title ?? '',
            onChapters: _showChapters,
            onSettings: _showSettings,
          ),
          _BottomBar(
            visible: _ui,
            theme: th,
            progress: _progress,
            minutesLeft: _minutesLeft(),
            hasPrev: _idx > 0,
            hasNext: _idx + 1 < _ordered.length,
            onPrev: () => _open(_idx - 1),
            onNext: () => _open(_idx + 1),
            onSeek: (v) {
              if (_scroll.hasClients) _scroll.jumpTo(v * _scroll.position.maxScrollExtent);
            },
          ),
          // a quiet line while reading: how far into the chapter
          if (!_ui && _text != null)
            Positioned(
              right: 14,
              bottom: MediaQuery.paddingOf(context).bottom + 6,
              child: IgnorePointer(
                child: Text('${(_progress * 100).round()}%',
                    style: TextStyle(fontSize: 11, color: th.text.withValues(alpha: 0.45), fontFeatures: const [FontFeature.tabularFigures()])),
              ),
            ),
        ]),
      ),
    );
  }

  int? _minutesLeft() {
    if (_text == null) return null;
    return math.max(0, (_words * (1 - _progress) / 180).ceil());
  }

  Widget _content(NovelPrefs p) {
    final th = p.theme;
    if (_error != null) {
      return Center(
        child: Theme(
          data: Theme.of(context),
          child: ErrorState(error: _error!, onRetry: () => _chapter == null ? _init() : _open(_idx)),
        ),
      );
    }
    final t = _text;
    if (t == null) return Center(child: CircularProgressIndicator(color: th.text.withValues(alpha: 0.6)));
    final pad = MediaQuery.paddingOf(context);
    final base = TextStyle(
      fontFamily: p.font.family,
      fontSize: p.fontSize,
      height: p.lineHeight,
      color: th.text,
      letterSpacing: 0.1,
    );
    final words = _words;
    final next = _idx + 1 < _ordered.length ? _ordered[_idx + 1] : null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _onTap,
      child: Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: EdgeInsets.fromLTRB(p.margin, pad.top + 72, p.margin, pad.bottom + 140),
          child: Center(
            child: ConstrainedBox(
              // a comfortable line length on tablets: about 70 characters
              constraints: BoxConstraints(maxWidth: p.fontSize * 36),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(_chapter?.title ?? t.title,
                    textAlign: TextAlign.center,
                    style: base.copyWith(fontSize: p.fontSize * 1.45, fontWeight: FontWeight.w700, height: 1.25)),
                const SizedBox(height: 10),
                Text('≈ ${math.max(1, (words / 180).round())} мин · $words слов',
                    textAlign: TextAlign.center, style: base.copyWith(fontSize: p.fontSize * 0.72, color: th.text.withValues(alpha: 0.55))),
                SizedBox(height: p.fontSize * 1.6),
                for (final b in t.blocks) _block(b, p, base),
                SizedBox(height: p.fontSize * 2),
                _EndOfChapter(
                  theme: th,
                  next: next,
                  onNext: next == null ? null : () => _open(_idx + 1),
                  onClose: () => Navigator.of(context).maybePop(),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _block(NovelBlock b, NovelPrefs p, TextStyle base) {
    final fs = p.fontSize;
    List<InlineSpan> spans(TextStyle style) => [
          for (final s in b.spans)
            TextSpan(
              text: s.text,
              style: style.copyWith(
                fontStyle: s.italic ? FontStyle.italic : null,
                fontWeight: s.bold ? FontWeight.w700 : null,
              ),
            ),
        ];
    switch (b.type) {
      case 'h':
        return Padding(
          padding: EdgeInsets.only(top: fs * 0.8, bottom: fs * 0.7),
          child: Text.rich(TextSpan(children: spans(base.copyWith(fontWeight: FontWeight.w700, fontSize: fs * 1.18))),
              textAlign: TextAlign.center),
        );
      case 'hr':
        return Padding(
          padding: EdgeInsets.symmetric(vertical: fs * 0.9),
          child: Text('⁂', textAlign: TextAlign.center, style: base.copyWith(color: p.theme.text.withValues(alpha: 0.5))),
        );
      case 'gap':
        return SizedBox(height: fs * 0.7);
      case 'img':
        final url = b.url;
        if (url == null) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.symmetric(vertical: fs * 0.6),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image(
              image: netImage(url),
              fit: BoxFit.fitWidth,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : AspectRatio(aspectRatio: 1.4, child: ColoredBox(color: p.theme.text.withValues(alpha: 0.06))),
            ),
          ),
        );
      case 'quote':
        return Container(
          margin: EdgeInsets.only(bottom: fs * 0.6),
          padding: EdgeInsets.only(left: fs * 0.8),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: p.theme.text.withValues(alpha: 0.3), width: 3))),
          child: Text.rich(TextSpan(children: spans(base.copyWith(fontStyle: FontStyle.italic))),
              textAlign: p.justify ? TextAlign.justify : TextAlign.start),
        );
      default:
        final dialogue = b.plain.startsWith('—') || b.plain.startsWith('–') || b.plain.startsWith('-');
        return GestureDetector(
          onLongPress: () {
            HapticFeedback.mediumImpact();
            Clipboard.setData(ClipboardData(text: b.plain));
            showSnack(context, 'Абзац скопирован');
          },
          child: Padding(
            padding: EdgeInsets.only(bottom: fs * 0.55),
            child: Text.rich(
              TextSpan(children: [
                // book-style first-line indent (not before a line of dialogue: the dash is its indent)
                if (p.indent && !dialogue) WidgetSpan(child: SizedBox(width: fs * 1.4)),
                ...spans(base),
              ]),
              textAlign: p.justify ? TextAlign.justify : TextAlign.start,
            ),
          ),
        );
    }
  }

  // ---------------------------------------------------------------- sheets
  Future<void> _showChapters() async {
    _hideTimer?.cancel();
    final th = ref.read(settingsProvider).novel.theme;
    final picked = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: th.background,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: ListView.builder(
            controller: ScrollController(initialScrollOffset: math.max(0, (_idx - 3) * 56.0)),
            itemCount: _ordered.length,
            itemExtent: 56,
            itemBuilder: (context, i) => ListTile(
              selected: i == _idx,
              selectedColor: th.text,
              selectedTileColor: th.text.withValues(alpha: 0.08),
              textColor: th.text.withValues(alpha: 0.8),
              title: Text(_ordered[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(context, i),
            ),
          ),
        ),
      ),
    );
    if (picked != null && picked != _idx) await _open(picked);
  }

  Future<void> _showSettings() async {
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => const _NovelSettingsSheet(),
    );
  }
}

// ==================================================================== pieces

class _TopBar extends StatelessWidget {
  const _TopBar({required this.visible, required this.theme, required this.title, required this.chapter,
      required this.onChapters, required this.onSettings});
  final bool visible;
  final NovelTheme theme;
  final String title;
  final String chapter;
  final VoidCallback onChapters;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final fg = theme.text;
    return AnimatedPositioned(
      duration: MfMotion.base,
      curve: MfMotion.standard,
      top: visible ? 0 : -140,
      left: 0,
      right: 0,
      child: Material(
        color: theme.background.withValues(alpha: 0.96),
        elevation: 0,
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 56,
            child: Row(children: [
              IconButton(icon: Icon(Icons.arrow_back_rounded, color: fg), onPressed: () => Navigator.of(context).maybePop()),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: fg.withValues(alpha: 0.6), fontSize: 12)),
                  Text(chapter, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: fg, fontSize: 15, fontWeight: FontWeight.w700)),
                ]),
              ),
              IconButton(tooltip: 'Главы', icon: Icon(Icons.format_list_bulleted_rounded, color: fg), onPressed: onChapters),
              IconButton(tooltip: 'Текст и цвета', icon: Icon(Icons.text_fields_rounded, color: fg), onPressed: onSettings),
            ]),
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.visible,
    required this.theme,
    required this.progress,
    required this.minutesLeft,
    required this.hasPrev,
    required this.hasNext,
    required this.onPrev,
    required this.onNext,
    required this.onSeek,
  });
  final bool visible;
  final NovelTheme theme;
  final double progress;
  final int? minutesLeft;
  final bool hasPrev;
  final bool hasNext;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    final fg = theme.text;
    return AnimatedPositioned(
      duration: MfMotion.base,
      curve: MfMotion.standard,
      bottom: visible ? 0 : -180,
      left: 0,
      right: 0,
      child: Material(
        color: theme.background.withValues(alpha: 0.96),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: fg.withValues(alpha: 0.85),
                  inactiveTrackColor: fg.withValues(alpha: 0.15),
                  thumbColor: fg,
                  overlayColor: fg.withValues(alpha: 0.1),
                ),
                child: Slider(value: progress.clamp(0.0, 1.0), onChanged: onSeek),
              ),
              Row(children: [
                TextButton.icon(
                  onPressed: hasPrev ? onPrev : null,
                  style: TextButton.styleFrom(foregroundColor: fg),
                  icon: const Icon(Icons.chevron_left_rounded),
                  label: const Text('Глава'),
                ),
                Expanded(
                  child: Text(
                    '${(progress * 100).round()}%${minutesLeft == null ? '' : ' · осталось ~$minutesLeft мин'}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 13),
                  ),
                ),
                TextButton.icon(
                  onPressed: hasNext ? onNext : null,
                  style: TextButton.styleFrom(foregroundColor: fg),
                  iconAlignment: IconAlignment.end,
                  icon: const Icon(Icons.chevron_right_rounded),
                  label: const Text('Глава'),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

class _EndOfChapter extends StatelessWidget {
  const _EndOfChapter({required this.theme, required this.next, required this.onNext, required this.onClose});
  final NovelTheme theme;
  final Chapter? next;
  final VoidCallback? onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final fg = theme.text;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(children: [
        Icon(next == null ? Icons.auto_stories_rounded : Icons.check_circle_outline_rounded, color: fg.withValues(alpha: 0.7)),
        const SizedBox(height: 8),
        Text(next == null ? 'Это последняя глава — пока' : 'Конец главы',
            style: TextStyle(color: fg, fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        if (next != null)
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onNext,
              style: FilledButton.styleFrom(backgroundColor: fg, foregroundColor: theme.background, minimumSize: const Size(0, 52)),
              child: Text('Дальше: ${next!.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          )
        else
          OutlinedButton(
            onPressed: onClose,
            style: OutlinedButton.styleFrom(foregroundColor: fg, side: BorderSide(color: fg.withValues(alpha: 0.4))),
            child: const Text('К тайтлу'),
          ),
      ]),
    );
  }
}

/// «Текст и цвета»: size, spacing, font, page colour — with a live sample.
class _NovelSettingsSheet extends ConsumerWidget {
  const _NovelSettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(settingsProvider.select((s) => s.novel));
    final ctrl = ref.read(settingsProvider.notifier);
    void set(NovelPrefs n) => ctrl.update((s) => s.copyWith(novel: n));
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // the sample reads exactly like the chapter will
          AnimatedContainer(
            duration: MfMotion.base,
            padding: EdgeInsets.symmetric(horizontal: p.margin * 0.7, vertical: 16),
            decoration: BoxDecoration(color: p.theme.background, borderRadius: BorderRadius.circular(18)),
            child: Text.rich(
              TextSpan(children: [
                if (p.indent) WidgetSpan(child: SizedBox(width: p.fontSize * 1.4)),
                const TextSpan(text: 'В исповедальне пахло воском, старым деревом и чужими грехами. '),
                const TextSpan(text: 'Зак знал этот запах', style: TextStyle(fontStyle: FontStyle.italic)),
                const TextSpan(text: ' лучше, чем запах собственного дома.'),
              ]),
              maxLines: 4,
              overflow: TextOverflow.fade,
              textAlign: p.justify ? TextAlign.justify : TextAlign.start,
              style: TextStyle(fontFamily: p.font.family, fontSize: p.fontSize, height: p.lineHeight, color: p.theme.text),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            for (final t in NovelTheme.values)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => set(p.copyWith(theme: t)),
                    child: Container(
                      height: 58,
                      decoration: BoxDecoration(
                        color: t.background,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: p.theme == t ? scheme.primary : scheme.outlineVariant, width: p.theme == t ? 2.5 : 1),
                      ),
                      alignment: Alignment.center,
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text('Аа', style: TextStyle(color: t.text, fontSize: 17, fontWeight: FontWeight.w700, fontFamily: p.font.family)),
                        Text(t.label, style: TextStyle(color: t.text.withValues(alpha: 0.7), fontSize: 10)),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            for (final f in NovelFont.values)
              ChoiceChip(
                label: Text(f.label, style: TextStyle(fontFamily: f.family)),
                selected: p.font == f,
                showCheckmark: false,
                onSelected: (_) => set(p.copyWith(font: f)),
              ),
          ]),
          _SliderRow(
            icon: Icons.format_size_rounded,
            label: 'Размер',
            value: p.fontSize,
            min: 13,
            max: 32,
            divisions: 19,
            text: '${p.fontSize.round()}',
            onChanged: (v) => set(p.copyWith(fontSize: v)),
          ),
          _SliderRow(
            icon: Icons.format_line_spacing_rounded,
            label: 'Интервал',
            value: p.lineHeight,
            min: 1.2,
            max: 2.2,
            divisions: 20,
            text: p.lineHeight.toStringAsFixed(2),
            onChanged: (v) => set(p.copyWith(lineHeight: v)),
          ),
          _SliderRow(
            icon: Icons.width_normal_rounded,
            label: 'Поля',
            value: p.margin,
            min: 8,
            max: 48,
            divisions: 10,
            text: '${p.margin.round()}',
            onChanged: (v) => set(p.copyWith(margin: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Выравнивать по ширине'),
            value: p.justify,
            onChanged: (v) => set(p.copyWith(justify: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Красная строка'),
            subtitle: const Text('Отступ в начале абзаца, как в книге'),
            value: p.indent,
            onChanged: (v) => set(p.copyWith(indent: v)),
          ),
          Text('Тап внизу экрана — дальше, вверху — назад, в середине — меню. Долгое нажатие на абзац копирует его.',
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({required this.icon, required this.label, required this.value, required this.min, required this.max,
      required this.divisions, required this.text, required this.onChanged});
  final IconData icon;
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String text;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        SizedBox(width: 72, child: Text(label)),
        Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged)),
        SizedBox(width: 36, child: Text(text, textAlign: TextAlign.end)),
      ]);
}
