import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/library.dart';
import '../../data/models/manga.dart';
import '../../data/remote/discover_api.dart';
import '../../widgets/effects.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/states.dart';
import 'recommendations.dart';

/// «Для вас»: plot neighbours of what you read, what readers like you read, friends, popular.
final forYouProvider = FutureProvider<List<FeedSection>>((ref) async {
  ref.keepAlive();
  final lib = [for (final e in await ref.read(libraryRepositoryProvider).all()) if (!e.deleted) e];
  if (lib.isEmpty) return const <FeedSection>[];
  DateTime at(LibraryEntry e) => e.lastReadAt ?? e.updatedAt;
  lib.sort((a, b) => at(b).compareTo(at(a)));
  final seeds = [for (final e in lib) if (DiscoverApi.seedWeight(e) > 0) e].take(40).toList();
  return ref.read(discoverApiProvider).forYou(
        seeds,
        [for (final e in lib.take(2000)) e.title],
        includeNsfw: ref.read(settingsProvider).showNsfw,
      );
});

void _open(BuildContext context, MangaCard c) => context.push(Routes.title(c.sourceId, c.id));

class _FeedRow extends StatelessWidget {
  const _FeedRow({required this.section, required this.heroPrefix, this.label, this.onMore});
  final FeedSection section;
  final String heroPrefix;
  final String? label;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final reasons = {for (final i in section.items) i.card.key: i.reason};
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(title: section.title, subtitle: label, onMore: onMore),
      CoverCarousel(
        items: [for (final i in section.items) i.card],
        heroPrefix: heroPrefix,
        subtitleOf: (c) => reasons[c.key],
        onTap: (c) => _open(context, c),
      ),
    ]);
  }
}

/// Home: the first rows of the feed; genre picks when the server has nothing yet.
class ForYouHomeSection extends ConsumerWidget {
  const ForYouHomeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(forYouProvider);
    final sections = feed.valueOrNull ?? const <FeedSection>[];
    if (feed.isLoading && sections.isEmpty) return const SizedBox.shrink();
    if (sections.isEmpty) return const RecommendationsSection();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final (i, s) in sections.take(2).indexed)
        _FeedRow(
          section: s,
          heroPrefix: 'fy-home-$i',
          label: i == 0 ? 'Для вас' : null,
          onMore: () => context.push(Routes.forYou),
        ),
    ]);
  }
}

class ForYouScreen extends ConsumerWidget {
  const ForYouScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(forYouProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Для вас')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(forYouProvider.future),
        child: feed.when(
          loading: () => ListView(children: const [SizedBox(height: MfSpace.xxl), CarouselSkeleton(), CarouselSkeleton()]),
          error: (e, _) => ListView(children: [
            SizedBox(
              height: 420,
              child: ErrorState(error: e, onRetry: () => ref.invalidate(forYouProvider)),
            ),
          ]),
          data: (sections) => sections.isEmpty
              ? ListView(children: const [
                  SizedBox(
                    height: 420,
                    child: EmptyState(
                      icon: Icons.auto_awesome_rounded,
                      title: 'Пока нечего посоветовать',
                      message: 'Добавьте в библиотеку пару тайтлов, которые нравятся, — и здесь появятся рекомендации',
                    ),
                  ),
                ])
              : ListView(
                  padding: EdgeInsets.only(bottom: bottomInset(context, MfSpace.huge)),
                  children: [
                    for (final (i, s) in sections.indexed) _FeedRow(section: s, heroPrefix: 'fy-$i'),
                  ],
                ),
        ),
      ),
    );
  }
}

final similarTitlesProvider = FutureProvider.autoDispose.family<List<FeedItem>, (String, String, String)>((ref, k) {
  return ref.read(discoverApiProvider).similar(k.$1, k.$2, title: k.$3, includeNsfw: ref.read(settingsProvider).showNsfw);
});

/// Title screen: «Похожие» — by plot and by what readers of this title also read.
class SimilarTitlesSection extends ConsumerWidget {
  const SimilarTitlesSection({super.key, required this.sourceId, required this.mangaId, required this.title});
  final String sourceId, mangaId, title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(similarTitlesProvider((sourceId, mangaId, title))).valueOrNull ?? const <FeedItem>[];
    if (items.length < 2) return const SizedBox.shrink();
    return _FeedRow(
      section: FeedSection(key: 'similar', title: 'Похожие', items: items),
      heroPrefix: 'similar-$mangaId',
    );
  }
}
