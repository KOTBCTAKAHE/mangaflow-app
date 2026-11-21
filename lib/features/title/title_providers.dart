import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models/library.dart';
import '../../data/models/manga.dart';
import '../../data/models/reading.dart';
import '../../data/services/download_manager.dart';

typedef TitleKey = ({String sourceId, String mangaId});

/// The title as its own source has it, then — a moment later — with the chapters every other
/// source adds (one title, every source).
final titleProvider = AsyncNotifierProvider.autoDispose.family<TitleNotifier, TitleData, TitleKey>(TitleNotifier.new);

class TitleNotifier extends AutoDisposeFamilyAsyncNotifier<TitleData, TitleKey> {
  @override
  Future<TitleData> build(TitleKey k) async {
    _alive = true;
    ref.onDispose(() => _alive = false);
    final repo = ref.watch(catalogRepositoryProvider);
    final data = await repo.title(k.sourceId, k.mangaId);
    await ref.read(libraryRepositoryProvider).refreshSnapshot(data);
    unawaited(_upgrade(k));
    return data;
  }

  bool _alive = false;

  Future<void> _upgrade(TitleKey k) async {
    final repo = ref.read(catalogRepositoryProvider);
    final library = ref.read(libraryRepositoryProvider);
    final merged = await repo.merged(k.sourceId, k.mangaId);
    if (!_alive || merged == null || state.valueOrNull == null) return;
    state = AsyncData(merged);
    try {
      await library.refreshSnapshot(merged);
    } catch (_) {}
  }
}

final titleProgressProvider = FutureProvider.autoDispose.family<Map<String, ChapterProgress>, TitleKey>((ref, k) {
  ref.watch(dataVersionProvider);
  return ref.watch(readingRepositoryProvider).progressFor(k.sourceId, k.mangaId);
});

final titleEntryProvider = FutureProvider.autoDispose.family<LibraryEntry?, TitleKey>((ref, k) {
  ref.watch(dataVersionProvider);
  return ref.watch(libraryRepositoryProvider).get(k.sourceId, k.mangaId);
});

final titleDownloadsProvider = FutureProvider.autoDispose.family<Map<String, DownloadTask>, TitleKey>((ref, k) {
  ref.watch(downloadsChangesProvider);
  return ref.watch(downloadManagerProvider).forManga(k.sourceId, k.mangaId);
});

final chapterOrderAscProvider = StateProvider.autoDispose.family<bool, TitleKey>((_, __) => false);
