import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../ui/widgets.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key, this.next});
  final String? next;

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  bool _signup = true;
  bool _busy = false;
  String? _error;
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();

  bool get _fromInvite => widget.next?.startsWith('/invite/') == true;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final n = ref.read(sessionProvider.notifier);
      if (_signup) {
        await n.signup(_email.text.trim(), _password.text, _name.text.trim());
      } else {
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
                Text(_signup ? 'Create your account' : 'Welcome back', style: T.h1),
                const SizedBox(height: 8),
                Text(
                  _fromInvite
                      ? 'Sign up or log in to accept your league invite.'
                      : _signup
                          ? 'Make calls on NFL and NBA player lines. New accounts start with 1,000 free coins.'
                          : 'Log in to see your picks and coins.',
                  style: T.dim,
                ),
                const SizedBox(height: 22),
                AutofillGroup(
                  child: Column(children: [
                    if (_signup)
                      TextField(
                        controller: _name,
                        decoration: const InputDecoration(labelText: 'Display name'),
                        autofillHints: const [AutofillHints.name],
                        textInputAction: TextInputAction.next,
                      ),
                    TextField(
                      controller: _email,
                      decoration: const InputDecoration(labelText: 'Email'),
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                    ),
                    TextField(
                      controller: _password,
                      decoration: InputDecoration(labelText: _signup ? 'Password (8+ characters)' : 'Password'),
                      obscureText: true,
                      autofillHints: [_signup ? AutofillHints.newPassword : AutofillHints.password],
                      onSubmitted: (_) => _submit(),
                    ),
                  ]),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!, style: const TextStyle(color: C.danger)),
                ],
                const SizedBox(height: 26),
                PrimaryButton(_signup ? 'Create account' : 'Log in', busy: _busy, onPressed: _submit),
                const SizedBox(height: 10),
                Center(
                  child: GhostButton(
                    _signup ? 'I already have an account' : 'Create a new account',
                    color: C.dim,
                    onPressed: () => setState(() {
                      _signup = !_signup;
                      _error = null;
                    }),
                  ),
                ),
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
