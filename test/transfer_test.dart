import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/storage/database.dart';
import 'package:mangaflow/data/local/daos.dart';
import 'package:mangaflow/data/models/manga.dart';
import 'package:mangaflow/data/services/download_manager.dart';
import 'package:mangaflow/data/services/transfer/chapter_transfer.dart';
import 'package:mangaflow/data/services/transfer/zip.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A CBZ made by another program (Python zipfile, deflate) with nested folders.
const foreignCbz = 'UEsDBBQAAAAIABBMc10Znqx/WAAAAGYAAAANAAAAQ29taWNJbmZvLnhtbLOxr8jNUShLLSrOzM+zVTLUM1Cyt7Nxzs/NTPbMS8u3swlOLcpMLba7MPfCvovtF/Ze2Hdhp8KFLRf2Xdh+Yd/FBht9qLyNX2luUmqRnbGNPpRlo48wBQBQSwMEFAAAAAgAEExzXUf3cG5FAAAARQAAABgAAABWb2wgMS9DaGFwdGVyIDEwLzAwMS5wbmfrDPBz5+WS4mJgYOD19HAJYmBgYARhDiYGBoYJ5cH3GBgYeDxdHEMq5iQ/ePSIiYHBgUE+rvGHEAMDA4Onq5/LOqeEJgBQSwMEFAAAAAgAEExzXWMdYptFAAAARQAAABcAAABWb2wgMS9DaGFwdGVyIDIvMDAyLnBuZ+sM8HPn5ZLiYmBg4PX0cAliYGBgBGEOJgYGhgnlwfcYGBh4PF0cQyrmJAsICzMzMHQwOPM3iW9mYGBg8HT1c1nnlNAEAFBLAwQUAAAACAAQTHNdvp8eA0UAAABFAAAAFwAAAFZvbCAxL0NoYXB0ZXIgMi8wMDEucG5n6wzwc+flkuJiYGDg9fRwCWJgYGAEYQ4mBgaGCeXB9xgYGHg8XRxDKuYkC4iKsjIwNDE4vPglU8/AwMDg6ernss4poQkAUEsDBBQAAAAIABBMc11RzrIKCAAAAPQBAAAZAAAAVm9sIDEvQ2hhcHRlciAyL25vdGVzLnR4dKuoGAUjDQAAUEsDBBQAAAAIABBMc13Va8BJRQAAAEUAAAAYAAAAX19NQUNPU1gvVm9sIDEvLl8wMDEucG5n6wzwc+flkuJiYGDg9fRwCWJgYGAEYQ4mBgaGCeXB9xgYGHg8XRxDKuYkJ6SksDAwcDGwpJd36jMwMDB4uvq5rHNKaAIAUEsBAhQDFAAAAAgAEExzXRmerH9YAAAAZgAAAA0AAAAAAAAAAAAAAIABAAAAAENvbWljSW5mby54bWxQSwECFAMUAAAACAAQTHNdR/dwbkUAAABFAAAAGAAAAAAAAAAAAAAAgAGDAAAAVm9sIDEvQ2hhcHRlciAxMC8wMDEucG5nUEsBAhQDFAAAAAgAEExzXWMdYptFAAAARQAAABcAAAAAAAAAAAAAAIAB/gAAAFZvbCAxL0NoYXB0ZXIgMi8wMDIucG5nUEsBAhQDFAAAAAgAEExzXb6fHgNFAAAARQAAABcAAAAAAAAAAAAAAIABeAEAAFZvbCAxL0NoYXB0ZXIgMi8wMDEucG5nUEsBAhQDFAAAAAgAEExzXVHOsgoIAAAA9AEAABkAAAAAAAAAAAAAAIAB8gEAAFZvbCAxL0NoYXB0ZXIgMi9ub3Rlcy50eHRQSwECFAMUAAAACAAQTHNd1WvASUUAAABFAAAAGAAAAAAAAAAAAAAAgAExAgAAX19NQUNPU1gvVm9sIDEvLl8wMDEucG5nUEsFBgAAAAAGAAYAmAEAAKwCAAAAAA==';

class Phone {
  Phone(this.root, this.db);
  final Directory root;
  final AppDatabase db;
  late final transfer = ChapterTransfer(db: db.db, rootDir: () async => root, titleCache: TitleCacheDao(db.db));

  static Future<Phone> create(Directory tmp, String name) async {
    final root = Directory(p.join(tmp.path, name))..createSync();
    return Phone(root, await AppDatabase.open(path: p.join(root.path, 'app.db'), factory: databaseFactoryFfi));
  }

  Future<List<Map<String, Object?>>> downloads() => db.db.query('downloads', orderBy: 'chapter_number');
}

void main() {
  late Directory tmp;
  setUpAll(sqfliteFfiInit);
  setUp(() async => tmp = await Directory.systemTemp.createTemp('transfer'));
  tearDown(() => tmp.delete(recursive: true));

  test('zip writer output is a valid archive the reader (and unzip) understand', () async {
    final path = p.join(tmp.path, 'a.zip');
    final src = File(p.join(tmp.path, 'big.bin'))..writeAsBytesSync(List.generate(200000, (i) => i * 7 % 251));
    final w = await ZipWriter.create(path);
    await w.addBytes('Ёжик/текст.txt', utf8.encode('привет'));
    await w.addFile('c000/0000.jpg', src);
    await w.close();
    final r = await ZipReader.open(path);
    expect(r.entries.map((e) => e.name), ['Ёжик/текст.txt', 'c000/0000.jpg']);
    expect(utf8.decode(await r.read(r.entries.first)), 'привет');
    expect(await r.read(r.entries.last), src.readAsBytesSync());
    await r.close();
    expect(crc32Update(0, utf8.encode('123456789')), 0xCBF43926);
    final unzip = await Process.run('which', ['unzip']);
    if (unzip.exitCode == 0) {
      final t = await Process.run('unzip', ['-t', path]);
      expect(t.exitCode, 0, reason: '${t.stdout}${t.stderr}');
    }
  });

  test('send → receive: chapters land under the same title, AI pages included, opens offline', () async {
    final a = await Phone.create(tmp, 'a');
    final b = await Phone.create(tmp, 'b');
    const manga = MangaDetails(sourceId: 'mangalib', sourceName: 'MangaLib', id: 'm1', title: 'Берсерк', coverUrl: 'https://x/c.jpg');
    final tasks = <DownloadTask>[];
    for (final (id, n, pages) in [('ch2', 2.0, 2), ('ch1', 1.0, 3)]) {
      final dir = Directory(downloadDirFor(a.root.path, 'mangalib', id))..createSync(recursive: true);
      for (var i = 0; i < pages; i++) {
        File(p.join(dir.path, '${i.toString().padLeft(4, '0')}.webp')).writeAsBytesSync([n.toInt(), i]);
      }
      tasks.add(DownloadTask(
          sourceId: 'mangalib', mangaId: 'm1', chapterId: id, mangaTitle: 'Берсерк', chapterTitle: 'Глава ${n.toInt()}',
          chapterNumber: n, status: DownloadStatus.completed, dir: dir.path, sizeBytes: pages * 2));
    }
    // an AI-enhanced copy of ch1 page 0
    final hd = File(p.join(tasks[1].dir, 'hd_balanced', '0000.jpg'))..createSync(recursive: true);
    hd.writeAsBytesSync([9, 9, 9]);
    expect(ChapterTransfer.hdCount(tasks), 1);

    final progress = <double>[];
    final out = await a.transfer.exportPack(
      manga: manga,
      chapters: [for (final t in tasks) ExportChapter(t)],
      outDir: Directory(p.join(tmp.path, 'out')),
      cover: [1, 2, 3],
      onProgress: progress.add,
    );
    expect(p.extension(out.file.path), '.cbz');
    expect(out.file.path, contains('Берсерк'));
    expect((out.chapters, out.pages, out.hdPages), (2, 5, 1));
    expect(progress.last, 1);

    final pv = await b.transfer.inspect(out.file.path);
    expect(pv.isMangaFlowPack, isTrue);
    expect(pv.title, 'Берсерк');
    expect(pv.chapters, ['Глава 1', 'Глава 2']);
    expect((pv.pages, pv.alreadyHave), (5, 0));
    expect(pv.cover, [1, 2, 3]);

    final r = await b.transfer.importPack(out.file.path);
    expect((r.sourceId, r.mangaId, r.added, r.skipped, r.firstChapterId), ('mangalib', 'm1', 2, 0, 'ch1'));
    final rows = await b.downloads();
    expect(rows.map((x) => x['chapter_id']), ['ch1', 'ch2']);
    expect(rows.every((x) => x['status'] == 'completed'), isTrue);
    expect(rows.first['cover_url'], startsWith('file:'));
    final ch1 = Directory(rows.first['dir']! as String);
    final files = ch1.listSync().whereType<File>().toList()..sort((x, y) => x.path.compareTo(y.path));
    expect(files.map((f) => p.basename(f.path)), ['0000.jpg', '0001.webp', '0002.webp']);
    expect(files.first.readAsBytesSync(), [9, 9, 9], reason: 'the AI page replaces the original');
    final cached = await TitleCacheDao(b.db.db).get('mangalib', 'm1');
    expect(cached!.$1.chapters.map((c) => c.id), ['ch2', 'ch1']);
    expect(cached.$1.manga.title, 'Берсерк');

    // receiving the same file again changes nothing
    final again = await b.transfer.importPack(out.file.path);
    expect((again.added, again.skipped), (0, 2));
    expect((await b.transfer.inspect(out.file.path)).alreadyHave, 2);
  });

  test('a CBZ from another app becomes a local title, one chapter per folder', () async {
    final b = await Phone.create(tmp, 'b');
    final f = File(p.join(tmp.path, '1700_night.cbz'))..writeAsBytesSync(base64Decode(foreignCbz));
    final pv = await b.transfer.inspect(f.path);
    expect(pv.isMangaFlowPack, isFalse);
    expect(pv.title, 'Ночной дозор');
    expect(pv.chapters, ['Chapter 2', 'Chapter 10']);
    expect(pv.pages, 3);
    final r = await b.transfer.importPack(f.path);
    expect(r.sourceId, localSourceId);
    expect(r.added, 2);
    final rows = await b.downloads();
    expect(rows.map((x) => x['chapter_number']), [2.0, 10.0]);
    final dir = Directory(rows.first['dir']! as String);
    final pages = dir.listSync().whereType<File>().map((f) => p.basename(f.path)).toList()..sort();
    expect(pages, ['0000.png', '0001.png']);
    expect(await TitleCacheDao(b.db.db).get(localSourceId, r.mangaId), isNotNull);
  });

  test('garbage is rejected with a readable reason', () async {
    final b = await Phone.create(tmp, 'b');
    final f = File(p.join(tmp.path, 'x.cbz'))..writeAsStringSync('not a zip at all, just text');
    expect(() => b.transfer.inspect(f.path), throwsA(isA<ZipFormatException>()));
  });

  test('natural order and safe names', () {
    final l = ['p10', 'p2', 'p1']..sort(naturalCompare);
    expect(l, ['p1', 'p2', 'p10']);
    expect(safeFileName('a/b:c?'), 'a b c');
  });
}
