import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'novel_reader_screen.dart';
import 'reader_screen.dart';

/// Is a source ранобэ (text chapters)?
final textSourceProvider = FutureProvider.family<bool, String>(
  (ref, sourceId) => ref.watch(catalogRepositoryProvider).isTextSource(sourceId),
);

/// `/reader/...`: pages for manga, the text reader for ранобэ — every link to a chapter (title,
/// continue reading, updates, history) lands in the right one.
class ChapterScreen extends ConsumerWidget {
  const ChapterScreen({
    super.key,
    required this.sourceId,
    required this.mangaId,
    required this.chapterId,
    this.initialPage,
    this.roomCode,
  });

  final String sourceId;
  final String mangaId;
  final String chapterId;
  final int? initialPage;
  final String? roomCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = sourceId == 'ranobelib' ? true : ref.watch(textSourceProvider(sourceId)).valueOrNull;
    if (text == null) return const Scaffold(backgroundColor: Colors.black);
    if (text) return NovelReaderScreen(sourceId: sourceId, mangaId: mangaId, chapterId: chapterId);
    return ReaderScreen(
      sourceId: sourceId,
      mangaId: mangaId,
      chapterId: chapterId,
      initialPage: initialPage,
      roomCode: roomCode,
    );
  }
}
