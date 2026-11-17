import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config.dart';
import '../models/library.dart';
import '../models/settings.dart';

/// Holds [AppSettings] and persists every change to SharedPreferences.
class SettingsController extends StateNotifier<AppSettings> {
  SettingsController(this._prefs) : super(_load(_prefs));

  final SharedPreferences _prefs;
  static const _key = 'app_settings_v1';

  static AppSettings _load(SharedPreferences prefs) {
    final raw = prefs.getString(_key);
    if (raw == null) {
      return AppSettings(apiBaseUrl: AppConfig.defaultApiBaseUrl, updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    }
    try {
      return AppSettings.fromJson((jsonDecode(raw) as Map).cast(), fallbackUrl: AppConfig.defaultApiBaseUrl);
    } catch (_) {
      return AppSettings(apiBaseUrl: AppConfig.defaultApiBaseUrl, updatedAt: DateTime.now().toUtc());
    }
  }

  Future<void> _save(AppSettings s) async {
    state = s;
    await _prefs.setString(_key, jsonEncode(s.toJson()));
  }

  /// Local change (bumps updatedAt → will be pushed on next sync).
  Future<void> update(AppSettings Function(AppSettings s) change) => _save(change(state));

  /// Device-only change that must not win over remote settings (e.g. brightness slider).
  Future<void> updateLocalOnly(AppSettings Function(AppSettings s) change) {
    final next = change(state);
    return _save(next.copyWith(updatedAt: state.updatedAt));
  }

  Future<void> applyRemote(Map<String, dynamic> remote, DateTime remoteUpdatedAt) async {
    if (!remoteUpdatedAt.isAfter(state.updatedAt)) return;
    await _save(state.mergeRemote(remote, remoteUpdatedAt));
  }

  Future<void> setDefaultReadingMode(ReadingMode? mode) => update((s) => s.copyWith(defaultReadingMode: () => mode));
}
