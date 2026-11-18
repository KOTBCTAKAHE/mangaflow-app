import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/format.dart';
import '../../data/services/year_review.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/states.dart';
import 'stats_screen.dart' show statsProvider;

final yearReviewProvider = FutureProvider.autoDispose.family<YearReview, int>((ref, year) async {
  final history = await ref.read(historyDaoProvider).all();
  final cache = ref.read(titleCacheDaoProvider);
  final genres = <String, List<String>>{};
  for (final h in history) {
    if (h.readAt.toLocal().year != year) continue;
    final k = '${h.sourceId}:${h.mangaId}';
    if (genres.containsKey(k)) continue;
    genres[k] = (await cache.get(h.sourceId, h.mangaId))?.$1.manga.genres ?? const [];
  }
  return computeYearReview(history, year, genresOf: (s, m) => genres['$s:$m'] ?? const []);
});

final achievementsProvider = FutureProvider.autoDispose<List<Achievement>>((ref) async {
  ref.watch(dataVersionProvider);
  final stats = await ref.watch(statsProvider.future);
  return computeAchievements(
    stats: stats,
    history: await ref.read(historyDaoProvider).all(),
    library: await ref.read(libraryRepositoryProvider).all(),
  );
});

const _monthsNom = ['январь', 'февраль', 'март', 'апрель', 'май', 'июнь', 'июль', 'август', 'сентябрь', 'октябрь', 'ноябрь', 'декабрь'];
const _monthsGen = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];

String plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

class YearReviewScreen extends ConsumerStatefulWidget {
  const YearReviewScreen({super.key});

  @override
  ConsumerState<YearReviewScreen> createState() => _YearReviewScreenState();
}

class _YearReviewScreenState extends ConsumerState<YearReviewScreen> {
  final _cardKey = GlobalKey();
  int _year = DateTime.now().year;
  bool _sharing = false;

  Future<void> _share(YearReview r) async {
    setState(() => _sharing = true);
    try {
      final boundary = _cardKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('${(await getTemporaryDirectory()).path}/MangaFlow_итоги_${r.year}.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'image/png')],
        text: 'Мои итоги ${r.year} в MangaFlow: ${r.chapters} ${plural(r.chapters, 'глава', 'главы', 'глав')}',
      ));
    } catch (e) {
      if (mounted) showSnack(context, 'Не получилось поделиться: $e');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final review = ref.watch(yearReviewProvider(_year));
    final now = DateTime.now().year;
    return Scaffold(
      appBar: AppBar(title: Text('Итоги $_year')),
      body: AsyncBody(
        value: review,
        onRetry: () => ref.invalidate(yearReviewProvider(_year)),
        data: (r) => ListView(padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.sm, MfSpace.gutter, MfSpace.huge), children: [
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [for (final y in [now - 1, now]) ButtonSegment(value: y, label: Text('$y'))],
            selected: {_year},
            onSelectionChanged: (v) => setState(() => _year = v.first),
          ),
          const SizedBox(height: MfSpace.lg),
          if (r.isEmpty)
            const EmptyState(icon: Icons.auto_graph_rounded, title: 'Пока пусто', message: 'Почитайте немного — здесь появятся итоги года')
          else ...[
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: RepaintBoundary(key: _cardKey, child: ReviewCard(review: r)),
              ),
            ),
            const SizedBox(height: MfSpace.lg),
            FilledButton.icon(
              onPressed: _sharing ? null : () => _share(r),
              icon: const Icon(Icons.ios_share_rounded),
              label: Text(_sharing ? 'Готовлю картинку…' : 'Поделиться карточкой'),
            ),
          ],
        ]),
      ),
    );
  }
}

/// The shareable card itself (also rendered to PNG).
class ReviewCard extends StatelessWidget {
  const ReviewCard({super.key, required this.review});
  final YearReview review;

  @override
  Widget build(BuildContext context) {
    final r = review;
    final a = MfColors.accent;
    final hours = r.seconds / 3600;
    final b = r.bingeDay;
    Widget stat(String value, String label) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            FittedBox(child: Text(value, style: MfType.display.copyWith(color: Colors.white, fontSize: 30, height: 1.1))),
            Text(label, style: MfType.caption.copyWith(color: Colors.white70)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(MfSpace.xl),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(MfRadius.xl),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(a, Colors.black, 0.15)!, Color.lerp(a, const Color(0xFF1B1030), 0.75)!, const Color(0xFF0D0E11)],
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('MangaFlow', style: MfType.label.copyWith(color: Colors.white70, letterSpacing: 1)),
          const Spacer(),
          Text('ИТОГИ ${r.year}', style: MfType.label.copyWith(color: Colors.white, letterSpacing: 2)),
        ]),
        const SizedBox(height: MfSpace.xl),
        Text('${r.chapters}', style: MfType.display.copyWith(color: Colors.white, fontSize: 64, height: 1)),
        Text('${plural(r.chapters, 'глава прочитана', 'главы прочитано', 'глав прочитано')} за год',
            style: MfType.title.copyWith(color: Colors.white)),
        const SizedBox(height: MfSpace.xl),
        Row(children: [
          stat(hours >= 1 ? hours.toStringAsFixed(hours >= 10 ? 0 : 1) : formatDuration(r.seconds), hours >= 1 ? 'часов чтения' : 'чтения'),
          stat('${r.titles}', plural(r.titles, 'тайтл', 'тайтла', 'тайтлов')),
          stat('${r.longestStreak}', 'дней подряд — рекорд'),
        ]),
        if (r.topGenres.isNotEmpty) ...[
          const SizedBox(height: MfSpace.xl),
          Text('Любимый жанр', style: MfType.caption.copyWith(color: Colors.white60)),
          Text(r.topGenres.first, style: MfType.headline.copyWith(color: Colors.white)),
          if (r.topGenres.length > 1)
            Text('а ещё ${r.topGenres.skip(1).join(' и ').toLowerCase()}', style: MfType.bodySmall.copyWith(color: Colors.white70)),
        ],
        if (r.topTitles.isNotEmpty) ...[
          const SizedBox(height: MfSpace.xl),
          Text('Топ тайтлов', style: MfType.caption.copyWith(color: Colors.white60)),
          const SizedBox(height: MfSpace.sm),
          for (final (i, t) in r.topTitles.take(3).indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: MfSpace.sm),
              child: Row(children: [
                SizedBox(width: 22, child: Text('${i + 1}', style: MfType.title.copyWith(color: Colors.white54))),
                MangaCover(url: t.coverUrl, width: 34, radius: 6, shadow: false),
                const SizedBox(width: MfSpace.md),
                Expanded(
                  child: Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: MfType.bodyStrong.copyWith(color: Colors.white)),
                ),
                Text('${t.chapters} гл.', style: MfType.caption.copyWith(color: Colors.white70)),
              ]),
            ),
        ],
        const SizedBox(height: MfSpace.md),
        Wrap(spacing: MfSpace.sm, runSpacing: MfSpace.sm, children: [
          if (b != null && r.bingeChapters >= 3)
            _Pill(Icons.whatshot_rounded, 'Самый долгий запой: ${r.bingeChapters} гл. ${b.day} ${_monthsGen[b.month - 1]}'),
          if (r.busiestMonth != null) _Pill(Icons.calendar_month_rounded, 'Самый читательский месяц — ${_monthsNom[r.busiestMonth! - 1]}'),
          if (r.nightShare >= 0.15) _Pill(Icons.nightlight_round, 'Сова: ${(r.nightShare * 100).round()}% глав ночью'),
          _Pill(Icons.event_available_rounded, 'Дней с чтением: ${r.activeDays}'),
        ]),
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(8, 5, 12, 5),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(MfRadius.pill)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Flexible(child: Text(text, style: MfType.caption.copyWith(color: Colors.white))),
        ]),
      );
}

const _achievementIcons = <String, IconData>{
  'first': Icons.menu_book_rounded,
  'ch100': Icons.auto_stories_rounded,
  'ch1000': Icons.local_library_rounded,
  'ch5000': Icons.emoji_events_rounded,
  'streak7': Icons.local_fire_department_rounded,
  'streak30': Icons.whatshot_rounded,
  'streak100': Icons.military_tech_rounded,
  'binge': Icons.bolt_rounded,
  'owl': Icons.nightlight_round,
  'hours': Icons.schedule_rounded,
  'finisher': Icons.task_alt_rounded,
  'collector': Icons.collections_bookmark_rounded,
  'explorer': Icons.explore_rounded,
};

/// Achievements grid (stats screen).
class AchievementsSection extends ConsumerWidget {
  const AchievementsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(achievementsProvider).valueOrNull;
    if (list == null) return const SizedBox.shrink();
    final done = list.where((a) => a.unlocked).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Достижения · $done из ${list.length}', style: context.text.titleLarge),
      const SizedBox(height: MfSpace.md),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 180, mainAxisExtent: 128, mainAxisSpacing: MfSpace.sm, crossAxisSpacing: MfSpace.sm),
        itemCount: list.length,
        itemBuilder: (context, i) {
          final a = list[i];
          final on = a.unlocked;
          return Container(
            padding: const EdgeInsets.all(MfSpace.md),
            decoration: BoxDecoration(
              color: on ? MfColors.accentSoft : context.colors.surfaceContainer,
              borderRadius: BorderRadius.circular(MfRadius.lg),
              border: Border.all(color: on ? MfColors.accent.withValues(alpha: 0.5) : Colors.transparent),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(_achievementIcons[a.id] ?? Icons.star_rounded, color: on ? MfColors.accent : context.textTertiary),
              const SizedBox(height: MfSpace.xs),
              Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: MfType.label.copyWith(color: on ? context.colors.onSurface : context.textTertiary)),
              Text(a.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: MfType.caption.copyWith(color: context.textTertiary)),
              const Spacer(),
              if (!on)
                ClipRRect(
                  borderRadius: BorderRadius.circular(MfRadius.pill),
                  child: LinearProgressIndicator(value: a.fraction, minHeight: 4),
                ),
            ]),
          );
        },
      ),
    ]);
  }
}
