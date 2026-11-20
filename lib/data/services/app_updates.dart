import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/config.dart';
import '../local/daos.dart';
import 'ota.dart';

/// A delta from the installed APK to the new one (MFDELTA1, built in CI).
class OtaPatch {
  const OtaPatch({required this.url, required this.name, required this.size, required this.sha256, required this.toSha256});
  final String url, name, sha256, toSha256;
  final int size;
}

class AppRelease {
  const AppRelease({
    this.patch,
    this.apkSha256,
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
  final String? apkSha256;

  /// Small update: present when the installed APK is one CI made a patch from.
  final OtaPatch? patch;
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
    var asset = pickAsset(assets, Platform.version);
    final (patch, apkSha) = await _ota(assets);
    if (patch != null) {
      // the patch decides the ABI (the one actually installed); its full APK is the fallback
      final abi = RegExp(r'-([a-z0-9]+)\.mfdelta$').firstMatch(patch.name)?.group(1);
      asset = assets.where((a) => (a['name'] as String? ?? '') == 'MangaFlow-$tag-$abi.apk').firstOrNull ?? asset;
    }
    return AppRelease(
      patch: patch,
      apkSha256: apkSha[asset?['name']],
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

  /// ota.json of the release → the patch for the installed APK (by its SHA-256) + APK hashes.
  Future<(OtaPatch?, Map<String, String>)> _ota(List<Map<String, dynamic>> assets) async {
    final m = assets.where((a) => a['name'] == 'ota.json').firstOrNull;
    if (m == null) return (null, const <String, String>{});
    try {
      final res = await _http.get<String>(m['browser_download_url'] as String,
          options: Options(responseType: ResponseType.plain, headers: {'Accept': 'application/octet-stream'}));
      final j = jsonDecode(res.data!) as Map<String, dynamic>;
      final hashes = {for (final a in (j['apks'] as List? ?? const [])) (a as Map)['name'] as String: a['sha256'] as String};
      final me = await Ota.installed();
      if (me == null) return (null, hashes);
      final p = (j['patches'] as List? ?? const []).cast<Map>().where((p) => p['from_sha256'] == me.sha256).firstOrNull;
      if (p == null) return (null, hashes);
      final url = assets.where((a) => a['name'] == p['name']).firstOrNull?['browser_download_url'] as String?;
      if (url == null) return (null, hashes);
      return (
        OtaPatch(url: url, name: p['name'] as String, size: (p['size'] as num).toInt(), sha256: p['sha256'] as String,
            toSha256: p['to_sha256'] as String),
        hashes,
      );
    } catch (_) {
      return (null, const <String, String>{});
    }
  }

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
