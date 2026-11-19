import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../../app/router.dart' show rootNavigatorKey;
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';

/// PIN kept as salted SHA-256 in the keystore-backed secure storage.
class PinStore {
  PinStore([FlutterSecureStorage? s])
      : _s = s ?? const FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  final FlutterSecureStorage _s;
  static const _kHash = 'app_lock_pin_hash';
  static const _kSalt = 'app_lock_pin_salt';
  static const _kLen = 'app_lock_pin_len';

  static String _hash(String salt, String pin) => sha256.convert(utf8.encode('$salt:$pin')).toString();

  Future<bool> hasPin() async {
    try {
      return (await _s.read(key: _kHash)) != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> setPin(String pin) async {
    final r = Random.secure();
    final salt = base64Url.encode(List<int>.generate(16, (_) => r.nextInt(256)));
    await _s.write(key: _kSalt, value: salt);
    await _s.write(key: _kHash, value: _hash(salt, pin));
    await _s.write(key: _kLen, value: '${pin.length}');
  }

  /// How many digits to wait for on the lock screen.
  Future<int> length() async {
    try {
      return int.tryParse(await _s.read(key: _kLen) ?? '')?.clamp(4, 6) ?? 4;
    } catch (_) {
      return 4;
    }
  }

  Future<bool> check(String pin) async {
    try {
      final salt = await _s.read(key: _kSalt);
      final hash = await _s.read(key: _kHash);
      return salt != null && hash != null && _hash(salt, pin) == hash;
    } catch (_) {
      return false;
    }
  }

  Future<void> clear() async {
    await _s.delete(key: _kHash);
    await _s.delete(key: _kSalt);
    await _s.delete(key: _kLen);
  }
}

/// Privacy flags on the Android window (recents preview).
abstract final class PrivacyWindow {
  static const _ch = MethodChannel('mangaflow/privacy');

  static Future<void> hideInRecents(bool hide) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('hideInRecents', hide);
    } catch (_) {}
  }
}

class AppLockState {
  const AppLockState({this.locked = false, this.failures = 0, this.coolDownUntil});
  final bool locked;
  final int failures;
  final DateTime? coolDownUntil;

  Duration get coolDown {
    final u = coolDownUntil;
    if (u == null) return Duration.zero;
    final d = u.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }
}

class AppLockController extends StateNotifier<AppLockState> with WidgetsBindingObserver {
  AppLockController(this.ref) : super(const AppLockState()) {
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initial());
  }

  final Ref ref;
  final pins = PinStore();
  final auth = LocalAuthentication();
  DateTime? _backgroundAt;
  bool _authInProgress = false;

  Future<void> _initial() async {
    final s = ref.read(settingsProvider);
    unawaited(PrivacyWindow.hideInRecents(s.hideInRecents));
    if (!s.appLock) return;
    if (await pins.hasPin()) {
      state = const AppLockState(locked: true);
    } else {
      // PIN vanished (restored backup on a new phone, keystore reset): don't lock the user out
      await ref.read(settingsProvider.notifier).updateLocalOnly((s) => s.copyWith(appLock: false));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final settings = ref.read(settingsProvider);
    if (!settings.appLock) return;
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      // the system biometric sheet also pauses the app — that is not "leaving"
      if (!_authInProgress) _backgroundAt ??= DateTime.now();
      if (settings.lockTimeoutSec == 0 && !_authInProgress) state = AppLockState(locked: true, failures: state.failures);
    } else if (s == AppLifecycleState.resumed) {
      final at = _backgroundAt;
      _backgroundAt = null;
      if (at != null && DateTime.now().difference(at).inSeconds >= settings.lockTimeoutSec) {
        state = AppLockState(locked: true, failures: state.failures, coolDownUntil: state.coolDownUntil);
      }
    }
  }

  Future<bool> unlockWithPin(String pin) async {
    if (state.coolDown > Duration.zero) return false;
    if (await pins.check(pin)) {
      state = const AppLockState();
      return true;
    }
    final f = state.failures + 1;
    // 5 wrong in a row → wait 30 s, then +30 s for every further miss
    state = AppLockState(
      locked: true,
      failures: f,
      coolDownUntil: f >= 5 ? DateTime.now().add(Duration(seconds: 30 * (f - 4))) : null,
    );
    return false;
  }

  Future<bool> canUseBiometrics() async {
    try {
      return await auth.canCheckBiometrics && await auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  /// Fingerprint / face. [deviceCredential]: also accept the phone's own PIN (for «Забыли PIN?»).
  Future<bool> unlockWithBiometrics({bool deviceCredential = false}) async {
    if (_authInProgress) return false;
    _authInProgress = true;
    try {
      final ok = await auth.authenticate(
        localizedReason: deviceCredential ? 'Подтвердите, что это вы, чтобы сбросить PIN MangaFlow' : 'Разблокировать MangaFlow',
        biometricOnly: !deviceCredential,
        persistAcrossBackgrounding: true,
      );
      if (ok) state = const AppLockState();
      return ok;
    } catch (_) {
      return false;
    } finally {
      _authInProgress = false;
    }
  }

  /// Turn the lock on with a new PIN.
  Future<void> enable(String pin) async {
    await pins.setPin(pin);
    await ref.read(settingsProvider.notifier).updateLocalOnly((s) => s.copyWith(appLock: true));
  }

  Future<void> disable() async {
    await pins.clear();
    await ref.read(settingsProvider.notifier).updateLocalOnly((s) => s.copyWith(appLock: false));
    state = const AppLockState();
  }

  /// Lock right now (button in settings / when the user wants).
  void lockNow() {
    if (ref.read(settingsProvider).appLock) state = AppLockState(locked: true, failures: state.failures);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final appLockProvider = StateNotifierProvider<AppLockController, AppLockState>((ref) => AppLockController(ref));

/// Wraps the whole app (MaterialApp.builder): the lock screen sits above every route.
class AppLockGate extends ConsumerWidget {
  const AppLockGate({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locked = ref.watch(appLockProvider.select((s) => s.locked));
    final incognito = ref.watch(settingsProvider.select((s) => s.incognito));
    return Stack(children: [
      // keep the app alive underneath, but hide it from accessibility and touches
      ExcludeSemantics(excluding: locked, child: AbsorbPointer(absorbing: locked, child: child)),
      if (incognito && !locked)
        Positioned(
          top: MediaQuery.paddingOf(context).top + 2,
          left: 0,
          right: 0,
          child: const Center(child: _IncognitoPill()),
        ),
      if (locked) const Positioned.fill(child: LockScreen()),
    ]);
  }
}

/// Reminder that nothing is being recorded; tap to turn it off.
class _IncognitoPill extends ConsumerWidget {
  const _IncognitoPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: Colors.black.withValues(alpha: 0.72),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () async {
          // this sits above the Navigator (MaterialApp.builder): show the dialog on the root one
          final nav = rootNavigatorKey.currentContext;
          if (nav == null) return;
          final off = await showDialog<bool>(
            context: nav,
            builder: (context) => AlertDialog(
              title: const Text('Инкогнито включено'),
              content: const Text('История, прогресс глав и поисковые запросы сейчас не сохраняются. Выключить?'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Оставить')),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Выключить')),
              ],
            ),
          );
          if (off == true) {
            await ref.read(settingsProvider.notifier).updateLocalOnly((s) => s.copyWith(incognito: false));
          }
        },
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.visibility_off_rounded, size: 13, color: Colors.white),
            SizedBox(width: 5),
            Text('Инкогнито', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  String _pin = '';
  int _len = 4;
  bool _error = false;
  bool _bio = false;
  bool _checking = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ctrl = ref.read(appLockProvider.notifier);
      final len = await ctrl.pins.length();
      if (mounted) setState(() => _len = len);
      final can = ref.read(settingsProvider).lockBiometrics && await ctrl.canUseBiometrics();
      if (!mounted) return;
      setState(() => _bio = can);
      if (can) unawaited(ctrl.unlockWithBiometrics());
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(appLockProvider).coolDown > Duration.zero) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _digit(String d) async {
    if (_checking || ref.read(appLockProvider).coolDown > Duration.zero || _pin.length >= _len) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += d;
      _error = false;
    });
    if (_pin.length < _len) return;
    _checking = true;
    final ok = await ref.read(appLockProvider.notifier).unlockWithPin(_pin);
    _checking = false;
    if (!ok && mounted) {
      HapticFeedback.heavyImpact();
      setState(() {
        _pin = '';
        _error = true;
      });
    }
  }

  Future<void> _forgot() async {
    final ok = await ref.read(appLockProvider.notifier).unlockWithBiometrics(deviceCredential: true);
    if (!ok || !mounted) return;
    await ref.read(appLockProvider.notifier).disable();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Блокировка выключена. Задайте новый PIN в настройках')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(appLockProvider);
    final wait = st.coolDown;
    return Material(
      color: context.colors.surface,
      child: SafeArea(
        child: Column(children: [
          const Spacer(),
          Icon(Icons.lock_rounded, size: 40, color: MfColors.accent),
          const SizedBox(height: MfSpace.md),
          Text('MangaFlow', style: MfType.title.copyWith(color: context.colors.onSurface)),
          const SizedBox(height: MfSpace.xs),
          Text(
            wait > Duration.zero
                ? 'Слишком много попыток. Подождите ${wait.inSeconds + 1} с'
                : _error
                    ? 'Неверный PIN'
                    : 'Введите PIN',
            style: context.text.bodyMedium?.copyWith(color: _error || wait > Duration.zero ? context.colors.error : null),
          ),
          const SizedBox(height: MfSpace.lg),
          _Dots(count: _pin.length, total: _len, error: _error),
          const Spacer(),
          _Keypad(
            onDigit: _digit,
            onBackspace: () => setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1)),
            extra: _bio
                ? IconButton(
                    iconSize: 30,
                    tooltip: 'Отпечаток или лицо',
                    onPressed: () => ref.read(appLockProvider.notifier).unlockWithBiometrics(),
                    icon: const Icon(Icons.fingerprint_rounded),
                  )
                : null,
          ),
          TextButton(onPressed: _forgot, child: const Text('Забыли PIN?')),
          const SizedBox(height: MfSpace.md),
        ]),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.error, this.total = 6});
  final int count, total;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < total; i++)
        AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 7),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: error
                ? context.colors.error
                : i < count
                    ? MfColors.accent
                    : Colors.transparent,
            border: Border.all(color: context.colors.outline, width: 1.5),
          ),
        ),
    ]);
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.onDigit, required this.onBackspace, this.extra});
  final void Function(String) onDigit;
  final VoidCallback onBackspace;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    Widget key(String d) => SizedBox(
          width: 84,
          height: 72,
          child: TextButton(
            style: TextButton.styleFrom(shape: const CircleBorder()),
            onPressed: () => onDigit(d),
            child: Text(d, style: context.text.headlineSmall),
          ),
        );
    return Column(children: [
      for (final row in const [
        ['1', '2', '3'],
        ['4', '5', '6'],
        ['7', '8', '9'],
      ])
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (final d in row) key(d)]),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        SizedBox(width: 84, height: 72, child: Center(child: extra)),
        key('0'),
        SizedBox(
          width: 84,
          height: 72,
          child: IconButton(tooltip: 'Стереть', onPressed: onBackspace, icon: const Icon(Icons.backspace_outlined)),
        ),
      ]),
    ]);
  }
}

/// New PIN, twice. Returns the PIN or null if cancelled.
Future<String?> askNewPin(BuildContext context) => Navigator.of(context).push<String>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _PinSetupScreen()),
    );

class _PinSetupScreen extends StatefulWidget {
  const _PinSetupScreen();

  @override
  State<_PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<_PinSetupScreen> {
  String? _first;
  String _pin = '';
  bool _mismatch = false;

  void _digit(String d) {
    if (_pin.length >= 6) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += d;
      _mismatch = false;
    });
    if (_first != null && _pin.length == _first!.length) {
      if (_pin == _first) {
        Navigator.pop(context, _pin);
      } else {
        HapticFeedback.heavyImpact();
        setState(() {
          _first = null;
          _pin = '';
          _mismatch = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final confirming = _first != null;
    return Scaffold(
      appBar: AppBar(title: const Text('PIN для входа')),
      body: SafeArea(
        child: Column(children: [
          const Spacer(),
          Text(
            _mismatch
                ? 'PIN не совпал — введите заново'
                : confirming
                    ? 'Повторите PIN'
                    : 'Придумайте PIN из 4–6 цифр',
            style: context.text.titleMedium?.copyWith(color: _mismatch ? context.colors.error : null),
          ),
          const SizedBox(height: MfSpace.lg),
          _Dots(count: _pin.length, total: confirming ? _first!.length : 6, error: false),
          const SizedBox(height: MfSpace.md),
          if (!confirming)
            AnimatedOpacity(
              opacity: _pin.length >= 4 ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: FilledButton(
                onPressed: _pin.length >= 4 ? () => setState(() {
                      _first = _pin;
                      _pin = '';
                    }) : null,
                child: const Text('Дальше'),
              ),
            ),
          const Spacer(),
          _Keypad(
            onDigit: _digit,
            onBackspace: () => setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1)),
          ),
          const SizedBox(height: MfSpace.xl),
        ]),
      ),
    );
  }
}
