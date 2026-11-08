import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'contest_hub.dart';
import 'parlay_deck.dart';
import 'single_deck.dart';

class PlayScreen extends StatefulWidget {
  const PlayScreen({super.key});

  @override
  State<PlayScreen> createState() => _PlayScreenState();
}

class _PlayScreenState extends State<PlayScreen> {
  bool _contests = false;
  bool _parlay = false;
  String _sport = 'all';

  Widget _toggle(String label, bool active, VoidCallback onTap, {bool underline = false}) => InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: underline && active ? C.green : Colors.transparent, width: 2)),
          ),
          child: Text(label,
              style: TextStyle(fontSize: 15, fontWeight: active ? FontWeight.w700 : FontWeight.w500, color: active ? C.green : C.dim)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      if (!_contests)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
            child: Row(children: [
              for (final (id, label) in const [('all', 'All sports'), ('nba', 'NBA'), ('nfl', 'NFL')])
                Padding(
                  padding: const EdgeInsets.only(right: 22),
                  child: Semantics(
                    selected: _sport == id,
                    button: true,
                    child: InkWell(
                      onTap: () => setState(() => _sport = id),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: _sport == id ? C.green : Colors.transparent, width: 2)),
                        ),
                        child: Text(label,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: _sport == id ? FontWeight.w700 : FontWeight.w500,
                              color: _sport == id ? C.green : C.dim,
                            )),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
        child: Container(
          decoration: _contests ? const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))) : null,
          child: Row(children: [
            _toggle('Solo', !_contests, () => setState(() => _contests = false)),
            const SizedBox(width: 8),
            _toggle('Contests', _contests, () => setState(() => _contests = true)),
            const Spacer(),
            if (!_contests) ...[
              _toggle('Single', !_parlay, () => setState(() => _parlay = false), underline: true),
              const SizedBox(width: 10),
              _toggle('Parlay', _parlay, () => setState(() => _parlay = true), underline: true),
            ],
          ]),
        ),
      ),
      Expanded(
        child: _contests
            ? const ContestHub()
            : _parlay
                ? ParlayDeck(key: ValueKey('parlay-$_sport'), sport: _sport)
                : SingleDeck(key: ValueKey('single-$_sport'), sport: _sport, onBuildParlay: () => setState(() => _parlay = true)),
      ),
    ]);
  }
}
