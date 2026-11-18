import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/storage/database.dart';
import 'package:mangaflow/data/models/settings.dart';
import 'package:mangaflow/data/services/downloads/download_upscale.dart';
import 'package:mangaflow/data/services/upscale_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class Fake implements UpscaleBackend {
  final runs = <String>[];
  String Function(String input) status = (_) => 'ok';
  @override
  Future<UpscaleOutcome> run({required String id, required String input, required String output, required UpscaleQuality quality, required int maxSourceWidth, int maxOutPixels = 24000000}) async {
    runs.add(input.split('/').last);
    final st = status(input);
    if (st == 'ok') await File(output).writeAsBytes([1]);
    return UpscaleOutcome(st, message: st == 'skipped' ? 'large_enough' : null);
  }

  @override
  Future<void> cancel(String id) async {}
  @override
  Future<void> release() async {}
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late SharedPreferences prefs;
  var settings = AppSettings(apiBaseUrl: 'x', updatedAt: DateTime.utc(2026));

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dl');
    db = await AppDatabase.open(path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    settings = AppSettings(apiBaseUrl: 'x', updatedAt: DateTime.utc(2026));
    for (final (ch, status, n) in [('c1', 'done', 3), ('c2', 'done', 2), ('c3', 'queued', 2)]) {
      final dir = Directory('${tmp.path}/$ch')..createSync();
      for (var i = 0; i < n; i++) {
        File('${dir.path}/${i.toString().padLeft(4, '0')}.webp').writeAsBytesSync([0]);
      }
      await db.db.insert('downloads', {
        'source_id': 's', 'manga_id': 'm', 'chapter_id': ch, 'manga_title': 'M', 'chapter_title': ch,
        'status': status, 'dir': dir.path, 'created_at': ch.codeUnitAt(1), 'updated_at': 0,
      });
    }
  });
  tearDown(() async {
    await db.db.close();
    await tmp.delete(recursive: true);
  });

  test('enhances every page of downloaded chapters, next to the pages, oldest first', () async {
    final fake = Fake();
    final progress = <String>[];
    final up = DownloadUpscaler(db: db.db, settings: () => settings, prefs: prefs, backend: fake,
        onProgress: (p) => progress.add('${p.chapterTitle}:${p.page}/${p.pages}'));
    await up.run();
    expect(fake.runs, ['0000.webp', '0001.webp', '0002.webp', '0000.webp', '0001.webp']);
    expect(File('${tmp.path}/c1/hd_fast/0001.jpg').existsSync(), isTrue);
    expect(progress.first, 'c1:1/3');
    expect(up.processed, 5);
    // second night: nothing left to do
    await up.run();
    expect(fake.runs.length, 5);
    expect(await up.pendingChapters(), isEmpty);
  });

  test('skipped pages are remembered; the reader treats them as skipped too', () async {
    final fake = Fake()..status = (p) => p.endsWith('0000.webp') ? 'skipped' : 'ok';
    await DownloadUpscaler(db: db.db, settings: () => settings, prefs: prefs, backend: fake).run();
    expect(File(localHdPath('${tmp.path}/c1/0000.webp', UpscaleQuality.fast, skipMarker: true)).existsSync(), isTrue);
    final again = Fake();
    await DownloadUpscaler(db: db.db, settings: () => settings, prefs: prefs, backend: again).run();
    expect(again.runs, isEmpty);
  });

  test('yields to new downloads and respects the switch', () async {
    final fake = Fake();
    var calls = 0;
    await DownloadUpscaler(db: db.db, settings: () => settings, prefs: prefs, backend: fake, shouldYield: () async => ++calls > 1).run();
    expect(fake.runs.length, 1);
    settings = settings.copyWith(upscaleDownloads: false);
    final off = Fake();
    await DownloadUpscaler(db: db.db, settings: () => settings, prefs: prefs, backend: off).run();
    expect(off.runs, isEmpty);
  });

  test('hd path sits next to the page', () {
    expect(localHdPath('/d/ch/0003.webp', UpscaleQuality.max), '/d/ch/hd_max/0003.jpg');
    expect(localHdPath('/d/ch/0003.webp', UpscaleQuality.fast, skipMarker: true), '/d/ch/hd_fast/0003.skip');
  });
}
