import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// «По кадрам»: finds comic panels on a page by its gutters (recursive XY-cut
/// over a small grayscale copy) so the reader can zoom from panel to panel.
///
/// Works on-device in an isolate, ~5–20 ms per page; pages without clear
/// gutters (splash pages, webtoon strips) return a single full-page panel.
class PanelLayout {
  const PanelLayout(this.aspect, this.panels);

  /// width / height of the page image.
  final double aspect;

  /// Normalised rects (0..1) in reading order.
  final List<Rect> panels;

  bool get isSingle => panels.length <= 1;
}

/// Pure detector (tested): [gray] is w×h luminance, row-major.
List<Rect> detectPanels(Uint8List gray, int w, int h, {bool rtl = true}) {
  if (w < 16 || h < 16 || gray.length < w * h) return const [Rect.fromLTWH(0, 0, 1, 1)];
  // background = the dominant border tone (white pages, sometimes black)
  var light = 0, dark = 0;
  void sample(int x, int y) {
    final v = gray[y * w + x];
    if (v > 200) light++;
    if (v < 55) dark++;
  }

  for (var x = 0; x < w; x += 2) {
    sample(x, 0);
    sample(x, h - 1);
  }
  for (var y = 0; y < h; y += 2) {
    sample(0, y);
    sample(w - 1, y);
  }
  final darkBg = dark > light * 1.5;
  bool isBg(int v) => darkBg ? v < 50 : v > 215;

  final minGapH = (h * 0.007).ceil().clamp(2, 12);
  final minGapW = (w * 0.007).ceil().clamp(2, 12);
  final out = <_R>[];

  // trims background rows/columns around a region
  _R? trim(_R r) {
    var (x0, y0, x1, y1) = (r.x0, r.y0, r.x1, r.y1);
    bool rowBg(int y) {
      var n = 0;
      for (var x = x0; x < x1; x++) {
        if (!isBg(gray[y * w + x])) n++;
      }
      return n <= (x1 - x0) * 0.01;
    }

    bool colBg(int x) {
      var n = 0;
      for (var y = y0; y < y1; y++) {
        if (!isBg(gray[y * w + x])) n++;
      }
      return n <= (y1 - y0) * 0.01;
    }

    while (y0 < y1 && rowBg(y0)) {
      y0++;
    }
    while (y1 > y0 && rowBg(y1 - 1)) {
      y1--;
    }
    while (x0 < x1 && colBg(x0)) {
      x0++;
    }
    while (x1 > x0 && colBg(x1 - 1)) {
      x1--;
    }
    if (x1 - x0 < 4 || y1 - y0 < 4) return null;
    return _R(x0, y0, x1, y1);
  }

  /// Splits [r] along gutters: horizontal bands when [rows], else vertical.
  List<_R> split(_R r, {required bool rows}) {
    final len = rows ? r.y1 - r.y0 : r.x1 - r.x0;
    final across = rows ? r.x1 - r.x0 : r.y1 - r.y0;
    final gap = rows ? minGapH : minGapW;
    final isGutter = List<bool>.filled(len, false);
    for (var i = 0; i < len; i++) {
      var n = 0;
      for (var j = 0; j < across; j++) {
        final v = rows ? gray[(r.y0 + i) * w + r.x0 + j] : gray[(r.y0 + j) * w + r.x0 + i];
        if (!isBg(v)) n++;
      }
      isGutter[i] = n <= across * 0.015;
    }
    final parts = <_R>[];
    var start = 0, i = 0;
    while (i < len) {
      if (!isGutter[i]) {
        i++;
        continue;
      }
      var j = i;
      while (j < len && isGutter[j]) {
        j++;
      }
      if (j - i >= gap && i > start) {
        parts.add(rows ? _R(r.x0, r.y0 + start, r.x1, r.y0 + i) : _R(r.x0 + start, r.y0, r.x0 + i, r.y1));
        start = j;
      }
      i = j;
    }
    if (start < len) parts.add(rows ? _R(r.x0, r.y0 + start, r.x1, r.y1) : _R(r.x0 + start, r.y0, r.x1, r.y1));
    return parts;
  }

  void cut(_R region, int depth, bool rowsFirst) {
    final r = trim(region);
    if (r == null) return;
    if (depth > 5) {
      out.add(r);
      return;
    }
    var parts = split(r, rows: rowsFirst);
    var byRows = rowsFirst;
    if (parts.length <= 1) {
      parts = split(r, rows: !rowsFirst);
      byRows = !rowsFirst;
    }
    if (parts.length <= 1) {
      out.add(r);
      return;
    }
    if (!byRows && rtl) parts = parts.reversed.toList(); // manga: right panel first
    for (final p in parts) {
      cut(p, depth + 1, !byRows);
    }
  }

  cut(_R(0, 0, w, h), 0, true);

  // drop specks (page numbers, stray marks)
  final area = (w * h).toDouble();
  final kept = out.where((r) => (r.x1 - r.x0) * (r.y1 - r.y0) >= area * 0.012).toList();
  if (kept.length <= 1) return const [Rect.fromLTWH(0, 0, 1, 1)];
  return [
    for (final r in kept)
      Rect.fromLTRB(r.x0 / w, r.y0 / h, r.x1 / w, r.y1 / h),
  ];
}

class _R {
  const _R(this.x0, this.y0, this.x1, this.y1);
  final int x0, y0, x1, y1;
}

List<Rect> _detectEntry(({Uint8List gray, int w, int h, bool rtl}) a) => detectPanels(a.gray, a.w, a.h, rtl: a.rtl);

/// Decodes [provider] small, converts to luminance and detects panels off the UI thread.
class PanelDetector {
  static final _cache = LinkedHashMap<String, PanelLayout>();
  static final _pending = <String, Future<PanelLayout?>>{};

  static PanelLayout? cached(String key) => _cache[key];

  static Future<PanelLayout?> layout(String key, ImageProvider provider, {required bool rtl}) {
    final hit = _cache[key];
    if (hit != null) return SynchronousFuture(hit);
    return _pending[key] ??= _compute(provider, rtl).then((l) {
      _pending.remove(key);
      if (l != null) {
        _cache[key] = l;
        while (_cache.length > 200) {
          _cache.remove(_cache.keys.first);
        }
      }
      return l;
    }, onError: (Object _) {
      _pending.remove(key);
      return null;
    });
  }

  static Future<PanelLayout?> _compute(ImageProvider provider, bool rtl) async {
    final stream = ResizeImage(provider, width: 360, allowUpscaling: false).resolve(ImageConfiguration.empty);
    final completer = Completer<ui.Image>();
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      if (!completer.isCompleted) completer.complete(info.image.clone());
      stream.removeListener(listener);
    }, onError: (Object e, StackTrace? _) {
      if (!completer.isCompleted) completer.completeError(e);
      stream.removeListener(listener);
    });
    stream.addListener(listener);
    final img = await completer.future.timeout(const Duration(seconds: 20));
    try {
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      final w = img.width, h = img.height;
      final rgba = data.buffer.asUint8List();
      final gray = Uint8List(w * h);
      for (var i = 0, p = 0; i < gray.length; i++, p += 4) {
        gray[i] = (rgba[p] * 77 + rgba[p + 1] * 150 + rgba[p + 2] * 29) >> 8;
      }
      final panels = await compute(_detectEntry, (gray: gray, w: w, h: h, rtl: rtl));
      return PanelLayout(w / h, panels);
    } finally {
      img.dispose();
    }
  }
}

/// Matrix that fits [panel] (normalised, inside an image of [aspect] shown with
/// BoxFit.contain in [viewport]) into the viewport, centred, with a small margin.
Matrix4 panelMatrix(Rect panel, double aspect, Size viewport, {double margin = 0.04, double maxScale = 5}) {
  // where the page image sits inside the viewport
  final vAspect = viewport.width / viewport.height;
  final Rect img = aspect > vAspect
      ? Rect.fromCenter(center: viewport.center(Offset.zero), width: viewport.width, height: viewport.width / aspect)
      : Rect.fromCenter(center: viewport.center(Offset.zero), width: viewport.height * aspect, height: viewport.height);
  final r = Rect.fromLTRB(
    img.left + panel.left * img.width,
    img.top + panel.top * img.height,
    img.left + panel.right * img.width,
    img.top + panel.bottom * img.height,
  );
  final s = ((1 - margin * 2) * (viewport.width / r.width < viewport.height / r.height ? viewport.width / r.width : viewport.height / r.height))
      .clamp(1.0, maxScale);
  final tx = viewport.width / 2 - s * r.center.dx;
  final ty = viewport.height / 2 - s * r.center.dy;
  return Matrix4.identity()
    ..translateByDouble(tx, ty, 0, 1)
    ..scaleByDouble(s, s, 1, 1);
}
