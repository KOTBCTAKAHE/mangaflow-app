import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final unseen = ref.watch(unseenUpdatesProvider).valueOrNull ?? 0;
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
