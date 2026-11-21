import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/network/api_exception.dart';
import 'package:mangaflow/core/theme/app_theme.dart';
import 'package:mangaflow/data/models/manga.dart';
import 'package:mangaflow/data/models/library.dart';
import 'package:mangaflow/widgets/manga_widgets.dart';
import 'package:mangaflow/widgets/setting_previews.dart';
import 'package:mangaflow/widgets/states.dart';

Widget wrap(Widget child) => MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child));

void main() {
  testWidgets('settings previews paint every frame of every kind', (tester) async {
    var picked = ReadingMode.pagedRtl as ReadingMode?;
    await tester.pumpWidget(wrap(SingleChildScrollView(
      child: Column(children: [
        for (final on in [true, false])
          Wrap(children: [
            for (final k in PreviewKind.values)
              if (k == PreviewKind.mode)
                for (final m in ReadingMode.values) SettingPreview(kind: k, mode: m, enabled: on)
              else
                SettingPreview(kind: k, enabled: on),
          ]),
        StatefulBuilder(
          builder: (context, setState) => ReadingModePicker(selected: picked, onSelect: (m) => setState(() => picked = m)),
        ),
      ]),
    )));
    // walk through whole loops: page turns, panel steps, crop, taps
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 190));
    }
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Лента'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(picked, ReadingMode.vertical);
    await tester.tap(find.textContaining('Авто'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(picked, isNull);
  });

  testWidgets('error state shows a friendly message and retries', (tester) async {
    var retried = 0;
    await tester.pumpWidget(wrap(ErrorState(
      error: const ApiException('offline', 'offline'),
      onRetry: () => retried++,
    )));
    expect(find.textContaining('Нет подключения'), findsOneWidget);
    await tester.tap(find.text('Повторить'));
    expect(retried, 1);
  });

  testWidgets('manga tile renders title, subtitle and badge without network', (tester) async {
    var tapped = false;
    await tester.pumpWidget(wrap(Center(
      child: MangaTile(
        card: const MangaCard(sourceId: 's', id: 'm', title: 'Берсерк'),
        width: 120,
        subtitle: 'MangaLib',
        badge: '+2',
        onTap: () => tapped = true,
      ),
    )));
    expect(find.text('Берсерк'), findsOneWidget);
    expect(find.text('MangaLib'), findsOneWidget);
    expect(find.text('+2'), findsOneWidget);
    await tester.tap(find.text('Берсерк'));
    expect(tapped, isTrue);
  });

  testWidgets('themes build in both brightnesses', (tester) async {
    for (final theme in [AppTheme.dark(), AppTheme.light()]) {
      await tester.pumpWidget(MaterialApp(theme: theme, home: const Scaffold(body: EmptyState(icon: Icons.inbox, title: 'Пусто'))));
      expect(find.text('Пусто'), findsOneWidget);
    }
  });
}
