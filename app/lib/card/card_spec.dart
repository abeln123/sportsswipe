import 'package:flutter/painting.dart';

Color hex(String? v, [Color fallback = const Color(0xFF1F2937)]) {
  if (v == null) return fallback;
  final h = v.replaceAll('#', '');
  final n = int.tryParse(h, radix: 16);
  if (n == null || h.length != 6) return fallback;
  return Color(0xFF000000 | n);
}

class Colorway {
  const Colorway({required this.base, required this.trim, required this.accent, required this.numberFill, required this.numberOutline});

  factory Colorway.fromJson(Map<String, dynamic>? j) => Colorway(
        base: hex(j?['base'] as String?),
        trim: hex(j?['trim'] as String?, const Color(0xFFFFFFFF)),
        accent: hex(j?['accent'] as String?, const Color(0xFFDDDDDD)),
        numberFill: hex(j?['numberFill'] as String?, const Color(0xFFFFFFFF)),
        numberOutline: hex(j?['numberOutline'] as String?, const Color(0xFFFFFFFF)),
      );

  final Color base;
  final Color trim;
  final Color accent;
  final Color numberFill;
  final Color numberOutline;
}

/// Everything needed to draw a player's card, independent of any market.
class CardSpec {
  CardSpec({
    required this.playerId,
    required this.league,
    required this.teamAbbr,
    required this.cardNo,
    required this.colorway,
    required this.jerseyNumber,
    required this.firstName,
    required this.lastName,
    required this.fullName,
    this.position,
    this.headshotUrl,
    this.series = 'Debut Series',
  });

  factory CardSpec.fromJson(Map<String, dynamic> j) => CardSpec(
        playerId: (j['playerId'] as num).toInt(),
        league: j['league'] as String? ?? 'nba',
        teamAbbr: j['teamAbbr'] as String? ?? '',
        cardNo: (j['cardNo'] as num?)?.toInt(),
        colorway: Colorway.fromJson((j['colorway'] as Map?)?.cast<String, dynamic>()),
        jerseyNumber: j['jerseyNumber'] as String? ?? '',
        firstName: j['firstName'] as String? ?? '',
        lastName: j['lastName'] as String? ?? '',
        fullName: j['fullName'] as String? ?? '',
        position: j['position'] as String?,
        headshotUrl: j['headshotUrl'] as String?,
        series: j['series'] as String? ?? 'Debut Series',
      );

  final int playerId;
  final String league;
  final String teamAbbr;
  final int? cardNo;
  final Colorway colorway;
  final String jerseyNumber;
  final String firstName;
  final String lastName;
  final String fullName;
  final String? position;
  final String? headshotUrl;
  final String series;

  bool get isNfl => league == 'nfl';
  String get leagueLabel => league.toUpperCase();

  /// A team card, used for moneyline, spread and total markets.
  bool get isTeam => position == 'TEAM';
}

class MarketInfo {
  MarketInfo.fromJson(Map<String, dynamic> j)
      : marketId = (j['marketId'] as num).toInt(),
        lineVersion = (j['lineVersion'] as num).toInt(),
        line = (j['line'] as num).toDouble(),
        statKey = j['statKey'] as String,
        statLabel = j['statLabel'] as String,
        statShort = j['statShort'] as String? ?? (j['statLabel'] as String).toUpperCase(),
        lockAt = DateTime.parse(j['lockAt'] as String),
        startAt = DateTime.parse(j['startAt'] as String),
        open = j['open'] as bool? ?? true,
        matchup = j['matchup'] as String? ?? '',
        gameStatus = j['gameStatus'] as String? ?? 'scheduled',
        communityTotal = ((j['community'] as Map?)?['total'] as num?)?.toInt() ?? 0,
        overPct = ((j['community'] as Map?)?['overPct'] as num?)?.toInt() ?? 50,
        isGame = j['kind'] == 'game',
        overLabel = j['overLabel'] as String? ?? 'Over',
        underLabel = j['underLabel'] as String? ?? 'Under',
        homeAbbr = j['homeAbbr'] as String? ?? '',
        awayAbbr = j['awayAbbr'] as String? ?? '';

  final int marketId;
  final int lineVersion;
  final double line;
  final String statKey;
  final String statLabel;
  final String statShort;
  final DateTime lockAt;
  final DateTime startAt;
  final bool open;
  final String matchup;
  final String gameStatus;
  final int communityTotal;
  final int overPct;

  /// Moneyline, spread or total, graded on the game score from the home side.
  final bool isGame;

  /// What a right (Over) and left (Under) swipe mean, e.g. "BUF -3.5".
  final String overLabel;
  final String underLabel;
  final String homeAbbr;
  final String awayAbbr;

  /// "Over 24.5" for players, "BUF -3.5" for games.
  String pickText(String side) => isGame
      ? '${side == 'over' ? overLabel : underLabel}${statKey == 'moneyline' ? ' to win' : ''}'
      : '${side == 'over' ? 'Over' : 'Under'} ${_line(line)}';

  static String _line(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

class Mastery {
  const Mastery({this.tier = 'none', this.count = 0, this.nextTier, this.nextAt});

  factory Mastery.fromJson(Map<String, dynamic>? j) => Mastery(
        tier: j?['tier'] as String? ?? 'none',
        count: (j?['count'] as num?)?.toInt() ?? 0,
        nextTier: j?['nextTier'] as String?,
        nextAt: (j?['nextAt'] as num?)?.toInt(),
      );

  final String tier;
  final int count;
  final String? nextTier;
  final int? nextAt;

  /// Tier shown on the card footer; an unearned card displays as Base.
  String get displayTier => tier == 'none' ? 'base' : tier;
}

class PlayableCard {
  PlayableCard.fromJson(Map<String, dynamic> j)
      : card = CardSpec.fromJson((j['card'] as Map).cast<String, dynamic>()),
        market = MarketInfo.fromJson((j['market'] as Map).cast<String, dynamic>()),
        recentForm = ((j['recentForm'] as List?) ?? []).map((e) => (e as num).toDouble()).toList(),
        mastery = Mastery.fromJson((j['mastery'] as Map?)?.cast<String, dynamic>()),
        packId = j['packId'] as String?;

  final CardSpec card;
  final MarketInfo market;
  final List<double> recentForm;
  final Mastery mastery;

  /// The pack this card was dealt from, if any.
  final String? packId;

  /// Short name for receipts: "J. Allen" or "BUF vs MIA".
  String get subject => card.isTeam
      ? '${market.awayAbbr} at ${market.homeAbbr}'
      : (card.firstName.isEmpty ? card.fullName : '${card.firstName[0]}. ${card.lastName}');
}
