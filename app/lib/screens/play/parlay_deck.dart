import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../card/card_spec.dart';
import '../../card/sport_card.dart';
import '../../core/format.dart' as f;
import '../../core/payout.dart';
import '../../core/theme.dart';
import '../../state/pick_queue.dart';
import '../../ui/swipe.dart';
import '../../ui/widgets.dart';
import 'single_deck.dart';

class Leg {
  Leg(this.card, this.side);
  final PlayableCard card;
  final String side;
}

class ParlayDeck extends ConsumerStatefulWidget {
  const ParlayDeck({super.key, required this.sport});
  final String sport;

  @override
  ConsumerState<ParlayDeck> createState() => _ParlayDeckState();
}

class _ParlayDeckState extends ConsumerState<ParlayDeck> {
  late Future<List<PlayableCard>> _deck = loadDeck(widget.sport, limit: 20);
  int _index = 0;
  var _legs = <Leg>[];
  int _stake = 0;
  String? _pendingId;
  List<Leg>? _submitted;
  StreamSubscription<QueueEvent>? _sub;

  static const maxLegs = 5;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(pickQueueProvider.notifier).events.listen(_onEvent);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// A rejected parlay comes back as a draft without the stale legs.
  void _onEvent(QueueEvent e) {
    if (!mounted || e.intent.commandId != _pendingId) return;
    _pendingId = null;
    if (!e.rejected) {
      _submitted = null;
      return;
    }
    final stale = ((e.body['staleLegs'] as List?) ?? []).map((s) => (s as Map)['marketId']).toSet();
    setState(() {
      _legs = (_submitted ?? []).where((l) => !stale.contains(l.card.market.marketId)).toList();
      _submitted = null;
    });
  }

  void _add(List<PlayableCard> cards, String side) {
    if (_legs.length >= maxLegs) return;
    setState(() {
      _legs.add(Leg(cards[_index], side));
      _index++;
    });
  }

  bool _inDraft(PlayableCard c) => _legs.any((l) => l.card.market.marketId == c.market.marketId);

  Future<void> _review() async {
    final locked = await showSheet<bool>(context, (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
          final balance = math.max(0, ref.read(displayBalanceProvider));
          final stake = math.min(_stake, balance);
          final n = _legs.length;
          final ret = parlayReturn(stake, n);
          void update(VoidCallback fn) {
            setState(fn);
            setSheet(() {});
          }

          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('Review $n-pick parlay', style: T.h1)),
              Text('${parlayMultiplier(n)}×', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: C.under)),
            ]),
            const SizedBox(height: 10),
            const Text('Every leg must be correct to earn a return.', style: T.dim),
            const SizedBox(height: 14),
            for (final l in [..._legs])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  JerseyIcon(spec: l.card.card, size: 38),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(l.card.card.fullName, style: T.h3),
                      SideText(side: l.side, line: l.card.market.line, rest: l.card.market.statLabel),
                    ]),
                  ),
                  IconButton(
                    tooltip: 'Remove ${l.card.card.fullName}',
                    onPressed: () {
                      update(() => _legs.remove(l));
                      if (_legs.length < 2) Navigator.pop(ctx, false);
                    },
                    icon: const Icon(Icons.close, color: C.dim),
                  ),
                ]),
              ),
            const Hr(),
            Row(children: [
              const Text('Coin wager', style: T.h3),
              const Spacer(),
              Text('${f.coins(balance)} available', style: T.small),
            ]),
            Row(children: [
              WagerRing(value: stake, max: balance, dark: true, onChanged: (v) => update(() => _stake = v)),
              const Spacer(),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                const Text('Return if all hit', style: T.small),
                Text.rich(TextSpan(children: [
                  TextSpan(text: f.coins(ret), style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
                  const TextSpan(text: ' coins', style: TextStyle(fontSize: 14, color: C.dim)),
                ])),
                Text('+${f.coins(ret - stake)} net gain', style: const TextStyle(color: C.green, fontWeight: FontWeight.w700)),
                const Text('Includes wager', style: T.small),
              ]),
            ]),
            const Text('Drag ring or tap amount · − / + 25', style: T.small),
            const SizedBox(height: 4),
            Text(stake == 0 ? 'Free entry. Every leg must hit.' : 'A miss on any leg loses ${f.coins(stake)} coins.', style: T.dim),
            const Hr(),
            Text('Return includes your wager + ${legBonus * n} bonus coins. Parlays do not add contest points.', style: T.dim),
            const SizedBox(height: 22),
            PrimaryButton('Lock $n-leg parlay', onPressed: n >= 2 ? () => Navigator.pop(ctx, true) : null),
            const SizedBox(height: 6),
            Center(child: GhostButton('Cancel', color: C.dim, onPressed: () => Navigator.pop(ctx, false))),
          ]);
        }));
    if (locked == true && mounted) _lock();
  }

  void _lock() {
    final q = ref.read(pickQueueProvider.notifier);
    final balance = math.max(0, ref.read(displayBalanceProvider));
    final stake = math.min(_stake, balance);
    final legs = [..._legs];
    final id = q.add(
      path: '/parlays',
      payload: {
        'stake': stake,
        'legs': [
          for (final l in legs) {'marketId': l.card.market.marketId, 'lineVersion': l.card.market.lineVersion, 'side': l.side},
        ],
      },
      stake: stake,
      label: '${legs.length}-leg parlay',
    );
    setState(() {
      _pendingId = id;
      _submitted = legs;
      _legs = [];
      _stake = 0;
    });
    toast(context, '${legs.length}-leg parlay locked.', action: 'Undo', duration: undoWindow, onAction: () {
      if (q.undo(id) && mounted) {
        setState(() {
          _legs = legs;
          _pendingId = null;
          _submitted = null;
        });
      }
    });
  }

  Widget _slots() {
    return Row(children: [
      for (var i = 0; i < maxLegs; i++)
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.only(bottom: 8, top: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: i < _legs.length ? (_legs[i].side == 'over' ? C.over : C.under) : C.line,
                  width: 1.5,
                ),
              ),
            ),
            child: Column(children: [
              Text('${i + 1}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: i < _legs.length ? (_legs[i].side == 'over' ? C.over : C.under) : C.dim,
                  )),
              const SizedBox(height: 3),
              if (i < _legs.length) ...[
                Text(_legs[i].card.card.lastName.isEmpty ? _legs[i].card.card.fullName : _legs[i].card.card.lastName,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                Text('${_legs[i].side == 'over' ? 'O' : 'U'} ${f.line(_legs[i].card.market.line)}', style: T.small),
              ] else
                Text(i == 0 ? 'First leg' : i == 1 ? 'Second' : 'Optional', style: T.small.copyWith(fontSize: 12.5)),
            ]),
          ),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<PlayableCard>>(
      future: _deck,
      builder: (context, snap) {
        if (snap.hasError) return ErrorText(snap.error!, onRetry: () => setState(() => _deck = loadDeck(widget.sport, limit: 20)));
        if (!snap.hasData) return const Loading();
        final cards = snap.data!;
        while (_index < cards.length && _inDraft(cards[_index])) {
          _index++;
        }
        final n = _legs.length;
        final full = n >= maxLegs;
        final done = _index >= cards.length;
        return Column(children: [
          Expanded(
            child: LayoutBuilder(builder: (context, c) {
              final width = math.min(c.maxWidth - 40, 360.0);
              return ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 16), children: [
                Row(children: [
                  Text('$n ${n == 1 ? 'leg' : 'legs'} added', style: T.h3.copyWith(fontSize: 15)),
                  const Spacer(),
                  const Text('All legs must hit', style: T.small),
                ]),
                _slots(),
                const SizedBox(height: 14),
                if (full || done)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(children: [
                      Text(full ? 'FIVE LEGS ADDED' : 'END OF DECK', style: T.label),
                      const SizedBox(height: 10),
                      Text(n >= 2 ? 'Review parlay' : 'Not enough legs', style: T.h1),
                      const SizedBox(height: 10),
                      Text(
                        n >= 2
                            ? 'Review your calls and choose one coin wager. Nothing is locked yet.'
                            : 'A parlay needs at least two legs. Load another deck to keep building.',
                        style: T.dim,
                        textAlign: TextAlign.center,
                      ),
                      if (done && !full)
                        GhostButton('Load more cards', color: C.green, onPressed: () => setState(() {
                              _deck = loadDeck(widget.sport, limit: 20);
                              _index = 0;
                            })),
                    ]),
                  )
                else ...[
                  Center(
                    child: Swipeable(
                      key: ValueKey(cards[_index].market.marketId),
                      onSwipe: (side) => _add(cards, side),
                      child: SportCard(
                        spec: cards[_index].card,
                        market: cards[_index].market,
                        width: width,
                        topRight: '${f.two(_index + 1)} / ${f.two(cards.length)}',
                        body: Column(children: [
                          Container(height: 1, color: const Color(0xFFCBD3DB), margin: const EdgeInsets.only(top: 8)),
                          RecentForm(values: cards[_index].recentForm, statLabel: cards[_index].market.statLabel.toLowerCase()),
                          CommunityBar(overPct: cards[_index].market.overPct, total: cards[_index].market.communityTotal),
                        ]),
                        footer: CardFooter(
                          spec: cards[_index].card,
                          left: '${cards[_index].mastery.displayTier.toUpperCase()} / ${f.two(cards[_index].card.cardNo)}',
                          right: cards[_index].mastery.nextTier == null
                              ? 'Diamond earned'
                              : 'Earn ${f.cap(cards[_index].mastery.nextTier!)}: ${cards[_index].mastery.count}/${cards[_index].mastery.nextAt}',
                        ),
                      ),
                    ),
                  ),
                  SwipeButtons(hint: 'Swipe to add', onSide: (s) => _add(cards, s), onSkip: () => setState(() => _index++)),
                ],
              ]);
            }),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: C.line))),
            child: Column(children: [
              Row(children: [
                Text('$n ${n == 1 ? 'leg' : 'legs'} selected', style: const TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(n >= 2 ? '${parlayMultiplier(n)}× wager + ${legBonus * n} coins' : '2–5 legs · one entry',
                    style: const TextStyle(fontWeight: FontWeight.w600, color: C.dim)),
              ]),
              const SizedBox(height: 10),
              PrimaryButton(
                n >= 2 ? 'Review parlay' : 'Add ${2 - n} more ${2 - n == 1 ? 'leg' : 'legs'}',
                onPressed: n >= 2 ? _review : null,
              ),
            ]),
          ),
        ]);
      },
    );
  }
}
