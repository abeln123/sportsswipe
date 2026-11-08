import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../screens/play/pack_feedback.dart';

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
    this.onHold,
    this.onPull,
    this.enabled = true,
    this.verticalDrag = true,
    this.overLabel = 'OVER',
    this.underLabel = 'UNDER',
  });

  /// Downward pull distance while dragging (0 when released or sideways).
  final ValueChanged<double>? onPull;

  /// Stamp text shown as the card leans right and left.
  final String overLabel;
  final String underLabel;

  final Widget child;
  final void Function(String side) onSwipe;
  final VoidCallback? onSkip;
  final VoidCallback? onPullDown;

  /// Called when a drag starts.
  final VoidCallback? onEngage;

  /// True while a finger is on the card.
  final ValueChanged<bool>? onHold;
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
    PackFeedback.instance.preload();
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
    widget.onHold?.call(true);
  }

  void _update(DragUpdateDetails d) {
    if (_busy) return;
    var delta = d.delta;
    if (!_vertical) delta = Offset(delta.dx, 0);
    // Pulling down is a gesture, not a throw: it gets heavier as it goes.
    if (_pos.dy + delta.dy > 0) delta = Offset(delta.dx, delta.dy * (1 / (1 + _pos.dy / 120)));
    setState(() => _pos += delta);
    widget.onPull?.call(_pos.dy > 0 && _pos.dy > _pos.dx.abs() ? _pos.dy : 0);
    final armed = _intent(_pos);
    if (armed != _armed) {
      // One light tap where letting go would commit; none when backing out.
      if (armed != null) HapticFeedback.lightImpact();
      _armed = armed;
    }
  }

  void _end(DragEndDetails d) {
    widget.onHold?.call(false);
    if (_busy) {
      widget.onPull?.call(0);
      return;
    }
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
    widget.onPull?.call(0);
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
    PackFeedback.instance.play('swoosh');
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
    await _c.animateTo(
      1,
      duration: Duration(milliseconds: ms),
      curve: Curves.easeIn,
    );
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
            child: Stack(
              children: [
                RepaintBoundary(child: widget.child),
                if (upward && py > 0.12)
                  _stamp('SKIP', C.dim, py, 0, top: true)
                else if (px.abs() > 0.12)
                  _stamp(
                    px > 0 ? widget.overLabel : widget.underLabel,
                    px > 0 ? const Color(0xFF2FA968) : const Color(0xFF8B6FE0),
                    px.abs(),
                    px > 0 ? -0.25 : 0.25,
                    left: px > 0,
                  ),
              ],
            ),
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
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                border: Border.all(color: color, width: 3),
              ),
              child: Text(
                text,
                style: TextStyle(fontFamily: kCondensed, fontWeight: FontWeight.w800, fontSize: 30, color: color),
              ),
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
class CardStage extends StatefulWidget {
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
    this.onPull,
    this.coach = false,
    this.cardWidth = 340,
    this.overLabel = 'OVER',
    this.underLabel = 'UNDER',
  });

  final ValueChanged<double>? onPull;
  final String overLabel;
  final String underLabel;
  final GlobalKey<SwipeableState> swipeKey;
  final Object topId;
  final Widget top;
  final Widget? next;
  final void Function(String side) onSwipe;
  final VoidCallback? onSkip;
  final VoidCallback? onPullDown;
  final VoidCallback? onEngage;

  /// Shows the first-run "how to play" overlay on top of the card.
  final bool coach;

  /// Width the card is laid out at before scaling to fit.
  final double cardWidth;

  @override
  State<CardStage> createState() => _CardStageState();
}

class _CardStageState extends State<CardStage> {
  bool _held = false;

  Widget _fit(Widget card) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.cardWidth * 1.3),
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(width: widget.cardWidth, child: card),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.of(context).disableAnimations;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Stack(
        children: [
          if (widget.next != null)
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: RepaintBoundary(
                    child: Transform.translate(
                      offset: const Offset(0, 14),
                      child: Transform.scale(scale: 0.92, child: Opacity(opacity: 0.45, child: _fit(widget.next!))),
                    ),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: Swipeable(
              key: widget.swipeKey,
              onSwipe: widget.onSwipe,
              onSkip: widget.onSkip,
              onPullDown: widget.onPullDown,
              onEngage: widget.onEngage,
              onPull: widget.onPull,
              overLabel: widget.overLabel,
              underLabel: widget.underLabel,
              onHold: (h) {
                if (h != _held) setState(() => _held = h);
              },
              child: TweenAnimationBuilder<double>(
                key: ValueKey(widget.topId),
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                child: RepaintBoundary(child: _fit(widget.top)),
                builder: (context, t, child) => still
                    ? Opacity(opacity: t, child: child)
                    : Transform.translate(
                        offset: Offset(0, 14 * (1 - t)),
                        child: Transform.scale(
                          scale: 0.92 + 0.08 * t,
                          child: Opacity(opacity: 0.45 + 0.55 * t, child: child),
                        ),
                      ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: widget.coach && !_held ? 1 : 0,
                duration: Duration(milliseconds: widget.coach && !_held ? 260 : 140),
                curve: Curves.easeOut,
                child: widget.coach ? SwipeCoachOverlay(skip: widget.onSkip != null) : const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// First-run tutorial drawn over the card. It never takes touches, so the
/// first real swipe goes straight to the card underneath.
class SwipeCoachOverlay extends StatefulWidget {
  const SwipeCoachOverlay({super.key, this.skip = true});
  final bool skip;

  @override
  State<SwipeCoachOverlay> createState() => _SwipeCoachOverlayState();
}

class _SwipeCoachOverlayState extends State<SwipeCoachOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 4200))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  List<(String, String, IconData, Color, Offset)> get _moves => [
    ('Swipe right', 'Over', Icons.arrow_forward_rounded, C.over, const Offset(1, 0)),
    ('Swipe left', 'Under', Icons.arrow_back_rounded, C.under, const Offset(-1, 0)),
    if (widget.skip) ('Swipe up', 'Skip', Icons.arrow_upward_rounded, C.dim, const Offset(0, -1)),
  ];

  @override
  Widget build(BuildContext context) {
    final moves = _moves;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [C.bg.withValues(alpha: 0.9), C.bg.withValues(alpha: 0.97)],
        ),
      ),
      child: Center(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final phase = _c.value * moves.length;
            final i = phase.floor() % moves.length;
            final t = phase - phase.floor();
            // Each beat: rest, glide out, hold, fade back.
            final out = Curves.easeInOutCubic.transform(((t - 0.12) / 0.45).clamp(0.0, 1.0));
            final back = ((t - 0.8) / 0.2).clamp(0.0, 1.0);
            final move = moves[i];
            final offset = move.$5 * 34 * out;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 130,
                  width: 200,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Opacity(
                        opacity: 1 - back,
                        child: Transform.translate(
                          offset: offset,
                          child: Transform.rotate(
                            angle: move.$5.dx * 0.18 * out,
                            child: Container(
                              width: 62,
                              height: 86,
                              decoration: BoxDecoration(
                                color: const Color(0xFFF2F4F6),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Color.lerp(Colors.white, move.$4, out)!, width: 2),
                                boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 6))],
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(width: 30, height: 4, color: const Color(0xFFCBD3DB)),
                                  const SizedBox(height: 6),
                                  Container(width: 40, height: 4, color: const Color(0xFFCBD3DB)),
                                  const SizedBox(height: 6),
                                  Container(width: 22, height: 4, color: const Color(0xFFCBD3DB)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Opacity(
                        opacity: 1 - back,
                        child: Transform.translate(
                          offset: offset + const Offset(14, 34),
                          child: const Icon(Icons.touch_app_rounded, color: Colors.white, size: 34),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'How to play',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: C.text),
                ),
                const SizedBox(height: 18),
                for (final (k, m) in moves.indexed) _row(m.$1, m.$2, m.$3, m.$4, k == i),
                const SizedBox(height: 14),
                const Text('Pull down anytime for the menu.', style: TextStyle(fontSize: 12.5, color: C.dim)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _row(String gesture, String result, IconData icon, Color color, bool active) => AnimatedContainer(
    duration: const Duration(milliseconds: 220),
    curve: Curves.easeOut,
    width: 240,
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: active ? color.withValues(alpha: 0.14) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: active ? color.withValues(alpha: 0.6) : C.line),
    ),
    child: Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 12),
        Text(
          gesture,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: C.text),
        ),
        const Spacer(),
        Text(
          result,
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color),
        ),
      ],
    ),
  );
}
