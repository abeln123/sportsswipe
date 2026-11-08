import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../state/immersive.dart';
import '../../ui/widgets.dart';
import 'contest_hub.dart';
import 'parlay_deck.dart';
import 'single_deck.dart';

class PlayScreen extends ConsumerStatefulWidget {
  const PlayScreen({super.key});

  @override
  ConsumerState<PlayScreen> createState() => _PlayScreenState();
}

class _PlayScreenState extends ConsumerState<PlayScreen> {
  bool _contests = false;
  bool _parlay = false;
  String _sport = 'all';

  void _set(VoidCallback fn) {
    ref.read(immersiveProvider.notifier).set(false);
    setState(fn);
  }

  Widget _tab(String label, bool active, VoidCallback onTap, {double fontSize = 15, double vertical = 10, bool underline = true}) => Semantics(
        selected: active,
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: vertical),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: underline && active ? C.green : Colors.transparent, width: 2)),
            ),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              style: TextStyle(fontSize: fontSize, fontWeight: active ? FontWeight.w700 : FontWeight.w500, color: active ? C.green : C.dim),
              child: Text(label),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final immersive = ref.watch(immersiveProvider);
    final mode = _contests ? 'contests' : (_parlay ? 'parlay-$_sport' : 'single-$_sport');
    return Column(children: [
      Collapse(
        visible: !immersive,
        child: Column(children: [
          if (!_contests)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
                child: Row(children: [
                  for (final (id, label) in const [('all', 'All sports'), ('nba', 'NBA'), ('nfl', 'NFL')])
                    Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: _tab(label, _sport == id, () => _set(() => _sport = id), fontSize: 14, vertical: 12),
                    ),
                ]),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
            child: Row(children: [
              _tab('Solo', !_contests, () => _set(() => _contests = false), underline: false),
              const SizedBox(width: 8),
              _tab('Contests', _contests, () => _set(() => _contests = true), underline: false),
              const Spacer(),
              if (!_contests) ...[
                _tab('Single', !_parlay, () => _set(() => _parlay = false)),
                const SizedBox(width: 10),
                _tab('Parlay', _parlay, () => _set(() => _parlay = true)),
              ],
            ]),
          ),
        ]),
      ),
      Expanded(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(position: Tween(begin: const Offset(0, 0.02), end: Offset.zero).animate(a), child: child),
          ),
          child: switch (mode) {
            'contests' => const ContestHub(key: ValueKey('contests')),
            _ when _parlay => ParlayDeck(key: ValueKey(mode), sport: _sport),
            _ => SingleDeck(key: ValueKey(mode), sport: _sport, onBuildParlay: () => _set(() => _parlay = true)),
          },
        ),
      ),
    ]);
  }
}
