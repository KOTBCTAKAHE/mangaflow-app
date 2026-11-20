import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/states.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _login = TextEditingController();
  final _email = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _register = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    for (final c in [_login, _email, _username, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = ref.read(authProvider.notifier);
    try {
      if (_register) {
        await auth.register(email: _email.text, username: _username.text, password: _password.text);
      } else {
        await auth.login(_login.text, _password.text);
      }
      if (mounted) {
        showSnack(context, 'Готово! Библиотека синхронизируется');
        context.pop();
      }
    } on ApiException catch (e) {
      setState(() => _error = e.userMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter), children: [
            Text(_register ? 'Создать аккаунт' : 'Вход', style: context.text.displaySmall),
            const SizedBox(height: MfSpace.sm),
            Text('Синхронизация библиотеки, истории и прогресса между устройствами.', style: context.text.bodySmall),
            const SizedBox(height: MfSpace.xxl),
            if (_register) ...[
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Email'),
                validator: (v) => (v == null || !v.contains('@')) ? 'Введите email' : null,
              ),
              const SizedBox(height: MfSpace.md),
              TextFormField(
                controller: _username,
                autofillHints: const [AutofillHints.newUsername],
                decoration: const InputDecoration(labelText: 'Имя пользователя', helperText: 'Латиница, цифры, . _ -'),
                validator: (v) => (v == null || !RegExp(r'^[A-Za-z0-9_.\-]{3,32}$').hasMatch(v)) ? '3–32 символа: латиница, цифры, . _ -' : null,
              ),
            ] else
              TextFormField(
                controller: _login,
                autofillHints: const [AutofillHints.username, AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Email или имя пользователя'),
                validator: (v) => (v == null || v.trim().length < 3) ? 'Введите логин' : null,
              ),
            const SizedBox(height: MfSpace.md),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              autofillHints: [_register ? AutofillHints.newPassword : AutofillHints.password],
              onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Пароль',
                helperText: _register ? 'Минимум 8 символов, буквы и цифры' : null,
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Показать' : 'Скрыть',
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Введите пароль';
                if (_register && (v.length < 8 || !RegExp(r'\d').hasMatch(v) || !RegExp(r'[^\d]').hasMatch(v))) {
                  return 'Минимум 8 символов, буквы и цифры';
                }
                return null;
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: MfSpace.lg),
              Text(_error!, style: context.text.bodyMedium?.copyWith(color: MfColors.danger)),
            ],
            const SizedBox(height: MfSpace.xxl),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : Text(_register ? 'Зарегистрироваться' : 'Войти'),
            ),
            const SizedBox(height: MfSpace.sm),
            TextButton(
              onPressed: () => setState(() {
                _register = !_register;
                _error = null;
              }),
              child: Text(_register ? 'Уже есть аккаунт? Войти' : 'Нет аккаунта? Регистрация'),
            ),
            const SizedBox(height: MfSpace.xl),
            TextButton.icon(
              onPressed: () => context.push('/settings'),
              icon: const Icon(Icons.vpn_lock_outlined, size: 18),
              label: const Text('Не подключается? Настроить прокси'),
            ),
          ]),
        ),
      ),
    );
  }
}
