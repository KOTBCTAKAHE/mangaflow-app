import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/network/api_exception.dart';
import 'package:mangaflow/core/storage/database.dart';
import 'package:mangaflow/data/models/manga.dart';
import 'package:mangaflow/data/services/downloads/download_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A valid-looking PNG of [n] bytes.
Uint8List png(int n, {int seed = 0}) {
  final b = Uint8List(n);
  const magic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < n; i++) {
    b[i] = i < 8 ? magic[i] : (i * 31 + seed) & 0xFF;
  }
  return b;
}

typedef Handler = ResponseBody Function(RequestOptions o);

/// Scriptable HTTP adapter: each URL gets a queue of handlers; the last one repeats.
class FakeAdapter implements HttpClientAdapter {
  final Map<String, List<Handler>> routes = {};
  final List<RequestOptions> requests = [];

  void on(String url, List<Handler> handlers) => routes[url] = handlers;

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancelFuture) async {
    requests.add(o);
    final list = routes[o.uri.toString()];
    if (list == null) return ResponseBody.fromString('nope', 404);
    final h = list.length > 1 ? list.removeAt(0) : list.first;
    return h(o);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody ok(Uint8List bytes) => ResponseBody.fromBytes(bytes, 200, headers: {
      'content-type': ['image/png'],
      'content-length': ['${bytes.length}'],
    });

ResponseBody networkDown(RequestOptions o) => throw const SocketException('Network is unreachable');

class FakeNet implements NetworkProbe {
  final List<NetState> script = [];
  NetState fallback = NetState.unmetered;
  int checks = 0;

  @override
  Future<NetState> check() async {
    checks++;
    return script.isNotEmpty ? script.removeAt(0) : fallback;
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late Directory tmp;
  late FakeAdapter http;
  late FakeNet net;
  late DateTime clock;
  late List<Duration> sleeps;
  late int pageListCalls;
  late Future<List<PageRef>> Function(String, String, int?) pagesImpl;

  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    tmp = await Directory.systemTemp.createTemp('mf-dl-');
    http = FakeAdapter();
    net = FakeNet();
    clock = DateTime.utc(2026, 1, 1, 22);
    sleeps = [];
    pageListCalls = 0;
    pagesImpl = (s, c, w) async => [for (var i = 0; i < 3; i++) PageRef(index: i, url: 'http://img/$c/$i')];
    await db.db.insert('downloads', {
      'source_id': 's', 'manga_id': 'm', 'chapter_id': 'c1', 'manga_title': 'Тайтл', 'chapter_title': 'Глава 1',
      'status': 'queued', 'dir': '${tmp.path}/c1', 'created_at': 1, 'updated_at': 1,
    });
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<bool> Function()? reachable;

  DownloadEngine engine({String owner = 'test'}) => DownloadEngine(
        reachable: reachable,
        db: db.db,
        owner: owner,
        http: Dio()..httpClientAdapter = http,
        net: net,
        settings: () => const EngineSettings(),
        now: () => clock,
        sleep: (d) async {
          sleeps.add(d);
          clock = clock.add(d);
        },
        pagesFor: (s, c, w) {
          pageListCalls++;
          return pagesImpl(s, c, w);
        },
      );

  Future<Map<String, Object?>> row() async => (await db.db.query('downloads')).first;

  List<String> files() => Directory('${tmp.path}/c1').listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

  test('flaky network: page retries until the chapter completes', () async {
    http.on('http://img/c1/0', [(_) => ok(png(500))]);
    http.on('http://img/c1/1', [networkDown, networkDown, (_) => ok(png(500, seed: 1))]);
    http.on('http://img/c1/2', [(_) => ok(png(500, seed: 2))]);

    expect(await engine().run(), RunResult.idle);
    final r = await row();
    expect(r['status'], 'completed');
    expect(r['pages_done'], 3);
    expect(files(), ['0000.png', '0001.png', '0002.png']);
  });

  test('resumes a partially downloaded page with an HTTP Range request', () async {
    final full = png(1000, seed: 7);
    Directory('${tmp.path}/c1').createSync(recursive: true);
    File('${tmp.path}/c1/0001.part').writeAsBytesSync(full.sublist(0, 400));
    http.on('http://img/c1/0', [(_) => ok(png(300))]);
    http.on('http://img/c1/2', [(_) => ok(png(300))]);
    http.on('http://img/c1/1', [
      (o) {
        expect(o.headers['Range'], 'bytes=400-');
        final rest = full.sublist(400);
        return ResponseBody.fromBytes(rest, 206, headers: {
          'content-type': ['image/png'],
          'content-length': ['${rest.length}'],
          'content-range': ['bytes 400-999/1000'],
        });
      }
    ]);

    await engine().run();
    expect((await row())['status'], 'completed');
    expect(File('${tmp.path}/c1/0001.png').readAsBytesSync(), full);
  });

  test('waits for the network instead of failing while offline', () async {
    net.script.addAll([NetState.none, NetState.none, NetState.none]);
    for (var i = 0; i < 3; i++) {
      http.on('http://img/c1/$i', [(_) => ok(png(200, seed: i))]);
    }
    await engine().run();
    final r = await row();
    expect(r['status'], 'completed');
    expect(r['attempts'], 0); // offline time never counts as a failure
    expect(sleeps, contains(const Duration(seconds: 15)));
  });

  test('source temporarily down → backoff retry, then success', () async {
    var failures = 2;
    pagesImpl = (s, c, w) async {
      if (failures-- > 0) throw const ApiException('source_unavailable', 'down');
      return [for (var i = 0; i < 3; i++) PageRef(index: i, url: 'http://img/$c/$i')];
    };
    for (var i = 0; i < 3; i++) {
      http.on('http://img/c1/$i', [(_) => ok(png(200, seed: i))]);
    }
    final start = clock;
    expect(await engine().run(), RunResult.idle);
    expect((await row())['status'], 'completed');
    expect(pageListCalls, 3);
    // 1 min + 2 min of backoff were waited (in fake time)
    expect(clock.difference(start), greaterThanOrEqualTo(const Duration(minutes: 3)));
  });

  test('one failing chapter does not block the rest of the queue', () async {
    await db.db.insert('downloads', {
      'source_id': 's', 'manga_id': 'm', 'chapter_id': 'c2', 'manga_title': 'Тайтл', 'chapter_title': 'Глава 2',
      'status': 'queued', 'dir': '${tmp.path}/c2', 'created_at': 2, 'updated_at': 2,
    });
    pagesImpl = (s, c, w) async {
      if (c == 'c1') throw const ApiException('timeout', 'timeout');
      return [PageRef(index: 0, url: 'http://img/$c/0')];
    };
    http.on('http://img/c2/0', [(_) => ok(png(200))]);
    await engine().run(budget: const Duration(seconds: 30));
    final rows = {for (final r in await db.db.query('downloads')) r['chapter_id']: r};
    expect(rows['c2']!['status'], 'completed', reason: '${rows['c2']}');
    expect(rows['c1']!['status'], 'retrying');
    expect(rows['c1']!['attempts'], 1);
  });

  test('permanent errors give up after a few attempts', () async {
    pagesImpl = (s, c, w) async => throw const ApiException('source_auth_required', 'paid', status: 403);
    expect(await engine().run(), RunResult.idle);
    final r = await row();
    expect(r['status'], 'failed');
    expect(r['attempts'], DownloadEngine.maxPermanentAttempts);
  });

  test('expired signed page URLs are refreshed transparently', () async {
    var generation = 0;
    pagesImpl = (s, c, w) async {
      generation++;
      return [for (var i = 0; i < 3; i++) PageRef(index: i, url: 'http://img/$c/$i?g=$generation')];
    };
    for (var i = 0; i < 3; i++) {
      http.on('http://img/c1/$i?g=1', [
        (_) => ResponseBody.fromString(jsonEncode({'error': {'code': 'image_token_invalid'}}), 404),
      ]);
      http.on('http://img/c1/$i?g=2', [(_) => ok(png(200, seed: i))]);
    }
    await engine().run();
    expect((await row())['status'], 'completed');
    expect(pageListCalls, 2);
  });

  test('corrupted responses are not saved as pages', () async {
    http.on('http://img/c1/0', [
      (_) => ResponseBody.fromString('<html>captcha</html>${' ' * 100}', 200, headers: {'content-type': ['text/html']}),
      (_) => ok(png(300)),
    ]);
    http.on('http://img/c1/1', [(_) => ok(png(300, seed: 1))]);
    http.on('http://img/c1/2', [(_) => ok(png(300, seed: 2))]);
    await engine().run();
    expect((await row())['status'], 'completed');
    expect(files().where((f) => f.endsWith('.part')), isEmpty);
    expect(File('${tmp.path}/c1/0000.png').readAsBytesSync().sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  });

  test('only one runner works at a time (lease)', () async {
    await db.db.insert('kv', {'key': DownloadEngine.leaseKey, 'value': 'service|${clock.add(const Duration(minutes: 1)).millisecondsSinceEpoch}'});
    expect(await engine(owner: 'workmanager').run(), RunResult.leaseBusy);
    expect((await row())['status'], 'queued');
  });

  test('a dead runner leaves "downloading" rows that the next run resumes', () async {
    await db.db.update('downloads', {'status': 'downloading'});
    for (var i = 0; i < 3; i++) {
      http.on('http://img/c1/$i', [(_) => ok(png(200, seed: i))]);
    }
    await engine().run();
    expect((await row())['status'], 'completed');
  });

  test('screen-off blackout: "connected" but server unreachable → waits without burning attempts', () async {
    var blackout = 5; // probe fails 5 times (~100 s of fake time), then the network is back
    reachable = () async => blackout-- <= 0;
    http.on('http://img/c1/0', [networkDown, networkDown, (_) => ok(png(200))]);
    http.on('http://img/c1/1', [(_) => ok(png(200, seed: 1))]);
    http.on('http://img/c1/2', [(_) => ok(png(200, seed: 2))]);
    await engine().run();
    final r = await row();
    expect(r['status'], 'completed');
    expect(r['attempts'], 0);
    expect(sleeps.where((d) => d == const Duration(seconds: 20)), isNotEmpty);
    reachable = null;
  });

  test('page list fails while server unreachable → requeued without penalty', () async {
    var down = 3;
    reachable = () async => down <= 0;
    pagesImpl = (s, c, w) async {
      if (down-- > 0) throw const ApiException('offline', 'offline');
      return [PageRef(index: 0, url: 'http://img/$c/0')];
    };
    http.on('http://img/c1/0', [(_) => ok(png(200))]);
    await engine().run();
    final r = await row();
    expect(r['status'], 'completed');
    expect(r['attempts'], 0);
    reachable = null;
  });

  test('chapter backoff schedule', () {
    expect(DownloadEngine.chapterBackoff(1), const Duration(minutes: 1));
    expect(DownloadEngine.chapterBackoff(3), const Duration(minutes: 4));
    expect(DownloadEngine.chapterBackoff(10), const Duration(minutes: 30));
  });
}
