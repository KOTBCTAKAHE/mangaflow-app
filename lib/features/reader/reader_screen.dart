import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/library.dart';
import '../../data/models/settings.dart';
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
  }

  bool _lastUi = true;

  void _onChange() {
    if (c.uiVisible != _lastUi) {
      _lastUi = c.uiVisible;
      SystemChrome.setEnabledSystemUIMode(c.uiVisible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
    }
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
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
              if (c.mode.isPaged)
                PagedReader(c: c, tapZones: s.tapZones)
              else
                VerticalReader(c: c, tapZones: s.tapZones),
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
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(MfRadius.pill)),
              child: Text('${c.page + 1} / ${c.pageCount}', style: MfType.caption.copyWith(color: Colors.white70)),
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
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: top ? Alignment.topCenter : Alignment.bottomCenter,
                    end: top ? Alignment.bottomCenter : Alignment.topCenter,
                    colors: const [Color(0xF0000000), Color(0x99000000), Color(0x00000000)],
                    stops: const [0, 0.65, 1],
                  ),
                ),
                child: child,
              ),
            ),
          ),
        );

    return Column(children: [
      bar(
        top: true,
        child: Padding(
          padding: EdgeInsets.fromLTRB(4, pad.top + 4, 4, MfSpace.xxl),
          child: Row(children: [
            const BackButton(color: fg),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.manga?.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: MfType.titleSmall.copyWith(color: fg)),
                if (seg != null)
                  Text(seg.chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: MfType.bodySmall.copyWith(color: Colors.white70)),
              ]),
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
          padding: EdgeInsets.fromLTRB(MfSpace.sm, MfSpace.xxl, MfSpace.sm, pad.bottom + MfSpace.sm),
          child: Row(children: [
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
