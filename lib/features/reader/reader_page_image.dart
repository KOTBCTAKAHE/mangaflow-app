import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../data/models/manga.dart';
import 'reader_controller.dart';

/// One page image with loading progress, broken-image handling and retry.
class ReaderPageImage extends StatefulWidget {
  const ReaderPageImage({
    super.key,
    required this.page,
    required this.fit,
    required this.cacheWidth,
    this.placeholderHeight,
  });

  final PageRef page;
  final BoxFit fit;
  final int cacheWidth;

  /// Vertical mode: reserve space while loading so the strip doesn't jump.
  final double? placeholderHeight;

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
