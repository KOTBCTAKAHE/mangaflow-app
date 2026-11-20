import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/proxy.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/states.dart';

/// Settings → Подключение → Прокси: reach the MangaFlow server through HTTP or SOCKS5.
class ProxyScreen extends ConsumerStatefulWidget {
  const ProxyScreen({super.key});

  @override
  ConsumerState<ProxyScreen> createState() => _ProxyScreenState();
}

class _ProxyScreenState extends ConsumerState<ProxyScreen> {
  late ProxyType _type;
  late bool _all;
  late final TextEditingController _host, _port, _user, _pass;
  bool _hidePass = true;
  bool _testing = false;
  String? _result;
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    final p = ref.read(settingsProvider).proxy;
    _type = p.type;
    _all = p.allTraffic;
    _host = TextEditingController(text: p.host);
    _port = TextEditingController(text: p.port > 0 ? '${p.port}' : '');
    _user = TextEditingController(text: p.username);
    _pass = TextEditingController(text: p.password);
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  ProxyConfig get _draft => ProxyConfig(
        type: _type,
        host: _host.text.trim(),
        port: int.tryParse(_port.text.trim()) ?? 0,
        username: _user.text.trim(),
        password: _pass.text,
        allTraffic: _all,
      );

  String? _invalid() {
    if (_type == ProxyType.none) return null;
    if (_host.text.trim().isEmpty) return 'Укажите адрес прокси';
    final port = int.tryParse(_port.text.trim()) ?? 0;
    if (port <= 0 || port > 65535) return 'Порт — число от 1 до 65535';
    return null;
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final p = ProxyConfig.parseUrl(text, fallback: _type == ProxyType.http ? ProxyType.http : ProxyType.socks5);
    if (!mounted) return;
    if (p == null) {
      showSnack(context, 'В буфере нет ссылки вида socks5://логин:пароль@адрес:порт');
      return;
    }
    setState(() {
      _type = p.type;
      _host.text = p.host;
      _port.text = '${p.port}';
      _user.text = p.username;
      _pass.text = p.password;
      _result = null;
    });
  }

  Future<void> _test() async {
    final bad = _invalid();
    if (bad != null) {
      setState(() {
        _result = bad;
        _ok = false;
      });
      return;
    }
    setState(() {
      _testing = true;
      _result = null;
    });
    final sw = Stopwatch()..start();
    final err = await AppProxy.test(_draft);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _ok = err == null;
      _result = err ?? 'Сервер MangaFlow отвечает через прокси · ${sw.elapsedMilliseconds} мс';
    });
  }

  Future<void> _save() async {
    final bad = _invalid();
    if (bad != null) {
      showSnack(context, bad);
      return;
    }
    await ref.read(settingsProvider.notifier).updateLocalOnly((s) => s.copyWith(proxy: _draft));
    if (!mounted) return;
    showSnack(context, _type == ProxyType.none ? 'Прокси выключен' : 'Прокси сохранён');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final on = _type != ProxyType.none;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Прокси')),
      body: ListView(padding: const EdgeInsets.all(MfSpace.gutter), children: [
        Text(
          'Приложение будет обращаться к серверу MangaFlow через ваш прокси — например, если сервер недоступен из вашей сети.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: MfSpace.lg),
        SegmentedButton<ProxyType>(
          segments: [for (final t in ProxyType.values) ButtonSegment(value: t, label: Text(t.label))],
          selected: {_type},
          onSelectionChanged: (v) => setState(() {
            _type = v.first;
            _result = null;
          }),
        ),
        if (on) ...[
          const SizedBox(height: MfSpace.lg),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _host,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Адрес', hintText: '203.0.113.5 или proxy.example.com'),
              ),
            ),
            const SizedBox(width: MfSpace.sm),
            Expanded(
              child: TextField(
                controller: _port,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: 'Порт', hintText: _type == ProxyType.http ? '8080' : '1080'),
              ),
            ),
          ]),
          const SizedBox(height: MfSpace.sm),
          TextField(
            controller: _user,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Логин (если нужен)'),
          ),
          const SizedBox(height: MfSpace.sm),
          TextField(
            controller: _pass,
            obscureText: _hidePass,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Пароль (если нужен)',
              suffixIcon: IconButton(
                icon: Icon(_hidePass ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _hidePass = !_hidePass),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _paste,
              icon: const Icon(Icons.content_paste, size: 18),
              label: const Text('Вставить ссылку из буфера'),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Весь трафик приложения'),
            subtitle: const Text('Не только сервер MangaFlow, но и картинки с сайтов-источников и загрузка обновлений'),
            value: _all,
            onChanged: (v) => setState(() => _all = v),
          ),
          const SizedBox(height: MfSpace.sm),
          OutlinedButton.icon(
            onPressed: _testing ? null : _test,
            icon: _testing
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.network_check),
            label: Text(_testing ? 'Проверяю…' : 'Проверить подключение'),
          ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: MfSpace.sm),
              child: Row(children: [
                Icon(_ok ? Icons.check_circle_outline : Icons.error_outline, size: 18, color: _ok ? Colors.green : scheme.error),
                const SizedBox(width: MfSpace.sm),
                Expanded(child: Text(_result!, style: Theme.of(context).textTheme.bodySmall)),
              ]),
            ),
        ],
        const SizedBox(height: MfSpace.xl),
        FilledButton(onPressed: _save, child: const Text('Сохранить')),
        const SizedBox(height: MfSpace.md),
        Text(
          'Прокси хранится только на этом устройстве и не синхронизируется с аккаунтом. Устройства в локальной сети (передача по Wi‑Fi) всегда подключаются напрямую.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ]),
    );
  }
}
