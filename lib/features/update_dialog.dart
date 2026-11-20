import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/providers.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../core/utils/format.dart';
import '../data/services/app_updates.dart';
import '../data/services/ota.dart';
import '../widgets/states.dart';

final appUpdaterProvider = Provider((ref) => AppUpdater(ref.watch(kvDaoProvider)));

/// Automatic check (throttled to every 12 h) — call after the first frame.
Future<void> autoCheckForUpdates(BuildContext context, WidgetRef ref) async {
  if (!Platform.isAndroid) return;
  try {
    final r = await ref.read(appUpdaterProvider).check();
    if (r != null && context.mounted) await showUpdateDialog(context, ref, r);
  } catch (_) {
    // no network / GitHub rate limit: try again next time
  }
}

/// Manual check from Settings.
Future<void> manualCheckForUpdates(BuildContext context, WidgetRef ref) async {
  try {
    final r = await ref.read(appUpdaterProvider).check(manual: true);
    if (!context.mounted) return;
    if (r == null) {
      final v = await ref.read(appUpdaterProvider).currentVersion();
      if (context.mounted) showSnack(context, 'Установлена последняя версия ($v)');
    } else {
      await showUpdateDialog(context, ref, r);
    }
  } catch (_) {
    if (context.mounted) showSnack(context, 'Не удалось проверить обновления. Проверьте интернет.');
  }
}

Future<void> showUpdateDialog(BuildContext context, WidgetRef ref, AppRelease r) async {
  final current = await ref.read(appUpdaterProvider).currentVersion();
  if (!context.mounted) return;
  final notes = r.notes.length > 900 ? '${r.notes.substring(0, 900)}…' : r.notes;
  final action = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Доступна версия ${r.version}'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Установлена $current', style: context.text.bodySmall),
          if (r.patch != null) ...[
            const SizedBox(height: MfSpace.xs),
            Text('Мини-обновление: ${formatBytes(r.patch!.size)} вместо ${formatBytes(r.apkSize)}',
                style: context.text.bodySmall?.copyWith(color: MfColors.accent, fontWeight: FontWeight.w600)),
          ] else if (r.apkName != null) ...[
            const SizedBox(height: MfSpace.xs),
            Text('${r.apkName} · ${formatBytes(r.apkSize)}', style: context.text.bodySmall),
          ],
          if (notes.isNotEmpty) ...[
            const SizedBox(height: MfSpace.md),
            Text(notes, style: context.text.bodyMedium),
          ],
          const SizedBox(height: MfSpace.md),
          Text('Обновится прямо в приложении — библиотека и прогресс сохранятся.',
              style: context.text.bodySmall?.copyWith(color: context.textTertiary)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, 'skip'), child: const Text('Пропустить')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Позже')),
        FilledButton(onPressed: () => Navigator.pop(context, 'download'), child: const Text('Обновить')),
      ],
    ),
  );
  if (action == 'skip') await ref.read(appUpdaterProvider).skip(r.version);
  if (action == 'download' && context.mounted) {
    if (Platform.isAndroid && r.apkUrl != null) {
      await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => _UpdateProgress(release: r));
    } else {
      final ok = await launchUrl(Uri.parse(r.apkUrl ?? r.pageUrl), mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) showSnack(context, 'Откройте ${r.pageUrl} в браузере');
    }
  }
}

/// Download → (patch → rebuild) → verify → system installer. Falls back to the full APK.
class _UpdateProgress extends StatefulWidget {
  const _UpdateProgress({required this.release});
  final AppRelease release;

  @override
  State<_UpdateProgress> createState() => _UpdateProgressState();
}

class _UpdateProgressState extends State<_UpdateProgress> {
  String _stage = 'Готовлю…';
  double? _progress;
  String? _error;
  String? _ready; // APK path waiting for «Установить»
  bool _needsPermission = false;
  final _cancel = CancelToken();

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  void _set(String stage, [double? p]) {
    if (mounted) setState(() {
      _stage = stage;
      _progress = p;
    });
  }

  Future<void> _download(String url, String path, String label, int size) async {
    await Dio().download(url, path, cancelToken: _cancel, onReceiveProgress: (got, total) {
      final t = total > 0 ? total : size;
      _set('$label · ${formatBytes(got)} из ${formatBytes(t)}', t > 0 ? got / t : null);
    });
  }

  Future<void> _run() async {
    final r = widget.release;
    final dir = Directory('${(await getTemporaryDirectory()).path}/ota');
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
    } catch (_) {}
    final out = '${dir.path}/MangaFlow-${r.version}.apk';
    String? apk;
    final p = r.patch;
    if (p != null) {
      try {
        final patchPath = '${dir.path}/${p.name}';
        await _download(p.url, patchPath, 'Скачиваю мини-обновление', p.size);
        if (await Ota.sha256(patchPath) != p.sha256) throw StateError('патч повреждён при загрузке');
        _set('Собираю обновление…');
        final got = await Ota.apply(patchPath, out);
        if (got != p.toSha256) throw StateError('собранный APK не совпал с выпуском');
        File(patchPath).deleteSync();
        apk = out;
      } catch (e) {
        if (_cancel.isCancelled) return;
        _set('Мини-обновление не подошло ($e), качаю полную версию…');
      }
    }
    if (apk == null) {
      try {
        await _download(r.apkUrl!, out, 'Скачиваю ${r.apkName ?? 'APK'}', r.apkSize);
        if (r.apkSha256 != null && await Ota.sha256(out) != r.apkSha256) throw StateError('APK повреждён при загрузке');
        apk = out;
      } catch (e) {
        if (_cancel.isCancelled || !mounted) return;
        setState(() => _error = 'Не удалось скачать обновление: ${e is DioException ? (e.message ?? e.type.name) : e}');
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _ready = apk;
      _stage = 'Обновление готово';
      _progress = 1;
    });
    await _install();
  }

  Future<void> _install() async {
    final apk = _ready;
    if (apk == null) return;
    try {
      final res = await Ota.install(apk);
      if (!mounted) return;
      setState(() => _needsPermission = res == 'permission');
      if (res == 'started') Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось открыть установщик: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Обновление до ${widget.release.version}'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_error != null)
          Text(_error!, style: TextStyle(color: context.colors.error))
        else ...[
          Text(_needsPermission
              ? 'Разрешите MangaFlow устанавливать приложения (откроются настройки), вернитесь и нажмите «Установить».'
              : _stage),
          const SizedBox(height: MfSpace.md),
          LinearProgressIndicator(value: _progress),
        ],
      ]),
      actions: [
        TextButton(
          onPressed: () {
            _cancel.cancel();
            Navigator.pop(context);
          },
          child: Text(_ready != null || _error != null ? 'Закрыть' : 'Отмена'),
        ),
        if (_ready != null && _error == null) FilledButton(onPressed: _install, child: const Text('Установить')),
      ],
    );
  }
}
