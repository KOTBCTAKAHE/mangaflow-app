import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_exception.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';

/// Shimmering placeholder block used by skeleton loaders.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height, this.radius = MfRadius.sm});
  final double? width;
  final double? height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = context.colors.surfaceContainer;
    final hi = context.colors.surfaceContainerHigh;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value * 3 - 1;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(t - 1, -0.2),
              end: Alignment(t + 1, 0.2),
              colors: [base, hi, base],
              stops: const [0.25, 0.5, 0.75],
            ),
          ),
        );
      },
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MfSpace.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EmptyIllustration(icon: icon),
            const SizedBox(height: MfSpace.lg),
            Text(title, style: context.text.titleMedium, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: MfSpace.sm),
              Text(message!, style: context.text.bodySmall, textAlign: TextAlign.center),
            ],
            if (action != null) ...[const SizedBox(height: MfSpace.xl), action!],
          ],
        ),
      ),
    );
  }
}

/// Small composed illustration: accent glow, a fanned stack of "covers" and an icon badge.
class EmptyIllustration extends StatelessWidget {
  const EmptyIllustration({super.key, required this.icon, this.size = 148});
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 700),
      curve: MfMotion.emphasized,
      builder: (context, t, _) => SizedBox(
        width: size,
        height: size * 0.86,
        child: Stack(alignment: Alignment.center, children: [
          CustomPaint(
            size: Size(size, size * 0.86),
            painter: _EmptyPainter(
              accent: scheme.primary,
              card: scheme.surfaceContainerHigh,
              cardEdge: scheme.outlineVariant,
              t: t,
            ),
          ),
          Transform.translate(
            offset: Offset(0, size * 0.08 + (1 - t) * 10),
            child: Opacity(
              opacity: t,
              child: Container(
                width: size * 0.34,
                height: size * 0.34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [scheme.primary, Color.lerp(scheme.primary, Colors.white, 0.3)!],
                    begin: Alignment.bottomLeft,
                    end: Alignment.topRight,
                  ),
                  boxShadow: [BoxShadow(color: scheme.primary.withValues(alpha: 0.45), blurRadius: 18, offset: const Offset(0, 6))],
                ),
                child: Icon(icon, size: size * 0.17, color: scheme.onPrimary),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _EmptyPainter extends CustomPainter {
  _EmptyPainter({required this.accent, required this.card, required this.cardEdge, required this.t});
  final Color accent, card, cardEdge;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.52);
    // glow
    canvas.drawCircle(
      c,
      size.width * 0.5,
      Paint()
        ..shader = RadialGradient(colors: [accent.withValues(alpha: 0.22 * t), accent.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: c, radius: size.width * 0.5)),
    );
    // three fanned covers
    final w = size.width * 0.34, h = w / 0.7;
    for (final (angle, dx, shade) in [(-0.28, -0.22, 0.0), (0.26, 0.22, 0.0), (0.0, 0.0, 0.06)]) {
      canvas.save();
      canvas.translate(c.dx + dx * size.width * t, c.dy - size.height * 0.06);
      canvas.rotate(angle * t);
      final r = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: w, height: h), const Radius.circular(10));
      canvas.drawRRect(r.shift(const Offset(0, 6)), Paint()..color = Colors.black.withValues(alpha: 0.18 * t)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
      canvas.drawRRect(
        r,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color.lerp(card, Colors.white, 0.04 + shade)!, card],
          ).createShader(r.outerRect),
      );
      canvas.drawRRect(r, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = cardEdge.withValues(alpha: 0.6));
      // "text lines" on the card
      final line = Paint()..color = cardEdge.withValues(alpha: 0.55)..strokeCap = StrokeCap.round..strokeWidth = 4;
      canvas.drawLine(Offset(-w * 0.3, -h * 0.32), Offset(w * 0.22, -h * 0.32), line);
      canvas.drawLine(Offset(-w * 0.3, -h * 0.2), Offset(w * 0.05, -h * 0.2), line);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_EmptyPainter old) => old.t != t || old.accent != accent || old.card != card;
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.error, this.onRetry, this.compact = false});
  final Object error;
  final VoidCallback? onRetry;
  final bool compact;

  String get _message => error is ApiException ? (error as ApiException).userMessage : 'Не удалось загрузить данные';

  IconData get _icon {
    final e = error;
    if (e is ApiException && e.isOffline) return Icons.wifi_off_rounded;
    if (e is ApiException && e.isSourceProblem) return Icons.public_off_rounded;
    return Icons.error_outline_rounded;
  }

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter, vertical: MfSpace.md),
        child: Row(children: [
          Icon(_icon, size: MfSize.iconSm, color: context.colors.error),
          const SizedBox(width: MfSpace.sm),
          Expanded(child: Text(_message, style: context.text.bodySmall)),
          if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Повторить')),
        ]),
      );
    }
    return EmptyState(
      icon: _icon,
      title: 'Ошибка загрузки',
      message: _message,
      action: onRetry == null
          ? null
          : OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('Повторить')),
    );
  }
}

/// Standard handling of Riverpod AsyncValue: loading → data → error with retry.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.data, this.loading, this.onRetry});
  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final Widget? loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => value.when(
        skipLoadingOnRefresh: true,
        skipLoadingOnReload: true,
        data: data,
        loading: () => loading ?? const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
        error: (e, _) => ErrorState(error: e, onRetry: onRetry),
      );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.subtitle, this.onMore, this.trailing});
  final String title;
  final String? subtitle;
  final VoidCallback? onMore;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.xxl, MfSpace.sm, MfSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: context.text.titleLarge),
              if (subtitle != null) ...[
                const SizedBox(height: MfSpace.xxs),
                Text(subtitle!, style: context.text.bodySmall),
              ],
            ]),
          ),
          if (trailing != null) trailing!,
          if (onMore != null)
            IconButton(
              onPressed: onMore,
              tooltip: 'Показать все',
              icon: const Icon(Icons.arrow_forward_rounded, size: MfSize.icon),
            ),
        ],
      ),
    );
  }
}

/// Small rounded label (genres, statuses, source names).
class Tag extends StatelessWidget {
  const Tag(this.label, {super.key, this.accent = false, this.icon, this.onTap});
  final String label;
  final bool accent;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = accent ? MfColors.accent : context.colors.onSurfaceVariant;
    return Material(
      color: accent ? MfColors.accentSoft : context.colors.surfaceContainer,
      borderRadius: BorderRadius.circular(MfRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MfRadius.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: MfSpace.md, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 14, color: fg), const SizedBox(width: MfSpace.xs)],
            Text(label, style: MfType.caption.copyWith(color: fg)),
          ]),
        ),
      ),
    );
  }
}

void showSnack(BuildContext context, String message, {String? action, VoidCallback? onAction}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      action: action == null ? null : SnackBarAction(label: action, onPressed: onAction ?? () {}),
    ));
}

String errorText(Object e) => e is ApiException ? e.userMessage : e.toString();
