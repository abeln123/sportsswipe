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
}
