import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/network/api_client.dart';
import 'package:mangaflow/core/storage/secure_store.dart';
import 'package:mangaflow/data/models/user.dart';
import 'package:mangaflow/data/repositories/auth_repository.dart';

/// Fake server: counts refreshes; status configurable; slow so calls overlap.
class FakeAdapter implements HttpClientAdapter {
  int refreshes = 0;
  int status = 200;
  final usedRefreshTokens = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    if (o.path.endsWith('/auth/refresh')) {
      refreshes++;
      usedRefreshTokens.add((o.data as Map)['refresh_token'] as String);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      if (status != 200) {
        return ResponseBody.fromString(jsonEncode({'error': {'code': 'x', 'message': 'x'}}), status,
            headers: {'content-type': ['application/json']});
      }
      return ResponseBody.fromString(
        jsonEncode({
          'user': {'id': 'u', 'email': 'a@b.c', 'username': 'a'},
          'tokens': {'access_token': 'access$refreshes', 'refresh_token': 'refresh$refreshes', 'expires_in': 900},
        }),
        200,
        headers: {'content-type': ['application/json']},
      );
    }
    return ResponseBody.fromString('{}', 200, headers: {'content-type': ['application/json']});
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late FakeAdapter server;
  late AuthController auth;
  late SecureStore store;

  Future<void> signedInWith({required bool expiring}) async {
    FlutterSecureStorage.setMockInitialValues({});
    store = SecureStore();
    await store.saveTokens(AuthTokens(
      access: 'access0',
      refresh: 'refresh0',
      expiresAt: DateTime.now().add(expiring ? const Duration(seconds: 10) : const Duration(minutes: 10)),
    ));
    await store.saveUser(const UserProfile(id: 'u', email: 'a@b.c', username: 'a'));
    server = FakeAdapter();
    final client = ApiClient(baseUrl: 'http://x');
    client.dio.httpClientAdapter = server;
    auth = AuthController(client, store);
    await auth.restore();
  }

  test('parallel requests with an expiring token refresh only once', () async {
    await signedInWith(expiring: true);
    final tokens = await Future.wait([for (var i = 0; i < 6; i++) auth.accessToken()]);
    expect(server.refreshes, 1);
    expect(tokens.toSet(), {'access1'});
    expect(auth.isSignedIn, isTrue);
  });

  test('server errors (502, 429) or no network do not sign the user out', () async {
    await signedInWith(expiring: true);
    for (final code in [502, 503, 429, 500]) {
      server.status = code;
      await auth.refresh();
      expect(auth.isSignedIn, isTrue, reason: 'HTTP $code');
    }
  });

  test('a rejected refresh token (401) signs out', () async {
    await signedInWith(expiring: true);
    server.status = 401;
    expect(await auth.refresh(), isNull);
    expect(auth.isSignedIn, isFalse);
  });

  test('tokens rotated by another process are adopted instead of replaying the stale one', () async {
    await signedInWith(expiring: true);
    // background update check refreshed meanwhile and stored a fresh pair
    await store.saveTokens(AuthTokens(access: 'bgAccess', refresh: 'bgRefresh', expiresAt: DateTime.now().add(const Duration(minutes: 14))));
    expect(await auth.accessToken(), 'bgAccess');
    expect(server.refreshes, 0);
    // later refreshes use the adopted token, never the stale refresh0
    await auth.refresh();
    expect(server.usedRefreshTokens, ['bgRefresh']);
  });
}
