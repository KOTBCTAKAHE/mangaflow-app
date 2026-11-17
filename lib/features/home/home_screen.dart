import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/manga.dart';
import '../../data/models/reading.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/states.dart';

final sourcesProvider = FutureProvider<List<SourceInfo>>((ref) {
  ref.watch(settingsProvider.select((s) => (s.showNsfw, s.disabledSources, s.apiBaseUrl)));
  return ref.watch(catalogRepositoryProvider).enabledSources();
});

final homeFeedProvider = FutureProvider.family<(List<HomeSection>, List<SourceFailure>), String>((ref, sourceId) {
  ref.watch(authProvider);
  return ref.watch(catalogRepositoryProvider).home(sourceId);
});

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(sourcesProvider);
    final primary = ref.watch(settingsProvider.select((s) => s.primarySource));
    final list = sources.valueOrNull ?? const <SourceInfo>[];
    final current = list.where((s) => s.id == primary).firstOrNull ?? list.firstOrNull;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(sourcesProvider);
          if (current != null) ref.invalidate(homeFeedProvider(current.id));
          ref.invalidate(continueReadingProvider);
          await ref.read(syncEngineProvider).sync();
        },
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              floating: true,
              snap: true,
              titleSpacing: MfSpace.gutter,
              title: Row(children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(color: MfColors.accent, borderRadius: BorderRadius.circular(MfRadius.sm)),
                  child: const Icon(Icons.auto_stories_rounded, size: 18, color: MfColors.onAccent),
                ),
                const SizedBox(width: MfSpace.sm),
                Text('MangaFlow', style: MfType.title.copyWith(color: context.colors.onSurface)),
              ]),
              actions: [
                _UpdatesBell(),
                const SizedBox(width: MfSpace.xs),
              ],
            ),
            const SliverToBoxAdapter(child: _ContinueReading()),
            if (sources.hasError && list.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: ErrorState(error: sources.error!, onRetry: () => ref.invalidate(sourcesProvider)),
              )
            else if (current == null)
              const SliverToBoxAdapter(child: Column(children: [SizedBox(height: MfSpace.xxl), CarouselSkeleton()]))
            else ...[
              SliverToBoxAdapter(child: _SourceSwitcher(sources: list, current: current)),
              _Feed(source: current),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: MfSpace.huge)),
          ],
        ),
      ),
    );
  }
}

class _UpdatesBell extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(unseenUpdatesProvider).valueOrNull ?? 0;
    return IconButton(
      tooltip: 'Обновления',
      onPressed: () => context.push('/updates'),
      icon: Badge(isLabelVisible: n > 0, label: Text('$n'), child: const Icon(Icons.notifications_none_rounded)),
    );
  }
}

class _ContinueReading extends ConsumerWidget {
  const _ContinueReading();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(continueReadingProvider).valueOrNull ?? const <ContinueItem>[];
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(title: 'Продолжить чтение', onMore: () => context.push('/history')),
      SizedBox(
        height: 132,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: MfSpace.md),
          itemBuilder: (context, i) => _ContinueCard(item: items[i]),
        ),
      ),
    ]);
  }
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.item});
  final ContinueItem item;

  @override
  Widget build(BuildContext context) {
    final width = (MediaQuery.sizeOf(context).width * 0.78).clamp(260.0, 360.0);
    return SizedBox(
      width: width,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push(Routes.reader(item.sourceId, item.mangaId, item.chapterId)),
          onLongPress: () => context.push(Routes.title(item.sourceId, item.mangaId)),
          child: Padding(
            padding: const EdgeInsets.all(MfSpace.md),
            child: Row(children: [
              MangaCover(url: item.coverUrl, width: 76, radius: MfRadius.sm, thumbWidth: 160),
              const SizedBox(width: MfSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.titleMedium),
                    const SizedBox(height: MfSpace.xs),
                    Text(item.chapterTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodySmall),
                    const SizedBox(height: MfSpace.md),
                    Row(children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(MfRadius.pill),
                          child: LinearProgressIndicator(value: item.fraction, minHeight: 4),
                        ),
                      ),
                      const SizedBox(width: MfSpace.sm),
                      Text('${(item.fraction * 100).round()}%', style: context.text.labelMedium),
                    ]),
                  ],
                ),
              ),
              const SizedBox(width: MfSpace.sm),
              const Icon(Icons.play_arrow_rounded, color: MfColors.accent),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SourceSwitcher extends ConsumerWidget {
  const _SourceSwitcher({required this.sources, required this.current});
  final List<SourceInfo> sources;
  final SourceInfo current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.lg, MfSpace.gutter, 0),
        itemCount: sources.length,
        separatorBuilder: (_, __) => const SizedBox(width: MfSpace.sm),
        itemBuilder: (context, i) {
          final s = sources[i];
          return ChoiceChip(
            label: Text(s.name),
            selected: s.id == current.id,
            showCheckmark: false,
            onSelected: (_) => ref.read(settingsProvider.notifier).update((st) => st.copyWith(primarySource: s.id)),
          );
        },
      ),
    );
  }
}

class _Feed extends ConsumerWidget {
  const _Feed({required this.source});
  final SourceInfo source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(homeFeedProvider(source.id));
    void open(MangaCard c) => context.push(Routes.title(c.sourceId, c.id));

    return feed.when(
      skipLoadingOnRefresh: true,
      loading: () => SliverList.list(children: const [
        SizedBox(height: MfSpace.xxl),
        CarouselSkeleton(),
        SizedBox(height: MfSpace.xxl),
        CarouselSkeleton(),
      ]),
      error: (e, _) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: MfSpace.xxxl),
          child: ErrorState(error: e, onRetry: () => ref.invalidate(homeFeedProvider(source.id))),
        ),
      ),
      data: (data) {
        final (sections, errors) = data;
        if (sections.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: MfSpace.xxxl),
              child: errors.isNotEmpty
                  ? EmptyState(
                      icon: Icons.public_off_rounded,
                      title: '${source.name} недоступен',
                      message: '${errors.first.message}\nВыберите другой источник выше.',
                      action: OutlinedButton(
                          onPressed: () => ref.invalidate(homeFeedProvider(source.id)), child: const Text('Повторить')),
                    )
                  : const EmptyState(icon: Icons.inbox_outlined, title: 'Пока пусто'),
            ),
          );
        }
        return SliverList.list(children: [
          for (final s in sections) ...[
            SectionHeader(
              title: s.title,
              subtitle: s.key == 'recommended' ? 'На основе вашей библиотеки' : source.name,
              onMore: () => context.push(Routes.source(source.id)),
            ),
            CoverCarousel(items: s.items, onTap: open, heroPrefix: 'home-${s.key}'),
          ],
        ]);
      },
    );
  }
}
