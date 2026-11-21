import 'dart:async';
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
import '../../data/services/transfer/local_files.dart';
import '../../data/services/transfer/zip.dart';
import '../../widgets/net_image.dart';
import '../../widgets/states.dart';
import 'wifi_transfer_ui.dart';

final chapterTransferProvider = Provider((ref) {
  final m = ref.watch(downloadManagerProvider);
  return ChapterTransfer(db: m.db, rootDir: m.rootDir, titleCache: ref.watch(titleCacheDaoProvider));
});

String transferError(Object e) => e is ZipFormatException ? e.message : (e is FormatException ? e.message : errorText(e));

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

  /// Builds the pack; [wifi] → hand it over the hotspot, else the share sheet.
  Future<void> _send({bool wifi = false}) async {
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
      if (outDir.existsSync()) await outDir.delete(recursive: true); // previous packs were already sent
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
      final nav = Navigator.of(context);
      nav.pop();
      if (wifi) {
        await nav.push(MaterialPageRoute<void>(
          builder: (_) => WifiSendScreen(pack: result.file, title: manga.title, chapters: result.chapters),
        ));
        return;
      }
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
                'Быстрее всего — по точке доступа: телефоны соединяются напрямую по Wi-Fi, без интернета. '
                'Или отправьте один файл .cbz через Quick Share, Bluetooth, Telegram — на другом телефоне откройте его в MangaFlow.',
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
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                    FilledButton.icon(
                      onPressed: sel.isEmpty ? null : () => _send(wifi: true),
                      icon: const Icon(Icons.wifi_tethering_rounded),
                      label: Text(sel.isEmpty
                          ? 'Выберите главы'
                          : 'По точке доступа — быстрее всего · ~${formatBytes(bytes)}'),
                    ),
                    const SizedBox(height: MfSpace.sm),
                    OutlinedButton.icon(
                      onPressed: sel.isEmpty ? null : _send,
                      icon: const Icon(Icons.send_rounded),
                      label: Text('Файлом: Quick Share, Bluetooth, Telegram (${_chapters(sel.length)})'),
                    ),
                  ]),
          ),
        ]),
      ),
    );
  }
}

// ================================================================= receiving

/// «Получить главы из файла»: same as «Открыть файл».
Future<void> pickChaptersFile(BuildContext context) => openLocalFiles(context);

/// «Открыть файл»: CBZ/ZIP, PDF, pictures — one or many — become a title in «Загрузки».
Future<void> openLocalFiles(BuildContext context) async {
  final picked = await FilePicker.platform.pickFiles(type: FileType.any, allowMultiple: true);
  final paths = [for (final f in picked?.files ?? const <PlatformFile>[]) if (f.path != null) f.path!];
  if (paths.isEmpty || !context.mounted) return;
  final ok = paths.where(LocalFiles.supported).toList();
  if (ok.isEmpty) {
    showSnack(context, 'Подходят CBZ, ZIP, PDF и картинки');
    return;
  }
  if (ok.length == 1 && !isImageName(ok.first)) {
    await context.push(Routes.importChapters(ok.first)); // the import screen prepares a PDF itself
    return;
  }
  final status = ValueNotifier<String>('Готовлю файлы…');
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: MfSpace.lg),
          Expanded(child: ValueListenableBuilder<String>(valueListenable: status, builder: (_, v, __) => Text(v))),
        ]),
      ),
    ),
  ));
  String? pack;
  Object? error;
  try {
    pack = await LocalFiles.toPack(ok, onStatus: (v) => status.value = v);
  } catch (e) {
    error = e;
  }
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  status.dispose();
  if (error != null) {
    showSnack(context, transferError(error));
  } else if (pack != null) {
    await context.push(Routes.importChapters(pack));
  }
}

class ImportChaptersScreen extends ConsumerStatefulWidget {
  const ImportChaptersScreen({super.key, required this.path, this.autoImport = false});
  final String path;

  /// Received over Wi-Fi: add right away, no extra tap.
  final bool autoImport;

  @override
  ConsumerState<ImportChaptersScreen> createState() => _ImportChaptersScreenState();
}

class _ImportChaptersScreenState extends ConsumerState<ImportChaptersScreen> {
  /// The file to import: the picked archive, or a CBZ made from a PDF / pictures.
  late String _pack = widget.path;
  String? _status;

  late final Future<PackPreview> _preview = () async {
    if (!LocalFiles.isArchive(widget.path)) {
      _pack = await LocalFiles.toPack([widget.path], onStatus: (v) {
        if (mounted) setState(() => _status = v);
      });
    }
    return ref.read(chapterTransferProvider).inspect(_pack);
  }()
    ..then((_) {
      if (widget.autoImport && mounted && _progress == null && _result == null) unawaited(_import());
    }, onError: (Object _) {});
  double? _progress;
  ImportResult? _result;
  String? _error;

  Future<void> _import() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final r = await ref.read(chapterTransferProvider).importPack(_pack, onProgress: (v) {
        if (mounted) setState(() => _progress = v);
      });
      ref.read(downloadManagerProvider).notifyChanged();
      if (_pack != widget.path) {
        try {
          await File(_pack).delete(); // the CBZ we made from a PDF / pictures
        } catch (_) {}
      }
      if (widget.path.contains('/incoming/') || widget.path.contains('/wifi-in/')) {
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
              message: '${transferError(snap.error!)}\n\nПодходят файлы из MangaFlow, обычные CBZ/ZIP-архивы, PDF и картинки.',
            );
          }
          final pv = snap.data;
          if (pv == null) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                if (_status != null) ...[const SizedBox(height: MfSpace.lg), Text(_status!, style: context.text.bodyMedium)],
              ]),
            );
          }
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
