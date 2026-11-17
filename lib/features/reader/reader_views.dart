import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/tokens.dart';
import '../../data/models/library.dart';
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

class _VerticalReaderState extends State<VerticalReader> {
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

  ReaderController get c => widget.c;

  @override
  void initState() {
    super.initState();
    _transform.addListener(() {
      final z = _transform.value.getMaxScaleOnAxis() > 1.01;
      if (z != _zoomed) setState(() => _zoomed = z);
    });
  }

  @override
  void dispose() {
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
    _items = _flatten();
    _marks.removeWhere((k, _) => k >= _items.length);
    final anchor = _anchorFlat.clamp(0, _items.isEmpty ? 0 : _items.length - 1);

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollUpdateNotification || n is ScrollEndNotification) _onScroll();
        return false;
      },
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
    return Container(
      height: 220,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(MfSpace.xl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('Конец: ${segment.chapter.title}', style: MfType.label.copyWith(color: Colors.white60), textAlign: TextAlign.center),
        const SizedBox(height: MfSpace.sm),
        if (next == null)
          Text('Это последняя доступная глава', style: MfType.titleSmall.copyWith(color: Colors.white))
        else ...[
          Text('Далее: ${next.title}', style: MfType.titleSmall.copyWith(color: Colors.white), textAlign: TextAlign.center),
          if (isLastLoaded) ...[
            const SizedBox(height: MfSpace.md),
            c.loadingNext
                ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5))
                : FilledButton(onPressed: () => c.openChapter(segment.index + 1), child: const Text('Следующая глава')),
          ],
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

  ReaderController get c => widget.c;
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
    final next = c.nextChapter;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MfSpace.xxl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Глава прочитана', style: MfType.title.copyWith(color: Colors.white)),
          const SizedBox(height: MfSpace.sm),
          Text(next == null ? 'Это последняя доступная глава' : 'Далее: ${next.title}',
              style: MfType.body.copyWith(color: Colors.white70), textAlign: TextAlign.center),
          const SizedBox(height: MfSpace.xl),
          if (next != null) FilledButton(onPressed: c.goNextChapter, child: const Text('Следующая глава')),
        ]),
      ),
    );
  }
}
