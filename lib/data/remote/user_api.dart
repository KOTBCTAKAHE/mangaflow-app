import '../../core/network/api_client.dart';
import '../models/library.dart';
import '../models/reading.dart';
import '../models/user.dart';

typedef Synced<T> = ({List<T> items, DateTime serverTime});

/// Authenticated endpoints: profile, settings and sync.
class UserApi {
  UserApi(this.client);
  final ApiClient client;

  Synced<T> _synced<T>(dynamic d, T Function(Map<String, dynamic>) f) {
    final m = (d as Map).cast<String, dynamic>();
    return (
      items: [for (final x in m['items'] as List) f((x as Map).cast())],
      serverTime: DateTime.parse(m['server_time'] as String),
    );
  }

  Future<UserProfile> me() => client.get('/users/me', parse: (d) => UserProfile.fromJson((d as Map).cast()));

  Future<UserProfile> updateMe({String? displayName}) =>
      client.patch('/users/me', body: {'display_name': displayName}, parse: (d) => UserProfile.fromJson((d as Map).cast()));

  Future<void> changePassword(String current, String next) => client.post('/users/me/password',
      body: {'current_password': current, 'new_password': next}, parse: (_) {});

  Future<void> logoutAll() => client.post('/auth/logout-all', parse: (_) {});

  Future<void> deleteAccount(String password) => client.delete('/users/me', query: {'password': password});

  // ---- settings
  Future<({Map<String, dynamic> settings, DateTime updatedAt})> getSettings() =>
      client.get('/users/me/settings', parse: (d) {
        final m = (d as Map).cast<String, dynamic>();
        return (settings: (m['settings'] as Map).cast<String, dynamic>(), updatedAt: DateTime.parse(m['updated_at'] as String));
      });

  Future<void> putSettings(Map<String, dynamic> settings, DateTime updatedAt) => client.put('/users/me/settings',
      body: {'settings': settings, 'updated_at': updatedAt.toUtc().toIso8601String()}, parse: (_) {});

  // ---- library
  Future<Synced<LibraryEntry>> library({DateTime? since}) => client.get('/library',
      query: {'since': since?.toUtc().toIso8601String()}, parse: (d) => _synced(d, LibraryEntry.fromApi));

  Future<Synced<LibraryEntry>> syncLibrary(List<LibraryEntry> items) => client.post('/library/sync',
      body: {'items': [for (final e in items) e.toApi()]}, parse: (d) => _synced(d, LibraryEntry.fromApi));

  // ---- collections
  Future<List<Map<String, dynamic>>> collections() =>
      client.get('/collections', parse: (d) => [for (final c in d as List) (c as Map).cast<String, dynamic>()]);

  Future<Map<String, dynamic>> createCollection(String name, int position) => client.post('/collections',
      body: {'name': name, 'position': position}, parse: (d) => (d as Map).cast<String, dynamic>());

  Future<void> deleteCollection(String id) => client.delete('/collections/$id');

  Future<void> setCollectionItems(String id, List<String> add, List<String> remove) async {
    if (add.isNotEmpty) {
      await client.post('/collections/$id/items', body: {'entry_ids': add}, parse: (_) {});
    }
    if (remove.isNotEmpty) {
      await client.delete('/collections/$id/items', body: {'entry_ids': remove});
    }
  }

  Future<Map<String, String>> libraryEntryIds() => client.get('/library', parse: (d) {
        final out = <String, String>{};
        for (final e in ((d as Map)['items'] as List)) {
          final m = (e as Map).cast<String, dynamic>();
          out['${m['source_id']}:${m['manga_id']}'] = m['id'] as String;
        }
        return out;
      });

  // ---- progress & history
  Future<Synced<ChapterProgress>> progress({DateTime? since}) => client.get('/progress',
      query: {'since': since?.toUtc().toIso8601String()}, parse: (d) => _synced(d, ChapterProgress.fromApi));

  Future<void> pushProgress(List<ChapterProgress> items) => client.post('/progress/batch',
      body: {'items': [for (final p in items) p.toApi()]}, parse: (_) {});

  Future<Synced<HistoryItem>> history({DateTime? since, int limit = 500}) => client.get('/history',
      query: {'since': since?.toUtc().toIso8601String(), 'limit': limit}, parse: (d) => _synced(d, HistoryItem.fromApi));

  Future<void> pushHistory(List<HistoryItem> items) =>
      client.post('/history', body: {'items': [for (final h in items) h.toApi()]}, parse: (_) {});

  Future<void> deleteHistory(String id) => client.delete('/history/$id');

  Future<void> clearHistory() => client.delete('/history');

  // ---- updates
  Future<List<ChapterUpdate>> updates({bool unseen = false, DateTime? since}) => client.get('/updates',
      query: {'unseen': unseen, 'since': since?.toUtc().toIso8601String()},
      parse: (d) => [for (final u in d as List) ChapterUpdate.fromApi((u as Map).cast())]);

  Future<void> markUpdatesSeen({List<String>? ids, bool all = false}) =>
      client.post('/updates/seen', body: {'ids': ids, 'all': all}, parse: (_) {});

  Future<void> triggerUpdateCheck() => client.post('/updates/check', parse: (_) {});

  // ---- downloads registry
  Future<void> reportDownloads(List<Map<String, dynamic>> items) =>
      client.post('/downloads', body: {'items': items}, parse: (_) {});

  // ---- backup
  Future<Map<String, dynamic>> exportBackup() =>
      client.get('/users/me/export', parse: (d) => (d as Map).cast<String, dynamic>());

  Future<Map<String, dynamic>> importBackup(Map<String, dynamic> data) =>
      client.post('/users/me/import', body: data, parse: (d) => (d as Map).cast<String, dynamic>());
}
