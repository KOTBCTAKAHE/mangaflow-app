import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// «По кадрам»: finds comic panels on a page (ink blobs + XY-cut along page-paper gutters and
/// frame lines over a 600-px grayscale copy) so the reader can go panel to panel.
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

/// Pure detector (tested): [gray] is w×h luminance, row-major (the app passes a 600-px-wide copy).
///
/// 1. Paper tone from the page edges (white, cream, grey scans; black pages too) → ink mask.
/// 2. **Page paper**: white 4-connected to the image edge — margins and gutters, never a
///    panel's own sky — plus long thin straight white strips (a gutter that bubbles close off).
/// 3. Connected blobs of ink → blocks; overlapping blocks are united.
/// 4. Recursive XY-cut inside each block. A row/column is a separator when it is mostly page
///    paper (a bubble may sit on part of it), or when it is a frame line between touching
///    panels: a dense run, or a ruled line across the block that a bubble interrupts.
///    Every piece of a cut must hold a picture, so the cut never slices a panel's empty sky.
/// 5. Nothing may be skipped: ink that no panel covers becomes a panel, or joins the panel
///    next to it (a caption beside a frame); a box inside another box is dropped.
/// 6. Reading order, recursively: rows top→bottom, inside a row columns right→left (manga)
///    or left→right; a two-page spread reads one page, then the other.
///
/// Mirrors the reference implementation the thresholds were tuned with (synthetic pages with
/// ground truth built from real manga art: bubbles over gutters, touching frames, bleeds).
List<Rect> detectPanels(Uint8List gray, int w, int h, {bool rtl = true}) {
  const whole = [Rect.fromLTWH(0, 0, 1, 1)];
  if (w < 16 || h < 16 || gray.length < w * h || h > w * 3) return whole;
  final n = w * h;

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
    final all = List<int>.generate((n / 7).ceil(), (i) => gray[i * 7])..sort();
    bg = pct(all, 0.97);
  }
  const tol = 24;
  final ink = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final v = gray[i];
    if (darkBg ? v > bg + tol : v < bg - tol) ink[i] = 1;
  }

  // ---- connected components (one label array: paper and ink pixels never share an id)
  final label = Int32List(n);
  final stack = Int32List(n);
  _Comp flood(Uint8List mask, int want, int start, int id, bool eight) {
    var sp = 0;
    stack[sp++] = start;
    label[start] = id;
    var x0 = w, y0 = h, x1 = -1, y1 = -1, count = 0;
    var edge = false;
    void visit(int q) {
      if (mask[q] == want && label[q] == 0) {
        label[q] = id;
        stack[sp++] = q;
      }
    }

    while (sp > 0) {
      final p = stack[--sp];
      final x = p % w, y = p ~/ w;
      count++;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
      if (x == 0 || y == 0 || x == w - 1 || y == h - 1) edge = true;
      if (x > 0) visit(p - 1);
      if (x < w - 1) visit(p + 1);
      if (y > 0) visit(p - w);
      if (y < h - 1) visit(p + w);
      if (eight) {
        if (y > 0 && x > 0) visit(p - w - 1);
        if (y > 0 && x < w - 1) visit(p - w + 1);
        if (y < h - 1 && x > 0) visit(p + w - 1);
        if (y < h - 1 && x < w - 1) visit(p + w + 1);
      }
    }
    return _Comp(_R(x0, y0, x1 + 1, y1 + 1), count, edge);
  }

  // page paper: white reaching the image edge (4-connected: a thin frame stops it) and long thin
  // straight white strips — a gutter that bubbles close off at both ends is still a gutter
  final paperComps = <_Comp>[];
  for (var i = 0; i < n; i++) {
    if (ink[i] == 0 && label[i] == 0) paperComps.add(flood(ink, 0, i, paperComps.length + 1, false));
  }
  final thin = math.max(3, (w * 0.035).floor());
  bool strip(_Comp c) {
    final bw = c.box.x1 - c.box.x0, bh = c.box.y1 - c.box.y0;
    final short = math.min(bw, bh), long = math.max(bw, bh);
    return short <= thin && long >= short * 6 && long >= w * 0.08 && c.count / (bw * bh) >= 0.6;
  }

  final isPage = [for (final c in paperComps) c.edge || strip(c)];
  final page = Uint8List(n);
  for (var i = 0; i < n; i++) {
    if (ink[i] == 0 && isPage[label[i] - 1]) page[i] = 1;
  }

  // ruled strokes: pixels in straight runs of ink at least 4 % of the width long (frames, not art)
  final bar = math.max(15, (w * 0.04).floor());
  final hl = Uint8List(n), vl = Uint8List(n);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w;) {
      if (ink[y * w + x] == 0) {
        x++;
        continue;
      }
      var e = x;
      while (e < w && ink[y * w + e] == 1) {
        e++;
      }
      if (e - x >= bar) hl.fillRange(y * w + x, y * w + e, 1);
      x = e;
    }
  }
  for (var x = 0; x < w; x++) {
    for (var y = 0; y < h;) {
      if (ink[y * w + x] == 0) {
        y++;
        continue;
      }
      var e = y;
      while (e < h && ink[e * w + x] == 1) {
        e++;
      }
      if (e - y >= bar) {
        for (var k = y; k < e; k++) {
          vl[k * w + x] = 1;
        }
      }
      y = e;
    }
  }

  // blobs of ink (8-neighbourhood)
  final inkBoxes = <_R>[];
  final firstInk = paperComps.length + 1;
  for (var i = 0; i < n; i++) {
    if (ink[i] == 1 && label[i] == 0) inkBoxes.add(flood(ink, 1, i, firstInk + inkBoxes.length, true).box);
  }

  // integral images: any rectangle's count in O(1)
  final sw = w + 1;
  Int32List integral(Uint8List m) {
    final s = Int32List(sw * (h + 1));
    for (var y = 0; y < h; y++) {
      var row = 0;
      for (var x = 0; x < w; x++) {
        row += m[y * w + x];
        s[(y + 1) * sw + x + 1] = s[y * sw + x + 1] + row;
      }
    }
    return s;
  }

  final inkS = integral(ink), pageS = integral(page), hlS = integral(hl), vlS = integral(vl);
  int sumOf(Int32List s, int x0, int y0, int x1, int y1) => s[y1 * sw + x1] - s[y0 * sw + x1] - s[y1 * sw + x0] + s[y0 * sw + x0];
  int area(_R r) => (r.x1 - r.x0) * (r.y1 - r.y0);
  double inkMean(_R r) => sumOf(inkS, r.x0, r.y0, r.x1, r.y1) / area(r);
  final minArea = n * 0.012;

  // ---- blocks: big blobs; overlapping ones (pieces of one picture, panels glued by a bubble) unite
  final blocks = _byAreaDesc(inkBoxes.where((b) => area(b) >= minArea).toList());
  for (var changed = true; changed;) {
    changed = false;
    outer:
    for (var i = 0; i < blocks.length; i++) {
      for (var j = i + 1; j < blocks.length; j++) {
        final a = blocks[i], b = blocks[j];
        if (_inter(a, b) >= math.min(area(a), area(b)) * 0.1) {
          blocks[i] = _union(a, b);
          blocks.removeAt(j);
          changed = true;
          break outer;
        }
      }
    }
  }
  if (blocks.isEmpty) return whole;

  // ---- XY-cut
  _R? trim(_R r) {
    // drop only page paper around the picture (gutters, margins): a panel's own sky stays
    final rw = r.x1 - r.x0, rh = r.y1 - r.y0;
    int? fy, ly, fx, lx;
    for (var y = r.y0; y < r.y1; y++) {
      if ((rw - sumOf(pageS, r.x0, y, r.x1, y + 1)) / rw > 0.02) {
        fy ??= y;
        ly = y;
      }
    }
    for (var x = r.x0; x < r.x1; x++) {
      if ((rh - sumOf(pageS, x, r.y0, x + 1, r.y1)) / rh > 0.02) {
        fx ??= x;
        lx = x;
      }
    }
    if (fy == null || fx == null) return null;
    final t = _R(fx, fy, lx! + 1, ly! + 1);
    if (t.x1 - t.x0 < 6 || t.y1 - t.y0 < 6) return null;
    return t;
  }

  /// Runs of v ≥ hi, bridging dips up to [gap] long (a double frame line is one separator).
  List<(int, int)> runs(Float64List v, double hi, int gap) {
    final m = v.length;
    final out = <(int, int)>[];
    for (var i = 0; i < m;) {
      if (v[i] < hi) {
        i++;
        continue;
      }
      var j = i;
      while (true) {
        while (j < m && v[j] >= hi) {
          j++;
        }
        var k = j;
        while (k < m && k - j < gap && v[k] < hi) {
          k++;
        }
        if (k < m && k > j && v[k] >= hi) {
          j = k;
          continue;
        }
        break;
      }
      out.add((i, j));
      i = j;
    }
    return out;
  }

  List<_R> split(_R r, bool rows) {
    final len = rows ? r.y1 - r.y0 : r.x1 - r.x0;
    final span = rows ? r.x1 - r.x0 : r.y1 - r.y0;
    double frac(Int32List s, int i) =>
        (rows ? sumOf(s, r.x0, r.y0 + i, r.x1, r.y0 + i + 1) : sumOf(s, r.x0 + i, r.y0, r.x0 + i + 1, r.y1)) / span;
    final d = Float64List(len), o = Float64List(len), cl = Float64List(len);
    for (var i = 0; i < len; i++) {
      d[i] = frac(inkS, i);
      o[i] = frac(pageS, i);
      cl[i] = frac(rows ? hlS : vlS, i);
    }
    // a gutter is page paper across the block; a bubble on it hides part of it but adds little ink
    final sep = List<bool>.generate(len, (i) => o[i] >= 0.75 || (o[i] >= 0.5 && d[i] <= 0.08));
    final line = List<bool>.filled(len, false);
    double mean(Float64List v, int a, int b) {
      a = a.clamp(0, len);
      b = b.clamp(0, len);
      if (b <= a) return 1;
      var s = 0.0;
      for (var i = a; i < b; i++) {
        s += v[i];
      }
      return s / (b - a);
    }

    void mark(int i, int j) {
      for (var k = i; k < j; k++) {
        line[k] = true;
        sep[k] = true;
      }
    }

    // a frame line between touching panels: a dense thin run, lighter on both sides
    for (final run in runs(d, 0.9, 3)) {
      final i = run.$1, j = run.$2;
      if (j - i <= 10 && i >= 3 && j + 3 <= len) {
        final before = mean(d, i - 6, i - 2), after = mean(d, j + 2, j + 6);
        final dense = mean(d, i, j);
        if (math.max(before, after) <= math.min(0.8, dense - 0.08) && math.min(before, after) <= 0.6) mark(i, j);
      }
    }
    // a ruled line right across the block that a bubble interrupts
    for (final run in runs(cl, 0.85, 4)) {
      final i = run.$1, j = run.$2;
      if (j - i <= 12 && i >= 4 && j + 4 <= len && mean(cl, i - 8, i - 2) <= 0.15 && mean(cl, j + 2, j + 8) <= 0.15) {
        mark(i, j);
      }
    }
    final parts = <_R>[];
    var start = 0;
    for (var i = 0; i < len;) {
      if (!sep[i]) {
        i++;
        continue;
      }
      var j = i;
      while (j < len && sep[j]) {
        j++;
      }
      if ((j - i >= 2 || line[i]) && i > start) {
        parts.add(rows ? _R(r.x0, r.y0 + start, r.x1, r.y0 + i) : _R(r.x0 + start, r.y0, r.x0 + i, r.y1));
        start = j;
      }
      i = j;
    }
    if (start < len) parts.add(rows ? _R(r.x0, r.y0 + start, r.x1, r.y1) : _R(r.x0 + start, r.y0, r.x1, r.y1));
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
      final parts = split(r, rows);
      // every piece must hold a picture: an empty slice means the cut went through a panel's sky
      if (parts.length > 1 && parts.any((p) => inkMean(p) < 0.08)) continue;
      if (parts.length > 1) {
        for (final p in parts) {
          cut(p, depth + 1, out);
        }
        return;
      }
    }
    out.add(r);
  }

  final cuts = <_R>[];
  for (final b in blocks) {
    cut(b, 0, cuts);
  }
  // specks and slivers (page numbers, a column of text outside the panels)
  var kept = cuts
      .where((r) =>
          area(r) >= minArea && !(math.min((r.x1 - r.x0) / w, (r.y1 - r.y0) / h) < 0.07 && area(r) < n * 0.04))
      .toList();

  // ---- nothing on the page may be skipped
  if (kept.isNotEmpty) {
    final covered = Uint8List(n);
    for (final r in kept) {
      final x0 = math.max(0, r.x0 - 4), x1 = math.min(w, r.x1 + 4);
      for (var y = math.max(0, r.y0 - 4); y < math.min(h, r.y1 + 4); y++) {
        covered.fillRange(y * w + x0, y * w + x1, 1);
      }
    }
    // uncovered ink grown by 6 px (city-block), so the words of a caption hold together
    const far = 1 << 20;
    final dist = Int32List(n);
    for (var i = 0; i < n; i++) {
      dist[i] = ink[i] == 1 && covered[i] == 0 ? 0 : far;
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        var v = dist[i];
        if (y > 0 && dist[i - w] + 1 < v) v = dist[i - w] + 1;
        if (x > 0 && dist[i - 1] + 1 < v) v = dist[i - 1] + 1;
        dist[i] = v;
      }
    }
    for (var y = h - 1; y >= 0; y--) {
      for (var x = w - 1; x >= 0; x--) {
        final i = y * w + x;
        var v = dist[i];
        if (y < h - 1 && dist[i + w] + 1 < v) v = dist[i + w] + 1;
        if (x < w - 1 && dist[i + 1] + 1 < v) v = dist[i + 1] + 1;
        dist[i] = v;
      }
    }
    final rest = Uint8List(n);
    for (var i = 0; i < n; i++) {
      if (dist[i] <= 6 && covered[i] == 0) rest[i] = 1;
    }
    label.fillRange(0, n, 0);
    var id = 0;
    for (var i = 0; i < n; i++) {
      if (rest[i] == 0 || label[i] != 0) continue;
      final r = flood(rest, 1, i, ++id, false).box;
      final inkN = sumOf(inkS, r.x0, r.y0, r.x1, r.y1);
      if (area(r) >= minArea * 1.5 && inkN / area(r) >= 0.05 && math.min((r.x1 - r.x0) / w, (r.y1 - r.y0) / h) >= 0.07) {
        kept.add(r);
      } else if (inkN >= n * 0.001) {
        // a caption or a few words next to a panel: read them with that panel
        int gapTo(_R k) => [k.x0 - r.x1, r.x0 - k.x1, k.y0 - r.y1, r.y0 - k.y1, 0].reduce(math.max);
        var best = 0;
        for (var k = 1; k < kept.length; k++) {
          if (gapTo(kept[k]) < gapTo(kept[best])) best = k;
        }
        if (gapTo(kept[best]) <= w * 0.06) {
          final u = _union(kept[best], r);
          var clear = true;
          for (var k = 0; k < kept.length; k++) {
            if (k != best && _inter(u, kept[k]) > area(kept[k]) * 0.1) clear = false;
          }
          if (clear) kept[best] = u;
        }
      }
    }
  }
  // a box inside another box is the same picture twice
  final uniq = <_R>[];
  for (final r in _byAreaDesc(kept)) {
    if (!uniq.any((k) => _inter(r, k) >= area(r) * 0.85)) uniq.add(r);
  }
  kept = uniq;
  if (kept.length <= 1) return whole;

  List<_R> ordered;
  if (w > h * 1.15) {
    // a two-page spread in one image: one page, then the other
    final right = kept.where((r) => (r.x0 + r.x1) / 2 >= w / 2).toList();
    final left = kept.where((r) => (r.x0 + r.x1) / 2 < w / 2).toList();
    ordered = rtl ? [..._order(right, rtl), ..._order(left, rtl)] : [..._order(left, rtl), ..._order(right, rtl)];
  } else {
    ordered = _order(kept, rtl);
  }
  return [for (final r in ordered) Rect.fromLTRB(r.x0 / w, r.y0 / h, r.x1 / w, r.y1 / h)];
}

int _inter(_R a, _R b) {
  final iw = math.min<int>(a.x1, b.x1) - math.max<int>(a.x0, b.x0);
  final ih = math.min<int>(a.y1, b.y1) - math.max<int>(a.y0, b.y0);
  return iw > 0 && ih > 0 ? iw * ih : 0;
}

_R _union(_R a, _R b) => _R(math.min(a.x0, b.x0), math.min(a.y0, b.y0), math.max(a.x1, b.x1), math.max(a.y1, b.y1));

/// Stable sort, biggest first.
List<_R> _byAreaDesc(List<_R> rs) => _stableSort(rs, (a, b) => b.area.compareTo(a.area));

List<T> _stableSort<T>(List<T> items, int Function(T a, T b) cmp) {
  final idx = List<int>.generate(items.length, (i) => i)
    ..sort((a, b) {
      final c = cmp(items[a], items[b]);
      return c != 0 ? c : a.compareTo(b);
    });
  return [for (final i in idx) items[i]];
}

/// Splits rects into runs along one axis wherever there is a gap (overlaps of up to 15 % of
/// the smaller size still count as a gap: a bubble poking into the next row).
List<List<_R>> _groups(List<_R> rects, bool vertical) {
  int lo(_R r) => vertical ? r.y0 : r.x0;
  int hi(_R r) => vertical ? r.y1 : r.x1;
  final groups = <List<_R>>[];
  var cur = <_R>[];
  var end = 0, curMin = 0;
  for (final r in _stableSort(rects, (a, b) => lo(a).compareTo(lo(b)))) {
    final size = hi(r) - lo(r);
    if (cur.isNotEmpty && lo(r) < end - 0.15 * math.min(size, curMin)) {
      cur.add(r);
      end = math.max(end, hi(r));
      curMin = math.min(curMin, size);
    } else {
      if (cur.isNotEmpty) groups.add(cur);
      cur = [r];
      end = hi(r);
      curMin = size;
    }
  }
  if (cur.isNotEmpty) groups.add(cur);
  return groups;
}

/// Reading order, recursively: rows top→bottom; inside a row, columns by side; inside a column,
/// rows again… (a tall panel beside a stack of small ones reads before or after the whole stack).
List<_R> _order(List<_R> rects, bool rtl, [int depth = 0]) {
  if (rects.length <= 1 || depth > 8) return List.of(rects);
  final rows = _groups(rects, true);
  if (rows.length > 1) return [for (final g in rows) ..._order(g, rtl, depth + 1)];
  var cols = _groups(rects, false);
  if (cols.length > 1) {
    if (rtl) cols = cols.reversed.toList();
    return [for (final g in cols) ..._order(g, rtl, depth + 1)];
  }
  // tangled (overlapping boxes): rough rows by top edge, then by side
  final top = rects.map((r) => r.y0).reduce(math.min), bottom = rects.map((r) => r.y1).reduce(math.max);
  final band = math.max(1.0, (bottom - top) * 0.12);
  return _stableSort(rects, (a, b) {
    final c = (a.y0 / band).floor().compareTo((b.y0 / band).floor());
    if (c != 0) return c;
    return rtl ? b.x1.compareTo(a.x1) : a.x0.compareTo(b.x0);
  });
}

class _Comp {
  const _Comp(this.box, this.count, this.edge);
  final _R box;
  final int count;
  final bool edge;
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

  int get area => (x1 - x0) * (y1 - y0);
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
