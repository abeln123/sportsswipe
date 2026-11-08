import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportsswipe/core/theme.dart';
import 'package:sportsswipe/ui/research_report.dart';

Map<String, dynamic> report({bool line = false}) => {
  'kind': 'form',
  'focus': line ? 'line' : 'form',
  'statKey': 'rush_yds',
  'statLabel': 'Rushing yards',
  'card': {
    'playerId': 7,
    'league': 'nfl',
    'teamAbbr': 'ATL',
    'cardNo': 7,
    'jerseyNumber': '7',
    'firstName': 'Bijan',
    'lastName': 'Robinson',
    'fullName': 'Bijan Robinson',
    'colorway': {
      'base': '#A71930',
      'trim': '#FFFFFF',
      'accent': '#000000',
      'numberFill': '#FFFFFF',
      'numberOutline': '#000000',
    },
  },
  'metric': {
    'average': 86.2,
    'aboveLine': 1,
    'games': 5,
    'line': 86.5,
    'rangeMin': 61,
    'rangeMax': 145,
  },
  'games': [
    for (var i = 0; i < 5; i++)
      {
        'date': DateTime.utc(2026, 10, 4 + i * 7).toIso8601String(),
        'opponent': ['NO', 'BAL', 'CHI', 'SF', 'TB'][i],
        'value': [145, 86, 63, 61, 76][i],
      },
  ],
  'definition':
      'Rushing yards from five final ESPN box scores, oldest to latest.',
  'sources': <Map<String, dynamic>>[],
  'playable': {
    'market': {'lockAt': '2099-01-01T00:00:00Z'},
  },
};
void main() {
  setUpAll(() async {
    for (final e in {
      'Inter': 'Inter.ttf',
      kCondensed: 'BarlowCondensed-ExtraBold.ttf',
    }.entries) {
      final font = FontLoader(e.key)
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File('assets/fonts/${e.value}').readAsBytesSync(),
            ),
          ),
        );
      await font.load();
    }
  });
  Future<void> mount(
    WidgetTester t,
    Map<String, dynamic> a, {
    double scale = 1,
  }) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: SingleChildScrollView(
              child: RepaintBoundary(
                key: const ValueKey('report'),
                child: ColoredBox(
                  color: C.bg,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: ResearchReport(a),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('recent form leads with average and explains the outlier', (
    t,
  ) async {
    await mount(t, report());
    expect(find.text('86.2 yards per game'), findsOneWidget);
    expect(
      find.textContaining('145-yard game against NO lifted'),
      findsOneWidget,
    );
    expect(find.text('Average'), findsNothing);
    expect(find.text('Game breakdown'), findsNothing);
    await expectLater(
      find.byKey(const ValueKey('report')),
      matchesGoldenFile('goldens/research_form.png'),
    );
    await t.tap(find.text('86'));
    await t.pump();
    expect(find.textContaining('0.5 below'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('line question leads with count and distinct latest label', (
    t,
  ) async {
    await mount(t, report(line: true));
    expect(find.text('1 of 5 games'), findsOneWidget);
    expect(find.text('Above'), findsOneWidget);
    expect(find.text('Latest'), findsOneWidget);
    await expectLater(
      find.byKey(const ValueKey('report')),
      matchesGoldenFile('goldens/research_line.png'),
    );
    await t.tap(find.text('Game log'));
    await t.pump();
    expect(find.textContaining('vs BAL'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('large text remains usable and closed lines lose today label', (
    t,
  ) async {
    final a = report();
    a['playable'] = {
      'market': {'lockAt': '2000-01-01T00:00:00Z'},
    };
    await mount(t, a, scale: 1.5);
    expect(find.textContaining('Today’s line'), findsNothing);
    expect(t.takeException(), isNull);
  });
  for (final kind in ['matchup', 'rest']) {
    testWidgets('$kind research keeps the evidence and chart readable', (
      t,
    ) async {
      final a = (jsonDecode(
        File('test/fixtures/research_$kind.json').readAsStringSync(),
      ) as Map).cast<String, dynamic>();
      await mount(t, a);
      expect(find.text(a['headline'] as String), findsOneWidget);
      expect(find.text('Game log'), findsOneWidget);
      await expectLater(
        find.byKey(const ValueKey('report')),
        matchesGoldenFile('goldens/research_$kind.png'),
      );
      await t.tap(find.text('Game log'));
      await t.pump();
      expect(
        find.textContaining(kind == 'rest' ? 'days between games' : 'vs BAL'),
        findsWidgets,
      );
      expect(t.takeException(), isNull);
      await mount(t, a, scale: 1.8);
      expect(t.takeException(), isNull);
    });
  }
}
