import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Phone-to-phone transfer over a hotspot or a shared Wi-Fi: the sender serves
/// the ready .cbz pack over plain HTTP (no internet, Wi-Fi speed), the receiver
/// finds it by UDP beacons or by asking the hotspot gateway, and needs the
/// 4-digit code shown on the sender's screen.
const wifiTransferPort = 47810;
const wifiBeaconPort = 47811;

class WifiOffer {
  const WifiOffer({
    required this.host,
    required this.port,
    required this.device,
    required this.title,
    required this.chapters,
    required this.bytes,
  });
  final String host;
  final int port;
  final String device, title;
  final int chapters, bytes;

  String get address => '$host:$port';

  factory WifiOffer.fromJson(String host, Map<String, dynamic> j) => WifiOffer(
        host: host,
        port: (j['port'] as num?)?.toInt() ?? wifiTransferPort,
        device: j['device'] as String? ?? 'Телефон',
        title: j['title'] as String? ?? '',
        chapters: (j['chapters'] as num?)?.toInt() ?? 0,
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() =>
      {'mf': 1, 'port': port, 'device': device, 'title': title, 'chapters': chapters, 'bytes': bytes};
}

class WifiSendStatus {
  const WifiSendStatus({this.client, this.sent = 0, this.total = 0, this.done = false, this.bytesPerSecond = 0});
  final String? client;
  final int sent, total;
  final bool done;
  final double bytesPerSecond;
  double get progress => total == 0 ? 0 : sent / total;
}

/// Our IPv4 addresses that another phone could reach (hotspot / Wi-Fi interfaces first).
Future<List<String>> localAddresses() async {
  final out = <String>[];
  try {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    int score(NetworkInterface i) {
      final n = i.name.toLowerCase();
      if (n.contains('ap') || n.startsWith('swlan') || n.contains('softap')) return 0; // hotspot
      if (n.startsWith('wlan') || n.startsWith('en') || n.startsWith('eth')) return 1;
      if (n.contains('rmnet') || n.contains('ccmni') || n.contains('tun')) return 9; // mobile data / VPN
      return 5;
    }

    ifs.sort((a, b) => score(a).compareTo(score(b)));
    for (final i in ifs) {
      if (i.name.toLowerCase().contains('rmnet') || i.name.toLowerCase().contains('ccmni')) continue;
      for (final a in i.addresses) {
        if (!a.isLoopback && !a.isLinkLocal) out.add(a.address);
      }
    }
  } catch (_) {}
  return out;
}

class WifiSendSession {
  WifiSendSession._(this._server, this.pin, this.offer, this._file);

  final HttpServer _server;
  final String pin;
  final WifiOffer offer;
  final File _file;
  final _status = StreamController<WifiSendStatus>.broadcast();
  Timer? _beacon;
  RawDatagramSocket? _udp;
  var _badPins = 0;

  Stream<WifiSendStatus> get status => _status.stream;
  int get port => _server.port;

  static Future<WifiSendSession> start({
    required File pack,
    required String title,
    required int chapters,
    required String device,
    int port = wifiTransferPort,
    bool beacon = true,
    String? pin,
  }) async {
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0); // port taken: any free one
    }
    final code = pin ?? (Random.secure().nextInt(9000) + 1000).toString();
    final offer = WifiOffer(
        host: '', port: server.port, device: device, title: title, chapters: chapters, bytes: await pack.length());
    final s = WifiSendSession._(server, code, offer, pack);
    server.listen(s._handle, onError: (Object _) {});
    if (beacon) await s._startBeacon();
    return s;
  }

  Future<void> _startBeacon() async {
    try {
      final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      udp.broadcastEnabled = true;
      _udp = udp;
      final payload = utf8.encode(jsonEncode(offer.toJson()));
      void send() {
        try {
          udp.send(payload, InternetAddress('255.255.255.255'), wifiBeaconPort);
        } catch (_) {}
      }

      send();
      _beacon = Timer.periodic(const Duration(seconds: 1), (_) => send());
    } catch (_) {
      // no broadcast on this network: the receiver still finds us via the gateway probe
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Access-Control-Allow-Origin', '*');
    try {
      switch (req.uri.path) {
        case '/hello':
          _json(res, offer.toJson());
        case '/pack':
          if (_badPins >= 10) {
            res.statusCode = HttpStatus.tooManyRequests;
            _json(res, {'error': 'too_many_attempts'});
            return;
          }
          if (req.uri.queryParameters['k'] != pin) {
            _badPins++;
            res.statusCode = HttpStatus.forbidden;
            _json(res, {'error': 'bad_pin'});
            return;
          }
          final client = req.uri.queryParameters['from'] ?? req.connectionInfo?.remoteAddress.address ?? 'телефон';
          final total = await _file.length();
          res.headers
            ..contentType = ContentType('application', 'vnd.comicbook+zip')
            ..contentLength = total
            ..set('Content-Disposition', 'attachment; filename="pack.cbz"');
          var sent = 0;
          final started = DateTime.now();
          var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
          _status.add(WifiSendStatus(client: client, total: total));
          await res.addStream(_file.openRead().map((chunk) {
            sent += chunk.length;
            final now = DateTime.now();
            if (now.difference(lastEmit).inMilliseconds > 200) {
              lastEmit = now;
              final secs = now.difference(started).inMilliseconds / 1000;
              _status.add(WifiSendStatus(client: client, sent: sent, total: total, bytesPerSecond: secs > 0 ? sent / secs : 0));
            }
            return chunk;
          }));
          await res.close();
          final secs = DateTime.now().difference(started).inMilliseconds / 1000;
          _status.add(WifiSendStatus(client: client, sent: sent, total: total, done: sent >= total, bytesPerSecond: secs > 0 ? sent / secs : 0));
          return;
        default:
          res.statusCode = HttpStatus.notFound;
          _json(res, {'error': 'not_found'});
      }
    } catch (_) {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  void _json(HttpResponse res, Object body) {
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    unawaited(res.close());
  }

  Future<void> stop() async {
    _beacon?.cancel();
    _udp?.close();
    await _server.close(force: true);
    await _status.close();
  }
}

/// Finds senders: UDP beacons + asking likely hotspot gateways (`x.y.z.1`).
class WifiDiscovery {
  WifiDiscovery({List<String>? extraHosts, this.beaconPort = wifiBeaconPort}) : _extra = extraHosts ?? const [];

  final List<String> _extra;
  final int beaconPort;
  final _found = <String, WifiOffer>{};
  final _changes = StreamController<List<WifiOffer>>.broadcast();
  RawDatagramSocket? _udp;
  Timer? _probe;
  var _closed = false;

  Stream<List<WifiOffer>> get offers => _changes.stream;
  List<WifiOffer> get current => _found.values.toList();

  Future<void> start() async {
    try {
      final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, beaconPort, reuseAddress: true);
      _udp = udp;
      udp.listen((e) {
        if (e != RawSocketEvent.read) return;
        final d = udp.receive();
        if (d == null) return;
        try {
          final j = jsonDecode(utf8.decode(d.data)) as Map<String, dynamic>;
          if (j['mf'] == 1) _add(WifiOffer.fromJson(d.address.address, j));
        } catch (_) {}
      });
    } catch (_) {
      // port busy / no permission: probing still works
    }
    await _probeAll();
    _probe = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(_probeAll()));
  }

  void _add(WifiOffer o) {
    if (_closed) return;
    final had = _found.containsKey(o.address);
    _found[o.address] = o;
    if (!had) _changes.add(current);
  }

  Future<List<String>> _candidates() async {
    final hosts = <String>{..._extra, '192.168.43.1', '192.168.49.1', '192.168.137.1', '172.20.10.1'};
    for (final a in await localAddresses()) {
      final parts = a.split('.');
      if (parts.length == 4) hosts.add('${parts[0]}.${parts[1]}.${parts[2]}.1');
    }
    return hosts.toList();
  }

  Future<void> _probeAll() async {
    if (_closed) return;
    final hosts = await _candidates();
    await Future.wait([for (final h in hosts) _probeOne(h)]);
  }

  Future<void> _probeOne(String hostPort) async {
    final o = await probe(hostPort, timeout: const Duration(milliseconds: 900));
    if (o != null) _add(o);
  }

  /// `host` or `host:port` → the sender's offer, or null.
  static Future<WifiOffer?> probe(String hostPort, {Duration timeout = const Duration(seconds: 3)}) async {
    final (host, port) = parseAddress(hostPort);
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(Uri.http('$host:$port', '/hello')).timeout(timeout);
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      final j = jsonDecode(body) as Map<String, dynamic>;
      return j['mf'] == 1 ? WifiOffer.fromJson(host, j) : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> stop() async {
    _closed = true;
    _probe?.cancel();
    _udp?.close();
    await _changes.close();
  }
}

(String, int) parseAddress(String s) {
  final t = s.trim().replaceFirst(RegExp(r'^https?://'), '').split('/').first;
  final i = t.lastIndexOf(':');
  if (i > 0) return (t.substring(0, i), int.tryParse(t.substring(i + 1)) ?? wifiTransferPort);
  return (t, wifiTransferPort);
}

class WifiPinException implements Exception {
  const WifiPinException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads the pack into [target]. [onProgress] gets (received, total, bytes/s).
Future<File> downloadOffer(
  WifiOffer offer,
  String pin,
  File target, {
  String from = '',
  void Function(int received, int total, double bytesPerSecond)? onProgress,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final req = await client.getUrl(Uri.http(offer.address, '/pack', {'k': pin.trim(), if (from.isNotEmpty) 'from': from}));
    final res = await req.close();
    if (res.statusCode == HttpStatus.forbidden) {
      await res.drain<void>();
      throw const WifiPinException('Неверный код — посмотрите на экран отправителя');
    }
    if (res.statusCode == HttpStatus.tooManyRequests) {
      await res.drain<void>();
      throw const WifiPinException('Слишком много неверных попыток. Начните передачу заново.');
    }
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw WifiPinException('Отправитель ответил ошибкой ${res.statusCode}');
    }
    final total = res.contentLength;
    await target.parent.create(recursive: true);
    final sink = target.openWrite();
    var got = 0;
    final started = DateTime.now();
    var last = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await for (final chunk in res.timeout(const Duration(seconds: 20))) {
        sink.add(chunk);
        got += chunk.length;
        final now = DateTime.now();
        if (now.difference(last).inMilliseconds > 150) {
          last = now;
          final secs = now.difference(started).inMilliseconds / 1000;
          onProgress?.call(got, total, secs > 0 ? got / secs : 0);
        }
      }
    } finally {
      await sink.close();
    }
    if (total > 0 && got != total) {
      throw const WifiPinException('Связь оборвалась — попробуйте ещё раз, телефоны должны быть рядом');
    }
    final secs = DateTime.now().difference(started).inMilliseconds / 1000;
    onProgress?.call(got, total > 0 ? total : got, secs > 0 ? got / secs : 0);
    return target;
  } on TimeoutException {
    throw const WifiPinException('Связь оборвалась — попробуйте ещё раз, телефоны должны быть рядом');
  } on SocketException {
    throw const WifiPinException('Не удаётся связаться с отправителем: проверьте, что телефоны в одной сети');
  } finally {
    client.close(force: true);
  }
}
