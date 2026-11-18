import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/format.dart';
import '../../data/models/reading.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/services/sync_engine.dart';
import '../../widgets/effects.dart';
import 'stats_screen.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final stats = ref.watch(statsProvider).valueOrNull;
    final sync = ref.watch(syncStatusProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: MfSpace.gutter,
        title: const Text('Профиль'),
        actions: [
          IconButton(tooltip: 'Настройки', onPressed: () => context.push('/settings'), icon: const Icon(Icons.settings_outlined)),
        ],
      ),
      body: ListView(padding: EdgeInsets.only(bottom: bottomInset(context, MfSpace.huge)), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.sm, MfSpace.gutter, 0),
          child: switch (auth) {
            SignedIn(:final user) => _AccountCard(
                title: user.shownName,
                subtitle: user.email,
                trailing: _SyncChip(status: sync),
                onTap: () => ref.read(syncEngineProvider).sync(),
              ),
            Guest() => _AccountCard(
                title: 'Локальный режим',
                subtitle: 'Всё хранится на устройстве. Войдите, чтобы синхронизировать библиотеку и прогресс.',
                trailing: FilledButton(onPressed: () => context.push('/auth'), child: const Text('Войти')),
              ),
          },
        ),
        if (stats != null) _StatsStrip(stats: stats),
        const SizedBox(height: MfSpace.md),
        const _Link(icon: Icons.insights_outlined, title: 'Статистика', subtitle: 'Время чтения, серии, календарь', route: '/stats'),
        const _Link(icon: Icons.history_rounded, title: 'История чтения', route: '/history'),
        const _Link(icon: Icons.notifications_none_rounded, title: 'Новые главы', route: '/updates'),
        const _Link(icon: Icons.download_for_offline_outlined, title: 'Загрузки', subtitle: 'Главы для чтения офлайн', route: '/downloads'),
        const _Link(icon: Icons.public_rounded, title: 'Источники', subtitle: 'Включение, состояние, 18+', route: '/sources'),
        const _Link(icon: Icons.settings_outlined, title: 'Настройки', subtitle: 'Сервер, тема, читалка, резервные копии', route: '/settings'),
      ]),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.title, required this.subtitle, required this.trailing, this.onTap});
  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(MfSpace.lg),
            child: Row(children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: MfColors.accentSoft,
                child: Text(title.isEmpty ? '?' : title.characters.first.toUpperCase(),
                    style: MfType.title.copyWith(color: MfColors.accent)),
              ),
              const SizedBox(width: MfSpace.lg),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: context.text.titleMedium),
                  const SizedBox(height: 2),
                  Text(subtitle, style: context.text.bodySmall, maxLines: 3),
                ]),
              ),
              const SizedBox(width: MfSpace.sm),
              trailing,
            ]),
          ),
        ),
      );
}

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.status});
  final SyncStatus? status;

  @override
  Widget build(BuildContext context) {
    final s = status;
    final (icon, label, color) = switch (s?.phase) {
      SyncPhase.running => (Icons.sync_rounded, 'Синхронизация…', MfColors.accent),
      SyncPhase.error => (Icons.sync_problem_rounded, 'Ошибка', MfColors.danger),
      SyncPhase.offline => (Icons.cloud_off_rounded, 'Офлайн', MfColors.warning),
      _ => (Icons.cloud_done_outlined, s?.lastSync == null ? 'Синхр.' : formatDateTime(s!.lastSync!), MfColors.success),
    };
    return Tooltip(
      message: s?.message ?? 'Нажмите, чтобы синхронизировать',
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color),
        const SizedBox(height: 2),
        Text(label, style: MfType.caption.copyWith(color: context.textTertiary)),
      ]),
    );
  }
}

class _StatsStrip extends StatelessWidget {
  const _StatsStrip({required this.stats});
  final ReadingStats stats;

  @override
  Widget build(BuildContext context) {
    Widget cell(String value, String label) => Expanded(
          child: Column(children: [
            Text(value, style: MfType.title.copyWith(color: context.colors.onSurface)),
            const SizedBox(height: 2),
            Text(label, style: context.text.labelMedium, textAlign: TextAlign.center),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.lg, MfSpace.gutter, 0),
      child: Row(children: [
        cell('${stats.chaptersRead}', plural(stats.chaptersRead, 'глава', 'главы', 'глав')),
        cell(formatDuration(stats.totalSeconds), 'за чтением'),
        cell('${stats.currentStreak}', 'дней подряд'),
        cell('${stats.libraryTotal}', 'в библиотеке'),
      ]),
    );
  }
}

class _Link extends StatelessWidget {
  const _Link({required this.icon, required this.title, required this.route, this.subtitle});
  final IconData icon;
  final String title;
  final String? subtitle;
  final String route;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => context.push(route),
      );
}
