import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../../ui/shell.dart';
import '../../ui/widgets.dart';

/// The user chooses the destination in the native share sheet.
Future<void> textInvite(BuildContext context, [String? leagueId]) async {
  try {
    final inv = await api.post('/invites', {'leagueId': ?leagueId});
    if (!context.mounted) return;
    final body = inv['smsBody'] as String;
    final box = context.findRenderObject() as RenderBox?;
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          text: body,
          subject: 'Join me on Sports Swipe',
          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
      if (result.status != ShareResultStatus.unavailable) return;
    } catch (_) {}
    if (!context.mounted) return;
    await showSheet<void>(
      context,
      (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Invite a friend', style: T.h2),
          const SizedBox(height: 16),
          SelectableText(body),
          const SizedBox(height: 16),
          PrimaryButton(
            'Copy invitation',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: body));
              if (ctx.mounted) {
                Navigator.pop(ctx);
                toast(context, 'Invitation copied.');
              }
            },
          ),
        ],
      ),
    );
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message, ok: false);
  }
}

class LeagueScreen extends StatefulWidget {
  const LeagueScreen({super.key, required this.leagueId});
  final String leagueId;

  @override
  State<LeagueScreen> createState() => _LeagueScreenState();
}

class _LeagueScreenState extends State<LeagueScreen> {
  late Future<Map<String, dynamic>> _data = api.get('/leagues/${widget.leagueId}');
  bool _inviting = false;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _data,
      builder: (context, snap) {
        if (snap.hasError) {
          return TabPage(
            back: 'Leagues',
            children: [
              ErrorText(
                snap.error!,
                onRetry: () => setState(() {
                  _data = api.get('/leagues/${widget.leagueId}');
                }),
              ),
            ],
          );
        }
        if (!snap.hasData) return const Loading();
        final l = snap.data!;
        final members = (l['members'] as List).cast<Map<String, dynamic>>();
        return TabPage(
          back: 'Leagues',
          onRefresh: () async {
            setState(() {
              _data = api.get('/leagues/${widget.leagueId}');
            });
            await _data;
          },
          children: [
            PageTitle(l['name'] as String, '${members.length} of ${l['capacity']} members · weekly contest points'),
            PrimaryButton(
              'Invite friends',
              busy: _inviting,
              onPressed: () async {
                setState(() => _inviting = true);
                try {
                  await textInvite(context, widget.leagueId);
                } finally {
                  if (mounted) setState(() => _inviting = false);
                }
              },
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Join code ', style: T.dim),
                SelectableText(l['joinCode'] as String, style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2)),
                IconButton(
                  tooltip: 'Copy code',
                  icon: const Icon(Icons.copy, size: 16, color: C.dim),
                  onPressed: () async {
                    try {
                      await Clipboard.setData(ClipboardData(text: l['joinCode'] as String));
                      if (context.mounted) toast(context, 'Code copied.');
                    } catch (_) {
                      if (context.mounted) toast(context, 'Copy blocked by the browser. Select the code instead.', ok: false);
                    }
                  },
                ),
              ],
            ),
            const Hr(),
            const Text('This week', style: T.h2),
            const SizedBox(height: 8),
            for (final m in members)
              InkWell(
                onTap: () => context.go('/social/user/${m['userId']}'),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: C.line)),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 30,
                        child: Text('${m['rank']}', style: const TextStyle(fontWeight: FontWeight.w800)),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${m['displayName']}${m['isMe'] == true ? ' (you)' : ''}',
                              style: TextStyle(fontWeight: FontWeight.w700, color: m['isMe'] == true ? C.green : C.text),
                            ),
                            Text('${m['handleTag']}${m['role'] == 'owner' ? ' · Owner' : ''}', style: T.small),
                          ],
                        ),
                      ),
                      Text('${m['weeklyPoints']} pts', style: const TextStyle(fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
            const Hr(),
            const Text('League conversation', style: T.h3),
            ArrowLink(
              'Open messages',
              onTap: () => context.go('/social/thread/${l['threadId']}?title=${Uri.encodeQueryComponent(l['name'] as String)}'),
            ),
          ],
        );
      },
    );
  }
}
