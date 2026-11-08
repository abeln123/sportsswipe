import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/session.dart';

import '../../core/theme.dart';
import '../../state/play.dart';
import '../../ui/widgets.dart';
import 'contest_hub.dart';
import 'pack_store.dart';
import 'parlay_deck.dart';

class PlayScreen extends ConsumerStatefulWidget {
  const PlayScreen({super.key});

  @override
  ConsumerState<PlayScreen> createState() => _PlayScreenState();
}

class _PlayScreenState extends ConsumerState<PlayScreen> with SingleTickerProviderStateMixin {
  late final _menu = AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
  @override
  void initState() {
    super.initState();
    playMenuPull.addListener(_onPull);
  }

  @override
  void dispose() {
    playMenuPull.removeListener(_onPull);
    _menu.dispose();
    super.dispose();
  }

  void _onPull() {
    if (!ref.read(playCardsProvider)) return;
    final pull = playMenuPull.value;
    if (pull > 0 && !ref.read(playMenuProvider)) {
      _menu.value = (pull / 140).clamp(0, 1);
    } else if (pull == 0) {
      _settle(ref.read(playMenuProvider));
    }
  }

  void _settle(bool open) => _menu.animateTo(open ? 1 : 0, curve: Curves.easeOutCubic);
  Future<void> _select(PlayMode next) async {
    if (ref.read(playCardsProvider) && !ref.read(playModeProvider).parlay) {
      final user = ref.read(sessionProvider).value?.id;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('pack.pending.$user');
      if (!mounted) return;
    }
    HapticFeedback.selectionClick();
    ref.read(playMenuProvider.notifier).close();
    ref.read(playCardsProvider.notifier).set(false);
    ref.read(playModeProvider.notifier).set(next.copyWith(revision: ref.read(playModeProvider).revision + 1));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playMenuProvider, (_, open) => _settle(open));
    final mode = ref.watch(playModeProvider);
    final cards = ref.watch(playCardsProvider);
    final key = ValueKey('${mode.place}-${mode.sport}-${mode.revision}');
    final navigation = PlayNavigation(mode: mode, onSelect: _select);
    return Column(
      children: [
        if (!cards) navigation,
        Expanded(
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              const Positioned.fill(child: PineBackdrop()),
              Positioned.fill(
                child: switch (mode) {
                  PlayMode(contests: true) => ContestHub(key: key),
                  PlayMode(parlay: true) => ParlayDeck(key: key, sport: mode.sport),
                  _ => PackStore(key: key, sport: mode.sport),
                },
              ),
              if (cards)
                AnimatedBuilder(
                  animation: _menu,
                  child: navigation,
                  builder: (context, panel) {
                    if (_menu.value == 0) return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
                    return Positioned.fill(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: GestureDetector(
                              onTap: () => ref.read(playMenuProvider.notifier).close(),
                              child: ColoredBox(color: Colors.black.withValues(alpha: .45 * _menu.value)),
                            ),
                          ),
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: ClipRect(
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                heightFactor: _menu.value,
                                child: IgnorePointer(ignoring: _menu.value < .8, child: panel),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Primary mode tabs with underlined sport tabs on the right.
class PlayNavigation extends StatelessWidget {
  const PlayNavigation({super.key, required this.mode, required this.onSelect});
  final PlayMode mode;
  final ValueChanged<PlayMode> onSelect;

  @override
  Widget build(BuildContext context) => Material(
    color: C.bg,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: UnderTabs(
        labels: const ['Packs', 'Parlays', 'Contests'],
        index: mode.contests
            ? 2
            : mode.parlay
            ? 1
            : 0,
        onChanged: (i) => onSelect(mode.copyWith(contests: i == 2, parlay: i == 1)),
        trailing: mode.contests
            ? null
            : _SportFilter(
                sport: mode.sport,
                onChanged: (s) => onSelect(mode.copyWith(sport: s)),
              ),
      ),
    ),
  );
}

class _SportFilter extends StatelessWidget {
  const _SportFilter({required this.sport, required this.onChanged});
  final String sport;
  final ValueChanged<String> onChanged;

  static const _items = [('all', 'All sports'), ('nfl', 'NFL'), ('nba', 'NBA')];

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < _items.length; i++)
        Semantics(
          button: true,
          selected: sport == _items[i].$1,
          child: InkWell(
            onTap: () => onChanged(_items[i].$1),
            child: Container(
              padding: EdgeInsets.fromLTRB(i == 0 ? 4 : 6, 12, i == _items.length - 1 ? 2 : 6, 10),
              margin: EdgeInsets.only(left: i == 0 ? 0 : 4),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: sport == _items[i].$1 ? C.green : Colors.transparent, width: 2),
                ),
              ),
              child: Text(
                _items[i].$2,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: sport == _items[i].$1 ? FontWeight.w700 : FontWeight.w500,
                  color: sport == _items[i].$1 ? C.green : C.dim,
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

/// Deep pine surface with two oversized diagonal cuts at the upper right.
/// It never moves, so cards change while the room stays put.
class PineBackdrop extends StatelessWidget {
  const PineBackdrop({super.key});

  @override
  Widget build(BuildContext context) => const RepaintBoundary(child: CustomPaint(painter: _PinePainter()));
}

class _PinePainter extends CustomPainter {
  const _PinePainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final w = size.width, h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0A1C17));
    void cut(Offset anchor, double thickness, Color color) {
      canvas.save();
      canvas.translate(anchor.dx, anchor.dy);
      canvas.rotate(-0.62);
      canvas.drawRect(Rect.fromLTWH(-w * 1.6, -thickness / 2, w * 3.2, thickness), Paint()..color = color);
      canvas.restore();
    }

    cut(Offset(w * 1.02, h * 0.10), w * 0.52, const Color(0xFF0F2820));
    cut(Offset(w * 1.18, h * 0.44), w * 0.30, const Color(0xFF0D241D));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PinePainter old) => false;
}
