import 'dart:async';

import 'package:dio/dio.dart';

import '../../data/models/user.dart';
import '../config.dart';
import 'api_exception.dart';

/// Supplies and refreshes credentials for [ApiClient]. Implemented by the auth repository.
abstract interface class TokenProvider {
  Future<String?> accessToken();

  /// Refreshes the session; returns the new access token or null when the user must sign in again.
  Future<String?> refresh();
}

/// Thin Dio wrapper: base URL, auth header, single-flight token refresh, error mapping.
class ApiClient {
  ApiClient({required String baseUrl, TokenProvider? tokens, Dio? dio})
      : _tokens = tokens,
        dio = dio ??
            Dio(BaseOptions(
              baseUrl: _normalize(baseUrl),
              connectTimeout: AppConfig.connectTimeout,
              receiveTimeout: AppConfig.receiveTimeout,
              headers: {'Accept': 'application/json'},
            )) {
    this.dio.interceptors.add(_AuthInterceptor(this));
  }

  final Dio dio;
  TokenProvider? _tokens;
  Future<String?>? _refreshing;

  set tokens(TokenProvider? t) => _tokens = t;

  String get baseUrl => dio.options.baseUrl;
  set baseUrl(String v) => dio.options.baseUrl = _normalize(v);

  static String _normalize(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return '$u/api/v1';
  }

  Future<String?> _refreshOnce() {
    final t = _tokens;
    if (t == null) return Future.value(null);
    return _refreshing ??= t.refresh().whenComplete(() => _refreshing = null);
  }

  Future<T> _wrap<T>(Future<Response<dynamic>> Function() call, T Function(dynamic data) parse) async {
    try {
      final res = await call();
      return parse(res.data);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  Future<T> get<T>(String path, {Map<String, dynamic>? query, CancelToken? cancel, required T Function(dynamic) parse}) =>
      _wrap(() => dio.get<dynamic>(path, queryParameters: _clean(query), cancelToken: cancel), parse);

  Future<T> post<T>(String path, {Object? body, Map<String, dynamic>? query, required T Function(dynamic) parse}) =>
      _wrap(() => dio.post<dynamic>(path, data: body, queryParameters: _clean(query)), parse);

  Future<T> put<T>(String path, {Object? body, required T Function(dynamic) parse}) =>
      _wrap(() => dio.put<dynamic>(path, data: body), parse);

  Future<T> patch<T>(String path, {Object? body, required T Function(dynamic) parse}) =>
      _wrap(() => dio.patch<dynamic>(path, data: body), parse);

  Future<void> delete(String path, {Object? body, Map<String, dynamic>? query}) =>
      _wrap(() => dio.delete<dynamic>(path, data: body, queryParameters: _clean(query)), (_) {});

  static Map<String, dynamic>? _clean(Map<String, dynamic>? q) {
    if (q == null) return null;
    final out = <String, dynamic>{};
    q.forEach((k, v) {
      if (v == null) return;
      if (v is String && v.isEmpty) return;
      if (v is List && v.isEmpty) return;
      out[k] = v;
    });
    return out;
  }
}

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this.client);
  final ApiClient client;

  static const _retried = 'mf_retried';
  static const _noAuth = ['/auth/login', '/auth/register', '/auth/refresh'];

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    final path = options.path;
    if (!_noAuth.any(path.endsWith)) {
      final token = await client._tokens?.accessToken();
      if (token != null) options.headers['Authorization'] = 'Bearer $token';
    }
    // Repeated query params as `a=1&a=2` (FastAPI list style).
    options.listFormat = ListFormat.multi;
    handler.next(options);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final req = err.requestOptions;
    final unauthorized = err.response?.statusCode == 401;
    final hadAuth = req.headers.containsKey('Authorization');
    if (!unauthorized || !hadAuth || req.extra[_retried] == true || _noAuth.any(req.path.endsWith)) {
      return handler.next(err);
    }
    final fresh = await client._refreshOnce();
    if (fresh == null) return handler.next(err);
    req.headers['Authorization'] = 'Bearer $fresh';
    req.extra[_retried] = true;
    try {
      final res = await client.dio.fetch<dynamic>(req);
      handler.resolve(res);
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}

/// Raw auth endpoints (no interceptor recursion problems: they are excluded from auth handling).
class AuthApi {
  AuthApi(this.client);
  final ApiClient client;

  Future<(UserProfile, AuthTokens)> _auth(dynamic data) async {
    final m = (data as Map).cast<String, dynamic>();
    return (
      UserProfile.fromJson((m['user'] as Map).cast()),
      AuthTokens.fromJson((m['tokens'] as Map).cast()),
    );
  }

  Future<(UserProfile, AuthTokens)> login(String login, String password, {String? device}) async =>
      _auth(await client.post('/auth/login',
          body: {'login': login, 'password': password, 'device_name': device}, parse: (d) => d));

  Future<(UserProfile, AuthTokens)> register(
          {required String email, required String username, required String password, String? displayName, String? device}) async =>
      _auth(await client.post('/auth/register',
          body: {
            'email': email,
            'username': username,
            'password': password,
            if (displayName != null && displayName.isNotEmpty) 'display_name': displayName,
            'device_name': device,
          },
          parse: (d) => d));

  Future<(UserProfile, AuthTokens)> refresh(String refreshToken) async =>
      _auth(await client.post('/auth/refresh', body: {'refresh_token': refreshToken}, parse: (d) => d));

  Future<void> logout(String refreshToken) =>
      client.post('/auth/logout', body: {'refresh_token': refreshToken}, parse: (_) {});
}
