import 'dart:async';

import '../models/manga.dart';
import '../repositories/catalog_repository.dart';

/// The same title found in another source.
class SourceMatch {
  const SourceMatch({required this.card, required this.chapterCount, this.maxNumber, this.continueFrom});
  final MangaCard card;
  final int chapterCount;
  final double? maxNumber;

  /// First chapter after the one the user finished (null = nothing newer there).
  final Chapter? continueFrom;
}

String normalizeTitle(String s) =>
    s.toLowerCase().replaceAll('ё', 'е').replaceAll(RegExp(r'[^a-zа-я0-9]+', unicode: true), '');

/// Finds [m] in other sources via the global search (grouped by the server across
/// sources), then loads each candidate to compare chapter counts.
Future<List<SourceMatch>> findInOtherSources(
  CatalogRepository catalog,
  MangaDetails m, {
  double? lastRead,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final names = {normalizeTitle(m.title), for (final a in m.altTitles) normalizeTitle(a)}..remove('');
  final queries = [m.title, ...m.altTitles.where((a) => RegExp(r'[a-zA-Z]').hasMatch(a)).take(1)];
  final found = <String, MangaCard>{}; // one candidate per source
  for (final q in queries) {
    SearchResults res;
    try {
      res = await catalog.search(q).timeout(timeout);
    } catch (_) {
      continue;
    }
    for (final group in res.items) {
      final hits = [group, ...group.alsoIn];
      final isOurs = hits.any((h) => h.sourceId == m.sourceId && h.id == m.id);
      for (final h in hits) {
        if (h.sourceId == m.sourceId || found.containsKey(h.sourceId)) continue;
        if (isOurs || names.contains(normalizeTitle(h.title)) || names.contains(normalizeTitle(group.title))) {
          found[h.sourceId] = h;
        }
      }
    }
    if (found.length >= 3) break;
  }
  final matches = await Future.wait(found.values.take(6).map((card) async {
    try {
      final t = await catalog.title(card.sourceId, card.id).timeout(timeout);
      final numbers = [for (final c in t.chapters) if (c.number != null) c.number!];
      final maxN = numbers.isEmpty ? null : numbers.reduce((a, b) => a > b ? a : b);
      Chapter? next;
      for (final c in t.chapters) {
        final n = c.number;
        if (n == null) continue;
        if (lastRead == null ? (next == null || n < next.number!) : (n > lastRead && (next == null || n < next.number!))) next = c;
      }
      return SourceMatch(card: card, chapterCount: t.chapters.length, maxNumber: maxN, continueFrom: next);
    } catch (_) {
      return null;
    }
  }));
  final list = matches.whereType<SourceMatch>().toList()
    ..sort((a, b) => (b.maxNumber ?? b.chapterCount.toDouble()).compareTo(a.maxNumber ?? a.chapterCount.toDouble()));
  return list;
}
