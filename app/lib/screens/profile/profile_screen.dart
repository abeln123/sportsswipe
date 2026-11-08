import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../card/card_spec.dart';
import '../../card/sport_card.dart';
import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../core/theme.dart';
import '../../state/pick_queue.dart';
import '../../state/session.dart';
import '../../ui/widgets.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key, this.initialTab = 0});
  final int initialTab;

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  late int _tab = widget.initialTab;

  @override
  void didUpdateWidget(covariant ProfileScreen old) {
    super.didUpdateWidget(old);
    if (old.initialTab != widget.initialTab) _tab = widget.initialTab;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 32), children: [
      const SizedBox(height: 6),
      UnderTabs(labels: const ['Profile', 'Collection', 'Store'], index: _tab, onChanged: (i) => setState(() => _tab = i)),
      switch (_tab) {
        0 => const _ProfileTab(),
        1 => _CollectionTab(onStore: () => setState(() => _tab = 2)),
        _ => const _StoreTab(),
      },
    ]);
  }
}

class StatsBlock extends StatelessWidget {
  const StatsBlock(this.s, {super.key});
  final Map<String, dynamic> s;

  @override
  Widget build(BuildContext context) {
    final wc = (s['weeklyContest'] as Map).cast<String, dynamic>();
    final best = (s['bestCard'] as Map?)?.cast<String, dynamic>();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: _stat('${s['won']}–${s['lost']}', 'Entries W–L')),
        Expanded(child: _stat(s['winRate'] == null ? '—' : '${s['winRate']}%', 'Win rate')),
        Expanded(child: _stat(f.coins(s['coinsReturned'] as num), 'Coins returned')),
      ]),
      const SizedBox(height: 16),
      Text(
        'Single picks and parlays count as one entry each. Returns include winning stakes. '
        'Net settled coins: ${f.signed(s['netSettled'] as num)}. Cash awards: \$0 · No live payouts.',
        style: T.dim,
      ),
      const Hr(v: 22),
      const Text('Rankings', style: T.h3),
      const SizedBox(height: 12),
      Row(children: [
        const Text('Weekly contest', style: T.body),
        const Spacer(),
        Text('${wc['points']} / ${wc['maxPoints']} points', style: const TextStyle(fontWeight: FontWeight.w800)),
      ]),
      const SizedBox(height: 8),
      Text(wc['rank'] == null ? 'No rank yet this week. Points come from graded contest days.' : 'Rank #${wc['rank']} this week.',
          style: T.dim),
      if (best != null && best['card'] != null) ...[
        const Hr(v: 22),
        const Text('Top card', style: T.h3),
        const SizedBox(height: 12),
        Row(children: [
          JerseyIcon(spec: CardSpec.fromJson((best['card'] as Map).cast<String, dynamic>()), size: 44),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((best['card'] as Map)['fullName'] as String, style: T.h3),
              Text('${f.cap((best['mastery'] as Map)['tier'] as String)} · ${(best['mastery'] as Map)['count']} correct calls', style: T.small),
            ]),
          ),
        ]),
      ],
    ]);
  }

  Widget _stat(String v, String label) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(v, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(label, style: T.small),
      ]);
}

class _ProfileTab extends ConsumerStatefulWidget {
  const _ProfileTab();

  @override
  ConsumerState<_ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends ConsumerState<_ProfileTab> {
  Future<Map<String, dynamic>>? _stats;
  String? _forUser;

  Future<void> _edit(Me me) async {
    final name = TextEditingController(text: me.displayName);
    final bio = TextEditingController(text: me.bio);
    final teams = ((await api.get('/teams'))['teams'] as List).cast<Map<String, dynamic>>();
    int? team = me.favoriteTeamId;
    String vis = me.visibility;
    if (!mounted) return;
    final ok = await showSheet<bool>(context, (ctx) => StatefulBuilder(
          builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Edit profile', style: T.h1),
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Display name'), maxLength: 40),
            TextField(controller: bio, decoration: const InputDecoration(labelText: 'Bio'), maxLength: 160, maxLines: 2),
            const SizedBox(height: 8),
            DropdownButtonFormField<int?>(
              initialValue: team,
              isExpanded: true,
              dropdownColor: C.sheet,
              decoration: const InputDecoration(labelText: 'Favorite team'),
              items: [
                const DropdownMenuItem(value: null, child: Text('None')),
                for (final t in teams)
                  DropdownMenuItem(value: (t['teamId'] as num).toInt(), child: Text('${t['name']} · ${(t['league'] as String).toUpperCase()}')),
              ],
              onChanged: (v) => set(() => team = v),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: vis,
              dropdownColor: C.sheet,
              decoration: const InputDecoration(labelText: 'Who can see my stats'),
              items: const [
                DropdownMenuItem(value: 'public', child: Text('Everyone')),
                DropdownMenuItem(value: 'friends', child: Text('Friends')),
                DropdownMenuItem(value: 'private', child: Text('Only me')),
              ],
              onChanged: (v) => set(() => vis = v ?? vis),
            ),
            const SizedBox(height: 20),
            PrimaryButton('Save', onPressed: () => Navigator.pop(ctx, true)),
            Center(child: GhostButton('Cancel', color: C.dim, onPressed: () => Navigator.pop(ctx, false))),
          ]),
        ));
    if (ok != true) return;
    try {
      await api.patch('/me/profile', {'displayName': name.text, 'bio': bio.text, 'favoriteTeamId': team, 'visibility': vis});
      await ref.read(sessionProvider.notifier).refreshMe();
      if (mounted) toast(context, 'Profile saved.');
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message, ok: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionProvider).value;
    if (me == null) return const Loading();
    if (_forUser != me.id) {
      _forUser = me.id;
      _stats = api.get('/profiles/${me.id}/stats');
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 22),
      Row(children: [
        InitialsBadge(me.initials, color: C.green, size: 22),
        const SizedBox(width: 18),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(me.displayName, style: T.h1),
            const SizedBox(height: 4),
            Text('${me.handleTag} · ${f.cap(me.visibility)} profile', style: T.small),
          ]),
        ),
      ]),
      const SizedBox(height: 14),
      Text(me.bio.isEmpty ? 'Add a short bio and your favorite team.' : me.bio, style: T.body),
      InkWell(
        onTap: () => _edit(me),
        child: const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Edit profile', style: TextStyle(fontWeight: FontWeight.w700))),
      ),
      const SizedBox(height: 18),
      FutureBuilder(
        future: _stats,
        builder: (context, snap) {
          if (snap.hasError) return ErrorText(snap.error!);
          if (!snap.hasData) return const Loading();
          return StatsBlock(snap.data!);
        },
      ),
      const Hr(v: 22),
      if (me.isAdmin) ArrowLink('Demo controls (admin)', color: C.under, onTap: () => context.go('/profile/admin')),
      GhostButton('Log out', color: C.dim, onPressed: () async {
        if (ref.read(pickQueueProvider).isNotEmpty) {
          toast(context, 'Saving picks before logging out…', duration: const Duration(seconds: 20));
          final saved = await ref.read(pickQueueProvider.notifier).drain();
          if (!context.mounted) return;
          if (!saved) {
            toast(context, 'Some picks haven\'t reached the server yet. Check the connection and try again.', ok: false);
            return;
          }
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
        }
        await ref.read(sessionProvider.notifier).logout();
      }),
    ]);
  }
}

class _CollectionTab extends StatefulWidget {
  const _CollectionTab({required this.onStore});
  final VoidCallback onStore;

  @override
  State<_CollectionTab> createState() => _CollectionTabState();
}

class _CollectionTabState extends State<_CollectionTab> {
  late Future<Map<String, dynamic>> _data = api.get('/me/collection');

  Future<void> _equip(Map<String, dynamic> c, List<Map<String, dynamic>> unassigned) async {
    final spec = CardSpec.fromJson((c['card'] as Map).cast<String, dynamic>());
    final current = c['finish'] as String;
    final options = ['base', ...unassigned.map((u) => u['finish'] as String)];
    if (current != 'base' && !options.contains(current)) options.add(current);
    final choice = await showSheet<String>(context, (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Finish for ${spec.fullName}', style: T.h2),
          const SizedBox(height: 6),
          const Text('Finishes change appearance only. Mastery is earned separately.', style: T.dim),
          const SizedBox(height: 12),
          for (final o in options)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(f.cap(o)),
              subtitle: Text(o == 'base' ? 'Default chrome' : 'Owned finish', style: T.small),
              trailing: o == current ? const Icon(Icons.check, color: C.green) : null,
              onTap: () => Navigator.pop(ctx, o),
            ),
          if (unassigned.isEmpty) ArrowLink('Buy finishes in the store', onTap: () {
            Navigator.pop(ctx);
            widget.onStore();
          }),
        ]));
    if (choice == null || choice == current) return;
    try {
      await api.post('/me/collection/${spec.playerId}/equip', {'finish': choice});
      setState(() => _data = api.get('/me/collection'));
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message, ok: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _data,
      builder: (context, snap) {
        if (snap.hasError) return ErrorText(snap.error!);
        if (!snap.hasData) return const Loading();
        final d = snap.data!;
        final cards = (d['cards'] as List).cast<Map<String, dynamic>>();
        final unassigned = (d['unassignedFinishes'] as List).cast<Map<String, dynamic>>();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const PageTitle('Collection', 'Player cards and earned mastery'),
          InkWell(
            onTap: widget.onStore,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
              child: const Row(children: [
                Text('Card store', style: TextStyle(fontWeight: FontWeight.w700)),
                Spacer(),
                Text('Cosmetic finishes', style: T.dim),
              ]),
            ),
          ),
          const SizedBox(height: 22),
          Row(children: [
            Text((d['series'] as String).toUpperCase(), style: T.label),
            const Spacer(),
            Text.rich(TextSpan(children: [
              TextSpan(text: '${d['collected']}', style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: C.green)),
              TextSpan(text: ' / ${d['total']}', style: const TextStyle(fontSize: 18, color: C.dim)),
            ])),
          ]),
          const SizedBox(height: 6),
          const Text('Player cards collected', style: T.h3),
          const SizedBox(height: 8),
          const Text(
            'Earn a player\'s Base card with your first correct call. Keep getting that player right to reach Bronze, '
            'Silver, Gold, and Diamond. Store finishes change appearance only. Cards never redeem for money.',
            style: T.dim,
          ),
          Container(height: 2, color: C.green, margin: const EdgeInsets.symmetric(vertical: 18)),
          if (cards.isEmpty)
            const EmptyState(icon: Icons.style_outlined, title: 'No cards yet', body: 'Your first correct call on a player earns their card.'),
          LayoutBuilder(builder: (context, c) {
            final w = math.min((c.maxWidth - 12) / 2, 200.0);
            return Wrap(spacing: 12, runSpacing: 12, children: [
              for (final card in cards)
                GestureDetector(
                  onTap: () => _equip(card, unassigned),
                  child: CardTile(
                    spec: CardSpec.fromJson((card['card'] as Map).cast<String, dynamic>()),
                    width: w,
                    finish: card['finish'] as String,
                    tierLabel: card['finish'] == 'base' ? 'Base' : f.cap(card['finish'] as String),
                    progress: _progress(Mastery.fromJson((card['mastery'] as Map).cast<String, dynamic>())),
                  ),
                ),
            ]);
          }),
          if (unassigned.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Unapplied finishes: ${unassigned.map((u) => '${u['count']} ${u['finish']}').join(', ')}. Tap a card to apply.', style: T.small),
          ],
        ]);
      },
    );
  }

  String _progress(Mastery m) => m.nextTier == null
      ? 'Mastery: ${f.cap(m.tier)} · ${m.count} correct'
      : 'Mastery: ${f.cap(m.displayTier)} · ${m.count} / ${m.nextAt} to ${f.cap(m.nextTier!)}';
}

class _StoreTab extends ConsumerStatefulWidget {
  const _StoreTab();

  @override
  ConsumerState<_StoreTab> createState() => _StoreTabState();
}

class _StoreTabState extends ConsumerState<_StoreTab> {
  late Future<Map<String, dynamic>> _data = api.get('/store/skus');
  String? _busy;

  static const _swatch = {
    'bronze': [Color(0xFFE7B48F), Color(0xFFA8643C)],
    'silver': [Color(0xFFFFFFFF), Color(0xFFB9C2CC)],
    'gold': [Color(0xFFFFE8A3), Color(0xFFC9972B)],
    'diamond': [Color(0xFFC9F6FF), Color(0xFFE5CCFF)],
  };

  Future<void> _buy(String finish, int price) async {
    final ok = await showSheet<bool>(context, (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Buy ${f.cap(finish)} finish', style: T.h1),
          const SizedBox(height: 8),
          Text('${f.coins(price)} coins. Apply it to any card you have earned. Cosmetic only; no cash value.', style: T.dim),
          const SizedBox(height: 20),
          PrimaryButton('Buy · ${f.coins(price)} coins', onPressed: () => Navigator.pop(ctx, true)),
          Center(child: GhostButton('Cancel', color: C.dim, onPressed: () => Navigator.pop(ctx, false))),
        ]));
    if (ok != true) return;
    setState(() => _busy = finish);
    final commandId = const Uuid().v4();
    var r = await api.raw('POST', '/store/purchases', body: {'commandId': commandId, 'finish': finish});
    if (r.status == 0) {
      r = await api.raw('POST', '/store/purchases', body: {'commandId': commandId, 'finish': finish});
    }
    if (!mounted) return;
    setState(() {
      _busy = null;
      _data = api.get('/store/skus');
    });
    if (r.ok) {
      ref.read(summaryProvider.notifier).applyBalance((r.map['balance'] as num).toInt());
      toast(context, '${f.cap(finish)} finish added. Apply it from Collection.');
    } else {
      toast(context, r.map['message']?.toString() ?? 'Purchase failed.', ok: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _data,
      builder: (context, snap) {
        if (snap.hasError) return ErrorText(snap.error!);
        if (!snap.hasData) return const Loading();
        final d = snap.data!;
        final balance = (d['balance'] as num).toInt();
        final skus = (d['skus'] as List).cast<Map<String, dynamic>>();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const PageTitle('Card store', 'Cosmetic finishes for your collection'),
          const Text('Cosmetic finishes · No cash value', style: T.dim),
          const SizedBox(height: 18),
          Row(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Your free coins', style: T.small),
              Text(f.coins(balance), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: C.green)),
            ]),
            const Spacer(),
            const Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('Earned mastery', style: T.small),
              Text('Never sold', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            ]),
          ]),
          const SizedBox(height: 18),
          for (final s in skus)
            InkWell(
              onTap: _busy == null && balance >= (s['price'] as num) ? () => _buy(s['finish'] as String, (s['price'] as num).toInt()) : null,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
                child: Row(children: [
                  Container(
                    width: 54,
                    height: 66,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      gradient: LinearGradient(colors: _swatch[s['finish']] ?? const [Colors.white, Colors.grey]),
                    ),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Text('SS', style: TextStyle(color: C.ink, fontWeight: FontWeight.w900, fontSize: 18)),
                      Text((s['finish'] as String).toUpperCase(), style: const TextStyle(color: C.ink, fontSize: 7, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(f.cap(s['finish'] as String), style: T.h3.copyWith(fontSize: 18)),
                      const Text('Cosmetic · choose a player later', style: T.small),
                    ]),
                  ),
                  if (_busy == s['finish'])
                    const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: C.green))
                  else
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(f.coins(s['price'] as num),
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: balance >= (s['price'] as num) ? C.text : C.faint)),
                      const Text('coins', style: T.small),
                    ]),
                ]),
              ),
            ),
          const SizedBox(height: 14),
          const Text(
            'Finishes change appearance, not mastery. Earn each tier with correct calls: 20 for Bronze, '
            '80 for Silver, 200 for Gold and 400 for Diamond. Coins have no cash value.',
            style: T.small,
          ),
        ]);
      },
    );
  }
}
