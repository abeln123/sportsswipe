import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';

/// A card you can throw. Right is Over, left is Under; with [onSkip] set,
/// up skips; with [onPullDown] set, a downward pull calls it and the card
/// springs back. Arrow keys do the same when focused.
///
/// Haptics give the card weight: a tick when it's picked up, a firmer bump
/// when a drag crosses the point where letting go would commit, and a heavy
/// thud when it's thrown.
class Swipeable extends StatefulWidget {
  const Swipeable({
    super.key,
    required this.child,
    required this.onSwipe,
    this.onSkip,
    this.onPullDown,
    this.onEngage,
    this.enabled = true,
    this.verticalDrag = true,
  });

  final Widget child;
  final void Function(String side) onSwipe;
  final VoidCallback? onSkip;
  final VoidCallback? onPullDown;

  /// Called when a drag starts.
  final VoidCallback? onEngage;
  final bool enabled;

  /// Off inside scrolling pages, where vertical drags must scroll.
  final bool verticalDrag;

  @override
  State<Swipeable> createState() => SwipeableState();
}

class SwipeableState extends State<Swipeable> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(vsync: this);
  Offset _pos = Offset.zero;
  Offset _from = Offset.zero;
  Offset _to = Offset.zero;
  bool _grabTop = true;
  bool _busy = false;
  String? _armed;

  bool get _vertical => widget.verticalDrag && (widget.onSkip != null || widget.onPullDown != null);

  @override
  void initState() {
    super.initState();
    _c.addListener(() => setState(() => _pos = Offset.lerp(_from, _to, _c.value)!));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Size get _size => (context.findRenderObject() as RenderBox?)?.size ?? MediaQuery.of(context).size;

  /// What letting go right now would do, ignoring velocity.
  String? _intent(Offset p) {
    final s = _size;
    if (_vertical && p.dy.abs() > p.dx.abs()) {
      if (widget.onSkip != null && p.dy < -s.height * 0.16) return 'skip';
      if (widget.onPullDown != null && p.dy > 70) return 'menu';
      return null;
    }
    if (p.dx > s.width * 0.28) return 'over';
    if (p.dx < -s.width * 0.28) return 'under';
    return null;
  }

  void _start(DragStartDetails d) {
    if (_busy) return;
    _c.stop();
    _grabTop = d.localPosition.dy < _size.height / 2;
    HapticFeedback.selectionClick();
    widget.onEngage?.call();
  }

  void _update(DragUpdateDetails d) {
    if (_busy) return;
    var delta = d.delta;
    if (!_vertical) delta = Offset(delta.dx, 0);
    // Pulling down is a gesture, not a throw: it gets heavier as it goes.
    if (_pos.dy + delta.dy > 0) delta = Offset(delta.dx, delta.dy * (1 / (1 + _pos.dy / 120)));
    setState(() => _pos += delta);
    final armed = _intent(_pos);
    if (armed != _armed) {
      armed == null ? HapticFeedback.selectionClick() : HapticFeedback.mediumImpact();
      _armed = armed;
    }
  }

  void _end(DragEndDetails d) {
    if (_busy) return;
    final v = d.velocity.pixelsPerSecond;
    _armed = null;
    final vertical = _vertical && _pos.dy.abs() > _pos.dx.abs();
    String? action = _intent(_pos);
    if (action == null) {
      if (vertical) {
        if (widget.onSkip != null && v.dy < -900) action = 'skip';
        if (widget.onPullDown != null && v.dy > 900) action = 'menu';
      } else if (v.dx > 900) {
        action = 'over';
      } else if (v.dx < -900) {
        action = 'under';
      }
    }
    if (action == 'menu') {
      HapticFeedback.lightImpact();
      widget.onPullDown?.call();
      _springHome(v);
    } else if (action != null) {
      _throw(action, v);
    } else {
      _springHome(v);
    }
  }

  void _springHome(Offset velocity) {
    _from = _pos;
    _to = Offset.zero;
    final dist = _pos.distance;
    final speed = dist == 0 ? 0.0 : -(velocity.dx * _pos.dx + velocity.dy * _pos.dy) / (dist * dist);
    _c.value = 0;
    _c.animateWith(SpringSimulation(const SpringDescription(mass: 1, stiffness: 420, damping: 28), 0, 1, speed));
  }

  /// Throws the card off screen, then reports [action]. Used by drags,
  /// buttons and keys so every path looks and feels the same.
  Future<void> fling(String action, [Offset velocity = Offset.zero]) => _throw(action, velocity);

  Future<void> _throw(String action, Offset velocity) async {
    if (_busy || !widget.enabled) return;
    _busy = true;
    widget.onEngage?.call();
    action == 'skip' ? HapticFeedback.lightImpact() : HapticFeedback.heavyImpact();
    final s = _size;
    final dir = switch (action) {
      'over' => const Offset(1, 0),
      'under' => const Offset(-1, 0),
      _ => const Offset(0, -1),
    };
    final far = math.max(s.width, s.height) * 1.4;
    // Keep some of the drift so the card leaves along the path it was thrown.
    final drift = dir.dx != 0 ? Offset(0, _pos.dy + velocity.dy * 0.08) : Offset(_pos.dx + velocity.dx * 0.08, 0);
    _from = _pos;
    _to = Offset(dir.dx * far, dir.dy * far) + drift;
    final speed = math.max(velocity.distance, 1600.0);
    final ms = (((_to - _from).distance / speed) * 1000).clamp(140, 260).round();
    _c.value = 0;
    await _c.animateTo(1, duration: Duration(milliseconds: ms), curve: Curves.easeIn);
    if (!mounted) return;
    if (action == 'skip') {
      widget.onSkip?.call();
    } else {
      widget.onSwipe(action);
    }
    if (mounted) {
      setState(() => _pos = Offset.zero);
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final px = (_pos.dx / (w * 0.28)).clamp(-1.0, 1.0);
    final py = _vertical && _pos.dy < 0 ? (-_pos.dy / (MediaQuery.of(context).size.height * 0.16)).clamp(0.0, 1.0) : 0.0;
    final upward = py > px.abs();
    final angle = (_pos.dx / w) * 0.32 * (_grabTop ? 1 : -1);
    return Focus(
      onKeyEvent: (_, e) {
        if (!widget.enabled || e is! KeyDownEvent) return KeyEventResult.ignored;
        final action = switch (e.logicalKey) {
          LogicalKeyboardKey.arrowRight => 'over',
          LogicalKeyboardKey.arrowLeft => 'under',
          LogicalKeyboardKey.arrowUp when widget.onSkip != null => 'skip',
          _ => null,
        };
        if (action == null) return KeyEventResult.ignored;
        fling(action);
        return KeyEventResult.handled;
      },
      child: GestureDetector(
        onPanStart: widget.enabled && _vertical ? _start : null,
        onPanUpdate: widget.enabled && _vertical ? _update : null,
        onPanEnd: widget.enabled && _vertical ? _end : null,
        onHorizontalDragStart: widget.enabled && !_vertical ? _start : null,
        onHorizontalDragUpdate: widget.enabled && !_vertical ? _update : null,
        onHorizontalDragEnd: widget.enabled && !_vertical ? _end : null,
        child: Transform.translate(
          offset: _pos,
          child: Transform.rotate(
            angle: angle,
            child: Stack(children: [
              widget.child,
              if (upward && py > 0.12)
                _stamp('SKIP', C.dim, py, 0, top: true)
              else if (px.abs() > 0.12)
                _stamp(px > 0 ? 'OVER' : 'UNDER', px > 0 ? const Color(0xFF2FA968) : const Color(0xFF8B6FE0), px.abs(), px > 0 ? -0.25 : 0.25,
                    left: px > 0),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _stamp(String text, Color color, double opacity, double angle, {bool left = false, bool top = false}) => Positioned(
        top: top ? null : 70,
        bottom: top ? 40 : null,
        left: top ? 0 : (left ? 22 : null),
        right: top ? 0 : (left ? null : 22),
        child: IgnorePointer(
          child: Opacity(
            opacity: opacity,
            child: Center(
              widthFactor: top ? null : 1,
              child: Transform.rotate(
                angle: angle,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), border: Border.all(color: color, width: 3)),
                  child: Text(text, style: TextStyle(fontFamily: kCondensed, fontWeight: FontWeight.w800, fontSize: 30, color: color)),
                ),
              ),
            ),
          ),
        ),
      );
}

/// The top card scaled to fill the available space (never cut off), with
/// the next card waiting behind it. When the top card is thrown, the next
/// one rises into place.
class CardStage extends StatelessWidget {
  const CardStage({
    super.key,
    required this.swipeKey,
    required this.topId,
    required this.top,
    this.next,
    required this.onSwipe,
    this.onSkip,
    this.onPullDown,
    this.onEngage,
    this.cardWidth = 340,
  });

  final GlobalKey<SwipeableState> swipeKey;
  final Object topId;
  final Widget top;
  final Widget? next;
  final void Function(String side) onSwipe;
  final VoidCallback? onSkip;
  final VoidCallback? onPullDown;
  final VoidCallback? onEngage;

  /// Width the card is laid out at before scaling to fit.
  final double cardWidth;

  Widget _fit(Widget card) => Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: cardWidth * 1.3),
          child: FittedBox(fit: BoxFit.contain, child: SizedBox(width: cardWidth, child: card)),
        ),
      );

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Stack(children: [
          if (next != null)
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: RepaintBoundary(
                    child: Transform.translate(
                      offset: const Offset(0, 14),
                      child: Transform.scale(scale: 0.92, child: Opacity(opacity: 0.45, child: _fit(next!))),
                    ),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: Swipeable(
              key: swipeKey,
              onSwipe: onSwipe,
              onSkip: onSkip,
              onPullDown: onPullDown,
              onEngage: onEngage,
              child: TweenAnimationBuilder<double>(
                key: ValueKey(topId),
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                child: RepaintBoundary(child: _fit(top)),
                builder: (context, t, child) => Transform.translate(
                  offset: Offset(0, 14 * (1 - t)),
                  child: Transform.scale(
                    scale: 0.92 + 0.08 * t,
                    child: Opacity(opacity: 0.45 + 0.55 * t, child: child),
                  ),
                ),
              ),
            ),
          ),
        ]),
      );
}

/// Round buttons under the card for people who'd rather tap. They throw the
/// card through [swipe] so taps animate and buzz like swipes.
class SwipeButtons extends StatelessWidget {
  const SwipeButtons({super.key, required this.swipe, this.hint, this.skipLabel = 'Skip'});
  final GlobalKey<SwipeableState> swipe;
  final String? hint;
  final String skipLabel;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (hint != null) ...[
            Text(hint!, style: const TextStyle(color: C.dim, fontSize: 13)),
            const SizedBox(height: 8),
          ],
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _RoundButton(label: 'Under', icon: Icons.arrow_back_rounded, color: C.under, onTap: () => swipe.currentState?.fling('under')),
            const SizedBox(width: 22),
            _RoundButton(label: skipLabel, icon: Icons.arrow_upward_rounded, color: C.dim, small: true, onTap: () => swipe.currentState?.fling('skip')),
            const SizedBox(width: 22),
            _RoundButton(label: 'Over', icon: Icons.arrow_forward_rounded, color: C.over, onTap: () => swipe.currentState?.fling('over')),
          ]),
        ]),
      );
}

class _RoundButton extends StatefulWidget {
  const _RoundButton({required this.label, required this.icon, required this.color, required this.onTap, this.small = false});
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool small;

  @override
  State<_RoundButton> createState() => _RoundButtonState();
}

class _RoundButtonState extends State<_RoundButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final size = widget.small ? 46.0 : 58.0;
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedScale(
            scale: _down ? 0.88 : 1,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: widget.color.withValues(alpha: 0.7), width: 1.5)),
              child: Icon(widget.icon, color: widget.color, size: widget.small ? 20 : 24),
            ),
          ),
          const SizedBox(height: 5),
          Text(widget.label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: widget.color)),
        ]),
      ),
    );
  }
}
