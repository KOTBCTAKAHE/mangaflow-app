import 'dart:async';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/format.dart';
import '../../data/services/transfer/wifi_transfer.dart';
import '../../widgets/states.dart';
import '../library/library_actions.dart';
import 'transfer_ui.dart';

Future<String> _deviceName() async {
  try {
    if (Platform.isAndroid) {
      final i = await DeviceInfoPlugin().androidInfo;
      final brand = i.brand.isEmpty ? '' : '${i.brand[0].toUpperCase()}${i.brand.substring(1)} ';
      return '$brand${i.model}'.trim();
    }
  } catch (_) {}
  return 'Телефон';
}

String _speed(double bps) => bps <= 0 ? '' : '${formatBytes(bps.round())}/с';

Future<void> openHotspotSettings() async {
  if (!Platform.isAndroid) return;
  for (final action in ['android.settings.TETHER_SETTINGS', 'android.settings.WIRELESS_SETTINGS', 'android.settings.WIFI_SETTINGS']) {
    try {
      await AndroidIntent(action: action, flags: const [Flag.FLAG_ACTIVITY_NEW_TASK]).launch();
      return;
    } catch (_) {}
  }
}

Future<void> openWifiSettings() async {
  if (!Platform.isAndroid) return;
  try {
    await const AndroidIntent(action: 'android.settings.WIFI_SETTINGS', flags: [Flag.FLAG_ACTIVITY_NEW_TASK]).launch();
  } catch (_) {}
}

Widget _step(BuildContext context, int n, String text, {Widget? action}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: MfSpace.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CircleAvatar(radius: 12, child: Text('$n', style: const TextStyle(fontSize: 12))),
        const SizedBox(width: MfSpace.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: Text(text)),
            if (action != null) action,
          ]),
        ),
      ]),
    );

// =================================================================== sender

class WifiSendScreen extends StatefulWidget {
  const WifiSendScreen({super.key, required this.pack, required this.title, required this.chapters});
  final File pack;
  final String title;
  final int chapters;

  @override
  State<WifiSendScreen> createState() => _WifiSendScreenState();
}

class _WifiSendScreenState extends State<WifiSendScreen> with WidgetsBindingObserver {
  WifiSendSession? _session;
  StreamSubscription<WifiSendStatus>? _sub;
  WifiSendStatus? _status;
  List<String> _addresses = const [];
  String? _error;
  Timer? _addrTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(WakelockPlus.enable().catchError((Object _) {}));
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final s = await WifiSendSession.start(
        pack: widget.pack,
        title: widget.title,
        chapters: widget.chapters,
        device: await _deviceName(),
      );
      if (!mounted) {
        await s.stop();
        return;
      }
      _session = s;
      _sub = s.status.listen((st) {
        if (mounted) setState(() => _status = st);
        if (st.done) HapticFeedback.mediumImpact();
      });
      await _refreshAddresses();
      // the hotspot may be switched on after this screen opened
      _addrTimer = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(_refreshAddresses()));
      setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось открыть передачу: ${errorText(e)}');
    }
  }

  Future<void> _refreshAddresses() async {
    final a = await localAddresses();
    if (mounted && a.join() != _addresses.join()) setState(() => _addresses = a);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshAddresses());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _addrTimer?.cancel();
    unawaited(_sub?.cancel());
    unawaited(_session?.stop());
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    final st = _status;
    final port = s?.port ?? wifiTransferPort;
    return Scaffold(
      appBar: AppBar(title: const Text('Передача по точке доступа')),
      body: _error != null
          ? EmptyState(icon: Icons.wifi_off_rounded, title: 'Передача не запустилась', message: _error)
          : s == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(padding: const EdgeInsets.all(MfSpace.gutter), children: [
                  Text('«${widget.title}»', style: context.text.titleMedium),
                  Text('${widget.chapters} гл. · ${formatBytes(s.offer.bytes)}', style: context.text.bodySmall),
                  const SizedBox(height: MfSpace.xl),
                  Center(child: Text('Код', style: context.text.labelLarge)),
                  Center(
                    child: Text(s.pin,
                        style: context.text.displayMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 10)),
                  ),
                  const SizedBox(height: MfSpace.xl),
                  if (st == null) ...[
                    _step(context, 1, 'Включите точку доступа на этом телефоне (мобильный интернет не нужен). '
                        'Или подключите оба телефона к одной Wi-Fi.',
                        action: TextButton.icon(
                          onPressed: openHotspotSettings,
                          icon: const Icon(Icons.wifi_tethering_rounded),
                          label: const Text('Открыть настройки точки доступа'),
                        )),
                    _step(context, 2, 'Второй телефон подключите к этой точке доступа.'),
                    _step(context, 3, 'На нём: MangaFlow → Загрузки → ⋮ → «Принять по Wi-Fi» и введите код ${s.pin}.'),
                    const SizedBox(height: MfSpace.lg),
                    Row(children: [
                      const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: MfSpace.md),
                      Expanded(child: Text('Жду второй телефон… Не закрывайте этот экран.', style: context.text.bodyMedium)),
                    ]),
                  ] else if (!st.done) ...[
                    Text('${st.client} получает главы', style: context.text.titleSmall),
                    const SizedBox(height: MfSpace.sm),
                    LinearProgressIndicator(value: st.progress),
                    const SizedBox(height: MfSpace.xs),
                    Text('${(st.progress * 100).round()}% · ${formatBytes(st.sent)} из ${formatBytes(st.total)} · ${_speed(st.bytesPerSecond)}',
                        style: context.text.bodySmall),
                  ] else ...[
                    const Icon(Icons.check_circle_rounded, color: MfColors.success, size: 56),
                    const SizedBox(height: MfSpace.sm),
                    Center(child: Text('Передано!', style: context.text.titleLarge)),
                    Center(
                      child: Text('${formatBytes(st.total)} · ${_speed(st.bytesPerSecond)}', style: context.text.bodySmall),
                    ),
                    const SizedBox(height: MfSpace.lg),
                    FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Готово')),
                    TextButton(onPressed: () => setState(() => _status = null), child: const Text('Отправить ещё одному телефону')),
                  ],
                  const SizedBox(height: MfSpace.xxl),
                  Text(
                    _addresses.isEmpty
                        ? 'Сеть пока не найдена — включите точку доступа или Wi-Fi.'
                        : 'Адрес для ручного ввода: ${_addresses.map((a) => '$a:$port').join(', ')}',
                    style: context.text.bodySmall,
                  ),
                ]),
    );
  }
}

// ================================================================= receiver

class WifiReceiveScreen extends ConsumerStatefulWidget {
  const WifiReceiveScreen({super.key});

  @override
  ConsumerState<WifiReceiveScreen> createState() => _WifiReceiveScreenState();
}

class _WifiReceiveScreenState extends ConsumerState<WifiReceiveScreen> {
  final _discovery = WifiDiscovery();
  StreamSubscription<List<WifiOffer>>? _sub;
  List<WifiOffer> _offers = const [];
  WifiOffer? _active;
  int _got = 0, _total = 0;
  double _bps = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sub = _discovery.offers.listen((o) {
      if (mounted) setState(() => _offers = o);
    });
    unawaited(_discovery.start());
    unawaited(WakelockPlus.enable().catchError((Object _) {}));
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_discovery.stop());
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
    super.dispose();
  }

  Future<void> _manual() async {
    final v = await promptText(context, title: 'Адрес отправителя', hint: '192.168.43.1:$wifiTransferPort');
    if (v == null || v.trim().isEmpty || !mounted) return;
    final o = await WifiDiscovery.probe(v);
    if (!mounted) return;
    if (o == null) {
      showSnack(context, 'По адресу ${v.trim()} никто не отвечает');
      return;
    }
    await _receive(o);
  }

  Future<void> _receive(WifiOffer o) async {
    final pin = await promptText(context, title: 'Код с экрана отправителя', hint: '4 цифры', keyboard: TextInputType.number);
    if (pin == null || pin.trim().isEmpty || !mounted) return;
    setState(() {
      _active = o;
      _got = 0;
      _total = o.bytes;
      _bps = 0;
      _error = null;
    });
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/wifi-in');
      final target = File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}.cbz');
      await downloadOffer(o, pin, target, from: await _deviceName(), onProgress: (got, total, bps) {
        if (mounted) {
          setState(() {
            _got = got;
            _total = total;
            _bps = bps;
          });
        }
      });
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => ImportChaptersScreen(path: target.path, autoImport: true),
      ));
    } catch (e) {
      if (mounted) {
        setState(() {
          _active = null;
          _error = e is WifiPinException ? e.message : 'Не получилось: ${errorText(e)}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _active;
    return Scaffold(
      appBar: AppBar(title: const Text('Принять по Wi-Fi')),
      body: ListView(padding: const EdgeInsets.all(MfSpace.gutter), children: [
        if (a != null) ...[
          Text('Получаю «${a.title}» от ${a.device}', style: context.text.titleMedium),
          const SizedBox(height: MfSpace.md),
          LinearProgressIndicator(value: _total > 0 ? _got / _total : null),
          const SizedBox(height: MfSpace.xs),
          Text(
            '${_total > 0 ? '${(_got * 100 / _total).round()}% · ' : ''}${formatBytes(_got)}'
            '${_total > 0 ? ' из ${formatBytes(_total)}' : ''} · ${_speed(_bps)}'
            '${_bps > 0 && _total > _got ? ' · осталось ~${((_total - _got) / _bps).ceil()} с' : ''}',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: MfSpace.md),
          Text('Держите телефоны рядом и не закрывайте экран.', style: context.text.bodySmall),
        ] else ...[
          _step(context, 1, 'Подключитесь к точке доступа телефона, который отправляет главы (или к общей Wi-Fi).',
              action: TextButton.icon(
                onPressed: openWifiSettings,
                icon: const Icon(Icons.wifi_rounded),
                label: const Text('Открыть настройки Wi-Fi'),
              )),
          _step(context, 2, 'На том телефоне: Загрузки → тайтл → «Передать главы» → «По точке доступа».'),
          _step(context, 3, 'Выберите его ниже и введите код с его экрана.'),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: MfSpace.md),
              child: Text(_error!, style: const TextStyle(color: MfColors.danger)),
            ),
          const SizedBox(height: MfSpace.lg),
          Row(children: [
            Text('Рядом', style: context.text.titleSmall),
            const SizedBox(width: MfSpace.sm),
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: MfSpace.sm),
          if (_offers.isEmpty)
            Text('Ищу отправителя…', style: context.text.bodySmall)
          else
            for (final o in _offers)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.phone_android_rounded),
                  title: Text(o.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${o.device} · ${o.chapters} гл. · ${formatBytes(o.bytes)}'),
                  trailing: const Icon(Icons.download_rounded),
                  onTap: () => _receive(o),
                ),
              ),
          const SizedBox(height: MfSpace.lg),
          TextButton.icon(onPressed: _manual, icon: const Icon(Icons.edit_rounded), label: const Text('Ввести адрес вручную')),
        ],
      ]),
    );
  }
}
