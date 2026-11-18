import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../data/models/manga.dart';
import '../../data/services/upscale_service.dart';
import 'reader_controller.dart';

/// One page image with loading progress, broken-image handling and retry.
class ReaderPageImage extends StatefulWidget {
  const ReaderPageImage({
    super.key,
    required this.page,
    required this.fit,
    required this.cacheWidth,
    this.placeholderHeight,
    this.upscaler,
  });

  final PageRef page;
  final BoxFit fit;
  final int cacheWidth;

  /// Vertical mode: reserve space while loading so the strip doesn't jump.
  final double? placeholderHeight;

  /// When set, the AI-upscaled version replaces the page as soon as it's ready.
  final PageUpscaler? upscaler;

  @override
  State<ReaderPageImage> createState() => _ReaderPageImageState();
}

class _ReaderPageImageState extends State<ReaderPageImage> {
  int _attempt = 0;

  Future<void> _retry() async {
    final provider = pageImageProvider(widget.page, cacheWidth: widget.cacheWidth);
    await provider.evict();
    if (widget.page.localPath == null) await CachedNetworkImage.evictFromCache(widget.page.url);
    if (mounted) setState(() => _attempt++);
  }

  Widget _box(Widget child) => widget.placeholderHeight == null
      ? Center(child: child)
      : SizedBox(height: widget.placeholderHeight, child: Center(child: child));

  @override
  Widget build(BuildContext context) {
    final original = _original();
    final u = widget.upscaler;
    if (u == null) return original;
    return ValueListenableBuilder<UpscaleState>(
      valueListenable: u.watch(widget.page),
      child: original,
      builder: (context, st, child) {
        final base = child!;
        var img = base;
        final file = st.file;
        if (st.isDone && file != null) {
          img = Image(
            key: ValueKey(file.path),
            image: ResizeImage(FileImage(file), width: widget.cacheWidth, allowUpscaling: false),
            fit: widget.fit,
            width: double.infinity,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            // keep showing the original until the sharp version is decoded: no flicker, no jump
            frameBuilder: (context, hd, frame, sync) => frame == null && !sync ? base : hd,
            errorBuilder: (_, __, ___) => base,
          );
        }
        if (st.status != UpscaleStatus.running) return img;
        // passthrough: keep the tight constraints of paged mode, or the page sticks to the top
        return Stack(fit: StackFit.passthrough, children: [
          img,
          const Positioned(top: MfSpace.sm, right: MfSpace.sm, child: _UpscaleBadge()),
        ]);
      },
    );
  }

  Widget _original() {
    return Image(
      key: ValueKey('${widget.page.url}#$_attempt'),
      image: pageImageProvider(widget.page, cacheWidth: widget.cacheWidth),
      fit: widget.fit,
      width: double.infinity,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        final total = progress.expectedTotalBytes;
        return _box(SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            value: total == null ? null : progress.cumulativeBytesLoaded / total,
            color: Colors.white70,
          ),
        ));
      },
      errorBuilder: (context, error, _) => _box(Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 40),
        const SizedBox(height: MfSpace.sm),
        Text('Страница ${widget.page.index + 1} не загрузилась',
            style: MfType.bodySmall.copyWith(color: Colors.white70)),
        const SizedBox(height: MfSpace.md),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
          onPressed: _retry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Повторить'),
        ),
      ])),
    );
  }
}

/// "Улучшаю…" pill shown on a page while the model works on it.
class _UpscaleBadge extends StatelessWidget {
  const _UpscaleBadge();

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 4, 10, 4),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(MfRadius.pill)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: Colors.white70)),
            const SizedBox(width: 6),
            Text('Улучшаю…', style: MfType.caption.copyWith(color: Colors.white70, fontSize: 10.5)),
          ]),
        ),
      );
}
