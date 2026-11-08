import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import 'pack_feedback.dart';

Color hexColor(String hex) => Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));

List<Color> foilColors(List<dynamic>? foil) {
  final c = (foil ?? const []).map((e) => hexColor(e.toString())).toList();
  if (c.isEmpty) return const [Color(0xFF2E6B57), Color(0xFF9FD8C0)];
  if (c.length == 1) return [c[0], Color.lerp(c[0], Colors.white, 0.45)!];
  return c;
}

/// A sealed foil pack: crimped ends, a printed band and a diagonal sheen.
class FoilPack extends StatelessWidget {
  const FoilPack({
    super.key,
    required this.name,
    required this.colors,
    this.badge,
    this.caption,
    this.width = 150,
    this.sheen = 0.4,
    this.tension = 0,
  });

  final String name;
  final List<Color> colors;

  /// Large mark on the pack face, e.g. "3X".
  final String? badge;

  /// Small print under the name, e.g. "5 CARDS".
  final String? caption;
  final double width;

  /// 0..1 position of the light sweep across the foil.
  final double sheen;
  final double tension;

  @override
  Widget build(BuildContext context) {
    final h = width * 1.42;
    return SizedBox(
      width: width,
      height: h,
      child: CustomPaint(
        painter: _FoilPainter(colors, sheen, tension),
        child: Padding(
          padding: EdgeInsets.fromLTRB(width * 0.1, h * 0.16, width * 0.1, h * 0.12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SPORTS SWIPE',
                style: TextStyle(
                  fontFamily: kCondensed,
                  fontWeight: FontWeight.w800,
                  fontSize: width * 0.075,
                  letterSpacing: 1.6,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              const Spacer(),
              if (badge != null)
                Text(
                  badge!,
                  style: TextStyle(
                    fontFamily: kCondensed,
                    fontWeight: FontWeight.w800,
                    fontSize: width * 0.34,
                    height: 0.9,
                    color: Colors.white,
                    shadows: const [Shadow(color: Colors.black26, blurRadius: 8)],
                  ),
                ),
              Text(
                name.toUpperCase(),
                maxLines: 2,
                style: TextStyle(
                  fontFamily: kCondensed,
                  fontWeight: FontWeight.w800,
                  fontSize: width * 0.15,
                  height: 0.95,
                  color: Colors.white,
                  shadows: const [Shadow(color: Colors.black38, blurRadius: 6)],
                ),
              ),
              if (caption != null) ...[
                SizedBox(height: width * 0.03),
                Text(
                  caption!.toUpperCase(),
                  style: TextStyle(
                    fontSize: width * 0.06,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Crimp line height as a share of the pack height.
const _crimp = 0.07;

Path _crimped(Size s, {double top = 0, double? bottom, double tension = 0}) {
  final w = s.width, h = bottom ?? s.height;
  final p = Path()..moveTo(w * .06, top + 3);
  for (var i = 0; i < 18; i++) {
    final x = w * (.06 + .88 * i / 18);
    p.lineTo(x, top + (i.isEven ? 0 : 3) + i * .12 - tension * i * .7);
  }
  p.lineTo(w * .94, h * .07);
  p.lineTo(w * .90, h * .085); // tear notch
  p.lineTo(w * .94, h * .10);
  p.cubicTo(w * .99, h * .28, w, h * .72, w * .93, h * .91);
  p.lineTo(w * .95, h - 4);
  for (var i = 18; i >= 0; i--) {
    p.lineTo(w * (.05 + .90 * i / 18), h - (i.isEven ? 1 : 4));
  }
  p.lineTo(w * .07, h * .91);
  p.cubicTo(0, h * .70, w * .015, h * .29, w * .065, h * .09);
  return p..close();
}

class _FoilPainter extends CustomPainter {
  _FoilPainter(this.colors, this.sheen, this.tension);
  final List<Color> colors;
  final double sheen, tension;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final body = _crimped(size, tension: tension);
    canvas.drawShadow(body, Colors.black, 10, false);
    canvas.drawPath(
      body,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.first, colors.last, colors.first],
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );
    canvas.save();
    canvas.clipPath(body);
    // Two cropped diagonal cuts, echoing the table behind the cards.
    final cut = Paint()..color = Colors.white.withValues(alpha: 0.10);
    for (final (x, t) in [(0.78, 0.42), (1.05, 0.22)]) {
      canvas.save();
      canvas.translate(size.width * x, size.height * 0.2);
      canvas.rotate(-0.62);
      canvas.drawRect(Rect.fromLTWH(-size.width * 2, -size.width * t / 2, size.width * 4, size.width * t), cut);
      canvas.restore();
    }
    // A reflection follows the shoulder folds, then broadens on taut foil.
    final w = size.width, h = size.height;
    final x = w * (.28 + sheen * .26);
    final light = Path()
      ..moveTo(x - w * .14, 0)
      ..lineTo(x + w * .03, h * .10)
      ..lineTo(x - w * .08, h * .19)
      ..cubicTo(x + w * .25, h * .38, x + w * .24, h * .70, x + w * .12, h * .88)
      ..lineTo(x + w * .22, h)
      ..lineTo(x - w * .03, h)
      ..lineTo(x - w * .12, h * .88)
      ..cubicTo(x + w * .07, h * .66, x + w * .02, h * .36, x - w * .20, h * .19)
      ..close();
    canvas.drawPath(
      light,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: .36), Colors.white.withValues(alpha: .02)],
        ).createShader(Rect.fromLTWH(x - w * .2, 0, w * .44, h)),
    );
    // Shaded gussets and creases are fixed to the printed wrapper.
    for (final right in [false, true]) {
      canvas.save();
      if (right) {
        canvas.translate(w, 0);
        canvas.scale(-1, 1);
      }
      final fold = Path()
        ..moveTo(w * .065, h * .08)
        ..lineTo(w * (.28 + tension * .09), h * .25)
        ..lineTo(w * .11, h * .15)
        ..lineTo(w * .045, h * .72)
        ..lineTo(w * .17, h * .88)
        ..lineTo(w * .07, h * .93)
        ..close();
      canvas.drawPath(fold, Paint()..color = Colors.black.withValues(alpha: .23));
      canvas.drawPath(
        Path()
          ..moveTo(w * .075, h * .08)
          ..lineTo(w * (.28 + tension * .09), h * .25),
        Paint()
          ..color = Colors.white.withValues(alpha: .48)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .7,
      );
      canvas.restore();
    }
    // Heat-sealed ends.
    final seal = Paint()..color = Colors.black.withValues(alpha: 0.14);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height * _crimp), seal);
    canvas.drawRect(Rect.fromLTWH(0, size.height * (1 - _crimp), size.width, size.height * _crimp), seal);
    final ribs = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    for (var x = 4.0; x < size.width; x += 4) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height * _crimp), ribs);
      canvas.drawLine(Offset(x, size.height * (1 - _crimp)), Offset(x, size.height), ribs);
    }
    final grooves = Paint()
      ..color = Colors.black.withValues(alpha: .32)
      ..strokeWidth = 1;
    for (var x = 5.0; x < size.width; x += 4) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height * _crimp), grooves);
      canvas.drawLine(Offset(x, size.height * (1 - _crimp)), Offset(x, size.height), grooves);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FoilPainter old) => old.sheen != sheen || old.colors != colors || old.tension != tension;
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

/// Rip the foil, shuffle the cards, present them. Tap to skip. With Reduce
/// Motion on, the pack simply fades into the deck.
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
  bool _ripped = false, _squared = false, _done = false, _haptics = PackFeedback.instance.haptics;
  bool _brushed = false;
  double _grip = 0;

  @override
  void initState() {
    super.initState();
    _c.addListener(() {
      if (!_ripped && _c.value >= .24) {
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
    if (_c.value == 0) PackFeedback.instance.play('grip');
    _c.forward();
  }

  @override
  void dispose() {
    PackFeedback.instance.stop();
    _c.dispose();
    super.dispose();
  }

  double _seg(double a, double b) => Curves.easeInOutCubic.transform(((_c.value - a) / (b - a)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: LayoutBuilder(
          builder: (context, box) {
            final w = math.min(box.maxWidth * .57, 240.0);
            return Semantics(
              label: 'Pull the top right notch to open. Or tap to open pack.',
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _open,
                onPanStart: (d) {
                  if (MediaQuery.of(context).disableAnimations) return;
                  if (_c.value < .24) {
                    _c.stop();
                    setState(() => _grip = 1);
                    PackFeedback.instance.play('grip');
                  }
                },
                onPanUpdate: (d) {
                  if (MediaQuery.of(context).disableAnimations) return;
                  if (_c.value < .36) _c.value = (_c.value + (d.delta.dx.abs() + d.delta.dy.abs()) / (w * 2.5)).clamp(0.0, .36);
                },
                onPanEnd: (_) {
                  setState(() => _grip = 0);
                  _open();
                },
                onPanCancel: () {
                  setState(() => _grip = 0);
                  _open();
                },
                child: AnimatedBuilder(animation: _c, builder: (context, _) => _sequence(w, box)),
              ),
            );
          },
        ),
      ),
      const Text('Pull the corner · Tap to open', style: T.small),
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
    final h = w * 1.42;
    final tear = _seg(.18, .38), extract = _seg(.38, .59), drop = _seg(.49, .67);
    final square = _seg(.82, .96), flip = _seg(.96, 1);
    final n = widget.count;
    final tension = (_seg(0, .23) + _grip * .3).clamp(0.0, 1.0) * (1 - tear);
    final art = FoilPack(
      name: widget.pack.name,
      colors: widget.pack.colors,
      badge: widget.pack.badge,
      caption: widget.pack.caption,
      width: w,
      sheen: .4 + tension * .25,
      tension: tension,
    );
    return Stack(
      alignment: Alignment.center,
      children: [
        // The dark mouth and five cream edges are visible before extraction.
        if (tear > 0 && drop < 1)
          Transform.translate(
            offset: Offset(0, -h * .40),
            child: Container(
              width: w * .85,
              height: n * 2.0 + tear * 12,
              decoration: const BoxDecoration(color: Color(0xFF080B09), borderRadius: BorderRadius.all(Radius.circular(4))),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (var i = 0; i < n; i++)
                    Container(height: 1, margin: const EdgeInsets.only(top: 1, left: 5, right: 5), color: const Color(0xFFE2D7BE)),
                ],
              ),
            ),
          ),
        for (var i = 0; i < n; i++)
          Builder(
            builder: (context) {
              final peel = _seg(.62 + i * .018, .74 + i * .018) * (1 - square);
              final angle = (i - (n - 1) / 2) * .115 * peel;
              return Opacity(
                opacity: extract,
                child: Transform.translate(
                  offset: Offset(0, (1 - extract) * h * .15 - (n - i - 1) * 2.2),
                  child: Transform.rotate(
                    angle: angle,
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
        Transform.translate(
          offset: Offset(-drop * 18, drop * box.maxHeight * .65),
          child: Transform.rotate(
            angle: -.025 * tension - drop * .12,
            child: Opacity(
              opacity: 1 - drop,
              child: ClipPath(
                clipper: _OpenedBody(tear),
                child: SizedBox(width: w, height: h, child: art),
              ),
            ),
          ),
        ),
        if (tear > 0 && drop < 1)
          Transform.translate(
            offset: Offset(w * .04 * tear, -h * .40 - tear * h * .09),
            child: Transform.rotate(
              angle: -.18 * tear,
              child: Opacity(
                opacity: 1 - drop,
                child: CustomPaint(size: Size(w * .88, h * .13 * tear), painter: _SilverStrip(tear)),
              ),
            ),
          ),
      ],
    );
  }
}

class _OpenedBody extends CustomClipper<Path> {
  _OpenedBody(this.tear);
  final double tear;
  @override
  Path getClip(Size s) {
    final p = Path()
      ..moveTo(0, 0)
      ..lineTo(s.width * (1 - tear), 0);
    // The opening travels from the right notch across the seal.
    p.lineTo(s.width * (1 - tear), s.height * .13);
    for (var i = 0; i <= 24; i++) {
      p.lineTo(s.width * (1 - tear + tear * i / 24), s.height * .13 + (i.isEven ? 1 : -1.5));
    }
    return p
      ..lineTo(s.width, s.height)
      ..lineTo(0, s.height)
      ..close();
  }

  @override
  bool shouldReclip(_OpenedBody old) => old.tear != tear;
}

class _SilverStrip extends CustomPainter {
  _SilverStrip(this.tear);
  final double tear;
  @override
  void paint(Canvas c, Size s) {
    final p = Path()
      ..moveTo(s.width * (1 - tear), s.height)
      ..quadraticBezierTo(s.width * .65, -s.height * .5, s.width, s.height * .2)
      ..lineTo(s.width * .95, s.height)
      ..quadraticBezierTo(s.width * .6, s.height * .3, s.width * (1 - tear), s.height)
      ..close();
    c.drawShadow(p, Colors.black, 4, false);
    c.drawPath(
      p,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF646E78), Color(0xFFF7F8F4), Color(0xFF9AA6AD), Color(0xFFE7EBE8)],
          stops: [0, .3, .65, 1],
        ).createShader(Offset.zero & s),
    );
  }

  @override
  bool shouldRepaint(_SilverStrip old) => old.tear != tear;
}
