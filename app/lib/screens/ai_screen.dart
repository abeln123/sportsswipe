import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../card/card_spec.dart';
import '../card/sport_card.dart';
import '../core/api.dart';
import '../core/format.dart' as f;
import '../core/theme.dart';
import '../state/pick_queue.dart';
import '../state/session.dart';
import '../ui/widgets.dart';

class AiScreen extends ConsumerStatefulWidget {
  const AiScreen({super.key});

  @override
  ConsumerState<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends ConsumerState<AiScreen> {
  final _q = TextEditingController();
  final _scroll = ScrollController();
  late final Future<Map<String, dynamic>> _suggestions = api.get('/analyst/suggestions');
  final _turns = <Map<String, dynamic>>[];
  bool _busy = false;

  String get _key => 'ss.ai.${ref.read(sessionProvider).value?.id}';

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || !mounted) return;
    setState(() => _turns.addAll((jsonDecode(raw) as List).cast<Map<String, dynamic>>()));
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final keep = _turns.length > 10 ? _turns.sublist(_turns.length - 10) : _turns;
    await prefs.setString(_key, jsonEncode(keep));
  }

  Future<void> _ask(String question, {Map<String, dynamic>? form}) async {
    if (question.trim().isEmpty || _busy) return;
    _q.clear();
    setState(() {
      _busy = true;
      _turns.add({'q': question});
    });
    try {
      final a = form != null ? await api.post('/analyst/form', form) : await api.post('/analyst/ask', {'question': question});
      _turns.last['a'] = a;
    } on ApiException catch (e) {
      _turns.last['a'] = {'kind': 'error', 'answer': e.message};
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _persist();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), children: [
          const PageTitle('AI analyst', 'Sports research and player trends'),
          const Row(children: [
            Icon(Icons.circle, size: 7, color: C.green),
            SizedBox(width: 8),
            Text('Computed from final ESPN box scores · no guesses', style: T.small),
          ]),
          if (_turns.isEmpty) ...[
            const SizedBox(height: 30),
            const Icon(Icons.show_chart, color: C.green, size: 30),
            const SizedBox(height: 20),
            const Text('Look closer at the game', style: T.h1),
            const SizedBox(height: 10),
            const Text('Ask about an NFL or NBA player\'s recent form. Answers show the numbers, game breakdown and sources.', style: T.dim),
            const SizedBox(height: 16),
            FutureBuilder(
              future: _suggestions,
              builder: (context, snap) {
                if (!snap.hasData) return const SizedBox(height: 40);
                final s = (snap.data!['suggestions'] as List).cast<Map<String, dynamic>>();
                return Column(children: [
                  for (final x in s)
                    InkWell(
                      onTap: () => _ask(x['label'] as String, form: {'playerId': x['playerId'], 'statKey': x['statKey'], 'n': 5}),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
                        child: Row(children: [
                          Expanded(child: Text(x['label'] as String, style: const TextStyle(fontSize: 14.5))),
                          const Icon(Icons.north_east, size: 18, color: C.green),
                        ]),
                      ),
                    ),
                ]);
              },
            ),
            const SizedBox(height: 14),
            const Text('Try "Josh Allen passing yards last 5 games" or "Tatum points against the Knicks".', style: T.small),
          ] else
            for (final t in _turns) ..._turn(t),
          if (_busy) const Loading(),
          if (_turns.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: GhostButton('Clear conversation', color: C.dim, onPressed: () {
                setState(_turns.clear);
                _persist();
              }),
            ),
        ]),
      ),
      Container(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: C.line))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Ask a sports question', style: T.small),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _q,
                maxLength: 300,
                decoration: const InputDecoration(hintText: 'Ask about a player or matchup…', counterText: ''),
                onSubmitted: _ask,
              ),
            ),
            const SizedBox(width: 12),
            Container(
              color: C.green,
              child: IconButton(onPressed: () => _ask(_q.text), icon: const Icon(Icons.arrow_upward, color: C.bg), tooltip: 'Ask'),
            ),
          ]),
          const SizedBox(height: 4),
          const Text('Saved on this device · optional card picks', style: T.small),
        ]),
      ),
    ]);
  }

  List<Widget> _turn(Map<String, dynamic> t) {
    final a = (t['a'] as Map?)?.cast<String, dynamic>();
    return [
      const Hr(),
      const Text('You', style: T.small),
      const SizedBox(height: 6),
      Text(t['q'] as String, style: T.body.copyWith(fontSize: 16)),
      if (a != null) ...[
        const SizedBox(height: 18),
        const Text('Sports Swipe AI', style: TextStyle(color: C.green, fontWeight: FontWeight.w700, fontSize: 13)),
        const Text('Calculated from stored box scores', style: T.small),
        const SizedBox(height: 12),
        _Answer(a),
      ],
    ];
  }
}

class _Answer extends ConsumerStatefulWidget {
  const _Answer(this.a);
  final Map<String, dynamic> a;

  @override
  ConsumerState<_Answer> createState() => _AnswerState();
}

class _AnswerState extends ConsumerState<_Answer> {
  bool _method = false;
  String? _picked;

  void _pick(PlayableCard p, String side) {
    final q = ref.read(pickQueueProvider.notifier);
    final id = q.add(
      path: '/picks',
      payload: {'marketId': p.market.marketId, 'lineVersion': p.market.lineVersion, 'side': side, 'stake': 0},
      stake: 0,
      label: '${p.card.fullName} · ${f.cap(side)} ${f.line(p.market.line)} ${p.market.statLabel.toLowerCase()}',
    );
    setState(() => _picked = side);
    toast(context, '${f.cap(side)} ${f.line(p.market.line)} locked · free pick.', action: 'Undo', duration: undoWindow, onAction: () {
      if (q.undo(id) && mounted) setState(() => _picked = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.a;
    final kind = a['kind'] as String;
    final card = a['card'] == null ? null : CardSpec.fromJson((a['card'] as Map).cast<String, dynamic>());
    final playable = a['playable'] == null ? null : PlayableCard.fromJson((a['playable'] as Map).cast<String, dynamic>());
    if (kind != 'form') {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (card != null) Text(card.fullName, style: T.h1),
        const SizedBox(height: 8),
        Text(a['answer'] as String, style: T.body),
      ]);
    }
    final m = (a['metric'] as Map).cast<String, dynamic>();
    final games = (a['games'] as List).cast<Map<String, dynamic>>();
    final line = (m['line'] as num?)?.toDouble();
    final values = games.map((g) => (g['value'] as num).toDouble()).toList();
    final maxV = values.fold<double>(line ?? 0, math.max);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(card!.fullName, style: T.h1),
      const SizedBox(height: 6),
      Text('${a['statLabel']} · last ${m['games']} games', style: T.small),
      const SizedBox(height: 14),
      Text(a['answer'] as String, style: T.body.copyWith(fontSize: 16)),
      const SizedBox(height: 18),
      Row(children: [
        Expanded(child: Labeled('Average', f.line(m['average'] as num))),
        if (m['aboveLine'] != null) Expanded(child: Labeled('Above line', '${m['aboveLine']}', suffix: ' / ${m['games']}')),
        Expanded(child: Labeled('Range', '${f.line(m['rangeMin'] as num)}–${f.line(m['rangeMax'] as num)}')),
      ]),
      const SizedBox(height: 20),
      Row(children: [
        const Text('Results', style: TextStyle(fontWeight: FontWeight.w700)),
        const Spacer(),
        const Text('Oldest → latest', style: T.small),
      ]),
      const SizedBox(height: 12),
      SizedBox(
        height: 150,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final (i, g) in games.indexed)
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                Text(f.line(g['value'] as num), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                const SizedBox(height: 6),
                Container(
                  width: 22,
                  height: maxV == 0 ? 2 : math.max(2, 90 * (g['value'] as num) / maxV),
                  color: i == games.length - 1 ? C.green : const Color(0xFF4C8A68),
                ),
                const SizedBox(height: 6),
                Text(i == games.length - 1 ? 'Latest' : 'G${i + 1}', style: T.small),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: 18),
      const Text('Game breakdown', style: TextStyle(fontWeight: FontWeight.w700)),
      const Divider(color: C.line),
      for (final (i, g) in games.indexed)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
          child: Row(children: [
            Expanded(flex: 3, child: Text('${f.shortDate(DateTime.parse(g['date'] as String))} vs ${g['opponent']}${i == games.length - 1 ? ' · Latest' : ''}')),
            Expanded(flex: 2, child: Text(f.line(g['value'] as num))),
            if (g['aboveLine'] != null)
              Text(g['aboveLine'] == true ? 'Above' : 'Below', style: TextStyle(color: g['aboveLine'] == true ? C.over : C.dim)),
          ]),
        ),
      const SizedBox(height: 12),
      Text(
        'Past results describe what happened, not a reliable probability for the next game. '
        '${values.length < 5 ? 'Small samples are especially noisy.' : ''}',
        style: T.small,
      ),
      InkWell(
        onTap: () => setState(() => _method = !_method),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text('${_method ? '▼' : '▶'} Data & method', style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      ),
      if (_method) ...[
        Text(a['definition'] as String, style: T.dim),
        const SizedBox(height: 6),
        for (final s in (a['sources'] as List).cast<Map<String, dynamic>>())
          InkWell(
            onTap: () => launchUrl(Uri.parse(s['url'] as String)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(s['label'] as String, style: const TextStyle(color: C.green, decoration: TextDecoration.underline)),
            ),
          ),
        Text('Data as of ${f.dayTime(DateTime.parse(a['dataAsOf'] as String))}', style: T.small),
      ],
      if (playable != null) ...[
        const Hr(),
        const Text('Playable card', style: TextStyle(color: C.green, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Center(
          child: SportCard(
            spec: playable.card,
            market: playable.market,
            width: 300,
            footer: CardFooter(
              spec: playable.card,
              scale: 300 / 340,
              left: '${playable.mastery.displayTier.toUpperCase()} / ${f.two(playable.card.cardNo)}',
              right: playable.mastery.nextTier == null ? '' : 'Earn ${f.cap(playable.mastery.nextTier!)}: ${playable.mastery.count}/${playable.mastery.nextAt}',
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (a['alreadyPickedEntryId'] != null || _picked != null)
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_picked != null ? 'Pick locked · ${f.cap(_picked!)}' : 'You already made this call.', style: T.dim),
            ArrowLink('View in My picks', onTap: () => context.go('/picks')),
          ])
        else
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => _pick(playable, 'under'), child: Text('Under ${f.line(playable.market.line)}', style: const TextStyle(color: C.under)))),
            const SizedBox(width: 12),
            Expanded(child: OutlinedButton(onPressed: () => _pick(playable, 'over'), child: Text('Over ${f.line(playable.market.line)}', style: const TextStyle(color: C.over)))),
          ]),
        const SizedBox(height: 4),
        const Text('Free pick from here. Use Play to add a coin wager.', style: T.small),
      ],
    ]);
  }
}
