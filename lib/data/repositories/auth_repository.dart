import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/storage/secure_store.dart';
import '../models/user.dart';

sealed class AuthState {
  const AuthState();
}

/// Using the app locally without an account (fully supported).
class Guest extends AuthState {
  const Guest();
}

class SignedIn extends AuthState {
  const SignedIn(this.user);
  final UserProfile user;
}

/// Owns tokens; implements [TokenProvider] for [ApiClient].
class AuthController extends StateNotifier<AuthState> implements TokenProvider {
  AuthController(this._client, this._store) : _api = AuthApi(_client), super(const Guest()) {
    _client.tokens = this;
  }

  final ApiClient _client;
  final SecureStore _store;
  final AuthApi _api;
  AuthTokens? _tokens;

  /// Fired after sign-in / sign-out so sync can react.
  final _events = StreamController<AuthState>.broadcast();
  Stream<AuthState> get events => _events.stream;

  bool get isSignedIn => state is SignedIn;

  Future<void> restore() async {
    _tokens = await _store.readTokens();
    final user = await _store.readUser();
    if (_tokens != null && user != null) state = SignedIn(user);
  }

  String get _device => '${Platform.operatingSystem} · MangaFlow';

  Future<void> login(String login, String password) async {
    final (user, tokens) = await _api.login(login.trim(), password, device: _device);
    await _signedIn(user, tokens);
  }

  Future<void> register({required String email, required String username, required String password, String? displayName}) async {
    final (user, tokens) = await _api.register(
        email: email.trim(), username: username.trim(), password: password, displayName: displayName, device: _device);
    await _signedIn(user, tokens);
  }

  Future<void> _signedIn(UserProfile user, AuthTokens tokens) async {
    _tokens = tokens;
    await _store.saveTokens(tokens);
    await _store.saveUser(user);
    state = SignedIn(user);
    _events.add(state);
  }

  Future<void> updateUser(UserProfile user) async {
    await _store.saveUser(user);
    if (state is SignedIn) state = SignedIn(user);
  }

  Future<void> logout() async {
    final t = _tokens;
    if (t != null) {
      try {
        await _api.logout(t.refresh);
      } on ApiException {
        // offline: the server session expires on its own
      }
    }
    await _signedOut();
  }

  Future<void> _signedOut() async {
    _tokens = null;
    await _store.clear();
    state = const Guest();
    _events.add(state);
  }

  // ---- TokenProvider
  @override
  Future<String?> accessToken() async {
    final t = _tokens;
    if (t == null) return null;
    if (t.isExpiringSoon) return refresh();
    return t.access;
  }

  @override
  Future<String?> refresh() async {
    final t = _tokens;
    if (t == null) return null;
    try {
      final (user, tokens) = await _api.refresh(t.refresh);
      _tokens = tokens;
      await _store.saveTokens(tokens);
      await _store.saveUser(user);
      if (state is! SignedIn) state = SignedIn(user);
      return tokens.access;
    } on ApiException catch (e) {
      if (e.isOffline) return t.access; // keep session while offline
      await _signedOut();
      return null;
    }
  }

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }
}
