import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../ui/widgets.dart';

/// Opening an invite link only previews it. Joining is an explicit action by
/// a signed-in user; signed-out users go through signup and come back here.
class InviteScreen extends ConsumerStatefulWidget {
  const InviteScreen({super.key, required this.token});
  final String token;

  @override
  ConsumerState<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends ConsumerState<InviteScreen> {
  late final Future<Map<String, dynamic>> _preview = api.get('/invites/${widget.token}');
  bool _busy = false;
  String? _error;

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await api.post('/invites/${widget.token}/accept');
      if (mounted) context.go('/social/league/${r['leagueId']}');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionProvider).value;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: FutureBuilder(
              future: _preview,
              builder: (context, snap) {
                if (snap.hasError) {
                  return ErrorText('This invite link is not valid.', onRetry: () => context.go('/play'));
                }
                if (!snap.hasData) return const Loading();
                final p = snap.data!;
                final valid = p['valid'] == true;
                return ListView(shrinkWrap: true, padding: const EdgeInsets.all(24), children: [
                  const Text('LEAGUE INVITE', style: T.label),
                  const SizedBox(height: 10),
                  Text(p['leagueName'] as String, style: T.h1),
                  const SizedBox(height: 8),
                  Text('${p['inviter']} invited you · ${p['memberCount']} ${p['memberCount'] == 1 ? 'member' : 'members'}', style: T.dim),
                  const SizedBox(height: 28),
                  if (!valid)
                    const Text('This invite has expired. Ask for a new link.', style: TextStyle(color: C.danger))
                  else if (me == null) ...[
                    PrimaryButton('Sign up to join',
                        onPressed: () => context.go('/login?next=${Uri.encodeComponent('/invite/${widget.token}')}')),
                    const SizedBox(height: 8),
                    const Text('You will come back here after signing up.', style: T.small, textAlign: TextAlign.center),
                  ] else ...[
                    PrimaryButton('Join ${p['leagueName']}', busy: _busy, onPressed: _accept),
                    const SizedBox(height: 8),
                    Text('Joining as ${me.displayName} (${me.handleTag})', style: T.small, textAlign: TextAlign.center),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: const TextStyle(color: C.danger)),
                  ],
                  const SizedBox(height: 12),
                  Center(child: GhostButton('Not now', color: C.dim, onPressed: () => context.go('/play'))),
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }
}
