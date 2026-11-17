import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/network/api_exception.dart';
import 'package:mangaflow/core/theme/app_theme.dart';
import 'package:mangaflow/data/models/manga.dart';
import 'package:mangaflow/widgets/manga_widgets.dart';
import 'package:mangaflow/widgets/states.dart';

Widget wrap(Widget child) => MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child));

void main() {
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
