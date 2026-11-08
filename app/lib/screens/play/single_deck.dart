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
import '../../ui/swipe.dart';
import '../../ui/widgets.dart';

Future<List<PlayableCard>> loadDeck(String sport, {int limit = 8}) async {
  final r = await api.get('/deck?sport=$sport&limit=$limit');
  return (r['cards'] as List).map((e) => PlayableCard.fromJson((e as Map).cast<String, dynamic>())).toList();
}

class SingleDeck extends ConsumerStatefulWidget {
  const SingleDeck({super.key, required this.sport, required this.onBuildParlay});
  final String sport;
  final VoidCallback onBuildParlay;

  @override
  ConsumerState<SingleDeck> createState() => _SingleDeckState();
}

class _SingleDeckState extends ConsumerState<SingleDeck> {
  late Future<List<PlayableCard>> _deck = loadDeck(widget.sport);
  int _index = 0;
  final _stakes = <int, int>{};

  /// Command ids locked from this deck, in card order.
  final _locked = <String>[];

  void _reload() => setState(() {
        _deck = loadDeck(widget.sport);
        _index = 0;
        _stakes.clear();
        _locked.clear();
      });

  Future<void> _choose(List<PlayableCard> cards, String side) async {
    final card = cards[_index];
    final stake = _stakes[card.market.marketId] ?? 0;
    if (stake > 0) {
      final ok = await _confirm(card, side, stake);
      if (ok != true || !mounted) return;
    }
    _lock(cards, card, side, stake);
  }

  void _lock(List<PlayableCard> cards, PlayableCard card, String side, int stake) {
    final q = ref.read(pickQueueProvider.notifier);
    final lineText = '${f.cap(side)} ${f.line(card.market.line)}';
    final id = q.add(
      path: '/picks',
      payload: {'marketId': card.market.marketId, 'lineVersion': card.market.lineVersion, 'side': side, 'stake': stake},
      stake: stake,
      label: '${card.card.fullName} · $lineText ${card.market.statLabel.toLowerCase()}',
    );
    final at = _index;
    setState(() {
      _locked.add(id);
      _index++;
    });
    if (_index >= cards.length) q.flush();
    toast(
      context,
      stake > 0 ? '${f.coins(stake)} coins · $lineText locked.' : '$lineText locked.',
      action: 'Undo',
      duration: undoWindow,
      onAction: () {
        if (q.undo(id) && mounted) {
          setState(() {
            _locked.remove(id);
            _index = at;
          });
        }
      },
    );
  }

  Future<bool?> _confirm(PlayableCard card, String side, int stake) {
    final balance = ref.read(displayBalanceProvider);
    final ret = singleReturn(stake);
    return showSheet<bool>(context, (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(card.card.fullName, style: T.h2.copyWith(fontSize: 24)),
          const SizedBox(height: 10),
          Text('${f.cap(side)} ${f.line(card.market.line)} ${card.market.statLabel.toLowerCase()}', style: T.h2),
          const SizedBox(height: 8),
          Text('${card.market.matchup} · ${f.time(card.market.startAt)}', style: T.dim),
          const SizedBox(height: 28),
          Center(child: Text('Return if right', style: T.dim)),
          Center(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: f.coins(ret), style: const TextStyle(fontSize: 52, fontWeight: FontWeight.w800, color: C.green)),
              const TextSpan(text: ' coins', style: TextStyle(fontSize: 18, color: C.dim)),
            ])),
          ),
          Center(child: Text('Includes your ${f.coins(stake)}-coin wager.', style: T.dim)),
          const SizedBox(height: 24),
          _row('Your wager', '${f.coins(stake)} coins'),
          const SizedBox(height: 12),
          _row('Balance after locking', '${f.coins(balance - stake)} coins'),
          const SizedBox(height: 14),
          Text('If incorrect, you lose ${f.coins(stake)} coins. Coins are always free and have no cash value.', style: T.small),
          const SizedBox(height: 22),
          PrimaryButton('Lock ${f.cap(side)} · ${f.coins(stake)} coins', focusRing: true, onPressed: () => Navigator.pop(ctx, true)),
          const SizedBox(height: 6),
          Center(child: GhostButton('Cancel', color: C.dim, onPressed: () => Navigator.pop(ctx, false))),
        ]));
  }

  Widget _row(String a, String b) => Row(children: [
        Text(a, style: T.body),
        const Spacer(),
        Text(b, style: T.body.copyWith(fontWeight: FontWeight.w700)),
      ]);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<PlayableCard>>(
      future: _deck,
      builder: (context, snap) {
        if (snap.hasError) return ErrorText(snap.error!, onRetry: _reload);
        if (!snap.hasData) return const Loading();
        final cards = snap.data!;
        if (cards.isEmpty) {
          return ListView(padding: const EdgeInsets.symmetric(horizontal: 20), children: [
            EmptyState(
              icon: Icons.event_busy_outlined,
              title: 'No open lines right now',
              body: 'New lines open before each NFL and NBA game. Check back closer to tip-off or kickoff.',
              action: PrimaryButton('Refresh', onPressed: _reload),
            ),
          ]);
        }
        if (_index >= cards.length) return _complete(cards.length);
        return _deckView(cards);
      },
    );
  }

  Widget _deckView(List<PlayableCard> cards) {
    final card = cards[_index];
    final balance = math.max(0, ref.watch(displayBalanceProvider));
    final stake = math.min(_stakes[card.market.marketId] ?? 0, balance);
    final ret = singleReturn(stake);
    return LayoutBuilder(builder: (context, c) {
      final width = math.min(c.maxWidth - 40, 360.0);
      return ListView(padding: const EdgeInsets.fromLTRB(20, 14, 20, 24), children: [
        Center(
          child: Swipeable(
            key: ValueKey(card.market.marketId),
            onSwipe: (side) => _choose(cards, side),
            child: SportCard(
              spec: card.card,
              market: card.market,
              width: width,
              topRight: '${f.two(_index + 1)} / ${f.two(cards.length)}',
              body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Container(height: 1, color: const Color(0xFFCBD3DB), margin: const EdgeInsets.only(top: 8, bottom: 10)),
                Row(children: [
                  const Text('Coin wager', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  const Spacer(),
                  Text('${f.coins(balance)} available', style: const TextStyle(fontSize: 12.5, color: C.inkDim)),
                ]),
                Row(children: [
                  WagerRing(
                    value: stake,
                    max: balance,
                    size: 84,
                    onChanged: (v) => setState(() => _stakes[card.market.marketId] = v),
                  ),
                  const Spacer(),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    const Text('Return if right', style: TextStyle(fontSize: 12.5, color: C.inkDim)),
                    Text.rich(TextSpan(children: [
                      TextSpan(text: f.coins(ret), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: C.ink)),
                      const TextSpan(text: ' coins', style: TextStyle(fontSize: 13, color: C.ink)),
                    ])),
                    Text('+${f.coins(ret - stake)} net gain',
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF1F8A4C))),
                    const Text('Includes wager', style: TextStyle(fontSize: 12, color: C.inkDim)),
                  ]),
                ]),
                const Text('Drag ring or tap amount · − / + 25', style: TextStyle(fontSize: 10.5, color: C.inkDim)),
                const SizedBox(height: 4),
                Text(stake == 0 ? 'Free pick. No coins at risk.' : 'Wrong call loses ${f.coins(stake)} coins.',
                    style: const TextStyle(fontSize: 12.5, color: C.ink)),
                Container(height: 1, color: const Color(0xFFCBD3DB), margin: const EdgeInsets.only(top: 8)),
                RecentForm(values: card.recentForm, statLabel: card.market.statLabel.toLowerCase()),
                CommunityBar(overPct: card.market.overPct, total: card.market.communityTotal),
              ]),
              footer: CardFooter(
                spec: card.card,
                left: '${card.mastery.displayTier.toUpperCase()} / ${f.two(card.card.cardNo)}',
                right: card.mastery.nextTier == null
                    ? 'Diamond earned'
                    : 'Earn ${f.cap(card.mastery.nextTier!)}: ${card.mastery.count}/${card.mastery.nextAt}',
              ),
            ),
          ),
        ),
        SwipeButtons(
          onSide: (side) => _choose(cards, side),
          onSkip: () => setState(() => _index++),
        ),
      ]);
    });
  }

  Widget _complete(int total) {
    final n = _locked.length;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 32, 20, 24), children: [
      Center(
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: C.line, width: 1.5)),
          child: const Icon(Icons.check, color: C.green),
        ),
      ),
      const SizedBox(height: 14),
      const Center(child: Text('Deck complete', style: T.small)),
      const SizedBox(height: 8),
      Center(child: Text(n > 0 ? 'Picks submitted' : 'Deck finished', style: T.h1)),
      const SizedBox(height: 8),
      Center(
        child: Text(
          n > 0 ? '$n ${n == 1 ? 'pick is' : 'picks are'} locked. Results arrive after each game ends.' : 'You skipped every card in this deck.',
          style: T.dim,
          textAlign: TextAlign.center,
        ),
      ),
      const SizedBox(height: 16),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < total; i++)
          Container(
            width: 34,
            height: 28,
            margin: const EdgeInsets.symmetric(horizontal: 2.5),
            decoration: BoxDecoration(color: const Color(0xFF263634), border: Border.all(color: C.line)),
            child: i < n ? const Icon(Icons.check, size: 16, color: C.text) : null,
          ),
      ]),
      const SizedBox(height: 22),
      Center(
        child: Text.rich(TextSpan(children: [
          TextSpan(text: '$n', style: T.big),
          const TextSpan(text: '  awaiting results', style: TextStyle(color: C.dim, fontSize: 16)),
        ])),
      ),
      const SizedBox(height: 22),
      PrimaryButton('Review my picks', onPressed: () => context.go('/picks')),
      const SizedBox(height: 18),
      Center(child: GhostButton('Start another practice deck', onPressed: _reload)),
      const SizedBox(height: 12),
      const Text('Extra play earns coins and mastery, never extra contest entries.', style: T.dim),
      const SizedBox(height: 18),
      ArrowLink('Build a parlay', color: C.under, onTap: widget.onBuildParlay),
    ]);
  }
}
