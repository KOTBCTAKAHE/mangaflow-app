import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/services/home_widget_sync.dart';
import '../../widgets/states.dart';
import 'app_lock.dart';

const lockTimeouts = <int, String>{0: 'Сразу', 60: 'Через 1 минуту', 300: 'Через 5 минут', 900: 'Через 15 минут'};

/// Asks for the current PIN (to turn the lock off or change it). Fingerprint works too.
Future<bool> confirmCurrentPin(BuildContext context, WidgetRef ref) async {
  final ctrl = ref.read(appLockProvider.notifier);
  if (ref.read(settingsProvider).lockBiometrics && await ctrl.canUseBiometrics()) {
    if (await ctrl.unlockWithBiometrics()) return true;
  }
  if (!context.mounted) return false;
  final text = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Текущий PIN'),
      content: TextField(
        controller: text,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
        decoration: const InputDecoration(hintText: '4–6 цифр'),
        onSubmitted: (v) async => Navigator.pop(context, await ctrl.pins.check(v)),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
        FilledButton(
          onPressed: () async {
            final good = await ctrl.pins.check(text.text);
            if (context.mounted) Navigator.pop(context, good);
          },
          child: const Text('Готово'),
        ),
      ],
    ),
  );
  if (ok == false && context.mounted) showSnack(context, 'Неверный PIN');
  return ok ?? false;
}

class PrivacySettings extends ConsumerWidget {
  const PrivacySettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final settings = ref.read(settingsProvider.notifier);
    final lock = ref.read(appLockProvider.notifier);
    return Column(children: [
      SwitchListTile(
        secondary: const Icon(Icons.visibility_off_outlined),
        title: const Text('Инкогнито'),
        subtitle: const Text('История, прогресс глав и поисковые запросы не сохраняются и не синхронизируются'),
        value: s.incognito,
        onChanged: (v) => settings.updateLocalOnly((x) => x.copyWith(incognito: v)),
      ),
      SwitchListTile(
        secondary: const Icon(Icons.lock_outline_rounded),
        title: const Text('Вход по PIN'),
        subtitle: const Text('PIN-код, а также отпечаток или лицо, при открытии приложения'),
        value: s.appLock,
        onChanged: (v) async {
          if (v) {
            final pin = await askNewPin(context);
            if (pin == null) return;
            await lock.enable(pin);
            if (context.mounted) showSnack(context, 'Блокировка включена');
          } else if (await confirmCurrentPin(context, ref)) {
            await lock.disable();
          }
        },
      ),
      if (s.appLock) ...[
        SwitchListTile(
          secondary: const Icon(Icons.fingerprint_rounded),
          title: const Text('Отпечаток или лицо'),
          subtitle: const Text('Если на телефоне настроены'),
          value: s.lockBiometrics,
          onChanged: (v) => settings.updateLocalOnly((x) => x.copyWith(lockBiometrics: v)),
        ),
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Блокировать после выхода'),
          subtitle: Text(lockTimeouts[s.lockTimeoutSec] ?? 'Через ${s.lockTimeoutSec} с'),
          onTap: () async {
            final v = await showModalBottomSheet<int>(
              context: context,
              builder: (context) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final e in lockTimeouts.entries)
                    ListTile(
                      title: Text(e.value),
                      trailing: e.key == s.lockTimeoutSec ? Icon(Icons.check_rounded, color: MfColors.accent) : null,
                      onTap: () => Navigator.pop(context, e.key),
                    ),
                ]),
              ),
            );
            if (v != null) await settings.updateLocalOnly((x) => x.copyWith(lockTimeoutSec: v));
          },
        ),
        ListTile(
          leading: const Icon(Icons.pin_outlined),
          title: const Text('Сменить PIN'),
          onTap: () async {
            if (!await confirmCurrentPin(context, ref) || !context.mounted) return;
            final pin = await askNewPin(context);
            if (pin == null) return;
            await lock.enable(pin);
            if (context.mounted) showSnack(context, 'PIN изменён');
          },
        ),
        ListTile(
          leading: const Icon(Icons.lock_clock_outlined),
          title: const Text('Заблокировать сейчас'),
          onTap: lock.lockNow,
        ),
      ],
      if (Platform.isAndroid)
        SwitchListTile(
          secondary: const Icon(Icons.web_asset_off_outlined),
          title: const Text('Скрывать в недавних приложениях'),
          subtitle: const Text('Вместо страниц — пустой экран при переключении приложений. '
              'На Android 12 и старше это также запрещает скриншоты'),
          value: s.hideInRecents,
          onChanged: (v) async {
            await settings.updateLocalOnly((x) => x.copyWith(hideInRecents: v));
            await PrivacyWindow.hideInRecents(v);
          },
        ),
    ]);
  }
}

/// «Добавить на рабочий стол»: the launcher shows its own confirmation (Android 8+).
class WidgetSettings extends StatelessWidget {
  const WidgetSettings({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    Future<void> pin(String kind) async {
      final ok = await HomeWidgetSync.pin(kind);
      if (!ok && context.mounted) {
        showSnack(context, 'Лаунчер не умеет добавлять виджеты из приложения. '
            'Зажмите пустое место на рабочем столе → «Виджеты» → MangaFlow');
      }
    }

    return Column(children: [
      ListTile(
        leading: const Icon(Icons.play_circle_outline_rounded),
        title: const Text('Виджет «Продолжить чтение»'),
        subtitle: const Text('Последняя глава одним нажатием'),
        trailing: const Icon(Icons.add_to_home_screen_rounded),
        onTap: () => pin('continue'),
      ),
      ListTile(
        leading: const Icon(Icons.grid_view_rounded),
        title: const Text('Виджет «Библиотека»'),
        subtitle: const Text('Четыре тайтла с новыми главами и последние прочитанные'),
        trailing: const Icon(Icons.add_to_home_screen_rounded),
        onTap: () => pin('library'),
      ),
    ]);
  }
}
