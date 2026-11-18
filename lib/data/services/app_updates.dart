import 'dart:io';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/config.dart';
import '../local/daos.dart';

class AppRelease {
  const AppRelease({
    required this.version,
    required this.tag,
    required this.notes,
    required this.pageUrl,
    required this.apkUrl,
    required this.apkName,
    required this.apkSize,
  });

  final String version;
  final String tag;
  final String notes;
  final String pageUrl;
  final String? apkUrl;
  final String? apkName;
  final int apkSize;
}

/// Checks GitHub Releases of the app repository for a newer version.
class AppUpdater {
  AppUpdater(this.kv, {Dio? http})
      : _http = http ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              headers: {'Accept': 'application/vnd.github+json'},
            ));

  final KvDao kv;
  final Dio _http;

  static const _checkedKey = 'update_checked_at';
  static const _skippedKey = 'update_skipped_version';
  static const autoInterval = Duration(hours: 12);

  Future<String> currentVersion() async => (await PackageInfo.fromPlatform()).version;

  /// `null` when up to date (or when an automatic check is throttled/skipped).
  Future<AppRelease?> check({bool manual = false}) async {
    if (!manual) {
      final last = DateTime.tryParse(await kv.get(_checkedKey) ?? '');
      if (last != null && DateTime.now().difference(last) < autoInterval) return null;
    }
    final res = await _http.get<Map<String, dynamic>>(
        'https://api.github.com/repos/${AppConfig.githubRepo}/releases/latest');
    await kv.set(_checkedKey, DateTime.now().toIso8601String());
    final data = res.data!;
    final tag = data['tag_name'] as String? ?? '';
    final latest = tag.replaceFirst(RegExp('^v'), '');
    final current = await currentVersion();
    if (compareVersions(latest, current) <= 0) return null;
    if (!manual && await kv.get(_skippedKey) == latest) return null;

    final assets = [for (final a in data['assets'] as List? ?? const []) (a as Map).cast<String, dynamic>()];
    final asset = pickAsset(assets, Platform.version);
    return AppRelease(
      version: latest,
      tag: tag,
      notes: (data['body'] as String? ?? '').trim(),
      pageUrl: data['html_url'] as String? ?? 'https://github.com/${AppConfig.githubRepo}/releases',
      apkUrl: asset?['browser_download_url'] as String?,
      apkName: asset?['name'] as String?,
      apkSize: asset?['size'] as int? ?? 0,
    );
  }

  Future<void> skip(String version) => kv.set(_skippedKey, version);

  /// arm64 / armv7 / universal by the running VM's ABI (`Platform.version` ends with `on "android_arm64"`).
  static Map<String, dynamic>? pickAsset(List<Map<String, dynamic>> assets, String platformVersion) {
    final apks = assets.where((a) => (a['name'] as String? ?? '').endsWith('.apk')).toList();
    if (apks.isEmpty) return null;
    final abi = platformVersion.contains('android_arm64')
        ? 'arm64'
        : platformVersion.contains('android_arm')
            ? 'armv7'
            : 'universal';
    return apks.where((a) => (a['name'] as String).contains('-$abi')).firstOrNull ??
        apks.where((a) => (a['name'] as String).contains('universal')).firstOrNull ??
        apks.first;
  }
}

/// Semantic-ish comparison of "1.2.10" style versions.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [for (final p in v.split(RegExp(r'[.+-]')).take(3)) int.tryParse(p) ?? 0];
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0, y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}
