import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/config.dart';
import 'package:mangaflow/core/network/proxy.dart';

/// Minimal SOCKS5 server (user/password auth) that sends every CONNECT to [target].
Future<(ServerSocket, List<String>)> _fakeSocks(int target, {String user = 'u', String pass = 'p'}) async {
  final seen = <String>[];
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((c) {
    final buf = <int>[];
    var stage = 0;
    Socket? up;
    c.listen((d) async {
      if (up != null) {
        up!.add(d);
        return;
      }
      buf.addAll(d);
      if (stage == 0 && buf.length >= 2 && buf.length >= 2 + buf[1]) {
        final methods = buf.sublist(2, 2 + buf[1]);
        buf.removeRange(0, 2 + buf[1]);
        c.add([5, methods.contains(2) ? 2 : 0xff]);
        stage = 1;
      }
      if (stage == 1 && buf.length >= 2 && buf.length >= 3 + buf[1] && buf.length >= 3 + buf[1] + buf[2 + buf[1]]) {
        final ul = buf[1];
        final u = utf8.decode(buf.sublist(2, 2 + ul));
        final pl = buf[2 + ul];
        final p = utf8.decode(buf.sublist(3 + ul, 3 + ul + pl));
        buf.removeRange(0, 3 + ul + pl);
        c.add([1, u == user && p == pass ? 0 : 1]);
        stage = 2;
      }
      if (stage == 2 && buf.length >= 5 && buf[3] == 3 && buf.length >= 7 + buf[4]) {
        final host = utf8.decode(buf.sublist(5, 5 + buf[4]));
        final port = buf[5 + buf[4]] << 8 | buf[6 + buf[4]];
        seen.add('$host:$port');
        buf.removeRange(0, 7 + buf[4]);
        stage = 3;
        final s = await Socket.connect(InternetAddress.loopbackIPv4, target);
        up = s;
        s.listen(c.add, onDone: c.destroy);
        c.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
        if (buf.isNotEmpty) s.add(Uint8List.fromList(buf));
        buf.clear();
      }
    }, onDone: () => up?.destroy());
  });
  return (server, seen);
}

void main() {
  test('proxy links parse', () {
    final p = ProxyConfig.parseUrl('socks5://bob:s%40cret@10.0.0.2:1080')!;
    expect([p.type, p.host, p.port, p.username, p.password], [ProxyType.socks5, '10.0.0.2', 1080, 'bob', 's@cret']);
    expect(ProxyConfig.parseUrl('http://proxy.example.com:3128')!.type, ProxyType.http);
    expect(ProxyConfig.parseUrl('1.2.3.4:8080', fallback: ProxyType.http)!.type, ProxyType.http);
    expect(ProxyConfig.parseUrl('нет'), isNull);
    expect(ProxyConfig.fromJson(p.toJson()), p);
  });

  test('only the MangaFlow server goes through the proxy unless all traffic is on; LAN is direct', () async {
    final server = Uri.parse(AppConfig.defaultApiBaseUrl);
    await AppProxy.apply(const ProxyConfig(type: ProxyType.http, host: 'proxy.example.com', port: 3128, username: 'a', password: 'b'));
    expect(AppProxy.findProxy(server), 'PROXY a:b@proxy.example.com:3128');
    expect(AppProxy.findProxy(Uri.parse('https://img.example.org/1.jpg')), 'DIRECT');
    await AppProxy.apply(const ProxyConfig(type: ProxyType.http, host: 'proxy.example.com', port: 3128, allTraffic: true));
    expect(AppProxy.findProxy(Uri.parse('https://img.example.org/1.jpg')), 'PROXY proxy.example.com:3128');
    expect(AppProxy.findProxy(Uri.parse('http://192.168.1.20:8080/x')), 'DIRECT');
    await AppProxy.apply(const ProxyConfig());
    expect(AppProxy.findProxy(server), 'DIRECT');
  });

  test('SOCKS5: requests go through the proxy with remote DNS and auth', () async {
    final web = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    web.listen((r) {
      r.response.write('hello ${r.uri.path}');
      r.response.close();
    });
    final (socks, seen) = await _fakeSocks(web.port);
    await AppProxy.apply(ProxyConfig(type: ProxyType.socks5, host: '127.0.0.1', port: socks.port, username: 'u', password: 'p', allTraffic: true));
    final client = HttpClient()..findProxy = AppProxy.findProxy;
    final req = await client.getUrl(Uri.parse('http://manga.example.test/page'));
    final res = await req.close();
    expect(await res.transform(utf8.decoder).join(), 'hello /page');
    expect(seen, ['manga.example.test:80'], reason: 'the proxy resolves the name, not the phone');

    // wrong password: the request fails instead of silently going direct
    client.close(force: true);
    await AppProxy.apply(ProxyConfig(type: ProxyType.socks5, host: '127.0.0.1', port: socks.port, username: 'u', password: 'x', allTraffic: true));
    final fresh = HttpClient()..findProxy = AppProxy.findProxy;
    await expectLater(() async {
      final r = await fresh.getUrl(Uri.parse('http://manga.example.test/page'));
      final s = await r.close();
      if (s.statusCode != 200) throw HttpException('status ${s.statusCode}');
    }(), throwsA(anything));
    fresh.close(force: true);
    await AppProxy.apply(const ProxyConfig());
    await socks.close();
    await web.close(force: true);
  });
}
