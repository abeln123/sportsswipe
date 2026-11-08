import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';

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
    this.sheen = 0,
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

  @override
  Widget build(BuildContext context) {
    final h = width * 1.42;
    return SizedBox(
      width: width,
      height: h,
      child: CustomPaint(
        painter: _FoilPainter(colors, sheen),
        child: Padding(
          padding: EdgeInsets.fromLTRB(width * 0.1, h * 0.16, width * 0.1, h * 0.12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('SPORTS SWIPE',
                style: TextStyle(
                  fontFamily: kCondensed,
                  fontWeight: FontWeight.w800,
                  fontSize: width * 0.075,
                  letterSpacing: 1.6,
                  color: Colors.white.withValues(alpha: 0.85),
                )),
            const Spacer(),
            if (badge != null)
              Text(badge!,
                  style: TextStyle(
                    fontFamily: kCondensed,
                    fontWeight: FontWeight.w800,
                    fontSize: width * 0.34,
                    height: 0.9,
                    color: Colors.white,
                    shadows: const [Shadow(color: Colors.black26, blurRadius: 8)],
                  )),
            Text(name.toUpperCase(),
                maxLines: 2,
                style: TextStyle(
                  fontFamily: kCondensed,
                  fontWeight: FontWeight.w800,
                  fontSize: width * 0.15,
                  height: 0.95,
                  color: Colors.white,
                  shadows: const [Shadow(color: Colors.black38, blurRadius: 6)],
                )),
            if (caption != null) ...[
              SizedBox(height: width * 0.03),
              Text(caption!.toUpperCase(),
                  style: TextStyle(
                    fontSize: width * 0.06,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: Colors.white.withValues(alpha: 0.8),
                  )),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Crimp line height as a share of the pack height.
const _crimp = 0.07;

Path _crimped(Size s, {double top = 0, double? bottom}) {
  final w = s.width, b = bottom ?? s.height;
  const teeth = 14;
  final tw = w / teeth, d = s.height * 0.012;
  final p = Path()..moveTo(0, top + d);
  for (var i = 0; i < teeth; i++) {
    p.lineTo(tw * (i + 0.5), top);
    p.lineTo(tw * (i + 1), top + d);
  }
  p.lineTo(w, b - d);
  for (var i = teeth; i > 0; i--) {
    p.lineTo(tw * (i - 0.5), b);
    p.lineTo(tw * (i - 1), b - d);
  }
  return p..close();
}

class _FoilPainter extends CustomPainter {
  _FoilPainter(this.colors, this.sheen);
  final List<Color> colors;
  final double sheen;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final body = _crimped(size);
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
    // Moving foil highlight.
    final sx = -size.width + sheen * size.width * 3;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: 0.28), Colors.white.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(sx, 0, size.width, size.height)),
    );
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
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FoilPainter old) => old.sheen != sheen || old.colors != colors;
}

/// The back of a Sports Swipe card.
class CardBack extends StatelessWidget {
  const CardBack({super.key, this.width = 200});
  final double width;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: width * 1.4,
        decoration: BoxDecoration(
          color: const Color(0xFF12302A),
          borderRadius: BorderRadius.circular(width * 0.05),
          border: Border.all(color: const Color(0xFFE9EEF0), width: width * 0.035),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 14, offset: Offset(0, 6))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(width * 0.03),
          child: CustomPaint(
            painter: const _BackPainter(),
            child: Center(
              child: Text('SS',
                  style: TextStyle(
                    fontFamily: kCondensed,
                    fontWeight: FontWeight.w800,
                    fontSize: width * 0.3,
                    color: Colors.white.withValues(alpha: 0.9),
                    letterSpacing: -1,
                  )),
            ),
          ),
        ),
      );
}

class _BackPainter extends CustomPainter {
  const _BackPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.white.withValues(alpha: 0.06);
    for (final (x, t) in [(0.9, 0.5), (1.2, 0.25), (0.3, 0.18)]) {
      canvas.save();
      canvas.translate(size.width * x, size.height * 0.25);
      canvas.rotate(-0.62);
      canvas.drawRect(Rect.fromLTWH(-size.width * 2, -size.width * t / 2, size.width * 4, size.width * t), p);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_BackPainter old) => false;
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
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
  bool _ripped = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(_beat);
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) _finish();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.of(context).disableAnimations) _c.duration = const Duration(milliseconds: 500);
      _c.forward();
    });
  }

  void _beat() {
    if (!_ripped && _c.value > 0.16) {
      _ripped = true;
      HapticFeedback.heavyImpact();
    }
  }

  void _finish() {
    if (_done) return;
    _done = true;
    HapticFeedback.lightImpact();
    widget.onDone();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _seg(double a, double b, [Curve curve = Curves.easeInOutCubic]) =>
      curve.transform(((_c.value - a) / (b - a)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.of(context).disableAnimations;
    return Semantics(
      label: 'Opening pack. Tap to skip.',
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _finish,
        child: LayoutBuilder(builder: (context, box) {
          final packW = math.min(box.maxWidth * 0.6, 240.0);
          final cardW = packW * 0.92;
          return AnimatedBuilder(
            animation: _c,
            builder: (context, _) => still ? _fade(packW) : _sequence(packW, cardW, box),
          );
        }),
      ),
    );
  }

  Widget _fade(double packW) => Center(
        child: Opacity(
          opacity: 1 - _c.value,
          child: SizedBox(width: packW, child: widget.pack),
        ),
      );

  Widget _sequence(double packW, double cardW, BoxConstraints box) {
    final packH = packW * 1.42;
    final arrive = _seg(0, 0.12, Curves.easeOutBack);
    final tear = _seg(0.14, 0.32);
    final drop = _seg(0.3, 0.48, Curves.easeInCubic);
    final rise = _seg(0.3, 0.5, Curves.easeOutCubic);
    final shuffle = _seg(0.5, 0.86, Curves.linear);
    final square = _seg(0.84, 1);
    final n = widget.count.clamp(3, 6);
    final strip = packH * 0.16;

    return Stack(alignment: Alignment.center, children: [
      // Cards climb out of the opened pack, riffle, then square up.
      for (var i = 0; i < n; i++)
        Transform.translate(
          offset: Offset(
            math.sin((shuffle * 3 + i / n) * math.pi * 2) * cardW * 0.32 * (1 - square) * (i.isEven ? 1 : -1) * rise,
            (1 - rise) * packH * 0.25 - i * 2.0 * (1 - square),
          ),
          child: Transform.rotate(
            angle: math.sin((shuffle * 3 + i / n) * math.pi * 2) * 0.12 * (1 - square) * rise,
            child: Opacity(opacity: rise, child: CardBack(width: cardW)),
          ),
        ),
      // Pack body falls away once torn.
      Transform.translate(
        offset: Offset(0, (1 - arrive) * 40 + drop * box.maxHeight * 0.7),
        child: Opacity(
          opacity: (arrive * (1 - drop)).clamp(0.0, 1.0),
          child: ClipRect(
            clipper: _BelowTear(strip),
            child: SizedBox(width: packW, height: packH, child: widget.pack),
          ),
        ),
      ),
      // The torn-off strip flies up and away.
      Transform.translate(
        offset: Offset(tear * packW * 0.5, (1 - arrive) * 40 - tear * packH * 0.5),
        child: Transform.rotate(
          angle: tear * 0.6,
          child: Opacity(
            opacity: (arrive * (1 - tear)).clamp(0.0, 1.0),
            child: ClipPath(
              clipper: _AboveTear(strip, tear),
              child: SizedBox(width: packW, height: packH, child: widget.pack),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _BelowTear extends CustomClipper<Rect> {
  _BelowTear(this.y);
  final double y;
  @override
  Rect getClip(Size size) => Rect.fromLTRB(-20, y, size.width + 20, size.height + 20);
  @override
  bool shouldReclip(_BelowTear old) => old.y != y;
}

/// The strip above the tear, with a ragged lower edge.
class _AboveTear extends CustomClipper<Path> {
  _AboveTear(this.y, this.progress);
  final double y;
  final double progress;

  @override
  Path getClip(Size size) {
    final p = Path()..moveTo(-20, -20)..lineTo(size.width + 20, -20)..lineTo(size.width + 20, y);
    final rnd = math.Random(7);
    for (var x = size.width; x > 0; x -= size.width / 18) {
      p.lineTo(x, y + (rnd.nextDouble() - 0.5) * 6);
    }
    return p
      ..lineTo(-20, y)
      ..close();
  }

  @override
  bool shouldReclip(_AboveTear old) => old.y != y;
}
