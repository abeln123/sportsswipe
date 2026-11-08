import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

Future<List<PlayableCard>> loadDeck(String sport, {int limit = 8}) async {
  final r = await api.get('/deck?sport=$sport&limit=$limit');
  final raw = (r['cards'] as List?) ?? const [];
  final cards = <PlayableCard>[];
  for (final item in raw) {
    if (item is Map) {
      try {
        cards.add(PlayableCard.fromJson(item.cast<String, dynamic>()));
      } catch (_) {}
    }
  }
  return cards;
}

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
  }

  void _removeAt(int index) {
    if (index < 0 || index >= _legs.length) return;
    setState(() {
      final removed = _legs.removeAt(index);
      _queue?.insert(0, removed.card);
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
                      SideText(
                          side: l.side,
                          line: l.card.market.line,
                          rest: l.card.market.statLabel,
                          label: l.card.market.isGame ? l.card.market.pickText(l.side) : null),
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
            const Text('Coin wager', style: T.h3),
            Row(children: [
              WagerControl(value: stake, max: balance, dark: true, onChanged: (v) => update(() => _stake = v)),
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
            const Text('Tap amount to edit · − / + 25', style: T.small),
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
    ref.read(receiptProvider.notifier).show(
      id,
      '${legs.length}-leg parlay · ${parlayMultiplier(legs.length)}× · ${stake == 0 ? 'Free entry' : '${f.coins(stake)} coins'}',
      onUndo: () {
        if (!mounted) return;
        setState(() {
          _legs = legs;
          _pendingId = null;
          _submitted = null;
        });
      },
    );
  }

  Widget _slots() {
    const badges = ['Leg 1', '3×', '6×', '10×', '20×'];
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Row(
        children: [
          for (var i = 0; i < maxLegs; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 4, right: i == maxLegs - 1 ? 0 : 4),
                child: i < _legs.length
                    ? Semantics(
                        button: true,
                        label: 'Remove ${_legs[i].card.card.fullName} from parlay',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => _removeAt(i),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                            decoration: BoxDecoration(
                              color: C.surface,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: (_legs[i].side == 'over' ? C.over : C.under).withValues(alpha: 0.75),
                                width: 1.2,
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _legs[i].card.card.lastName.isEmpty
                                            ? _legs[i].card.card.fullName
                                            : _legs[i].card.card.lastName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: C.text),
                                      ),
                                    ),
                                    const Icon(Icons.close, size: 11, color: C.dim),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _legs[i].card.market.isGame
                                      ? _legs[i].card.market.pickText(_legs[i].side)
                                      : '${_legs[i].side == 'over' ? 'O' : 'U'} ${f.line(_legs[i].card.market.line)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: _legs[i].side == 'over' ? C.over : C.under,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    : Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
                        decoration: BoxDecoration(
                          color: C.surface.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: C.line.withValues(alpha: 0.85)),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              badges[i],
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: i < 2 ? C.text.withValues(alpha: 0.75) : C.dim,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              i < 2 ? 'Required' : 'Bonus',
                              maxLines: 1,
                              style: const TextStyle(fontSize: 10.5, color: C.dim),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: ErrorText(_error!, onRetry: _reload));
    if (_queue == null) return const Loading.card();
    final queue = _queue!;
    final n = _legs.length;
    final full = n >= maxLegs;
    final done = queue.isEmpty;
    if (done && n == 0) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          EmptyState(
            icon: Icons.layers_outlined,
            title: 'No open lines right now',
            body: 'Parlays combine 2 to 5 predictions into one higher-multiplier entry. Check back when the next slate opens.',
            action: GhostButton('Refresh lines', color: C.green, bold: true, onPressed: _reload),
          ),
        ],
      );
    }
    return Column(children: [
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
                      Text(n >= 2 ? 'Review parlay' : 'Add one more leg', style: T.h1),
                      const SizedBox(height: 10),
                      Text(
                        n >= 2
                            ? 'Review your calls and choose one coin wager. Nothing is locked yet.'
                            : 'A parlay needs at least two legs. Load more cards or tap your selected leg above to clear it.',
                        style: T.dim,
                        textAlign: TextAlign.center,
                      ),
                      if (done && !full) ...[
                        const SizedBox(height: 12),
                        GhostButton('Load more cards', color: C.green, bold: true, onPressed: _reload),
                      ],
                    ]),
                  ),
                ])
              : CardStage(
                  key: const ValueKey('deck'),
                  swipeKey: _swipe,
                  topId: queue.first.market.marketId,
                  top: _card(queue.first, queue.length),
                  next: queue.length > 1 ? _card(queue[1], queue.length - 1) : null,
                  coach: ref.watch(swipeCoachProvider),
                  onSwipe: (side) {
                    ref.read(swipeCoachProvider.notifier).done();
                    _add(side);
                  },
                  onSkip: () {
                    ref.read(swipeCoachProvider.notifier).done();
                    _skip();
                  },
                  overLabel: queue.first.market.isGame ? queue.first.market.overLabel.toUpperCase() : 'OVER',
                  underLabel: queue.first.market.isGame ? queue.first.market.underLabel.toUpperCase() : 'UNDER',
                  onEngage: () => ref.read(playMenuProvider.notifier).close(),
                  onPull: (dy) => playMenuPull.value = dy,
                  onPullDown: () => ref.read(playMenuProvider.notifier).open(),
                ),
        ),
      ),
      Collapse(
        visible: n >= 1 || full,
        alignment: Alignment.bottomCenter,
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
          decoration: const BoxDecoration(
            color: C.bg,
            border: Border(top: BorderSide(color: C.line)),
          ),
          child: Column(children: [
            Row(children: [
              Text('$n ${n == 1 ? 'leg' : 'legs'} selected', style: const TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                n >= 2 ? '${parlayMultiplier(n)}× wager + ${legBonus * n} coins' : 'Pick 1 more leg for 3×',
                style: TextStyle(fontWeight: FontWeight.w600, color: n >= 2 ? C.green : C.dim),
              ),
            ]),
            if (n >= 2) ...[
              const SizedBox(height: 10),
              PrimaryButton('Review $n-leg parlay', onPressed: _review),
            ],
          ]),
        ),
      ),
    ]);
  }

  Widget _card(PlayableCard c, int left) {
    final m = c.market;
    return SportCard(
      spec: c.card,
      market: m,
      width: 340,
      topRight: '$left LEFT',
      body: Column(children: [
        Container(height: 1, color: const Color(0xFFCBD3DB), margin: const EdgeInsets.only(top: 8)),
        RecentForm(
          values: c.recentForm,
          statLabel: m.isGame ? (m.statKey == 'total' ? 'total points' : 'point margin, ${m.homeAbbr}') : m.statLabel.toLowerCase(),
        ),
        CommunityBar(
          overPct: m.overPct,
          total: m.communityTotal,
          overLabel: m.isGame ? m.overLabel : 'Over',
          underLabel: m.isGame ? m.underLabel : 'Under',
        ),
      ]),
      footer: CardFooter(
        spec: c.card,
        left: '${c.mastery.displayTier.toUpperCase()} / ${f.two(c.card.cardNo)}',
        right: c.mastery.nextTier == null ? 'Diamond earned' : 'Earn ${f.cap(c.mastery.nextTier!)}: ${c.mastery.count}/${c.mastery.nextAt}',
      ),
    );
  }
}
