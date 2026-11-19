import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/network/api_client.dart';
import 'package:mangaflow/data/models/library.dart';
import 'package:mangaflow/data/models/settings.dart';
import 'package:mangaflow/data/remote/discover_api.dart';
import 'package:mangaflow/features/security/app_lock.dart';

class _Server implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  Map<String, dynamic> group(String title, {String reason = '', double? similarity}) => {
        'key': 'fake:$title',
        'title': title,
        'cover_url': 'https://api/api/v1/images/x',
        'type': null,
        'reason': reason,
        if (similarity != null) 'similarity': similarity,
        if (similarity != null) 'snippet': 'про $title',
        if (similarity != null) 'genres': ['Экшен'],
        'sources': [
          {'source_id': 'fake', 'id': 'id-$title', 'title': title, 'cover_url': '', 'source_name': 'Fake'},
          {'source_id': 'other', 'id': 'o-$title', 'title': title, 'cover_url': '', 'source_name': 'Other'},
        ],
      };

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    requests.add(o);
    Object payload = {};
    if (o.path.endsWith('/search/plot')) {
      payload = {'items': [group('Паучок', similarity: 87.5)], 'indexed': 321, 'page': 1, 'has_next': false};
    } else if (o.path.endsWith('/similar')) {
      payload = {'items': [group('Слизь', reason: 'Похожий сюжет')]};
    } else if (o.path.endsWith('/discover/for-you')) {
      payload = {
        'sections': [
          {'key': 'for_you', 'title': 'Подобрано для вас', 'items': [group('А', reason: 'Похожий сюжет'), group('Б')]},
          {'key': 'popular', 'title': 'Популярно', 'items': [group('В', reason: 'Читали 3 человек')]},
        ],
      };
    }
    return ResponseBody.fromString(jsonEncode(payload), 200, headers: {'content-type': ['application/json']});
  }

  @override
  void close({bool force = false}) {}
}

LibraryEntry _entry(String title, LibraryStatus status, {bool fav = false}) => LibraryEntry(
      sourceId: 'fake',
      mangaId: 'id-$title',
      title: title,
      status: status,
      isFavorite: fav,
      updatedAt: DateTime.utc(2026),
      addedAt: DateTime.utc(2026),
    );

void main() {
  late _Server server;
  late DiscoverApi api;

  setUp(() {
    server = _Server();
    final client = ApiClient(baseUrl: 'http://x');
    client.dio.httpClientAdapter = server;
    api = DiscoverApi(client);
  });

  test('plot search: cards with sources, snippet and similarity', () async {
    final r = await api.plotSearch('девушка переродилась пауком');
    expect(r.indexed, 321);
    expect(r.items.single.card.title, 'Паучок');
    expect(r.items.single.card.alsoIn.single.sourceId, 'other');
    expect(r.items.single.similarity, 87.5);
    expect(r.items.single.snippet, 'про Паучок');
    expect(server.requests.single.queryParameters['q'], 'девушка переродилась пауком');
  });

  test('«Для вас»: seeds with weights, sections with reasons', () async {
    final seeds = [_entry('X', LibraryStatus.reading, fav: true), _entry('Y', LibraryStatus.completed)];
    final sections = await api.forYou(seeds, ['X', 'Y', 'Z']);
    expect([for (final s in sections) s.key], ['for_you', 'popular']);
    expect(sections.first.items.map((i) => i.card.title), ['А', 'Б']);
    expect(sections.first.items.first.reason, 'Похожий сюжет');
    final sent = server.requests.single.data as Map;
    expect((sent['seeds'] as List).first['weight'], 3.5);
    expect(sent['known'], ['X', 'Y', 'Z']);
    final similar = await api.similar('fake', 'id-X', title: 'X');
    expect(similar.single.card.title, 'Слизь');
    expect(server.requests.last.path, '/manga/fake/id-X/similar');
  });

  test('seed weights: dropped never seeds, favourites weigh more', () {
    expect(DiscoverApi.seedWeight(_entry('a', LibraryStatus.dropped)), 0);
    expect(DiscoverApi.seedWeight(_entry('a', LibraryStatus.planned)), 0.5);
    expect(DiscoverApi.seedWeight(_entry('a', LibraryStatus.planned, fav: true)), 2.0);
    expect(DiscoverApi.seedWeight(_entry('a', LibraryStatus.completed)), 2.5);
  });

  test('PIN: salted hash, length remembered, wrong PIN rejected, clear removes it', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final pins = PinStore();
    expect(await pins.hasPin(), isFalse);
    await pins.setPin('20481');
    expect(await pins.hasPin(), isTrue);
    expect(await pins.length(), 5);
    expect(await pins.check('20481'), isTrue);
    expect(await pins.check('2048'), isFalse);
    expect(await pins.check('00000'), isFalse);
    await pins.clear();
    expect(await pins.hasPin(), isFalse);
    expect(await pins.check('20481'), isFalse);
  });

  test('privacy settings are device-only: kept locally, never synced, survive a remote merge', () {
    final s = AppSettings(apiBaseUrl: 'http://x', updatedAt: DateTime.utc(2026))
        .copyWith(incognito: true, appLock: true, lockTimeoutSec: 300, hideInRecents: true, lockBiometrics: false);
    final back = AppSettings.fromJson(s.toJson(), fallbackUrl: 'http://x');
    expect([back.incognito, back.appLock, back.hideInRecents, back.lockBiometrics], [true, true, true, false]);
    expect(back.lockTimeoutSec, 300);
    expect(s.toSyncJson().keys.where((k) => k.contains('lock') || k.contains('incognito') || k.contains('recents')), isEmpty);
    final merged = s.mergeRemote({'show_nsfw': true}, DateTime.utc(2027));
    expect(merged.incognito && merged.appLock, isTrue);
    expect(merged.showNsfw, isTrue);
  });
}
