import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/theme/app_theme.dart';
import 'package:mangaflow/core/theme/tokens.dart';
import 'package:mangaflow/data/models/settings.dart';
import 'package:mangaflow/widgets/cover_color.dart';
import 'package:mangaflow/data/models/manga.dart';
import 'package:mangaflow/widgets/manga_widgets.dart';
import 'package:mangaflow/widgets/states.dart';

List<int> solid(int r, int g, int b, [int n = 64]) => [for (var i = 0; i < n; i++) ...[r, g, b, 255]];

void main() {
  group('dominantColor', () {
    test('picks the saturated hue and lifts it into a readable range', () {
      final c = dominantColor([...solid(20, 60, 200), ...solid(30, 30, 30), ...solid(250, 250, 250)])!;
      final hsl = HSLColor.fromColor(c);
      expect(hsl.hue, inInclusiveRange(215, 240));
      expect(hsl.lightness, inInclusiveRange(0.58, 0.70));
      expect(hsl.saturation, greaterThanOrEqualTo(0.5));
    });

    test('greyscale art yields no tint', () {
      expect(dominantColor([...solid(120, 120, 120), ...solid(10, 10, 10)]), isNull);
      expect(dominantColor(const []), isNull);
    });

    test('transparent pixels are ignored', () {
      expect(dominantColor([for (var i = 0; i < 32; i++) ...[255, 0, 0, 0]]), isNull);
    });
  });

  test('accent and library view survive settings round-trip; unknown values fall back', () {
    final s = AppSettings(apiBaseUrl: 'https://x', updatedAt: DateTime.utc(2026), accent: AccentPalette.mint, libraryView: LibraryView.list);
    final back = AppSettings.fromJson(s.toJson(), fallbackUrl: 'https://x');
    expect(back.accent, AccentPalette.mint);
    expect(back.libraryView, LibraryView.list);
    expect(s.toSyncJson()['accent'], 'mint');
    expect(AccentPalette.parse('nope'), AccentPalette.wallpaper);
    // settings saved before Material You (no accent_v) start on the wallpaper colours once
    expect(AppSettings.fromJson({...s.toJson()}..remove('accent_v'), fallbackUrl: 'https://x').accent, AccentPalette.wallpaper);
    expect(LibraryView.parse(null), LibraryView.grid);
    final v = AppSettings.fromJson(s.copyWith(volumeKeys: true, volumeKeysInverted: true).toJson(), fallbackUrl: 'https://x');
    expect((v.volumeKeys, v.volumeKeysInverted), (true, true));
    expect(AppSettings.fromJson(const {}, fallbackUrl: 'https://x').volumeKeys, isFalse);
  });

  testWidgets('each accent seeds a tonal scheme that keeps its hue', (tester) async {
    final primaries = <Color>{};
    for (final p in AccentPalette.values) {
      MfColors.palette = p;
      final scheme = AppTheme.dark().colorScheme;
      primaries.add(scheme.primary);
      final want = HSVColor.fromColor(p.color).hue, got = HSVColor.fromColor(scheme.primary).hue;
      final diff = (want - got).abs();
      expect(diff < 30 || diff > 330, isTrue, reason: '${p.label}: hue $want → $got');
      // Material You surfaces carry a hint of the accent, but stay dark
      expect(scheme.surface.computeLuminance(), lessThan(0.05));
    }
    expect(primaries.length, AccentPalette.values.length);
    MfColors.palette = AccentPalette.ember;
  });

  testWidgets('empty state renders the illustration', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: const Scaffold(body: EmptyState(icon: Icons.inbox_outlined, title: 'Пусто', message: 'm')),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(EmptyIllustration), findsOneWidget);
    expect(find.text('Пусто'), findsOneWidget);
  });

  testWidgets('long-press on a tile shows the full, untruncated title', (tester) async {
    const long = 'Очень длинное название тайтла, которое никак не помещается в две строки под обложкой в сетке';
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: SizedBox(
          width: 120,
          child: MangaTile(card: const MangaCard(sourceId: 's', id: '1', title: long), onTap: () {}),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(MangaTile));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('Копировать'), findsOneWidget);
  });

  test('source languages: both by default; English catalogs carry an EN badge', () {
    expect(AppSettings(apiBaseUrl: 'x', updatedAt: DateTime.utc(2026)).sourceLanguages, ['ru', 'en']);
    expect(AppSettings.fromJson(const {}, fallbackUrl: 'x').sourceLanguages, ['ru', 'en']);
    final en = SourceInfo.fromJson(const {'id': 'mangadex', 'name': 'MangaDex', 'lang': 'en'});
    expect(en.langBadge, 'EN');
    expect(SourceInfo.fromJson(const {'id': 'mangalib', 'name': 'MangaLib'}).langBadge, isNull);
  });
}
