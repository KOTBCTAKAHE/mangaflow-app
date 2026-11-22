// Renders key screens with fake data to PNGs (design review in CI).
// Run: flutter test --update-goldens screenshots/
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/providers.dart';
import 'package:mangaflow/core/storage/database.dart';
import 'package:mangaflow/core/theme/app_theme.dart';
import 'package:mangaflow/core/theme/tokens.dart';
import 'package:mangaflow/data/models/library.dart';
import 'package:mangaflow/data/models/manga.dart';
import 'package:mangaflow/data/models/reading.dart';
import 'package:mangaflow/data/repositories/catalog_repository.dart';
import 'package:mangaflow/features/discover/discover_screen.dart';
import 'package:mangaflow/features/discover/search_controller.dart';
import 'package:mangaflow/features/home/home_screen.dart';
import 'package:mangaflow/features/library/library_screen.dart';
import 'package:mangaflow/features/profile/settings_screen.dart';
import 'package:mangaflow/features/reader/reader_screen.dart';
import 'package:mangaflow/features/reader/reader_views.dart';
import 'package:mangaflow/features/shell/app_shell.dart';
import 'package:mangaflow/features/title/title_providers.dart';
import 'package:mangaflow/features/title/title_screen.dart';
import 'package:mangaflow/widgets/net_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

late List<Uint8List> covers;
late Uint8List page;
final _providers = <String, MemoryImage>{};

Future<void> loadFonts() async {
  final manifest = json.decode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final f in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(f['family'] as String);
    for (final a in (f['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(a['asset'] as String));
    }
    await loader.load();
  }
  final roboto = FontLoader('Roboto')..addFont(rootBundle.load('assets/fonts/Manrope.ttf'));
  await roboto.load();
}

String cover(int i) => 'https://img.test/c/$i';
String pageUrl(int i) => 'https://img.test/p/$i';

const titles = [
  'Поднятие уровня в одиночку',
  'Ван Пис',
  'Магическая битва',
  'Всеведущий читатель',
  'Башня Бога',
  'Берсерк',
  'Человек-бензопила',
  'Возвращение безумного демона',
];

MangaCard card(int i, {String source = 'MangaLib'}) => MangaCard(
      sourceId: 'mangalib',
      id: 'm$i',
      title: titles[i % titles.length],
      coverUrl: cover(i),
      kind: i.isEven ? MangaKind.manhwa : MangaKind.manga,
      sourceName: source,
    );

const sources = [
  SourceInfo(id: 'mangalib', name: 'MangaLib', baseUrl: 'https://mangalib.me'),
  SourceInfo(id: 'remanga', name: 'ReManga', baseUrl: 'https://remanga.org'),
  SourceInfo(id: 'senkuro', name: 'Senkuro', baseUrl: 'https://senkuro.com'),
  SourceInfo(id: 'readmanga', name: 'ReadManga', baseUrl: 'https://readmanga.live'),
];

MangaDetails details() => MangaDetails(
      sourceId: 'mangalib',
      sourceName: 'MangaLib',
      id: 'm0',
      title: 'Поднятие уровня в одиночку: Рагнарёк — возвращение охотника',
      altTitles: const ['Solo Leveling: Ragnarok', '나 혼자만 레벨업: 라그나로크'],
      coverUrl: cover(0),
      description: 'Прошло несколько лет после победы над Монархами. Сын Сон Джину, Сухо, '
          'пробуждает в себе силу отца и оказывается втянут в новую войну, где ставки выше, чем когда-либо.',
      genres: const ['Боевик', 'Фэнтези', 'Приключения', 'Сверхъестественное'],
      authors: const ['Daul', 'Chugong'],
      status: PubStatus.ongoing,
      kind: MangaKind.manhwa,
      ageRating: '16+',
    );

List<Chapter> chapters() => [
      for (var i = 48; i >= 1; i--)
        Chapter(id: 'ch$i', title: 'Глава $i${i == 48 ? ' — Новый монарх' : ''}', number: i.toDouble(),
            uploadedAt: DateTime.utc(2026, 11, 18).subtract(Duration(days: (48 - i) * 7)), scanlator: 'Team Arise'),
    ];

class FakeCatalog implements CatalogRepository {
  @override
  Future<TitleData> title(String sourceId, String mangaId, {bool refresh = false}) async =>
      TitleData(manga: details(), chapters: chapters());

  @override
  Future<List<PageRef>> pages(String sourceId, String chapterId) async =>
      [for (var i = 0; i < 24; i++) PageRef(index: i, url: pageUrl(i))];

  @override
  Future<TitleData?> merged(String sourceId, String mangaId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AppDatabase db;

  setUpAll(() async {
    sqfliteFfiInit();
    await loadFonts();
    covers = [for (var i = 0; i < 8; i++) File('screenshots/fixtures/cover_$i.png').readAsBytesSync()];
    page = File('screenshots/fixtures/page_0.png').readAsBytesSync();
    debugNetworkImageOverride = (url) {
      final path = Uri.parse(url).pathSegments;
      final bytes = path.length > 1 && path[0] == 'p' ? page : covers[(int.tryParse(path.last) ?? 0) % covers.length];
      return _providers.putIfAbsent(path.join("/"), () => MemoryImage(bytes));
    };
  });

  Future<ProviderContainer> setup(WidgetTester tester, {Map<String, Object> prefs = const {}}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    tester.view.padding = const FakeViewPadding(top: 66, bottom: 44);
    tester.view.viewPadding = const FakeViewPadding(top: 66, bottom: 44);
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(prefs);
    final sp = await SharedPreferences.getInstance();
    db = (await tester.runAsync(() => AppDatabase.open(path: inMemoryDatabasePath, factory: databaseFactoryFfi)))!;
    final container = ProviderContainer(overrides: [
      prefsProvider.overrideWithValue(sp),
      databaseProvider.overrideWithValue(db),
      catalogRepositoryProvider.overrideWithValue(FakeCatalog()),
      sourcesProvider.overrideWith((_) async => sources),
      unseenUpdatesProvider.overrideWith((_) async => 3),
      continueReadingProvider.overrideWith((_) async => [
            ContinueItem(sourceId: 'mangalib', mangaId: 'm3', title: titles[3], coverUrl: cover(3), chapterId: 'c',
                chapterTitle: 'Глава 127 — Сценарий', fraction: 0.62, updatedAt: DateTime.utc(2026)),
            ContinueItem(sourceId: 'mangalib', mangaId: 'm1', title: titles[1], coverUrl: cover(1), chapterId: 'c',
                chapterTitle: 'Глава 1102', fraction: 0.2, updatedAt: DateTime.utc(2026)),
          ]),
      homeFeedProvider.overrideWith((ref, id) async => (
            [
              HomeSection(key: 'popular', title: 'Популярное', items: [for (var i = 0; i < 8; i++) card(i)]),
              HomeSection(key: 'latest', title: 'Свежие главы', items: [for (var i = 7; i >= 0; i--) card(i)]),
            ],
            const <SourceFailure>[],
          )),
      searchHistoryProvider.overrideWith((_) async => ['поднятие уровня', 'берсерк', 'башня']),
      libraryEntriesProvider.overrideWith((_) async => [
            for (var i = 0; i < 8; i++)
              LibraryEntry(
                sourceId: 'mangalib',
                mangaId: 'm$i',
                title: titles[i],
                coverUrl: cover(i),
                addedAt: DateTime.utc(2026),
                updatedAt: DateTime.utc(2026),
                status: i < 5 ? LibraryStatus.reading : LibraryStatus.planned,
                isFavorite: i == 1,
                totalChapters: 120,
                lastChapterNumber: (i * 17 % 110).toDouble() + 3,
                unreadUpdates: i % 3 == 0 ? i + 1 : 0,
              ),
          ]),
      collectionsProvider.overrideWith((_) async => const [Collection(id: 'c', name: 'Сёнэн')]),
      titleProgressProvider.overrideWith((ref, k) async => {
            for (var i = 1; i <= 31; i++)
              'ch$i': ChapterProgress(sourceId: 'mangalib', mangaId: 'm0', chapterId: 'ch$i', updatedAt: DateTime.utc(2026),
                  completed: true, pageCount: 40, pageIndex: 39),
            'ch32': ChapterProgress(sourceId: 'mangalib', mangaId: 'm0', chapterId: 'ch32', updatedAt: DateTime.utc(2026, 2),
                pageCount: 40, pageIndex: 12),
          }),
      titleEntryProvider.overrideWith((ref, k) async => null),
      titleDownloadsProvider.overrideWith((ref, k) async => const {}),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  Future<void> shot(WidgetTester tester, ProviderContainer c, Widget screen, String name,
      {Future<void> Function()? before}) async {
    const key = ValueKey('shot');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: AppTheme.light(), darkTheme: AppTheme.dark(),
            themeMode: ThemeMode.dark, home: screen),
      ),
    ));
    await settle(tester);
    if (before != null) {
      await before();
      await settle(tester);
    }
    await expectLater(find.byKey(key), matchesGoldenFile('out/$name.png'));
    // let short-lived timers (the reader's auto-hiding controls) run out before the test ends
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  Widget tab(Widget body, int index) => Scaffold(
        extendBody: true,
        body: body,
        bottomNavigationBar: MfNavBar(selectedIndex: index, onSelect: (_) {}, unseen: 3),
      );

  testWidgets('01 home', (tester) async {
    final c = await setup(tester);
    await shot(tester, c, tab(const HomeScreen(), 0), '01_home');
  });

  testWidgets('02 home scrolled', (tester) async {
    final c = await setup(tester);
    await shot(tester, c, tab(const HomeScreen(), 0), '02_home_scrolled', before: () async {
      await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -520));
    });
  });

  testWidgets('03 discover', (tester) async {
    final c = await setup(tester);
    await shot(tester, c, tab(const DiscoverScreen(), 1), '03_discover');
  });

  testWidgets('04 library grid', (tester) async {
    final c = await setup(tester);
    await shot(tester, c, tab(const LibraryScreen(), 2), '04_library_grid');
  });

  testWidgets('05 library list', (tester) async {
    final c = await setup(tester, prefs: {
      'app_settings_v1': jsonEncode({'library_view': 'list', 'api_base_url': 'https://x'}),
    });
    await shot(tester, c, tab(const LibraryScreen(), 2), '05_library_list');
  });

  testWidgets('06 title', (tester) async {
    final c = await setup(tester);
    await shot(tester, c, const TitleScreen(sourceId: 'mangalib', mangaId: 'm0'), '06_title');
  });

  testWidgets('07 title scrolled', (tester) async {
    final c = await setup(tester);
    await shot(tester, c, const TitleScreen(sourceId: 'mangalib', mangaId: 'm0'), '07_title_scrolled', before: () async {
      await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -700));
    });
  });

  testWidgets('08 reader overlay', (tester) async {
    final c = await setup(tester, prefs: {'reader_hint_strip': true, 'reader_hint_paged': true});
    await shot(tester, c, const ReaderScreen(sourceId: 'mangalib', mangaId: 'm0', chapterId: 'ch32'), '08_reader_overlay');
  });

  testWidgets('09 reader tap hint', (tester) async {
    final c = await setup(tester);
    await shot(tester, c, const ReaderScreen(sourceId: 'mangalib', mangaId: 'm0', chapterId: 'ch32'), '09_reader_hint');
  });

  testWidgets('10 settings', (tester) async {
    final c = await setup(tester);
    await shot(tester, c, const SettingsScreen(), '10_settings');
  });

  testWidgets('11 accent violet home', (tester) async {
    final c = await setup(tester, prefs: {
      'app_settings_v1': jsonEncode({'accent': 'violet', 'api_base_url': 'https://x'}),
    });
    MfColors.palette = AccentPalette.violet;
    addTearDown(() => MfColors.palette = AccentPalette.ember);
    await shot(tester, c, tab(const LibraryScreen(), 2), '11_library_violet');
  });

  testWidgets('12 reader settings', (tester) async {
    final c = await setup(tester, prefs: {'reader_hint_strip': true, 'reader_hint_paged': true});
    await shot(tester, c, const ReaderScreen(sourceId: 'mangalib', mangaId: 'm0', chapterId: 'ch32'), '12_reader_settings',
        before: () async {
      await tester.tap(find.byIcon(Icons.tune_rounded));
    });
  });

  testWidgets('13 chapter finished', (tester) async {
    final c = await setup(tester);
    final ch = chapters();
    await shot(
      tester,
      c,
      Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: ChapterFinishCard(finished: ch[16], next: ch[15], remaining: 16, onNext: () {}),
          ),
        ),
      ),
      '13_chapter_finished',
    );
  });
}
