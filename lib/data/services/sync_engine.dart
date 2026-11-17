import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/network/api_exception.dart';
import '../local/daos.dart';
import '../models/reading.dart';
import '../remote/user_api.dart';
import '../repositories/settings_repository.dart';

enum SyncPhase { idle, running, error, offline }

class SyncStatus {
  const SyncStatus(this.phase, {this.lastSync, this.message});
  final SyncPhase phase;
  final DateTime? lastSync;
  final String? message;
}

/// Push-then-pull synchronisation of library, collections, progress, history,
/// settings and update notifications. Safe to call often: runs are coalesced.
class SyncEngine {
  SyncEngine({
    required this.api,
    required this.library,
    required this.collections,
    required this.progress,
    required this.history,
    required this.updates,
    required this.kv,
    required this.settings,
    required this.isSignedIn,
    required this.onPulled,
    this.onNewUpdates,
  });

  final UserApi api;
  final LibraryDao library;
  final CollectionsDao collections;
  final ProgressDao progress;
  final HistoryDao history;
  final UpdatesDao updates;
  final KvDao kv;
  final SettingsController settings;
  final bool Function() isSignedIn;
  final VoidCallback onPulled;
  final void Function(List<ChapterUpdate> fresh)? onNewUpdates;

  final status = ValueNotifier(const SyncStatus(SyncPhase.idle));

  Future<void>? _running;
  bool _again = false;
  Timer? _debounce;

  /// Debounced trigger after local edits.
  void schedule({Duration delay = const Duration(seconds: 3)}) {
    if (!isSignedIn()) return;
    _debounce?.cancel();
    _debounce = Timer(delay, () => unawaited(sync()));
  }

  Future<void> sync() {
    if (!isSignedIn()) return Future.value();
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      await _once();
    } while (_again);
  }

  Future<void> _once() async {
    status.value = SyncStatus(SyncPhase.running, lastSync: status.value.lastSync);
    try {
      await _pushSettings();
      await _pushLibrary();
      await _pushProgress();
      await _pushHistory();
      await _pull();
      await _syncCollections();
      await _pullUpdates();
      final now = DateTime.now();
      await kv.set('last_sync', now.toUtc().toIso8601String());
      status.value = SyncStatus(SyncPhase.idle, lastSync: now);
      onPulled();
    } on ApiException catch (e) {
      status.value = SyncStatus(e.isOffline ? SyncPhase.offline : SyncPhase.error,
          lastSync: status.value.lastSync, message: e.userMessage);
    } catch (e) {
      status.value = SyncStatus(SyncPhase.error, lastSync: status.value.lastSync, message: e.toString());
    }
  }

  /// On first sign-in the guest's local data must be uploaded.
  Future<void> markAllDirty() async {
    await library.db.update('library', {'dirty': 1});
    await progress.db.update('progress', {'dirty': 1});
    await history.db.update('history', {'dirty': 1}, where: 'deleted = 0');
    for (final k in const ['since_library', 'since_progress', 'since_history']) {
      await kv.set(k, null);
    }
  }

  Future<DateTime?> _since(String key) async => DateTime.tryParse(await kv.get(key) ?? '');

  Future<void> _pushSettings() async {
    final s = settings.state;
    final remote = await api.getSettings();
    if (remote.updatedAt.isAfter(s.updatedAt)) {
      await settings.applyRemote(remote.settings, remote.updatedAt);
    } else if (s.updatedAt.isAfter(remote.updatedAt)) {
      await api.putSettings(s.toSyncJson(), s.updatedAt);
    }
  }

  Future<void> _pushLibrary() async {
    final dirty = await library.dirty();
    for (var i = 0; i < dirty.length; i += 500) {
      final chunk = dirty.sublist(i, (i + 500).clamp(0, dirty.length));
      await api.syncLibrary(chunk);
      await library.markClean(chunk);
    }
  }

  Future<void> _pushProgress() async {
    while (true) {
      final dirty = await progress.dirty();
      if (dirty.isEmpty) return;
      await api.pushProgress(dirty);
      await progress.markClean(dirty);
      if (dirty.length < 2000) return;
    }
  }

  Future<void> _pushHistory() async {
    while (true) {
      final dirty = await history.dirty();
      if (dirty.isEmpty) return;
      await api.pushHistory(dirty);
      await history.markClean(dirty.map((h) => h.id));
      if (dirty.length < 2000) return;
    }
  }

  Future<void> _pull() async {
    final lib = await api.library(since: await _since('since_library'));
    for (final e in lib.items) {
      await library.mergeRemote(e);
    }
    await kv.set('since_library', lib.serverTime.toIso8601String());

    final prog = await api.progress(since: await _since('since_progress'));
    for (final p in prog.items) {
      await progress.mergeRemote(p);
    }
    await kv.set('since_progress', prog.serverTime.toIso8601String());

    final hist = await api.history(since: await _since('since_history'));
    for (final h in hist.items) {
      await history.mergeRemote(h);
    }
    await kv.set('since_history', hist.serverTime.toIso8601String());
  }

  /// Collections: local is authoritative for membership of collections it knows;
  /// collections created on other devices are pulled in.
  Future<void> _syncCollections() async {
    final remote = await api.collections();
    final remoteById = {for (final c in remote) c['id'] as String: c};
    final entryIds = await api.libraryEntryIds(); // "source:manga" -> server entry id
    final keyById = {for (final e in entryIds.entries) e.value: e.key};
    final local = await collections.all();
    final knownRemote = <String>{};

    for (final c in local) {
      var rid = await collections.remoteId(c.id);
      if (rid == null || !remoteById.containsKey(rid)) {
        final byName = remote.where((r) => (r['name'] as String).toLowerCase() == c.name.toLowerCase());
        rid = byName.isNotEmpty ? byName.first['id'] as String : (await api.createCollection(c.name, c.position))['id'] as String;
        await collections.setRemoteId(c.id, rid);
      }
      knownRemote.add(rid);
      final remoteMembers = {
        for (final id in (remoteById[rid]?['entry_ids'] as List? ?? const [])) keyById[id as String],
      }.whereType<String>().toSet();
      final localMembers = c.entryKeys.toSet();
      final add = [for (final k in localMembers.difference(remoteMembers)) if (entryIds[k] != null) entryIds[k]!];
      final remove = [for (final k in remoteMembers.difference(localMembers)) if (entryIds[k] != null) entryIds[k]!];
      await api.setCollectionItems(rid, add, remove);
    }
    for (final r in remote) {
      final rid = r['id'] as String;
      if (knownRemote.contains(rid)) continue;
      final localId = await collections.create(r['name'] as String, remoteId: rid);
      for (final id in r['entry_ids'] as List? ?? const []) {
        final key = keyById[id as String];
        if (key == null) continue;
        final parts = key.split(':');
        final current = await library.get(parts[0], parts.sublist(1).join(':'));
        await collections.setMembership(parts[0], parts.sublist(1).join(':'), {...?current?.collectionIds, localId});
      }
    }
  }

  Future<void> _pullUpdates() async {
    final since = await _since('since_updates');
    final items = await api.updates(unseen: true, since: since);
    if (items.isEmpty) return;
    final fresh = await updates.addAll(items);
    final counts = <String, int>{};
    for (final u in items) {
      counts['${u.sourceId}\u0000${u.mangaId}'] = (counts['${u.sourceId}\u0000${u.mangaId}'] ?? 0) + 1;
    }
    for (final e in counts.entries) {
      final parts = e.key.split('\u0000');
      await library.setUnread(parts[0], parts[1], e.value);
    }
    final newest = items.map((u) => u.detectedAt).reduce((a, b) => a.isAfter(b) ? a : b);
    await kv.set('since_updates', newest.toIso8601String());
    if (fresh.isNotEmpty) onNewUpdates?.call(fresh);
  }

  void dispose() {
    _debounce?.cancel();
    status.dispose();
  }
}
