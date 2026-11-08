import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../state/play.dart';
import 'contest_hub.dart';
import 'pack_store.dart';
import 'parlay_deck.dart';

class PlayScreen extends ConsumerStatefulWidget {
  const PlayScreen({super.key});

  @override
  ConsumerState<PlayScreen> createState() => _PlayScreenState();
}

class _PlayScreenState extends ConsumerState<PlayScreen> with SingleTickerProviderStateMixin {
  /// 0 closed, 1 open. Follows the finger while the card is pulled down.
  late final AnimationController _menu = AnimationController(vsync: this, duration: const Duration(milliseconds: 280));

  /// Pull distance that brings the menu fully out.
  static const _reveal = 140.0;

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
    final p = playMenuPull.value;
    final open = ref.read(playMenuProvider);
    if (p > 0 && !open) {
      _menu.value = (p / _reveal).clamp(0.0, 1.0);
    } else if (p == 0) {
      _settle(open);
    }
  }

  void _settle(bool open) => _menu.animateTo(open ? 1 : 0, curve: Curves.easeOutCubic);

  void _set(PlayMode m) {
    HapticFeedback.selectionClick();
    ref.read(playModeProvider.notifier).set(m);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playMenuProvider, (_, open) => _settle(open));
    final mode = ref.watch(playModeProvider);
    final still = MediaQuery.of(context).disableAnimations;
    final key = mode.contests ? 'contests' : (mode.parlay ? 'parlay-${mode.sport}' : 'packs');
    return Stack(children: [
      const Positioned.fill(child: PineBackdrop()),
      Positioned.fill(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, a) => FadeTransition(opacity: a, child: child),
          child: switch (mode) {
            PlayMode(contests: true) => const ContestHub(key: ValueKey('contests')),
            PlayMode(parlay: true) => ParlayDeck(key: ValueKey(key), sport: mode.sport),
            _ => PackStore(key: ValueKey(key), sport: mode.sport),
          },
        ),
      ),
      AnimatedBuilder(
        animation: _menu,
        builder: (context, _) => _menu.value == 0
            ? const SizedBox.shrink()
            : Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => ref.read(playMenuProvider.notifier).close(),
                  child: ColoredBox(color: Colors.black.withValues(alpha: 0.5 * _menu.value)),
                ),
              ),
      ),
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: AnimatedBuilder(
          animation: _menu,
          child: _panel(mode),
          builder: (context, panel) => IgnorePointer(
            ignoring: _menu.value < 0.5,
            child: still
                ? Opacity(opacity: _menu.value, child: panel)
                : ClipRect(
                    child: Align(alignment: Alignment.bottomCenter, heightFactor: _menu.value, child: panel),
                  ),
          ),
        ),
      ),
    ]);
  }

  Widget _panel(PlayMode mode) => GestureDetector(
        onVerticalDragUpdate: (d) => _menu.value = (_menu.value + d.delta.dy / 260).clamp(0.0, 1.0),
        onVerticalDragEnd: (d) {
          final open = (d.primaryVelocity ?? 0) > -300 && _menu.value > 0.6;
          if (!open) ref.read(playMenuProvider.notifier).close();
          _settle(open);
        },
        child: Container(
          decoration: const BoxDecoration(
            color: C.surface,
            border: Border(bottom: BorderSide(color: C.line)),
            boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 24, offset: Offset(0, 12))],
          ),
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Segments(
              label: 'Play',
              options: const [('solo', 'Solo'), ('contests', 'Contests')],
              selected: mode.contests ? 'contests' : 'solo',
              onSelect: (v) => _set(mode.copyWith(contests: v == 'contests')),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: mode.contests
                  ? const SizedBox(width: double.infinity)
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _Segments(
                        label: 'Prediction mode',
                        options: const [('packs', 'Packs'), ('parlay', 'Parlay')],
                        selected: mode.parlay ? 'parlay' : 'packs',
                        onSelect: (v) => _set(mode.copyWith(parlay: v == 'parlay')),
                      ),
                      _Segments(
                        label: 'Sport',
                        options: const [('all', 'All sports'), ('nba', 'NBA'), ('nfl', 'NFL')],
                        selected: mode.sport,
                        onSelect: (v) => _set(mode.copyWith(sport: v)),
                      ),
                    ]),
            ),
            Semantics(
              button: true,
              label: 'Close menu',
              excludeSemantics: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => ref.read(playMenuProvider.notifier).close(),
                child: SizedBox(
                  height: 26,
                  width: double.infinity,
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(color: C.faint, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      );
}

class _Segments extends StatelessWidget {
  const _Segments({required this.label, required this.options, required this.selected, required this.onSelect});
  final String label;
  final List<(String, String)> options;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(), style: T.label.copyWith(fontSize: 11)),
          const SizedBox(height: 6),
          Row(children: [
            for (final (id, text) in options)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: id == options.last.$1 ? 0 : 8),
                  child: Semantics(
                    selected: id == selected,
                    button: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onSelect(id),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: id == selected ? C.green.withValues(alpha: 0.12) : Colors.transparent,
                          border: Border.all(color: id == selected ? C.green : C.line),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(text,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: id == selected ? FontWeight.w700 : FontWeight.w500,
                              color: id == selected ? C.green : C.dim,
                            )),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ]),
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
  }

  @override
  bool shouldRepaint(_PinePainter old) => false;
}
