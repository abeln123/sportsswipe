import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../card/card_spec.dart';
import '../card/jersey_painter.dart';
import '../core/api.dart';
import '../core/theme.dart';
import 'widgets.dart';

Future<void> challengeShare(BuildContext context, {required CardSpec card, int? marketId}) async {
  try {
    final r = await api.get('/friends');
    if (!context.mounted) return;
    await showSheet<void>(
      context,
      (ctx) => _ChallengeShare(card: card, marketId: marketId, friends: (r['friends'] as List).cast<Map<String, dynamic>>()),
    );
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message, ok: false);
  }
}

class _ChallengeShare extends StatefulWidget {
  const _ChallengeShare({required this.card, this.marketId, required this.friends});
  final CardSpec card;
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
          'playerId': widget.card.playerId,
          if (widget.marketId != null) 'marketId': widget.marketId,
          if (_opponent != null) 'opponentId': _opponent,
        });
        _id = r['id'] as String;
        _url = r['url'] as String;
      }
      if (!mounted) return;
      if (_opponent != null) {
        final router = GoRouter.of(context);
        Navigator.pop(context);
        router.go('/social/head-to-head/$_id');
        return;
      }
      // Creating an invitation is asynchronous. Offer Share as a separate tap
      // so web browsers retain the user gesture required by the share sheet.
      setState(() {});
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: 'Play me in Sports Swipe: 10 cards, one tiebreaker. No coins. Open in your browser: $_url',
          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Sharing is unavailable in this browser. Copy the link below to send your invitation.');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          const Expanded(child: Text('HEAD TO HEAD', style: T.label)),
          IconButton(
            tooltip: 'Close invitation',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close, size: 20, color: C.dim),
          ),
        ],
      ),
      const SizedBox(height: 10),
      const Text('Challenge a friend', style: T.h1),
      const SizedBox(height: 18),
      Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: C.line),
            bottom: BorderSide(color: C.line),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 66,
              height: 76,
              child: CustomPaint(painter: JerseyPainter.forLeague(widget.card.league, widget.card.colorway, widget.card.jerseyNumber)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.card.fullName, style: T.h3),
                  const SizedBox(height: 4),
                  Text('${widget.card.teamAbbr} · ${widget.card.leagueLabel}', style: T.small),
                  const SizedBox(height: 8),
                  const Text('This card + nine more', style: T.dim),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _detail('1 vs 1', 'You vs. a friend')),
          Expanded(child: _detail('10 PICKS', 'Same cards. Same lines.')),
        ],
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(_error!, style: const TextStyle(color: C.danger)),
        ),
      const SizedBox(height: 24),
      if (_url == null) ...[
        if (widget.friends.isNotEmpty) ...[
          const Text('SEND IN MESSAGES', style: T.label),
          const SizedBox(height: 6),
          for (final u in widget.friends)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: InitialsBadge(initialsOf(u['displayName'] as String)),
              title: Text(u['displayName'] as String, style: T.h3),
              trailing: const Icon(Icons.arrow_forward, size: 20, color: C.dim),
              onTap: _busy ? null : () => _send(u),
            ),
          const SizedBox(height: 12),
        ],
        PrimaryButton('Create invite link', busy: _busy, onPressed: _busy ? null : () => _send()),
      ] else ...[
        const Text('INVITATION READY', style: T.label),
        const SizedBox(height: 10),
        SelectableText(_url!, style: T.dim),
        const SizedBox(height: 14),
        PrimaryButton('Send by text or link', onPressed: _share),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _url!));
                if (context.mounted) toast(context, 'Challenge link copied.');
              },
              icon: const Icon(Icons.copy, size: 15),
              label: const Text('Copy link'),
            ),
            TextButton(
              onPressed: () {
                final router = GoRouter.of(context);
                Navigator.pop(context);
                router.go('/social/head-to-head/$_id');
              },
              child: const Text('Make my picks →'),
            ),
          ],
        ),
      ],
    ],
  );
  Widget _detail(String label, String text) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: T.label.copyWith(color: C.text)),
      const SizedBox(height: 5),
      Text(text, style: T.small),
    ],
  );
}
