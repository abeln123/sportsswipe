import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../card/card_spec.dart';
import '../../card/sport_card.dart';
import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../core/theme.dart';
import '../../state/session.dart';
import '../../ui/shell.dart';
import '../../ui/swipe.dart';
import '../../ui/widgets.dart';

class _Question {
  _Question(Map<String, dynamic> j)
      : id = (j['questionId'] as num).toInt(),
        no = (j['qNo'] as num).toInt(),
        card = PlayableCard.fromJson((j['playable'] as Map).cast<String, dynamic>());
  final int id;
  final int no;
  final PlayableCard card;
}

class ContestEntryScreen extends ConsumerStatefulWidget {
  const ContestEntryScreen({super.key, required this.dayId});
  final int dayId;

  @override
  ConsumerState<ContestEntryScreen> createState() => _ContestEntryScreenState();
}

class _ContestEntryScreenState extends ConsumerState<ContestEntryScreen> {
  Map<String, dynamic>? _slate;
  Object? _error;
  List<_Question> _qs = [];
  Map<int, String> _answers = {};
  int _cursor = 0;
  bool _reviewing = false;
  String? _commandId;
  bool _busy = false;
  final _tiebreak = TextEditingController();

  String get _draftKey => 'ss.contest.${ref.read(sessionProvider).value?.id}.${widget.dayId}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await api.get('/contest-days/${widget.dayId}/slate');
      final qs = (s['questions'] as List).map((e) => _Question((e as Map).cast<String, dynamic>())).toList();
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_draftKey);
      if (raw != null) {
        final d = jsonDecode(raw) as Map<String, dynamic>;
        if (d['slateVersion'] == s['slateVersion']) {
          _answers = (d['answers'] as Map).map((k, v) => MapEntry(int.parse(k as String), v as String));
          _commandId = d['commandId'] as String?;
          _tiebreak.text = d['tiebreak'] as String? ?? '';
        }
      }
      _commandId ??= const Uuid().v4();
      setState(() {
        _slate = s;
        _qs = qs;
        _cursor = qs.indexWhere((q) => !_answers.containsKey(q.id));
        if (_cursor < 0) {
          _cursor = 0;
          _reviewing = qs.isNotEmpty;
        }
      });
    } catch (e) {
      setState(() => _error = e);
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _draftKey,
      jsonEncode({
        'slateVersion': _slate?['slateVersion'],
        'commandId': _commandId,
        'tiebreak': _tiebreak.text,
        'answers': _answers.map((k, v) => MapEntry('$k', v)),
      }),
    );
  }

  void _answer(String side) {
    setState(() {
      _answers[_qs[_cursor].id] = side;
      final next = _qs.indexWhere((q) => !_answers.containsKey(q.id));
      if (next < 0) {
        _reviewing = true;
      } else {
        _cursor = next;
      }
    });
    _save();
  }

  Future<void> _submit() async {
    final tb = double.tryParse(_tiebreak.text.trim());
    if (tb == null) {
      toast(context, 'Enter a tiebreaker prediction.', ok: false);
      return;
    }
    final ok = await showSheet<bool>(context, (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Review contest entry', style: T.h1),
          const SizedBox(height: 8),
          Text('Day ${(_slate!['dayIndex'] as num) + 1}. Your picks are final once submitted.', style: T.dim),
          const SizedBox(height: 14),
          for (final q in _qs)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text.rich(TextSpan(style: const TextStyle(fontSize: 14), children: [
                TextSpan(text: '${q.no}.  ${q.card.card.fullName}: '),
                TextSpan(
                  text: '${_answers[q.id]} ${f.line(q.card.market.line)}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                TextSpan(text: ' ${q.card.market.statLabel.toLowerCase()}'),
              ])),
            ),
          const SizedBox(height: 12),
          Text.rich(TextSpan(children: [
            const TextSpan(text: 'Tiebreaker prediction: ', style: T.dim),
            TextSpan(text: f.line(tb), style: const TextStyle(fontWeight: FontWeight.w800)),
          ])),
          const SizedBox(height: 12),
          const Text('Free practice entry. No cash award or withdrawal.', style: T.small),
          const SizedBox(height: 20),
          PrimaryButton('Lock entry · Free', focusRing: true, onPressed: () => Navigator.pop(ctx, true)),
          const SizedBox(height: 6),
          Center(child: GhostButton('Cancel', color: C.dim, onPressed: () => Navigator.pop(ctx, false))),
        ]));
    if (ok != true) return;
    setState(() => _busy = true);
    final r = await api.raw('POST', '/contest-days/${widget.dayId}/entries', body: {
      'commandId': _commandId,
      'slateVersion': _slate!['slateVersion'],
      'tiebreak': tb,
      'answers': [for (final q in _qs) {'questionId': q.id, 'side': _answers[q.id]}],
    });
    setState(() => _busy = false);
    if (!mounted) return;
    final body = r.map;
    if (r.ok || body['code'] == 'already_entered') {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_draftKey);
      if (!mounted) return;
      toast(context, 'Contest entry locked.');
      setState(() => _slate = {..._slate!, 'receipt': r.ok ? body : body['receipt']});
    } else if (r.status == 0) {
      toast(context, 'Connection lost. Your draft is saved; try again.', ok: false);
    } else {
      toast(context, body['message']?.toString() ?? 'Could not submit.', ok: false);
      if (body['code'] == 'slate_changed') _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return TabPage(back: 'Weekly contest', children: [ErrorText(_error!, onRetry: _load)]);
    if (_slate == null) return const Loading();
    final s = _slate!;
    final receipt = (s['receipt'] as Map?)?.cast<String, dynamic>();
    final day = (s['dayIndex'] as num).toInt() + 1;
    if (receipt != null) return _receipt(day, receipt);
    if (s['open'] != true) {
      return TabPage(back: 'Weekly contest', children: [
        PageTitle('Day $day', 'This day is locked.'),
        const Text('Entries close at the first game of the day.', style: T.dim),
      ]);
    }
    return TabPage(back: 'Weekly contest', children: [
      PageTitle('Daily entry', 'Day $day · Practice contest'),
      Text('Draft saved on this device · Not submitted', style: T.small),
      const SizedBox(height: 12),
      if (!_reviewing) ..._cardStep() else ..._review(),
    ]);
  }

  List<Widget> _cardStep() {
    final q = _qs[_cursor];
    return [
      Row(children: [
        Text('Prediction ${_cursor + 1} of ${_qs.length}', style: T.small),
        const Spacer(),
        Text('${_answers.length} saved', style: T.small),
      ]),
      const SizedBox(height: 10),
      LayoutBuilder(builder: (context, c) {
        return Center(
          child: Swipeable(
            key: ValueKey(q.id),
            onSwipe: _answer,
            child: SportCard(
              spec: q.card.card,
              market: q.card.market,
              variant: CardVariant.contest,
              width: math.min(c.maxWidth, 360),
              topLeft: 'WEEKLY CONTEST',
              topRight: '${f.two(q.no)} / ${f.two(_qs.length)}',
              footer: const Padding(
                padding: EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Text('1 point for a correct prediction', style: TextStyle(fontSize: 12.5, color: C.ink)),
              ),
            ),
          ),
        );
      }),
      SwipeButtons(hint: 'Swipe to choose', onSide: _answer, onSkip: () {
        setState(() => _cursor = (_cursor + 1) % _qs.length);
      }),
      if (_answers.isNotEmpty) Align(alignment: Alignment.centerRight, child: ArrowLink('Review draft', onTap: () => setState(() => _reviewing = true))),
      const SizedBox(height: 10),
      const Text('Arrow keys work when the card is focused. No coin wager. Submit after reviewing every prediction.', style: T.dim),
    ];
  }

  List<Widget> _review() {
    final complete = _qs.every((q) => _answers.containsKey(q.id));
    return [
      for (final (i, q) in _qs.indexed)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(q.card.card.fullName, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('${q.card.market.statLabel} · Line ${f.line(q.card.market.line)}', style: T.small),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(_answers[q.id] == null ? '—' : f.cap(_answers[q.id]!),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: _answers[q.id] == 'over' ? C.over : _answers[q.id] == 'under' ? C.under : C.dim,
                  )),
              InkWell(
                onTap: () => setState(() {
                  _cursor = i;
                  _reviewing = false;
                }),
                child: const Padding(padding: EdgeInsets.only(top: 6), child: Text('Edit', style: T.small)),
              ),
            ]),
          ]),
        ),
      const SizedBox(height: 18),
      const Text('Prediction tiebreaker', style: T.h3),
      const SizedBox(height: 4),
      Text('${_slate!['tiebreakLabel'] ?? 'Combined total'}. Closest prediction breaks a points tie.', style: T.dim),
      TextField(
        controller: _tiebreak,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(hintText: 'Combined total'),
        onChanged: (_) => _save(),
      ),
      const SizedBox(height: 24),
      PrimaryButton('Review and submit · Free', busy: _busy, onPressed: complete ? _submit : null),
      if (!complete) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Answer every prediction first.', style: T.small)),
    ];
  }

  Widget _receipt(int day, Map<String, dynamic> r) {
    final answers = (r['answers'] as List).cast<Map<String, dynamic>>();
    final graded = answers.where((a) => a['result'] != null).length;
    return TabPage(back: 'Weekly contest', children: [
      PageTitle('Day $day entry', 'Locked ${f.dayTime(DateTime.parse(r['submittedAt'] as String))}'),
      Row(children: [
        Labeled('Points', '${r['points'] ?? 0}', suffix: ' / ${answers.length}'),
        const SizedBox(width: 30),
        Labeled('Graded', '$graded', suffix: ' / ${answers.length}'),
        const SizedBox(width: 30),
        Labeled('Tiebreaker', f.line((r['tiebreak'] as num))),
      ]),
      const Hr(),
      for (final a in answers)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${a['qNo']}. ${a['playerName']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                SideText(side: a['side'] as String, line: (a['line'] as num).toDouble(), rest: a['statLabel'] as String, size: 13.5),
              ]),
            ),
            Icon(
              a['correct'] == null ? Icons.schedule : (a['correct'] == true ? Icons.check_circle_outline : Icons.cancel_outlined),
              color: a['correct'] == null ? C.dim : (a['correct'] == true ? C.green : C.danger),
            ),
          ]),
        ),
      const SizedBox(height: 16),
      PrimaryButton('Back to contest', onPressed: () => context.go('/play')),
    ]);
  }
}
