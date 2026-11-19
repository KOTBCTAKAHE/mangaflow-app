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
