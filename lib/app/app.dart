import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/config.dart';
import '../core/providers.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../data/repositories/auth_repository.dart';
import '../features/security/app_lock.dart';

class MangaFlowApp extends ConsumerStatefulWidget {
  const MangaFlowApp({super.key, required this.router});
  final GoRouter router;

  @override
  ConsumerState<MangaFlowApp> createState() => _MangaFlowAppState();
}

class _MangaFlowAppState extends ConsumerState<MangaFlowApp> with WidgetsBindingObserver {
  Timer? _periodic;
  StreamSubscription<List<ConnectivityResult>>? _net;
  StreamSubscription<AuthState>? _auth;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final sync = ref.read(syncEngineProvider);
    unawaited(ref.read(downloadManagerProvider).resumeInterrupted());
    unawaited(sync.sync());
    _periodic = Timer.periodic(AppConfig.syncInterval, (_) => unawaited(sync.sync()));
    _net = Connectivity().onConnectivityChanged.listen((r) {
      if (!r.contains(ConnectivityResult.none)) unawaited(sync.sync());
    });
    _auth = ref.read(authProvider.notifier).events.listen((state) async {
      if (state is SignedIn) {
        await sync.markAllDirty(); // upload guest data into the new account
        await sync.sync();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(syncEngineProvider).sync());
      unawaited(ref.read(downloadManagerProvider).kick());
    }
    if (state == AppLifecycleState.paused) unawaited(ref.read(syncEngineProvider).sync());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _periodic?.cancel();
    _net?.cancel();
    _auth?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(settingsProvider.select((s) => s.themeMode));
    final accent = ref.watch(settingsProvider.select((s) => s.accent));
    MfColors.palette = accent; // read by tokens during build
    return MaterialApp.router(
      key: ValueKey(accent), // rebuild every widget that read the old accent
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: widget.router,
      // PIN / fingerprint screen above every route
      builder: (context, child) => AppLockGate(child: child ?? const SizedBox.shrink()),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
