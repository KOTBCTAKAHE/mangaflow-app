import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/discover/discover_screen.dart';
import '../features/discover/source_browse_screen.dart';
import '../features/home/home_screen.dart';
import '../features/library/library_screen.dart';
import '../features/profile/bookmarks_screen.dart';
import '../features/profile/year_review_screen.dart';
import '../features/profile/auth_screen.dart';
import '../features/profile/downloads_screen.dart';
import '../features/profile/history_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/profile/settings_screen.dart';
import '../features/profile/sources_screen.dart';
import '../features/profile/stats_screen.dart';
import '../features/profile/updates_screen.dart';
import '../features/reader/reader_screen.dart';
import '../features/shell/app_shell.dart';
import '../features/title/title_screen.dart';
import '../features/transfer/transfer_ui.dart';
import '../features/transfer/wifi_transfer_ui.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

abstract final class Routes {
  static String title(String sourceId, String mangaId) => '/title/$sourceId/$mangaId';
  static String reader(String sourceId, String mangaId, String chapterId, {int? page}) =>
      '/reader/$sourceId/$mangaId/$chapterId${page != null ? '?page=$page' : ''}';
  static String source(String sourceId) => '/source/$sourceId';
  static const receiveWifi = '/receive-wifi';
  static String importChapters(String path) => Uri(path: '/import', queryParameters: {'path': path}).toString();
}

CustomTransitionPage<void> _fade(GoRouterState s, Widget child) => CustomTransitionPage(
      key: s.pageKey,
      child: child,
      transitionDuration: const Duration(milliseconds: 220),
      transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: CurvedAnimation(parent: a, curve: Curves.easeOut), child: c),
    );

GoRouter buildRouter() => GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: '/home',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => AppShell(shell: shell),
          branches: [
            StatefulShellBranch(routes: [GoRoute(path: '/home', builder: (_, __) => const HomeScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: '/discover', builder: (_, __) => const DiscoverScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: '/library', builder: (_, __) => const LibraryScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen())]),
          ],
        ),
        GoRoute(
          path: '/title/:source/:manga',
          parentNavigatorKey: rootNavigatorKey,
          builder: (_, s) => TitleScreen(sourceId: s.pathParameters['source']!, mangaId: s.pathParameters['manga']!),
        ),
        GoRoute(
          path: '/reader/:source/:manga/:chapter',
          parentNavigatorKey: rootNavigatorKey,
          pageBuilder: (_, s) => _fade(
            s,
            ReaderScreen(
              sourceId: s.pathParameters['source']!,
              mangaId: s.pathParameters['manga']!,
              chapterId: s.pathParameters['chapter']!,
              initialPage: int.tryParse(s.uri.queryParameters['page'] ?? ''),
            ),
          ),
        ),
        GoRoute(
          path: '/source/:source',
          parentNavigatorKey: rootNavigatorKey,
          builder: (_, s) => SourceBrowseScreen(sourceId: s.pathParameters['source']!),
        ),
        GoRoute(path: '/auth', parentNavigatorKey: rootNavigatorKey, builder: (_, __) => const AuthScreen()),
        GoRoute(path: '/settings', parentNavigatorKey: rootNavigatorKey, builder: (_, __) => const SettingsScreen()),
        GoRoute(path: '/stats', parentNavigatorKey: rootNavigatorKey, builder: (_, __) => const StatsScreen()),
        GoRoute(path: '/review', parentNavigatorKey: rootNavigatorKey, builder: (_, __) => const YearReviewScreen()),
        GoRoute(path: '/bookmarks', parentNavigatorKey: rootNavigatorKey, builder: (_, __) => const BookmarksScreen()),
        GoRoute(path: '/downloads', parentNavigatorKey: rootNavigatorKey, builder: (_, __) => const DownloadsScreen()),
        GoRoute(path: '/receive-wifi', parentNavigatorKey: rootNavigatorKey, builder: (_, __) => const WifiReceiveScreen()),
        GoRoute(
          path: '/import',
          parentNavigatorKey: rootNavigatorKey,
          builder: (_, s) => ImportChaptersScreen(path: s.uri.queryParameters['path'] ?? ''),
        ),
        GoRoute(path: '/history', parentNavigatorKey: rootNavigatorKey, builder: (_, __) => const HistoryScreen()),
        GoRoute(path: '/updates', parentNavigatorKey: rootNavigatorKey, builder: (_, __) => const UpdatesScreen()),
        GoRoute(path: '/sources', parentNavigatorKey: rootNavigatorKey, builder: (_, __) => const SourcesScreen()),
      ],
    );
