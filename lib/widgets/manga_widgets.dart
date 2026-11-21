import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../data/models/manga.dart';
import 'effects.dart';
import 'net_image.dart';
import 'states.dart';

/// Cover image with rounded corners, placeholder and graceful failure.
///
/// Requests a server-side resize matched to the real on-screen size × device
/// pixel ratio, so covers stay crisp on 3x screens without loading originals.
class MangaCover extends StatelessWidget {
  const MangaCover({super.key, required this.url, this.width, this.radius = MfRadius.md, this.heroTag, this.thumbWidth, this.shadow = true});
  final String url;
  final double? width;
  final double radius;
  final Object? heroTag;
  final bool shadow;

  /// Force a proxy width; by default it is derived from the layout.
  final int? thumbWidth;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    Widget img = LayoutBuilder(builder: (context, box) {
      if (url.isEmpty) return _Fallback(radius: radius);
      final logical = width ?? (box.maxWidth.isFinite ? box.maxWidth : 160.0);
      final proxyW = thumbWidth ?? fitProxyWidth(logical, dpr);
      return Image(
        image: netImage(withWidth(url, proxyW), decodeWidth: (logical * dpr).round()),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        filterQuality: FilterQuality.medium,
        frameBuilder: (context, child, frame, sync) {
          if (sync) return child;
          return AnimatedSwitcher(
            duration: MfMotion.base,
            child: frame == null ? Skeleton(key: const ValueKey('s'), radius: radius) : KeyedSubtree(key: const ValueKey('i'), child: child),
          );
        },
        errorBuilder: (_, __, ___) => _Fallback(radius: radius),
      );
    });
    img = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: shadow
            ? [
                BoxShadow(color: Colors.black.withValues(alpha: 0.32), blurRadius: 18, offset: const Offset(0, 8)),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: AspectRatio(aspectRatio: MfSize.coverAspect, child: img),
      ),
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
    this.index,
    this.showKind = true,
  });

  final MangaCard card;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double? width;
  final String? subtitle;
  final String? badge;
  final double? progress;
  final String heroPrefix;

  /// Position in a list/grid — enables the staggered appear animation.
  final int? index;
  final bool showKind;

  @override
  Widget build(BuildContext context) {
    final kind = card.kind;
    Widget tile = SizedBox(
      width: width,
      child: Semantics(
        button: true,
        label: card.title,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress ?? () => showFullTitle(context, card.title, subtitle: subtitle, onOpen: onTap),
          borderRadius: BorderRadius.circular(MfRadius.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(children: [
                MangaCover(url: card.coverUrl, width: width, heroTag: '$heroPrefix-${card.key}'),
                if (showKind && kind != null && kind != MangaKind.other)
                  Positioned(left: MfSpace.sm, bottom: progress != null ? MfSpace.lg : MfSpace.sm, child: KindChip(kind)),
                if (badge != null)
                  Positioned(
                    top: MfSpace.sm,
                    right: MfSpace.sm,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      constraints: const BoxConstraints(minWidth: 22),
                      decoration: BoxDecoration(
                        color: MfColors.accent,
                        borderRadius: BorderRadius.circular(MfRadius.pill),
                        boxShadow: [BoxShadow(color: MfColors.accent.withValues(alpha: 0.5), blurRadius: 10)],
                      ),
                      child: Text(badge!, textAlign: TextAlign.center, style: MfType.caption.copyWith(color: MfColors.onAccent, fontWeight: FontWeight.w800)),
                    ),
                  ),
                if (progress != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(MfRadius.md)),
                      child: LinearProgressIndicator(
                        value: progress!.clamp(0.0, 1.0),
                        minHeight: 4,
                        color: MfColors.accent,
                        backgroundColor: Colors.black.withValues(alpha: 0.55),
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
    tile = PressableScale(child: tile);
    return index == null ? tile : Appear(index: index!, child: tile);
  }
}

/// Small frosted label with the title's format (Манга / Манхва / …).
class KindChip extends StatelessWidget {
  const KindChip(this.kind, {super.key});
  final MangaKind kind;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(MfRadius.sm),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Text(kind.label, style: MfType.caption.copyWith(color: Colors.white, fontSize: 10, height: 1.3)),
      );
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
          index: i,
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

/// Responsive grid delegate for cover grids: column count from [maxCover],
/// tile height computed from the real cover width + text lines (no overflow at any text scale).
SliverGridDelegate coverGridDelegate(
  BuildContext context, {
  double maxCover = MfSize.gridMaxCover,
  double horizontalPadding = MfSpace.gutter * 2,
  bool subtitle = true,
}) {
  final scale = MediaQuery.textScalerOf(context).scale(1);
  final width = MediaQuery.sizeOf(context).width - horizontalPadding;
  const spacing = MfSpace.md;
  final cols = ((width + spacing) / (maxCover + spacing)).ceil().clamp(2, 12);
  final tileW = (width - spacing * (cols - 1)) / cols;
  final text = MfSpace.sm + 2 * 17 * scale + (subtitle ? 2 + 18 * scale : 0) + 4;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: cols,
    mainAxisSpacing: MfSpace.lg,
    crossAxisSpacing: spacing,
    mainAxisExtent: tileW / MfSize.coverAspect + text,
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

/// Bottom sheet with the complete (untruncated) title, alt names and copy.
Future<void> showFullTitle(
  BuildContext context,
  String title, {
  String? subtitle,
  List<String> altTitles = const [],
  VoidCallback? onOpen,
}) {
  HapticFeedback.selectionClick();
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.7),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(MfSpace.gutter, 0, MfSpace.gutter, MfSpace.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(title, style: MfType.title.copyWith(color: sheet.colors.onSurface, height: 1.3)),
            if (subtitle != null && subtitle.isNotEmpty) ...[
              const SizedBox(height: MfSpace.xs),
              Text(subtitle, style: sheet.text.bodySmall),
            ],
            if (altTitles.isNotEmpty) ...[
              const SizedBox(height: MfSpace.lg),
              Text('Другие названия', style: MfType.overline.copyWith(color: sheet.textTertiary)),
              const SizedBox(height: MfSpace.xs),
              for (final a in altTitles)
                Padding(padding: const EdgeInsets.only(bottom: MfSpace.xs), child: SelectableText(a, style: sheet.text.bodyMedium)),
            ],
            const SizedBox(height: MfSpace.lg),
            Row(children: [
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: title));
                  Navigator.pop(sheet);
                  showSnack(context, 'Название скопировано');
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Копировать'),
              ),
              if (onOpen != null) ...[
                const SizedBox(width: MfSpace.sm),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      Navigator.pop(sheet);
                      onOpen();
                    },
                    child: const Text('Открыть'),
                  ),
                ),
              ],
            ]),
          ]),
        ),
      ),
    ),
  );
}
