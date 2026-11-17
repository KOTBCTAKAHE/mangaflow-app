import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../data/models/manga.dart';
import 'states.dart';

/// Cover image with rounded corners, placeholder and graceful failure.
class MangaCover extends StatelessWidget {
  const MangaCover({super.key, required this.url, this.width, this.radius = MfRadius.md, this.heroTag, this.thumbWidth = 320});
  final String url;
  final double? width;
  final double radius;
  final Object? heroTag;

  /// Server-side resize width (`?w=`) to save memory/traffic in lists.
  final int? thumbWidth;

  String get _src => (thumbWidth == null || url.isEmpty || url.contains('?')) ? url : '$url?w=$thumbWidth';

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    Widget img = url.isEmpty
        ? _Fallback(radius: radius)
        : CachedNetworkImage(
            imageUrl: _src,
            fit: BoxFit.cover,
            fadeInDuration: MfMotion.base,
            memCacheWidth: width == null ? null : (width! * dpr).round(),
            placeholder: (_, __) => Skeleton(radius: radius),
            errorWidget: (_, __, ___) => _Fallback(radius: radius),
          );
    img = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(aspectRatio: MfSize.coverAspect, child: img),
    );
    if (heroTag != null) img = Hero(tag: heroTag!, child: img);
    return SizedBox(width: width, child: img);
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.radius});
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: context.colors.surfaceContainer, borderRadius: BorderRadius.circular(radius)),
        alignment: Alignment.center,
        child: Icon(Icons.auto_stories_outlined, color: context.textTertiary),
      );
}

/// Grid/carousel tile: cover + title (+ optional subtitle/badge/progress).
class MangaTile extends StatelessWidget {
  const MangaTile({
    super.key,
    required this.card,
    required this.onTap,
    this.width,
    this.subtitle,
    this.badge,
    this.progress,
    this.onLongPress,
    this.heroPrefix = 'cover',
  });

  final MangaCard card;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double? width;
  final String? subtitle;
  final String? badge;
  final double? progress;
  final String heroPrefix;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Semantics(
        button: true,
        label: card.title,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(MfRadius.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(children: [
                MangaCover(url: card.coverUrl, width: width, heroTag: '$heroPrefix-${card.key}'),
                if (badge != null)
                  Positioned(
                    top: MfSpace.sm,
                    left: MfSpace.sm,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: MfSpace.sm, vertical: 3),
                      decoration: BoxDecoration(color: MfColors.accent, borderRadius: BorderRadius.circular(MfRadius.pill)),
                      child: Text(badge!, style: MfType.caption.copyWith(color: MfColors.onAccent)),
                    ),
                  ),
                if (progress != null)
                  Positioned(
                    left: MfSpace.sm,
                    right: MfSpace.sm,
                    bottom: MfSpace.sm,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(MfRadius.pill),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 4,
                        backgroundColor: Colors.black.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
              ]),
              const SizedBox(height: MfSpace.sm),
              Text(card.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: MfType.label.copyWith(color: context.colors.onSurface)),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelMedium),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal cover carousel with lazy building.
class CoverCarousel extends StatelessWidget {
  const CoverCarousel({super.key, required this.items, required this.onTap, this.subtitleOf, this.heroPrefix = 'carousel'});
  final List<MangaCard> items;
  final void Function(MangaCard) onTap;
  final String? Function(MangaCard)? subtitleOf;
  final String heroPrefix;

  static const double _w = MfSize.carouselCover;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return SizedBox(
      height: _w / MfSize.coverAspect + 58 * textScale,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
        itemCount: items.length,
        cacheExtent: 400,
        separatorBuilder: (_, __) => const SizedBox(width: MfSpace.md),
        itemBuilder: (context, i) => MangaTile(
          card: items[i],
          width: _w,
          heroPrefix: '$heroPrefix-$i',
          subtitle: subtitleOf?.call(items[i]),
          onTap: () => onTap(items[i]),
        ),
      ),
    );
  }
}

class CarouselSkeleton extends StatelessWidget {
  const CarouselSkeleton({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: CoverCarousel._w / MfSize.coverAspect + 58,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
          itemCount: 5,
          separatorBuilder: (_, __) => const SizedBox(width: MfSpace.md),
          itemBuilder: (_, __) => const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Skeleton(width: CoverCarousel._w, height: CoverCarousel._w / MfSize.coverAspect, radius: MfRadius.md),
            SizedBox(height: MfSpace.sm),
            Skeleton(width: 100, height: 12),
            SizedBox(height: 6),
            Skeleton(width: 64, height: 10),
          ]),
        ),
      );
}

/// Responsive grid delegate for cover grids (adapts to phone/tablet widths).
SliverGridDelegate coverGridDelegate(BuildContext context, {double maxCover = MfSize.gridMaxCover}) {
  final scale = MediaQuery.textScalerOf(context).scale(1);
  return SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: maxCover,
    mainAxisSpacing: MfSpace.lg,
    crossAxisSpacing: MfSpace.md,
    childAspectRatio: MfSize.coverAspect * 0.78 / (scale > 1.1 ? 1.08 : 1),
  );
}

class GridSkeleton extends StatelessWidget {
  const GridSkeleton({super.key, this.count = 9});
  final int count;

  @override
  Widget build(BuildContext context) => SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
        sliver: SliverGrid(
          gridDelegate: coverGridDelegate(context),
          delegate: SliverChildBuilderDelegate(
            (_, __) => const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AspectRatio(aspectRatio: MfSize.coverAspect, child: Skeleton(radius: MfRadius.md)),
              SizedBox(height: MfSpace.sm),
              Skeleton(width: 90, height: 12),
            ]),
            childCount: count,
          ),
        ),
      );
}
