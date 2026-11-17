import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models/library.dart';
import '../../data/models/manga.dart';
import '../../data/models/reading.dart';
import '../../data/services/download_manager.dart';

typedef TitleKey = ({String sourceId, String mangaId});

final titleProvider = FutureProvider.autoDispose.family<TitleData, TitleKey>((ref, k) async {
  final data = await ref.watch(catalogRepositoryProvider).title(k.sourceId, k.mangaId);
  await ref.read(libraryRepositoryProvider).refreshSnapshot(data);
  return data;
});

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
