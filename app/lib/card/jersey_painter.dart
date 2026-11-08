import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'card_spec.dart';

/// Vector jerseys drawn from a colorway, so every team renders without
/// per-team artwork and stays sharp from list icons to full cards. Leagues
/// differ only in silhouette, trim placement and number style.
abstract class JerseyPainter extends CustomPainter {
  JerseyPainter(this.colorway, this.number);

  final Colorway colorway;
  final String number;

  factory JerseyPainter.forLeague(String league, Colorway c, String number) =>
      league == 'nfl' ? NflJerseyPainter(c, number) : NbaJerseyPainter(c, number);

  Path body(Size s);
  void paintTrim(Canvas canvas, Size s);
  Offset numberCenter(Size s);
  double numberSize(Size s);

  @override
  void paint(Canvas canvas, Size s) {
    final shape = body(s);
    canvas.drawShadow(shape, Colors.black.withValues(alpha: 0.5), s.height * 0.03, false);
    canvas.drawPath(shape, Paint()..color = colorway.base);
    canvas.save();
    canvas.clipPath(shape);
    paintTrim(canvas, s);
    // Fabric shading: light from the upper left.
    canvas.drawRect(
      Offset.zero & s,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withValues(alpha: 0.10), Colors.transparent, Colors.black.withValues(alpha: 0.22)],
        ).createShader(Offset.zero & s),
    );
    canvas.restore();
    _paintNumber(canvas, s);
  }

  void _paintNumber(Canvas canvas, Size s) {
    if (number.isEmpty) return;
    final size = numberSize(s) * (number.length > 1 ? 0.92 : 1.0);
    TextPainter tp(Paint? stroke) => TextPainter(
          text: TextSpan(
            text: number,
            style: TextStyle(
              fontFamily: kCondensed,
              fontWeight: FontWeight.w800,
              fontSize: size,
              height: 1,
              letterSpacing: -size * 0.02,
              foreground: stroke,
              color: stroke == null ? colorway.numberFill : null,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (size * 0.07).clamp(1.0, 6.0)
      ..strokeJoin = StrokeJoin.round
      ..color = colorway.numberOutline;
    final fill = tp(null);
    final c = numberCenter(s);
    final at = Offset(c.dx - fill.width / 2, c.dy - fill.height / 2);
    if (colorway.numberOutline != colorway.numberFill && colorway.numberOutline != colorway.base) {
      tp(outline).paint(canvas, at);
    }
    fill.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant JerseyPainter old) =>
      old.colorway != colorway || old.number != number || old.runtimeType != runtimeType;
}

class NbaJerseyPainter extends JerseyPainter {
  NbaJerseyPainter(super.colorway, super.number);

  @override
  Path body(Size s) {
    final w = s.width, h = s.height;
    return Path()
      ..moveTo(w * 0.27, 0)
      ..quadraticBezierTo(w * 0.30, h * 0.20, w * 0.50, h * 0.21)
      ..quadraticBezierTo(w * 0.70, h * 0.20, w * 0.73, 0)
      ..lineTo(w * 0.86, 0)
      ..quadraticBezierTo(w * 0.84, h * 0.26, w * 0.98, h * 0.36)
      ..lineTo(w * 0.96, h)
      ..lineTo(w * 0.04, h)
      ..lineTo(w * 0.02, h * 0.36)
      ..quadraticBezierTo(w * 0.16, h * 0.26, w * 0.14, 0)
      ..close();
  }

  @override
  void paintTrim(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    final neck = Path()
      ..moveTo(w * 0.27, 0)
      ..quadraticBezierTo(w * 0.30, h * 0.20, w * 0.50, h * 0.21)
      ..quadraticBezierTo(w * 0.70, h * 0.20, w * 0.73, 0);
    final leftArm = Path()
      ..moveTo(w * 0.14, 0)
      ..quadraticBezierTo(w * 0.16, h * 0.26, w * 0.02, h * 0.36);
    final rightArm = Path()
      ..moveTo(w * 0.86, 0)
      ..quadraticBezierTo(w * 0.84, h * 0.26, w * 0.98, h * 0.36);
    final outer = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.06
      ..color = colorway.trim;
    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.02
      ..color = colorway.accent;
    for (final p in [neck, leftArm, rightArm]) {
      canvas.drawPath(p, outer);
      if (colorway.accent != colorway.trim) {
        canvas.drawPath(p.shift(Offset(0, w * 0.035)), inner);
      }
    }
    // Side panels.
    final side = Paint()..color = colorway.trim.withValues(alpha: 0.9);
    canvas.drawRect(Rect.fromLTWH(w * 0.04, h * 0.40, w * 0.025, h * 0.6), side);
    canvas.drawRect(Rect.fromLTWH(w * 0.935, h * 0.40, w * 0.025, h * 0.6), side);
  }

  @override
  Offset numberCenter(Size s) => Offset(s.width * 0.5, s.height * 0.56);

  @override
  double numberSize(Size s) => s.height * 0.40;
}

class NflJerseyPainter extends JerseyPainter {
  NflJerseyPainter(super.colorway, super.number);

  @override
  Path body(Size s) {
    final w = s.width, h = s.height;
    return Path()
      ..moveTo(w * 0.36, h * 0.03)
      ..lineTo(w * 0.50, h * 0.17)
      ..lineTo(w * 0.64, h * 0.03)
      ..lineTo(w * 0.84, h * 0.08)
      ..quadraticBezierTo(w * 0.96, h * 0.16, w * 1.0, h * 0.40)
      ..lineTo(w * 0.83, h * 0.46)
      ..lineTo(w * 0.81, h)
      ..lineTo(w * 0.19, h)
      ..lineTo(w * 0.17, h * 0.46)
      ..lineTo(0, h * 0.40)
      ..quadraticBezierTo(w * 0.04, h * 0.16, w * 0.16, h * 0.08)
      ..close();
  }

  @override
  void paintTrim(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    // V-neck collar.
    final collar = Path()
      ..moveTo(w * 0.34, h * 0.02)
      ..lineTo(w * 0.50, h * 0.19)
      ..lineTo(w * 0.66, h * 0.02);
    canvas.drawPath(
      collar,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.045
        ..color = colorway.trim,
    );
    // Sleeve stripes: trim, accent, trim.
    void stripes(bool left) {
      final x0 = left ? 0.0 : w;
      final dir = left ? 1.0 : -1.0;
      final bands = [(0.27, colorway.trim), (0.31, colorway.accent), (0.35, colorway.trim)];
      for (final (y, color) in bands) {
        final p = Path()
          ..moveTo(x0 + dir * w * 0.02, h * (y - 0.03))
          ..lineTo(x0 + dir * w * 0.19, h * (y + 0.01))
          ..lineTo(x0 + dir * w * 0.19, h * (y + 0.035))
          ..lineTo(x0 + dir * w * 0.01, h * (y + 0.005))
          ..close();
        canvas.drawPath(p, Paint()..color = color);
      }
    }

    stripes(true);
    stripes(false);
    // Sleeve cuffs.
    final cuff = Paint()..color = colorway.trim;
    canvas.drawPath(
      Path()
        ..moveTo(0, h * 0.40)
        ..lineTo(w * 0.17, h * 0.46)
        ..lineTo(w * 0.17, h * 0.43)
        ..lineTo(w * 0.005, h * 0.37)
        ..close(),
      cuff,
    );
    canvas.drawPath(
      Path()
        ..moveTo(w, h * 0.40)
        ..lineTo(w * 0.83, h * 0.46)
        ..lineTo(w * 0.83, h * 0.43)
        ..lineTo(w * 0.995, h * 0.37)
        ..close(),
      cuff,
    );
  }

  @override
  Offset numberCenter(Size s) => Offset(s.width * 0.5, s.height * 0.60);

  @override
  double numberSize(Size s) => s.height * 0.38;
}

class Jersey extends StatelessWidget {
  const Jersey({super.key, required this.spec, required this.width});

  final CardSpec spec;
  final double width;

  @override
  Widget build(BuildContext context) {
    final aspect = spec.isNfl ? 0.92 : 1.12;
    return Semantics(
      label: '${spec.teamAbbr} jersey number ${spec.jerseyNumber}',
      child: CustomPaint(
        size: Size(width, width * aspect),
        painter: JerseyPainter.forLeague(spec.league, spec.colorway, spec.jerseyNumber),
      ),
    );
  }
}
