import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/providers.dart';
import 'package:mangaflow/core/theme/app_theme.dart';
import 'package:mangaflow/data/models/library.dart';
import 'package:mangaflow/data/models/manga.dart';
import 'package:mangaflow/features/discover/discover_screen.dart';
import 'package:mangaflow/features/discover/search_controller.dart';
import 'package:mangaflow/features/home/home_screen.dart';
import 'package:mangaflow/features/library/library_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Smoke tests: screens must lay out without exceptions in their initial states
/// (a layout error shows up as a grey screen in release builds).
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pump(WidgetTester tester, Widget screen, List<Override> overrides) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs), ...overrides],
      child: MaterialApp(theme: AppTheme.dark(), home: screen),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  }

  const sources = [
    SourceInfo(id: 'mangalib', name: 'MangaLib', baseUrl: 'https://mangalib.org'),
    SourceInfo(id: 'remanga', name: 'Remanga', baseUrl: 'https://remanga.org'),
  ];

  testWidgets('Discover idle state (history, genres, source catalogs)', (tester) async {
    await pump(tester, const DiscoverScreen(), [
      sourcesProvider.overrideWith((_) async => sources),
      searchHistoryProvider.overrideWith((_) async => ['наруто', 'берсерк']),
    ]);
    expect(find.text('Недавние запросы'), findsOneWidget);
    expect(find.text('Жанры'), findsOneWidget);
    expect(find.text('наруто'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Каталоги источников'), 200);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Discover with empty history and no sources', (tester) async {
    await pump(tester, const DiscoverScreen(), [
      sourcesProvider.overrideWith((_) async => const <SourceInfo>[]),
      searchHistoryProvider.overrideWith((_) async => const <String>[]),
    ]);
    expect(find.text('Жанры'), findsOneWidget);
  });

  testWidgets('Library: empty and with entries', (tester) async {
    await pump(tester, const LibraryScreen(), [
      libraryEntriesProvider.overrideWith((_) async => const <LibraryEntry>[]),
      collectionsProvider.overrideWith((_) async => const <Collection>[]),
    ]);
    expect(find.text('Библиотека пуста'), findsOneWidget);

    await pump(tester, const LibraryScreen(), [
      libraryEntriesProvider.overrideWith((_) async => [
            LibraryEntry(sourceId: 's', mangaId: 'm', title: 'Берсерк', addedAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026),
                status: LibraryStatus.reading, unreadUpdates: 2),
          ]),
      collectionsProvider.overrideWith((_) async => const [Collection(id: 'c', name: 'Сёнэн')]),
    ]);
    expect(find.text('Берсерк'), findsOneWidget);
    expect(find.text('+2'), findsOneWidget);
  });
}
