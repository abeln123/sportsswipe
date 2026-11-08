import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportsswipe/core/theme.dart';
import 'package:sportsswipe/ui/research_chart.dart';

void main() {
  test(
    'reference and values use the same scale, including zero and negatives',
    () {
      final s = ResearchChartScale([145, 86, 63, 61, 76], threshold: 86.5);
      expect(s.y(86.5, 154), lessThan(s.y(86, 154)));
      expect(s.y(145, 154), lessThan(s.y(86.5, 154)));
      expect(s.y(0, 154), 154);
      final signed = ResearchChartScale([-10, 5, 0]);
      expect(signed.y(0, 154), greaterThan(0));
      expect(signed.y(0, 154), lessThan(154));
      expect(ResearchChartScale([0, 0, 0]).y(0, 154).isFinite, isTrue);
      expect(ResearchChartScale([0, 0], percent: true).ticks, [
        0,
        25,
        50,
        75,
        100,
      ]);
      expect(ResearchChartScale([0, 1, 0], threshold: 0).ticks, [0, 1]);
    },
  );
  testWidgets(
    'every positive bar rests on one baseline and preserves proportions',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 350,
              child: ResearchBarChart(
                bars: [
                  for (final v in [145, 86, 63, 61, 76])
                    {'value': v, 'label': 'BAL', 'detail': 'Oct 11'},
                ],
                threshold: 86.5,
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      final bars = [
        for (var i = 0; i < 5; i++)
          t.getRect(find.byKey(ValueKey('research-bar-$i'))),
      ];
      for (final bar in bars) {
        expect(bar.bottom, closeTo(bars.first.bottom, .01));
      }
      expect(bars[0].height / bars[1].height, closeTo(145 / 86, .001));
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('narrow screens, zero counts and large text remain usable', (
    t,
  ) async {
    t.view.physicalSize = const Size(320, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var selected = -1;
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
            child: ResearchBarChart(
              bars: [
                for (var i = 0; i < 10; i++)
                  {'value': 0, 'label': 'BAL', 'detail': 'Oct 11'},
              ],
              onSelected: (i) => selected = i,
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('research-bar-0')));
    expect(selected, 0);
    expect(t.takeException(), isNull);
  });
}
