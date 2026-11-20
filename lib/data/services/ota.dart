import 'dart:io';

import 'package:flutter/services.dart';

/// Native side of over-the-air updates (MainActivity «mangaflow/ota», OtaUpdater.kt).
abstract final class Ota {
  static const _ch = MethodChannel('mangaflow/ota');

  /// The installed APK and its SHA-256 (what a delta patch must start from).
  static Future<({String path, String sha256})?> installed() async {
    if (!Platform.isAndroid) return null;
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('installedApk');
      if (m == null) return null;
      return (path: m['path'] as String, sha256: m['sha256'] as String);
    } catch (_) {
      return null;
    }
  }

  /// Rebuilds the new APK at [out] from the installed one + [patch]; returns its SHA-256.
  static Future<String> apply(String patch, String out) async =>
      (await _ch.invokeMethod<String>('apply', {'patch': patch, 'out': out}))!;

  static Future<String> sha256(String path) async => (await _ch.invokeMethod<String>('sha256', {'path': path}))!;

  /// 'started' — the system installer is open; 'permission' — allow installs from MangaFlow first.
  static Future<String> install(String path) async =>
      (await _ch.invokeMethod<String>('install', {'path': path})) ?? 'started';
}
