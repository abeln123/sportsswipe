// Profile with flutter drive --driver=test_driver/pack_performance.dart --target=integration_test/pack_performance_test.dart --profile -d DEVICE.
// Uses in-memory fixtures; no accounts, purchases, or server data are changed.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sportsswipe/core/api.dart';
import 'package:sportsswipe/core/theme.dart';
import 'package:sportsswipe/screens/play/play_screen.dart';
import 'package:sportsswipe/state/pick_queue.dart';
import 'package:sportsswipe/state/session.dart';
import 'package:sportsswipe/ui/shell.dart';

class _Session extends SessionNotifier {
  @override
  Future<Me?> build() async => Me({'id': 'performance-fixture', 'displayName': 'Performance test'});
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('pack shelf and purchase frame timings', (tester) async {
    SharedPreferences.setMockInitialValues({'pack.sound': false, 'pack.haptics': false});
    http.runWithClient(
      () => api.base,
      () => MockClient((r) async {
        final body = r.url.path.endsWith('/packs')
            ? {
                'packs': [
                  for (var i = 0; i < 90; i++)
                    {
                      'key': 'pack-$i',
                      'name': i == 0 ? 'Starter Pack' : 'Team $i Pack',
                      'tagline': 'Five cards. Every position.',
                      'size': 5,
                      'price': i == 0 ? 10 : 50,
                      'available': 100,
                      if (i != 0) 'teamId': i,
                      'foil': [(0x17324A + i % 24 * 0x030205).toRadixString(16).padLeft(6, '0'), '8EB8C4'],
                    },
                ],
              }
            : {'balance': 1000, 'pendingCount': 0, 'unrevealedCount': 0};
        return http.Response(jsonEncode(body), 200);
      }),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWith(_Session.new), displayBalanceProvider.overrideWith((ref) => 1000)],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          home: const Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  AppHeader(play: true),
                  Expanded(child: PlayScreen()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await binding.watchPerformance(() async {
      for (var i = 0; i < 4; i++) {
        await tester.fling(find.byType(CustomScrollView).first, const Offset(0, -1600), 1400);
        await tester.pumpAndSettle();
        await tester.fling(find.byType(CustomScrollView).first, const Offset(0, 1600), 1400);
        await tester.pumpAndSettle();
      }
    }, reportKey: 'shelf');
    await tester.ensureVisible(find.text('Starter Pack'));
    await tester.pumpAndSettle();
    await binding.watchPerformance(() async {
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Starter Pack'));
        await tester.pumpAndSettle();
        expect(find.text('Open pack · 10 coins'), findsOneWidget);
        await tester.tap(find.byTooltip('Close preview'));
        await tester.pumpAndSettle();
      }
    }, reportKey: 'purchase');
    for (final entry in binding.reportData!.entries) {
      final data = entry.value;
      if (data is Map) {
        // Keep the raw frame arrays out of the console; retain useful aggregates.
        debugPrint('PACK_PERFORMANCE ${entry.key}: ${jsonEncode(Map.fromEntries(data.entries.where((e) => e.value is num)))}');
      }
    }
    expect(tester.takeException(), isNull);
  });
}
