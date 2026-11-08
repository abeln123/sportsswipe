import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../core/theme.dart';
import '../../state/session.dart';
import '../../ui/shell.dart';
import '../../ui/widgets.dart';

/// Demo controls: inject a final stat value for a market and run the real
/// grading path, so a judge sees a complete pick-to-payout loop on demand.
class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  final _q = TextEditingController();
  String _status = 'open';
  late Future<Map<String, dynamic>> _data = _load();

  Future<Map<String, dynamic>> _load() {
    final q = _q.text.trim();
    return api.get('/admin/markets?status=$_status${q.isEmpty ? '' : '&q=${Uri.encodeQueryComponent(q)}'}');
  }

  void _reload() => setState(() => _data = _load());

  Future<void> _settle(Map<String, dynamic> m) async {
    final value = TextEditingController();
    final go = await showSheet<bool>(context, (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Settle ${m['playerName']}', style: T.h2),
          const SizedBox(height: 6),
          Text('${m['statLabel']} · line ${f.line(m['line'] as num)} · ${m['picks']} picks', style: T.dim),
          TextField(
            controller: value,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Final stat value (blank = random near the line)'),
          ),
          const SizedBox(height: 10),
          const Text(
            'Locks the market, records the value as a new result revision and runs the same grading function the worker uses. '
            'Settling again with a different value regrades and credits only the difference.',
            style: T.small,
          ),
          const SizedBox(height: 18),
          PrimaryButton('Settle now', onPressed: () => Navigator.pop(ctx, true)),
          Center(child: GhostButton('Cancel', color: C.dim, onPressed: () => Navigator.pop(ctx, false))),
        ]));
    if (go != true) return;
    try {
      final v = double.tryParse(value.text.trim());
      final r = await api.post('/admin/settle-market', {'marketId': m['marketId'], 'value': ?v});
      final s = (r['summary'] as Map).cast<String, dynamic>();
      if (!mounted) return;
      toast(
        context,
        'Final ${f.line(r['value'] as num)} vs ${f.line(r['line'] as num)}: ${s['entriesSettled']} entries settled, '
        '${f.coins(s['coinsCredited'] as num)} coins credited.',
        duration: const Duration(seconds: 6),
      );
      ref.read(summaryProvider.notifier).refresh();
      _reload();
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message, ok: false);
    }
  }

  Future<void> _lock(Map<String, dynamic> m) async {
    try {
      await api.post('/admin/lock-market', {'marketId': m['marketId']});
      if (mounted) toast(context, 'Locked ${m['playerName']} ${m['statLabel']}.');
      _reload();
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message, ok: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TabPage(back: 'Profile', onRefresh: () async => _reload(), children: [
      const PageTitle('Demo controls', 'Settle a market with a final stat value'),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _q,
            decoration: const InputDecoration(hintText: 'Player name'),
            onSubmitted: (_) => _reload(),
          ),
        ),
        const SizedBox(width: 10),
        DropdownButton<String>(
          value: _status,
          dropdownColor: C.sheet,
          items: const [
            DropdownMenuItem(value: 'open', child: Text('Open')),
            DropdownMenuItem(value: 'locked', child: Text('Locked')),
            DropdownMenuItem(value: 'settled', child: Text('Settled')),
            DropdownMenuItem(value: 'void', child: Text('Void')),
          ],
          onChanged: (v) {
            _status = v ?? 'open';
            _reload();
          },
        ),
      ]),
      const SizedBox(height: 8),
      const Text('Markets with the most picks are listed first.', style: T.small),
      FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) return ErrorText(snap.error!, onRetry: _reload);
          if (!snap.hasData) return const Loading();
          final markets = (snap.data!['markets'] as List).cast<Map<String, dynamic>>();
          if (markets.isEmpty) return const Padding(padding: EdgeInsets.all(20), child: Text('No markets.', style: T.dim));
          return Column(children: [
            for (final m in markets)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${m['playerName']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('${m['statLabel']} ${f.line(m['line'] as num)} · ${m['picks']} picks · #${m['marketId']}', style: T.small),
                      Text('${f.cap(m['status'] as String)} · locks ${f.dayTime(DateTime.parse(m['lockAt'] as String))}', style: T.small),
                    ]),
                  ),
                  if (m['status'] == 'open') TextButton(onPressed: () => _lock(m), child: const Text('Lock', style: TextStyle(color: C.dim))),
                  TextButton(onPressed: () => _settle(m), child: const Text('Settle', style: TextStyle(color: C.green))),
                ]),
              ),
          ]);
        },
      ),
    ]);
  }
}
