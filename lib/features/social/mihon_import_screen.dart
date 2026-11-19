import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/library.dart';
import '../../data/models/manga.dart';
import '../../data/remote/catalog_api.dart';
import '../../data/services/cross_source.dart';
import '../../data/services/mihon_backup.dart';
import '../../widgets/states.dart';
import '../discover/search_controller.dart';

/// Mihon source name → our source id (by name; MangaDex RU when the backup says so).
String? mapMihonSource(String mihonName, List<SourceInfo> ours) {
  final n = normalizeTitle(mihonName.replaceAll(RegExp(r'\(.*?\)'), ''));
  if (n.isEmpty) return null;
  for (final s in ours) {
    if (normalizeTitle(s.name) == n || normalizeTitle(s.id) == n) return s.id;
  }
  for (final s in ours) {
    final sn = normalizeTitle(s.name);
    if (sn.isNotEmpty && (n.startsWith(sn) || sn.startsWith(n))) return s.id;
  }
  return null;
}

enum _RowState { waiting, working, done, notFound, failed }

class _Row {
  _Row(this.m);
  final MihonManga m;
  _RowState state = _RowState.waiting;
  String? sourceId, mangaId, note;
}

class MihonImportScreen extends ConsumerStatefulWidget {
  const MihonImportScreen({super.key});

  @override
  ConsumerState<MihonImportScreen> createState() => _MihonImportScreenState();
}

class _MihonImportScreenState extends ConsumerState<MihonImportScreen> {
  MihonBackup? _backup;
  List<_Row> _rows = const [];
  String? _error;
  bool _running = false, _finished = false;
  bool _withProgress = true, _withCategories = true;

  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
    final f = r?.files.single;
    if (f == null) return;
    try {
      final bytes = f.bytes ?? await File(f.path!).readAsBytes();
      final b = MihonBackup.parse(bytes);
      setState(() {
        _backup = b;
        _rows = [for (final m in b.library) _Row(m)];
        _error = b.library.isEmpty ? 'В копии нет тайтлов из библиотеки' : null;
        _finished = false;
      });
    } catch (e) {
      setState(() => _error = 'Не получилось прочитать файл: ${e is FormatException ? e.message : e}');
    }
  }

  Future<MangaCard?> _find(MihonManga m, String? sourceId) async {
    final catalog = ref.read(catalogRepositoryProvider);
    final want = normalizeTitle(m.title);
    bool same(String t) => normalizeTitle(t) == want;
    if (sourceId != null) {
      try {
        final page = await catalog.browse(sourceId, filters: CatalogFilters(query: m.title));
        for (final c in page.items) {
          if (same(c.title)) return c;
        }
        if (page.items.length == 1) return page.items.first;
      } catch (_) {}
    }
    final res = await catalog.search(m.title);
    for (final c in res.items) {
      for (final hit in [c, ...c.alsoIn]) {
        if (hit.sourceId == sourceId && (same(hit.title) || same(c.title))) return hit;
      }
    }
    for (final c in res.items) {
      if (same(c.title)) return c;
    }
    return null;
  }

  Future<void> _run() async {
    final b = _backup;
    if (b == null) return;
    setState(() => _running = true);
    final ours = await ref.read(catalogRepositoryProvider).sources();
    final library = ref.read(libraryRepositoryProvider);
    final reading = ref.read(readingRepositoryProvider);
    final catalog = ref.read(catalogRepositoryProvider);

    // categories → collections (by name)
    final colByOrder = <int, String>{};
    if (_withCategories && b.categories.isNotEmpty) {
      final existing = {for (final c in await library.allCollections()) c.name.toLowerCase(): c.id};
      for (final c in b.categories) {
        if (c.name.trim().isEmpty) continue;
        colByOrder[c.order] = existing[c.name.toLowerCase()] ?? await library.createCollection(c.name);
      }
    }

    var next = 0;
    Future<void> worker() async {
      while (mounted && next < _rows.length) {
        final row = _rows[next++];
        setState(() => row.state = _RowState.working);
        try {
          final sid = mapMihonSource(b.sourceName(row.m.source), ours);
          final card = await _find(row.m, sid);
          if (card == null) {
            setState(() => row.state = _RowState.notFound);
            continue;
          }
          final t = await catalog.title(card.sourceId, card.id);
          final last = row.m.lastRead;
          final status = last == null
              ? LibraryStatus.planned
              : (t.chapters.isNotEmpty && t.chapters.every((c) => c.number != null && c.number! <= last))
                  ? LibraryStatus.completed
                  : LibraryStatus.reading;
          await library.add(t.manga, status: status, totalChapters: t.chapters.length);
          final cols = {for (final o in row.m.categoryOrders) if (colByOrder[o] != null) colByOrder[o]!};
          if (cols.isNotEmpty) await library.setCollections(t.manga.sourceId, t.manga.id, cols);
          if (_withProgress && last != null) {
            final read = t.chapters.where((c) => c.number != null && c.number! <= last).toList();
            if (read.isNotEmpty) await reading.markChapters(t.manga, read, read: true);
          }
          setState(() {
            row.state = _RowState.done;
            row.sourceId = t.manga.sourceId;
            row.mangaId = t.manga.id;
            row.note = '${t.manga.sourceName}${last == null ? '' : ' · прочитано до гл. ${_n(last)}'}';
          });
        } catch (e) {
          setState(() => (row.state, row.note) = (_RowState.failed, errorText(e)));
        }
      }
    }

    await Future.wait([worker(), worker(), worker()]);
    if (mounted) setState(() => (_running, _finished) = (false, true));
    unawaited(ref.read(syncEngineProvider).sync().catchError((Object _) {}));
  }

  void _search(String title) {
    ref.read(searchControllerProvider.notifier)
      ..setQuery(title)
      ..submit();
    context.go('/discover');
  }

  static String _n(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  Widget build(BuildContext context) {
    final b = _backup;
    final done = _rows.where((r) => r.state == _RowState.done).length;
    final missed = _rows.where((r) => r.state == _RowState.notFound || r.state == _RowState.failed).length;
    final processed = _rows.where((r) => r.state != _RowState.waiting && r.state != _RowState.working).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Импорт из Mihon / Tachiyomi')),
      body: ListView(padding: const EdgeInsets.all(MfSpace.gutter), children: [
        if (b == null) ...[
          Text('В Mihon (Tachiyomi, Komikku…): Настройки → Данные и хранилище → Создать резервную копию. '
              'Затем выберите файл .tachibk здесь — тайтлы найдутся в источниках MangaFlow, '
              'категории станут коллекциями, прочитанные главы отметятся.',
              style: context.text.bodyMedium),
          const SizedBox(height: MfSpace.lg),
          FilledButton.icon(onPressed: _pick, icon: const Icon(Icons.file_open_rounded), label: const Text('Выбрать резервную копию')),
        ] else ...[
          Text('${_rows.length} тайтлов · ${b.categories.length} категорий', style: context.text.titleMedium),
          const SizedBox(height: MfSpace.xs),
          Text(
            'Источники: ${{for (final r in _rows) b.sourceName(r.m.source)}.join(', ')}',
            style: context.text.bodySmall,
          ),
          if (!_running && !_finished) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _withProgress,
              onChanged: (v) => setState(() => _withProgress = v),
              title: const Text('Перенести прочитанные главы'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _withCategories,
              onChanged: (v) => setState(() => _withCategories = v),
              title: const Text('Категории → коллекции'),
            ),
            const SizedBox(height: MfSpace.sm),
            FilledButton.icon(
              onPressed: _rows.isEmpty ? null : _run,
              icon: const Icon(Icons.download_rounded),
              label: Text('Импортировать ${_rows.length}'),
            ),
          ] else ...[
            const SizedBox(height: MfSpace.md),
            LinearProgressIndicator(value: _rows.isEmpty ? null : processed / _rows.length),
            const SizedBox(height: MfSpace.xs),
            Text(_finished ? 'Готово: перенесено $done, не найдено $missed' : 'Ищу тайтлы… $processed из ${_rows.length}',
                style: context.text.bodySmall),
          ],
          const SizedBox(height: MfSpace.md),
          for (final r in _rows)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: switch (r.state) {
                _RowState.waiting => const Icon(Icons.schedule_rounded, size: 20),
                _RowState.working => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                _RowState.done => const Icon(Icons.check_circle_rounded, color: MfColors.success, size: 20),
                _ => const Icon(Icons.help_outline_rounded, color: MfColors.danger, size: 20),
              },
              title: Text(r.m.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(r.note ??
                  '${b.sourceName(r.m.source)}${r.m.readCount > 0 ? ' · прочитано ${r.m.readCount}' : ''}'
                      '${r.state == _RowState.notFound ? ' · не найдено — нажмите, чтобы поискать' : ''}'),
              onTap: switch (r.state) {
                _RowState.done => () => context.push(Routes.title(r.sourceId!, r.mangaId!)),
                _RowState.notFound || _RowState.failed => () => _search(r.m.title),
                _ => null,
              },
            ),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: MfSpace.md), child: Text(_error!)),
      ]),
    );
  }
}

