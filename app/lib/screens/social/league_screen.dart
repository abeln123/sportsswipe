import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../../ui/shell.dart';
import '../../ui/widgets.dart';

/// Opens the phone's Messages app with the invite text filled in; the user
/// picks the recipient and sends it from their own number.
Future<void> textInvite(BuildContext context, String leagueId) async {
  final Map<String, dynamic> inv;
  try {
    inv = await api.post('/invites', {'leagueId': leagueId});
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message, ok: false);
    return;
  }
  final body = inv['smsBody'] as String;
  final mobile = defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android;
  if (mobile) {
    // "sms:?&body=" works on both iOS and Android.
    final sms = Uri.parse('sms:?&body=${Uri.encodeComponent(body)}');
    if (await launchUrl(sms)) return;
    try {
      final r = await SharePlus.instance
          .share(ShareParams(text: body, subject: 'Join my Sports Swipe league'))
          .timeout(const Duration(seconds: 20));
      if (r.status != ShareResultStatus.unavailable) return;
    } catch (_) {}
  }
  if (!context.mounted) return;
  await showSheet<void>(context, (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Text this invite', style: T.h2),
          const SizedBox(height: 6),
          Text('Open this page on your phone to send it from Messages, or copy the text below into a text.', style: T.dim),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            color: C.surface,
            child: SelectableText(body),
          ),
          const SizedBox(height: 16),
          PrimaryButton('Copy invite text', onPressed: () async {
            try {
              await Clipboard.setData(ClipboardData(text: body));
              if (ctx.mounted) {
                Navigator.pop(ctx);
                toast(context, 'Invite copied. Paste it into a text.');
              }
            } catch (_) {
              if (ctx.mounted) toast(ctx, 'Copy blocked by the browser. Select the text instead.', ok: false);
            }
          }),
          const SizedBox(height: 8),
          GhostButton('Done', onPressed: () => Navigator.pop(ctx)),
        ],
      ));
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
          return TabPage(back: 'Leagues', children: [ErrorText(snap.error!, onRetry: () => setState(() => _data = api.get('/leagues/${widget.leagueId}')))]);
        }
        if (!snap.hasData) return const Loading();
        final l = snap.data!;
        final members = (l['members'] as List).cast<Map<String, dynamic>>();
        return TabPage(
          back: 'Leagues',
          onRefresh: () async {
            setState(() => _data = api.get('/leagues/${widget.leagueId}'));
            await _data;
          },
          children: [
            PageTitle(l['name'] as String, '${members.length} of ${l['capacity']} members · weekly contest points'),
            PrimaryButton('Text an invite', busy: _inviting, onPressed: () async {
              setState(() => _inviting = true);
              try {
                await textInvite(context, widget.leagueId);
              } finally {
                if (mounted) setState(() => _inviting = false);
              }
            }),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
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
            ]),
            const Hr(),
            const Text('This week', style: T.h2),
            const SizedBox(height: 8),
            for (final m in members)
              InkWell(
                onTap: () => context.go('/social/user/${m['userId']}'),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
                  child: Row(children: [
                    SizedBox(width: 30, child: Text('${m['rank']}', style: const TextStyle(fontWeight: FontWeight.w800))),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${m['displayName']}${m['isMe'] == true ? ' (you)' : ''}',
                            style: TextStyle(fontWeight: FontWeight.w700, color: m['isMe'] == true ? C.green : C.text)),
                        Text('${m['handleTag']}${m['role'] == 'owner' ? ' · Owner' : ''}', style: T.small),
                      ]),
                    ),
                    Text('${m['weeklyPoints']} pts', style: const TextStyle(fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            const Hr(),
            const Text('League conversation', style: T.h3),
            ArrowLink('Open messages',
                onTap: () => context.go('/social/thread/${l['threadId']}?title=${Uri.encodeQueryComponent(l['name'] as String)}')),
          ],
        );
      },
    );
  }
}
