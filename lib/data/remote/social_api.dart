import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/image_urls.dart';
import '../models/manga.dart';
import 'catalog_api.dart';

Map<String, dynamic> _m(dynamic d) => (d as Map).cast<String, dynamic>();
List<Map<String, dynamic>> _l(dynamic d) => [for (final x in d as List) _m(x)];
DateTime? _dt(dynamic v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

class PublicUser {
  const PublicUser({required this.id, required this.username, this.displayName});
  final String id, username;
  final String? displayName;
  String get name => (displayName?.isNotEmpty ?? false) ? displayName! : username;

  factory PublicUser.fromJson(Map<String, dynamic> j) =>
      PublicUser(id: j['id'] as String, username: j['username'] as String, displayName: j['display_name'] as String?);
}

/// A title someone read / rated / recommended.
class TitleRef {
  const TitleRef({required this.sourceId, required this.mangaId, required this.title, this.coverUrl = '', this.chapterTitle, this.at});
  final String sourceId, mangaId, title, coverUrl;
  final String? chapterTitle;
  final DateTime? at;

  factory TitleRef.fromJson(Map<String, dynamic> j) => TitleRef(
        sourceId: j['source_id'] as String,
        mangaId: j['manga_id'] as String,
        title: (j['manga_title'] as String?) ?? '',
        coverUrl: ImageUrls.fix((j['cover_url'] as String?) ?? ''),
        chapterTitle: j['chapter_title'] as String?,
        at: _dt(j['read_at'] ?? j['updated_at'] ?? j['created_at'] ?? j['at']),
      );
}

class Friend {
  const Friend({required this.user, this.reading});
  final PublicUser user;
  final TitleRef? reading;
}

class FriendRequest {
  const FriendRequest(this.id, this.user, this.incoming);
  final String id;
  final PublicUser user;
  final bool incoming;
}

class FriendsData {
  const FriendsData(this.friends, this.incoming, this.outgoing);
  final List<Friend> friends;
  final List<FriendRequest> incoming, outgoing;
}

class Rated {
  const Rated({required this.title, required this.score, this.review = '', this.user});
  final TitleRef title;
  final int score;
  final String review;
  final PublicUser? user;

  factory Rated.fromJson(Map<String, dynamic> j) => Rated(
        title: TitleRef.fromJson(j),
        score: (j['score'] as num).toInt(),
        review: (j['review'] as String?) ?? '',
        user: j['user'] == null ? null : PublicUser.fromJson(_m(j['user'])),
      );
}

class TitleRatings {
  const TitleRatings({this.mine, this.friends = const [], this.average, this.count = 0});
  final Rated? mine;
  final List<Rated> friends;
  final double? average;
  final int count;
}

class ActivityItem {
  const ActivityItem({required this.kind, required this.user, required this.title, this.score});
  final String kind; // read | rated
  final PublicUser user;
  final TitleRef title;
  final int? score;
}

class FriendProfile {
  const FriendProfile(this.user, this.reading, this.ratings, this.chapters30d);
  final PublicUser user;
  final List<TitleRef> reading;
  final List<Rated> ratings;
  final int chapters30d;
}

class RecommendationItem {
  const RecommendationItem({required this.id, required this.from, required this.title, this.message = '', this.seen = false});
  final String id;
  final PublicUser? from;
  final TitleRef title;
  final String message;
  final bool seen;
}

class CommentItem {
  const CommentItem({
    required this.id,
    required this.user,
    required this.text,
    required this.likes,
    required this.liked,
    required this.mine,
    required this.createdAt,
    this.pageIndex,
  });
  final String id, text;
  final PublicUser? user;
  final int likes;
  final bool liked, mine;
  final DateTime createdAt;
  final int? pageIndex;

  factory CommentItem.fromJson(Map<String, dynamic> j) => CommentItem(
        id: j['id'] as String,
        user: j['user'] == null ? null : PublicUser.fromJson(_m(j['user'])),
        text: j['text'] as String,
        likes: (j['likes'] as num?)?.toInt() ?? 0,
        liked: j['liked'] as bool? ?? false,
        mine: j['mine'] as bool? ?? false,
        createdAt: _dt(j['created_at']) ?? DateTime.now(),
        pageIndex: (j['page_index'] as num?)?.toInt(),
      );

  CommentItem copyWith({int? likes, bool? liked}) => CommentItem(
      id: id, user: user, text: text, likes: likes ?? this.likes, liked: liked ?? this.liked, mine: mine,
      createdAt: createdAt, pageIndex: pageIndex);
}

class TrackerInfo {
  const TrackerInfo({
    required this.service,
    required this.name,
    required this.configured,
    required this.connected,
    this.username,
    this.lastError,
    this.redirectUri = '',
  });
  final String service, name, redirectUri;
  final bool configured, connected;
  final String? username, lastError;

  factory TrackerInfo.fromJson(Map<String, dynamic> j) => TrackerInfo(
        service: j['service'] as String,
        name: j['name'] as String,
        configured: j['configured'] as bool? ?? false,
        connected: j['connected'] as bool? ?? false,
        username: j['username'] as String?,
        lastError: j['last_error'] as String?,
        redirectUri: j['redirect_uri'] as String? ?? '',
      );
}

class TrackerLinkInfo {
  const TrackerLinkInfo({required this.service, required this.name, this.remoteId, this.remoteTitle = '', this.remoteUrl = '', this.chaptersSent, this.searched = false});
  final String service, name, remoteTitle, remoteUrl;
  final String? remoteId;
  final int? chaptersSent;
  final bool searched;

  factory TrackerLinkInfo.fromJson(Map<String, dynamic> j) => TrackerLinkInfo(
        service: j['service'] as String,
        name: j['name'] as String,
        remoteId: j['remote_id'] as String?,
        remoteTitle: (j['remote_title'] as String?) ?? '',
        remoteUrl: (j['remote_url'] as String?) ?? '',
        chaptersSent: (j['chapters_sent'] as num?)?.toInt(),
        searched: j['searched'] as bool? ?? false,
      );
}

class TrackerCandidate {
  const TrackerCandidate({required this.remoteId, required this.title, this.cover = '', this.chapters, this.year, this.url = '', this.altTitles = const []});
  final String remoteId, title, cover, url;
  final int? chapters, year;
  final List<String> altTitles;

  factory TrackerCandidate.fromJson(Map<String, dynamic> j) => TrackerCandidate(
        remoteId: j['remote_id'] as String,
        title: j['title'] as String,
        cover: (j['cover'] as String?) ?? '',
        chapters: (j['chapters'] as num?)?.toInt(),
        year: (j['year'] as num?)?.toInt(),
        url: (j['url'] as String?) ?? '',
        altTitles: [for (final t in (j['alt_titles'] as List?) ?? const []) t as String],
      );
}

class RoomInfo {
  const RoomInfo({
    required this.code,
    required this.sourceId,
    required this.mangaId,
    required this.mangaTitle,
    required this.chapterId,
    required this.chapterTitle,
    required this.host,
    this.coverUrl = '',
    this.page = 0,
    this.members = const [],
  });
  final String code, sourceId, mangaId, mangaTitle, chapterId, chapterTitle, host, coverUrl;
  final int page;
  final List<String> members;

  factory RoomInfo.fromJson(Map<String, dynamic> j) {
    final st = j['state'] is Map ? _m(j['state']) : const <String, dynamic>{};
    return RoomInfo(
      code: j['code'] as String,
      sourceId: j['source_id'] as String,
      mangaId: j['manga_id'] as String,
      mangaTitle: (j['manga_title'] as String?) ?? '',
      chapterId: (st['chapter_id'] as String?) ?? j['chapter_id'] as String,
      chapterTitle: (st['chapter_title'] as String?) ?? (j['chapter_title'] as String?) ?? '',
      host: (j['host'] as String?) ?? '',
      coverUrl: ImageUrls.fix((j['cover_url'] as String?) ?? ''),
      page: (st['page'] as num?)?.toInt() ?? 0,
      members: [for (final m in (j['members'] as List?) ?? const []) m as String],
    );
  }
}

class LookupMatch {
  const LookupMatch({required this.title, this.part = '', this.chapterNumber, required this.similarity, this.thumbnail = '',
      this.isManga = false, this.engine = '', this.names = const []});
  final String title, part, thumbnail, engine;
  final double? chapterNumber;
  final double similarity;
  final bool isManga;

  /// Alternative titles (Russian first when known) — the best query for our sources.
  final List<String> names;
  String get searchName => names.isNotEmpty ? names.first : title;

  factory LookupMatch.fromJson(Map<String, dynamic> j) => LookupMatch(
        title: j['title'] as String,
        engine: (j['engine'] as String?) ?? '',
        names: [for (final n in (j['names'] as List?) ?? const []) n.toString()],
        part: (j['part'] as String?) ?? '',
        chapterNumber: (j['chapter_number'] as num?)?.toDouble(),
        similarity: (j['similarity'] as num).toDouble(),
        thumbnail: (j['thumbnail'] as String?) ?? '',
        isManga: j['is_manga'] as bool? ?? false,
      );
}

/// One image-search engine's outcome: ok / nothing / no_key / error.
class LookupEngine {
  const LookupEngine(this.name, this.status, this.detail);
  final String name, status, detail;
  factory LookupEngine.fromJson(Map<String, dynamic> j) =>
      LookupEngine(j['name'] as String? ?? '', j['status'] as String? ?? '', j['detail'] as String? ?? '');
}

class SocialApi {
  SocialApi(this.client);
  final ApiClient client;

  // ---------------------------------------------------------------- friends
  Future<FriendsData> friends() => client.get('/friends', parse: (d) {
        final m = _m(d);
        return FriendsData(
          [
            for (final f in _l(m['friends']))
              Friend(user: PublicUser.fromJson(_m(f['user'])), reading: f['reading'] == null ? null : TitleRef.fromJson(_m(f['reading'])))
          ],
          [for (final r in _l(m['incoming'])) FriendRequest(r['id'] as String, PublicUser.fromJson(_m(r['user'])), true)],
          [for (final r in _l(m['outgoing'])) FriendRequest(r['id'] as String, PublicUser.fromJson(_m(r['user'])), false)],
        );
      });

  Future<String> addFriend(String username) =>
      client.post('/friends', body: {'username': username}, parse: (d) => _m(d)['message'] as String);
  Future<void> acceptFriend(String requestId) => client.post('/friends/requests/$requestId/accept', parse: (_) {});
  Future<void> dropRequest(String requestId) => client.delete('/friends/requests/$requestId');
  Future<void> unfriend(String userId) => client.delete('/friends/$userId');

  Future<List<ActivityItem>> activity() => client.get('/friends/activity', parse: (d) => [
        for (final i in _l(_m(d)['items']))
          ActivityItem(
            kind: i['kind'] as String,
            user: PublicUser.fromJson(_m(i['user'])),
            title: TitleRef.fromJson(i),
            score: (i['score'] as num?)?.toInt(),
          )
      ]);

  Future<FriendProfile> profile(String userId) => client.get('/friends/$userId/profile', parse: (d) {
        final m = _m(d);
        return FriendProfile(
          PublicUser.fromJson(_m(m['user'])),
          [for (final r in _l(m['reading'])) TitleRef.fromJson(r)],
          [for (final r in _l(m['ratings'])) Rated.fromJson(r)],
          (m['chapters_30d'] as num?)?.toInt() ?? 0,
        );
      });

  // ---------------------------------------------------------------- ratings
  Future<TitleRatings> titleRatings(String sourceId, String mangaId) => client.get('/ratings/title',
      query: {'source_id': sourceId, 'manga_id': mangaId},
      parse: (d) {
        final m = _m(d);
        return TitleRatings(
          mine: m['mine'] == null ? null : Rated.fromJson(_m(m['mine'])),
          friends: [for (final r in _l(m['friends'])) Rated.fromJson(r)],
          average: (m['average'] as num?)?.toDouble(),
          count: (m['count'] as num?)?.toInt() ?? 0,
        );
      });

  Future<void> rate(MangaDetails m, int score, {String review = ''}) => client.put('/ratings', body: {
        'source_id': m.sourceId,
        'manga_id': m.id,
        'manga_title': m.title,
        'cover_url': m.coverUrl,
        'score': score,
        'review': review,
      }, parse: (_) {});

  Future<void> unrate(String sourceId, String mangaId) =>
      client.delete('/ratings', query: {'source_id': sourceId, 'manga_id': mangaId});

  // -------------------------------------------------------- recommendations
  Future<void> recommend(MangaDetails m, List<String> userIds, String message) => client.post('/recommendations', body: {
        'to_user_ids': userIds,
        'source_id': m.sourceId,
        'manga_id': m.id,
        'manga_title': m.title,
        'cover_url': m.coverUrl,
        'message': message,
      }, parse: (_) {});

  Future<(List<RecommendationItem>, int)> recommendations() => client.get('/recommendations', parse: (d) {
        final m = _m(d);
        return (
          [
            for (final r in _l(m['items']))
              RecommendationItem(
                id: r['id'] as String,
                from: r['from'] == null ? null : PublicUser.fromJson(_m(r['from'])),
                title: TitleRef.fromJson(r),
                message: (r['message'] as String?) ?? '',
                seen: r['seen'] as bool? ?? false,
              )
          ],
          (m['unseen'] as num?)?.toInt() ?? 0,
        );
      });

  Future<void> recommendationsSeen() => client.post('/recommendations/seen', parse: (_) {});

  // ---------------------------------------------------------------- comments
  Future<({List<CommentItem> items, int total, bool hasMore})> comments(String sourceId, String chapterId, {DateTime? before}) =>
      client.get('/comments', query: {
        'source_id': sourceId,
        'chapter_id': chapterId,
        if (before != null) 'before': before.toUtc().toIso8601String(),
      }, parse: (d) {
        final m = _m(d);
        return (
          items: [for (final c in _l(m['items'])) CommentItem.fromJson(c)],
          total: (m['total'] as num?)?.toInt() ?? 0,
          hasMore: m['has_more'] as bool? ?? false,
        );
      });

  Future<int> commentCount(String sourceId, String chapterId) => client.get('/comments/count',
      query: {'source_id': sourceId, 'chapter_id': chapterId}, parse: (d) => (_m(d)['count'] as num).toInt());

  Future<CommentItem> addComment(String sourceId, String mangaId, String chapterId, String text, {int? pageIndex}) =>
      client.post('/comments', body: {
        'source_id': sourceId,
        'manga_id': mangaId,
        'chapter_id': chapterId,
        'text': text,
        if (pageIndex != null) 'page_index': pageIndex,
      }, parse: (d) => CommentItem.fromJson(_m(d)));

  Future<void> deleteComment(String id) => client.delete('/comments/$id');

  Future<(int, bool)> likeComment(String id) => client.post('/comments/$id/like', parse: (d) {
        final m = _m(d);
        return ((m['likes'] as num).toInt(), m['liked'] as bool);
      });

  // ---------------------------------------------------------------- trackers
  Future<List<TrackerInfo>> trackers() =>
      client.get('/trackers', parse: (d) => [for (final t in _l(_m(d)['items'])) TrackerInfo.fromJson(t)]);

  Future<String> trackerAuthorizeUrl(String service) =>
      client.post('/trackers/$service/authorize', parse: (d) => _m(d)['url'] as String);

  Future<void> disconnectTracker(String service) => client.delete('/trackers/$service');

  Future<void> syncTrackers() => client.post('/trackers/sync', parse: (_) {});

  Future<List<TrackerLinkInfo>> trackerLinks(String sourceId, String mangaId) => client.get('/trackers/links',
      query: {'source_id': sourceId, 'manga_id': mangaId},
      parse: (d) => [for (final t in _l(_m(d)['items'])) TrackerLinkInfo.fromJson(t)]);

  Future<List<TrackerCandidate>> trackerSearch(String service, String q) => client.get('/trackers/$service/search',
      query: {'q': q}, parse: (d) => [for (final t in _l(_m(d)['items'])) TrackerCandidate.fromJson(t)]);

  Future<void> setTrackerLink(String service, String sourceId, String mangaId, TrackerCandidate? c) =>
      client.put('/trackers/$service/links', body: {
        'source_id': sourceId,
        'manga_id': mangaId,
        'remote_id': c?.remoteId,
        'remote_title': c?.title ?? '',
        'remote_url': c?.url ?? '',
        'remote_chapters': c?.chapters,
      }, parse: (_) {});

  // ------------------------------------------------------------------- rooms
  Future<RoomInfo> createRoom({
    required MangaDetails manga,
    required Chapter chapter,
    required int page,
  }) =>
      client.post('/rooms', body: {
        'source_id': manga.sourceId,
        'manga_id': manga.id,
        'manga_title': manga.title,
        'cover_url': manga.coverUrl,
        'chapter_id': chapter.id,
        'chapter_title': chapter.title,
        'page': page,
      }, parse: (d) => RoomInfo.fromJson(_m(d)));

  Future<RoomInfo> room(String code) => client.get('/rooms/${code.trim().toUpperCase()}', parse: (d) => RoomInfo.fromJson(_m(d)));

  /// ws(s)://…/api/v1/rooms/<code>/ws
  Uri roomSocket(String code, String token) {
    final base = Uri.parse(client.baseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/rooms/${code.toUpperCase()}/ws',
      queryParameters: {'token': token},
    );
  }

  // ------------------------------------------------------------------ lookup
  Future<({List<LookupMatch> matches, List<MangaCard> results, List<LookupEngine> engines})> lookupImage(Uint8List image, {String contentType = 'image/jpeg'}) async {
    try {
      final res = await client.dio.post<dynamic>('/lookup/image',
          data: Stream.fromIterable([image]),
          options: Options(
            contentType: contentType,
            headers: {Headers.contentLengthHeader: image.length},
            receiveTimeout: const Duration(seconds: 60),
          ));
      final m = _m(res.data);
      return (
        matches: [for (final x in _l(m['matches'])) LookupMatch.fromJson(x)],
        results: m['results'] is Map ? parseSearchResults(_m(m['results'])).items : const <MangaCard>[],
        engines: [for (final x in _l(m['engines'] ?? const [])) LookupEngine.fromJson(x)],
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}
