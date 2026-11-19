import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/reading.dart';
import '../../data/services/home_widget_sync.dart';
import '../../data/services/transfer/incoming_files.dart';
import '../../widgets/effects.dart';
import '../update_dialog.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  StatefulNavigationShell get shell => widget.shell;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (mounted) autoCheckForUpdates(context, ref);
      });
      // home-screen widget: open the chapter it shows
      HomeWidgetSync.listen((route) {
        if (mounted) GoRouter.of(context).push(route);
      });
      // a .cbz opened with / shared to MangaFlow → «Получить главы»
      IncomingFiles.listen((path) {
        if (mounted) GoRouter.of(context).push(Routes.importChapters(path));
      });
    });
    // keep the widget in sync with "continue reading"
    ref.listenManual<AsyncValue<List<ContinueItem>>>(continueReadingProvider, (_, next) {
      final items = next.valueOrNull;
      if (items != null) unawaited(HomeWidgetSync.update(ref.read(prefsProvider), items.isEmpty ? null : items.first));
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) {
    final unseen = ref.watch(unseenUpdatesProvider).valueOrNull ?? 0;
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 840) {
      // Tablet / landscape: navigation rail on the side, content gets the full height.
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            extended: width >= 1200,
            selectedIndex: shell.currentIndex,
            labelType: width >= 1200 ? NavigationRailLabelType.none : NavigationRailLabelType.all,
            onDestinationSelected: (i) {
              HapticFeedback.selectionClick();
              shell.goBranch(i, initialLocation: i == shell.currentIndex);
            },
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: MfSpace.lg),
              child: Icon(Icons.auto_stories_rounded, color: MfColors.accent, size: 28),
            ),
            destinations: [
              const NavigationRailDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: Text('Главная')),
              const NavigationRailDestination(icon: Icon(Icons.explore_outlined), selectedIcon: Icon(Icons.explore_rounded), label: Text('Поиск')),
              NavigationRailDestination(
                icon: Badge(isLabelVisible: unseen > 0, label: Text('$unseen'), child: const Icon(Icons.collections_bookmark_outlined)),
                selectedIcon: Badge(isLabelVisible: unseen > 0, label: Text('$unseen'), child: const Icon(Icons.collections_bookmark_rounded)),
                label: const Text('Библиотека'),
              ),
              const NavigationRailDestination(icon: Icon(Icons.person_outline_rounded), selectedIcon: Icon(Icons.person_rounded), label: Text('Профиль')),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: shell),
        ]),
      );
    }
    return Scaffold(
      body: shell,
      extendBody: true, // content scrolls under the frosted bar
      bottomNavigationBar: MfNavBar(
        selectedIndex: shell.currentIndex,
        unseen: unseen,
        onSelect: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
      ),
    );
  }
}

/// Frosted bottom navigation shared by the shell (and screenshot tests).
class MfNavBar extends StatelessWidget {
  const MfNavBar({super.key, required this.selectedIndex, required this.onSelect, this.unseen = 0});
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final int unseen;

  @override
  Widget build(BuildContext context) => Glass(
        child: NavigationBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          selectedIndex: selectedIndex,
          onDestinationSelected: (i) {
            HapticFeedback.selectionClick();
            onSelect(i);
          },
          destinations: [
            const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Главная'),
            const NavigationDestination(icon: Icon(Icons.explore_outlined), selectedIcon: Icon(Icons.explore_rounded), label: 'Поиск'),
            NavigationDestination(
              icon: Badge(isLabelVisible: unseen > 0, label: Text('$unseen'), child: const Icon(Icons.collections_bookmark_outlined)),
              selectedIcon: Badge(isLabelVisible: unseen > 0, label: Text('$unseen'), child: const Icon(Icons.collections_bookmark_rounded)),
              label: 'Библиотека',
            ),
            const NavigationDestination(icon: Icon(Icons.person_outline_rounded), selectedIcon: Icon(Icons.person_rounded), label: 'Профиль'),
          ],
        ),
      );
}
