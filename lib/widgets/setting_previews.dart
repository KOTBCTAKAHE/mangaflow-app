import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/models/library.dart';

/// Little animated phones next to reader settings: what a reading mode, «по кадрам»,
/// cropping or tap zones look like before you switch them on. Drawn, not recorded —
/// they follow the theme colours and cost nothing to ship.
enum PreviewKind { mode, panels, crop, tapZones, merge, autoHide }

class SettingPreview extends StatefulWidget {
  const SettingPreview({
    super.key,
    required this.kind,
    this.mode = ReadingMode.pagedRtl,
    this.enabled = true,
    this.width = 50,
    this.height = 80,
  });

  final PreviewKind kind;

  /// For [PreviewKind.mode].
  final ReadingMode mode;

  /// Off: a still picture of how it is without the setting.
  final bool enabled;
  final double width;
  final double height;

  @override
  State<SettingPreview> createState() => _SettingPreviewState();
}

class _SettingPreviewState extends State<SettingPreview> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: _duration);

  Duration get _duration => switch (widget.kind) {
        PreviewKind.mode => widget.mode == ReadingMode.vertical ? const Duration(seconds: 4) : const Duration(milliseconds: 6600),
        PreviewKind.panels => const Duration(milliseconds: 7200),
        PreviewKind.crop => const Duration(milliseconds: 4200),
        PreviewKind.tapZones => const Duration(milliseconds: 4500),
        PreviewKind.merge => const Duration(milliseconds: 4000),
        PreviewKind.autoHide => const Duration(milliseconds: 4000),
      };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SettingPreview old) {
    super.didUpdateWidget(old);
    if (old.kind != widget.kind || old.mode != widget.mode) _c.duration = _duration;
    _sync();
  }

  void _sync() {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still || !widget.enabled) {
      _c.stop();
      _c.value = widget.kind == PreviewKind.panels ? 0.1 : 0.0;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: CustomPaint(
            painter: _PreviewPainter(
              t: _c,
              kind: widget.kind,
              mode: widget.mode,
              enabled: widget.enabled,
              accent: scheme.primary,
              frame: scheme.outline,
              screen: Color.alphaBlend(Colors.black.withValues(alpha: 0.55), scheme.surfaceContainerHighest),
              text: scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ drawing

const _paper = Color(0xFFF3F0EA);
const _ink = Color(0xFF2A2A30);
const _tone = Color(0xFFB9B5AE);

/// Panel layouts of a page (left, top, right, bottom inside the page's margins).
const _layouts = <List<List<double>>>[
  [
    [0, 0, 1, .3],
    [.52, .33, 1, .64],
    [0, .33, .48, .64],
    [0, .67, 1, 1],
  ],
  [
    [.5, 0, 1, .45],
    [0, 0, .47, .45],
    [0, .48, 1, .72],
    [0, .75, 1, 1],
  ],
  [
    [0, 0, 1, .42],
    [.36, .45, 1, 1],
    [0, .45, .33, 1],
  ],
];

double _ease(double x) => Curves.easeInOutCubic.transform(x.clamp(0.0, 1.0));

class _PreviewPainter extends CustomPainter {
  _PreviewPainter({
    required this.t,
    required this.kind,
    required this.mode,
    required this.enabled,
    required this.accent,
    required this.frame,
    required this.screen,
    required this.text,
  }) : super(repaint: t);

  final Animation<double> t;
  final PreviewKind kind;
  final ReadingMode mode;
  final bool enabled;
  final Color accent, frame, screen, text;

  @override
  void paint(Canvas canvas, Size size) {
    final landscape = kind == PreviewKind.mode && mode == ReadingMode.doublePage;
    var phone = Offset.zero & size;
    if (landscape) {
      final h = math.min(size.height, size.width * 0.62);
      phone = Rect.fromCenter(center: size.center(Offset.zero), width: size.width, height: h);
    }
    final r = phone.shortestSide * 0.14;
    final body = RRect.fromRectAndRadius(phone.deflate(0.75), Radius.circular(r));
    canvas.drawRRect(body, Paint()..color = screen);
    final scr = phone.deflate(phone.shortestSide * 0.07);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(scr, Radius.circular(r * 0.6)));
    switch (kind) {
      case PreviewKind.mode:
        _mode(canvas, scr);
      case PreviewKind.panels:
        _panels(canvas, scr);
      case PreviewKind.crop:
        _crop(canvas, scr);
      case PreviewKind.tapZones:
        _tapZones(canvas, scr);
      case PreviewKind.merge:
        _merge(canvas, scr);
      case PreviewKind.autoHide:
        _autoHide(canvas, scr);
    }
    canvas.restore();
    canvas.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = frame,
    );
  }

  /// A manga page in [r]: paper, framed panels with a head, a few lines and a bubble.
  void _page(Canvas canvas, Rect r, int variant, {double margin = 0.06, bool number = false}) {
    canvas.drawRect(r, Paint()..color = _paper);
    final inner = Rect.fromLTRB(r.left + r.width * margin, r.top + r.height * margin * 0.8,
        r.right - r.width * margin, r.bottom - r.height * margin * (number ? 1.6 : 0.8));
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.6, r.width * 0.012)
      ..color = _ink;
    final layout = _layouts[variant % _layouts.length];
    for (var i = 0; i < layout.length; i++) {
      final p = _panelRect(inner, layout[i]);
      _panel(canvas, p, i + variant, stroke);
    }
    if (number) {
      final w = r.width * 0.08;
      canvas.drawRect(Rect.fromCenter(center: Offset(r.center.dx, r.bottom - r.height * margin * 0.8), width: w, height: w * 0.5),
          Paint()..color = _tone);
    }
  }

  Rect _panelRect(Rect inner, List<double> p) =>
      Rect.fromLTRB(inner.left + inner.width * p[0], inner.top + inner.height * p[1], inner.left + inner.width * p[2],
          inner.top + inner.height * p[3]);

  void _panel(Canvas canvas, Rect p, int seed, Paint stroke) {
    final fill = Paint()..color = seed.isEven ? const Color(0xFFE4E0D8) : const Color(0xFFEDEAE3);
    canvas.drawRect(p, fill);
    final s = p.shortestSide;
    // a character: head and shoulders
    final hx = p.left + p.width * (seed % 3 == 0 ? 0.32 : 0.66);
    final head = Offset(hx, p.top + p.height * 0.48);
    canvas.drawCircle(head, s * 0.16, Paint()..color = _ink);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: head + Offset(0, s * 0.38), width: s * 0.55, height: s * 0.4),
        Radius.circular(s * 0.2),
      ),
      Paint()..color = _ink.withValues(alpha: 0.85),
    );
    // speed lines / background strokes
    final lines = Paint()
      ..color = _tone
      ..strokeWidth = math.max(0.4, s * 0.025);
    for (var k = 0; k < 3; k++) {
      final y = p.top + p.height * (0.18 + k * 0.12);
      final x0 = p.left + p.width * (seed % 3 == 0 ? 0.6 : 0.08);
      canvas.drawLine(Offset(x0, y), Offset(x0 + p.width * 0.28, y), lines);
    }
    // speech bubble
    final b = Rect.fromCenter(
      center: Offset(p.left + p.width * (seed % 3 == 0 ? 0.72 : 0.28), p.top + p.height * 0.26),
      width: s * 0.5,
      height: s * 0.32,
    );
    canvas.drawOval(b, Paint()..color = Colors.white);
    canvas.drawOval(b, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke.strokeWidth * 0.7
      ..color = _ink);
    canvas.drawRect(p, stroke);
  }

  // ------------------------------------------------------------ reading modes
  void _mode(Canvas canvas, Rect s) {
    final v = t.value;
    switch (mode) {
      case ReadingMode.vertical:
        // a webtoon strip scrolling up, page after page without gaps between turns
        final w = s.width, h = w * 1.45, gap = w * 0.04;
        final stride = h + gap;
        final off = v * stride * 3; // three pages per loop: the fourth is the first again
        for (var k = 0; k < 6; k++) {
          final top = s.top + k * stride - off;
          if (top > s.bottom || top + h < s.top) continue;
          _page(canvas, Rect.fromLTWH(s.left, top, w, h), k % 3, margin: 0.03);
        }
        _arrow(canvas, Offset(s.right - s.width * 0.14, s.center.dy), up: true, alpha: 0.9);
      case ReadingMode.pagedLtr:
      case ReadingMode.pagedRtl:
        _turn(canvas, s, rtl: mode == ReadingMode.pagedRtl, pair: false);
      case ReadingMode.doublePage:
        _turn(canvas, s, rtl: true, pair: true);
    }
  }

  /// Three page turns per loop: hold, tap at the edge, slide.
  void _turn(Canvas canvas, Rect s, {required bool rtl, required bool pair}) {
    final seg = (t.value * 3).floor().clamp(0, 2);
    final local = t.value * 3 - seg;
    final slide = _ease((local - 0.55) / 0.35);
    final dir = rtl ? 1.0 : -1.0; // where the old page goes
    void pageAt(int variant, double dx) {
      final r = s.shift(Offset(dx * s.width, 0));
      if (pair) {
        final half = r.width / 2;
        final pageH = math.min(r.height, half * 1.42);
        final top = r.center.dy - pageH / 2;
        final pw = pageH / 1.42;
        _page(canvas, Rect.fromLTWH(r.center.dx - pw, top, pw, pageH), variant + 1);
        _page(canvas, Rect.fromLTWH(r.center.dx, top, pw, pageH), variant);
      } else {
        final ph = math.min(r.height, r.width * 1.42);
        final pw = ph / 1.42;
        _page(canvas, Rect.fromCenter(center: r.center, width: pw, height: ph), variant);
      }
    }

    pageAt(seg, dir * slide);
    pageAt(seg + 1, dir * (slide - 1));
    // the tap that turns the page: on the side you read towards
    if (local > 0.32 && local < 0.62) {
      final p = _ease((local - 0.32) / 0.3);
      final at = Offset(rtl ? s.left + s.width * 0.16 : s.right - s.width * 0.16, s.center.dy + s.height * 0.12);
      _tap(canvas, at, p, s.shortestSide);
    }
  }

  // ------------------------------------------------------------ «по кадрам»
  void _panels(Canvas canvas, Rect s) {
    final ph = math.min(s.height, s.width * 1.42);
    final page = Rect.fromCenter(center: s.center, width: ph / 1.42, height: ph);
    final inner = Rect.fromLTRB(page.left + page.width * 0.06, page.top + page.height * 0.048,
        page.right - page.width * 0.06, page.bottom - page.height * 0.048);
    final order = [for (final p in _layouts[0]) _panelRect(inner, p)];
    // 0: whole page, then panel 1..4 in manga order (top, right, left, bottom)
    final stops = [page, ...order];
    Rect cam;
    if (!enabled) {
      cam = page;
    } else {
      final n = stops.length;
      final x = t.value * n;
      final i = x.floor() % n;
      final local = x - x.floor();
      cam = Rect.lerp(stops[i], stops[(i + 1) % n], _ease((local - 0.6) / 0.4))!;
    }
    final scale = math.min(s.width / cam.width, s.height / cam.height) * 0.94;
    canvas.save();
    canvas.translate(s.center.dx, s.center.dy);
    canvas.scale(scale);
    canvas.translate(-cam.center.dx, -cam.center.dy);
    _page(canvas, page, 0);
    canvas.restore();
    if (enabled) {
      // the rest of the page fades away: only the panel being read stays
      final shown = Rect.fromCenter(center: s.center, width: cam.width * scale, height: cam.height * scale);
      final zoomed = (cam.width - page.width).abs() > 1;
      if (zoomed) {
        canvas.drawPath(
          Path()
            ..fillType = PathFillType.evenOdd
            ..addRect(s)
            ..addRect(shown.inflate(1)),
          Paint()..color = screen.withValues(alpha: 0.88),
        );
      }
    }
  }

  // ------------------------------------------------------------ cropping
  void _crop(Canvas canvas, Rect s) {
    final ph = math.min(s.height, s.width * 1.42);
    final page = Rect.fromCenter(center: s.center, width: ph / 1.42, height: ph);
    const m = 0.17;
    final content = Rect.fromLTRB(page.left + page.width * m, page.top + page.height * m * 0.75,
        page.right - page.width * m, page.bottom - page.height * m * 0.95);
    var k = 0.0;
    if (enabled) {
      final v = t.value;
      k = v < 0.3 ? 0 : (v < 0.55 ? _ease((v - 0.3) / 0.25) : (v < 0.85 ? 1 : 1 - _ease((v - 0.85) / 0.15)));
    }
    final target = Rect.fromCenter(
      center: s.center,
      width: math.min(s.width, s.height * content.width / content.height),
      height: math.min(s.height, s.width * content.height / content.width),
    );
    final scale = 1 + (target.width / content.width - 1) * k;
    canvas.save();
    canvas.translate(s.center.dx, s.center.dy);
    canvas.scale(scale);
    canvas.translate(-Offset.lerp(page.center, content.center, k)!.dx, -Offset.lerp(page.center, content.center, k)!.dy);
    canvas.drawRect(page, Paint()..color = _paper);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.6, page.width * 0.012)
      ..color = _ink;
    for (var i = 0; i < _layouts[1].length; i++) {
      _panel(canvas, _panelRect(content, _layouts[1][i]), i + 1, stroke);
    }
    // page number in the margin
    canvas.drawRect(
        Rect.fromCenter(center: Offset(page.center.dx, page.bottom - page.height * 0.06), width: page.width * 0.08, height: page.width * 0.04),
        Paint()..color = _tone);
    canvas.restore();
    if (enabled && t.value > 0.12 && t.value < 0.32) {
      // the cut line appears before the page grows
      final a = _ease((t.value - 0.12) / 0.12);
      final r = Rect.fromCenter(center: s.center, width: content.width, height: content.height)
          .shift(content.center - page.center);
      _dashed(canvas, r, accent.withValues(alpha: a));
    }
  }

  // ------------------------------------------------------------ tap zones
  void _tapZones(Canvas canvas, Rect s) {
    final ph = math.min(s.height, s.width * 1.42);
    _page(canvas, Rect.fromCenter(center: s.center, width: ph / 1.42, height: ph), 2);
    canvas.drawRect(s, Paint()..color = screen.withValues(alpha: 0.45));
    final zones = enabled
        ? [Rect.fromLTRB(s.left, s.top, s.left + s.width * 0.3, s.bottom), Rect.fromLTRB(s.left + s.width * 0.3, s.top, s.right - s.width * 0.3, s.bottom), Rect.fromLTRB(s.right - s.width * 0.3, s.top, s.right, s.bottom)]
        : [s];
    final active = enabled ? (t.value * 3).floor().clamp(0, 2) : 0;
    for (var i = 0; i < zones.length; i++) {
      final on = i == active;
      canvas.drawRect(zones[i].deflate(0.5), Paint()..color = accent.withValues(alpha: on ? 0.32 : 0.12));
      final label = zones.length == 1 ? '☰' : const ['‹', '☰', '›'][i];
      _label(canvas, label, zones[i].center, s.width * (label == '☰' ? 0.16 : 0.26), Colors.white.withValues(alpha: on ? 1 : 0.7));
    }
    if (enabled) {
      final local = t.value * 3 - active;
      _tap(canvas, zones[active].center + Offset(0, s.height * 0.18), _ease(local / 0.5), s.shortestSide);
    }
  }

  // ------------------------------------------------------------ one title, every source
  void _merge(Canvas canvas, Rect s) {
    canvas.drawRect(s, Paint()..color = screen);
    final rowH = s.height / 7;
    final k = enabled ? (t.value < 0.15 ? _ease(t.value / 0.15) : (t.value > 0.85 ? 1 - _ease((t.value - 0.85) / 0.15) : 1.0)) : 0.0;
    var y = s.top + rowH * 0.5;
    for (var i = 0; i < 6; i++) {
      final foreign = i == 0 || i == 3;
      final h = foreign ? rowH * k : rowH;
      if (h > 0.5) {
        final row = Rect.fromLTWH(s.left + s.width * 0.08, y + h * 0.15, s.width * 0.84, h * 0.7);
        final dx = foreign ? (1 - k) * s.width : 0.0;
        final r = row.shift(Offset(dx, 0));
        canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(r.height / 2)),
            Paint()..color = foreign ? accent.withValues(alpha: 0.3) : text.withValues(alpha: 0.16));
        canvas.drawCircle(Offset(r.left + r.height * 0.55, r.center.dy), r.height * 0.22,
            Paint()..color = foreign ? accent : text.withValues(alpha: 0.5));
      }
      y += h;
    }
  }

  // ------------------------------------------------------------ controls hide by themselves
  void _autoHide(Canvas canvas, Rect s) {
    final ph = math.min(s.height, s.width * 1.42);
    _page(canvas, Rect.fromCenter(center: s.center, width: ph / 1.42, height: ph), 1);
    final v = t.value;
    final shown = v < 0.45 ? 1.0 : (v < 0.6 ? 1 - _ease((v - 0.45) / 0.15) : 0.0);
    if (shown > 0) {
      final bar = Paint()..color = screen.withValues(alpha: 0.92 * shown);
      canvas.drawRect(Rect.fromLTWH(s.left, s.top, s.width, s.height * 0.14), bar);
      canvas.drawRect(Rect.fromLTWH(s.left, s.bottom - s.height * 0.16, s.width, s.height * 0.16), bar);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(s.left + s.width * 0.12, s.bottom - s.height * 0.09, s.width * 0.76, s.height * 0.025),
            const Radius.circular(4)),
        Paint()..color = accent.withValues(alpha: shown),
      );
    }
  }

  // ------------------------------------------------------------ bits
  void _tap(Canvas canvas, Offset at, double p, double unit) {
    canvas.drawCircle(at, unit * (0.08 + 0.16 * p), Paint()..color = accent.withValues(alpha: 0.45 * (1 - p)));
    canvas.drawCircle(at, unit * 0.07, Paint()..color = accent.withValues(alpha: 1 - p * 0.6));
  }

  void _arrow(Canvas canvas, Offset at, {required bool up, double alpha = 1}) {
    const w = 4.0;
    final p = Path()
      ..moveTo(at.dx - w, at.dy + (up ? w * 0.6 : -w * 0.6))
      ..lineTo(at.dx, at.dy + (up ? -w * 0.6 : w * 0.6))
      ..lineTo(at.dx + w, at.dy + (up ? w * 0.6 : -w * 0.6));
    canvas.drawPath(p, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = accent.withValues(alpha: alpha));
  }

  void _dashed(Canvas canvas, Rect r, Color c) {
    final paint = Paint()
      ..color = c
      ..strokeWidth = 1.2;
    const dash = 3.0, gap = 2.0;
    void line(Offset a, Offset b) {
      final len = (b - a).distance;
      final dir = (b - a) / len;
      for (var d = 0.0; d < len; d += dash + gap) {
        canvas.drawLine(a + dir * d, a + dir * math.min(len, d + dash), paint);
      }
    }

    line(r.topLeft, r.topRight);
    line(r.topRight, r.bottomRight);
    line(r.bottomRight, r.bottomLeft);
    line(r.bottomLeft, r.topLeft);
  }

  void _label(Canvas canvas, String s, Offset at, double size, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontWeight: FontWeight.w700, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_PreviewPainter old) =>
      old.kind != kind || old.mode != mode || old.enabled != enabled || old.accent != accent || old.screen != screen;
}

/// A switch row with a live preview on the left: tap anywhere to toggle.
class PreviewSwitchTile extends StatelessWidget {
  const PreviewSwitchTile({
    super.key,
    required this.preview,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final Widget preview;
  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
        child: Row(children: [
          preview,
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DefaultTextStyle.merge(style: theme.listTileTheme.titleTextStyle ?? theme.textTheme.titleMedium, child: title),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                DefaultTextStyle.merge(style: theme.listTileTheme.subtitleTextStyle ?? theme.textTheme.bodySmall, child: subtitle!),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          Switch(value: value, onChanged: onChanged),
        ]),
      ),
    );
  }
}

/// «Режим по умолчанию»: a row of animated phones — Авто, лента, страницы, разворот.
class ReadingModePicker extends StatelessWidget {
  const ReadingModePicker({super.key, required this.selected, required this.onSelect, this.withAuto = true});

  /// null = «Авто».
  final ReadingMode? selected;
  final ValueChanged<ReadingMode?> onSelect;
  final bool withAuto;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget card(ReadingMode? m, Widget art, String label) {
      final on = m == selected;
      return Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Material(
          color: on ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: on ? scheme.primary : Colors.transparent, width: 2),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => onSelect(m),
            child: SizedBox(
              width: 86,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                child: Column(children: [
                  SizedBox(height: 92, child: Center(child: art)),
                  const SizedBox(height: 6),
                  Text(label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: on ? scheme.onSecondaryContainer : scheme.onSurface,
                            fontWeight: on ? FontWeight.w700 : null,
                          )),
                ]),
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 150,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          if (withAuto)
            card(
              null,
              Icon(Icons.auto_awesome_rounded, size: 34, color: selected == null ? scheme.primary : scheme.onSurfaceVariant),
              'Авто\nпо формату',
            ),
          for (final m in ReadingMode.values)
            card(
              m,
              SettingPreview(kind: PreviewKind.mode, mode: m, width: m == ReadingMode.doublePage ? 78 : 56, height: 90),
              modeShortLabel(m),
            ),
        ],
      ),
    );
  }
}

String modeShortLabel(ReadingMode m) => switch (m) {
      ReadingMode.vertical => 'Лента',
      ReadingMode.pagedLtr => 'Слева\nнаправо',
      ReadingMode.pagedRtl => 'Справа\nналево',
      ReadingMode.doublePage => 'Разворот',
    };
