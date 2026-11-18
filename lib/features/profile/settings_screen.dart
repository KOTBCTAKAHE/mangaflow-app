import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/network/api_exception.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/library.dart';
import '../../data/models/settings.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/services/background.dart';
import '../../data/services/notifications.dart';
import '../../widgets/states.dart';
import '../discover/filters_sheet.dart' show commonGenres;
import '../downloads_support.dart';
import '../library/library_actions.dart' show promptText;
import '../update_dialog.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final signedIn = ref.watch(authProvider) is SignedIn;

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(padding: const EdgeInsets.only(bottom: MfSpace.huge), children: [
        const _Header('Сервер'),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('Адрес backend'),
          subtitle: Text(s.apiBaseUrl),
          onTap: () async {
            final v = await promptText(context, title: 'Адрес сервера', initial: s.apiBaseUrl, hint: 'https://manga.example.com');
            if (v == null || v.isEmpty) return;
            final uri = Uri.tryParse(v);
            if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
              if (context.mounted) showSnack(context, 'Некорректный адрес');
              return;
            }
            await ctrl.updateLocalOnly((x) => x.copyWith(apiBaseUrl: v));
            if (context.mounted) showSnack(context, 'Сервер изменён');
          },
        ),
        const _Header('Внешний вид'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.dark, label: Text('Тёмная'), icon: Icon(Icons.dark_mode_outlined)),
              ButtonSegment(value: ThemeMode.light, label: Text('Светлая'), icon: Icon(Icons.light_mode_outlined)),
              ButtonSegment(value: ThemeMode.system, label: Text('Система'), icon: Icon(Icons.brightness_auto_outlined)),
            ],
            selected: {s.themeMode},
            onSelectionChanged: (v) => ctrl.update((x) => x.copyWith(themeMode: v.first)),
          ),
        ),
        const _Header('Читалка'),
        ListTile(
          leading: const Icon(Icons.chrome_reader_mode_outlined),
          title: const Text('Режим по умолчанию'),
          subtitle: Text(s.defaultReadingMode?.label ?? 'Автоматически по формату (манхва — лента, манга — RTL)'),
          onTap: () async {
            final picked = await showDialog<Object>(
              context: context,
              builder: (context) => SimpleDialog(title: const Text('Режим по умолчанию'), children: [
                SimpleDialogOption(onPressed: () => Navigator.pop(context, 'auto'), child: const Text('Автоматически')),
                for (final m in ReadingMode.values)
                  SimpleDialogOption(onPressed: () => Navigator.pop(context, m), child: Text(m.label)),
              ]),
            );
            if (picked == 'auto') await ctrl.setDefaultReadingMode(null);
            if (picked is ReadingMode) await ctrl.setDefaultReadingMode(picked);
          },
        ),
        ListTile(
          leading: const Icon(Icons.high_quality_outlined),
          title: const Text('Качество изображений'),
          subtitle: Text(s.imageQuality.label),
          onTap: () async {
            final q = await showDialog<ImageQuality>(
              context: context,
              builder: (context) => SimpleDialog(title: const Text('Качество изображений'), children: [
                for (final q in ImageQuality.values)
                  SimpleDialogOption(onPressed: () => Navigator.pop(context, q), child: Text(q.label)),
              ]),
            );
            if (q != null) await ctrl.update((x) => x.copyWith(imageQuality: q));
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.skip_next_outlined),
          title: const Text('Автопереход к следующей главе'),
          value: s.autoNextChapter,
          onChanged: (v) => ctrl.update((x) => x.copyWith(autoNextChapter: v)),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.touch_app_outlined),
          title: const Text('Зоны касания'),
          value: s.tapZones,
          onChanged: (v) => ctrl.update((x) => x.copyWith(tapZones: v)),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.light_mode_outlined),
          title: const Text('Не выключать экран при чтении'),
          value: s.keepScreenOn,
          onChanged: (v) => ctrl.update((x) => x.copyWith(keepScreenOn: v)),
        ),
        const _Header('Контент'),
        SwitchListTile(
          secondary: const Icon(Icons.eighteen_up_rating_outlined),
          title: const Text('Показывать источники 18+'),
          subtitle: const Text('Только если вам исполнилось 18 лет'),
          value: s.showNsfw,
          onChanged: (v) => ctrl.update((x) => x.copyWith(showNsfw: v)),
        ),
        ListTile(
          leading: const Icon(Icons.block_outlined),
          title: const Text('Исключённые жанры'),
          subtitle: Text(s.excludedGenres.isEmpty ? 'Нет' : s.excludedGenres.join(', ')),
          onTap: () => _editExcludedGenres(context, ref),
        ),
        ListTile(
          leading: const Icon(Icons.public_rounded),
          title: const Text('Источники'),
          subtitle: Text(s.disabledSources.isEmpty ? 'Все включены' : 'Отключено: ${s.disabledSources.length}'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.push('/sources'),
        ),
        const _Header('Уведомления и загрузки'),
        SwitchListTile(
          secondary: const Icon(Icons.notifications_active_outlined),
          title: const Text('Уведомлять о новых главах'),
          subtitle: const Text('Фоновая проверка примерно раз в 6 часов'),
          value: s.notifyUpdates,
          onChanged: (v) async {
            await ctrl.update((x) => x.copyWith(notifyUpdates: v));
            if (v) {
              await ChapterNotifier.instance.requestPermission();
              await BackgroundUpdates.register().catchError((Object _) {});
            } else {
              await BackgroundUpdates.cancel().catchError((Object _) {});
            }
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.wifi_rounded),
          title: const Text('Загружать только по Wi-Fi'),
          value: s.downloadWifiOnly,
          onChanged: (v) => ctrl.update((x) => x.copyWith(downloadWifiOnly: v)),
        ),
        ListTile(
          leading: const Icon(Icons.battery_charging_full_rounded),
          title: const Text('Фоновая загрузка'),
          subtitle: const Text('Батарея, автозапуск и настройки прошивки (Vivo, Xiaomi, Samsung…)'),
          onTap: () => ensureBackgroundAllowed(context, ref, force: true),
        ),
        const _Header('Приложение'),
        ListTile(
          leading: const Icon(Icons.system_update_rounded),
          title: const Text('Проверить обновления'),
          subtitle: FutureBuilder<String>(
            future: ref.read(appUpdaterProvider).currentVersion(),
            builder: (_, v) => Text('Версия ${v.data ?? '…'} · GitHub Releases'),
          ),
          onTap: () => manualCheckForUpdates(context, ref),
        ),
        const _Header('Данные'),
        ListTile(
          leading: const Icon(Icons.upload_file_outlined),
          title: const Text('Экспорт резервной копии'),
          subtitle: const Text('Библиотека, коллекции, прогресс, история, настройки'),
          onTap: () async {
            try {
              final file = await ref.read(backupServiceProvider).exportToFile();
              await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: 'Резервная копия MangaFlow'));
            } catch (e) {
              if (context.mounted) showSnack(context, 'Не удалось экспортировать: $e');
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('Импорт резервной копии'),
          subtitle: const Text('Данные объединяются, ничего не удаляется'),
          onTap: () async {
            try {
              final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
              final path = picked?.files.single.path;
              if (path == null) return;
              final r = await ref.read(backupServiceProvider).importJson(await File(path).readAsString());
              ref.read(dataVersionProvider.notifier).state++;
              ref.read(syncEngineProvider).schedule(delay: const Duration(seconds: 1));
              if (context.mounted) {
                showSnack(context, 'Импортировано: ${r.library} тайтлов, ${r.progress} отметок, ${r.history} сессий');
              }
            } on FormatException catch (e) {
              if (context.mounted) showSnack(context, e.message);
            } catch (e) {
              if (context.mounted) showSnack(context, 'Ошибка импорта: $e');
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.cleaning_services_outlined),
          title: const Text('Очистить кэш изображений'),
          subtitle: const Text('Загруженные главы не затрагиваются'),
          onTap: () async {
            await DefaultCacheManager().emptyCache();
            PaintingBinding.instance.imageCache.clear();
            if (context.mounted) showSnack(context, 'Кэш очищен');
          },
        ),
        if (signedIn) ...[
          const _Header('Аккаунт'),
          ListTile(
            leading: const Icon(Icons.sync_rounded),
            title: const Text('Синхронизировать сейчас'),
            onTap: () async {
              await ref.read(syncEngineProvider).sync();
              final st = ref.read(syncEngineProvider).status.value;
              if (context.mounted) showSnack(context, st.message ?? 'Синхронизировано');
            },
          ),
          ListTile(
            leading: const Icon(Icons.password_rounded),
            title: const Text('Сменить пароль'),
            onTap: () => _changePassword(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.devices_other_outlined),
            title: const Text('Выйти на всех устройствах'),
            onTap: () async {
              try {
                await ref.read(userApiProvider).logoutAll();
              } on ApiException catch (e) {
                if (context.mounted) showSnack(context, e.userMessage);
                return;
              }
              await ref.read(authProvider.notifier).logout();
              if (context.mounted) showSnack(context, 'Все сессии завершены');
            },
          ),
          ListTile(
            leading: const Icon(Icons.logout_rounded),
            title: const Text('Выйти'),
            subtitle: const Text('Локальные данные останутся на устройстве'),
            onTap: () async {
              await ref.read(syncEngineProvider).sync();
              await ref.read(authProvider.notifier).logout();
              if (context.mounted) context.pop();
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined, color: MfColors.danger),
            title: const Text('Удалить аккаунт', style: TextStyle(color: MfColors.danger)),
            onTap: () async {
              final pwd = await promptText(context, title: 'Подтвердите паролем', hint: 'Пароль');
              if (pwd == null || pwd.isEmpty) return;
              try {
                await ref.read(userApiProvider).deleteAccount(pwd);
                await ref.read(authProvider.notifier).logout();
                if (context.mounted) showSnack(context, 'Аккаунт удалён');
              } on ApiException catch (e) {
                if (context.mounted) showSnack(context, e.userMessage);
              }
            },
          ),
        ],
      ]),
    );
  }

  Future<void> _editExcludedGenres(BuildContext context, WidgetRef ref) async {
    final current = {...ref.read(settingsProvider).excludedGenres};
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(MfSpace.gutter, 0, MfSpace.gutter, MfSpace.lg),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Исключить из поиска', style: context.text.titleMedium),
              const SizedBox(height: MfSpace.md),
              Wrap(spacing: MfSpace.sm, runSpacing: MfSpace.sm, children: [
                for (final g in commonGenres)
                  FilterChip(
                    label: Text(g),
                    selected: current.contains(g),
                    onSelected: (v) => setState(() => v ? current.add(g) : current.remove(g)),
                  ),
              ]),
              const SizedBox(height: MfSpace.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: () => Navigator.pop(context, current), child: const Text('Сохранить')),
              ),
            ]),
          ),
        ),
      ),
    );
    if (result != null) {
      await ref.read(settingsProvider.notifier).update((x) => x.copyWith(excludedGenres: result.toList()));
    }
  }

  Future<void> _changePassword(BuildContext context, WidgetRef ref) async {
    final current = await promptText(context, title: 'Текущий пароль');
    if (current == null || current.isEmpty || !context.mounted) return;
    final next = await promptText(context, title: 'Новый пароль', hint: 'Минимум 8 символов');
    if (next == null || next.length < 8) return;
    try {
      await ref.read(userApiProvider).changePassword(current, next);
      if (context.mounted) showSnack(context, 'Пароль изменён');
    } on ApiException catch (e) {
      if (context.mounted) showSnack(context, e.userMessage);
    }
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.xxl, MfSpace.gutter, MfSpace.sm),
        child: Text(text.toUpperCase(), style: context.text.labelSmall),
      );
}
