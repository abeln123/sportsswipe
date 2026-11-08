import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportsswipe/card/card_spec.dart';
import 'package:sportsswipe/card/sport_card.dart';
import 'package:sportsswipe/core/theme.dart';

Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(Future.value(ByteData.sublistView(File('assets/fonts/$f').readAsBytesSync())));
  }
  await loader.load();
}

CardSpec _spec(String league, String abbr, String num, String first, String last, Map<String, String> c, {int no = 1}) =>
    CardSpec.fromJson({
      'playerId': no,
      'league': league,
      'teamAbbr': abbr,
      'cardNo': no,
      'jerseyNumber': num,
      'firstName': first,
      'lastName': last,
      'fullName': '$first $last',
      'colorway': c,
    });

// Colorways as the API derives them (team colors + contrast rules + overrides).
final celtics = _spec('nba', 'BOS', '0', 'Jayson', 'Tatum',
    {'base': '#007A33', 'trim': '#FFFFFF', 'accent': '#BA9653', 'numberFill': '#FFFFFF', 'numberOutline': '#007A33'});
final warriors = _spec('nba', 'GS', '30', 'Stephen', 'Curry',
    {'base': '#1D428A', 'trim': '#FFC72C', 'accent': '#FFC72C', 'numberFill': '#FFC72C', 'numberOutline': '#1D428A'}, no: 2);
final bills = _spec('nfl', 'BUF', '17', 'Josh', 'Allen',
    {'base': '#00338D', 'trim': '#FFFFFF', 'accent': '#C60C30', 'numberFill': '#FFFFFF', 'numberOutline': '#C60C30'}, no: 3);
final vikings = _spec('nfl', 'MIN', '18', 'Justin', 'Jefferson',
    {'base': '#4F2683', 'trim': '#FFFFFF', 'accent': '#FFC62F', 'numberFill': '#FFFFFF', 'numberOutline': '#4F2683'}, no: 4);
final longName = _spec('nba', 'MIL', '34', 'Giannis', 'Antetokounmpo',
    {'base': '#00471B', 'trim': '#EEE1C6', 'accent': '#0077C0', 'numberFill': '#EEE1C6', 'numberOutline': '#00471B'}, no: 5);

final market = MarketInfo.fromJson({
  'marketId': 1,
  'lineVersion': 1,
  'line': 27.5,
  'statKey': 'pts',
  'statLabel': 'Points',
  'statShort': 'POINTS',
  'lockAt': '2026-11-08T00:30:00Z',
  'startAt': '2026-11-08T00:30:00Z',
  'matchup': 'BOS vs NYK',
  'community': {'total': 120, 'overPct': 62},
});

Widget _frame(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: Scaffold(body: Center(child: RepaintBoundary(child: child))),
    );

void main() {
  setUpAll(() async {
    await _loadFont('Inter', ['Inter.ttf']);
    await _loadFont(kCondensed, ['BarlowCondensed-SemiBold.ttf', 'BarlowCondensed-Bold.ttf', 'BarlowCondensed-ExtraBold.ttf']);
  });

  Future<void> golden(WidgetTester t, String name, Widget card, {Size size = const Size(400, 700)}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(_frame(card));
    await expectLater(find.byType(RepaintBoundary).last, matchesGoldenFile('goldens/$name.png'));
  }

  Widget full(CardSpec s) => SportCard(
        spec: s,
        market: market,
        topRight: '01 / 08',
        body: const RecentForm(values: [31, 26, 34, 29, 24], statLabel: 'points'),
        footer: CardFooter(spec: s, left: 'BASE / 01', right: 'Earn Bronze: 0/20'),
      );

  testWidgets('Celtics #0', (t) => golden(t, 'celtics_0', full(celtics)));
  testWidgets('Warriors #30', (t) => golden(t, 'warriors_30', full(warriors)));
  testWidgets('Bills #17', (t) => golden(t, 'bills_17', full(bills)));
  testWidgets('Vikings #18', (t) => golden(t, 'vikings_18', full(vikings)));
  testWidgets('long name fits on one line', (t) async {
    await golden(t, 'long_name', full(longName));
    final text = t.widget<Text>(find.text('ANTETOKOUNMPO'));
    expect(text.maxLines, 1);
  });

  for (final finish in ['base', 'bronze', 'silver', 'gold', 'diamond']) {
    testWidgets('finish $finish', (t) => golden(
          t,
          'finish_$finish',
          CardTile(spec: warriors, width: 190, finish: finish, tierLabel: finish, progress: 'Mastery: Base · 1 / 20 to Bronze'),
          size: const Size(260, 420),
        ));
  }

  testWidgets('contest variant has no wager', (t) async {
    await golden(t, 'contest_bills', SportCard(spec: bills, market: market, variant: CardVariant.contest, topLeft: 'WEEKLY CONTEST', topRight: '01 / 10'));
    expect(find.text('Coin wager'), findsNothing);
    expect(find.text('Shared contest line'), findsOneWidget);
  });
}
