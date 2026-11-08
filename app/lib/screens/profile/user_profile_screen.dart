import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../../ui/shell.dart';
import '../../ui/widgets.dart';
import 'profile_screen.dart';

class UserProfileScreen extends StatefulWidget {
  const UserProfileScreen({super.key, required this.userId});
  final String userId;

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  late final Future<Map<String, dynamic>> _data = api.get('/profiles/${widget.userId}');

  Future<void> _block(String name) async {
    final ok = await showSheet<bool>(context, (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Block $name?', style: T.h1),
          const SizedBox(height: 8),
          const Text('You will stop seeing each other in search, messages and requests. Your friendship is removed.', style: T.dim),
          const SizedBox(height: 20),
          PrimaryButton('Block', onPressed: () => Navigator.pop(ctx, true)),
          Center(child: GhostButton('Cancel', color: C.dim, onPressed: () => Navigator.pop(ctx, false))),
        ]));
    if (ok != true) return;
    await api.post('/blocks', {'userId': widget.userId});
    if (mounted) {
      toast(context, '$name is blocked.');
      context.go('/social');
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _data,
      builder: (context, snap) {
        if (snap.hasError) return TabPage(back: 'Back', children: [ErrorText(snap.error!)]);
        if (!snap.hasData) return const Loading();
        final p = snap.data!;
        final stats = (p['stats'] as Map?)?.cast<String, dynamic>();
        return TabPage(back: 'Back', children: [
          const SizedBox(height: 18),
          Row(children: [
            InitialsBadge(initialsOf(p['displayName'] as String), color: C.green, size: 22),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p['displayName'] as String, style: T.h1),
                Text('${p['handleTag']}${p['favoriteTeam'] != null ? ' · ${p['favoriteTeam']}' : ''}', style: T.small),
              ]),
            ),
          ]),
          if ((p['bio'] as String).isNotEmpty) Padding(padding: const EdgeInsets.only(top: 14), child: Text(p['bio'] as String, style: T.body)),
          const SizedBox(height: 22),
          if (stats != null) StatsBlock(stats) else const Text('This profile is private.', style: T.dim),
          if (p['isMe'] != true) ...[
            const Hr(),
            GhostButton('Block', color: C.danger, onPressed: () => _block(p['displayName'] as String)),
          ],
        ]);
      },
    );
  }
}
