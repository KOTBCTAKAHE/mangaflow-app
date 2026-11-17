import 'dart:async';

import '../local/daos.dart';
import '../models/library.dart';
import '../models/manga.dart';

/// Local-first library operations. Every mutation marks rows dirty and
/// notifies [changes]; the sync engine pushes them when online.
class LibraryRepository {
  LibraryRepository({required this.library, required this.collections, required this.onChanged, this.onCollectionDeleted});

  final LibraryDao library;
  final CollectionsDao collections;
  final void Function() onChanged;

  /// Propagates a collection deletion to the server (remote id).
  final Future<void> Function(String remoteId)? onCollectionDeleted;

  DateTime get _now => DateTime.now().toUtc();

  Future<List<LibraryEntry>> all() => library.all();

  Future<LibraryEntry?> get(String sourceId, String mangaId) async {
    final e = await library.get(sourceId, mangaId);
    return (e == null || e.deleted) ? null : e;
  }

  Future<LibraryEntry> add(MangaDetails m, {LibraryStatus status = LibraryStatus.planned, int? totalChapters}) async {
    final existing = await library.get(m.sourceId, m.id);
    final now = _now;
    final entry = existing != null
        ? existing.copyWith(
            title: m.title, coverUrl: m.coverUrl, status: status, deleted: false, updatedAt: now, totalChapters: totalChapters)
        : LibraryEntry(
            sourceId: m.sourceId,
            mangaId: m.id,
            title: m.title,
            coverUrl: m.coverUrl,
            status: status,
            totalChapters: totalChapters,
            addedAt: now,
            updatedAt: now,
          );
    await library.upsert(entry);
    onChanged();
    return entry;
  }

  Future<void> remove(String sourceId, String mangaId) async {
    final e = await library.get(sourceId, mangaId);
    if (e == null) return;
    await library.upsert(e.copyWith(deleted: true, isFavorite: false, updatedAt: _now));
    await collections.setMembership(sourceId, mangaId, {});
    onChanged();
  }

  Future<void> _patch(String sourceId, String mangaId, LibraryEntry Function(LibraryEntry e) f) async {
    final e = await library.get(sourceId, mangaId);
    if (e == null) return;
    await library.upsert(f(e).copyWith(updatedAt: _now));
    onChanged();
  }

  Future<void> setStatus(String sourceId, String mangaId, LibraryStatus status) =>
      _patch(sourceId, mangaId, (e) => e.copyWith(status: status));

  Future<void> setFavorite(String sourceId, String mangaId, bool fav) =>
      _patch(sourceId, mangaId, (e) => e.copyWith(isFavorite: fav));

  Future<void> setReaderSettings(String sourceId, String mangaId, Map<String, dynamic> s) =>
      _patch(sourceId, mangaId, (e) => e.copyWith(readerSettings: {...e.readerSettings, ...s}));

  /// Keeps the snapshot fresh when the title page is opened.
  Future<void> refreshSnapshot(TitleData t) async {
    final e = await library.get(t.manga.sourceId, t.manga.id);
    if (e == null || e.deleted) return;
    if (e.title == t.manga.title && e.coverUrl == t.manga.coverUrl && e.totalChapters == t.chapters.length) return;
    await library.upsert(
        e.copyWith(title: t.manga.title, coverUrl: t.manga.coverUrl, totalChapters: t.chapters.length, updatedAt: _now));
    onChanged();
  }

  /// Reading bumps last-read and moves "planned" titles to "reading".
  Future<void> touchRead(String sourceId, String mangaId, {double? chapterNumber, bool completed = false}) async {
    final e = await library.get(sourceId, mangaId);
    if (e == null || e.deleted) return;
    var next = e.copyWith(lastReadAt: _now, updatedAt: _now);
    if (e.status == LibraryStatus.planned) next = next.copyWith(status: LibraryStatus.reading);
    if (completed && chapterNumber != null && (e.lastChapterNumber == null || chapterNumber > e.lastChapterNumber!)) {
      next = next.copyWith(lastChapterNumber: chapterNumber);
    }
    await library.upsert(next);
    onChanged();
  }

  // ---- collections
  Future<List<Collection>> allCollections() => collections.all();

  Future<String> createCollection(String name) async {
    final id = await collections.create(name.trim());
    onChanged();
    return id;
  }

  Future<void> renameCollection(String id, String name) async {
    await collections.rename(id, name.trim());
    onChanged();
  }

  Future<void> deleteCollection(String id) async {
    final remote = await collections.remoteId(id);
    await collections.delete(id);
    if (remote != null) {
      try {
        await onCollectionDeleted?.call(remote);
      } catch (_) {
        // offline: the collection will be re-pulled; user can delete again later
      }
    }
    onChanged();
  }

  Future<void> setCollections(String sourceId, String mangaId, Set<String> ids) async {
    await collections.setMembership(sourceId, mangaId, ids);
    final e = await library.get(sourceId, mangaId);
    if (e != null) await library.upsert(e.copyWith(updatedAt: _now)); // mark dirty → membership sync
    onChanged();
  }
}
