import 'package:dio/dio.dart';

import '../../core/network/api_client.dart';
import '../models/library.dart';
import '../models/manga.dart';
import 'catalog_api.dart';

/// A title found by its plot description.
class PlotHit {
  const PlotHit({required this.card, required this.similarity, this.snippet = '', this.genres = const []});
  final MangaCard card;
  final double similarity;
  final String snippet;
  final List<String> genres;
}

/// A card in «Для вас» / «Похожие» with why it is there.
class FeedItem {
  const FeedItem(this.card, this.reason);
  final MangaCard card;
  final String reason;
}

class FeedSection {
  const FeedSection({required this.key, required this.title, required this.items});
  final String key;
  final String title;
  final List<FeedItem> items;
}

List<FeedItem> _feedItems(List raw) {
  final maps = [for (final x in raw) (x as Map).cast<String, dynamic>()];
  final cards = parseSearchResults({'items': maps}).items;
  return [
    for (var i = 0; i < cards.length && i < maps.length; i++) FeedItem(cards[i], (maps[i]['reason'] as String?) ?? ''),
  ];
}

/// `/search/plot`, `/manga/{s}/{m}/similar`, `/discover/for-you`.
class DiscoverApi {
  DiscoverApi(this.client);
  final ApiClient client;

  Future<({List<PlotHit> items, int indexed})> plotSearch(String q, {bool includeNsfw = false, CancelToken? cancel}) =>
      client.get('/search/plot', query: {'q': q, 'include_nsfw': includeNsfw}, cancel: cancel, parse: (d) {
        final m = (d as Map).cast<String, dynamic>();
        final raw = [for (final x in m['items'] as List) (x as Map).cast<String, dynamic>()];
        final cards = parseSearchResults({'items': raw}).items;
        return (
          items: [
            for (var i = 0; i < cards.length; i++)
              PlotHit(
                card: cards[i],
                similarity: (raw[i]['similarity'] as num?)?.toDouble() ?? 0,
                snippet: (raw[i]['snippet'] as String?) ?? '',
                genres: [for (final g in (raw[i]['genres'] as List?) ?? const []) g.toString()],
              ),
          ],
          indexed: (m['indexed'] as num?)?.toInt() ?? 0,
        );
      });

  Future<List<FeedItem>> similar(String sourceId, String mangaId, {String title = '', bool includeNsfw = false}) =>
      client.get('/manga/$sourceId/$mangaId/similar',
          query: {'title': title, 'include_nsfw': includeNsfw},
          parse: (d) => _feedItems(((d as Map)['items'] as List?) ?? const []));

  /// Seeds: what the reader likes (recent first); known: the whole library, never suggested back.
  Future<List<FeedSection>> forYou(List<LibraryEntry> seeds, List<String> known, {bool includeNsfw = false}) =>
      client.post('/discover/for-you', body: {
        'seeds': [
          for (final e in seeds)
            {'source_id': e.sourceId, 'manga_id': e.mangaId, 'title': e.title, 'weight': seedWeight(e)},
        ],
        'known': known,
        'include_nsfw': includeNsfw,
      }, parse: (d) => [
            for (final s in ((d as Map)['sections'] as List?) ?? const [])
              FeedSection(
                key: (s as Map)['key'] as String? ?? '',
                title: s['title'] as String? ?? '',
                items: _feedItems((s['items'] as List?) ?? const []),
              ),
          ]);

  /// Favourites and titles being read say the most about taste; planned ones a little.
  static double seedWeight(LibraryEntry e) {
    var w = switch (e.status) {
      LibraryStatus.completed => 2.5,
      LibraryStatus.reading => 2.0,
      LibraryStatus.onHold => 1.0,
      LibraryStatus.planned => 0.5,
      LibraryStatus.dropped => 0.0,
    };
    if (e.isFavorite) w += 1.5;
    return w;
  }
}
