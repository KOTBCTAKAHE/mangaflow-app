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
import '../../data/services/auto_download.dart';
import '../../data/services/background.dart';
import '../../data/services/notifications.dart';
import '../../widgets/states.dart';
import '../discover/filters_sheet.dart' show commonGenres;
import '../downloads_support.dart';
import '../library/library_actions.dart' show promptText;
import '../reader/upscale_settings.dart';
import '../security/privacy_settings.dart';
import '../update_dialog.dart';
import 'proxy_screen.dart';
import '../../widgets/beta_badge.dart';

/// Settings in five sections (3.0): a short hub, each section on its own page.
enum SettingsSection {
  reading('Чтение', 'Режимы, по кадрам, поля, улучшение ИИ', Icons.auto_stories_outlined, ['Читалка', 'Улучшение качества страниц (ИИ)']),
  look('Внешний вид', 'Тема, цвета Material You, виджеты', Icons.palette_outlined, ['Внешний вид', 'Виджеты на рабочий стол']),
  downloads('Загрузки и контент', 'Уведомления, загрузки, источники, 18+', Icons.download_outlined, ['Уведомления и загрузки', 'Контент']),
  account('Аккаунт и данные', 'Вход, резервная копия, приватность', Icons.person_outline_rounded, ['Аккаунт', 'Данные', 'Приватность']),
  app('Подключение и приложение', 'Прокси, обновления, о приложении', Icons.settings_suggest_outlined, ['Подключение', 'Приложение']);

  const SettingsSection(this.title, this.summary, this.icon, this.headers);
  final String title;
  final String summary;
  final IconData icon;
  final List<String> headers;
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key, this.section});

  /// null: the hub with the five sections.
  final SettingsSection? section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final signedIn = ref.watch(authProvider) is SignedIn;

    final all = <Widget>[
        const _Header('Подключение'),
        ListTile(
          leading: const Icon(Icons.vpn_lock_outlined),
          title: const Text('Прокси'),
          subtitle: Text(s.proxy.display),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ProxyScreen())),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.lg, MfSpace.gutter, MfSpace.xs),
          child: Text('Цвета приложения · «Обои» — Material You: оттенки берутся из обоев телефона', style: context.text.bodySmall),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter - 4),
          child: Wrap(spacing: MfSpace.xs, children: [
            for (final p in AccentPalette.values)
              _AccentSwatch(
                palette: p,
                selected: s.accent == p,
                onTap: () => ctrl.update((x) => x.copyWith(accent: p)),
              ),
          ]),
        ),
        const _Header('Улучшение качества страниц (ИИ)'),
        const UpscaleSettingsPanel(showCache: true),
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
          secondary: const Icon(Icons.signal_cellular_alt_rounded),
          title: const Text('Экономия трафика на мобильном'),
          subtitle: const Text('Без Wi-Fi страницы грузятся в 720px — в ~2–3 раза меньше трафика. Улучшение ИИ на телефоне возвращает чёткость.'),
          value: s.mobileDataSaver,
          onChanged: (v) => ctrl.update((x) => x.copyWith(mobileDataSaver: v)),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.merge_type_rounded),
          title: const Text('Один тайтл — все источники'),
          subtitle: const Text('Главы, которых нет на сайте тайтла, подтягиваются с других; если сайт лежит, глава откроется с другого'),
          value: s.mergeSources,
          onChanged: (v) => ctrl.update((x) => x.copyWith(mergeSources: v)),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.crop_rounded),
          title: const Text('Обрезать белые поля'),
          subtitle: const Text('В режиме страниц картинка крупнее: пустые края и номер страницы не занимают экран'),
          value: s.autoCrop,
          onChanged: (v) => ctrl.update((x) => x.copyWith(autoCrop: v)),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.crop_free_rounded),
          title: const BetaTitle('Чтение по кадрам'),
          subtitle: const Text('В страничном режиме: тап по краю — следующий кадр с плавным приближением'),
          value: s.panelMode,
          onChanged: (v) => ctrl.update((x) => x.copyWith(panelMode: v)),
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
          secondary: const Icon(Icons.volume_down_outlined),
          title: const Text('Листать кнопками громкости'),
          subtitle: Text(s.volumeKeysInverted ? 'Громкость + — следующая страница' : 'Громкость − — следующая страница'),
          value: s.volumeKeys,
          onChanged: (v) => ctrl.update((x) => x.copyWith(volumeKeys: v)),
        ),
        if (s.volumeKeys)
          SwitchListTile(
            secondary: const Icon(Icons.swap_vert_rounded),
            title: const Text('Поменять кнопки громкости местами'),
            value: s.volumeKeysInverted,
            onChanged: (v) => ctrl.update((x) => x.copyWith(volumeKeysInverted: v)),
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
          secondary: const Icon(Icons.download_for_offline_rounded),
          title: const Text('Автоскачивание новых глав'),
          subtitle: const Text('Для тайтлов «Читаю»: до 5 непрочитанных глав вперёд, только по Wi-Fi и на зарядке'),
          value: s.autoDownloadNew,
          onChanged: (v) async {
            await ctrl.update((x) => x.copyWith(autoDownloadNew: v));
            await AutoDownload.sync(v);
            if (v && context.mounted) showSnack(context, 'Новые главы будут скачиваться ночью на зарядке по Wi-Fi');
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
        const _Header('Приватность'),
        const PrivacySettings(),
        const _Header('Виджеты на рабочий стол'),
        const WidgetSettings(),
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
          subtitle: const Text('Библиотека, полки, прогресс, история, настройки'),
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
    ];
    return _layout(context, all);
  }

  Widget _layout(BuildContext context, List<Widget> all) {
    final sec = section;
    if (sec == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Настройки')),
        body: ListView(padding: const EdgeInsets.fromLTRB(MfSpace.md, MfSpace.sm, MfSpace.md, MfSpace.huge), children: [
          for (final x in SettingsSection.values)
            Padding(
              padding: const EdgeInsets.only(bottom: MfSpace.sm),
              child: Material(
                color: context.colors.surfaceContainer,
                borderRadius: BorderRadius.circular(MfRadius.lg),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: MfSpace.lg, vertical: MfSpace.xs),
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: context.colors.secondaryContainer,
                      borderRadius: BorderRadius.circular(MfRadius.md),
                    ),
                    child: Icon(x.icon, color: context.colors.onSecondaryContainer),
                  ),
                  title: Text(x.title),
                  subtitle: Text(x.summary),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(section: x))),
                ),
              ),
            ),
        ]),
      );
    }
    // the section's part of the full list: from each of its headers to the next header
    final mine = <Widget>[];
    var on = false;
    for (final w in all) {
      if (w is _Header) on = sec.headers.contains(w.text);
      if (on) mine.add(w);
    }
    return Scaffold(
      appBar: AppBar(title: Text(sec.title)),
      body: ListView(padding: const EdgeInsets.only(bottom: MfSpace.huge), children: mine),
    );
  }

  Future<void> _editExcludedGenres(BuildContext context, WidgetRef ref) async {
    final current = {...ref.read(settingsProvider).excludedGenres};
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      useRootNavigator: true,
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

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({required this.palette, required this.selected, required this.onTap});
  final AccentPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: palette.label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(MfRadius.md),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              AnimatedContainer(
                duration: MfMotion.base,
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: selected ? BoxShape.rectangle : BoxShape.circle,
                  borderRadius: selected ? BorderRadius.circular(14) : null,
                  color: palette == AccentPalette.wallpaper ? null : palette.color,
                  gradient: palette == AccentPalette.wallpaper
                      ? SweepGradient(colors: [
                          MfColors.wallpaperSeed ?? palette.color,
                          const Color(0xFFFF8A65),
                          const Color(0xFF4DB6AC),
                          const Color(0xFF7986CB),
                          MfColors.wallpaperSeed ?? palette.color,
                        ])
                      : null,
                  border: Border.all(color: selected ? context.colors.onSurface : Colors.transparent, width: 2.5),
                ),
                child: selected
                    ? Icon(Icons.check_rounded, color: palette == AccentPalette.wallpaper ? Colors.white : palette.on, size: 22)
                    : (palette == AccentPalette.wallpaper ? const Icon(Icons.wallpaper_rounded, color: Colors.white, size: 20) : null),
              ),
              const SizedBox(height: 4),
              Text(palette.label, style: MfType.caption.copyWith(color: context.textTertiary)),
            ]),
          ),
        ),
      );
}
