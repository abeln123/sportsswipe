import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../ui/widgets.dart';

enum _Mode { quick, signup, login }

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key, this.next});
  final String? next;

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  _Mode _mode = _Mode.quick;
  bool _busy = false;
  String? _error;
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();

  bool get _fromInvite => widget.next?.startsWith('/invite/') == true;

  void _switch(_Mode m) => setState(() {
        _mode = m;
        _error = null;
      });

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final n = ref.read(sessionProvider.notifier);
      switch (_mode) {
        case _Mode.quick:
          await n.quick(_name.text.trim(), _email.text.trim());
        case _Mode.signup:
          await n.signup(_email.text.trim(), _password.text, _name.text.trim());
        case _Mode.login:
          await n.login(_email.text.trim(), _password.text);
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (title, intro, action) = switch (_mode) {
      _Mode.quick => (
          'Try Sports Swipe',
          'Swipe Over or Under on real NFL and NBA player lines. You start with 1,000 free coins.',
          'Start swiping',
        ),
      _Mode.signup => (
          'Create your account',
          'Make calls on NFL and NBA player lines. New accounts start with 1,000 free coins.',
          'Create account',
        ),
      _Mode.login => ('Welcome back', 'Log in to see your picks and coins.', 'Log in'),
    };
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Row(children: [
                  Transform(transform: Matrix4.skewX(-0.3), child: Container(width: 14, height: 24, color: C.green)),
                  const SizedBox(width: 12),
                  const Text('Sports Swipe', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                ]),
                const SizedBox(height: 28),
                Text(title, style: T.h1),
                const SizedBox(height: 8),
                Text(_fromInvite ? 'Sign up or log in to accept your league invite.' : intro, style: T.dim),
                const SizedBox(height: 22),
                AutofillGroup(
                  child: Column(children: [
                    if (_mode != _Mode.login)
                      TextField(
                        controller: _name,
                        decoration: InputDecoration(labelText: _mode == _Mode.quick ? 'Your name' : 'Display name'),
                        autofillHints: const [AutofillHints.name],
                        textCapitalization: TextCapitalization.words,
                        textInputAction: _mode == _Mode.quick ? TextInputAction.go : TextInputAction.next,
                        onSubmitted: _mode == _Mode.quick ? (_) => _submit() : null,
                      ),
                    TextField(
                      controller: _email,
                      decoration: InputDecoration(labelText: _mode == _Mode.quick ? 'Email (optional)' : 'Email'),
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: _mode == _Mode.quick ? TextInputAction.go : TextInputAction.next,
                      onSubmitted: _mode == _Mode.quick ? (_) => _submit() : null,
                    ),
                    if (_mode != _Mode.quick)
                      TextField(
                        controller: _password,
                        decoration: InputDecoration(labelText: _mode == _Mode.signup ? 'Password (8+ characters)' : 'Password'),
                        obscureText: true,
                        autofillHints: [_mode == _Mode.signup ? AutofillHints.newPassword : AutofillHints.password],
                        onSubmitted: (_) => _submit(),
                      ),
                  ]),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!, style: const TextStyle(color: C.danger)),
                ],
                const SizedBox(height: 26),
                PrimaryButton(action, busy: _busy, onPressed: _submit),
                const SizedBox(height: 10),
                Wrap(alignment: WrapAlignment.center, spacing: 4, children: [
                  if (_mode != _Mode.quick) GhostButton('Quick start', color: C.dim, onPressed: () => _switch(_Mode.quick)),
                  if (_mode != _Mode.signup) GhostButton('Sign up with a password', color: C.dim, onPressed: () => _switch(_Mode.signup)),
                  if (_mode != _Mode.login) GhostButton('Log in', color: C.dim, onPressed: () => _switch(_Mode.login)),
                ]),
                const SizedBox(height: 18),
                const Text(
                  'Coins are free and have no cash value. Results come from real NFL and NBA box scores.',
                  style: T.small,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
