import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';

/// Horizontal swipe: right is Over, left is Under. Arrow keys do the same
/// when focused. A short drag springs back.
class Swipeable extends StatefulWidget {
  const Swipeable({super.key, required this.child, required this.onSwipe, this.enabled = true});

  final Widget child;
  final void Function(String side) onSwipe;
  final bool enabled;

  @override
  State<Swipeable> createState() => _SwipeableState();
}

class _SwipeableState extends State<Swipeable> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  double _dx = 0;
  Animation<double>? _anim;

  @override
  void initState() {
    super.initState();
    _c.addListener(() {
      if (_anim != null) setState(() => _dx = _anim!.value);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _animateTo(double target, {VoidCallback? then}) {
    _anim = Tween(begin: _dx, end: target).animate(CurvedAnimation(parent: _c, curve: Curves.easeOut));
    _c.forward(from: 0).whenComplete(() {
      then?.call();
    });
  }

  void _commit(String side) {
    final w = MediaQuery.of(context).size.width;
    _animateTo(side == 'over' ? w : -w, then: () {
      widget.onSwipe(side);
      if (mounted) setState(() => _dx = 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final p = (_dx / (w * 0.35)).clamp(-1.0, 1.0);
    return Focus(
      onKeyEvent: (_, e) {
        if (!widget.enabled || e is! KeyDownEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
          _commit('over');
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _commit('under');
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onHorizontalDragUpdate: widget.enabled ? (d) => setState(() => _dx += d.delta.dx) : null,
        onHorizontalDragEnd: widget.enabled
            ? (d) {
                final v = d.primaryVelocity ?? 0;
                if (_dx > w * 0.25 || v > 900) {
                  _commit('over');
                } else if (_dx < -w * 0.25 || v < -900) {
                  _commit('under');
                } else {
                  _animateTo(0);
                }
              }
            : null,
        child: Transform.translate(
          offset: Offset(_dx, 0),
          child: Transform.rotate(
            angle: p * 0.08,
            child: Stack(children: [
              widget.child,
              if (p.abs() > 0.15)
                Positioned(
                  top: 70,
                  left: p > 0 ? 22 : null,
                  right: p < 0 ? 22 : null,
                  child: Opacity(
                    opacity: p.abs().clamp(0.0, 1.0),
                    child: Transform.rotate(
                      angle: p > 0 ? -0.25 : 0.25,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.85),
                          border: Border.all(color: p > 0 ? const Color(0xFF2FA968) : const Color(0xFF8B6FE0), width: 3),
                        ),
                        child: Text(p > 0 ? 'OVER' : 'UNDER',
                            style: TextStyle(
                              fontFamily: kCondensed,
                              fontWeight: FontWeight.w800,
                              fontSize: 30,
                              color: p > 0 ? const Color(0xFF2FA968) : const Color(0xFF8B6FE0),
                            )),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Explicit buttons under the card for people who don't swipe.
class SwipeButtons extends StatelessWidget {
  const SwipeButtons({super.key, required this.onSide, required this.onSkip, this.hint = 'Swipe left or right'});
  final void Function(String side) onSide;
  final VoidCallback onSkip;
  final String hint;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(children: [
          Text(hint, style: const TextStyle(color: C.dim, fontSize: 14)),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            TextButton(
              onPressed: () => onSide('under'),
              child: const Text('← Under', style: TextStyle(color: C.under, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 12),
            TextButton(onPressed: onSkip, child: const Text('Skip', style: TextStyle(color: C.text))),
            const SizedBox(width: 12),
            TextButton(
              onPressed: () => onSide('over'),
              child: const Text('Over →', style: TextStyle(color: C.over, fontWeight: FontWeight.w700)),
            ),
          ]),
        ]),
      );
}
