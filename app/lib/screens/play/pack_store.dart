import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../card/card_spec.dart';
import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../core/theme.dart';
import '../../state/pick_queue.dart';
import '../../state/play.dart';
import '../../state/session.dart';
import '../../ui/shell.dart' show CoinGlyph;
import '../../ui/widgets.dart';
import 'pack_art.dart';
import 'pack_feedback.dart';
import 'pack_deck.dart';

const _uuid = Uuid();

/// A pack in the store, as sent by `GET /packs`.
class PackOffer {
  PackOffer(Map<String, dynamic> j)
    : key = j['key'] as String,
      name = j['name'] as String,
      tagline = j['tagline'] as String? ?? '',
      price = (j['price'] as num).toInt(),
      size = (j['size'] as num).toInt(),
      kind = j['kind'] as String? ?? 'mixed',
      league = j['league'] as String?,
      team = j['teamId'] != null,
      targetPct = (j['targetPct'] as num?)?.toInt(),
      payout = (j['payout'] as num?)?.toInt() ?? 0,
      multiplier = (j['multiplier'] as num?)?.toInt() ?? 1,
      colors = foilColors(j['foil'] as List?),
      available = (j['available'] as num?)?.toInt() ?? 0;

  final String key, name, tagline, kind;
  final String? league;
  final bool team;
  final int price, size, payout, multiplier, available;
  final int? targetPct;
  final List<Color> colors;

  bool get challenge => targetPct != null;
  bool get soldOut => available < size;
  int get packsRemaining => available ~/ size;
  int get deals => available < size ? available : size;

  FoilPack art({double width = 150, double sheen = 0}) => FoilPack(
    name: name,
    colors: colors,
    badge: challenge && !name.toUpperCase().contains('${multiplier}X') ? '${multiplier}X' : null,
    caption: '$size cards per pack',
    width: width,
    sheen: sheen,
  );
}

/// Cards being played: a freshly opened pack, or the leftovers.
class _Session {
  _Session({required this.id, required this.title, required this.cards, this.pack, this.targetPct, this.payout});
  final String id;
  final String title;
  final List<PlayableCard> cards;
  final FoilPack? pack;
  final int? targetPct;
  final int? payout;
}

class PackStore extends ConsumerStatefulWidget {
  const PackStore({super.key, required this.sport});
  final String sport;

  @override
  ConsumerState<PackStore> createState() => _PackStoreState();
}

class _PackStoreState extends ConsumerState<PackStore> {
  Map<String, dynamic>? _data;
  Object? _error;
  _Session? _session;
  bool _opening = false;
  final Animation<double> _sheen = const AlwaysStoppedAnimation(0.4);
  bool _buying = false;
  int _loadVersion = 0;

  @override
  void initState() {
    super.initState();
    _load();
    PackFeedback.instance.preload();
    _restore();
  }

  @override
  void didUpdateWidget(PackStore old) {
    super.didUpdateWidget(old);
    if (old.sport != widget.sport) {
      setState(() {
        _data = null;
        _error = null;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final version = ++_loadVersion;
    try {
      final r = await api.get('/packs?sport=${widget.sport}');
      if (mounted && version == _loadVersion) {
        setState(() {
          _data = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && version == _loadVersion) setState(() => _error = e);
    }
  }

  List<PackOffer> get _offers => ((_data?['packs'] as List?) ?? [])
      .map((e) => PackOffer((e as Map).cast<String, dynamic>()))
      .where((p) => widget.sport == 'all' || p.league == null || p.league == widget.sport)
      .toList();

  String get _pendingKey => 'pack.pending.${ref.read(sessionProvider).value?.id}';

  Future<void> _exit() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingKey);
    if (!mounted) return;
    ref.read(playMenuProvider.notifier).close();
    ref.read(playCardsProvider.notifier).set(false);
    setState(() => _session = null);
    _load();
  }

  Future<void> _restore() async {
    if (_buying) return;
    _buying = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final saved = prefs.getString(_pendingKey);
      if (saved != null) {
        await _purchase(jsonDecode(saved) as Map<String, dynamic>);
      }
    } finally {
      if (mounted) {
        setState(() => _buying = false);
      }
    }
  }

  Future<void> _buy(PackOffer p) async {
    if (_buying) return;
    _buying = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final pending = prefs.getString(_pendingKey);
      if (pending != null) {
        await _purchase(jsonDecode(pending) as Map<String, dynamic>);
        return;
      }
      final ok = await showSheet<bool>(context, (ctx) => _BuySheet(offer: p, balance: ref.read(displayBalanceProvider)));
      if (ok != true || !mounted) return;
      final command = <String, dynamic>{'commandId': _uuid.v4(), 'packKey': p.key, 'sport': widget.sport};
      // Persist before sending: a lost response or app restart retries the same purchase.
      await prefs.setString(_pendingKey, jsonEncode(command));
      if (!mounted) return;
      await _purchase(command);
    } finally {
      if (mounted) {
        setState(() => _buying = false);
      }
    }
  }

  Future<void> _purchase(Map<String, dynamic> command) async {
    final r = await api.raw('POST', '/packs/buy', body: command);
    if (!mounted) return;
    final body = r.map;
    if (!r.ok) {
      if (r.status >= 400 && r.status < 500) {
        final prefs = await SharedPreferences.getInstance();
        if (!mounted) return;
        await prefs.remove(_pendingKey);
      }
      if (!mounted) return;
      toast(context, body['message']?.toString() ?? 'Could not open that pack.', ok: false);
      _load();
      return;
    }
    final balance = (body['balance'] as num?)?.toInt();
    if (balance != null) {
      ref.read(summaryProvider.notifier).applyBalance(balance);
    }
    final cards = ((body['cards'] as List?) ?? []).map((e) => PlayableCard.fromJson((e as Map).cast<String, dynamic>())).toList();
    if (cards.isEmpty) {
      await _exit();
      return;
    }
    ref.read(playCardsProvider.notifier).set(true);
    setState(() {
      _session = _Session(
        id: body['packId'] as String,
        title: body['name'] as String,
        cards: cards,
        pack: FoilPack(
          name: body['name'] as String,
          colors: foilColors(body['foil'] as List?),
          caption: '${cards.length} cards',
          width: 220,
        ),
        targetPct: (body['targetPct'] as num?)?.toInt(),
        payout: (body['payout'] as num?)?.toInt(),
      );
      _opening = true;
    });
  }

  Future<void> _leftovers() async {
    try {
      final r = await api.get('/packs/leftovers?sport=${widget.sport}');
      final cards = ((r['cards'] as List?) ?? []).map((e) => PlayableCard.fromJson((e as Map).cast<String, dynamic>())).toList();
      if (!mounted) return;
      if (cards.isEmpty) {
        toast(context, 'No leftover cards right now.');
        _exit();
        return;
      }
      ref.read(playCardsProvider.notifier).set(true);
      setState(() {
        _session = _Session(id: 'leftovers-${DateTime.now().millisecondsSinceEpoch}', title: 'Leftovers', cards: cards);
        _opening = false;
      });
    } catch (e) {
      if (mounted) toast(context, e.toString(), ok: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    final Widget view;
    if (s != null && _opening && s.pack != null) {
      view = PackOpening(
        key: ValueKey('open-${s.id}'),
        pack: s.pack!,
        count: s.cards.length,
        onDone: () => setState(() => _opening = false),
      );
    } else if (s != null) {
      view = PackDeck(
        key: ValueKey(s.id),
        title: s.title,
        cards: s.cards,
        sport: widget.sport,
        targetPct: s.targetPct,
        payout: s.payout,
        onExit: _exit,
        onLeftovers: _leftovers,
      );
    } else if (_error != null && _data == null) {
      view = ErrorText(_error!, onRetry: _load);
    } else if (_data == null) {
      view = const Center(child: CircularProgressIndicator(strokeWidth: 2, color: C.dim));
    } else {
      view = _store();
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      child: KeyedSubtree(key: ValueKey(view.key ?? view.runtimeType), child: view),
    );
  }

  Widget _store() {
    final offers = _offers;
    final featured = offers.where((p) => p.challenge).toList();
    final regular = offers.where((p) => !p.challenge && !p.team).toList();
    final teams = offers.where((p) => p.team).toList();
    final leftovers = (_data?['leftoverCount'] as num?)?.toInt() ?? 0;
    final challenges = ((_data?['challenges'] as List?) ?? []).cast<Map>();
    return RefreshIndicator(
      onRefresh: _load,
      color: C.green,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        scrollCacheExtent: const ScrollCacheExtent.pixels(180),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            sliver: SliverList.list(
              children: [
                const Text('Packs', style: T.h1),
                if (leftovers > 0) ...[
                  const SizedBox(height: 18),
                  const Text('LEFTOVER CARDS', style: T.label),
                  const SizedBox(height: 10),
                  _LeftoverStrip(count: leftovers, onPlay: _leftovers),
                ],
                for (final c in challenges) ...[const SizedBox(height: 16), _ChallengeRow(c.cast<String, dynamic>())],
                if (featured.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  const Text('CHALLENGE PACK', style: T.label),
                  const SizedBox(height: 12),
                  for (final p in featured)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _FeaturedPack(offer: p, sheen: _sheen, onTap: p.soldOut ? null : () => _buy(p)),
                    ),
                ],
                const SizedBox(height: 22),
                const Text('10-COIN PACKS', style: T.label),
                const SizedBox(height: 10),
              ],
            ),
          ),
          SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 16), sliver: _grid(regular)),
          if (teams.isNotEmpty) ...[
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverList.list(
                children: const [
                  SizedBox(height: 28),
                  Text('TEAM PACKS · 50 COINS', style: T.label),
                  SizedBox(height: 12),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
              sliver: _grid(teams),
            ),
          ] else
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  Widget _grid(List<PackOffer> offers) => SliverGrid.builder(
    itemCount: offers.length,
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      mainAxisSpacing: 22,
      crossAxisSpacing: 14,
      childAspectRatio: 0.50,
    ),
    itemBuilder: (context, i) => _PackTile(offer: offers[i], sheen: _sheen, onTap: offers[i].soldOut ? null : () => _buy(offers[i])),
  );
}

class _PackTile extends StatelessWidget {
  const _PackTile({required this.offer, required this.sheen, required this.onTap});
  final PackOffer offer;
  final Animation<double> sheen;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    label: '${offer.name}, ${offer.tagline}, ${offer.price} coins${onTap == null ? ', sold out' : ''}',
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => Center(
                  child: AnimatedBuilder(
                    animation: sheen,
                    builder: (context, _) => offer.art(
                      width: (box.maxHeight / foilPackHeightRatio).clamp(0.0, box.maxWidth),
                      sheen: onTap == null ? 0 : sheen.value,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(offer.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.h3),
            const SizedBox(height: 4),
            _Price(price: offer.price, soldOut: onTap == null),
            Text('${offer.packsRemaining} packs left · ${offer.size} cards each', style: T.small),
          ],
        ),
      ),
    ),
  );
}

class _Price extends StatelessWidget {
  const _Price({required this.price, this.soldOut = false});
  final int price;
  final bool soldOut;

  @override
  Widget build(BuildContext context) => soldOut
      ? const Text(
          'Sold out today',
          style: TextStyle(fontSize: 13, color: C.dim, fontWeight: FontWeight.w600),
        )
      : Row(
          children: [
            const CoinGlyph(size: 14, color: C.text),
            const SizedBox(width: 5),
            Text(
              f.coins(price),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ],
        );
}

class _FeaturedPack extends StatelessWidget {
  const _FeaturedPack({required this.offer, required this.sheen, required this.onTap});
  final PackOffer offer;
  final Animation<double> sheen;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    label: '${offer.name}. Hit ${offer.targetPct} percent to earn ${offer.payout} coins. Costs ${offer.price} coins.',
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Row(
          children: [
            AnimatedBuilder(
              animation: sheen,
              builder: (context, _) => offer.art(width: 118, sheen: sheen.value),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(offer.name, style: T.h3.copyWith(fontSize: 18)),
                  const SizedBox(height: 6),
                  Text.rich(
                    TextSpan(
                      style: const TextStyle(fontSize: 13.5, color: C.text),
                      children: [
                        TextSpan(
                          text: 'Hit ${offer.targetPct}%',
                          style: const TextStyle(fontWeight: FontWeight.w700, color: C.green),
                        ),
                        TextSpan(text: ' of ${offer.size} picks → '),
                        TextSpan(
                          text: '${f.coins(offer.payout)} coins',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _Price(price: offer.price, soldOut: onTap == null),
                  Text('${offer.packsRemaining} packs left · ${offer.size} cards each', style: T.small),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _LeftoverStrip extends StatelessWidget {
  const _LeftoverStrip({required this.count, required this.onPlay});
  final int count;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Leftover cards, $count not played yet',
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onPlay,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              height: 50,
              child: Stack(
                children: [
                  for (var i = 0; i < 3; i++)
                    Positioned(
                      left: i * 8.0,
                      top: (2 - i) * 2.0,
                      child: Transform.rotate(angle: (i - 1) * 0.12, child: const CardBack(width: 30)),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Leftover cards', style: T.h3),
                  const SizedBox(height: 2),
                  Text('$count unplayed ${count == 1 ? 'card' : 'cards'}', style: T.small),
                ],
              ),
            ),
            const Text('Swipe', style: TextStyle(fontWeight: FontWeight.w700, color: C.green)),
            const Icon(Icons.chevron_right_rounded, color: C.green),
          ],
        ),
      ),
    ),
  );
}

class _ChallengeRow extends StatelessWidget {
  const _ChallengeRow(this.c);
  final Map<String, dynamic> c;

  @override
  Widget build(BuildContext context) {
    final size = (c['size'] as num).toInt();
    final won = (c['won'] as num?)?.toInt() ?? 0;
    final picked = (c['picked'] as num?)?.toInt() ?? 0;
    final target = (c['targetPct'] as num?)?.toInt() ?? 80;
    final need = (size * target / 100).ceil();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('${c['name']} in play', style: T.h3)),
              Text('${f.coins((c['payout'] as num?)?.toInt() ?? 0)} coins', style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < size; i++)
                Expanded(
                  child: Container(
                    height: 6,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                      color: i < won ? C.text : (i < picked ? C.faint : C.line),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text('$won hit · $picked of $size picked · needs $need', style: T.small),
        ],
      ),
    );
  }
}

/// Quiet purchase preview: the detailed foil stays on its own cached layer.
class _BuySheet extends StatelessWidget {
  const _BuySheet({required this.offer, required this.balance});
  final PackOffer offer;
  final int balance;
  @override
  Widget build(BuildContext context) {
    final short = balance < offer.price;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Text('PACK PREVIEW', style: T.label)),
            IconButton(
              tooltip: 'Close preview',
              onPressed: () => Navigator.pop(context, false),
              icon: const Icon(Icons.close, size: 20, color: C.dim),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 22),
          decoration: BoxDecoration(
            gradient: RadialGradient(radius: .85, colors: [offer.colors.last.withValues(alpha: .1), Colors.transparent]),
            border: const Border(
              top: BorderSide(color: C.line),
              bottom: BorderSide(color: C.line),
            ),
          ),
          child: Center(child: offer.art(width: 132, sheen: .4)),
        ),
        const SizedBox(height: 22),
        Text(offer.name, style: T.h1),
        const SizedBox(height: 6),
        Text(offer.tagline, style: T.dim),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(child: _detail('${offer.size}', 'CARDS')),
            Container(width: 1, height: 36, color: C.line),
            Expanded(
              child: Padding(padding: const EdgeInsets.only(left: 24), child: _detail('${offer.packsRemaining}', 'PACKS LEFT')),
            ),
            const CoinGlyph(size: 19, color: Color(0xFFE9DCA7)),
            const SizedBox(width: 7),
            Text(f.coins(offer.price), style: T.h2),
          ],
        ),
        const SizedBox(height: 20),
        if (offer.challenge) ...[
          Text('Hit ${offer.targetPct}% of your picks to earn ${f.coins(offer.payout)} coins.', style: T.body),
          const SizedBox(height: 16),
        ],
        PrimaryButton(
          short ? 'Not enough coins' : 'Open pack · ${f.coins(offer.price)} coins',
          onPressed: short
              ? null
              : () {
                  if (PackFeedback.instance.haptics) {
                    HapticFeedback.selectionClick();
                  }
                  Navigator.pop(context, true);
                },
        ),
        const SizedBox(height: 12),
        Text(
          short ? 'You need ${f.coins(offer.price - balance)} more coins.' : '${f.coins(balance - offer.price)} coins after opening',
          style: T.small,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _detail(String value, String label) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: T.h2),
      const SizedBox(height: 3),
      Text(label, style: T.label.copyWith(fontSize: 10, letterSpacing: 1)),
    ],
  );
}
