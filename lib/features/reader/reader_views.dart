import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/theme/tokens.dart';
import '../../data/models/library.dart';
import '../../data/models/manga.dart';
import 'reader_controller.dart';
import 'reader_page_image.dart';

/// Decides what a tap at [pos] means (paged modes): -1 previous, 1 next, 0 toggle UI.
int tapZone(Offset pos, Size size, {required bool rtl}) {
  final x = pos.dx / size.width;
  if (x < 0.3) return rtl ? 1 : -1;
  if (x > 0.7) return rtl ? -1 : 1;
  return 0;
}

int _cacheWidth(BuildContext context) {
  final mq = MediaQuery.of(context);
  return (mq.size.width * mq.devicePixelRatio).round().clamp(480, 2160);
}

// =====================================================================================
// Vertical (webtoon) — continuous strip, infinite into the next chapter.
// =====================================================================================

class VerticalReader extends StatefulWidget {
  const VerticalReader({super.key, required this.c, required this.tapZones});
  final ReaderController c;
  final bool tapZones;

  @override
  State<VerticalReader> createState() => _VerticalReaderState();
}

typedef _Item = ({int seg, int page}); // page == -1 → end-of-chapter card

class _VerticalReaderState extends State<VerticalReader> with SingleTickerProviderStateMixin {
  ScrollController _scroll = ScrollController();
  final _centerKey = UniqueKey();
  final _transform = TransformationController();
  final Map<int, BuildContext> _marks = {};
  bool _zoomed = false;
  int _anchorVersion = -1;
  int _anchorFlat = 0;
  List<_Item> _items = const [];
  Timer? _throttle;
  TapDownDetails? _doubleTap;
  StreamSubscription<int>? _steps;
  late final Ticker _ticker = createTicker(_tick);
  Duration _lastTick = Duration.zero;
  bool _finger = false;

  ReaderController get c => widget.c;

  /// Auto-scroll: advances by speed × dt; pauses under a finger or while the menu is open.
  void _tick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (_finger || _zoomed || !_scroll.hasClients || dt <= 0 || dt > 0.25) return;
    final pos = _scroll.position;
    final next = pos.pixels + c.settings().autoScrollSpeed * dt;
    if (next >= pos.maxScrollExtent) {
      _scroll.jumpTo(pos.maxScrollExtent);
      if (c.nextChapter == null && !c.loadingNext) c.setAutoScroll(false);
      return;
    }
    _scroll.jumpTo(next);
    _onScroll();
  }

  void _syncTicker() {
    final run = c.autoScrolling && !c.uiVisible;
    if (run && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    _steps = c.stepRequests.listen((d) => _scrollBy(0.8 * d));
    _transform.addListener(() {
      final z = _transform.value.getMaxScaleOnAxis() > 1.01;
      if (z != _zoomed) setState(() => _zoomed = z);
    });
  }

  @override
  void dispose() {
    _steps?.cancel();
    _ticker.dispose();
    _throttle?.cancel();
    _scroll.dispose();
    _transform.dispose();
    super.dispose();
  }

  List<_Item> _flatten() => [
        for (var s = 0; s < c.segments.length; s++) ...[
          for (var p = 0; p < c.segments[s].pages.length; p++) (seg: s, page: p),
          (seg: s, page: -1),
        ],
      ];

  void _syncAnchor() {
    if (_anchorVersion == c.anchorVersion) return;
    _anchorVersion = c.anchorVersion;
    final flat = _flatten();
    final idx = flat.indexWhere((i) => i.seg == c.anchorSegment && i.page == c.anchorPage);
    _anchorFlat = idx < 0 ? 0 : idx;
    final old = _scroll;
    _scroll = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    _transform.value = Matrix4.identity();
  }

  void _onScroll() {
    if (_throttle?.isActive ?? false) return;
    _throttle = Timer(const Duration(milliseconds: 120), _detectVisible);
  }

  /// Finds the item crossing the upper third of the viewport.
  void _detectVisible() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final probe = box.size.height * 0.33;
    for (final e in _marks.entries) {
      final ctx = e.value;
      if (!ctx.mounted) continue;
      final rb = ctx.findRenderObject() as RenderBox?;
      if (rb == null || !rb.attached) continue;
      final top = rb.localToGlobal(Offset.zero, ancestor: box).dy;
      if (top <= probe && top + rb.size.height > probe) {
        if (e.key >= _items.length) return;
        final item = _items[e.key];
        if (item.page >= 0 && item.seg < c.segments.length) {
          c.onPageVisible(c.segments[item.seg].index, item.page);
          c.preload(context, cacheWidth: _cacheWidth(context));
        }
        return;
      }
    }
  }

  void _scrollBy(double fraction) {
    if (!_scroll.hasClients) return;
    final h = (context.findRenderObject() as RenderBox?)?.size.height ?? 600;
    final target = (_scroll.offset + h * fraction).clamp(_scroll.position.minScrollExtent, _scroll.position.maxScrollExtent);
    _scroll.animateTo(target, duration: MfMotion.slow, curve: MfMotion.standard);
  }

  void _onTapUp(TapUpDetails d) {
    final size = (context.findRenderObject() as RenderBox).size;
    final y = d.localPosition.dy / size.height;
    if (widget.tapZones && !_zoomed && y < 0.22) return _scrollBy(-0.8);
    if (widget.tapZones && !_zoomed && y > 0.78) return _scrollBy(0.8);
    c.toggleUi();
  }

  void _onDoubleTap() {
    if (_zoomed) {
      _transform.value = Matrix4.identity();
      return;
    }
    final p = _doubleTap?.localPosition ?? Offset.zero;
    _transform.value = Matrix4.identity()
      ..translate(-p.dx, -p.dy)
      ..scale(2.0);
    HapticFeedback.lightImpact();
  }

  Widget _buildItem(BuildContext context, int flatIndex) {
    final item = _items[flatIndex];
    final seg = c.segments[item.seg];
    final h = MediaQuery.sizeOf(context).height;
    return Builder(builder: (ctx) {
      _marks[flatIndex] = ctx;
      if (item.page == -1) {
        if (item.seg == c.segments.length - 1) {
          // reaching the end of the strip loads the next chapter
          WidgetsBinding.instance.addPostFrameCallback((_) => c.appendNext());
        }
        return _ChapterEndCard(c: c, segment: seg);
      }
      return ReaderPageImage(
        page: seg.pages[item.page],
        fit: BoxFit.fitWidth,
        cacheWidth: _cacheWidth(context),
        placeholderHeight: h * 0.75,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncAnchor();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncTicker();
    });
    _items = _flatten();
    _marks.removeWhere((k, _) => k >= _items.length);
    final anchor = _anchorFlat.clamp(0, _items.isEmpty ? 0 : _items.length - 1);

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollUpdateNotification || n is ScrollEndNotification) _onScroll();
        return false;
      },
      child: Listener(
        onPointerDown: (_) => _finger = true,
        onPointerUp: (_) => _finger = false,
        onPointerCancel: (_) => _finger = false,
        child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: _onTapUp,
        onDoubleTapDown: (d) => _doubleTap = d,
        onDoubleTap: _onDoubleTap,
        child: InteractiveViewer(
          transformationController: _transform,
          minScale: 1,
          maxScale: 3.5,
          panEnabled: _zoomed,
          clipBehavior: Clip.none,
          child: CustomScrollView(
            key: ValueKey(_anchorVersion),
            controller: _scroll,
            center: _centerKey,
            cacheExtent: MediaQuery.sizeOf(context).height * 2.5,
            physics: _zoomed ? const NeverScrollableScrollPhysics() : const ClampingScrollPhysics(),
            slivers: [
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _buildItem(context, anchor - 1 - i),
                  childCount: anchor,
                  addAutomaticKeepAlives: false,
                ),
              ),
              SliverList(
                key: _centerKey,
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _buildItem(context, anchor + i),
                  childCount: _items.length - anchor,
                  addAutomaticKeepAlives: false,
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

class _ChapterEndCard extends StatelessWidget {
  const _ChapterEndCard({required this.c, required this.segment});
  final ReaderController c;
  final LoadedChapter segment;

  @override
  Widget build(BuildContext context) {
    final isLastLoaded = segment == c.segments.last;
    final next = segment.index + 1 < c.ordered.length ? c.ordered[segment.index + 1] : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter, vertical: MfSpace.xxxl),
      child: ChapterFinishCard(
        finished: segment.chapter,
        next: next,
        remaining: c.ordered.length - segment.index - 1,
        loading: isLastLoaded && c.loadingNext,
        // in the strip the next chapter streams in below; the button jumps straight to it
        onNext: next == null ? null : () => c.openChapter(segment.index + 1),
      ),
    );
  }
}

/// "Chapter finished" card shared by both reading modes.
class ChapterFinishCard extends StatelessWidget {
  const ChapterFinishCard({
    super.key,
    required this.finished,
    required this.next,
    required this.remaining,
    required this.onNext,
    this.loading = false,
  });

  final Chapter finished;
  final Chapter? next;
  final int remaining;
  final VoidCallback? onNext;
  final bool loading;

  String _plural(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return 'глава';
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'главы';
    return 'глав';
  }

  @override
  Widget build(BuildContext context) {
    final accent = MfColors.accent;
    return Container(
      constraints: const BoxConstraints(maxWidth: 460),
      padding: const EdgeInsets.all(MfSpace.xl),
      decoration: BoxDecoration(
        color: const Color(0xFF17181C),
        borderRadius: BorderRadius.circular(MfRadius.xl),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        gradient: RadialGradient(
          center: const Alignment(0, -1.2),
          radius: 1.4,
          colors: [accent.withValues(alpha: 0.18), const Color(0xFF17181C)],
        ),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent,
            boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.5), blurRadius: 20)],
          ),
          child: Icon(Icons.check_rounded, color: MfColors.onAccent, size: 30),
        ),
        const SizedBox(height: MfSpace.md),
        Text('Глава прочитана', style: MfType.title.copyWith(color: Colors.white)),
        const SizedBox(height: MfSpace.xs),
        Text(finished.title, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
            style: MfType.bodySmall.copyWith(color: Colors.white60)),
        const SizedBox(height: MfSpace.lg),
        if (next == null)
          Text('Это последняя доступная глава.\nНовые появятся в «Обновлениях».',
              textAlign: TextAlign.center, style: MfType.body.copyWith(color: Colors.white70))
        else ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(MfSpace.md),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(MfRadius.md),
            ),
            child: Row(children: [
              Icon(Icons.arrow_downward_rounded, color: accent, size: 20),
              const SizedBox(width: MfSpace.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Далее', style: MfType.caption.copyWith(color: Colors.white54)),
                  Text(next!.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: MfType.bodyStrong.copyWith(color: Colors.white)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: MfSpace.md),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: loading
                ? const Center(child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5)))
                : FilledButton.icon(
                    onPressed: onNext,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Следующая глава'),
                  ),
          ),
          const SizedBox(height: MfSpace.sm),
          Text('Ещё $remaining ${_plural(remaining)} впереди', style: MfType.caption.copyWith(color: Colors.white38)),
        ],
      ]),
    );
  }
}

// =====================================================================================
// Paged — LTR / RTL / double-page spreads, pinch & double-tap zoom.
// =====================================================================================

class PagedReader extends StatefulWidget {
  const PagedReader({super.key, required this.c, required this.tapZones});
  final ReaderController c;
  final bool tapZones;

  @override
  State<PagedReader> createState() => _PagedReaderState();
}

class _PagedReaderState extends State<PagedReader> {
  PageController? _pc;
  int _anchorVersion = -1;
  bool _zoomed = false;
  bool _autoAdvancing = false;
  StreamSubscription<int>? _steps;

  ReaderController get c => widget.c;

  @override
  void initState() {
    super.initState();
    _steps = c.stepRequests.listen(_go);
  }
  bool get _double => c.mode == ReadingMode.doublePage;

  /// Spreads: first page alone (cover), then pairs.
  List<List<int>> _spreads(int count) {
    if (!_double) return [for (var i = 0; i < count; i++) [i]];
    final out = <List<int>>[];
    if (count > 0) out.add([0]);
    for (var i = 1; i < count; i += 2) {
      out.add(i + 1 < count ? [i, i + 1] : [i]);
    }
    return out;
  }

  int _spreadOf(List<List<int>> spreads, int page) {
    for (var i = 0; i < spreads.length; i++) {
      if (spreads[i].contains(page)) return i;
    }
    return 0;
  }

  @override
  void dispose() {
    _steps?.cancel();
    _pc?.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final pc = _pc;
    if (pc == null || !pc.hasClients) return;
    final target = (pc.page?.round() ?? 0) + delta;
    if (target < 0) {
      c.goPrevChapter();
      return;
    }
    pc.animateToPage(target, duration: MfMotion.base, curve: MfMotion.standard);
  }

  @override
  Widget build(BuildContext context) {
    final seg = c.current;
    if (seg == null) return const SizedBox.shrink();
    final spreads = _spreads(seg.pages.length);
    if (_anchorVersion != c.anchorVersion || _pc == null) {
      _anchorVersion = c.anchorVersion;
      _pc?.dispose();
      _pc = PageController(initialPage: _spreadOf(spreads, c.anchorPage));
      _zoomed = false;
      _autoAdvancing = false;
    }
    final rtl = c.mode.isRtl;

    return LayoutBuilder(builder: (context, box) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final zone = widget.tapZones && !_zoomed ? tapZone(d.localPosition, box.biggest, rtl: rtl) : 0;
          if (zone == 0) {
            c.toggleUi();
          } else {
            _go(zone);
          }
        },
        child: PageView.builder(
          key: ValueKey('pv-$_anchorVersion-${c.mode.api}'),
          controller: _pc,
          reverse: rtl,
          allowImplicitScrolling: true,
          physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
          itemCount: spreads.length + 1,
          onPageChanged: (i) {
            if (i >= spreads.length) {
              if (c.settings().autoNextChapter && c.nextChapter != null && !_autoAdvancing) {
                _autoAdvancing = true;
                Future<void>.delayed(const Duration(milliseconds: 450), c.goNextChapter);
              }
              return;
            }
            c.onPageVisible(seg.index, spreads[i].last);
            c.preload(context, cacheWidth: _cacheWidth(context));
          },
          itemBuilder: (context, i) {
            if (i >= spreads.length) return _PagedEnd(c: c);
            final pages = [for (final p in spreads[i]) seg.pages[p]];
            final ordered = rtl ? pages.reversed.toList() : pages;
            return _ZoomablePage(
              onZoomChanged: (z) {
                if (z != _zoomed) setState(() => _zoomed = z);
              },
              child: pages.length == 1
                  ? ReaderPageImage(page: pages.first, fit: BoxFit.contain, cacheWidth: _cacheWidth(context))
                  : Row(children: [
                      for (final p in ordered)
                        Expanded(
                          child: ReaderPageImage(page: p, fit: BoxFit.contain, cacheWidth: _cacheWidth(context) ~/ 2),
                        ),
                    ]),
            );
          },
        ),
      );
    });
  }
}

class _ZoomablePage extends StatefulWidget {
  const _ZoomablePage({required this.child, required this.onZoomChanged});
  final Widget child;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ZoomablePage> createState() => _ZoomablePageState();
}

class _ZoomablePageState extends State<_ZoomablePage> with SingleTickerProviderStateMixin {
  final _t = TransformationController();
  late final AnimationController _anim = AnimationController(vsync: this, duration: MfMotion.base);
  Animation<Matrix4>? _tween;
  TapDownDetails? _tap;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _t.addListener(() {
      final z = _t.value.getMaxScaleOnAxis() > 1.01;
      if (z != _zoomed) {
        _zoomed = z;
        widget.onZoomChanged(z);
      }
    });
    _anim.addListener(() {
      final t = _tween;
      if (t != null) _t.value = t.value;
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    _t.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    final p = _tap?.localPosition ?? Offset.zero;
    final end = _zoomed
        ? Matrix4.identity()
        : (Matrix4.identity()
          ..translate(-p.dx * 1.5, -p.dy * 1.5)
          ..scale(2.5));
    _tween = Matrix4Tween(begin: _t.value, end: end).animate(CurvedAnimation(parent: _anim, curve: MfMotion.emphasized));
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onDoubleTapDown: (d) => _tap = d,
        onDoubleTap: _toggleZoom,
        child: InteractiveViewer(
          transformationController: _t,
          minScale: 1,
          maxScale: 5,
          panEnabled: _zoomed,
          child: SizedBox.expand(child: widget.child),
        ),
      );
}

class _PagedEnd extends StatelessWidget {
  const _PagedEnd({required this.c});
  final ReaderController c;

  @override
  Widget build(BuildContext context) {
    final seg = c.current;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(MfSpace.gutter),
        child: seg == null
            ? const SizedBox.shrink()
            : ChapterFinishCard(
                finished: seg.chapter,
                next: c.nextChapter,
                remaining: c.ordered.length - seg.index - 1,
                onNext: c.nextChapter == null ? null : c.goNextChapter,
              ),
      ),
    );
  }
}
