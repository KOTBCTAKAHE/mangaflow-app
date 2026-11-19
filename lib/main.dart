import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/router.dart';
import 'core/providers.dart';
import 'core/storage/database.dart';
import 'core/theme/tokens.dart';
import 'data/services/auto_download.dart';
import 'data/services/background.dart';
import 'data/services/downloads/download_runtime.dart';
import 'data/services/notifications.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Release builds render a blank grey box on build errors; show something actionable instead.
  ErrorWidget.builder = (details) => Material(
        color: const Color(0xFF15171B),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: Text(
              'Ошибка отображения. Сообщите разработчику:\n\n${details.exceptionAsString()}',
              style: const TextStyle(color: Color(0xFFA2A7B0), fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));

  // Keep decoded-image memory bounded on low-end devices.
  PaintingBinding.instance.imageCache
    ..maximumSize = 200
    ..maximumSizeBytes = 120 << 20;

  final results = await Future.wait([AppDatabase.open(), SharedPreferences.getInstance()]);
  final db = results[0] as AppDatabase;
  final prefs = results[1] as SharedPreferences;

  final container = ProviderContainer(overrides: [
    databaseProvider.overrideWithValue(db),
    prefsProvider.overrideWithValue(prefs),
  ]);
  await container.read(authProvider.notifier).restore();
  MfColors.palette = container.read(settingsProvider).accent;

  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    DownloadService.init();
    await BackgroundUpdates.initialize();
    unawaited(ChapterNotifier.instance.init());
    if (container.read(settingsProvider).notifyUpdates) {
      unawaited(BackgroundUpdates.register().catchError((Object _) {}));
    }
    unawaited(AutoDownload.sync(container.read(settingsProvider).autoDownloadNew));
  }

  runApp(UncontrolledProviderScope(container: container, child: MangaFlowApp(router: buildRouter())));
}
