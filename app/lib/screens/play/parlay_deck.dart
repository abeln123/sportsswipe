import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../card/card_spec.dart';
import '../../card/sport_card.dart';
import '../../core/format.dart' as f;
import '../../core/payout.dart';
import '../../core/theme.dart';
import '../../state/immersive.dart';
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
  /// Cards not in the draft, top first. Skipping sends the top card to the back.
  List<PlayableCard>? _queue;
  Object? _error;
  final _swipe = GlobalKey<SwipeableState>();
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
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _queue = null;
      _error = null;
    });
    try {
      final cards = await loadDeck(widget.sport, limit: 20);
      if (mounted) setState(() => _queue = cards.where((c) => !_inDraft(c)).toList());
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _immersive(bool on) => ref.read(immersiveProvider.notifier).set(on);

  void _skip() => setState(() {
        final q = _queue!;
        if (q.length > 1) q.add(q.removeAt(0));
      });

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

  void _add(String side) {
    if (_legs.length >= maxLegs) return;
    setState(() => _legs.add(Leg(_queue!.removeAt(0), side)));
    if (_legs.length >= maxLegs || _queue!.isEmpty) _immersive(false);
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
                      update(() {
                        _legs.remove(l);
                        _queue?.add(l.card);
                      });
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
    if (_error != null) return ErrorText(_error!, onRetry: _reload);
    if (_queue == null) return const Loading.card();
    final queue = _queue!;
    final immersive = ref.watch(immersiveProvider);
    final n = _legs.length;
    final full = n >= maxLegs;
    final done = queue.isEmpty;
    return Column(children: [
      Collapse(
        visible: !immersive,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Row(children: [
            Text('$n ${n == 1 ? 'leg' : 'legs'} added', style: T.h3.copyWith(fontSize: 15)),
            const Spacer(),
            const Text('All legs must hit', style: T.small),
          ]),
        ),
      ),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: _slots()),
      Expanded(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: (full || done)
              ? ListView(key: const ValueKey('end'), padding: const EdgeInsets.fromLTRB(20, 4, 20, 16), children: [
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
                      if (done && !full) GhostButton('Load more cards', color: C.green, onPressed: _reload),
                    ]),
                  ),
                ])
              : Column(key: const ValueKey('deck'), children: [
                  Expanded(
                    child: CardStage(
                      swipeKey: _swipe,
                      topId: queue.first.market.marketId,
                      top: _card(queue.first, queue.length),
                      next: queue.length > 1 ? _card(queue[1], queue.length - 1) : null,
                      onSwipe: _add,
                      onSkip: _skip,
                      onEngage: () => _immersive(true),
                      onPullDown: () => _immersive(false),
                    ),
                  ),
                  SwipeButtons(swipe: _swipe, hint: immersive ? null : 'Swipe to add a leg · up to skip'),
                ]),
        ),
      ),
      Collapse(
        visible: !immersive || n >= 2 || full || done,
        alignment: Alignment.bottomCenter,
        child: Container(
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
      ),
    ]);
  }

  Widget _card(PlayableCard c, int left) => SportCard(
        spec: c.card,
        market: c.market,
        width: 340,
        topRight: '$left LEFT',
        body: Column(children: [
          Container(height: 1, color: const Color(0xFFCBD3DB), margin: const EdgeInsets.only(top: 8)),
          RecentForm(values: c.recentForm, statLabel: c.market.statLabel.toLowerCase()),
          CommunityBar(overPct: c.market.overPct, total: c.market.communityTotal),
        ]),
        footer: CardFooter(
          spec: c.card,
          left: '${c.mastery.displayTier.toUpperCase()} / ${f.two(c.card.cardNo)}',
          right: c.mastery.nextTier == null ? 'Diamond earned' : 'Earn ${f.cap(c.mastery.nextTier!)}: ${c.mastery.count}/${c.mastery.nextAt}',
        ),
      );
}
