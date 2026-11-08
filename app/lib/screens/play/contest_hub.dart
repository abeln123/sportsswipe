import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../core/theme.dart';
import '../../state/session.dart';
import '../../ui/widgets.dart';

class ContestHub extends ConsumerStatefulWidget {
  const ContestHub({super.key});

  @override
  ConsumerState<ContestHub> createState() => _ContestHubState();
}

class _ContestHubState extends ConsumerState<ContestHub> {
  late Future<Map<String, dynamic>> _current = api.get('/contests/current');
  Future<Map<String, dynamic>>? _standings;
  bool _showStandings = false;
  bool _showPrizes = false;
  bool _showDemo = false;
  bool _settling = false;

  Future<void> _refresh() async {
    setState(() {
      _current = api.get('/contests/current');
      _standings = null;
    });
    await _current;
  }

  Future<void> _settleDay(int dayId) async {
    setState(() => _settling = true);
    try {
      final r = await api.post('/admin/settle-contest-day', {'dayId': dayId});
      if (!mounted) return;
      toast(context, 'Settled ${(r['settled'] as List).length} questions and graded the day.');
      ref.read(summaryProvider.notifier).refresh();
      await _refresh();
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message, ok: false);
    } finally {
      if (mounted) setState(() => _settling = false);
    }
  }

  static const _dow = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(summaryProvider).isAdmin;
    return FutureBuilder<Map<String, dynamic>>(
      future: _current,
      builder: (context, snap) {
        if (snap.hasError) return ErrorText(snap.error!, onRetry: _refresh);
        if (!snap.hasData) return const Loading();
        final c = snap.data!;
        final days = (c['days'] as List).cast<Map<String, dynamic>>();
        final today = days.where((d) => d['isToday'] == true).firstOrNull;
        final me = (c['me'] as Map).cast<String, dynamic>();
        return RefreshIndicator(
          onRefresh: _refresh,
          color: C.green,
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 18, 20, 32), children: [
            const Text('Weekly contest', style: T.h1),
            const SizedBox(height: 18),
            ..._today(today),
            const Hr(v: 26),
            const Text('Your week', style: T.h2),
            const SizedBox(height: 14),
            Row(children: [
              Labeled('Weekly points', '${me['points']}', suffix: ' / ${c['maxPoints']}'),
              const SizedBox(width: 30),
              Labeled('Days counted', '${me['daysCounted']}', suffix: ' / ${c['countedDays']}'),
              const Spacer(),
              if (me['rank'] != null) Labeled('Rank', '#${me['rank']}'),
            ]),
            const SizedBox(height: 18),
            Row(children: [
              for (final d in days)
                Expanded(
                  child: InkWell(
                    onTap: d['status'] != 'upcoming' && d['status'] != 'unavailable'
                        ? () => context.go('/play/contest/${d['dayId']}')
                        : null,
                    child: Container(
                      padding: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: d['isToday'] == true ? C.green : Colors.transparent, width: 2)),
                      ),
                      child: Column(children: [
                        Text(_dow[(d['dayIndex'] as num).toInt() % 7],
                            style: TextStyle(fontSize: 13, color: d['isToday'] == true ? C.green : C.text, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        _dayStatus(d),
                        if (d['isToday'] == true) const Text('Today', style: TextStyle(fontSize: 10, color: C.dim)),
                      ]),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 18),
            _disclosure('Weekly standings', _showStandings, () {
              setState(() {
                _showStandings = !_showStandings;
                _standings ??= api.get('/contests/${c['contestId']}/standings');
              });
            }),
            if (_showStandings) _standingsView(),
            const Hr(v: 22),
            const Text('Prizes', style: T.h2),
            const SizedBox(height: 14),
            const Text('\$1,500', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            _disclosure('Prize breakdown', _showPrizes, () => setState(() => _showPrizes = !_showPrizes)),
            if (_showPrizes)
              const Padding(
                padding: EdgeInsets.only(left: 16, bottom: 8),
                child: Text(
                  '1st \$300 · 2nd \$150 · 3rd \$100 · 4th–10th \$40 · 11th–60th \$13.60',
                  style: T.dim,
                ),
              ),
            if (isAdmin) ...[
              const Hr(v: 22),
              _disclosure('Demo controls', _showDemo, () => setState(() => _showDemo = !_showDemo)),
              if (_showDemo) ...[
                const SizedBox(height: 10),
                if (today != null && (today['questionCount'] as num) > 0)
                  PrimaryButton('Settle today\'s contest day', busy: _settling, onPressed: () => _settleDay((today['dayId'] as num).toInt())),
                ArrowLink('Open market settle tools', onTap: () => context.go('/profile/admin')),
              ],
            ],
          ]),
        );
      },
    );
  }

  List<Widget> _today(Map<String, dynamic>? d) {
    if (d == null) return [const Text('No contest day today.', style: T.dim)];
    final idx = (d['dayIndex'] as num).toInt() + 1;
    final lock = f.parseTime(d['lockAt']);
    final status = d['status'] as String;
    final entered = d['entered'] == true;
    return [
      Text('Day $idx of 7', style: const TextStyle(color: C.green, fontWeight: FontWeight.w700, fontSize: 13)),
      const SizedBox(height: 8),
      const Text('Today\'s entry', style: T.h1),
      const SizedBox(height: 8),
      Text(
        switch (status) {
          'upcoming' => 'Today\'s slate is not published yet.',
          'unavailable' => 'Not enough games today for a contest slate.',
          _ when entered => 'Your entry is locked${d['points'] != null ? ' · ${d['points']} points' : ''}.',
          'open' => '${d['questionCount']} predictions + tiebreaker',
          'graded' => 'Today is graded.',
          _ => 'Today is locked.',
        },
        style: T.dim,
      ),
      const SizedBox(height: 16),
      if (status == 'open' && !entered)
        PrimaryButton('Start daily entry', onPressed: () => context.go('/play/contest/${d['dayId']}'))
      else if (entered || status == 'graded' || status == 'locked')
        PrimaryButton(entered ? 'View my entry' : 'View slate', onPressed: () => context.go('/play/contest/${d['dayId']}')),
      if (lock != null) ...[
        const SizedBox(height: 10),
        Text(
          lock.isAfter(DateTime.now()) ? 'Locks ${f.dayTime(lock)}' : 'Locked ${f.dayTime(lock)}',
          style: T.dim,
        ),
      ],
    ];
  }

  Widget _dayStatus(Map<String, dynamic> d) {
    final s = d['status'] as String;
    if (d['entered'] == true && s == 'graded') {
      return Text('${d['points']}', style: const TextStyle(color: C.green, fontWeight: FontWeight.w800, fontSize: 16));
    }
    if (d['entered'] == true) return const Text('Locked', style: TextStyle(color: C.green, fontWeight: FontWeight.w800, fontSize: 13));
    if (s == 'open') return const Text('Open', style: TextStyle(color: C.text, fontSize: 12));
    return const Text('•', style: TextStyle(color: C.dim));
  }

  Widget _disclosure(String label, bool open, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text('${open ? '▼' : '▶'} $label', style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      );

  Widget _standingsView() => FutureBuilder<Map<String, dynamic>>(
        future: _standings,
        builder: (context, snap) {
          if (!snap.hasData) return const Loading();
          final rows = (snap.data!['rows'] as List).cast<Map<String, dynamic>>();
          if (rows.isEmpty) return const Padding(padding: EdgeInsets.all(8), child: Text('No graded entries yet this week.', style: T.dim));
          return Column(children: [
            for (final r in rows)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
                child: Row(children: [
                  SizedBox(width: 34, child: Text('${r['rank']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                  Expanded(
                    child: Text('${r['displayName']}${r['isMe'] == true ? ' (you)' : ''}',
                        style: TextStyle(fontWeight: FontWeight.w600, color: r['isMe'] == true ? C.green : C.text)),
                  ),
                  Text('${r['points']} pts · ${r['daysCounted']}d', style: T.small),
                ]),
              ),
          ]);
        },
      );
}
