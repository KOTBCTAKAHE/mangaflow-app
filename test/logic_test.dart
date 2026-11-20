import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/config.dart';
import 'package:mangaflow/core/network/api_exception.dart';
import 'package:mangaflow/core/network/proxy.dart';
import 'package:mangaflow/core/utils/format.dart';
import 'package:mangaflow/data/models/library.dart';
import 'package:mangaflow/data/models/manga.dart';
import 'package:mangaflow/data/models/reading.dart';
import 'package:mangaflow/data/models/settings.dart';
import 'package:mangaflow/data/remote/catalog_api.dart';
import 'package:mangaflow/data/repositories/reading_repository.dart';
import 'package:mangaflow/features/reader/reader_views.dart';

HistoryItem h(String chapter, DateTime at, {int seconds = 60, String manga = 'm1'}) => HistoryItem(
      id: '$manga-$chapter-${at.millisecondsSinceEpoch}',
      sourceId: 's',
      mangaId: manga,
      chapterId: chapter,
      startedAt: at,
      readAt: at,
      durationSeconds: seconds,
    );

void main() {
  group('computeStats', () {
    final now = DateTime(2026, 5, 10, 12);

    test('aggregates time, chapters, titles and streaks', () {
      final items = [
        h('c1', DateTime(2026, 5, 10, 9), seconds: 300),
        h('c2', DateTime(2026, 5, 9, 9), seconds: 120),
        h('c2', DateTime(2026, 5, 9, 10), seconds: 30), // same chapter twice in a day
        h('c3', DateTime(2026, 5, 8, 9), manga: 'm2'),
        h('c4', DateTime(2026, 5, 1, 9)),
      ];
      final s = computeStats(items, completedChapters: 2, byStatus: {'reading': 2, 'planned': 1}, now: now);
      expect(s.totalSeconds, 300 + 120 + 30 + 60 + 60);
      expect(s.titlesRead, 2);
      expect(s.chaptersRead, 4); // distinct chapters (> completed count)
      expect(s.currentStreak, 3);
      expect(s.longestStreak, 3);
      expect(s.libraryTotal, 3);
      expect(s.activity.length, 4);
    });

    test('streak survives until the day ends', () {
      final s = computeStats([h('c1', DateTime(2026, 5, 9, 22))],
          completedChapters: 0, byStatus: const {}, now: now);
      expect(s.currentStreak, 1);
      final broken = computeStats([h('c1', DateTime(2026, 5, 7))], completedChapters: 0, byStatus: const {}, now: now);
      expect(broken.currentStreak, 0);
    });
  });

  group('reader tap zones', () {
    const size = Size(300, 600);
    test('LTR', () {
      expect(tapZone(const Offset(10, 300), size, rtl: false), -1);
      expect(tapZone(const Offset(290, 300), size, rtl: false), 1);
      expect(tapZone(const Offset(150, 300), size, rtl: false), 0);
    });
    test('RTL mirrors the edges', () {
      expect(tapZone(const Offset(10, 300), size, rtl: true), 1);
      expect(tapZone(const Offset(290, 300), size, rtl: true), -1);
    });
  });

  group('formatting', () {
    test('russian plural', () {
      expect(plural(1, 'глава', 'главы', 'глав'), 'глава');
      expect(plural(3, 'глава', 'главы', 'глав'), 'главы');
      expect(plural(11, 'глава', 'главы', 'глав'), 'глав');
      expect(plural(22, 'глава', 'главы', 'глав'), 'главы');
      expect(plural(25, 'глава', 'главы', 'глав'), 'глав');
    });
    test('bytes & duration', () {
      expect(formatBytes(512), '512 Б');
      expect(formatBytes(1536), '1.5 КБ');
      expect(formatDuration(45), '45 с');
      expect(formatDuration(3720), '1 ч 2 мин');
    });
    test('relative dates', () {
      final now = DateTime(2026, 5, 10, 12);
      expect(formatDate(DateTime(2026, 5, 10, 1), now: now), 'сегодня');
      expect(formatDate(DateTime(2026, 5, 9, 1), now: now), 'вчера');
      expect(formatDate(DateTime(2026, 1, 3), now: now), '3 янв');
      expect(formatDate(DateTime(2025, 1, 3), now: now), '3 янв 2025');
    });
  });

  group('models', () {
    test('settings round-trip and remote merge keeps device-only keys', () {
      final s = AppSettings(apiBaseUrl: 'https://my.server', updatedAt: DateTime.utc(2026), readerBrightness: 0.5)
          .copyWith(
              showNsfw: true,
              defaultReadingMode: () => ReadingMode.pagedRtl,
              proxy: const ProxyConfig(type: ProxyType.socks5, host: '10.0.0.2', port: 1080));
      final back = AppSettings.fromJson(s.toJson(), fallbackUrl: 'x');
      expect(back.apiBaseUrl, AppConfig.defaultApiBaseUrl, reason: 'custom servers are gone');
      expect(back.proxy.port, 1080);
      expect(back.showNsfw, isTrue);
      expect(back.defaultReadingMode, ReadingMode.pagedRtl);
      final merged = back.mergeRemote({'show_nsfw': false, 'api_base_url': 'evil'}, DateTime.utc(2027));
      expect(merged.showNsfw, isFalse);
      expect(merged.apiBaseUrl, AppConfig.defaultApiBaseUrl);
      expect(merged.proxy.host, '10.0.0.2', reason: 'the proxy is device-only');
      expect(s.toSyncJson().containsKey('proxy'), isFalse);
      expect(merged.readerBrightness, 0.5);
      expect(merged.updatedAt, DateTime.utc(2027));
    });

    test('library entry api/row round-trip', () {
      final e = LibraryEntry(
        sourceId: 'mangalib', mangaId: 'abc', title: 'Ван Пис', addedAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 2, 1), status: LibraryStatus.onHold, isFavorite: true,
        readerSettings: const {'reading_mode': 'paged_rtl'},
      );
      final api = LibraryEntry.fromApi({...e.toApi(), 'collection_ids': <String>[]});
      expect(api.status, LibraryStatus.onHold);
      expect(api.isFavorite, isTrue);
      final row = LibraryEntry.fromRow(e.toRow());
      expect(row.readerSettings['reading_mode'], 'paged_rtl');
      expect(row.updatedAt, e.updatedAt);
    });

    test('reading mode suggestion per format', () {
      expect(ReadingMode.suggestedFor(MangaKind.manhwa), ReadingMode.vertical);
      expect(ReadingMode.suggestedFor(MangaKind.manga), ReadingMode.pagedRtl);
    });

    test('progress fraction', () {
      final p = ChapterProgress(sourceId: 's', mangaId: 'm', chapterId: 'c', updatedAt: DateTime.now(), pageIndex: 4, pageCount: 10);
      expect(p.fraction, 0.5);
    });

    test('catalog filters serialize to API query', () {
      const f = CatalogFilters(query: 'x', sort: SortMode.updated, kinds: [MangaKind.manhwa], statuses: [PubStatus.ongoing]);
      expect(f.toQuery(), containsPair('types', ['manhwa']));
      expect(f.toQuery(), containsPair('statuses', ['ongoing']));
      expect(f.activeCount, 2);
    });
  });

  group('ApiException', () {
    RequestOptions ro() => RequestOptions(path: '/x');

    test('maps backend error envelope', () {
      final e = ApiException.fromDio(DioException(
        requestOptions: ro(),
        response: Response(requestOptions: ro(), statusCode: 502, data: {
          'error': {'code': 'source_blocked', 'message': 'HTTP 403', 'details': {'source_id': 'remanga'}},
        }),
        type: DioExceptionType.badResponse,
      ));
      expect(e.code, 'source_blocked');
      expect(e.sourceId, 'remanga');
      expect(e.isSourceProblem, isTrue);
      expect(e.userMessage, contains('заблокировал'));
    });

    test('maps transport failures to offline', () {
      final e = ApiException.fromDio(DioException(requestOptions: ro(), type: DioExceptionType.connectionError));
      expect(e.isOffline, isTrue);
    });
  });
}
