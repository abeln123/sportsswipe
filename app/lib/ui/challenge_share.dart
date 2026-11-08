import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../core/api.dart';
import '../core/theme.dart';
import 'widgets.dart';

Future<void> challengeShare(BuildContext context, {required int playerId, int? marketId}) async {
  try {
    final r = await api.get('/friends');
    if (!context.mounted) return;
    await showSheet<void>(
      context,
      (ctx) => _ChallengeShare(playerId: playerId, marketId: marketId, friends: (r['friends'] as List).cast<Map<String, dynamic>>()),
    );
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message, ok: false);
  }
}

class _ChallengeShare extends StatefulWidget {
  const _ChallengeShare({required this.playerId, this.marketId, required this.friends});
  final int playerId;
  final int? marketId;
  final List<Map<String, dynamic>> friends;
  @override
  State<_ChallengeShare> createState() => _ChallengeShareState();
}

class _ChallengeShareState extends State<_ChallengeShare> {
  bool _busy = false;
  String? _error, _url, _id;
  String? _opponent;
  final _command = const Uuid().v4();
  Future<void> _send([Map<String, dynamic>? friend]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_id == null) {
        _opponent = friend?['userId'] as String?;
        final r = await api.post('/head-to-heads', {
          'commandId': _command,
          'playerId': widget.playerId,
          if (widget.marketId != null) 'marketId': widget.marketId,
          if (_opponent != null) 'opponentId': _opponent,
        });
        _id = r['id'] as String;
        _url = r['url'] as String;
      }
      if (!mounted) return;
      if (_opponent != null) {
        Navigator.pop(context);
        context.go('/social/head-to-head/$_id');
        return;
      }
      final box = context.findRenderObject() as RenderBox?;
      try {
        final r = await SharePlus.instance.share(
          ShareParams(
            text: 'Play me in Sports Swipe: 10 cards, one tiebreaker. No coins. Open in your browser: $_url',
            sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
        if (!mounted) return;
        if (r.status != ShareResultStatus.unavailable) {
          setState(() {});
          return;
        }
      } catch (_) {}
      if (mounted) setState(() {});
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('Send a card. Start a 1v1.', style: T.h2),
      const SizedBox(height: 8),
      const Text(
        'This card + 9 others. Same lines for both of you. Most correct wins, then the closest total-points tiebreaker. No coins or mastery rewards.',
        style: T.dim,
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(_error!, style: const TextStyle(color: C.danger)),
        ),
      if (_url == null) ...[
        const SizedBox(height: 16),
        for (final u in widget.friends)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: InitialsBadge(initialsOf(u['displayName'] as String)),
            title: Text(u['displayName'] as String),
            subtitle: const Text('Send invitation in Messages', style: T.small),
            trailing: const Icon(Icons.north_east, color: C.green),
            onTap: _busy ? null : () => _send(u),
          ),
        if (widget.friends.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Invite someone new with a link. They can sign up in a browser.', style: T.small),
          ),
        PrimaryButton('Invite by text or link', busy: _busy, onPressed: _busy ? null : () => _send()),
      ] else ...[
        const SizedBox(height: 16),
        SelectableText(_url!, style: T.dim),
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: _url!));
            if (context.mounted) toast(context, 'Challenge link copied.');
          },
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('Copy invite link'),
        ),
        PrimaryButton(
          'Make my 10 picks',
          onPressed: () {
            Navigator.pop(context);
            context.go('/social/head-to-head/$_id');
          },
        ),
      ],
    ],
  );
}
