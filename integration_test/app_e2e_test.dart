// End-to-end test on a real Android device/emulator against a running backend
// that has the `e2e` fixture source installed (see mangaflow-backend/e2e).
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/app_e2e_test.dart \
//     --dart-define=API_BASE_URL=http://10.0.2.2:8080
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mangaflow/core/config.dart';
import 'package:mangaflow/features/reader/reader_page_image.dart';
import 'package:mangaflow/main.dart' as app;

/// Pumps frames until [finder] matches (pumpAndSettle never settles with shimmer animations).
Future<void> pumpUntil(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 40)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder');
}

Future<void> settle(WidgetTester tester, [int ms = 1200]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

bool anyPageRendered(WidgetTester tester) => tester
    .widgetList<RawImage>(find.descendant(of: find.byType(ReaderPageImage), matching: find.byType(RawImage)))
    .any((r) => r.image != null);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final user = 'e2e${DateTime.now().millisecondsSinceEpoch % 100000000}';
  const password = 'e2e-pass-123';

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.pump();
    await binding.takeScreenshot(name);
  }

  testWidgets('MangaFlow end-to-end on Android', (tester) async {
    await app.main();
    await binding.convertFlutterSurfaceToImage();

    // ---- Home: feed from the backend
    await pumpUntil(tester, find.text('Тестовая манхва'));
    await settle(tester, 2500);
    await shot(tester, '01_home');
    expect(find.text('Популярное'), findsWidgets);

    // ---- Title details
    await tester.tap(find.text('Тестовая манхва').first);
    await pumpUntil(tester, find.textContaining('Описание: Тестовая манхва'));
    await settle(tester, 1500);
    expect(find.text('Экшен'), findsWidgets);
    await shot(tester, '02_title');
    final titleScroll = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('Глава 1'), 250, scrollable: titleScroll);
    await settle(tester, 600);
    await shot(tester, '02b_chapters');
    await tester.scrollUntilVisible(find.text('Читать'), -250, scrollable: titleScroll);
    await settle(tester, 400);

    await tester.tap(find.byTooltip('В библиотеку'));
    await pumpUntil(tester, find.text('Добавлено в библиотеку'));

    // ---- Reader (manhwa → vertical strip)
    await tester.tap(find.text('Читать'));
    await pumpUntil(tester, find.byType(ReaderPageImage));
    final until = DateTime.now().add(const Duration(seconds: 30));
    while (!anyPageRendered(tester) && DateTime.now().isBefore(until)) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(anyPageRendered(tester), isTrue, reason: 'page images should load through the signed image proxy');
    expect(find.textContaining('не загрузилась'), findsNothing);
    await shot(tester, '03_reader_vertical_ui');

    // the controls hide by themselves (3.0); scroll through the chapter
    final center = tester.getCenter(find.byType(Scaffold).last);
    await settle(tester, 3000);
    for (var i = 0; i < 6; i++) {
      await tester.fling(find.byType(CustomScrollView).last, const Offset(0, -900), 2500);
      await settle(tester, 700);
    }
    await shot(tester, '04_reader_vertical_reading');
    await tester.tapAt(center);
    await settle(tester, 600);
    await shot(tester, '05_reader_overlay');

    // switch to paged RTL via the mode button and back
    await tester.tap(find.byTooltip('Режим чтения'));
    await settle(tester, 1500);
    expect(find.byType(PageView), findsOneWidget);
    await shot(tester, '06_reader_paged');

    await tester.tap(find.byType(BackButton).first);
    await pumpUntil(tester, find.textContaining('Продолжить'));
    await settle(tester, 800);
    await shot(tester, '07_title_progress');

    // ---- Offline download of one chapter
    final scroll2 = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byTooltip('Скачать').first, 250, scrollable: scroll2);
    await settle(tester, 400);
    await tester.tap(find.byTooltip('Скачать').first);
    await pumpUntil(tester, find.byTooltip('Скачано · удалить'), timeout: const Duration(seconds: 60));
    await settle(tester, 500);
    await shot(tester, '07b_downloaded');

    // ---- Library
    await tester.tap(find.byType(BackButton).first);
    await settle(tester, 800);
    await tester.tap(find.text('Библиотека').last);
    await pumpUntil(tester, find.text('Тестовая манхва'));
    await settle(tester, 1500);
    await shot(tester, '08_library');

    // ---- Global search
    await tester.tap(find.text('Поиск').last);
    await settle(tester, 800);
    await tester.enterText(find.byType(TextField).first, 'Тестовая');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pumpUntil(tester, find.text('Тестовая манга'));
    await settle(tester, 1500);
    await shot(tester, '09_search');

    // ---- Register → sync local data into the account
    await tester.tap(find.text('Профиль').last);
    await settle(tester, 800);
    await shot(tester, '10_profile_guest');
    await tester.tap(find.text('Войти'));
    await pumpUntil(tester, find.text('Нет аккаунта? Регистрация'));
    await tester.tap(find.text('Нет аккаунта? Регистрация'));
    await settle(tester, 500);
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), '$user@example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Имя пользователя'), user);
    await tester.enterText(find.widgetWithText(TextFormField, 'Пароль'), password);
    await settle(tester, 300);
    await tester.tap(find.text('Зарегистрироваться'));
    await pumpUntil(tester, find.text(user), timeout: const Duration(seconds: 30));
    await settle(tester, 6000); // first sync after sign-in
    await shot(tester, '11_profile_signed_in');

    // ---- Verify on the server that library + progress + history were synced
    final api = Dio(BaseOptions(baseUrl: '${AppConfig.defaultApiBaseUrl}/api/v1'));
    final login = await api.post<Map<String, dynamic>>('/auth/login', data: {'login': user, 'password': password});
    final token = (login.data!['tokens'] as Map)['access_token'] as String;
    final auth = Options(headers: {'Authorization': 'Bearer $token'});
    final lib = await api.get<Map<String, dynamic>>('/library', options: auth);
    final titles = [for (final e in lib.data!['items'] as List) (e as Map)['title']];
    expect(titles, contains('Тестовая манхва'));
    final progress = await api.get<Map<String, dynamic>>('/progress', options: auth);
    expect((progress.data!['items'] as List), isNotEmpty);
    final history = await api.get<Map<String, dynamic>>('/history', options: auth);
    expect((history.data!['items'] as List), isNotEmpty);

    // ---- Stats screen from local data
    await tester.tap(find.text('Статистика'));
    await pumpUntil(tester, find.text('Календарь активности'));
    await settle(tester, 800);
    await shot(tester, '12_stats');
  });
}
