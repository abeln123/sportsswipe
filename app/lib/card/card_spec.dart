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
        overPct = ((j['community'] as Map?)?['overPct'] as num?)?.toInt() ?? 50;

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
        mastery = Mastery.fromJson((j['mastery'] as Map?)?.cast<String, dynamic>());

  final CardSpec card;
  final MarketInfo market;
  final List<double> recentForm;
  final Mastery mastery;
}
