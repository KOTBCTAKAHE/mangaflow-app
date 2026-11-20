import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// «По кадрам»: finds comic panels on a page (ink blobs + XY-cut along gutters and
/// border lines over a 600-px grayscale copy) so the reader can go panel to panel.
///
/// Works on-device in an isolate, ~20–60 ms per page; pages without clear panels
/// (splash pages, webtoon strips) return a single full-page panel.
class PanelLayout {
  const PanelLayout(this.aspect, this.panels);

  /// width / height of the page image.
  final double aspect;

  /// Normalised rects (0..1) in reading order.
  final List<Rect> panels;

  bool get isSingle => panels.length <= 1;
}

/// Pure detector (tested): [gray] is w×h luminance, row-major.
///
/// 1. Paper tone from the page edges (white, cream, grey scans; black pages too).
/// 2. Connected blobs of ink → big blocks (panels whose art touches stay together).
/// 3. Inside each block a recursive XY-cut splits along gutters **and** along panel
///    border lines (thin, almost solid dark runs) — after downscaling, the white gap
///    between two bordered panels often melts into one dark line.
/// 4. Reading order: bands top→bottom, right→left for manga.
List<Rect> detectPanels(Uint8List gray, int w, int h, {bool rtl = true}) {
  const whole = [Rect.fromLTWH(0, 0, 1, 1)];
  if (w < 16 || h < 16 || gray.length < w * h || h > w * 3) return whole;

  // ---- paper tone
  final border = <int>[];
  for (final y in [0, 1, h - 2, h - 1]) {
    for (var x = 0; x < w; x++) {
      border.add(gray[y * w + x]);
    }
  }
  for (final x in [0, 1, w - 2, w - 1]) {
    for (var y = 0; y < h; y++) {
      border.add(gray[y * w + x]);
    }
  }
  border.sort();
  int pct(List<int> v, double q) => v[((v.length - 1) * q).round()];
  double near(int t) => border.where((v) => (v - t).abs() <= 16).length / border.length;
  final hi = pct(border, 0.9), lo = pct(border, 0.1);
  int bg;
  var darkBg = false;
  if (near(hi) >= 0.25) {
    bg = hi;
  } else if (near(lo) >= 0.4 && lo < 80) {
    bg = lo;
    darkBg = true;
  } else {
    final all = List<int>.generate((w * h / 7).floor(), (i) => gray[i * 7])..sort();
    bg = pct(all, 0.97);
  }
  const tol = 24;
  final ink = Uint8List(w * h);
  for (var i = 0; i < w * h; i++) {
    final v = gray[i];
    if (darkBg ? v > bg + tol : v < bg - tol) ink[i] = 1;
  }

  // ---- connected blobs (8-neighbourhood), bounding boxes only
  final label = Int32List(w * h);
  final boxes = <_R>[];
  final stack = Int32List(w * h);
  var next = 0;
  for (var start = 0; start < w * h; start++) {
    if (ink[start] == 0 || label[start] != 0) continue;
    next++;
    var sp = 0;
    stack[sp++] = start;
    label[start] = next;
    var x0 = w, y0 = h, x1 = 0, y1 = 0;
    while (sp > 0) {
      final p = stack[--sp];
      final x = p % w, y = p ~/ w;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
      for (var dy = -1; dy <= 1; dy++) {
        final ny = y + dy;
        if (ny < 0 || ny >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx;
          if (nx < 0 || nx >= w) continue;
          final q = ny * w + nx;
          if (ink[q] == 1 && label[q] == 0) {
            label[q] = next;
            stack[sp++] = q;
          }
        }
      }
    }
    boxes.add(_R(x0, y0, x1 + 1, y1 + 1));
  }
  final minArea = w * h * 0.012;
  int area(_R r) => (r.x1 - r.x0) * (r.y1 - r.y0);
  int inter(_R a, _R b) {
    final iw = (a.x1 < b.x1 ? a.x1 : b.x1) - (a.x0 > b.x0 ? a.x0 : b.x0);
    final ih = (a.y1 < b.y1 ? a.y1 : b.y1) - (a.y0 > b.y0 ? a.y0 : b.y0);
    return iw > 0 && ih > 0 ? iw * ih : 0;
  }

  final big = boxes.where((b) => area(b) >= minArea).toList()..sort((a, b) => area(b).compareTo(area(a)));
  final blocks = <_R>[];
  for (final b in big) {
    if (blocks.any((k) => inter(b, k) >= area(b) * 0.6)) continue;
    blocks.add(b);
  }
  if (blocks.isEmpty) return whole;

  // ---- XY-cut inside a block: gutters and border lines
  double density(_R r, int i, bool rows) {
    var n = 0;
    if (rows) {
      final y = r.y0 + i;
      for (var x = r.x0; x < r.x1; x++) {
        n += ink[y * w + x];
      }
      return n / (r.x1 - r.x0);
    }
    final x = r.x0 + i;
    for (var y = r.y0; y < r.y1; y++) {
      n += ink[y * w + x];
    }
    return n / (r.y1 - r.y0);
  }

  _R? trim(_R r) {
    var (x0, y0, x1, y1) = (r.x0, r.y0, r.x1, r.y1);
    bool emptyRow(int y) {
      var n = 0;
      for (var x = x0; x < x1; x++) {
        n += ink[y * w + x];
      }
      return n <= (x1 - x0) * 0.01;
    }

    bool emptyCol(int x) {
      var n = 0;
      for (var y = y0; y < y1; y++) {
        n += ink[y * w + x];
      }
      return n <= (y1 - y0) * 0.01;
    }

    while (y0 < y1 && emptyRow(y0)) {
      y0++;
    }
    while (y1 > y0 && emptyRow(y1 - 1)) {
      y1--;
    }
    while (x0 < x1 && emptyCol(x0)) {
      x0++;
    }
    while (x1 > x0 && emptyCol(x1 - 1)) {
      x1--;
    }
    if (x1 - x0 < 6 || y1 - y0 < 6) return null;
    return _R(x0, y0, x1, y1);
  }

  List<_R> split(_R r, bool rows) {
    final n = rows ? r.y1 - r.y0 : r.x1 - r.x0;
    final d = List<double>.generate(n, (i) => density(r, i, rows));
    final sep = List<bool>.generate(n, (i) => d[i] <= 0.02);
    final line = List<bool>.filled(n, false);
    double mean(int a, int b) {
      a = a.clamp(0, n);
      b = b.clamp(0, n);
      if (b <= a) return 1;
      var s = 0.0;
      for (var i = a; i < b; i++) {
        s += d[i];
      }
      return s / (b - a);
    }

    for (var i = 0; i < n;) {
      if (d[i] < 0.9) {
        i++;
        continue;
      }
      var j = i;
      while (true) {
        while (j < n && d[j] >= 0.9) {
          j++;
        }
        // double border: line, ≤3 px gap, line → one separator
        var k = j;
        while (k < n && k - j < 3 && d[k] < 0.9) {
          k++;
        }
        if (k < n && k > j && d[k] >= 0.9) {
          j = k;
          continue;
        }
        break;
      }
      if (j - i <= 10 && i >= 3 && j + 3 <= n) {
        final before = mean(i - 6, i - 2), after = mean(j + 2, j + 6);
        if (before <= 0.8 && after <= 0.8 && (before < after ? before : after) <= 0.6) {
          for (var k = i; k < j; k++) {
            line[k] = true;
            sep[k] = true;
          }
        }
      }
      i = j;
    }
    final parts = <_R>[];
    var start = 0;
    for (var i = 0; i < n;) {
      if (!sep[i]) {
        i++;
        continue;
      }
      var j = i;
      while (j < n && sep[j]) {
        j++;
      }
      if ((j - i >= 2 || line[i]) && i > start) {
        parts.add(rows ? _R(r.x0, r.y0 + start, r.x1, r.y0 + i) : _R(r.x0 + start, r.y0, r.x0 + i, r.y1));
        start = j;
      }
      i = j;
    }
    if (start < n) parts.add(rows ? _R(r.x0, r.y0 + start, r.x1, r.y1) : _R(r.x0 + start, r.y0, r.x1, r.y1));
    return parts.where((p) => (rows ? p.y1 - p.y0 : p.x1 - p.x0) >= 6).toList();
  }

  void cut(_R region, int depth, List<_R> out) {
    final r = trim(region);
    if (r == null) return;
    if (depth > 6) {
      out.add(r);
      return;
    }
    for (final rows in const [true, false]) {
      var parts = split(r, rows);
      if (parts.length > 1) {
        if (!rows && rtl) parts = parts.reversed.toList(); // manga: right panel first
        for (final p in parts) {
          cut(p, depth + 1, out);
        }
        return;
      }
    }
    out.add(r);
  }

  // ---- reading order of the blocks: bands top→bottom, then by side
  blocks.sort((a, b) => a.y0.compareTo(b.y0));
  final bands = <List<_R>>[];
  for (final b in blocks) {
    final band = bands.isEmpty ? null : bands.last;
    if (band != null) {
      final top = band.map((x) => x.y0).reduce((a, c) => a < c ? a : c);
      final bottom = band.map((x) => x.y1).reduce((a, c) => a > c ? a : c);
      final overlap = (b.y1 < bottom ? b.y1 : bottom) - (b.y0 > top ? b.y0 : top);
      if (overlap >= (b.y1 - b.y0) * 0.5) {
        band.add(b);
        continue;
      }
    }
    bands.add([b]);
  }
  final out = <_R>[];
  for (final band in bands) {
    band.sort((a, b) => rtl ? b.x1.compareTo(a.x1) : a.x0.compareTo(b.x0));
    for (final b in band) {
      cut(b, 0, out);
    }
  }
  final kept = out.where((r) => area(r) >= minArea).toList();
  if (kept.length <= 1) return whole;
  return [for (final r in kept) Rect.fromLTRB(r.x0 / w, r.y0 / h, r.x1 / w, r.y1 / h)];
}

/// Where [panel] (normalised) lands in the viewport when the page is shown with BoxFit.contain.
Rect panelViewportRect(Rect panel, double aspect, Size viewport) {
  final vAspect = viewport.width / viewport.height;
  final Rect img = aspect > vAspect
      ? Rect.fromCenter(center: viewport.center(Offset.zero), width: viewport.width, height: viewport.width / aspect)
      : Rect.fromCenter(center: viewport.center(Offset.zero), width: viewport.height * aspect, height: viewport.height);
  return Rect.fromLTRB(
    img.left + panel.left * img.width,
    img.top + panel.top * img.height,
    img.left + panel.right * img.width,
    img.top + panel.bottom * img.height,
  );
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
    // 600 px: thin gutters between bordered panels survive the downscale (360 lost them)
    final stream = ResizeImage(provider, width: 600, allowUpscaling: false).resolve(ImageConfiguration.empty);
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
  final r = panelViewportRect(panel, aspect, viewport);
  final s = ((1 - margin * 2) * (viewport.width / r.width < viewport.height / r.height ? viewport.width / r.width : viewport.height / r.height))
      .clamp(1.0, maxScale);
  final tx = viewport.width / 2 - s * r.center.dx;
  final ty = viewport.height / 2 - s * r.center.dy;
  return Matrix4.identity()
    ..translateByDouble(tx, ty, 0, 1)
    ..scaleByDouble(s, s, 1, 1);
}
