import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Vendor-specific "let this app run in background" screens.
///
/// Stock Android respects foreground services, but several vendor ROMs (Vivo
/// Funtouch/OriginOS, MIUI/HyperOS, EMUI, ColorOS, One UI) kill them with the
/// screen off unless the user whitelists the app. There is no API for that, so
/// we open the right settings screen and explain what to switch on.
class VendorGuide {
  const VendorGuide({required this.vendor, required this.steps, required this.screens});

  final String vendor;
  final List<String> steps;

  /// Candidate activities, tried in order (they differ between ROM versions).
  final List<(String package, String activity)> screens;

  static Future<String> manufacturer() async {
    if (!Platform.isAndroid) return '';
    try {
      return (await DeviceInfoPlugin().androidInfo).manufacturer.toLowerCase();
    } catch (_) {
      return '';
    }
  }

  static Future<VendorGuide?> forThisDevice() async => forManufacturer(await manufacturer());

  static VendorGuide? forManufacturer(String m) {
    if (m.contains('vivo') || m.contains('iqoo')) {
      return const VendorGuide(
        vendor: 'Vivo / iQOO',
        steps: [
          'Настройки → Батарея → Фоновое энергопотребление → MangaFlow → «Разрешить высокое энергопотребление в фоне».',
          'i Manager → Управление приложениями → Автозапуск → включите MangaFlow.',
          'В списке недавних приложений потяните карточку MangaFlow вниз, чтобы закрепить её (значок замка).',
        ],
        screens: [
          ('com.vivo.permissionmanager', 'com.vivo.permissionmanager.activity.BgStartUpManagerActivity'),
          ('com.iqoo.secure', 'com.iqoo.secure.ui.phoneoptimize.BgStartUpManager'),
          ('com.iqoo.secure', 'com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity'),
          ('com.vivo.abe', 'com.vivo.applicationbehaviorengine.ui.ExcessivePowerManagerActivity'),
        ],
      );
    }
    if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
      return const VendorGuide(
        vendor: 'Xiaomi / Redmi / POCO',
        steps: [
          'Безопасность → Разрешения → Автозапуск → включите MangaFlow.',
          'Настройки → Приложения → MangaFlow → Контроль активности (Батарея) → «Нет ограничений».',
          'Закрепите MangaFlow в недавних приложениях (значок замка).',
        ],
        screens: [
          ('com.miui.securitycenter', 'com.miui.permcenter.autostart.AutoStartManagementActivity'),
          ('com.miui.powerkeeper', 'com.miui.powerkeeper.ui.HiddenAppsConfigActivity'),
        ],
      );
    }
    if (m.contains('huawei') || m.contains('honor')) {
      return const VendorGuide(
        vendor: 'Huawei / Honor',
        steps: [
          'Настройки → Батарея → Запуск приложений → MangaFlow → «Управлять вручную» и включите все три переключателя.',
        ],
        screens: [
          ('com.huawei.systemmanager', 'com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity'),
          ('com.huawei.systemmanager', 'com.huawei.systemmanager.optimize.process.ProtectActivity'),
          ('com.hihonor.systemmanager', 'com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity'),
        ],
      );
    }
    if (m.contains('oppo') || m.contains('realme') || m.contains('oneplus')) {
      return const VendorGuide(
        vendor: 'OPPO / realme / OnePlus',
        steps: [
          'Настройки → Батарея → MangaFlow → «Разрешить фоновую активность» и «Разрешить автозапуск».',
          'Закрепите MangaFlow в недавних приложениях.',
        ],
        screens: [
          ('com.coloros.safecenter', 'com.coloros.safecenter.permission.startup.StartupAppListActivity'),
          ('com.coloros.safecenter', 'com.coloros.safecenter.startupapp.StartupAppListActivity'),
          ('com.oppo.safe', 'com.oppo.safe.permission.startup.StartupAppListActivity'),
          ('com.oneplus.security', 'com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity'),
        ],
      );
    }
    if (m.contains('samsung')) {
      return const VendorGuide(
        vendor: 'Samsung',
        steps: [
          'Настройки → Приложения → MangaFlow → Батарея → «Без ограничений».',
          'Настройки → Обслуживание устройства → Батарея → Ограничения фона: уберите MangaFlow из «спящих» приложений.',
        ],
        screens: [
          ('com.samsung.android.lool', 'com.samsung.android.sm.battery.ui.BatteryActivity'),
          ('com.samsung.android.sm', 'com.samsung.android.sm.ui.battery.BatteryActivity'),
        ],
      );
    }
    return null;
  }

  /// Opens the first vendor screen that exists; falls back to the app's system settings page.
  Future<bool> openSettings() async {
    for (final (pkg, cls) in screens) {
      try {
        final intent = AndroidIntent(
          componentName: cls,
          package: pkg,
          flags: const [Flag.FLAG_ACTIVITY_NEW_TASK],
        );
        if (await intent.canResolveActivity() ?? false) {
          await intent.launch();
          return true;
        }
      } catch (_) {
        continue;
      }
    }
    return openAppDetails();
  }

  static Future<bool> openAppDetails() async {
    if (!Platform.isAndroid) return false;
    try {
      final pkg = (await PackageInfo.fromPlatform()).packageName;
      await AndroidIntent(
        action: 'android.settings.APPLICATION_DETAILS_SETTINGS',
        data: 'package:$pkg',
        flags: const [Flag.FLAG_ACTIVITY_NEW_TASK],
      ).launch();
      return true;
    } catch (_) {
      return false;
    }
  }
}
