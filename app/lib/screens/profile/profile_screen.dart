import 'package:url_launcher/url_launcher.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../card/card_spec.dart';
import '../../ui/share_object.dart';
import '../../card/sport_card.dart';
import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../core/theme.dart';
import '../../state/pick_queue.dart';
import '../../state/session.dart';
import '../../ui/shell.dart' show CoinGlyph;
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: C.bg,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: UnderTabs(
              labels: const ['Profile', 'Collection', 'Store'],
              index: _tab,
              onChanged: (i) => setState(() => _tab = i),
            ),
          ),
        ),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              const Positioned.fill(child: PineBackdrop()),
              ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                children: [
                  switch (_tab) {
                    0 => const _ProfileTab(),
                    1 => _CollectionTab(onStore: () => setState(() => _tab = 2)),
                    _ => const _StoreTab(),
                  },
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class StatsBlock extends StatelessWidget {
  const StatsBlock(this.s, {super.key, this.topCards});
  final Map<String, dynamic> s;
  final List<Map<String, dynamic>>? topCards;

  List<Map<String, dynamic>> _resolveTopCards() {
    if (topCards != null && topCards!.isNotEmpty) {
      return topCards!.take(3).toList();
    }
    final rawTop = s['topCards'];
    if (rawTop is List && rawTop.isNotEmpty) {
      return rawTop
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .where((e) => e['card'] != null)
          .take(3)
          .toList();
    }
    final best = (s['bestCard'] as Map?)?.cast<String, dynamic>();
    if (best != null && best['card'] != null) {
      return [best];
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final wc = (s['weeklyContest'] as Map).cast<String, dynamic>();
    final cards = _resolveTopCards();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _stat('${s['won']}–${s['lost']}', 'Entries W–L')),
            Expanded(child: _stat(s['winRate'] == null ? '—' : '${s['winRate']}%', 'Win rate')),
            Expanded(child: _stat(f.coins(s['coinsReturned'] as num), 'Coins returned')),
          ],
        ),
        const Hr(v: 22),
        const Text('Rankings', style: T.h3),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('Weekly contest', style: T.body),
            const Spacer(),
            Text('${wc['points']} / ${wc['maxPoints']} points', style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          wc['rank'] == null ? 'No rank yet this week.' : 'Rank #${wc['rank']} this week.',
          style: T.dim,
        ),
        if (cards.isNotEmpty) ...[
          const Hr(v: 22),
          Row(
            children: [
              const Text('Top cards', style: T.h3),
              const Spacer(),
              Text('Top ${cards.length}', style: T.small),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(
                  child: i < cards.length
                      ? _TopCardSlot(data: cards[i], rank: i + 1)
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _stat(String v, String label) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(v, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
      const SizedBox(height: 6),
      Text(label, style: T.small),
    ],
  );
}

class _TopCardSlot extends StatelessWidget {
  const _TopCardSlot({required this.data, required this.rank});
  final Map<String, dynamic> data;
  final int rank;

  @override
  Widget build(BuildContext context) {
    final spec = CardSpec.fromJson((data['card'] as Map).cast<String, dynamic>());
    final mastery = (data['mastery'] as Map).cast<String, dynamic>();
    final tier = (mastery['tier'] as String?) ?? 'base';
    final count = (mastery['count'] as num?)?.toInt() ?? 0;
    final equipped = (data['finish'] as String?) ?? 'base';
    final finish = Finish.collectionFinish(equipped, tier);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.topCenter,
      child: CardTile(
        spec: spec,
        width: 165,
        finish: finish,
        tierLabel: '#$rank · ${f.cap(tier)}',
        progress: '$count correct ${count == 1 ? 'call' : 'calls'}',
      ),
    );
  }
}

class _ProfileTab extends ConsumerStatefulWidget {
  const _ProfileTab();

  @override
  ConsumerState<_ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends ConsumerState<_ProfileTab> {
  Future<(Map<String, dynamic>, List<Map<String, dynamic>>)>? _stats;
  String? _forUser;

  Future<(Map<String, dynamic>, List<Map<String, dynamic>>)> _loadProfileData(String userId) async {
    final statsFuture = api.get('/profiles/$userId/stats');
    final colFuture = api.get('/me/collection').catchError((_) => <String, dynamic>{});
    final stats = await statsFuture;
    final col = await colFuture;
    final rawCards = (col['cards'] as List?)?.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() ?? <Map<String, dynamic>>[];
    rawCards.sort((a, b) {
      final ca = ((a['mastery'] as Map?)?['count'] as num?)?.toInt() ?? 0;
      final cb = ((b['mastery'] as Map?)?['count'] as num?)?.toInt() ?? 0;
      return cb.compareTo(ca);
    });
    return (stats, rawCards.take(3).toList());
  }

  Future<void> _edit(Me me) async {
    final name = TextEditingController(text: me.displayName);
    final bio = TextEditingController(text: me.bio);
    final teams = ((await api.get('/teams'))['teams'] as List).cast<Map<String, dynamic>>();
    int? team = me.favoriteTeamId;
    String vis = me.visibility;
    if (!mounted) return;
    final ok = await showSheet<bool>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, set) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Edit profile', style: T.h1),
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Display name'),
              maxLength: 40,
            ),
            TextField(
              controller: bio,
              decoration: const InputDecoration(labelText: 'Bio'),
              maxLength: 160,
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int?>(
              initialValue: team,
              isExpanded: true,
              dropdownColor: C.sheet,
              decoration: const InputDecoration(labelText: 'Favorite team'),
              items: [
                const DropdownMenuItem(value: null, child: Text('None')),
                for (final t in teams)
                  DropdownMenuItem(
                    value: (t['teamId'] as num).toInt(),
                    child: Text('${t['name']} · ${(t['league'] as String).toUpperCase()}'),
                  ),
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
            Center(
              child: GhostButton('Cancel', color: C.dim, onPressed: () => Navigator.pop(ctx, false)),
            ),
          ],
        ),
      ),
    );
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
      _stats = _loadProfileData(me.id);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 22),
        Row(
          children: [
            InitialsBadge(me.initials, color: C.green, size: 22),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(me.displayName, style: T.h1),
                  const SizedBox(height: 4),
                  Text('${me.handleTag} · ${f.cap(me.visibility)} profile', style: T.small),
                ],
              ),
            ),
          ],
        ),
        if (me.bio.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(me.bio, style: T.body),
        ],
        InkWell(
          onTap: () => _edit(me),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text('Edit profile', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: 18),
        FutureBuilder(
          future: _stats,
          builder: (context, snap) {
            if (snap.hasError) return ErrorText(snap.error!);
            if (!snap.hasData) return const Loading();
            return StatsBlock(snap.data!.$1, topCards: snap.data!.$2);
          },
        ),
        const Hr(v: 22),
        if (me.isAdmin) ArrowLink('Demo controls (admin)', color: C.under, onTap: () => context.go('/profile/admin')),
        GhostButton(
          'Log out',
          color: C.dim,
          onPressed: () async {
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
          },
        ),
      ],
    );
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

  Future<String?> _equip(Map<String, dynamic> c, List<Map<String, dynamic>> unassigned) async {
    final spec = CardSpec.fromJson((c['card'] as Map).cast<String, dynamic>());
    final current = c['finish'] as String;
    final options = ['base', ...unassigned.map((u) => u['finish'] as String)];
    if (current != 'base' && !options.contains(current)) options.add(current);
    final choice = await showSheet<String>(
      context,
      (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(spec.fullName, style: T.h2),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              shareObject(context, source: {'kind': 'card', 'playerId': spec.playerId});
            },
            icon: const Icon(Icons.ios_share, size: 16),
            label: const Text('Share earned card'),
          ),
          if ((c['mastery']['count'] as num? ?? 0) >= 400)
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                context.go('/profile/sell/${spec.playerId}?presentation=${c['presentation'] == true}');
              },
              icon: const Icon(Icons.sell_outlined, size: 18),
              label: Text(c['presentation'] == true ? 'Sell presentation Diamond' : 'Sell Diamond edition (devnet)'),
            ),
          if (c['presentation'] == true) const Text('ADMIN PRESENTATION · 400/400 demo grant', style: T.small),
          const SizedBox(height: 8),
          const Text('Card finish', style: T.label),
          const SizedBox(height: 8),
          for (final o in options)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(o == 'base' ? 'Earned ${f.cap(c['mastery']['tier'] as String)}' : f.cap(o)),
              subtitle: Text(o == 'base' ? 'Follow your mastery tier' : 'Owned finish', style: T.small),
              trailing: o == current ? const Icon(Icons.check, color: C.green) : null,
              onTap: () => Navigator.pop(ctx, o),
            ),
          if (unassigned.isEmpty)
            ArrowLink(
              'Buy finishes in the store',
              onTap: () {
                Navigator.pop(ctx);
                Navigator.pop(context);
                widget.onStore();
              },
            ),
        ],
      ),
    );
    if (choice == null || choice == current) return null;
    try {
      await api.post('/me/collection/${spec.playerId}/equip', {'finish': choice});
      setState(() {
        _data = api.get('/me/collection');
      });
      return choice;
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message, ok: false);
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _data,
      builder: (context, snap) {
        if (snap.hasError) return ErrorText(snap.error!);
        if (!snap.hasData) return const SizedBox(height: 360, child: Loading());
        final d = snap.data!;
        final cards = (d['cards'] as List).cast<Map<String, dynamic>>();
        final unassigned = (d['unassignedFinishes'] as List).cast<Map<String, dynamic>>();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const PageTitle('Collection'),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: C.line)),
              ),
              child: Row(
                children: [
                  const Expanded(child: Text('DIAMOND EDITIONS · DEVNET', style: T.label)),
                  TextButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Open devnet collection'),
                    onPressed: () async {
                      try {
                        final r = await api.post('/collectibles/handoff', {});
                        if (!context.mounted) return;
                        final opened = await launchUrl(Uri.parse(r['url'] as String), mode: LaunchMode.externalApplication);
                        if (!opened && context.mounted) toast(context, 'Could not open the devnet collection.', ok: false);
                      } on ApiException catch (e) {
                        if (context.mounted) toast(context, e.message, ok: false);
                      }
                    },
                  ),
                ],
              ),
            ),

            InkWell(
              onTap: widget.onStore,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: C.line)),
                ),
                child: const Row(
                  children: [
                    Text('Card store', style: TextStyle(fontWeight: FontWeight.w700)),
                    Spacer(),
                    Text('Cosmetic finishes', style: T.dim),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Text((d['series'] as String).toUpperCase(), style: T.label),
                const Spacer(),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${d['collected']}',
                        style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: C.green),
                      ),
                      TextSpan(
                        text: ' / ${d['total']}',
                        style: const TextStyle(fontSize: 18, color: C.dim),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text('Player cards collected', style: T.h3),
            Container(height: 2, color: C.green, margin: const EdgeInsets.symmetric(vertical: 18)),
            if (cards.isEmpty)
              const EmptyState(
                icon: Icons.style_outlined,
                title: 'No cards yet',
                body: 'Your first correct call on a player earns their card.',
              ),
            LayoutBuilder(
              builder: (context, c) {
                final w = math.min((c.maxWidth - 12) / 2, 200.0);
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final card in cards)
                      GestureDetector(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            fullscreenDialog: true,
                            builder: (_) => CollectionCardView(data: card, onCustomize: () => _equip(card, unassigned)),
                          ),
                        ),
                        child: CardTile(
                          spec: CardSpec.fromJson((card['card'] as Map).cast<String, dynamic>()),
                          width: w,
                          finish: Finish.collectionFinish(card['finish'] as String, card['mastery']['tier'] as String),
                          tierLabel: f.cap(card['mastery']['tier'] as String),
                          progress: _progress(Mastery.fromJson((card['mastery'] as Map).cast<String, dynamic>())),
                        ),
                      ),
                  ],
                );
              },
            ),
            if (unassigned.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Unapplied finishes: ${unassigned.map((u) => '${u['count']} ${u['finish']}').join(', ')}. Tap a card to apply.',
                style: T.small,
              ),
            ],
          ],
        );
      },
    );
  }

  String _progress(Mastery m) => m.nextTier == null
      ? 'Mastery: ${f.cap(m.tier)} · ${m.count} correct'
      : 'Mastery: ${f.cap(m.displayTier)} · ${m.count} / ${m.nextAt} to ${f.cap(m.nextTier!)}';
}

/// A collection card opens as its own screen, with actions in thumb reach.
class CollectionCardView extends StatefulWidget {
  const CollectionCardView({super.key, required this.data, required this.onCustomize});
  final Map<String, dynamic> data;
  final Future<String?> Function() onCustomize;
  @override
  State<CollectionCardView> createState() => _CollectionCardViewState();
}

class _CollectionCardViewState extends State<CollectionCardView> {
  late String _equipped = widget.data['finish'] as String;
  @override
  Widget build(BuildContext context) {
    final spec = CardSpec.fromJson((widget.data['card'] as Map).cast<String, dynamic>());
    final mastery = Mastery.fromJson((widget.data['mastery'] as Map).cast<String, dynamic>());
    final finish = Finish.collectionFinish(_equipped, mastery.tier);
    final demo = widget.data['presentation'] == true;
    void share() => shareObject(context, source: {'kind': 'card', 'playerId': spec.playerId});
    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.bg,
        title: const Text('Collection', style: T.h3),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${mastery.tier.toUpperCase()} · ${spec.series.toUpperCase()}', style: T.label),
                const SizedBox(height: 16),
                Center(
                  child: RepaintBoundary(
                    child: SportCard(
                      spec: spec,
                      width: math.min(box.maxWidth - 40, 380),
                      finish: finish,
                      onShare: share,
                      topRight: finish.toUpperCase(),
                      body: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${mastery.count} correct calls', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 6),
                            Text(
                              mastery.nextTier == null
                                  ? 'Diamond mastery unlocked'
                                  : '${mastery.count} / ${mastery.nextAt} to ${f.cap(mastery.nextTier!)}',
                              style: const TextStyle(color: C.inkDim),
                            ),
                          ],
                        ),
                      ),
                      footer: CardFooter(
                        spec: spec,
                        finish: finish,
                        left: mastery.tier.toUpperCase(),
                        right: mastery.nextTier == null ? '400/400 · Unlocked' : '${mastery.count} correct',
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                OutlinedButton.icon(onPressed: share, icon: const Icon(Icons.ios_share, size: 18), label: const Text('Share card')),
                if (mastery.count >= 400) ...[
                  const SizedBox(height: 10),
                  PrimaryButton('Sell Diamond edition', onPressed: () => context.go('/profile/sell/${spec.playerId}?presentation=$demo')),
                ],
                TextButton(
                  onPressed: () async {
                    final choice = await widget.onCustomize();
                    if (choice != null && mounted) setState(() => _equipped = choice);
                  },
                  child: const Text('Change card finish'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StoreTab extends ConsumerStatefulWidget {
  const _StoreTab();

  @override
  ConsumerState<_StoreTab> createState() => _StoreTabState();
}

class _StoreTabState extends ConsumerState<_StoreTab> {
  late Future<(Map<String, dynamic>, Map<String, dynamic>)> _data = _loadStore();
  String? _busy;

  static final _showcaseSpec = CardSpec.fromJson(const {
    'playerId': 1,
    'cardNo': 1,
    'series': 'Debut Series',
    'fullName': 'Josh Allen',
    'firstName': 'Josh',
    'lastName': 'Allen',
    'position': 'QB',
    'jerseyNumber': '17',
    'league': 'nfl',
    'teamAbbr': 'BUF',
    'teamName': 'Buffalo Bills',
    'colorway': {'base': '00338D', 'secondary': 'C60C30', 'Num': 'FFFFFF'},
  });

  static const _finishMeta = {
    'bronze': ('Warm copper foil', Color(0xFFE7B48F)),
    'silver': ('Brushed chrome frame', Color(0xFFD9E2EC)),
    'gold': ('24k championship foil', Color(0xFFFFDF7E)),
    'diamond': ('Prismatic facet finish', Color(0xFFB5E8FF)),
  };

  Future<(Map<String, dynamic>, Map<String, dynamic>)> _loadStore() async {
    final skusFuture = api.get('/store/skus');
    final colFuture = api.get('/me/collection').catchError((_) => <String, dynamic>{});
    return (await skusFuture, await colFuture);
  }

  Future<void> _buy(String finish, int price, CardSpec previewSpec) async {
    final ok = await showSheet<bool>(
      context,
      (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Buy ${f.cap(finish)} finish', style: T.h1),
          const SizedBox(height: 16),
          Center(
            child: SportCard(
              spec: previewSpec,
              variant: CardVariant.tile,
              showShare: false,
              width: 190,
              finish: finish,
              topRight: finish.toUpperCase(),
              footer: CardFooter(
                spec: previewSpec,
                scale: 190 / 340,
                finish: finish,
                left: finish.toUpperCase(),
                right: _finishMeta[finish]?.$1 ?? 'Cosmetic finish',
              ),
            ),
          ),
          const SizedBox(height: 20),
          PrimaryButton('Buy · ${f.coins(price)} coins', onPressed: () => Navigator.pop(ctx, true)),
          Center(
            child: GhostButton('Cancel', color: C.dim, onPressed: () => Navigator.pop(ctx, false)),
          ),
        ],
      ),
    );
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
      _data = _loadStore();
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
        final (d, col) = snap.data!;
        final balance = (d['balance'] as num).toInt();
        final skus = (d['skus'] as List).cast<Map<String, dynamic>>();
        final cards = (col['cards'] as List?)?.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() ?? const [];
        final unassigned = (col['unassignedFinishes'] as List?)?.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() ?? const [];
        final ownedCounts = <String, int>{
          for (final u in unassigned) (u['finish'] as String): (u['count'] as num).toInt(),
        };
        final previewSpec = cards.isNotEmpty
            ? CardSpec.fromJson((cards.first['card'] as Map).cast<String, dynamic>())
            : _showcaseSpec;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('COSMETIC FINISHES', style: T.label),
                      SizedBox(height: 4),
                      Text('Card store', style: T.h1),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0E241E),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: C.line),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CoinGlyph(size: 16, color: Color(0xFFE9DCA7)),
                      const SizedBox(width: 6),
                      Text(
                        f.coins(balance),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: C.green),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, box) {
                final tileW = (box.maxWidth - 14) / 2;
                final cardW = math.min(tileW, 180.0);
                return Wrap(
                  spacing: 14,
                  runSpacing: 22,
                  children: [
                    for (final s in skus)
                      _FinishStoreTile(
                        finish: s['finish'] as String,
                        price: (s['price'] as num).toInt(),
                        affordable: balance >= (s['price'] as num),
                        busy: _busy == s['finish'],
                        ownedCount: ownedCounts[s['finish'] as String] ?? 0,
                        spec: previewSpec,
                        tileWidth: tileW,
                        cardWidth: cardW,
                        subtitle: _finishMeta[s['finish'] as String]?.$1 ?? 'Custom frame',
                        accent: _finishMeta[s['finish'] as String]?.$2 ?? C.green,
                        onTap: _busy == null && balance >= (s['price'] as num)
                            ? () => _buy(s['finish'] as String, (s['price'] as num).toInt(), previewSpec)
                            : null,
                      ),
                  ],
                );
              },
            ),
          ],
        );
      },
    );
  }
}

class _FinishStoreTile extends StatelessWidget {
  const _FinishStoreTile({
    required this.finish,
    required this.price,
    required this.affordable,
    required this.busy,
    required this.ownedCount,
    required this.spec,
    required this.tileWidth,
    required this.cardWidth,
    required this.subtitle,
    required this.accent,
    required this.onTap,
  });

  final String finish;
  final int price;
  final bool affordable;
  final bool busy;
  final int ownedCount;
  final CardSpec spec;
  final double tileWidth;
  final double cardWidth;
  final String subtitle;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: tileWidth,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Opacity(
          opacity: affordable ? 1 : 0.55,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: SportCard(
                  spec: spec,
                  variant: CardVariant.tile,
                  showShare: false,
                  width: cardWidth,
                  finish: finish,
                  topRight: finish.toUpperCase(),
                  footer: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 9),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(height: 1, color: const Color(0xFFCBD3DB), margin: const EdgeInsets.only(bottom: 5)),
                        Row(
                          children: [
                            Text(
                              finish.toUpperCase(),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.1,
                                color: Finish.accent(finish),
                              ),
                            ),
                            const Spacer(),
                            Icon(
                              finish == 'diamond' ? Icons.diamond_outlined : Icons.auto_awesome,
                              size: 13,
                              color: Finish.accent(finish),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${f.cap(finish)} finish',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.h3,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small),
              const SizedBox(height: 6),
              if (busy)
                const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: C.green),
                )
              else
                Row(
                  children: [
                    const CoinGlyph(size: 14, color: Color(0xFFE9DCA7)),
                    const SizedBox(width: 5),
                    Text(
                      '${f.coins(price)} coins',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: affordable ? C.green : C.dim,
                      ),
                    ),
                    if (ownedCount > 0) ...[
                      const Spacer(),
                      Text('$ownedCount owned', style: T.small.copyWith(color: C.text)),
                    ],
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
