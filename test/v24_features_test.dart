import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/painting.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/network/network_status.dart';
import 'package:mangaflow/data/models/manga.dart';
import 'package:mangaflow/data/models/settings.dart';
import 'package:mangaflow/data/services/auto_download.dart';
import 'package:mangaflow/data/services/mihon_backup.dart';
import 'package:mangaflow/features/reader/reader_panels.dart';
import 'package:mangaflow/features/social/mihon_import_screen.dart';

/// White page, black panels: 2 rows; the top row has two panels side by side.
Uint8List _page(int w, int h) {
  final g = Uint8List(w * h)..fillRange(0, w * h, 255);
  void box(int x0, int y0, int x1, int y1) {
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        // panel art: mostly dark with some light pixels
        g[y * w + x] = (x + y) % 7 == 0 ? 230 : 20;
      }
    }
  }

  box(10, 10, 95, 140); // top-left
  box(105, 10, 190, 140); // top-right
  box(10, 150, 190, 290); // bottom, full width
  return g;
}

void main() {
  test('panels: gutters split the page; manga order is right-to-left, top-to-bottom', () {
    final p = detectPanels(_page(200, 300), 200, 300, rtl: true);
    expect(p.length, 3);
    expect(p[0].left, greaterThan(0.5), reason: 'right panel first');
    expect(p[1].left, lessThan(0.1));
    expect(p[2].top, greaterThan(0.45));
    final ltr = detectPanels(_page(200, 300), 200, 300, rtl: false);
    expect(ltr[0].left, lessThan(0.1));
    // a page with no gutters is one panel
    final full = Uint8List(100 * 100)..fillRange(0, 10000, 30);
    expect(detectPanels(full, 100, 100), [const Rect.fromLTWH(0, 0, 1, 1)]);
  });

  test('panels: bordered panels with no white gutters, a tall panel across rows, art bleeding over a border', () {
    // like a real manga page: borders 3 px, gaps of 2 px between them (they merge when downscaled)
    const w = 600, h = 880;
    final g = Uint8List(w * h)..fillRange(0, w * h, 245);
    void panel(int x0, int y0, int x1, int y1) {
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          g[y * w + x] = ((x ~/ 7) * 3 + (y ~/ 5) * 5) % 7 < 3 ? 30 : 240;
        }
      }
      for (var x = x0; x < x1; x++) {
        for (var t = 0; t < 3; t++) {
          g[(y0 + t) * w + x] = 10;
          g[(y1 - 1 - t) * w + x] = 10;
        }
      }
      for (var y = y0; y < y1; y++) {
        for (var t = 0; t < 3; t++) {
          g[y * w + x0 + t] = 10;
          g[y * w + x1 - 1 - t] = 10;
        }
      }
    }

    panel(468, 10, 590, 520); // right, tall
    panel(306, 10, 466, 520); // middle, tall
    panel(10, 10, 304, 125); // left column: top
    panel(10, 127, 304, 350); //              middle
    panel(10, 352, 304, 520); //              bottom
    panel(10, 540, 590, 870); // bottom row
    for (var y = 200; y < 215; y++) {
      for (var x = 300; x < 312; x++) {
        g[y * w + x] = 20; // art crossing the left|middle border
      }
    }
    final p = detectPanels(g, w, h, rtl: true);
    expect(p.length, 6);
    expect(p[0].left, greaterThan(0.75), reason: 'right tall panel first');
    expect(p[1].left, inInclusiveRange(0.5, 0.53), reason: 'then the middle one');
    expect([p[2].top, p[3].top, p[4].top], [lessThan(0.02), inInclusiveRange(0.14, 0.16), inInclusiveRange(0.39, 0.41)],
        reason: 'then the left column top to bottom');
    expect(p[5].top, greaterThan(0.6), reason: 'the wide bottom panel last');
    // cream / grey paper is still paper
    final cream = Uint8List.fromList([for (final v in g) v == 245 ? 222 : v]);
    expect(detectPanels(cream, w, h).length, 6);
  });

  test('panels: a bubble over a gutter, touching panels whose shared frame a bubble interrupts', () {
    const w = 600, h = 880;
    final g = Uint8List(w * h)..fillRange(0, w * h, 250);
    void panel(int x0, int y0, int x1, int y1) {
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final frame = y < y0 + 3 || y >= y1 - 3 || x < x0 + 3 || x >= x1 - 3;
          g[y * w + x] = frame ? 10 : (((x ~/ 7) * 3 + (y ~/ 5) * 5) % 7 < 3 ? 30 : 240);
        }
      }
    }

    void bubble(int cx, int cy, int rx, int ry) {
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final e = ((x - cx) / rx) * ((x - cx) / rx) + ((y - cy) / ry) * ((y - cy) / ry);
          if (e <= 1) g[y * w + x] = e >= 0.88 ? 10 : 250;
        }
      }
    }

    panel(10, 10, 295, 300); // top row, a white gutter between and below
    panel(305, 10, 590, 300);
    panel(10, 312, 590, 600); // two panels whose frames touch: one 6-px line
    panel(10, 597, 590, 870);
    bubble(300, 306, 120, 45); // hides 40 % of the gutter under the top row
    bubble(300, 599, 38, 40); // breaks the shared frame line
    final p = detectPanels(g, w, h, rtl: true);
    expect(p.length, 4);
    expect(p[0].left, greaterThan(0.5), reason: 'top-right first');
    expect(p[1].right, lessThan(0.5));
    expect([p[2].top, p[2].bottom], [closeTo(0.355, 0.01), closeTo(0.678, 0.01)]);
    expect([p[3].top, p[3].bottom], [closeTo(0.682, 0.01), closeTo(0.989, 0.01)]);
  });

  test('auto-crop: white margins and a page number go, a full-bleed page stays', () {
    const w = 300, h = 400;
    final g = Uint8List(w * h)..fillRange(0, w * h, 245);
    for (var y = 50; y < 350; y++) {
      for (var x = 60; x < 240; x++) {
        g[y * w + x] = (x + y) % 5 == 0 ? 240 : 25;
      }
    }
    for (var y = 385; y < 391; y++) {
      for (var x = 145; x < 156; x++) {
        g[y * w + x] = 20; // page number
      }
    }
    final b = contentBox(g, w, h)!;
    expect(b.left, closeTo(60 / w - 0.015, 0.01));
    expect(b.right, closeTo(240 / w + 0.015, 0.01));
    expect(b.top, closeTo(50 / h - 0.015, 0.01));
    expect(b.bottom, closeTo(350 / h + 0.015, 0.01), reason: 'the page number is not content');
    final full = Uint8List(w * h);
    for (var i = 0; i < full.length; i++) {
      full[i] = (i * 7919) % 255;
    }
    expect(contentBox(full, w, h), isNull);
  });

  test('panel matrix centres and fits the panel', () {
    final m = panelMatrix(const Rect.fromLTRB(0.5, 0, 1, 0.5), 2 / 3, const Size(400, 600));
    final s = m.getMaxScaleOnAxis();
    expect(s, closeTo(1.84, 0.05)); // panel 200×300 on screen → ×2 minus margin
    final centre = MatrixUtils.transformPoint(m, const Offset(300, 150));
    expect(centre.dx, closeTo(200, 1));
    expect(centre.dy, closeTo(300, 1));
  });

  test('mihon backup: library, categories, read progress, gzip', () {
    PbWriter chapter(String name, double n, {bool read = false}) => PbWriter()
      ..string(1, '/c/$name')
      ..string(2, name)
      ..varint(4, read ? 1 : 0)
      ..float32(9, n);
    final manga = PbWriter()
      ..varint(1, 7000000000000000001)
      ..string(2, '/manga/solo')
      ..string(3, 'Поднятие уровня в одиночку')
      ..string(7, 'Экшен')
      ..message(16, chapter('Глава 1', 1, read: true))
      ..message(16, chapter('Глава 2', 2, read: true))
      ..message(16, chapter('Глава 3', 3))
      ..varint(17, 1)
      ..varint(100, 1);
    final notInLibrary = PbWriter()
      ..varint(1, 5)
      ..string(3, 'История')
      ..varint(100, 0);
    final backup = PbWriter()
      ..message(1, manga)
      ..message(1, notInLibrary)
      ..message(2, PbWriter()
        ..string(1, 'Читаю')
        ..varint(2, 1))
      ..message(101, PbWriter()
        ..string(1, 'MangaLib')
        ..varint(2, 7000000000000000001));
    final b = MihonBackup.parse(Uint8List.fromList(gzip.encode(backup.toBytes())));
    expect(b.library.length, 1);
    final m = b.library.single;
    expect(m.title, 'Поднятие уровня в одиночку');
    expect(m.genres, ['Экшен']);
    expect((m.lastRead, m.readCount), (2.0, 2));
    expect(m.categoryOrders, [1]);
    expect(b.sourceName(m.source), 'MangaLib');
    expect(b.categories.single.name, 'Читаю');
    expect(() => MihonBackup.parse(Uint8List.fromList([1, 2, 3])), throwsFormatException);
  });

  test('mihon sources map to ours by name', () {
    const ours = [
      SourceInfo(id: 'mangalib', name: 'MangaLib', baseUrl: ''),
      SourceInfo(id: 'readmanga', name: 'ReadManga', baseUrl: ''),
      SourceInfo(id: 'mangadex', name: 'MangaDex', baseUrl: ''),
    ];
    expect(mapMihonSource('MangaLib', ours), 'mangalib');
    expect(mapMihonSource('Readmanga (RU)', ours), 'readmanga');
    expect(mapMihonSource('MangaDex', ours), 'mangadex');
    expect(mapMihonSource('Bato.to', ours), isNull);
  });

  test('auto-download picks the next unread chapters, oldest first, skipping downloaded', () {
    final chs = [for (var i = 10; i >= 1; i--) Chapter(id: 'c$i', title: 'Глава $i', number: i.toDouble())];
    final p = AutoDownload.pick(chs, lastRead: 4, have: {'c5'}, limit: 3);
    expect(p.map((c) => c.id), ['c6', 'c7', 'c8']);
    expect(AutoDownload.pick(chs, have: {}, limit: 2).map((c) => c.id), ['c1', 'c2']);
  });

  test('data saver caps page width only on mobile data', () {
    final s = AppSettings(apiBaseUrl: 'x', updatedAt: DateTime(2026));
    expect(effectivePageWidth(s, onMobile: false), isNull);
    expect(effectivePageWidth(s, onMobile: true), 720);
    expect(effectivePageWidth(s.copyWith(mobileDataSaver: false), onMobile: true), isNull);
    expect(effectivePageWidth(s.copyWith(imageQuality: ImageQuality.dataSaver), onMobile: false), 720);
    final round = AppSettings.fromJson(s.copyWith(panelMode: true, autoDownloadNew: true).toJson(), fallbackUrl: 'x');
    expect((round.panelMode, round.autoDownloadNew, round.mobileDataSaver), (true, true, true));
  });
}
