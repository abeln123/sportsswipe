import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sportsswipe/core/api.dart';
import 'package:sportsswipe/core/theme.dart';
import 'package:sportsswipe/screens/profile/sell_collectible_screen.dart';

void main() {
  final fixture = jsonDecode(File('test/fixtures/presentation_reset_transaction.json').readAsStringSync()) as Map<String, dynamic>;
  var reset = false, reject = false, signed = false;
  final calls = <String>[];
  final card = {
    'playerId': 1,
    'firstName': 'Riley',
    'lastName': 'Swift',
    'fullName': 'Riley Swift · DEMO',
    'league': 'nfl',
    'teamAbbr': 'SSP',
    'jerseyNumber': '7',
  };
  setUpAll(() {
    http.runWithClient(
      () => api.base,
      () => MockClient((request) async {
        final path = request.url.path;
        calls.add(path);
        final body = request.body.isEmpty ? <String, dynamic>{} : jsonDecode(request.body) as Map<String, dynamic>;
        Object response = {};
        if (path.endsWith('/me/collection'))
          response = {
            'cards': [
              {
                'card': card,
                'mastery': {'tier': 'diamond', 'count': 400},
                'finish': 'diamond',
                'presentation': true,
              },
            ],
          };
        if (path.endsWith('/collectibles/dashboard'))
          response = {
            'wallet': fixture['walletAddress'],
            'issuer': 'test issuer',
            'cards': [],
            'collectibles': [
              {
                'id': 'card-1',
                'player_id': '1',
                'is_earner': true,
                'edition': 3,
                'season': 2026,
                'earner_name': 'Presenter',
                'owner': reset ? fixture['walletAddress'] : fixture['buyerAddress'],
                'minted_at': '2026-01-01',
              },
            ],
            'sales': reset
                ? []
                : [
                    {'id': 'sale-1', 'collectible_id': 'card-1', 'status': 'confirmed', 'lamports': '100000000', 'is_seller': true},
                  ],
            'presentationResets': reset
                ? [
                    {
                      'id': 'reset-1',
                      'collectible_id': 'card-1',
                      'status': 'confirmed',
                      'transaction_url': 'https://explorer.solana.com/tx/test?cluster=devnet',
                    },
                  ]
                : [],
          };
        if (path.endsWith('/wallet/challenge')) {
          expect(body['address'], fixture['walletAddress']);
          response = {'message': 'Synthetic test wallet verification'};
        }
        if (path.endsWith('/wallet/verify')) response = {'address': fixture['walletAddress']};
        if (path.endsWith('/presentation/reset')) {
          if (reject) return http.Response(jsonEncode({'message': 'Reset service unavailable. Try again shortly.'}), 503);
          response = {'id': 'reset-1', 'status': 'signing', 'transaction': fixture['transaction']};
        }
        if (path.endsWith('/presentation/reset/sign')) {
          expect(body['id'], 'reset-1');
          // Verify the actual native signer returned the exact full two-wallet transaction.
          expect(body['transaction'], fixture['signedTransaction']);
          signed = true;
          reset = true;
          response = {'id': 'reset-1', 'reset': true, 'status': 'confirmed'};
        }
        return http.Response(jsonEncode(response), 200);
      }),
    );
  });
  setUp(() {
    reset = false;
    reject = false;
    signed = false;
    calls.clear();
    SharedPreferences.setMockInitialValues({'ss.devnet.wallet.seed': fixture['walletSeed']});
  });
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const Scaffold(body: SellCollectibleScreen(playerId: 1, presentation: true)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sale complete.'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Reset demo sale'), 300, scrollable: find.byType(Scrollable).first);
  }

  testWidgets('reset signs the refund and card return, then enables another demo sale', (tester) async {
    await mount(tester);
    await tester.tap(find.text('Reset demo sale'));
    await tester.pumpAndSettle();
    expect(signed, isTrue);
    expect(find.text('Sell to demo buyer · 0.1 devnet SOL'), findsOneWidget);
    expect(find.text('Demo ready again. Diamond returned to your wallet; test SOL refunded to the buyer.'), findsWidgets);
    expect(calls.where((p) => p.endsWith('/admin/reset-presentation')), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('a reset failure preserves the completed sale and exposes the real error', (tester) async {
    reject = true;
    await mount(tester);
    await tester.tap(find.text('Reset demo sale'));
    await tester.pumpAndSettle();
    expect(signed, isFalse);
    expect(reset, isFalse);
    await tester.scrollUntilVisible(
      find.text('Reset service unavailable. Try again shortly.'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Reset service unavailable. Try again shortly.'), findsOneWidget);
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('Sale complete.'), findsOneWidget);
    expect(calls.where((p) => p.endsWith('/admin/reset-presentation')), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
