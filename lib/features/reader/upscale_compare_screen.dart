import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/tokens.dart';
import '../../data/models/manga.dart';
import '../../data/services/upscale_service.dart';
import 'reader_controller.dart';

/// Before/after view of one page: drag the divider to compare the original with
/// the AI-upscaled version; pinch to zoom (both layers move together).
class UpscaleCompareScreen extends StatefulWidget {
  const UpscaleCompareScreen({super.key, required this.page, required this.upscaler});
  final PageRef page;
  final PageUpscaler upscaler;

  @override
  State<UpscaleCompareScreen> createState() => _UpscaleCompareScreenState();
}

class _UpscaleCompareScreenState extends State<UpscaleCompareScreen> {
  final _tc = TransformationController();
  double _split = 0.5;

  @override
  void initState() {
    super.initState();
    // Make sure the page is (or gets) upscaled, even if it is already wide enough.
    widget.upscaler.request(widget.page, force: true);
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _zoomTo(Offset focal) {
    final zoomed = _tc.value.getMaxScaleOnAxis() > 1.01;
    _tc.value = zoomed
        ? Matrix4.identity()
        : (Matrix4.identity()
          ..translate(-focal.dx * 2, -focal.dy * 2)
          ..scale(3.0));
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Сравнение: до и после'),
      ),
      body: ValueListenableBuilder<UpscaleState>(
        valueListenable: widget.upscaler.watch(widget.page),
        builder: (context, st, _) {
          final file = st.file;
          if (!st.isDone || file == null) return _Waiting(state: st, onRetry: () => widget.upscaler.request(widget.page, force: true));
          final original = Image(
            image: pageImageProvider(widget.page),
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          );
          final hd = Image(image: FileImage(file), fit: BoxFit.contain, filterQuality: FilterQuality.medium);
          return LayoutBuilder(builder: (context, box) {
            final x = box.maxWidth * _split;
            return Stack(fit: StackFit.expand, children: [
              GestureDetector(
                onDoubleTapDown: (d) => _zoomTo(d.localPosition),
                onDoubleTap: () {},
                child: InteractiveViewer(
                  transformationController: _tc,
                  maxScale: 8,
                  child: SizedBox.expand(child: original),
                ),
              ),
              // Upscaled layer: same transform, clipped to the right of the divider.
              IgnorePointer(
                child: ClipRect(
                  clipper: _RightOf(x),
                  child: AnimatedBuilder(
                    animation: _tc,
                    builder: (context, child) => Transform(transform: _tc.value, child: child),
                    child: SizedBox.expand(child: hd),
                  ),
                ),
              ),
              // Divider + handle.
              Positioned(
                left: x - 22,
                top: 0,
                bottom: 0,
                width: 44,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (d) =>
                      setState(() => _split = ((x + d.delta.dx) / box.maxWidth).clamp(0.0, 1.0)),
                  child: Stack(alignment: Alignment.center, children: [
                    Container(width: 2, color: Colors.white),
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: MfColors.accent,
                        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
                      ),
                      child: Icon(Icons.compare_arrows_rounded, color: MfColors.onAccent),
                    ),
                  ]),
                ),
              ),
              Positioned(left: MfSpace.md, top: MfSpace.md, child: _Label('Было', dim: true)),
              Positioned(right: MfSpace.md, top: MfSpace.md, child: _Label('Стало (ИИ ×2)')),
              Positioned(
                left: 0,
                right: 0,
                bottom: MediaQuery.paddingOf(context).bottom + MfSpace.md,
                child: Center(
                  child: _Label('Тяните ползунок · двойной тап — приблизить', dim: true),
                ),
              ),
            ]);
          });
        },
      ),
    );
  }
}

class _RightOf extends CustomClipper<Rect> {
  _RightOf(this.x);
  final double x;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(x, 0, size.width, size.height);

  @override
  bool shouldReclip(_RightOf old) => old.x != x;
}

class _Label extends StatelessWidget {
  const _Label(this.text, {this.dim = false});
  final String text;
  final bool dim;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: dim ? Colors.black.withValues(alpha: 0.6) : MfColors.accent,
          borderRadius: BorderRadius.circular(MfRadius.pill),
        ),
        child: Text(text, style: MfType.caption.copyWith(color: dim ? Colors.white : MfColors.onAccent)),
      );
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.state, required this.onRetry});
  final UpscaleState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = state.status == UpscaleStatus.failed || state.status == UpscaleStatus.skipped;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MfSpace.xxl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!failed) const CircularProgressIndicator(strokeWidth: 2.5),
          if (failed) const Icon(Icons.error_outline_rounded, color: Colors.white54, size: 40),
          const SizedBox(height: MfSpace.lg),
          Text(
            failed
                ? 'Не получилось улучшить страницу${state.message == null ? '' : ' (${state.message})'}'
                : 'Нейросеть улучшает страницу…\nОбычно это 5–30 секунд.',
            textAlign: TextAlign.center,
            style: MfType.body.copyWith(color: Colors.white70),
          ),
          if (failed) ...[
            const SizedBox(height: MfSpace.lg),
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
              onPressed: onRetry,
              child: const Text('Попробовать ещё раз'),
            ),
          ],
        ]),
      ),
    );
  }
}
