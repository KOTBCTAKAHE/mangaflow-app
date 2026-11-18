import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/library.dart';
import '../../data/models/manga.dart';
import '../../data/models/settings.dart';
import '../../data/services/upscale_service.dart';
import '../../data/services/volume_keys.dart';
import '../../widgets/effects.dart';
import '../../widgets/net_image.dart';
import '../../widgets/manga_widgets.dart' show showFullTitle;
import '../../widgets/states.dart';
import 'reader_controller.dart';
import 'reader_settings_sheet.dart';
import 'reader_views.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, required this.sourceId, required this.mangaId, required this.chapterId, this.initialPage});
  final String sourceId;
  final String mangaId;
  final String chapterId;
  final int? initialPage;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  late final ReaderController c;
  late final PageUpscaler _up = ref.read(pageUpscalerProvider);
  (int, int, int)? _focused;

  @override
  void initState() {
    super.initState();
    c = ReaderController(
      sourceId: widget.sourceId,
      mangaId: widget.mangaId,
      startChapterId: widget.chapterId,
      initialPage: widget.initialPage,
      catalog: ref.read(catalogRepositoryProvider),
      reading: ref.read(readingRepositoryProvider),
      library: ref.read(libraryRepositoryProvider),
      prefs: ref.read(titlePrefsDaoProvider),
      settings: () => ref.read(settingsProvider),
    )..addListener(_onChange);
    unawaited(c.init());
    if (ref.read(settingsProvider).keepScreenOn) unawaited(WakelockPlus.enable().catchError((Object _) {}));
    _applyVolumeKeys(ref.read(settingsProvider));
    c.setUpscaler(_up.enabled ? _up : null);
    ref.listenManual(settingsProvider.select((s) => (s.upscaleMode, s.upscaleQuality)), (_, __) {
      // the provider applies the new settings first (it listens to the same provider)
      scheduleMicrotask(() {
        if (!mounted) return;
        c.setUpscaler(_up.enabled ? _up : null);
        _focused = null;
        _focusUpscale();
      });
    });
    ref.listenManual(settingsProvider.select((s) => (s.volumeKeys, s.volumeKeysInverted)), (_, __) {
      _applyVolumeKeys(ref.read(settingsProvider));
    });
  }

  void _applyVolumeKeys(AppSettings s) {
    if (!s.volumeKeys) {
      unawaited(VolumeKeys.disable());
      return;
    }
    unawaited(VolumeKeys.enable((up) {
      final next = s.volumeKeysInverted ? up : !up; // default: volume-down = next page
      c.step(next ? 1 : -1);
    }));
  }

  bool _lastUi = true;
  String? _endBuzzed;

  /// Current page first, then the next ones (fewer for the slow "max" model).
  void _focusUpscale() {
    final u = c.upscaler;
    final seg = c.current;
    if (u == null || seg == null || seg.pages.isEmpty) return;
    final key = (seg.index, c.page, seg.pages.length);
    if (key == _focused) return;
    _focused = key;
    u.focus(seg.pages, c.page, ahead: u.quality == UpscaleQuality.max ? 2 : 4);
  }

  void _onChange() {
    _focusUpscale();
    final seg = c.current;
    if (seg != null && c.pageCount > 1 && c.page >= c.pageCount - 1 && _endBuzzed != seg.chapter.id) {
      _endBuzzed = seg.chapter.id;
      HapticFeedback.lightImpact(); // reached the end of the chapter
    }
    if (c.uiVisible != _lastUi) {
      _lastUi = c.uiVisible;
      SystemChrome.setEnabledSystemUIMode(c.uiVisible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
    }
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    unawaited(_up.stop());
    unawaited(VolumeKeys.disable());
    unawaited(c.close().whenComplete(c.dispose));
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Color _bg(ReaderBackground b) => switch (b) {
        ReaderBackground.black => MfColors.readerBlack,
        ReaderBackground.gray => MfColors.readerGray,
        ReaderBackground.white => MfColors.readerWhite,
      };

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    _up.targetWidth = (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).round();
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _bg(s.readerBackground),
        body: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            if (c.error != null && c.segments.isEmpty) {
              return SafeArea(
                child: Stack(children: [
                  Theme(
                    data: ThemeData.dark(useMaterial3: true),
                    child: ErrorState(error: c.error!, onRetry: c.retry),
                  ),
                  const Positioned(left: 4, top: 4, child: BackButton(color: Colors.white)),
                ]),
              );
            }
            if (c.loading && c.segments.isEmpty) {
              return const Center(child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white70));
            }
            return Stack(fit: StackFit.expand, children: [
              _Warmth(
                warmth: s.readerWarmth,
                child: c.mode.isPaged
                    ? PagedReader(c: c, tapZones: s.tapZones)
                    : VerticalReader(c: c, tapZones: s.tapZones),
              ),
              // in-app brightness (works without system permission)
              IgnorePointer(
                child: ColoredBox(color: Colors.black.withValues(alpha: (1 - s.readerBrightness).clamp(0.0, 0.85))),
              ),
              if (c.loading)
                const Align(
                  alignment: Alignment.topCenter,
                  child: LinearProgressIndicator(minHeight: 2, backgroundColor: Colors.transparent),
                ),
              _MiniIndicator(c: c),
              _Overlay(c: c),
              if (s.tapZones) _TapHint(c: c),
            ]);
          },
        ),
      ),
    );
  }
}

/// Faint "12 / 40" shown while the UI is hidden.
class _MiniIndicator extends StatelessWidget {
  const _MiniIndicator({required this.c});
  final ReaderController c;

  @override
  Widget build(BuildContext context) {
    if (c.pageCount == 0) return const SizedBox.shrink();
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: c.uiVisible ? 0 : 1,
        duration: MfMotion.fast,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 6),
            child: Container(
              padding: const EdgeInsets.fromLTRB(5, 3, 10, 3),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(MfRadius.pill)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    value: (c.page + 1) / c.pageCount,
                    strokeWidth: 2,
                    color: MfColors.accent,
                    backgroundColor: Colors.white24,
                  ),
                ),
                const SizedBox(width: 6),
                Text('${c.page + 1} / ${c.pageCount}', style: MfType.caption.copyWith(color: Colors.white70)),
                Text('  ·  ', style: MfType.caption.copyWith(color: Colors.white30)),
                const _Clock(),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Overlay extends ConsumerWidget {
  const _Overlay({required this.c});
  final ReaderController c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = c.uiVisible;
    final seg = c.current;
    final pad = MediaQuery.paddingOf(context);
    const fg = Colors.white;

    Widget bar({required Widget child, required bool top}) => AnimatedSlide(
          offset: visible ? Offset.zero : Offset(0, top ? -1 : 1),
          duration: MfMotion.base,
          curve: MfMotion.emphasized,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: MfMotion.fast,
            child: IgnorePointer(
              ignoring: !visible,
              child: Glass(
                color: Colors.black.withValues(alpha: 0.55),
                blur: 20,
                border: false,
                child: child,
              ),
            ),
          ),
        );

    return Column(children: [
      bar(
        top: true,
        child: Padding(
          padding: EdgeInsets.fromLTRB(4, pad.top + 4, 4, MfSpace.sm),
          child: Row(children: [
            const BackButton(color: fg),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: c.manga == null
                    ? null
                    : () => showFullTitle(context, c.manga!.title, subtitle: seg?.chapter.title, altTitles: c.manga!.altTitles),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.manga?.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: MfType.titleSmall.copyWith(color: fg)),
                if (seg != null)
                  Text(seg.chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: MfType.bodySmall.copyWith(color: Colors.white70)),
              ]),
              ),
            ),
            IconButton(
              tooltip: 'Режим чтения',
              color: fg,
              icon: Icon(switch (c.mode) {
                ReadingMode.vertical => Icons.view_day_outlined,
                ReadingMode.pagedLtr => Icons.arrow_forward_rounded,
                ReadingMode.pagedRtl => Icons.arrow_back_rounded,
                ReadingMode.doublePage => Icons.menu_book_outlined,
              }),
              onPressed: () {
                final modes = ReadingMode.values;
                c.setMode(modes[(modes.indexOf(c.mode) + 1) % modes.length]);
                showSnack(context, c.mode.label);
              },
            ),
            IconButton(
              tooltip: 'Настройки чтения',
              color: fg,
              icon: const Icon(Icons.tune_rounded),
              onPressed: () => showReaderSettings(context, c),
            ),
          ]),
        ),
      ),
      const Spacer(),
      bar(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(MfSpace.sm, MfSpace.sm, MfSpace.sm, pad.bottom + MfSpace.sm),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!c.mode.isPaged) _AutoScrollBar(c: c),
            if (seg != null && c.pageCount > 1)
              Directionality(
                textDirection: c.mode.isRtl ? TextDirection.rtl : TextDirection.ltr,
                child: _ThumbStrip(c: c, pages: seg.pages, visible: visible),
              ),
            Row(children: [
            IconButton(
              tooltip: 'Предыдущая глава',
              color: fg,
              onPressed: c.prevChapter == null ? null : c.goPrevChapter,
              icon: const Icon(Icons.skip_previous_rounded),
            ),
            Expanded(
              child: c.pageCount <= 1
                  ? const SizedBox(height: MfSize.tap)
                  : Directionality(
                      textDirection: c.mode.isRtl ? TextDirection.rtl : TextDirection.ltr,
                      child: _PageSlider(c: c),
                    ),
            ),
            IconButton(
              tooltip: 'Следующая глава',
              color: fg,
              onPressed: c.nextChapter == null ? null : c.goNextChapter,
              icon: const Icon(Icons.skip_next_rounded),
            ),
          ]),
          ]),
        ),
      ),
    ]);
  }
}

class _PageSlider extends StatefulWidget {
  const _PageSlider({required this.c});
  final ReaderController c;

  @override
  State<_PageSlider> createState() => _PageSliderState();
}

class _PageSliderState extends State<_PageSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final max = (c.pageCount - 1).toDouble();
    final value = (_drag ?? c.page.toDouble()).clamp(0.0, max);
    return Row(children: [
      SizedBox(
        width: 34,
        child: Text('${value.round() + 1}', textAlign: TextAlign.center, style: MfType.label.copyWith(color: Colors.white)),
      ),
      Expanded(
        child: Slider(
          value: value,
          max: max,
          divisions: c.pageCount > 1 ? c.pageCount - 1 : null,
          label: '${value.round() + 1}',
          onChanged: (v) => setState(() => _drag = v),
          onChangeEnd: (v) {
            setState(() => _drag = null);
            c.jumpToPage(v.round());
          },
        ),
      ),
      SizedBox(
        width: 34,
        child: Text('${c.pageCount}', textAlign: TextAlign.center, style: MfType.label.copyWith(color: Colors.white70)),
      ),
    ]);
  }
}

/// Network thumbnail URL via the image proxy's `?w=` resize (local files are resized on decode).
ImageProvider thumbProvider(PageRef p) {
  if (p.localPath != null) return pageImageProvider(p, cacheWidth: 120);
  final uri = Uri.tryParse(p.url);
  if (uri == null) return pageImageProvider(p, cacheWidth: 120);
  return netImage(withWidth(p.url, 160), decodeWidth: 120);
}

/// Lazy horizontal strip of page thumbnails; tap to jump.
class _ThumbStrip extends StatefulWidget {
  const _ThumbStrip({required this.c, required this.pages, required this.visible});
  final ReaderController c;
  final List<PageRef> pages;
  final bool visible;

  @override
  State<_ThumbStrip> createState() => _ThumbStripState();
}

class _ThumbStripState extends State<_ThumbStrip> {
  static const double _w = 46, _gap = 6;
  final _ctrl = ScrollController();
  int? _centered;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _center(int page) {
    if (_centered == page) return;
    _centered = page;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_ctrl.hasClients) return;
      final view = _ctrl.position.viewportDimension;
      final target = (page * (_w + _gap) - view / 2 + _w / 2).clamp(0.0, _ctrl.position.maxScrollExtent);
      _ctrl.animateTo(target, duration: MfMotion.base, curve: MfMotion.emphasized);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    if (widget.visible) _center(c.page);
    return SizedBox(
      height: 72,
      child: ListView.separated(
        controller: _ctrl,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: MfSpace.sm, vertical: 4),
        itemCount: widget.pages.length,
        separatorBuilder: (_, __) => const SizedBox(width: _gap),
        itemBuilder: (context, i) {
          final current = i == c.page;
          return GestureDetector(
            onTap: () => c.jumpToPage(i),
            child: AnimatedContainer(
              duration: MfMotion.fast,
              width: _w,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: current ? MfColors.accent : Colors.white12, width: current ? 2 : 1),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: Stack(fit: StackFit.expand, children: [
                  Image(
                    image: thumbProvider(widget.pages[i]),
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.white10),
                    frameBuilder: (_, child, frame, sync) => frame == null && !sync ? const ColoredBox(color: Colors.white10) : child,
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      width: double.infinity,
                      color: current ? MfColors.accent : Colors.black54,
                      child: Text('${i + 1}', textAlign: TextAlign.center,
                          style: MfType.caption.copyWith(fontSize: 9.5, height: 1.4, color: current ? MfColors.onAccent : Colors.white70)),
                    ),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Warm "night light" tint multiplied over the pages.
class _Warmth extends StatelessWidget {
  const _Warmth({required this.warmth, required this.child});
  final double warmth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (warmth <= 0.01) return child;
    final tint = Color.lerp(Colors.white, const Color(0xFFFFB366), warmth.clamp(0.0, 1.0))!;
    return ColorFiltered(colorFilter: ColorFilter.mode(tint, BlendMode.multiply), child: child);
  }
}

class _Clock extends StatefulWidget {
  const _Clock();

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return Text('${two(n.hour)}:${two(n.minute)}', style: MfType.caption.copyWith(color: Colors.white70));
  }
}

/// Webtoon auto-scroll: play/pause + speed.
class _AutoScrollBar extends ConsumerWidget {
  const _AutoScrollBar({required this.c});
  final ReaderController c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speed = ref.watch(settingsProvider.select((s) => s.autoScrollSpeed));
    return Padding(
      padding: const EdgeInsets.only(bottom: MfSpace.xs),
      child: Row(children: [
        const SizedBox(width: MfSpace.xs),
        FilledButton.tonalIcon(
          style: FilledButton.styleFrom(
            backgroundColor: c.autoScrolling ? MfColors.accent : Colors.white.withValues(alpha: 0.1),
            foregroundColor: c.autoScrolling ? MfColors.onAccent : Colors.white,
            visualDensity: VisualDensity.compact,
          ),
          onPressed: () {
            HapticFeedback.selectionClick();
            c.setAutoScroll(!c.autoScrolling);
          },
          icon: Icon(c.autoScrolling ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 20),
          label: Text(c.autoScrolling ? 'Пауза' : 'Автопрокрутка'),
        ),
        const SizedBox(width: MfSpace.sm),
        const Icon(Icons.speed_rounded, size: 18, color: Colors.white54),
        Expanded(
          child: Slider(
            value: speed.clamp(30.0, 600.0),
            min: 30,
            max: 600,
            onChanged: (v) => ref.read(settingsProvider.notifier).updateLocalOnly((x) => x.copyWith(autoScrollSpeed: v)),
            onChangeEnd: (v) => ref.read(settingsProvider.notifier).update((x) => x.copyWith(autoScrollSpeed: v)),
          ),
        ),
      ]),
    );
  }
}

/// First-run overlay explaining the tap zones (once per layout: paged / strip).
class _TapHint extends ConsumerStatefulWidget {
  const _TapHint({required this.c});
  final ReaderController c;

  @override
  ConsumerState<_TapHint> createState() => _TapHintState();
}

class _TapHintState extends ConsumerState<_TapHint> {
  bool _visible = false;
  String? _key;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _maybeShow() {
    final key = 'reader_hint_${widget.c.mode.isPaged ? 'paged' : 'strip'}';
    if (key == _key) return;
    _key = key;
    final prefs = ref.read(prefsProvider);
    if (prefs.getBool(key) ?? false) return;
    unawaited(prefs.setBool(key, true));
    widget.c.toggleUi(false); // show the zones on a clean page
    setState(() => _visible = true);
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    if (c.pageCount > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeShow();
      });
    }
    final paged = c.mode.isPaged;
    final rtl = c.mode.isRtl;
    Widget zone(String label, IconData icon, {bool center = false}) => Expanded(
          child: Container(
            margin: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: center ? MfColors.accent.withValues(alpha: 0.22) : Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(MfRadius.lg),
              border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
            ),
            alignment: Alignment.center,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: Colors.white, size: 30),
              const SizedBox(height: MfSpace.xs),
              Text(label, textAlign: TextAlign.center, style: MfType.label.copyWith(color: Colors.white)),
            ]),
          ),
        );
    final children = paged
        ? [
            zone(rtl ? 'Далее' : 'Назад', Icons.chevron_left_rounded),
            zone('Меню', Icons.touch_app_rounded, center: true),
            zone(rtl ? 'Назад' : 'Далее', Icons.chevron_right_rounded),
          ]
        : [
            zone('Вверх', Icons.keyboard_arrow_up_rounded),
            zone('Меню\nили просто листайте', Icons.touch_app_rounded, center: true),
            zone('Вниз', Icons.keyboard_arrow_down_rounded),
          ];
    return IgnorePointer(
      ignoring: !_visible,
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: MfMotion.base,
        child: GestureDetector(
          onTap: () => setState(() => _visible = false),
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.55),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(MfSpace.sm),
                child: paged
                    ? Row(children: [
                        Expanded(flex: 3, child: Column(children: [children[0]])),
                        Expanded(flex: 4, child: Column(children: [children[1]])),
                        Expanded(flex: 3, child: Column(children: [children[2]])),
                      ])
                    : Column(children: [
                        Expanded(flex: 22, child: Row(children: [children[0]])),
                        Expanded(flex: 56, child: Row(children: [children[1]])),
                        Expanded(flex: 22, child: Row(children: [children[2]])),
                      ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
