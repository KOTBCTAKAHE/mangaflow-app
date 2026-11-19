import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/format.dart';
import '../../data/models/manga.dart';
import '../../data/services/download_manager.dart';
import '../../data/services/transfer/chapter_transfer.dart';
import '../../data/services/transfer/zip.dart';
import '../../widgets/net_image.dart';
import '../../widgets/states.dart';

final chapterTransferProvider = Provider((ref) {
  final m = ref.watch(downloadManagerProvider);
  return ChapterTransfer(db: m.db, rootDir: m.rootDir, titleCache: ref.watch(titleCacheDaoProvider));
});

String transferError(Object e) => e is ZipFormatException ? e.message : errorText(e);

String _chapters(int n) {
  final m10 = n % 10, m100 = n % 100;
  final w = m10 == 1 && m100 != 11
      ? 'глава'
      : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) ? 'главы' : 'глав');
  return '$n $w';
}

/// Cover bytes for the pack: from the image cache, or a quick download.
Future<Uint8List?> _coverBytes(String url) async {
  if (url.isEmpty) return null;
  try {
    if (url.startsWith('file:')) {
      final f = File.fromUri(Uri.parse(url));
      return f.existsSync() ? await f.readAsBytes() : null;
    }
    final cm = DefaultCacheManager();
    for (final w in [480, 320, 720, 160, 1080]) {
      final hit = await cm.getFileFromCache(withWidth(url, w));
      if (hit != null) return await hit.file.readAsBytes();
    }
    final f = await cm.getSingleFile(withWidth(url, 480)).timeout(const Duration(seconds: 6));
    return await f.readAsBytes();
  } catch (_) {
    return null;
  }
}

// =================================================================== sending

/// «Передать главы»: pick chapters → one .cbz → system share sheet
/// (Quick Share / Bluetooth / Telegram — works without internet).
Future<void> showSendChaptersSheet(BuildContext context, WidgetRef ref, List<DownloadTask> tasks) async {
  final done = tasks.where((t) => t.status == DownloadStatus.completed).toList()
    ..sort((a, b) => (a.chapterNumber ?? 0).compareTo(b.chapterNumber ?? 0));
  if (done.isEmpty) {
    showSnack(context, 'Сначала дождитесь, пока главы скачаются');
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SendSheet(tasks: done),
  );
}

class _SendSheet extends ConsumerStatefulWidget {
  const _SendSheet({required this.tasks});
  final List<DownloadTask> tasks;

  @override
  ConsumerState<_SendSheet> createState() => _SendSheetState();
}

class _SendSheetState extends ConsumerState<_SendSheet> {
  late final Set<String> _picked = {for (final t in widget.tasks) t.chapterId};
  late final int _hdPages = ChapterTransfer.hdCount(widget.tasks);
  bool _hd = true;
  double? _progress;

  List<DownloadTask> get _selected => [for (final t in widget.tasks) if (_picked.contains(t.chapterId)) t];

  Future<void> _send() async {
    final tasks = _selected;
    if (tasks.isEmpty) return;
    setState(() => _progress = 0);
    final first = tasks.first;
    try {
      final cached = (await ref.read(titleCacheDaoProvider).get(first.sourceId, first.mangaId))?.$1;
      final manga = cached?.manga ??
          MangaDetails(sourceId: first.sourceId, sourceName: first.sourceId, id: first.mangaId, title: first.mangaTitle, coverUrl: first.coverUrl);
      final known = {for (final c in cached?.chapters ?? const <Chapter>[]) c.id: c};
      final outDir = Directory('${(await getTemporaryDirectory()).path}/transfer');
      if (outDir.existsSync()) await outDir.delete(recursive: true); // previous packs were already shared
      final result = await ref.read(chapterTransferProvider).exportPack(
            manga: manga,
            chapters: [for (final t in tasks) ExportChapter(t, chapter: known[t.chapterId])],
            outDir: outDir,
            hd: _hd && _hdPages > 0,
            cover: await _coverBytes(first.coverUrl.isNotEmpty ? first.coverUrl : manga.coverUrl),
            onProgress: (v) {
              if (mounted) setState(() => _progress = v);
            },
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      await SharePlus.instance.share(ShareParams(
        files: [XFile(result.file.path, mimeType: 'application/vnd.comicbook+zip')],
        subject: manga.title,
        text: '«${manga.title}» — ${_chapters(result.chapters)} для MangaFlow. Откройте файл в приложении MangaFlow '
            '(или любой читалке CBZ).',
      ));
    } catch (e) {
      if (mounted) {
        setState(() => _progress = null);
        showSnack(context, 'Не удалось собрать файл: ${transferError(e)}');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = widget.tasks;
    final sel = _selected;
    final bytes = sel.fold<int>(0, (s, t) => s + t.sizeBytes);
    final busy = _progress != null;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(MfSpace.gutter, 0, MfSpace.gutter, MfSpace.sm),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Передать главы', style: context.text.titleLarge),
              const SizedBox(height: MfSpace.xs),
              Text(
                'Получится один файл .cbz. Отправьте его через Quick Share, Bluetooth или Telegram — интернет не нужен. '
                'На другом телефоне откройте файл в MangaFlow, и главы появятся в «Загрузках».',
                style: context.text.bodySmall,
              ),
            ]),
          ),
          CheckboxListTile(
            value: sel.length == tasks.length ? true : (sel.isEmpty ? false : null),
            tristate: true,
            onChanged: busy
                ? null
                : (_) => setState(() {
                      if (sel.length == tasks.length) {
                        _picked.clear();
                      } else {
                        _picked.addAll(tasks.map((t) => t.chapterId));
                      }
                    }),
            title: Text('Все скачанные (${tasks.length})'),
          ),
          if (_hdPages > 0)
            SwitchListTile(
              value: _hd,
              onChanged: busy ? null : (v) => setState(() => _hd = v),
              secondary: const Icon(Icons.auto_awesome_rounded),
              title: const Text('С улучшенными ИИ страницами'),
              subtitle: Text('Готово $_hdPages стр. — другу не придётся ждать нейросеть'),
            ),
          const Divider(height: 1),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final t in tasks)
                CheckboxListTile(
                  dense: true,
                  value: _picked.contains(t.chapterId),
                  onChanged: busy
                      ? null
                      : (v) => setState(() => v == true ? _picked.add(t.chapterId) : _picked.remove(t.chapterId)),
                  title: Text(t.chapterTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(formatBytes(t.sizeBytes)),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.md, MfSpace.gutter, MfSpace.md),
            child: busy
                ? Column(mainAxisSize: MainAxisSize.min, children: [
                    LinearProgressIndicator(value: _progress),
                    const SizedBox(height: MfSpace.sm),
                    Text('Собираю файл… ${((_progress ?? 0) * 100).round()}%', style: context.text.bodySmall),
                  ])
                : FilledButton.icon(
                    onPressed: sel.isEmpty ? null : _send,
                    icon: const Icon(Icons.send_rounded),
                    label: Text(sel.isEmpty ? 'Выберите главы' : 'Отправить ${_chapters(sel.length)} · ~${formatBytes(bytes)}'),
                  ),
          ),
        ]),
      ),
    );
  }
}

// ================================================================= receiving

/// «Получить главы из файла»: pick a .cbz/.zip and open the import screen.
Future<void> pickChaptersFile(BuildContext context) async {
  final picked = await FilePicker.platform.pickFiles(type: FileType.any);
  final path = picked?.files.single.path;
  if (path == null || !context.mounted) return;
  await context.push(Routes.importChapters(path));
}

class ImportChaptersScreen extends ConsumerStatefulWidget {
  const ImportChaptersScreen({super.key, required this.path});
  final String path;

  @override
  ConsumerState<ImportChaptersScreen> createState() => _ImportChaptersScreenState();
}

class _ImportChaptersScreenState extends ConsumerState<ImportChaptersScreen> {
  late final Future<PackPreview> _preview = ref.read(chapterTransferProvider).inspect(widget.path);
  double? _progress;
  ImportResult? _result;
  String? _error;

  Future<void> _import() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final r = await ref.read(chapterTransferProvider).importPack(widget.path, onProgress: (v) {
        if (mounted) setState(() => _progress = v);
      });
      ref.read(downloadManagerProvider).notifyChanged();
      if (widget.path.contains('/incoming/')) {
        try {
          await File(widget.path).delete(); // our own copy of a received file
        } catch (_) {}
      }
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = transferError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Получить главы')),
      body: FutureBuilder<PackPreview>(
        future: _preview,
        builder: (context, snap) {
          if (snap.hasError) {
            return EmptyState(
              icon: Icons.folder_zip_outlined,
              title: 'Не получилось открыть файл',
              message: '${transferError(snap.error!)}\n\nПодходят файлы .cbz/.zip, которые отправили из MangaFlow, и обычные CBZ-архивы.',
            );
          }
          final pv = snap.data;
          if (pv == null) return const Center(child: CircularProgressIndicator());
          final fresh = pv.chapters.length - pv.alreadyHave;
          return ListView(padding: const EdgeInsets.all(MfSpace.gutter), children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(MfRadius.sm),
                child: SizedBox(
                  width: 96,
                  height: 136,
                  child: pv.cover != null
                      ? Image.memory(pv.cover!, fit: BoxFit.cover, cacheWidth: 300, errorBuilder: (_, __, ___) => _noCover(context))
                      : _noCover(context),
                ),
              ),
              const SizedBox(width: MfSpace.lg),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(pv.title, style: context.text.titleLarge),
                  const SizedBox(height: MfSpace.sm),
                  Text('${_chapters(pv.chapters.length)} · ${pv.pages} стр. · ${formatBytes(pv.bytes)}', style: context.text.bodyMedium),
                  if (pv.alreadyHave > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: MfSpace.xs),
                      child: Text('Уже скачано: ${pv.alreadyHave} — их пропущу', style: context.text.bodySmall),
                    ),
                  if (!pv.isMangaFlowPack)
                    Padding(
                      padding: const EdgeInsets.only(top: MfSpace.xs),
                      child: Text('Обычный архив комикса — появится в «Загрузках» как отдельный тайтл.',
                          style: context.text.bodySmall),
                    ),
                ]),
              ),
            ]),
            const SizedBox(height: MfSpace.xl),
            if (_result case final r?) ...[
              Card(
                child: ListTile(
                  leading: const Icon(Icons.check_circle_rounded, color: MfColors.success),
                  title: Text(r.added > 0 ? 'Добавлено: ${_chapters(r.added)}' : 'Все главы уже были'),
                  subtitle: const Text('Читаются без интернета'),
                ),
              ),
              const SizedBox(height: MfSpace.md),
              if (r.firstChapterId != null)
                FilledButton.icon(
                  onPressed: () => context.pushReplacement(Routes.reader(r.sourceId, r.mangaId, r.firstChapterId!)),
                  icon: const Icon(Icons.menu_book_rounded),
                  label: const Text('Читать'),
                ),
              const SizedBox(height: MfSpace.sm),
              OutlinedButton(
                onPressed: () => context.pushReplacement(Routes.title(r.sourceId, r.mangaId)),
                child: const Text('Открыть тайтл'),
              ),
            ] else if (_progress != null) ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: MfSpace.sm),
              Text('Распаковываю… ${((_progress ?? 0) * 100).round()}%', style: context.text.bodySmall),
            ] else ...[
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: MfSpace.md),
                  child: Text(_error!, style: const TextStyle(color: MfColors.danger)),
                ),
              FilledButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.download_done_rounded),
                label: Text(fresh > 0 ? 'Добавить ${_chapters(fresh)}' : 'Открыть'),
              ),
              const SizedBox(height: MfSpace.lg),
              for (final c in pv.chapters.take(30))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('• $c', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodySmall),
                ),
              if (pv.chapters.length > 30) Text('… и ещё ${pv.chapters.length - 30}', style: context.text.bodySmall),
            ],
          ]);
        },
      ),
    );
  }

  Widget _noCover(BuildContext context) =>
      ColoredBox(color: context.colors.surfaceContainerHighest, child: const Icon(Icons.menu_book_rounded, size: 36));
}
