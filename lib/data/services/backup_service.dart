import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/config.dart';
import '../local/daos.dart';
import '../models/library.dart';
import '../models/reading.dart';
import '../repositories/settings_repository.dart';

/// Local export/import in the same `mangaflow-backup` v1 format the server uses,
/// so a backup made on the phone can be imported into an account and vice versa.
class BackupService {
  BackupService({
    required this.db,
    required this.library,
    required this.collections,
    required this.progress,
    required this.history,
    required this.settings,
  });

  final Database db;
  final LibraryDao library;
  final CollectionsDao collections;
  final ProgressDao progress;
  final HistoryDao history;
  final SettingsController settings;

  Future<Map<String, dynamic>> build() async {
    final lib = await library.all();
    final cols = await collections.all();
    final prog = [for (final r in await db.query('progress')) ChapterProgress.fromRow(r)];
    final hist = await history.all();
    return {
      'format': AppConfig.backupFormat,
      'version': AppConfig.backupVersion,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'settings': settings.state.toSyncJson(),
      'library': [for (final e in lib) e.toApi()..remove('deleted')],
      'collections': [
        for (final c in cols)
          {
            'name': c.name,
            'position': c.position,
            'entries': [
              for (final k in c.entryKeys) [k.substring(0, k.indexOf(':')), k.substring(k.indexOf(':') + 1)],
            ],
          },
      ],
      'progress': [for (final p in prog) p.toApi()],
      'history': [for (final h in hist) h.toApi()],
    };
  }

  Future<File> exportToFile() async {
    final data = await build();
    final dir = await getTemporaryDirectory();
    final ts = DateTime.now();
    final name = 'mangaflow-backup-${ts.year}${_2(ts.month)}${_2(ts.day)}-${_2(ts.hour)}${_2(ts.minute)}.json';
    final file = File('${dir.path}/$name');
    await file.writeAsString(const JsonEncoder.withIndent(' ').convert(data));
    return file;
  }

  static String _2(int v) => v.toString().padLeft(2, '0');

  /// Merges a backup into local data (last-write-wins, never deletes).
  Future<({int library, int progress, int history})> importJson(String raw) async {
    final data = (jsonDecode(raw) as Map).cast<String, dynamic>();
    if (data['format'] != AppConfig.backupFormat) {
      throw const FormatException('Это не резервная копия MangaFlow');
    }
    var nLib = 0, nProg = 0, nHist = 0;
    for (final raw in data['library'] as List? ?? const []) {
      final m = (raw as Map).cast<String, dynamic>();
      m['updated_at'] ??= DateTime.now().toUtc().toIso8601String();
      final remote = LibraryEntry.fromApi(m);
      final local = await library.get(remote.sourceId, remote.mangaId);
      if (local == null || local.updatedAt.isBefore(remote.updatedAt)) {
        await library.upsert(remote);
        nLib++;
      }
    }
    for (final raw in data['collections'] as List? ?? const []) {
      final c = (raw as Map).cast<String, dynamic>();
      final existing = (await collections.all()).where((x) => x.name.toLowerCase() == (c['name'] as String).toLowerCase());
      final id = existing.isNotEmpty ? existing.first.id : await collections.create(c['name'] as String);
      for (final pair in c['entries'] as List? ?? const []) {
        final p = pair as List;
        final entry = await library.get(p[0] as String, p[1] as String);
        await collections.setMembership(p[0] as String, p[1] as String, {...?entry?.collectionIds, id});
      }
    }
    for (final raw in data['progress'] as List? ?? const []) {
      await progress.mergeRemote(ChapterProgress.fromApi((raw as Map).cast()));
      nProg++;
    }
    for (final raw in data['history'] as List? ?? const []) {
      await history.upsert(HistoryItem.fromApi((raw as Map).cast()));
      nHist++;
    }
    await db.update('progress', {'dirty': 1});
    return (library: nLib, progress: nProg, history: nHist);
  }
}
