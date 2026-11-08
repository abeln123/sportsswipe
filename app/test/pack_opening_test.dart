import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportsswipe/core/theme.dart';
import 'package:sportsswipe/screens/play/pack_art.dart';
import 'package:sportsswipe/screens/play/pack_store.dart';
import 'package:sportsswipe/screens/play/pack_feedback.dart';

const pack = FoilPack(name: 'QB Pack', colors: [Color(0xFF2862B9), Color(0xFF102F72)], caption: '5 cards per pack', width: 220);

void main() {
  setUpAll(() async {
    for (final entry in {'Inter': 'Inter.ttf', kCondensed: 'BarlowCondensed-ExtraBold.ttf'}.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(Future.value(ByteData.sublistView(File('assets/fonts/${entry.value}').readAsBytesSync())));
      await loader.load();
    }
    PackFeedback.instance.sound = false;
    PackFeedback.instance.haptics = false;
  });
  test('remaining inventory counts complete five-card purchases', () {
    PackOffer offer(int available) => PackOffer({'key': 'qb', 'name': 'QB', 'price': 10, 'size': 5, 'available': available});
    expect(offer(17).packsRemaining, 3);
    expect(offer(4).soldOut, true);
    expect(offer(5).soldOut, false);
  });
  testWidgets('grip, tear, extract and square keep exactly five cards', (t) async {
    t.view.physicalSize = const Size(390, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var completed = 0;
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('opening'),
            child: PackOpening(pack: pack, count: 5, onDone: () => completed++),
          ),
        ),
      ),
    );
    await expectLater(find.byKey(const ValueKey('opening')), matchesGoldenFile('goldens/pack_sealed.png'));
    expect(completed, 0);
    await t.tapAt(const Offset(195, 300));
    await t.pump();
    await t.pump(const Duration(milliseconds: 900));
    expect(t.takeException(), isNull);
    await expectLater(find.byKey(const ValueKey('opening')), matchesGoldenFile('goldens/pack_tear.png'));
    await t.pump(const Duration(milliseconds: 1200));
    expect(find.byType(CardBack), findsNWidgets(5));
    expect(t.takeException(), isNull);
    await expectLater(find.byKey(const ValueKey('opening')), matchesGoldenFile('goldens/pack_fan.png'));
    await t.pump(const Duration(seconds: 1));
    expect(completed, 1);
    await t.tap(find.text('Quick reveal'));
    expect(completed, 1);
  });
  testWidgets('reduced motion and quick reveal complete without ceremony', (t) async {
    t.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
    var completed = 0;
    await t.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: PackOpening(pack: pack, count: 5, onDone: () => completed++),
          ),
        ),
      ),
    );
    await t.tap(find.byType(FoilPack));
    await t.pump();
    expect(completed, 1);
    expect(t.takeException(), isNull);
  });
  testWidgets('drag completes with one tear pulse and one square pulse', (t) async {
    PackFeedback.instance.haptics = true;
    final pulses = <Object?>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') pulses.add(call.arguments);
      return null;
    });
    addTearDown(() {
      PackFeedback.instance.haptics = false;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    var completed = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PackOpening(pack: pack, count: 5, onDone: () => completed++),
        ),
      ),
    );
    await t.drag(find.byType(FoilPack), const Offset(-100, -35));
    for (var i = 0; i < 180; i++) {
      await t.pump(const Duration(milliseconds: 16));
      expect(t.takeException(), isNull);
    }
    expect(completed, 1);
    expect(pulses, ['HapticFeedbackType.mediumImpact', 'HapticFeedbackType.lightImpact']);
  });
  for (final scenario in [
    ('middle_left_to_right', const Offset(.08, .54), const Offset(.84, .54)),
    ('lower_right_to_left', const Offset(.92, .72), const Offset(.15, .72)),
    ('bottom_to_top', const Offset(.47, .88), const Offset(.47, .15)),
    ('diagonal', const Offset(.17, .24), const Offset(.84, .75)),
  ]) {
    testWidgets('tear follows swipe ${scenario.$1}', (t) async {
      t.view.physicalSize = const Size(390, 700);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('swipe'),
              child: PackOpening(pack: pack, count: 5, onDone: () {}),
            ),
          ),
        ),
      );
      final rect = t.getRect(find.byType(FoilPack));
      Offset point(Offset p) => rect.topLeft + Offset(p.dx * rect.width, p.dy * rect.height);
      final start = point(scenario.$2), end = point(scenario.$3);
      final gesture = await t.startGesture(start);
      await gesture.moveTo(Offset.lerp(start, end, .2)!);
      await t.pump();
      await gesture.moveTo(end);
      await t.pump();
      final painters = t.widgetList<CustomPaint>(find.byType(CustomPaint)).map((w) => w.painter).whereType<FoilTearPainter>();
      expect(painters, hasLength(1));
      final tear = painters.single;
      expect((tear.start - (start - rect.topLeft)).distance, lessThan(1));
      expect((tear.end - (end - rect.topLeft)).distance, lessThan(1));
      expect(t.takeException(), isNull);
      await expectLater(find.byKey(const ValueKey('swipe')), matchesGoldenFile('goldens/tear_${scenario.$1}.png'));
      await gesture.up();
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      expect(t.takeException(), isNull);
      await expectLater(find.byKey(const ValueKey('swipe')), matchesGoldenFile('goldens/open_${scenario.$1}.png'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  }
  testWidgets('cancelled grip before seal break leaves pack sealed', (t) async {
    var completed = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PackOpening(pack: pack, count: 5, onDone: () => completed++),
        ),
      ),
    );
    final p = t.getCenter(find.byType(FoilPack));
    final gesture = await t.startGesture(p);
    await gesture.moveBy(const Offset(25, 0));
    await t.pump();
    await gesture.moveBy(const Offset(4, 0));
    await t.pump();
    await gesture.cancel();
    await t.pumpAndSettle();
    expect(completed, 0);
    expect(find.byType(FoilPack), findsOneWidget);
  });
  testWidgets('foil material variants fit their shelf bounds', (t) async {
    t.view.physicalSize = const Size(820, 370);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: const ValueKey('shelf'),
              child: ColoredBox(
                color: C.bg,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const FoilPack(name: 'Game Day Pack', colors: [Color(0xFFEBA242), Color(0xFFC16A08)], width: 160),
                      const SizedBox(width: 22),
                      const FoilPack(name: '3x Pack', colors: [Color(0xFFD5B76B), Color(0xFF8F6D20)], badge: '3X', width: 160),
                      const SizedBox(width: 22),
                      const FoilPack(name: 'All-Star Pack', colors: [Color(0xFFD2EEF4), Color(0xFF9DBEC9)], width: 160),
                      const SizedBox(width: 22),
                      const FoilPack(name: 'QB Pack', colors: [Color(0xFF2862B9), Color(0xFF102F72)], width: 160),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(t.takeException(), isNull);
    await expectLater(find.byKey(const ValueKey('shelf')), matchesGoldenFile('goldens/foil_materials.png'));
  });
}
