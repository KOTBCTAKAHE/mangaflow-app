import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/format.dart';
import '../../data/models/library.dart';
import '../../data/models/reading.dart';
import '../../widgets/states.dart';

final statsProvider = FutureProvider<ReadingStats>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(readingRepositoryProvider).stats();
});

class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(statsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Статистика')),
      body: AsyncBody(
        value: stats,
        onRetry: () => ref.invalidate(statsProvider),
        data: (s) => ListView(padding: const EdgeInsets.all(MfSpace.gutter), children: [
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: MfSpace.md,
            crossAxisSpacing: MfSpace.md,
            childAspectRatio: 1.7,
            children: [
              _StatCard(value: '${s.chaptersRead}', label: 'прочитано глав', icon: Icons.menu_book_rounded),
              _StatCard(value: formatDuration(s.totalSeconds), label: 'время чтения', icon: Icons.schedule_rounded),
              _StatCard(value: '${s.titlesRead}', label: 'тайтлов открыто', icon: Icons.auto_stories_outlined),
              _StatCard(value: '${s.currentStreak} / ${s.longestStreak}', label: 'серия / рекорд, дней', icon: Icons.local_fire_department_outlined),
            ],
          ),
          const SizedBox(height: MfSpace.xxl),
          Text('Календарь активности', style: context.text.titleLarge),
          const SizedBox(height: MfSpace.md),
          _ActivityCalendar(activity: s.activity),
          const SizedBox(height: MfSpace.xxl),
          Text('Библиотека', style: context.text.titleLarge),
          const SizedBox(height: MfSpace.md),
          for (final st in LibraryStatus.values)
            _StatusBar(label: st.label, value: s.byStatus[st.api] ?? 0, total: s.libraryTotal),
        ]),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.value, required this.label, required this.icon});
  final String value;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(MfSpace.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Icon(icon, color: MfColors.accent, size: MfSize.icon),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FittedBox(child: Text(value, style: MfType.headline.copyWith(color: context.colors.onSurface))),
              Text(label, style: context.text.labelMedium),
            ]),
          ]),
        ),
      );
}

/// GitHub-style heatmap of the last ~6 months (weeks as columns).
class _ActivityCalendar extends StatelessWidget {
  const _ActivityCalendar({required this.activity});
  final List<DayActivity> activity;

  @override
  Widget build(BuildContext context) {
    final byDay = {for (final a in activity) DateTime(a.day.year, a.day.month, a.day.day): a};
    final maxCh = activity.fold<int>(1, (m, a) => a.chapters > m ? a.chapters : m);
    final today = DateTime.now();
    final end = DateTime(today.year, today.month, today.day);
    const weeks = 26;
    final start = end.subtract(Duration(days: end.weekday - 1 + (weeks - 1) * 7));
    final empty = context.colors.surfaceContainer;

    return LayoutBuilder(builder: (context, box) {
      final cell = ((box.maxWidth - (weeks - 1) * 3) / weeks).clamp(6.0, 16.0);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var w = 0; w < weeks; w++)
              Padding(
                padding: const EdgeInsets.only(right: 3),
                child: Column(children: [
                  for (var d = 0; d < 7; d++)
                    Builder(builder: (context) {
                      final day = start.add(Duration(days: w * 7 + d));
                      if (day.isAfter(end)) return SizedBox(width: cell, height: cell + 3);
                      final a = byDay[day];
                      final t = a == null ? 0.0 : (a.chapters / maxCh).clamp(0.2, 1.0);
                      return Tooltip(
                        message: '${formatDate(day)}: ${a?.chapters ?? 0} гл., ${formatDuration(a?.seconds ?? 0)}',
                        child: Container(
                          width: cell,
                          height: cell,
                          margin: const EdgeInsets.only(bottom: 3),
                          decoration: BoxDecoration(
                            color: a == null ? empty : Color.lerp(MfColors.accentSoft, MfColors.accent, t),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      );
                    }),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: MfSpace.sm),
        Text(activity.isEmpty ? 'Начните читать — здесь появится ваша активность' : 'Последние 6 месяцев',
            style: context.text.labelMedium),
      ]);
    });
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.label, required this.value, required this.total});
  final String label;
  final int value;
  final int total;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: MfSpace.md),
        child: Row(children: [
          SizedBox(width: 110, child: Text(label, style: context.text.bodyMedium)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(MfRadius.pill),
              child: LinearProgressIndicator(value: total == 0 ? 0 : value / total, minHeight: 8),
            ),
          ),
          SizedBox(width: 40, child: Text('$value', textAlign: TextAlign.end, style: context.text.labelLarge)),
        ]),
      );
}
