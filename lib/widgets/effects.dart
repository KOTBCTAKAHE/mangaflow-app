import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/theme/tokens.dart';

/// Frosted-glass surface: content scrolling underneath shows through, blurred.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.color, this.blur = 24, this.borderRadius, this.border = true});
  final Widget child;
  final Color? color;
  final double blur;
  final BorderRadius? borderRadius;
  final bool border;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tint = color ?? Theme.of(context).colorScheme.surfaceContainer.withValues(alpha: dark ? 0.74 : 0.8);
    final content = BackdropFilter(
      filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tint,
          borderRadius: borderRadius,
          border: border
              ? Border(top: BorderSide(color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.06)))
              : null,
        ),
        child: child,
      ),
    );
    return borderRadius == null ? ClipRect(child: content) : ClipRRect(borderRadius: borderRadius!, child: content);
  }
}

/// Bottom padding for tab screens drawn under the glass navigation bar.
double bottomInset(BuildContext context, [double extra = MfSpace.xxl]) => MediaQuery.paddingOf(context).bottom + extra;

/// Slight scale-down on press — makes cards feel physical.
class PressableScale extends StatefulWidget {
  const PressableScale({super.key, required this.child, this.scale = 0.965});
  final Widget child;
  final double scale;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _set(bool v) {
    if (v != _down) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => _set(true),
        onPointerUp: (_) => _set(false),
        onPointerCancel: (_) => _set(false),
        child: AnimatedScale(
          scale: _down ? widget.scale : 1,
          duration: _down ? MfMotion.fast : MfMotion.base,
          curve: _down ? Curves.easeOut : Curves.elasticOut,
          child: widget.child,
        ),
      );
}

/// Fade + rise-in, staggered by [index] (capped so long lists don't lag).
class Appear extends StatelessWidget {
  const Appear({super.key, required this.index, required this.child, this.maxStagger = 12});
  final int index;
  final Widget child;
  final int maxStagger;

  @override
  Widget build(BuildContext context) {
    if (index > maxStagger * 2) return child; // deep in a long list: no replay on scroll-back
    final delay = (index.clamp(0, maxStagger)) * 35;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 380 + delay),
      curve: Interval(delay / (380 + delay), 1, curve: MfMotion.emphasized),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 14), child: child),
      ),
      child: child,
    );
  }
}

/// Picks readable text (black/white) for a background color.
Color onColor(Color bg) => bg.computeLuminance() > 0.45 ? const Color(0xFF111214) : Colors.white;
