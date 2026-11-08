import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../card/card_spec.dart';
import '../ui/share_object.dart';
import '../card/sport_card.dart';
import '../core/api.dart';
import '../core/format.dart' as f;
import '../core/theme.dart';
import '../state/pick_queue.dart';
import '../state/session.dart';
import '../ui/widgets.dart';

class PicksScreen extends ConsumerStatefulWidget {
  const PicksScreen({super.key});

  @override
  ConsumerState<PicksScreen> createState() => _PicksScreenState();
}

class _PicksScreenState extends ConsumerState<PicksScreen> {
  int _tab = 0;
  final _items = <Map<String, dynamic>>[];
  Map<String, dynamic>? _summary;
  String? _cursor;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _items.clear();
        _cursor = null;
      }
    });
    try {
      final status = _tab == 0 ? 'pending' : 'settled';
      final r = await api.get('/me/picks?status=$status${_cursor != null ? '&cursor=${Uri.encodeComponent(_cursor!)}' : ''}');
      setState(() {
        _items.addAll((r['items'] as List).cast<Map<String, dynamic>>());
        _cursor = r['nextCursor'] as String?;
        _summary = (r['summary'] as Map).cast<String, dynamic>();
      });
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Refetch whenever a receipt lands or results are graded.
    ref.listen(summaryProvider, (prev, next) {
      if (prev?.pending != next.pending || prev?.unrevealed != next.unrevealed || prev?.balance != next.balance) {
        _load(reset: true);
      }
    });
    final queued = ref.watch(pickQueueProvider);
    final s = _summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: C.bg,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: UnderTabs(
              labels: const ['Pending', 'Settled'],
              counts: [((s?['pendingCount'] as num?)?.toInt() ?? 0) + queued.length, (s?['settledCount'] as num?)?.toInt() ?? 0],
              index: _tab,
              onChanged: (i) {
                setState(() => _tab = i);
                _load(reset: true);
              },
            ),
          ),
        ),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              const Positioned.fill(child: PineBackdrop()),
              RefreshIndicator(
                color: C.green,
                onRefresh: () => _load(reset: true),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  children: [
                    if (_tab == 0 && s != null && (s['pendingCount'] as num) > 0) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: Labeled('Locked entries', '${s['pendingCount']}')),
                          Expanded(child: Labeled('Wagered', f.coins(s['wagered'] as num))),
                          Expanded(child: Labeled('Possible return', f.coins(s['possibleReturn'] as num))),
                        ],
                      ),
                    ],
                    if (_tab == 0)
                      for (final q in queued) _queuedRow(q),
                    if (_error != null) ErrorText(_error!, onRetry: () => _load(reset: true)),
                    if (_items.isEmpty && !_loading && _error == null && (_tab == 1 || queued.isEmpty))
                      EmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: _tab == 0 ? 'No pending picks' : 'No settled picks yet',
                        body: _tab == 0 ? 'Submit a pick from Play to see it here.' : 'Results appear here after games end.',
                        action: PrimaryButton('Make another call', onPressed: () => context.go('/play')),
                      ),
                    for (final e in _items) _EntryRow(e),
                    if (_loading) const Loading(),
                    if (_cursor != null && !_loading) GhostButton('Load more', color: C.green, onPressed: _load),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _queuedRow(PendingIntent q) => Container(
    padding: const EdgeInsets.symmetric(vertical: 18),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: C.line)),
    ),
    child: Row(
      children: [
        const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: C.dim)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(q.label, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(switch (q.state) {
                'holding' => 'Sending in a moment · Undo available',
                'checking' => 'Checking status… no coins charged twice',
                _ => 'Sending…',
              }, style: T.small),
            ],
          ),
        ),
      ],
    ),
  );
}

class _EntryRow extends StatelessWidget {
  const _EntryRow(this.e);
  final Map<String, dynamic> e;

  String get _stageText => switch (e['stage']) {
    'live' => 'Game in progress',
    'final' => switch (e['status']) {
      'won' => 'Won',
      'lost' => 'Lost',
      'void' => 'Void · wager returned',
      _ => 'Final',
    },
    _ => 'Locked · awaiting result',
  };

  @override
  Widget build(BuildContext context) {
    final legs = (e['legs'] as List).cast<Map<String, dynamic>>();
    final stake = (e['stake'] as num).toInt();
    final status = e['status'] as String;
    final settled = status != 'pending';
    final credited = (e['credited'] as num).toInt();
    if (e['kind'] == 'parlay') {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: C.line)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.copy_all_outlined, color: C.under, size: 26),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${legs.length}-leg parlay', style: T.h3.copyWith(fontSize: 17)),
                      Text(
                        settled ? _stageText : '${f.cap(e['stage'] == 'live' ? 'in progress' : 'locked')} · awaiting results',
                        style: T.small,
                      ),
                    ],
                  ),
                ),
                Text(
                  '${e['multiplier'] ?? ''}×',
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: C.under),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (settled)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => shareObject(context, source: {'kind': 'pick', 'entryId': e['entryId'] ?? e['id']}),
                  icon: const Icon(Icons.ios_share, size: 16),
                  label: const Text('Share pick'),
                ),
              ),
            for (final l in legs) _legRow(l),
            const Hr(v: 10),
            _money(settled, stake, credited, (e['potentialReturn'] as num).toInt(), every: true),
          ],
        ),
      );
    }
    final l = legs.first;
    final spec = l['card'] == null ? null : CardSpec.fromJson((l['card'] as Map).cast<String, dynamic>());
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: C.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (spec != null) JerseyIcon(spec: spec, size: 44),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(spec?.fullName ?? 'Player', style: T.h3.copyWith(fontSize: 17)),
                    if (spec != null) Text('${spec.teamAbbr} · ${spec.leagueLabel}', style: T.small),
                  ],
                ),
              ),
              _resultIcon(l['result'] as String? ?? (settled ? status : null)),
            ],
          ),
          const SizedBox(height: 10),
          SideText(
            side: l['side'] as String,
            line: (l['line'] as num).toDouble(),
            rest: l['statLabel'] as String,
            label: l['sideLabel'] as String?,
          ),
          if (l['resultValue'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Final: ${f.line(l['resultValue'] as num)}', style: T.small),
            ),
          const SizedBox(height: 10),
          StageBar(stage: e['stage'] as String),
          const SizedBox(height: 10),
          Text(_stageText, style: T.dim),
          const SizedBox(height: 8),
          _money(settled, stake, credited, (e['potentialReturn'] as num).toInt()),
          if (settled)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => shareObject(context, source: {'kind': 'pick', 'entryId': e['entryId'] ?? e['id']}),
                icon: const Icon(Icons.ios_share, size: 16),
                label: const Text('Share pick'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _money(bool settled, int stake, int credited, int potential, {bool every = false}) {
    if (settled) {
      final net = credited - stake;
      return Row(
        children: [
          Text(stake == 0 ? 'Free pick' : 'Wager ${f.coins(stake)}', style: T.dim),
          const Spacer(),
          Text(
            'Returned ${f.coins(credited)} · ${f.signed(net)}',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: net > 0
                  ? C.green
                  : net < 0
                  ? C.danger
                  : C.dim,
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Text(stake == 0 ? (every ? 'Free entry' : 'Free pick') : 'Wager ${f.coins(stake)}', style: T.dim),
        const Spacer(),
        Text(every ? 'Return if every leg hits: ${f.coins(potential)} coins' : 'If right: ${f.coins(potential)} coins', style: T.dim),
      ],
    );
  }

  Widget _legRow(Map<String, dynamic> l) {
    final spec = l['card'] == null ? null : CardSpec.fromJson((l['card'] as Map).cast<String, dynamic>());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          if (spec != null) JerseyIcon(spec: spec, size: 34),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(spec?.fullName ?? 'Player', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                SideText(
                  side: l['side'] as String,
                  line: (l['line'] as num).toDouble(),
                  rest: l['statLabel'] as String,
                  size: 14,
                  label: l['sideLabel'] as String?,
                ),
              ],
            ),
          ),
          _resultIcon(l['result'] as String?),
        ],
      ),
    );
  }

  Widget _resultIcon(String? result) {
    final (icon, color) = switch (result) {
      'win' || 'won' => (Icons.check, C.green),
      'loss' || 'lost' => (Icons.close, C.danger),
      'push' || 'void' => (Icons.remove, C.dim),
      _ => (Icons.check, const Color(0xFF8FB08A)),
    };
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.8), width: 1.5),
      ),
      child: Icon(icon, size: 16, color: color),
    );
  }
}

/// "Results ready" sheet. Opening it marks the shown entries as revealed.
Future<void> showResultsSheet(BuildContext context, WidgetRef ref) async {
  final r = await api.raw('GET', '/me/results/unrevealed');
  if (!r.ok || !context.mounted) return;
  final d = r.map;
  final entries = (d['entries'] as List).cast<Map<String, dynamic>>();
  if (entries.isEmpty) return;
  final newCards = (d['newCards'] as List).map((e) => CardSpec.fromJson((e as Map).cast<String, dynamic>())).toList();
  final returned = (d['coinsReturned'] as num).toInt();
  final change = (d['roundChange'] as num).toInt();
  final goTo = await showSheet<String>(
    context,
    (ctx) => Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: C.green, width: 1.5),
          ),
          child: const Icon(Icons.check, color: C.green),
        ),
        const SizedBox(height: 14),
        Text('${d['won']} of ${d['total']} entries won', style: T.dim),
        const SizedBox(height: 6),
        const Text('Results ready', style: T.h1),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final e in entries)
              Container(
                width: 44,
                height: 34,
                decoration: BoxDecoration(
                  color: e['status'] == 'won' ? const Color(0xFF214A33) : const Color(0xFF2A3B3D),
                  border: Border.all(color: e['status'] == 'won' ? C.green.withValues(alpha: 0.6) : C.line),
                ),
                child: Icon(
                  e['status'] == 'won'
                      ? Icons.check
                      : e['status'] == 'void'
                      ? Icons.remove
                      : Icons.close,
                  size: 18,
                  color: e['status'] == 'won' ? C.green : C.dim,
                ),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          '+${f.coins(returned)}',
          style: const TextStyle(fontSize: 60, fontWeight: FontWeight.w800, color: C.green),
        ),
        const Text('Coins returned', style: T.dim),
        const Hr(),
        Row(
          children: [
            const Text('Round change', style: T.body),
            const Spacer(),
            Text(
              '${f.signed(change)} coins',
              style: TextStyle(fontWeight: FontWeight.w800, color: change >= 0 ? C.green : C.danger, fontSize: 16),
            ),
          ],
        ),
        if (newCards.isNotEmpty) ...[
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 40.0 + 30 * (newCards.length.clamp(1, 3) - 1),
                height: 46,
                child: Stack(
                  children: [
                    for (final (i, c) in newCards.take(3).indexed)
                      Positioned(
                        left: i * 30.0,
                        child: JerseyIcon(spec: c, size: 40),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Text(
                '${newCards.length} new ${newCards.length == 1 ? 'card' : 'cards'} unlocked',
                style: const TextStyle(color: Color(0xFFD5F5C8), fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ],
          ),
        ],
        const SizedBox(height: 22),
        if (newCards.isNotEmpty)
          PrimaryButton('View my cards', focusRing: true, onPressed: () => Navigator.pop(ctx, '/profile?tab=1'))
        else
          PrimaryButton('See results', focusRing: true, onPressed: () => Navigator.pop(ctx, '/picks')),
        const SizedBox(height: 6),
        GhostButton('Close', color: C.dim, onPressed: () => Navigator.pop(ctx)),
      ],
    ),
  );
  await api.raw('POST', '/me/results/reveal', body: {'entryIds': entries.map((e) => e['entryId']).toList()});
  ref.read(summaryProvider.notifier).refresh();
  if (goTo != null && context.mounted) context.go(goTo);
}
