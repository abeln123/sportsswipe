import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../card/card_spec.dart';
import '../../card/sport_card.dart';
import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../core/theme.dart';
import '../../state/session.dart';
import '../../ui/swipe.dart';
import '../../ui/widgets.dart';

class HeadToHeadInviteScreen extends ConsumerStatefulWidget {
  const HeadToHeadInviteScreen({super.key, required this.token});
  final String token;
  @override
  ConsumerState<HeadToHeadInviteScreen> createState() => _HeadToHeadInviteState();
}

class _HeadToHeadInviteState extends ConsumerState<HeadToHeadInviteScreen> {
  late final _data = api.get('/head-to-head-invites/${widget.token}');
  bool _busy = false;
  String? _error;
  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      final r = await api.post('/head-to-head-invites/${widget.token}/accept', {});
      if (mounted) context.go('/social/head-to-head/${r['id']}');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      fit: StackFit.expand,
      children: [
        const Positioned.fill(child: PineBackdrop()),
        SafeArea(
          child: FutureBuilder(
            future: _data,
            builder: (context, snap) {
              if (snap.hasError) return ErrorText(snap.error!);
              if (!snap.hasData) return const Loading();
              final d = snap.data!;
              final me = ref.watch(sessionProvider).value;
              return ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const Text('SPORTS SWIPE · HEAD-TO-HEAD', style: T.label),
                  const SizedBox(height: 18),
                  Text('${d['creatorName']} challenged you.', style: T.h1),
                  const SizedBox(height: 20),
                  Center(
                    child: SportCard(
                      spec: CardSpec.fromJson((d['card'] as Map).cast<String, dynamic>()),
                      variant: CardVariant.tile,
                      width: 230,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('Picks lock ${f.dayTime(DateTime.parse(d['lockAt'] as String))}', style: T.small),
                  const SizedBox(height: 16),
                  if (d['open'] != true)
                    const Text('This challenge has locked. Ask for a fresh invite.', style: T.dim)
                  else if (me == null)
                    PrimaryButton(
                      'Sign up or sign in to play',
                      onPressed: () => context.go('/login?next=${Uri.encodeComponent('/duel/${widget.token}')}'),
                    )
                  else ...[
                    Text('Playing as ${me.displayName}', style: T.small),
                    const SizedBox(height: 10),
                    PrimaryButton('Accept 1v1 & connect as friends', busy: _busy, onPressed: _accept),
                  ],
                  if (_error != null) Text(_error!, style: const TextStyle(color: C.danger)),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}

class HeadToHeadScreen extends StatefulWidget {
  const HeadToHeadScreen({super.key, required this.id});
  final String id;
  @override
  State<HeadToHeadScreen> createState() => _HeadToHeadState();
}

class _HeadToHeadState extends State<HeadToHeadScreen> {
  Map<String, dynamic>? _data;
  Object? _error;
  final _tie = TextEditingController();
  final _answers = List<String?>.filled(10, null);
  int _index = 0;
  bool _busy = false, _loading = false;
  Timer? _poll;
  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tie.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final d = await api.get('/head-to-heads/${widget.id}');
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      _loading = false;
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_answers.any((v) => v == null)) {
      toast(context, 'Choose all ten cards.', ok: false);
      return;
    }
    final tie = int.tryParse(_tie.text);
    if (tie == null || tie < 0 || tie > 2000) {
      toast(context, 'Enter a total-points tiebreaker from 0 to 2000.', ok: false);
      return;
    }
    setState(() => _busy = true);
    try {
      await api.post('/head-to-heads/${widget.id}/submit', {'answers': _answers, 'tiebreak': tie});
      await _load();
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message, ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) return _error != null ? ErrorText(_error!, onRetry: _load) : const Loading();
    final people = (d['people'] as List).cast<Map<String, dynamic>>();
    final mine = people.firstWhere((p) => p['isMe'] == true);
    final submitted = mine['submitted'] == true;
    final cards = (d['cards'] as List).map((c) => PlayableCard.fromJson((c as Map).cast<String, dynamic>())).toList();
    final open = ['open', 'invited'].contains(d['status']) && DateTime.parse(d['lockAt'] as String).isAfter(DateTime.now());
    final canPlay = open && (d['isCreator'] == true || d['accepted'] == true) && !submitted;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
        children: [
          TextButton(
            onPressed: () => context.go('/social?tab=1'),
            child: const Align(alignment: Alignment.centerLeft, child: Text('← Messages')),
          ),
          const Text('HEAD-TO-HEAD', style: T.label),
          const SizedBox(height: 6),
          const Text('Ten calls. One rival.', style: T.h1),
          const SizedBox(height: 8),
          Text('${d['graded']} / 10 graded', style: T.small),
          const SizedBox(height: 16),
          for (final p in people)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(child: Text('${p['name']}${p['isMe'] == true ? ' · You' : ''}', style: T.h3)),
                  Text(
                    p['points'] == null ? (p['submitted'] == true ? 'Picks submitted' : 'Choosing picks') : '${p['points']} / 10',
                    style: T.body,
                  ),
                ],
              ),
            ),
          if (d['status'] == 'complete')
            Container(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text(
                d['draw'] == true
                    ? 'An exact tie. Rematch?'
                    : d['winnerId'] == mine['userId']
                    ? 'You won the head-to-head.'
                    : '${people.firstWhere((p) => p['userId'] == d['winnerId'])['name']} wins.',
                style: T.h2,
              ),
            ),
          Text('Locks ${f.dayTime(DateTime.parse(d['lockAt'] as String))}', style: T.small),
          if (d['accepted'] != true)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text('Waiting for opponent to accept.', style: T.dim),
            ),
          if (!canPlay && !submitted && open && d['isCreator'] != true)
            TextButton(
              onPressed: () => context.go('/duel/${Uri.parse(d['inviteUrl'] as String).pathSegments.last}'),
              child: const Text('Accept invitation'),
            ),
          if (cards.isNotEmpty && canPlay) ...[
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${_index + 1} / 10 · ${_index == 0 ? 'Shared card' : 'Match card'}', style: T.label),
                Text('${_answers.where((a) => a != null).length} chosen', style: T.small),
              ],
            ),
            const SizedBox(height: 12),
            Center(
              child: Swipeable(
                key: ValueKey(_index),
                verticalDrag: false,
                onSwipe: (side) => setState(() {
                  _answers[_index] = side;
                  if (_index < 9) _index++;
                }),
                child: SportCard(spec: cards[_index].card, market: cards[_index].market, width: 300, variant: CardVariant.contest),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => setState(() => _answers[_index] = 'under'),
                    child: Text('${_answers[_index] == 'under' ? '✓ ' : ''}${cards[_index].market.underLabel}'),
                  ),
                ),
                Expanded(
                  child: TextButton(
                    onPressed: () => setState(() => _answers[_index] = 'over'),
                    child: Text('${_answers[_index] == 'over' ? '✓ ' : ''}${cards[_index].market.overLabel}'),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(onPressed: _index == 0 ? null : () => setState(() => _index--), child: const Text('← Previous')),
                TextButton(onPressed: _index == 9 ? null : () => setState(() => _index++), child: const Text('Next →')),
              ],
            ),
            const SizedBox(height: 12),
            Text(d['tiebreakLabel'] as String, style: T.h3),
            TextField(
              controller: _tie,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Predicted combined total points'),
            ),
            const SizedBox(height: 16),
            PrimaryButton('Submit 10 picks', busy: _busy, onPressed: _submit),
          ],
          if (submitted) ...[
            const SizedBox(height: 18),
            const Text('Your submitted picks', style: T.h3),
            for (final (i, c) in cards.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '${i + 1}. ${c.card.fullName} · ${(mine['answers'] as List)[i]} ${f.line(c.market.line)} ${c.market.statLabel}',
                  style: T.small,
                ),
              ),
            Text('${d['tiebreakLabel']} · Your prediction: ${mine['tiebreak']}', style: T.small),
            if (d['tiebreakActual'] != null)
              Text('Final total: ${d['tiebreakActual']} · Your error: ${mine['tiebreakError']}', style: T.small),
          ],
          if (_error != null) ErrorText(_error!, onRetry: _load),
        ],
      ),
    );
  }
}

class HeadToHeadList extends StatefulWidget {
  const HeadToHeadList({super.key});
  @override
  State<HeadToHeadList> createState() => _HeadToHeadListState();
}

class _HeadToHeadListState extends State<HeadToHeadList> {
  late Future<Map<String, dynamic>> _data = api.get('/head-to-heads');
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && TickerMode.valuesOf(context).enabled) {
        setState(() {
          _data = api.get('/head-to-heads');
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _data,
    builder: (context, snap) {
      if (!snap.hasData) return const SizedBox.shrink();
      final matches = (snap.data!['matches'] as List).cast<Map<String, dynamic>>();
      if (matches.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 18),
          const Text('Your 1v1s', style: T.h2),
          for (final m in matches)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text((m['people'] as List).map((p) => p['name']).join(' vs ')),
              subtitle: Text('${m['status']} · ${m['graded']}/10 graded', style: T.small),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/social/head-to-head/${m['id']}'),
            ),
          const SizedBox(height: 18),
        ],
      );
    },
  );
}
