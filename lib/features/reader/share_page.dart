import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/models/manga.dart';
import '../../data/services/upscale_service.dart';
import '../../widgets/states.dart';
import 'reader_controller.dart';

/// Picks the best file for a page: the AI-upscaled one when it exists (waits a
/// little if it is being processed right now), otherwise the original.
Future<File> pageFileForSharing(PageRef page, PageUpscaler? upscaler, {Duration wait = const Duration(seconds: 20)}) async {
  if (upscaler != null) {
    final st = upscaler.watch(page);
    if (!st.value.isDone && (st.value.status == UpscaleStatus.running || st.value.status == UpscaleStatus.queued)) {
      upscaler.request(page);
      final done = Completer<void>();
      void l() {
        final s = st.value.status;
        if (s != UpscaleStatus.running && s != UpscaleStatus.queued && !done.isCompleted) done.complete();
      }

      st.addListener(l);
      await done.future.timeout(wait, onTimeout: () {});
      st.removeListener(l);
    }
    final f = st.value.file;
    if (st.value.isDone && f != null && await f.exists()) return f;
  }
  return page.localPath != null ? File(page.localPath!) : (await PageUpscaler.sourceFileOf(page));
}

String _safe(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_').replaceAll(RegExp(r'_+'), '_');

/// Shares the page image (with a readable file name and caption) via the system sheet.
Future<void> sharePage(
  BuildContext context, {
  required PageRef page,
  required PageUpscaler? upscaler,
  required String mangaTitle,
  required String chapterTitle,
  required int pageNumber,
}) async {
  final busy = upscaler != null && upscaler.watch(page).value.status == UpscaleStatus.running;
  if (busy) showSnack(context, 'Дожидаюсь улучшения страницы…');
  try {
    final src = await pageFileForSharing(page, upscaler);
    final upscaled = upscaler != null && upscaler.watch(page).value.isDone;
    final ext = src.path.contains('.') ? src.path.substring(src.path.lastIndexOf('.')).toLowerCase() : '.jpg';
    final name = _safe('${mangaTitle.length > 40 ? mangaTitle.substring(0, 40) : mangaTitle}_$chapterTitle'
        '_стр$pageNumber${upscaled ? '_HD' : ''}');
    final dir = Directory('${(await getTemporaryDirectory()).path}/share')..createSync(recursive: true);
    final out = await src.copy('${dir.path}/$name${ext.length <= 5 ? ext : '.jpg'}');
    await SharePlus.instance.share(ShareParams(
      files: [XFile(out.path, mimeType: ext == '.png' ? 'image/png' : (ext == '.webp' ? 'image/webp' : 'image/jpeg'))],
      text: '$mangaTitle — $chapterTitle, стр. $pageNumber',
    ));
  } catch (e) {
    if (context.mounted) showSnack(context, 'Не удалось поделиться страницей: ${errorText(e)}');
  }
}

/// Share the page the reader is on (top-bar button and long-press on a page).
Future<void> shareCurrentPage(BuildContext context, ReaderController c) async {
  final seg = c.current;
  if (seg == null || seg.pages.isEmpty) return;
  final i = c.page.clamp(0, seg.pages.length - 1);
  await sharePage(
    context,
    page: seg.pages[i],
    upscaler: c.upscaler,
    mangaTitle: c.manga?.title ?? 'MangaFlow',
    chapterTitle: seg.chapter.title,
    pageNumber: i + 1,
  );
}
