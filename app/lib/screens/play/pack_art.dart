import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show listEquals;

import '../../core/theme.dart';
import 'pack_feedback.dart';

Color hexColor(String hex) => Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));

List<Color> foilColors(List<dynamic>? foil) {
  final c = (foil ?? const []).map((e) => hexColor(e.toString())).toList();
  if (c.isEmpty) return const [Color(0xFF2E6B57), Color(0xFF9FD8C0)];
  if (c.length == 1) return [c[0], Color.lerp(c[0], Colors.white, 0.45)!];
  return c;
}

/// Shared dimensions keep the shelf, purchase sheet, and opening aligned.
const foilPackHeightRatio = 1.64;

/// Printed foil over a small card stack, lit as a shaped surface.
class FoilPack extends StatelessWidget {
  const FoilPack({
    super.key,
    required this.name,
    required this.colors,
    this.badge,
    this.caption,
    this.width = 150,
    this.sheen = .4,
    this.tension = 0,
  });
  final String name;
  final List<Color> colors;
  final String? badge, caption;
  final double width, sheen, tension;

  @override
  Widget build(BuildContext context) {
    final premium = badge != null || name.toLowerCase().contains('presentation') || RegExp(r'^\d+[x×]\b',caseSensitive:false).hasMatch(name);
    final palette = premium ? const [Color(0xFF181C20), Color(0xFF343A40)] : colors;
    final base = Color.lerp(palette.first, palette.last, .38)!;
    final ink = premium
        ? const Color(0xFFE9DCA7)
        : base.computeLuminance() > .48
        ? const Color(0xFF182426)
        : const Color(0xFFF6F3E7);
    final h = width * foilPackHeightRatio;
    final title = name.replaceFirst(RegExp(r'\s+pack$', caseSensitive: false), '\nPack');
    return RepaintBoundary(child: SizedBox(
      width: width,
      height: h,
      child: CustomPaint(
        isComplex: true,
        willChange: tension != 0,
        painter: _FoilPainter(palette, sheen, tension),
        child: Padding(
          padding: EdgeInsets.fromLTRB(width * .15, h * .17, width * .13, h * .14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SPORTS\nSWIPE',
                style: TextStyle(
                  fontSize: width * .066,
                  height: 1.02,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .25,
                  color: ink.withValues(alpha: .88),
                ),
              ),
              const Spacer(flex: 3),
              Text(
                title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: width * .205,
                  height: .98,
                  letterSpacing: -width * .006,
                  fontWeight: FontWeight.w500,
                  color: ink,
                ),
              ),
              if (badge != null && !name.toLowerCase().contains(badge!.toLowerCase()))
                Padding(
                  padding: EdgeInsets.only(top: width * .07),
                  child: Text(
                    badge!.toUpperCase(),
                    style: TextStyle(fontSize: width * .095, fontWeight: FontWeight.w600, color: ink),
                  ),
                ),
              const Spacer(flex: 2),
              Text(
                (caption ?? '5 cards per pack').toUpperCase(),
                style: TextStyle(fontSize: width * .052, letterSpacing: .6, color: ink.withValues(alpha: .85)),
              ),
            ],
          ),
        ),
      ),
    ));
  }
}

Path _foilOutline(Size s, double tension) {
  final w = s.width, h = s.height;
  final p = Path()..moveTo(w * .035, h * .006);
  const teeth = 36;
  for (var i = 0; i <= teeth; i++) {
    final x = w * (.035 + .93 * i / teeth);
    p.lineTo(x, h * (i.isEven ? .005 : .009));
  }
  p.lineTo(w * .965, h * .085);
  p.cubicTo(w * .93, h * .17, w * .935, h * .24, w * .93, h * .34);
  p.cubicTo(w * (.91 - tension * .012), h * .55, w * .925, h * .77, w * .965, h * .915);
  p.lineTo(w * .968, h * .991);
  for (var i = teeth; i >= 0; i--) {
    p.lineTo(w * (.035 + .933 * i / teeth), h * (i.isEven ? .995 : .991));
  }
  p.lineTo(w * .035, h * .915);
  p.cubicTo(w * .075, h * .77, w * (.09 + tension * .012), h * .55, w * .07, h * .34);
  p.cubicTo(w * .065, h * .24, w * .07, h * .17, w * .035, h * .085);
  return p..close();
}

class _FoilPainter extends CustomPainter {
  _FoilPainter(this.colors, this.sheen, this.tension);
  final List<Color> colors;
  final double sheen, tension;
  @override
  void paint(Canvas c, Size s) {
    final w = s.width, h = s.height, rect = Offset.zero & s;
    final shape = _foilOutline(s, tension);
    final base = Color.lerp(colors.first, colors.last, .38)!;
    Color shade(double amount) => Color.lerp(base, amount < 0 ? Colors.black : Colors.white, amount.abs())!;
    c.drawShadow(shape, Colors.black.withValues(alpha: .75), w * .025, false);
    c.drawPath(
      shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [shade(-.55), shade(.17), shade(-.16), shade(.06), shade(.13), shade(-.06), shade(-.48), shade(.33), shade(-.36)],
          stops: const [0, .052, .085, .23, .52, .82, .927, .95, 1],
        ).createShader(rect),
    );
    c.save();
    c.clipPath(shape);
    void glow(Offset center, double rx, double ry, Color color) {
      c.save();
      c.translate(center.dx, center.dy);
      c.scale(rx, ry);
      c.drawCircle(
        Offset.zero,
        1,
        Paint()
          ..shader = RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
            stops: const [0, 1],
          ).createShader(const Rect.fromLTWH(-1, -1, 2, 2)),
      );
      c.restore();
    }

    // Broad, soft reflection on taut foil. Its ends bend into the shoulders.
    glow(Offset(w * (.36 + sheen * .13), h * .49), w * .62, h * .59, Colors.white.withValues(alpha: .21));
    glow(Offset(w * .73, h * .11), w * .31, h * .12, Colors.white.withValues(alpha: .23));
    glow(Offset(w * .20, h * .15), w * .18, h * .09, Colors.black.withValues(alpha: .25));
    glow(Offset(w * .51, h * .92), w * .43, h * .12, Colors.black.withValues(alpha: .30));
    glow(Offset(w * .57, h * .08), w * .12, h * .15, Colors.black.withValues(alpha: .17));
    // Curved side highlights narrow toward the pinched waist.
    for (final right in [false, true]) {
      c.save();
      if (right) {
        c.translate(w, 0);
        c.scale(-1, 1);
      }
      final edge = Path()
        ..moveTo(w * .043, h * .085)
        ..cubicTo(w * .091, h * .27, w * .098, h * .67, w * .05, h * .91);
      c.drawPath(
        edge,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * .025
          ..color = Colors.black.withValues(alpha: .30)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * .016),
      );
      c.drawPath(
        edge.shift(Offset(w * .009, 0)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * .008
          ..color = Colors.white.withValues(alpha: .55)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * .004),
      );
      c.restore();
    }
    // A few shoulder folds; a smooth face leaves the printed title readable.
    for (final f in [
      (.045, .09, .27, .14, .36, .105),
      (.96, .088, .81, .19, .61, .115),
      (.04, .915, .23, .85, .38, .912),
      (.96, .915, .78, .83, .63, .915),
    ]) {
      final crease = Path()
        ..moveTo(w * f.$1, h * f.$2)
        ..quadraticBezierTo(w * f.$3, h * (f.$4 + tension * .012), w * f.$5, h * f.$6);
      c.drawPath(
        crease,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * .024
          ..color = Colors.black.withValues(alpha: .18)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * .012),
      );
      c.drawPath(
        crease.shift(Offset(0, -h * .004)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * .009
          ..color = Colors.white.withValues(alpha: .19)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * .007),
      );
    }
    // Fine gathers die out as they leave each pressed seal.
    for (var i = 0; i < 15; i++) {
      final x = w * (.1 + i * .057);
      for (final bottom in [false, true]) {
        c.save();
        if (bottom) {
          c.translate(0, h);
          c.scale(1, -1);
        }
        final gather = Path()
          ..moveTo(x, h * .075)
          ..quadraticBezierTo(x + w * .015, h * .103, x + w * .01, h * (.13 + math.sin(i * 2.3) * .018));
        c.drawPath(
          gather,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = w * .009
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withValues(alpha: .19), Colors.transparent],
            ).createShader(Rect.fromLTWH(0, h * .075, w, h * .08))
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * .006),
        );
        c.restore();
      }
    }
    // The reference packs have horizontal heat-press ridges, not a flat band.
    for (final bottom in [false, true]) {
      c.save();
      if (bottom) {
        c.translate(0, h);
        c.scale(1, -1);
      }
      c.drawRect(
        Rect.fromLTWH(0, 0, w, h * .081),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [shade(.12), shade(.19), shade(-.24), shade(.08), shade(.18), shade(-.20), shade(.13), shade(-.30)],
            stops: const [0, .18, .27, .39, .51, .64, .83, 1],
          ).createShader(Rect.fromLTWH(0, 0, w, h * .081)),
      );
      for (final y in [.018, .041, .066]) {
        c.drawLine(
          Offset(w * .03, h * y),
          Offset(w * .97, h * y),
          Paint()
            ..strokeWidth = h * .0016
            ..color = Colors.white.withValues(alpha: .26),
        );
      }
      // A subtle center registration crease continues through the pressed foil.
      c.drawRect(
        Rect.fromLTWH(w * .49, 0, w * .035, h * .082),
        Paint()
          ..shader = LinearGradient(
            colors: [Colors.transparent, Colors.black.withValues(alpha: .12), Colors.white.withValues(alpha: .12), Colors.transparent],
          ).createShader(Rect.fromLTWH(w * .49, 0, w * .035, h * .082)),
      );
      c.restore();
    }
    c.restore();
  }

  @override
  bool shouldRepaint(_FoilPainter old) => old.sheen != sheen || old.tension != tension || !listEquals(old.colors, colors);
}

/// The back of a Sports Swipe card.
class CardBack extends StatelessWidget {
  const CardBack({super.key, this.width = 200, this.lift = 0});
  final double width, lift;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: width * 1.4,
    padding: const EdgeInsets.all(1.3),
    decoration: BoxDecoration(
      gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFF2EBD9), Color(0xFF746E5F)]),
      borderRadius: BorderRadius.circular(width * 0.05),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: .5 - lift * .15),
          blurRadius: 2 + lift * 12,
          offset: Offset(1 + lift * 3, 2 + lift * 9),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(width * 0.03),
      child: CustomPaint(
        painter: _BackPainter(lift),
        child: Center(
          child: Text(
            'SS',
            style: TextStyle(
              fontFamily: kCondensed,
              fontWeight: FontWeight.w800,
              fontSize: width * 0.3,
              color: Colors.white.withValues(alpha: 0.9),
              letterSpacing: -1,
            ),
          ),
        ),
      ),
    ),
  );
}

class _BackPainter extends CustomPainter {
  const _BackPainter(this.lift);
  final double lift;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF12302A));
    canvas.drawRRect(
      RRect.fromRectAndRadius((Offset.zero & size).deflate(size.width * .045), const Radius.circular(5)),
      Paint()
        ..color = const Color(0xFFDDD6C3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8,
    );
    final p = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.white.withValues(alpha: .04),
          Colors.white.withValues(alpha: .10 + lift * .22),
          Colors.white.withValues(alpha: .03),
        ],
      ).createShader(Offset.zero & size);
    for (final (x, t) in [(0.9, 0.5), (1.2, 0.25), (0.3, 0.18)]) {
      canvas.save();
      canvas.translate(size.width * x, size.height * 0.25);
      canvas.rotate(-0.62);
      canvas.drawRect(Rect.fromLTWH(-size.width * 2, -size.width * t / 2, size.width * 4, size.width * t), p);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_BackPainter old) => old.lift != lift;
}

/// A cut anchored in pack coordinates. Positive x/y follow the actual swipe;
/// scaling the pack keeps its cut and its clipped foil pieces aligned.
@immutable
class PackTear {
  const PackTear({required this.origin, required this.direction});
  final Offset origin, direction;
  Offset anchor(Size size) => Offset(origin.dx * size.width, origin.dy * size.height);
  Offset unit(Size size) {
    final d = Offset(direction.dx * size.width, direction.dy * size.height);
    return d.distance < .001 ? const Offset(1, 0) : d / d.distance;
  }

  (double, double) limits(Size size) {
    final a = anchor(size), u = unit(size);
    var lo = double.negativeInfinity, hi = double.infinity;
    for (final (v, d, edge) in [(a.dx, u.dx, size.width), (a.dy, u.dy, size.height)]) {
      if (d.abs() < .00001) continue;
      final t1 = -v / d, t2 = (edge - v) / d;
      lo = math.max(lo, math.min(t1, t2));
      hi = math.min(hi, math.max(t1, t2));
    }
    return (lo, hi);
  }

  Offset normal(Size size) {
    final u = unit(size);
    return Offset(-u.dy, u.dx);
  }

  double peelSign(Size size) {
    final center = Offset(size.width / 2, size.height / 2) - anchor(size), n = normal(size);
    return center.dx * n.dx + center.dy * n.dy >= 0 ? -1 : 1;
  }

  Path half(Size size, {required bool peeled}) {
    final a = anchor(size), n = normal(size) * peelSign(size) * (peeled ? 1 : -1);
    double side(Offset p) => (p - a).dx * n.dx + (p - a).dy * n.dy;
    final rect = [Offset.zero, Offset(size.width, 0), Offset(size.width, size.height), Offset(0, size.height)];
    final points = <Offset>[];
    for (var i = 0; i < rect.length; i++) {
      final p = rect[i], q = rect[(i + 1) % rect.length], dp = side(p), dq = side(q);
      if (dp >= 0) points.add(p);
      if ((dp >= 0) != (dq >= 0)) points.add(p + (q - p) * (dp / (dp - dq)));
    }
    if (points.isEmpty) return Path();
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 0; i < points.length; i++) {
      final p = points[i], q = points[(i + 1) % points.length];
      if (side(p).abs() < .01 && side(q).abs() < .01) {
        final count = ((q - p).distance / 3).ceil().clamp(1, 200);
        for (var j = 1; j < count; j++) {
          final v = Offset.lerp(p, q, j / count)!;
          final ragged = normal(size) * (math.sin(v.dx * .73 + v.dy * .51) * .7);
          path.lineTo(v.dx + ragged.dx, v.dy + ragged.dy);
        }
      }
      path.lineTo(q.dx, q.dy);
    }
    return path..close();
  }
}

/// Grip, directional tear, extraction and square-up. The drag is measured in
/// the same coordinate system used to paint the foil; no fixed top/right cut.
class PackOpening extends StatefulWidget {
  const PackOpening({super.key, required this.pack, required this.count, required this.onDone});
  final FoilPack pack;
  final int count;
  final VoidCallback onDone;
  @override
  State<PackOpening> createState() => _PackOpeningState();
}

class _PackOpeningState extends State<PackOpening> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800));
  PackTear _cut = const PackTear(origin: Offset(.06, .11), direction: Offset(1, 0));
  Offset? _down;
  bool _ripped = false, _squared = false, _brushed = false, _done = false, _dragging = false, _hasSwipe = false;
  bool _haptics = PackFeedback.instance.haptics;
  double _grip = 0, _dragLength = 0, _releaseValue = 0;
  @override
  void initState() {
    super.initState();
    _c.addListener(() {
      if (!_ripped && _c.value >= .18) {
        _ripped = true;
        if (_haptics) HapticFeedback.mediumImpact();
        PackFeedback.instance.play('tear');
      }
      if (!_brushed && _c.value >= .63) {
        _brushed = true;
        PackFeedback.instance.play('brush');
      }
      if (!_squared && _c.value >= .94) {
        _squared = true;
        if (_haptics) HapticFeedback.lightImpact();
        PackFeedback.instance.play('square');
      }
    });
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) _finish();
    });
  }

  @override
  void dispose() {
    PackFeedback.instance.stop();
    _c.dispose();
    super.dispose();
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _c.stop();
    PackFeedback.instance.stop();
    widget.onDone();
  }

  void _open() {
    if (_done) return;
    if (MediaQuery.of(context).disableAnimations) {
      _finish();
      return;
    }
    if (!_hasSwipe) _cut = const PackTear(origin: Offset(.06, .11), direction: Offset(1, 0));
    if (_c.value == 0) PackFeedback.instance.play('grip');
    _c.forward();
  }

  void _cancelGrip() {
    if (_done || !_hasSwipe) return;
    setState(() {
      _releaseValue = _c.value;
      _dragging = false;
      _grip = 0;
    });
    _down = null;
    if (_ripped) {
      _open();
    } else {
      _hasSwipe = false;
      _c.reverse();
    }
  }

  double _seg(double a, double b) => Curves.easeInOutCubic.transform(((_c.value - a) / (b - a)).clamp(0.0, 1.0));
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: LayoutBuilder(
          builder: (context, box) {
            final w = math.min(box.maxWidth * .62, 240.0), h = w * foilPackHeightRatio;
            final rect = Rect.fromCenter(center: Offset(box.maxWidth / 2, box.maxHeight / 2), width: w, height: h);
            Offset normalized(Offset p) => Offset(((p.dx - rect.left) / w).clamp(.01, .99), ((p.dy - rect.top) / h).clamp(.01, .99));
            return Semantics(
              label: 'Swipe across the pack to tear it, or tap to open.',
              button: true,
              child: Listener(
                onPointerCancel: (_) => _cancelGrip(),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) {
                    if (rect.contains(d.localPosition)) _open();
                  },
                  onPanDown: (d) {
                    if (_done || _c.value > .30) return;
                    _down = rect.contains(d.localPosition) ? d.localPosition : null;
                  },
                  onPanStart: (d) {
                    if (_down == null || _done || _c.value > .30) return;
                    if (MediaQuery.of(context).disableAnimations) return;
                    _c.stop();
                    setState(() {
                      _dragging = true;
                      _grip = 1;
                      _hasSwipe = true;
                      _dragLength = 0;
                      _cut = PackTear(origin: normalized(_down!), direction: const Offset(1, 0));
                    });
                    PackFeedback.instance.play('grip');
                  },
                  onPanUpdate: (d) {
                    if (!_dragging || _down == null || MediaQuery.of(context).disableAnimations) return;
                    final delta = d.localPosition - _down!;
                    if (delta.distance < 4) return;
                    setState(() {
                      _dragLength = delta.distance;
                      _cut = PackTear(origin: normalized(_down!), direction: Offset(delta.dx / w, delta.dy / h));
                    });
                    final next = (delta.distance / w * .7).clamp(0.0, .30);
                    _c.value = _ripped ? math.max(_c.value, next) : next;
                  },
                  onPanEnd: (_) {
                    if (_down == null) return;
                    setState(() {
                      _releaseValue = _c.value;
                      _dragging = false;
                      _grip = 0;
                    });
                    _down = null;
                    _open();
                  },
                  onPanCancel: () {
                    if (!_dragging) return;
                    setState(() {
                      _releaseValue = _c.value;
                      _dragging = false;
                      _grip = 0;
                    });
                    _down = null;
                    if (_ripped) {
                      _open();
                    } else {
                      _hasSwipe = false;
                      _c.reverse();
                    }
                  },
                  child: SizedBox.expand(
                    child: AnimatedBuilder(animation: _c, builder: (_, _) => _sequence(w, box)),
                  ),
                ),
              ),
            );
          },
        ),
      ),
      const Text('Swipe anywhere to rip · Tap to open', style: T.small),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton(onPressed: _finish, child: const Text('Quick reveal')),
          IconButton(
            tooltip: PackFeedback.instance.sound ? 'Mute pack sounds' : 'Enable pack sounds',
            onPressed: () {
              setState(() => PackFeedback.instance.sound = !PackFeedback.instance.sound);
              PackFeedback.instance.save();
            },
            icon: Icon(PackFeedback.instance.sound ? Icons.volume_up_outlined : Icons.volume_off_outlined, size: 19, color: C.dim),
          ),
          IconButton(
            tooltip: _haptics ? 'Turn haptics off' : 'Turn haptics on',
            onPressed: () {
              setState(() => _haptics = !_haptics);
              PackFeedback.instance.haptics = _haptics;
              PackFeedback.instance.save();
            },
            icon: Icon(_haptics ? Icons.vibration : Icons.phone_android, size: 19, color: C.dim),
          ),
        ],
      ),
    ],
  );
  Widget _sequence(double w, BoxConstraints box) {
    final h = w * foilPackHeightRatio, size = Size(w, h);
    final tear = _seg(.18, .38), separate = _seg(.30, .46), extract = _seg(.38, .61), drop = _seg(.49, .68);
    final square = _seg(.82, .96), flip = _seg(.96, 1), tension = (_seg(0, .18) + _grip * .25).clamp(0.0, 1.0) * (1 - separate);
    final outward = _cut.normal(size) * _cut.peelSign(size);
    final u = _cut.unit(size);
    final bodyOffset = -outward * drop * math.max(box.maxHeight * .65, h);
    final peelOffset = outward * separate * h * .27 + u * separate * w * .06;
    final art = FoilPack(
      name: widget.pack.name,
      colors: widget.pack.colors,
      badge: widget.pack.badge,
      caption: widget.pack.caption,
      width: w,
      sheen: .4 + tension * .16,
      tension: tension,
    );
    final extent = _cut.limits(size);
    final anchor = _cut.anchor(size);
    final completion = _hasSwipe ? Curves.easeOut.transform(((_c.value - _releaseValue) / (.40 - _releaseValue)).clamp(0.0, 1.0)) : tear;
    final from = _dragging ? anchor : anchor + u * extent.$1 * completion;
    final to = _dragging
        ? anchor + u * math.min(_dragLength, extent.$2)
        : anchor +
              u *
                  (_hasSwipe
                      ? (math.min(_dragLength, extent.$2) + (extent.$2 - math.min(_dragLength, extent.$2)) * completion)
                      : extent.$2 * (tear * 1.4).clamp(0.0, 1.0));
    Widget piece(bool peeled) => ClipPath(clipper: _TornHalf(_cut, peeled), child: art);
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        // The cards remain one squared stack until the wrapper releases them.
        for (var i = 0; i < widget.count; i++)
          Builder(
            builder: (_) {
              final peel = _seg(.62 + i * .018, .74 + i * .018) * (1 - square);
              return Opacity(
                opacity: _seg(.30, .47),
                child: Transform.translate(
                  offset: outward * (math.sin(extract * math.pi) * w * .16) + Offset(0, -(widget.count - i - 1) * 2.2),
                  child: Transform.rotate(
                    angle: (i - (widget.count - 1) / 2) * .115 * peel,
                    alignment: Alignment.bottomCenter,
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, .001)
                        ..rotateY(flip * math.pi / 2),
                      child: CardBack(width: w * .87, lift: peel),
                    ),
                  ),
                ),
              );
            },
          ),
        // Before separation, one continuous wrap shows the actual drawn tear.
        if (separate == 0)
          Transform.rotate(angle: -.018 * tension * u.dx, child: art)
        else ...[
          Transform.translate(
            offset: bodyOffset,
            child: Opacity(opacity: 1 - drop, child: piece(false)),
          ),
          Transform.translate(
            offset: peelOffset,
            child: Opacity(opacity: 1 - drop, child: piece(true)),
          ),
        ],
        if (tear > 0 && drop < 1)
          Transform.translate(
            offset: peelOffset,
            child: Opacity(
              opacity: (1 - drop) * tear,
              child: CustomPaint(
                size: size,
                painter: FoilTearPainter(start: from, end: to, outward: outward, curl: separate),
              ),
            ),
          ),
      ],
    );
  }
}

class _TornHalf extends CustomClipper<Path> {
  _TornHalf(this.cut, this.peeled);
  final PackTear cut;
  final bool peeled;
  @override
  Path getClip(Size size) => cut.half(size, peeled: peeled);
  @override
  bool shouldReclip(_TornHalf old) => old.cut != cut || old.peeled != peeled;
}

/// A silver reverse face follows the torn edge at the user's angle.
class FoilTearPainter extends CustomPainter {
  FoilTearPainter({required this.start, required this.end, required this.outward, required this.curl});
  final Offset start, end, outward;
  final double curl;
  @override
  void paint(Canvas c, Size size) {
    final length = (end - start).distance;
    if (length < 1) return;
    final points = <Offset>[];
    final n = (length / 3).ceil().clamp(2, 200);
    for (var i = 0; i <= n; i++) {
      final p = Offset.lerp(start, end, i / n)!;
      points.add(p + outward * (math.sin(p.dx * .73 + p.dy * .51) * .7));
    }
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    c.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..color = const Color(0xFF101612),
    );
    final silver = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      silver.lineTo(p.dx, p.dy);
    }
    for (var i = points.length - 1; i >= 0; i--) {
      final p = points[i] + outward * (2 + curl * size.width * .045) * (.35 + .65 * math.sin(i / n * math.pi));
      silver.lineTo(p.dx, p.dy);
    }
    silver.close();
    final mid = Offset.lerp(start, end, .5)!, radius = 3 + curl * size.width * .05;
    c.drawPath(
      silver,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment(-outward.dx, -outward.dy),
          end: Alignment(outward.dx, outward.dy),
          colors: const [Color(0xFF727F86), Color(0xFFF9FBF4), Color(0xFF9DABB0), Color(0xFFE5ECE9)],
          stops: const [0, .32, .7, 1],
        ).createShader(Rect.fromCircle(center: mid, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(FoilTearPainter old) => old.start != start || old.end != end || old.outward != outward || old.curl != curl;
}
