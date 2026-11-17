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
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(color: context.colors.surfaceContainer, shape: BoxShape.circle),
              child: Icon(icon, size: 32, color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: MfSpace.xl),
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
