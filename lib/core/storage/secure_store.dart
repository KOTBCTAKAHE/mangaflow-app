import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/models/user.dart';

/// Keystore/Keychain-backed storage for credentials.
class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
      : _s = storage ?? const FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));

  final FlutterSecureStorage _s;

  static const _kRefresh = 'refresh_token';
  static const _kAccess = 'access_token';
  static const _kExpires = 'access_expires';
  static const _kUser = 'user';

  Future<void> saveTokens(AuthTokens t) async {
    await _s.write(key: _kRefresh, value: t.refresh);
    await _s.write(key: _kAccess, value: t.access);
    await _s.write(key: _kExpires, value: t.expiresAt.toIso8601String());
  }

  Future<AuthTokens?> readTokens() async {
    final refresh = await _s.read(key: _kRefresh);
    final access = await _s.read(key: _kAccess);
    if (refresh == null || access == null) return null;
    final exp = DateTime.tryParse(await _s.read(key: _kExpires) ?? '') ?? DateTime.now();
    return AuthTokens(access: access, refresh: refresh, expiresAt: exp);
  }

  Future<void> saveUser(UserProfile u) => _s.write(key: _kUser, value: jsonEncode(u.toJson()));

  Future<UserProfile?> readUser() async {
    final raw = await _s.read(key: _kUser);
    if (raw == null) return null;
    return UserProfile.fromJson((jsonDecode(raw) as Map).cast());
  }

  Future<void> clear() async {
    for (final k in const [_kRefresh, _kAccess, _kExpires, _kUser]) {
      await _s.delete(key: k);
    }
  }
}
