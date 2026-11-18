import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../data/models/manga.dart';
import '../../data/remote/catalog_api.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/states.dart';

/// Taste profile: the genres that occur most in the library (from cached title details).
Future<List<String>> topLibraryGenres(Ref ref, {int take = 2}) async {
  final lib = await ref.read(libraryRepositoryProvider).all();
  final cache = ref.read(titleCacheDaoProvider);
  final counts = <String, double>{};
  for (final e in lib.take(80)) {
    final t = await cache.get(e.sourceId, e.mangaId);
    if (t == null) continue;
    // favourites and titles being read weigh more
    final w = (e.isFavorite ? 2.0 : 1.0) * (e.lastReadAt != null ? 1.5 : 1.0);
    for (final g in t.$1.manga.genres) {
      final name = g.trim();
      if (name.isEmpty) continue;
      counts[name] = (counts[name] ?? 0) + w;
    }
  }
  final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return [for (final e in sorted.take(take)) e.key];
}

/// "Похоже на то, что вы читаете": popular titles in your top genres you don't have yet.
final recommendationsProvider = FutureProvider<(List<String>, List<MangaCard>)>((ref) async {
  ref.keepAlive();
  final genres = await topLibraryGenres(ref);
  if (genres.isEmpty) return (const <String>[], const <MangaCard>[]);
  final lib = await ref.read(libraryRepositoryProvider).all();
  final owned = {for (final e in lib) '${e.sourceId}|${e.mangaId}', for (final e in lib) e.title.toLowerCase()};
  final catalog = ref.read(catalogRepositoryProvider);
  final lists = <List<MangaCard>>[];
  for (final g in genres) {
    try {
      final r = await catalog.search('', filters: CatalogFilters(genres: [g]));
      lists.add(r.items);
    } catch (_) {}
  }
  // interleave genres, drop what's already in the library
  final out = <MangaCard>[];
  final seen = <String>{};
  for (var i = 0; out.length < 20 && lists.any((l) => i < l.length); i++) {
    for (final l in lists) {
      if (i >= l.length) continue;
      final c = l[i];
      final hits = [c, ...c.alsoIn];
      if (hits.any((h) => owned.contains('${h.sourceId}|${h.id}')) || owned.contains(c.title.toLowerCase())) continue;
      if (seen.add(c.title.toLowerCase())) out.add(c);
    }
  }
  return (genres, out);
});

class RecommendationsSection extends ConsumerWidget {
  const RecommendationsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(recommendationsProvider).valueOrNull;
    if (r == null || r.$2.length < 3) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(title: 'Похоже на то, что вы читаете', subtitle: 'по жанрам: ${r.$1.join(', ').toLowerCase()}'),
      CoverCarousel(
        items: r.$2,
        heroPrefix: 'rec',
        subtitleOf: (c) => c.sourceName,
        onTap: (c) => context.push(Routes.title(c.sourceId, c.id)),
      ),
    ]);
  }
}
