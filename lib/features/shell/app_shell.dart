import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/reading.dart';
import '../../core/network/network_status.dart';
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

class _AppShellState extends ConsumerState<AppShell> with SingleTickerProviderStateMixin {
  StatefulNavigationShell get shell => widget.shell;

  /// Material «fade through» between tabs: the new tab fades and rises in.
  late final AnimationController _tab = AnimationController(vsync: this, duration: MfMotion.slow, value: 1);
  late int _lastIndex = widget.shell.currentIndex;

  @override
  void didUpdateWidget(AppShell old) {
    super.didUpdateWidget(old);
    if (widget.shell.currentIndex != _lastIndex) {
      _lastIndex = widget.shell.currentIndex;
      _tab.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Widget get _content => AnimatedBuilder(
        animation: _tab,
        builder: (context, child) {
          final t = MfMotion.emphasized.transform(_tab.value);
          return Opacity(
            opacity: (0.35 + 0.65 * t).clamp(0.0, 1.0),
            child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: child),
          );
        },
        child: shell,
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (mounted) autoCheckForUpdates(context, ref);
      });
      // home-screen widget: open the chapter it shows
      HomeWidgetSync.listen((route) {
        if (!mounted) return;
        route == '/library' ? GoRouter.of(context).go(route) : GoRouter.of(context).push(route);
      });
      unawaited(NetworkStatus.start());
      // a .cbz opened with / shared to MangaFlow → «Получить главы»
      IncomingFiles.listen((path) {
        if (!mounted) return;
        // a picture shared to MangaFlow → «Найти по скриншоту»; archives → «Получить главы»
        final isImage = RegExp(r'\.(jpe?g|png|webp|gif|heic|avif)$', caseSensitive: false).hasMatch(path);
        GoRouter.of(context).push(isImage ? Routes.lookup(path) : Routes.importChapters(path));
      });
    });
    // keep the widget in sync with "continue reading"
    ref.listenManual<AsyncValue<List<ContinueItem>>>(continueReadingProvider, (_, next) {
      final items = next.valueOrNull;
      if (items != null) unawaited(HomeWidgetSync.update(ref.read(prefsProvider), items.isEmpty ? null : items.first));
    }, fireImmediately: true);
    ref.listenManual<int>(dataVersionProvider, (_, __) => unawaited(_syncLibraryWidget()), fireImmediately: true);
  }

  Future<void> _syncLibraryWidget() async {
    try {
      final entries = await ref.read(libraryRepositoryProvider).all();
      await HomeWidgetSync.updateLibrary(ref.read(prefsProvider), entries);
    } catch (_) {}
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
          Expanded(child: _content),
        ]),
      );
    }
    return Scaffold(
      body: _content,
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
