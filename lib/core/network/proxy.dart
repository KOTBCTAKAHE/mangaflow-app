import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

enum ProxyType {
  none('none', 'Без прокси'),
  http('http', 'HTTP'),
  socks5('socks5', 'SOCKS5');

  const ProxyType(this.api, this.label);
  final String api;
  final String label;

  static ProxyType parse(String? v) => values.firstWhere((t) => t.api == v, orElse: () => ProxyType.none);
}

/// Device-only: how the app reaches the MangaFlow server (never synced to the account).
@immutable
class ProxyConfig {
  const ProxyConfig({
    this.type = ProxyType.none,
    this.host = '',
    this.port = 0,
    this.username = '',
    this.password = '',
    this.allTraffic = false,
  });

  final ProxyType type;
  final String host;
  final int port;
  final String username;
  final String password;

  /// false: only requests to the MangaFlow server; true: everything the app loads
  /// (images straight from sources, update downloads…). The local network is always direct.
  final bool allTraffic;

  bool get enabled => type != ProxyType.none && host.isNotEmpty && port > 0 && port < 65536;

  String get display => enabled ? '${type.label} · $host:$port' : 'Выключен';

  ProxyConfig copyWith({ProxyType? type, String? host, int? port, String? username, String? password, bool? allTraffic}) =>
      ProxyConfig(
        type: type ?? this.type,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password: password ?? this.password,
        allTraffic: allTraffic ?? this.allTraffic,
      );

  Map<String, dynamic> toJson() => {
        'type': type.api,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'all_traffic': allTraffic,
      };

  factory ProxyConfig.fromJson(Object? j) {
    if (j is! Map) return const ProxyConfig();
    return ProxyConfig(
      type: ProxyType.parse(j['type'] as String?),
      host: (j['host'] as String? ?? '').trim(),
      port: (j['port'] as num?)?.toInt() ?? 0,
      username: j['username'] as String? ?? '',
      password: j['password'] as String? ?? '',
      allTraffic: j['all_traffic'] as bool? ?? false,
    );
  }

  /// Parses `socks5://user:pass@host:1080` / `http://host:3128` / `host:port`.
  static ProxyConfig? parseUrl(String text, {ProxyType fallback = ProxyType.socks5}) {
    var t = text.trim();
    if (t.isEmpty) return null;
    if (!t.contains('://')) t = '${fallback == ProxyType.http ? 'http' : 'socks5'}://$t';
    final u = Uri.tryParse(t);
    if (u == null || u.host.isEmpty || !u.hasPort) return null;
    final type = switch (u.scheme.toLowerCase()) {
      'http' || 'https' => ProxyType.http,
      'socks' || 'socks5' || 'socks5h' => ProxyType.socks5,
      _ => null,
    };
    if (type == null) return null;
    final info = u.userInfo.split(':');
    return ProxyConfig(
      type: type,
      host: u.host,
      port: u.port,
      username: info.isNotEmpty ? Uri.decodeComponent(info.first) : '',
      password: info.length > 1 ? Uri.decodeComponent(info.sublist(1).join(':')) : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProxyConfig &&
      other.type == type &&
      other.host == host &&
      other.port == port &&
      other.username == username &&
      other.password == password &&
      other.allTraffic == allTraffic;

  @override
  int get hashCode => Object.hash(type, host, port, username, password, allTraffic);
}

/// Routes the app's HTTP through the configured proxy, in every isolate that calls [apply].
///
/// Works at the dart:io level ([HttpOverrides]), so Dio, image loading and downloads all
/// follow it. HTTP proxies are used directly; SOCKS5 goes through a tiny loopback relay that
/// speaks HTTP CONNECT to the HTTP client and SOCKS5 (with remote DNS) to the proxy.
abstract final class AppProxy {
  static ProxyConfig _config = const ProxyConfig();
  static _SocksRelay? _relay;
  static final String _serverHost = Uri.parse(AppConfig.defaultApiBaseUrl).host;

  static ProxyConfig get config => _config;

  static Future<void> apply(ProxyConfig c) async {
    if (c.enabled && c.type == ProxyType.socks5) {
      final relay = _relay ??= _SocksRelay();
      relay.upstream = c;
      await relay.start();
    } else {
      await _relay?.stop();
      _relay = null;
    }
    _config = c;
    if (HttpOverrides.current is! _ProxyOverrides) HttpOverrides.global = _ProxyOverrides();
  }

  /// For background isolates: reads the proxy from the saved settings.
  static Future<void> applyFromPrefs(SharedPreferences prefs) async {
    try {
      final raw = prefs.getString('app_settings_v1');
      if (raw == null) return;
      await apply(ProxyConfig.fromJson((jsonDecode(raw) as Map)['proxy']));
    } catch (_) {/* no proxy is better than no background work */}
  }

  static String findProxy(Uri uri) {
    final c = _config;
    if (!c.enabled || _isLocal(uri.host)) return 'DIRECT';
    if (!c.allTraffic && uri.host != _serverHost) return 'DIRECT';
    if (c.type == ProxyType.socks5) {
      final port = _relay?.port;
      return port == null ? 'DIRECT' : 'PROXY 127.0.0.1:$port';
    }
    final auth = c.username.isEmpty ? '' : '${c.username}:${c.password}@';
    return 'PROXY $auth${c.host}:${c.port}';
  }

  static bool _isLocal(String host) {
    if (host == 'localhost' || host.endsWith('.local')) return true;
    final a = InternetAddress.tryParse(host);
    if (a == null) return false;
    if (a.isLoopback || a.isLinkLocal) return true;
    final b = a.rawAddress;
    if (a.type == InternetAddressType.IPv4) {
      return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168);
    }
    return (b[0] & 0xfe) == 0xfc; // IPv6 unique local
  }

  /// Checks that the MangaFlow server answers through [c]. Returns null on success or an error text.
  static Future<String?> test(ProxyConfig c) async {
    final previous = _config;
    final sw = Stopwatch()..start();
    try {
      await apply(c.copyWith(allTraffic: false));
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12)
        ..findProxy = findProxy;
      try {
        final base = AppConfig.defaultApiBaseUrl.replaceAll(RegExp(r'/+$'), '');
        final req = await client.getUrl(Uri.parse('$base/api/v1/health/live')).timeout(const Duration(seconds: 15));
        final res = await req.close().timeout(const Duration(seconds: 15));
        await res.drain<void>();
        if (res.statusCode >= 500) return 'Сервер ответил ${res.statusCode}';
        if (res.statusCode == 407) return 'Прокси просит логин и пароль (407)';
        return null;
      } finally {
        client.close(force: true);
      }
    } on TimeoutException {
      return 'Нет ответа за ${sw.elapsed.inSeconds} с';
    } on SocketException catch (e) {
      return _socketError(e);
    } on HttpException catch (e) {
      return e.message.contains('407') ? 'Неверный логин или пароль прокси' : 'Ошибка прокси: ${e.message}';
    } on HandshakeException {
      return 'Не удалось установить защищённое соединение через прокси';
    } catch (e) {
      return 'Ошибка: $e';
    } finally {
      await apply(previous);
    }
  }

  static String _socketError(SocketException e) {
    final m = e.message.toLowerCase();
    if (m.contains('lookup') || m.contains('host')) return 'Адрес прокси не найден';
    if (m.contains('refused')) return 'Прокси отклонил соединение — проверьте адрес и порт';
    return 'Сеть: ${e.message}';
  }
}

class _ProxyOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => super.createHttpClient(context)..findProxy = AppProxy.findProxy;
}

/// Loopback HTTP CONNECT → SOCKS5 relay (RFC 1928, user/password RFC 1929, remote DNS).
class _SocksRelay {
  ProxyConfig upstream = const ProxyConfig();
  ServerSocket? _server;
  int? get port => _server?.port;

  Future<void> start() async {
    if (_server != null) return;
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = s;
    s.listen((client) => unawaited(_serve(client)), onError: (Object _) {});
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close();
  }

  Future<void> _serve(Socket client) async {
    final head = BytesBuilder(copy: false);
    late final StreamSubscription<Uint8List> sub;
    Socket? remote;
    final ready = Completer<Uint8List>();
    sub = client.listen((data) {
      if (remote != null) {
        remote!.add(data);
        return;
      }
      head.add(data);
      final bytes = head.toBytes();
      final end = _indexOf(bytes, const [13, 10, 13, 10]);
      if (end >= 0 && !ready.isCompleted) {
        sub.pause();
        ready.complete(bytes);
      } else if (bytes.length > 16384 && !ready.isCompleted) {
        ready.completeError(const FormatException('header too long'));
      }
    }, onError: (Object _) => client.destroy(), onDone: () {
      remote?.destroy();
      if (!ready.isCompleted) ready.completeError(const SocketException('client closed'));
    }, cancelOnError: true);

    try {
      final bytes = await ready.future;
      final end = _indexOf(bytes, const [13, 10, 13, 10]) + 4;
      final line = latin1.decode(bytes.sublist(0, _indexOf(bytes, const [13, 10]))).split(' ');
      if (line.length < 2) throw const FormatException('bad request');
      final connect = line[0].toUpperCase() == 'CONNECT';
      String host;
      int port;
      if (connect) {
        final i = line[1].lastIndexOf(':');
        host = line[1].substring(0, i).replaceAll('[', '').replaceAll(']', '');
        port = int.parse(line[1].substring(i + 1));
      } else {
        final u = Uri.parse(line[1]);
        host = u.host;
        port = u.hasPort ? u.port : 80;
      }
      final r = await _socksConnect(host, port).timeout(const Duration(seconds: 20));
      remote = r.socket;
      if (connect) {
        client.add(latin1.encode('HTTP/1.1 200 Connection established\r\n\r\n'));
        if (bytes.length > end) r.socket.add(bytes.sublist(end));
      } else {
        r.socket.add(bytes); // absolute-form request: servers accept it as is
      }
      if (r.extra.isNotEmpty) client.add(r.extra);
      r.sub.onData(client.add);
      r.sub.onDone(() => client.destroy());
      r.sub.onError((Object _) => client.destroy());
      r.sub.resume();
      sub.resume();
    } catch (_) {
      try {
        client.add(latin1.encode('HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'));
        await client.flush();
      } catch (_) {}
      client.destroy();
      remote?.destroy();
    }
  }

  /// Connects to [host]:[port] through the SOCKS5 proxy. The returned subscription is paused.
  Future<({Socket socket, StreamSubscription<Uint8List> sub, Uint8List extra})> _socksConnect(String host, int port) async {
    final c = upstream;
    final s = await Socket.connect(c.host, c.port, timeout: const Duration(seconds: 12));
    s.setOption(SocketOption.tcpNoDelay, true);
    final buf = BytesBuilder(copy: false);
    var waiter = Completer<void>();
    var done = false;
    final sub = s.listen((d) {
      buf.add(d);
      if (!waiter.isCompleted) waiter.complete();
    }, onError: (Object e) {
      if (!waiter.isCompleted) waiter.completeError(e);
    }, onDone: () {
      done = true;
      if (!waiter.isCompleted) waiter.complete();
    });
    Future<Uint8List> read(int n) async {
      while (buf.length < n) {
        if (done) throw const SocketException('SOCKS proxy closed the connection');
        waiter = Completer<void>();
        await waiter.future;
      }
      final all = buf.takeBytes();
      buf.add(all.sublist(n));
      return Uint8List.sublistView(all, 0, n);
    }

    try {
      final auth = c.username.isNotEmpty;
      s.add(auth ? [5, 2, 0, 2] : [5, 1, 0]);
      final hello = await read(2);
      if (hello[0] != 5) throw const SocketException('not a SOCKS5 proxy');
      if (hello[1] == 2) {
        final u = utf8.encode(c.username), p = utf8.encode(c.password);
        s.add([1, u.length, ...u, p.length, ...p]);
        final ok = await read(2);
        if (ok[1] != 0) throw const SocketException('SOCKS5 authentication failed');
      } else if (hello[1] != 0) {
        throw const SocketException('SOCKS5: no acceptable auth method');
      }
      final ip = InternetAddress.tryParse(host);
      final List<int> addr;
      if (ip != null && ip.type == InternetAddressType.IPv4) {
        addr = [1, ...ip.rawAddress];
      } else if (ip != null) {
        addr = [4, ...ip.rawAddress];
      } else {
        final h = utf8.encode(host);
        addr = [3, h.length, ...h];
      }
      s.add([5, 1, 0, ...addr, port >> 8, port & 0xff]);
      final rep = await read(4);
      if (rep[1] != 0) throw SocketException('SOCKS5 connect failed (code ${rep[1]})');
      final skip = switch (rep[3]) { 1 => 4, 4 => 16, 3 => (await read(1))[0], _ => 0 };
      await read(skip + 2);
      sub.pause();
      return (socket: s, sub: sub, extra: buf.takeBytes());
    } catch (_) {
      s.destroy();
      rethrow;
    }
  }

  static int _indexOf(Uint8List b, List<int> pat) {
    outer:
    for (var i = 0; i + pat.length <= b.length; i++) {
      for (var j = 0; j < pat.length; j++) {
        if (b[i + j] != pat[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}
