import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../card/card_spec.dart';
import '../../card/sport_card.dart';
import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../core/payout.dart';
import '../../core/theme.dart';
import '../../state/pick_queue.dart';
import '../../state/play.dart';
import '../../state/receipt.dart';
import '../../state/swipe_coach.dart';
import '../../ui/swipe.dart';
import '../../ui/widgets.dart';

/// Swipes through the cards dealt from a pack (or the leftovers), then shows
/// a recap with a way back to the store.
class PackDeck extends ConsumerStatefulWidget {
  const PackDeck({
    super.key,
    required this.title,
    required this.cards,
    required this.sport,
    required this.onExit,
    required this.onLeftovers,
    this.targetPct,
    this.payout,
  });

  final String title;
  final List<PlayableCard> cards;
  final String sport;

  /// Back to the pack store.
  final VoidCallback onExit;

  /// Start swiping the leftover cards.
  final VoidCallback onLeftovers;

  /// Challenge packs: share of picks that must hit, and what they pay.
  final int? targetPct;
  final int? payout;

  @override
  ConsumerState<PackDeck> createState() => _PackDeckState();
}

class _PackDeckState extends ConsumerState<PackDeck> {
  late final List<PlayableCard> _queue = [...widget.cards];
  final _stakes = <int, int>{};
  final _swipe = GlobalKey<SwipeableState>();

  /// Command ids locked from this deck, in card order.
  final _locked = <String>[];
  int? _leftovers;

  void _closeMenu() => ref.read(playMenuProvider.notifier).close();

  void _skip() => setState(() {
    if (_queue.length > 1) _queue.add(_queue.removeAt(0));
  });

  Future<void> _choose(String side) async {
    final card = _queue.first;
    final stake = _stakes[card.market.marketId] ?? 0;
    if (stake > 0) {
      final ok = await _confirm(card, side, stake);
      if (ok != true || !mounted) return;
    }
    _lock(card, side, stake);
  }

  void _lock(PlayableCard card, String side, int stake) {
    final q = ref.read(pickQueueProvider.notifier);
    final pick = card.market.pickText(side);
    final id = q.add(
      path: '/picks',
      payload: {
        'marketId': card.market.marketId,
        'lineVersion': card.market.lineVersion,
        'side': side,
        'stake': stake,
        if (card.packId != null) 'packId': card.packId,
      },
      stake: stake,
      label: '${card.card.fullName} · $pick ${card.market.isGame ? '' : card.market.statLabel.toLowerCase()}'.trim(),
    );
    setState(() {
      _locked.add(id);
      _queue.remove(card);
    });
    ref
        .read(receiptProvider.notifier)
        .show(
          id,
          '${card.subject} · $pick · ${stake == 0 ? 'Free pick' : '${f.coins(stake)} coins'}',
          onUndo: () {
            if (!mounted) return;
            setState(() {
              _locked.remove(id);
              _queue.insert(0, card);
            });
          },
        );
    if (_queue.isEmpty) _finish();
  }

  /// Everything goes out at the end of a deck; the recap also offers leftovers.
  Future<void> _finish() async {
    ref.read(pickQueueProvider.notifier).flush();
    try {
      final r = await api.get('/packs?sport=${widget.sport}');
      if (mounted) setState(() => _leftovers = (r['leftoverCount'] as num?)?.toInt() ?? 0);
    } catch (_) {}
  }

  Future<bool?> _confirm(PlayableCard card, String side, int stake) {
    final balance = ref.read(displayBalanceProvider);
    final ret = singleReturn(stake);
    return showSheet<bool>(
      context,
      (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(card.card.fullName, style: T.h2.copyWith(fontSize: 24)),
          const SizedBox(height: 10),
          Text(
            card.market.isGame ? card.market.pickText(side) : '${card.market.pickText(side)} ${card.market.statLabel.toLowerCase()}',
            style: T.h2,
          ),
          const SizedBox(height: 8),
          Text('${card.market.matchup} · ${f.time(card.market.startAt)}', style: T.dim),
          const SizedBox(height: 28),
          Center(child: Text('Return if right', style: T.dim)),
          Center(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: f.coins(ret),
                    style: const TextStyle(fontSize: 52, fontWeight: FontWeight.w800, color: C.text),
                  ),
                  const TextSpan(
                    text: ' coins',
                    style: TextStyle(fontSize: 18, color: C.dim),
                  ),
                ],
              ),
            ),
          ),
          Center(child: Text('Includes your ${f.coins(stake)}-coin wager.', style: T.dim)),
          const SizedBox(height: 24),
          _row('Your wager', '${f.coins(stake)} coins'),
          const SizedBox(height: 12),
          _row('Balance after locking', '${f.coins(balance - stake)} coins'),
          const SizedBox(height: 14),
          Text('If incorrect, you lose ${f.coins(stake)} coins. Coins are always free and have no cash value.', style: T.small),
          const SizedBox(height: 22),
          PrimaryButton(
            'Lock ${card.market.pickText(side)} · ${f.coins(stake)} coins',
            focusRing: true,
            onPressed: () => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 6),
          Center(
            child: GhostButton('Cancel', color: C.dim, onPressed: () => Navigator.pop(ctx, false)),
          ),
        ],
      ),
    );
  }

  Widget _row(String a, String b) => Row(
    children: [
      Text(a, style: T.body),
      const Spacer(),
      Text(b, style: T.body.copyWith(fontWeight: FontWeight.w700)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final done = _queue.isEmpty;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      child: done ? KeyedSubtree(key: const ValueKey('recap'), child: _recap()) : KeyedSubtree(key: const ValueKey('deck'), child: _deck()),
    );
  }

  Widget _deck() {
    final total = widget.cards.length;
    final played = total - _queue.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: widget.title,
                        style: const TextStyle(fontWeight: FontWeight.w700, color: C.text),
                      ),
                      TextSpan(
                        text: '  ${played + 1} of $total',
                        style: const TextStyle(color: C.dim),
                      ),
                      if (widget.targetPct != null)
                        TextSpan(
                          text: '  ·  Hit ${widget.targetPct}%',
                          style: const TextStyle(color: C.dim),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
              TextButton(
                onPressed: () {
                  ref.read(pickQueueProvider.notifier).flush();
                  widget.onExit();
                },
                style: TextButton.styleFrom(foregroundColor: C.dim, minimumSize: const Size(44, 40)),
                child: const Text('Save rest for later', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
        Expanded(
          child: CardStage(
            swipeKey: _swipe,
            topId: _queue.first.market.marketId,
            top: _card(_queue.first, _queue.length),
            next: _queue.length > 1 ? _card(_queue[1], _queue.length - 1) : null,
            coach: ref.watch(swipeCoachProvider),
            overLabel: _queue.first.market.isGame ? _queue.first.market.overLabel.toUpperCase() : 'OVER',
            underLabel: _queue.first.market.isGame ? _queue.first.market.underLabel.toUpperCase() : 'UNDER',
            onSwipe: (side) {
              ref.read(swipeCoachProvider.notifier).done();
              _choose(side);
            },
            onSkip: () {
              ref.read(swipeCoachProvider.notifier).done();
              _skip();
            },
            onEngage: _closeMenu,
            onPull: (dy) => playMenuPull.value = dy,
            onPullDown: () => ref.read(playMenuProvider.notifier).open(),
          ),
        ),
      ],
    );
  }

  Widget _card(PlayableCard card, int left) {
    final balance = math.max(0, ref.watch(displayBalanceProvider));
    final stake = math.min(_stakes[card.market.marketId] ?? 0, balance);
    final ret = singleReturn(stake);
    final m = card.market;
    return SportCard(
      spec: card.card,
      market: m,
      width: 340,
      topRight: '$left LEFT',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(height: 1, color: const Color(0xFFCBD3DB), margin: const EdgeInsets.only(top: 8, bottom: 10)),
          const Text('Coin wager', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          Row(
            children: [
              WagerControl(value: stake, max: balance, onChanged: (v) => setState(() => _stakes[m.marketId] = v)),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('Return if right', style: TextStyle(fontSize: 12.5, color: C.inkDim)),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: f.coins(ret),
                          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: C.ink),
                        ),
                        const TextSpan(
                          text: ' coins',
                          style: TextStyle(fontSize: 13, color: C.ink),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '+${f.coins(ret - stake)} net gain',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF1F8A4C)),
                  ),
                  const Text('Includes wager', style: TextStyle(fontSize: 12, color: C.inkDim)),
                ],
              ),
            ],
          ),
          const Text('Tap amount to edit · − / + 25', style: TextStyle(fontSize: 10.5, color: C.inkDim)),
          const SizedBox(height: 4),
          Text(
            stake == 0 ? 'Free pick. No coins at risk.' : 'Wrong call loses ${f.coins(stake)} coins.',
            style: const TextStyle(fontSize: 12.5, color: C.ink),
          ),
          Container(height: 1, color: const Color(0xFFCBD3DB), margin: const EdgeInsets.only(top: 8)),
          RecentForm(
            values: card.recentForm,
            statLabel: m.isGame ? (m.statKey == 'total' ? 'total points' : 'point margin, ${m.homeAbbr}') : m.statLabel.toLowerCase(),
          ),
          CommunityBar(
            overPct: m.overPct,
            total: m.communityTotal,
            overLabel: m.isGame ? m.overLabel : 'Over',
            underLabel: m.isGame ? m.underLabel : 'Under',
          ),
        ],
      ),
      footer: CardFooter(
        spec: card.card,
        left: '${card.mastery.displayTier.toUpperCase()} / ${f.two(card.card.cardNo)}',
        right: card.mastery.nextTier == null
            ? 'Diamond earned'
            : 'Earn ${f.cap(card.mastery.nextTier!)}: ${card.mastery.count}/${card.mastery.nextAt}',
      ),
    );
  }

  Widget _recap() {
    final n = _locked.length;
    final total = widget.cards.length;
    final left = _leftovers ?? 0;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
      children: [
        Center(
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: C.green, width: 1.5),
            ),
            child: const Icon(Icons.check, color: C.green),
          ),
        ),
        const SizedBox(height: 14),
        Center(child: Text('${widget.title.toUpperCase()} COMPLETE', style: T.label)),
        const SizedBox(height: 8),
        Center(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '$n', style: T.big),
                TextSpan(
                  text: n == 1 ? '  pick submitted' : '  picks submitted',
                  style: const TextStyle(color: C.dim, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            n > 0 ? 'Results arrive after each game ends.' : 'You skipped every card. They wait in your leftovers.',
            style: T.dim,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < total; i++)
              Container(
                width: 28,
                height: 38,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: i < n ? const Color(0xFF1C3A31) : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: i < n ? C.dim : C.line),
                ),
                child: i < n ? const Icon(Icons.check, size: 14, color: C.text) : null,
              ),
          ],
        ),
        if (widget.targetPct != null) ...[
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              border: Border.all(color: C.line),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Challenge: hit ${widget.targetPct}% of this pack to earn ${f.coins(widget.payout ?? 0)} coins. '
              'Unplayed cards count as misses once their games lock.',
              style: T.dim,
            ),
          ),
        ],
        const SizedBox(height: 24),
        PrimaryButton('View My picks', onPressed: () => context.go('/picks')),
        const SizedBox(height: 8),
        Center(child: GhostButton('Back to packs', bold: true, onPressed: widget.onExit)),
        if (left > 0) ...[
          const SizedBox(height: 4),
          Center(child: ArrowLink('Keep swiping · $left leftover ${left == 1 ? 'card' : 'cards'}', onTap: widget.onLeftovers)),
        ],
      ],
    );
  }
}
