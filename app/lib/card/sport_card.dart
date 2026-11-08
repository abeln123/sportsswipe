import 'package:flutter/material.dart';

import '../core/format.dart' as f;
import '../core/theme.dart';
import '../ui/challenge_share.dart';
import 'card_spec.dart';
import 'jersey_painter.dart';

enum CardVariant { full, contest, tile }

/// Frame colors per finish. Finishes change appearance only.
class Finish {
  static List<Color> frame(String finish) => switch (finish) {
    'bronze' => const [Color(0xFFE7B48F), Color(0xFFA8643C), Color(0xFFE2A77E)],
    'silver' => const [Color(0xFFFFFFFF), Color(0xFFB9C2CC), Color(0xFFF2F5F8)],
    'gold' => const [Color(0xFFFFE8A3), Color(0xFFC9972B), Color(0xFFFFDD7A)],
    'diamond' => const [Color(0xFFC9F6FF), Color(0xFFE5CCFF), Color(0xFFFFFFFF), Color(0xFFB5E8FF)],
    _ => const [Color(0xFFF7F9FB), Color(0xFFC6CED6), Color(0xFFEFF3F6)],
  };

  static String collectionFinish(String equipped, String tier) =>
      equipped == 'base' && const ['bronze', 'silver', 'gold', 'diamond'].contains(tier) ? tier : equipped;

  static List<Color> face(String finish) => switch (finish) {
    'diamond' => const [Color(0xFFD9EDFF), Color(0xFFF7FCFF), Color(0xFFE3D8F5), Color(0xFFDCF7FA)],
    'gold' => const [Color(0xFFFFF1CD), Color(0xFFFFF9EA), Color(0xFFEEDDB1)],
    'bronze' => const [Color(0xFFF6E1CF), Color(0xFFFFF7EF), Color(0xFFE9CEB8)],
    _ => const [Color(0xFFF8FAFC), Color(0xFFE9EEF2), Color(0xFFF3F6F8)],
  };

  static Color accent(String finish) => switch (finish) {
    'bronze' => const Color(0xFFB8733F),
    'silver' => const Color(0xFF8E9AA6),
    'gold' => const Color(0xFFC9972B),
    'diamond' => const Color(0xFF8C7BF0),
    _ => C.ink,
  };
}

/// The universal Chrome Sport card. Every variant shares the same frame,
/// hero (ghost number, diagonal team stripes, jersey) and name block.
class SportCard extends StatelessWidget {
  const SportCard({
    super.key,
    required this.spec,
    this.variant = CardVariant.full,
    this.market,
    this.topRight,
    this.topLeft,
    this.finish = 'base',
    this.body,
    this.footer,
    this.width = 340,
    this.showShare = true,
    this.onShare,
  });

  final CardSpec spec;
  final CardVariant variant;
  final MarketInfo? market;
  final String? topLeft;
  final String? topRight;
  final String finish;
  final Widget? body;
  final Widget? footer;
  final double width;
  final bool showShare;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final s = width / 340;
    final heroHeight = (variant == CardVariant.tile ? 150 : 158) * s;
    return Container(
      width: width,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16 * s),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: Finish.frame(finish)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 18 * s, offset: Offset(0, 8 * s))],
      ),
      padding: EdgeInsets.all((finish == 'diamond' ? 5 : 3) * s),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13 * s),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: Finish.face(finish)),
          ),
          child: DefaultTextStyle(
            style: const TextStyle(color: C.ink, fontFamily: 'Inter'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _topBar(s),
                SizedBox(
                  height: heroHeight,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: _Hero(spec: spec, scale: s),
                      ),
                      if (finish == 'diamond')
                        const Positioned.fill(
                          child: IgnorePointer(child: CustomPaint(painter: _DiamondFacets())),
                        ),
                    ],
                  ),
                ),
                Container(height: 1.5 * s, color: spec.colorway.base.withValues(alpha: 0.35)),
                Padding(
                  padding: EdgeInsets.fromLTRB(16 * s, 12 * s, 16 * s, 0),
                  child: _NameBlock(spec: spec, scale: s, compact: variant == CardVariant.tile, opponent: market?.awayAbbr),
                ),
                if (market != null && variant != CardVariant.tile) ...[
                  if (variant == CardVariant.full)
                    Padding(
                      padding: EdgeInsets.fromLTRB(16 * s, 4 * s, 16 * s, 0),
                      child: Text(
                        '${market!.isGame ? '${market!.awayAbbr} at ${market!.homeAbbr}' : market!.matchup} · ${f.time(market!.startAt)}',
                        style: TextStyle(fontSize: 12.5 * s, fontWeight: FontWeight.w600, color: C.ink),
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16 * s),
                    child: _divider(s),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16 * s),
                    child: _LineRow(market: market!, scale: s, contest: variant == CardVariant.contest),
                  ),
                ],
                if (body != null)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16 * s),
                    child: body!,
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child:
                          footer ?? CardFooter(spec: spec, scale: s, finish: finish, left: finish.toUpperCase(), right: 'Earn Base: 0/1'),
                    ),
                    if (showShare)
                      IconButton(
                        tooltip: 'Share card and start a head-to-head',
                        onPressed: onShare ?? () => challengeShare(context, card: spec, marketId: market?.marketId),
                        icon: Icon(Icons.near_me_outlined, size: 18 * s, color: C.ink),
                        constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
                        padding: const EdgeInsets.all(8),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _divider(double s) => Container(
    margin: EdgeInsets.symmetric(vertical: 8 * s),
    height: 1,
    color: const Color(0xFFCBD3DB),
  );

  Widget _topBar(double s) {
    return Padding(
      padding: EdgeInsets.fromLTRB(14 * s, 9 * s, 14 * s, 7 * s),
      child: Row(
        children: [
          Transform(
            transform: Matrix4.skewX(-0.35),
            child: Container(width: 9 * s, height: 11 * s, color: spec.colorway.base),
          ),
          SizedBox(width: 8 * s),
          Text(
            topLeft ?? '${spec.teamAbbr} / ${spec.leagueLabel}',
            style: TextStyle(fontSize: 12 * s, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: C.ink),
          ),
          const Spacer(),
          if (finish == 'diamond') ...[Icon(Icons.diamond_outlined, size: 16 * s, color: const Color(0xFF6657A5)), SizedBox(width: 5 * s)],
          if (topRight != null)
            Text(
              topRight!,
              style: TextStyle(fontSize: 12 * s, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: C.ink),
            ),
        ],
      ),
    );
  }
}

/// Printed prismatic facets, kept static so the card remains cheap to move.
class _DiamondFacets extends CustomPainter {
  const _DiamondFacets();
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final facets = [
      (
        Path()
          ..moveTo(0, h)
          ..lineTo(w * .42, 0)
          ..lineTo(w * .67, 0)
          ..lineTo(w * .2, h)
          ..close(),
        const Color(0xFFB1E7FF),
      ),
      (
        Path()
          ..moveTo(w * .7, 0)
          ..lineTo(w, h * .2)
          ..lineTo(w * .55, h)
          ..lineTo(w * .38, h)
          ..close(),
        const Color(0xFFE6BCFF),
      ),
    ];
    for (final (path, color) in facets) {
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            colors: [color.withValues(alpha: .28), Colors.white.withValues(alpha: .08), color.withValues(alpha: .18)],
          ).createShader(Offset.zero & size),
      );
    }
    canvas.drawLine(
      Offset(w * .42, 0),
      Offset(0, h),
      Paint()
        ..color = Colors.white.withValues(alpha: .5)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_DiamondFacets old) => false;
}

class _Hero extends StatelessWidget {
  const _Hero({required this.spec, required this.scale});

  final CardSpec spec;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final s = scale;
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned.fill(child: CustomPaint(painter: _HeroBackdrop(spec.colorway))),
        Positioned(
          left: 6 * s,
          top: -14 * s,
          child: Text(
            spec.isTeam ? spec.teamAbbr : spec.jerseyNumber,
            style: TextStyle(
              fontFamily: kCondensed,
              fontWeight: FontWeight.w800,
              fontSize: (spec.isTeam ? 128 : 168) * s,
              height: 1,
              color: const Color(0xFFB9C3CC).withValues(alpha: 0.55),
            ),
          ),
        ),
        Positioned(
          left: 4 * s,
          top: 0,
          bottom: 0,
          child: Center(
            child: RotatedBox(
              quarterTurns: 1,
              child: Text(
                'CHROME SPORT',
                style: TextStyle(fontSize: 7.5 * s, letterSpacing: 2.4, fontWeight: FontWeight.w700, color: C.inkDim),
              ),
            ),
          ),
        ),
        Align(
          alignment: const Alignment(0.05, 1),
          child: Padding(
            padding: EdgeInsets.only(top: 6 * s),
            child: Jersey(spec: spec, width: (spec.isNfl ? 150 : 128) * s),
          ),
        ),
      ],
    );
  }
}

class _HeroBackdrop extends CustomPainter {
  _HeroBackdrop(this.c);

  final Colorway c;

  @override
  void paint(Canvas canvas, Size s) {
    // Dot texture.
    final dot = Paint()..color = const Color(0xFFCFD7DE);
    for (double y = 6; y < s.height; y += 9) {
      for (double x = (y ~/ 9).isEven ? 4 : 8.5; x < s.width; x += 9) {
        canvas.drawCircle(Offset(x, y), 0.7, dot);
      }
    }
    // Diagonal team stripes on the right.
    Path band(double x, double width) => Path()
      ..moveTo(s.width * x + s.height * 0.75, 0)
      ..lineTo(s.width * x + s.height * 0.75 + width, 0)
      ..lineTo(s.width * x + width, s.height)
      ..lineTo(s.width * x, s.height)
      ..close();
    canvas.drawPath(band(0.55, s.width * 0.16), Paint()..color = c.base);
    canvas.drawPath(band(0.71, s.width * 0.07), Paint()..color = c.accent.withValues(alpha: 0.85));
    canvas.drawPath(band(0.78, s.width * 0.05), Paint()..color = c.base.withValues(alpha: 0.75));
  }

  @override
  bool shouldRepaint(covariant _HeroBackdrop old) => old.c != c;
}

class _NameBlock extends StatelessWidget {
  const _NameBlock({required this.spec, required this.scale, required this.compact, this.opponent});

  final CardSpec spec;
  final double scale;
  final bool compact;
  final String? opponent;

  @override
  Widget build(BuildContext context) {
    final s = scale;
    final last = spec.lastName.isEmpty ? spec.fullName : spec.lastName;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  spec.firstName.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12 * s, letterSpacing: 3, fontWeight: FontWeight.w700, color: C.ink),
                ),
                // Long names shrink to fit instead of wrapping.
                SizedBox(
                  height: (compact ? 46 : 54) * s,
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      last.toUpperCase(),
                      maxLines: 1,
                      style: TextStyle(
                        fontFamily: kCondensed,
                        fontWeight: FontWeight.w800,
                        fontSize: (compact ? 48 : 58) * s,
                        height: 1,
                        color: C.ink,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (!compact) ...[
            Container(
              width: 1,
              margin: EdgeInsets.symmetric(horizontal: 12 * s),
              color: const Color(0xFF9AA6B2),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  spec.isTeam ? 'VS' : 'NO.',
                  style: TextStyle(fontSize: 10 * s, fontWeight: FontWeight.w700, letterSpacing: 1.5, color: C.ink),
                ),
                Text(
                  spec.isTeam ? (opponent ?? '–') : (spec.jerseyNumber.isEmpty ? '–' : spec.jerseyNumber),
                  style: TextStyle(fontFamily: kCondensed, fontWeight: FontWeight.w800, fontSize: 30 * s, height: 1, color: C.ink),
                ),
                Text(
                  spec.isTeam ? 'GAME CARD' : spec.series.toUpperCase(),
                  style: TextStyle(fontSize: 7.5 * s, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: C.inkDim),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.market, required this.scale, required this.contest});

  final MarketInfo market;
  final double scale;
  final bool contest;

  @override
  Widget build(BuildContext context) {
    final s = scale;
    final m = market;
    final (big, short) = switch (m.statKey) {
      'moneyline' => ('WIN', 'MONEYLINE'),
      'spread' => (m.overLabel.split(' ').last, '${m.homeAbbr} SPREAD'),
      _ => (f.line(m.line), m.statShort),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          big,
          style: TextStyle(fontFamily: kCondensed, fontWeight: FontWeight.w800, fontSize: 44 * s, height: 1, color: C.ink),
        ),
        Container(
          width: 1.2,
          height: 34 * s,
          margin: EdgeInsets.symmetric(horizontal: 12 * s),
          color: C.ink,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                short,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: kCondensed, fontWeight: FontWeight.w800, fontSize: 20 * s, height: 1.05, color: C.ink),
              ),
              Text(
                contest
                    ? 'Shared contest line'
                    : m.isGame
                    ? 'Right ${m.overLabel} · Left ${m.underLabel}'
                    : 'Locks ${f.dayTime(m.lockAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5 * s, color: C.inkDim),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Footer strip used by the deck and collection: tier on the left, mastery
/// progress on the right, with a stripe accent.
class CardFooter extends StatelessWidget {
  const CardFooter({super.key, required this.left, required this.right, required this.spec, this.scale = 1, this.finish = 'base'});

  final String left;
  final String right;
  final CardSpec spec;
  final double scale;
  final String finish;

  @override
  Widget build(BuildContext context) {
    final s = scale;
    return Container(
      margin: EdgeInsets.only(top: 8 * s),
      padding: EdgeInsets.fromLTRB(14 * s, 8 * s, 14 * s, 9 * s),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFCBD3DB))),
      ),
      child: Row(
        children: [
          Transform(
            transform: Matrix4.skewX(-0.35),
            child: Container(width: 8 * s, height: 10 * s, color: spec.colorway.base),
          ),
          SizedBox(width: 7 * s),
          Text(
            left,
            style: TextStyle(fontSize: 12 * s, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: Finish.accent(finish)),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              right,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12 * s, fontWeight: FontWeight.w600, color: C.ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// Recent form row: oldest to newest with the latest value underlined.
class RecentForm extends StatelessWidget {
  const RecentForm({super.key, required this.values, required this.statLabel, this.scale = 1});

  final List<double> values;
  final String statLabel;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final s = scale;
    final desc = values.isEmpty
        ? 'No recent games'
        : 'Recent $statLabel, oldest to latest: ${values.map(f.line).join(', ')}. Latest ${f.line(values.last)}.';
    return Semantics(
      label: desc,
      excludeSemantics: true,
      child: Padding(
        padding: EdgeInsets.only(top: 8 * s),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Recent form',
                  style: TextStyle(fontSize: 12.5 * s, fontWeight: FontWeight.w700, color: C.ink),
                ),
                Text(
                  'Oldest → latest',
                  style: TextStyle(fontSize: 10 * s, color: C.inkDim),
                ),
              ],
            ),
            const Spacer(),
            if (values.isEmpty)
              Text(
                '—',
                style: TextStyle(fontSize: 14 * s, color: C.inkDim),
              ),
            for (var i = 0; i < values.length; i++)
              Container(
                width: 34 * s,
                padding: EdgeInsets.only(bottom: 2 * s),
                margin: EdgeInsets.only(left: 2 * s),
                decoration: i == values.length - 1
                    ? BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: const Color(0xFF1F8A4C), width: 2 * s),
                        ),
                      )
                    : null,
                child: Text(
                  f.line(values[i]),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14 * s, fontWeight: FontWeight.w700, color: C.ink),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Community split bar (Under purple, Over green).
class CommunityBar extends StatelessWidget {
  const CommunityBar({
    super.key,
    required this.overPct,
    required this.total,
    this.scale = 1,
    this.overLabel = 'Over',
    this.underLabel = 'Under',
  });

  final int overPct;
  final int total;
  final double scale;
  final String overLabel;
  final String underLabel;

  @override
  Widget build(BuildContext context) {
    final s = scale;
    return Padding(
      padding: EdgeInsets.only(top: 8 * s),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'Community picks',
                style: TextStyle(fontSize: 12 * s, fontWeight: FontWeight.w700, color: C.ink),
              ),
              const Spacer(),
              Text(
                total == 0 ? 'No picks yet' : '$total picks',
                style: TextStyle(fontSize: 11 * s, color: C.inkDim),
              ),
            ],
          ),
          Row(
            children: [
              Text(
                '$underLabel ${100 - overPct}%',
                style: TextStyle(fontSize: 12 * s, color: C.ink),
              ),
              const Spacer(),
              Text(
                '$overPct% $overLabel',
                style: TextStyle(fontSize: 12 * s, color: C.ink),
              ),
            ],
          ),
          SizedBox(height: 3 * s),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 5 * s,
              child: Row(
                children: [
                  Expanded(
                    flex: (100 - overPct).clamp(1, 99),
                    child: Container(color: const Color(0xFF8B6FE0)),
                  ),
                  SizedBox(width: 2 * s),
                  Expanded(
                    flex: overPct.clamp(1, 99),
                    child: Container(color: const Color(0xFF2FA968)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small jersey used in list rows.
class JerseyIcon extends StatelessWidget {
  const JerseyIcon({super.key, required this.spec, this.size = 36});

  final CardSpec spec;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size * 1.1,
    child: Center(
      child: Jersey(spec: spec, width: size),
    ),
  );
}

/// Collection grid tile.
class CardTile extends StatelessWidget {
  const CardTile({super.key, required this.spec, required this.tierLabel, required this.progress, this.finish = 'base', this.width = 170});

  final CardSpec spec;
  final String tierLabel;
  final String progress;
  final String finish;
  final double width;

  @override
  Widget build(BuildContext context) {
    final s = width / 340;
    return SportCard(
      spec: spec,
      variant: CardVariant.tile,
      showShare: false,
      width: width,
      finish: finish,
      topRight: f.two(spec.cardNo),
      footer: Padding(
        padding: EdgeInsets.fromLTRB(14 * s * 2, 6, 14 * s * 2, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(height: 1, color: const Color(0xFFCBD3DB), margin: const EdgeInsets.only(bottom: 6)),
            Row(
              children: [
                Text(
                  tierLabel.toUpperCase(),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: Finish.accent(finish)),
                ),
                const Spacer(),
                Icon(Icons.check, size: 14, color: Finish.accent(finish)),
              ],
            ),
            const SizedBox(height: 4),
            Text(progress, style: const TextStyle(fontSize: 11.5, color: C.ink, height: 1.3)),
          ],
        ),
      ),
    );
  }
}
