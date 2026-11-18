import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'effects.dart';

/// Dominant "vibrant" colour of a cover, tuned to be readable on dark UI.
///
/// Decodes a tiny (24px) version of the cached thumbnail and picks a
/// saturation-weighted average — no palette_generator dependency, ~1 ms.
final coverTintProvider = FutureProvider.family<Color?, String>((ref, url) async {
  if (url.isEmpty) return null;
  ref.keepAlive();
  final src = url.contains('?') ? url : '$url?w=160';
  try {
    final image = await _load(ResizeImage(CachedNetworkImageProvider(src), width: 24, height: 34));
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    if (data == null) return null;
    return dominantColor(data.buffer.asUint8List());
  } catch (_) {
    return null;
  }
});

Future<ui.Image> _load(ImageProvider provider) {
  final c = Completer<ui.Image>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener l;
  l = ImageStreamListener((info, _) {
    stream.removeListener(l);
    if (!c.isCompleted) c.complete(info.image.clone());
    info.dispose();
  }, onError: (e, st) {
    stream.removeListener(l);
    if (!c.isCompleted) c.completeError(e, st);
  });
  stream.addListener(l);
  return c.future.timeout(const Duration(seconds: 8));
}

/// Pure function (unit-tested): RGBA bytes → tuned accent, or null for greyscale art.
Color? dominantColor(List<int> rgba) {
  double r = 0, g = 0, b = 0, wSum = 0;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 128) continue;
    final c = HSLColor.fromColor(Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]));
    if (c.lightness < 0.12 || c.lightness > 0.92) continue;
    final w = c.saturation * c.saturation * (1 - (c.lightness - 0.5).abs());
    r += rgba[i] * w;
    g += rgba[i + 1] * w;
    b += rgba[i + 2] * w;
    wSum += w;
  }
  if (wSum < 0.5) return null;
  final avg = HSLColor.fromColor(Color.fromARGB(255, (r / wSum).round(), (g / wSum).round(), (b / wSum).round()));
  if (avg.saturation < 0.18) return null;
  // Lift into a range that reads as an accent on graphite: vivid but not neon.
  return avg.withSaturation(avg.saturation.clamp(0.5, 0.85)).withLightness(avg.lightness.clamp(0.58, 0.70)).toColor();
}

/// Theme with [tint] replacing the accent for one screen (buttons, progress, chips).
ThemeData tintedTheme(ThemeData base, Color tint) {
  final on = onColor(tint);
  return base.copyWith(
    colorScheme: base.colorScheme.copyWith(primary: tint, onPrimary: on),
    filledButtonTheme: FilledButtonThemeData(
      style: (base.filledButtonTheme.style ?? const ButtonStyle()).copyWith(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? base.colorScheme.surfaceContainerHighest : tint,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? base.colorScheme.onSurface.withValues(alpha: 0.38) : on,
        ),
      ),
    ),
    progressIndicatorTheme: base.progressIndicatorTheme.copyWith(color: tint),
  );
}
