import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sportsswipe/card/card_spec.dart';
import 'package:sportsswipe/core/api.dart';
import 'package:sportsswipe/core/theme.dart';
import 'package:sportsswipe/state/session.dart';
import 'package:sportsswipe/state/pick_queue.dart';
import 'package:sportsswipe/screens/play/pack_art.dart';
import 'package:sportsswipe/screens/play/pack_feedback.dart';
import 'package:sportsswipe/screens/play/pack_store.dart';
import 'package:sportsswipe/screens/play/play_screen.dart';
import 'package:sportsswipe/screens/profile/profile_screen.dart';
import 'package:sportsswipe/card/sport_card.dart';
import 'package:sportsswipe/state/play.dart';
import 'package:sportsswipe/ui/shell.dart';
import 'package:sportsswipe/ui/challenge_share.dart';
import 'package:sportsswipe/ui/widgets.dart';

class TestSession extends SessionNotifier {
  @override
  Future<Me?> build() async => Me({'id': 'me', 'displayName': 'Alex', 'isAdmin': true});
}

void main() {
  final commands = <String>[];
  var failInvite = false;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    for (final channel in ['xyz.luan/audioplayers.global/events', 'xyz.luan/audioplayers.global', 'xyz.luan/audioplayers']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(channel), (call) async {
        final args = call.arguments;
        if (args is Map && args['playerId'] is String) {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
            MethodChannel("xyz.luan/audioplayers/events/${args['playerId']}"),
            (_) async => null,
          );
        }
        return 1;
      });
    }
    PackFeedback.instance.sound = false;
    PackFeedback.instance.haptics = false;
    http.runWithClient(
      () => api.base,
      () => MockClient((r) async {
        Object body = {};
        if (r.url.path == '/v1/packs') {
          body = {
            'presentationAvailable': true,
            'packs': [
              for (var i = 0; i < 90; i++)
                {
                  'key': 'pack-$i',
                  'name': i == 0 ? 'Starter Pack' : 'Team $i Pack',
                  'tagline': 'Five cards. Every position.',
                  'price': i == 0 ? 10 : 50,
                  'size': 5,
                  'available': 100,
                  if (i != 0) 'teamId': i,
                  'foil': ['2862B9', '102F72'],
                },
            ],
          };
        }
        if (r.url.path == '/v1/me/summary') body = {'balance': 1000, 'pendingCount': 0, 'unrevealedCount': 0, 'isAdmin': true};
        if (r.url.path == '/v1/me/collection') {
          body = {
            'series': 'Debut Series',
            'collected': 1,
            'total': 1,
            'unassignedFinishes': [],
            'cards': [
              {
                'card': {
                  'playerId': 1,
                  'fullName': 'Riley Swift',
                  'firstName': 'Riley',
                  'lastName': 'Swift',
                  'teamAbbr': 'SSP',
                  'league': 'nfl',
                  'jerseyNumber': '7',
                  'colorway': {'base': '784CC6'},
                },
                'mastery': {'count': 400, 'tier': 'diamond'},
                'finish': 'base',
                'presentation': true,
              },
            ],
          };
        }
        if (r.url.path == '/v1/friends') body = {'friends': []};
        if (r.url.path == '/v1/deck') {
          body = {
            'cards': [
              {
                'card': {
                  'playerId': 10,
                  'fullName': 'Josh Allen',
                  'firstName': 'Josh',
                  'lastName': 'Allen',
                  'teamAbbr': 'BUF',
                  'league': 'nfl',
                  'jerseyNumber': '17',
                  'colorway': {'base': '00338D'},
                },
                'market': {
                  'marketId': 101,
                  'lineVersion': 1,
                  'line': 265.5,
                  'statKey': 'pass_yds',
                  'statLabel': 'Passing yards',
                  'statShort': 'PASS YDS',
                  'lockAt': '2030-01-01T00:00:00Z',
                  'startAt': '2030-01-01T00:00:00Z',
                  'matchup': 'BUF vs MIA',
                },
                'recentForm': [240, 280, 310, 255, 290],
                'mastery': {'tier': 'base', 'count': 1, 'nextTier': 'bronze', 'nextAt': 20},
              },
            ],
          };
        }
        if (r.url.path == '/v1/head-to-heads') {
          commands.add((jsonDecode(r.body) as Map)['commandId'] as String);
          if (failInvite) return http.Response('<html>Old server</html>', 404);
          body = {'id': 'challenge', 'url': 'https://sportsswipe.fly.dev/duel/test'};
        }
        return http.Response(jsonEncode(body), 200);
      }),
    );
    for (final e in {'Inter': 'Inter.ttf', kCondensed: 'BarlowCondensed-ExtraBold.ttf'}.entries) {
      final loader = FontLoader(e.key)..addFont(Future.value(ByteData.sublistView(File('assets/fonts/${e.value}').readAsBytesSync())));
      await loader.load();
    }
  });
  Future<void> mount(WidgetTester t, Widget child) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('surface'),
        child: ProviderScope(
          overrides: [sessionProvider.overrideWith(TestSession.new), displayBalanceProvider.overrideWith((ref) => 1000)],
          child: MaterialApp(
            theme: buildTheme(),
            home: Scaffold(body: child),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('large catalog is lazy and purchase preview has no continuous repaint ticker', (t) async {
    await mount(t, const PackStore(sport: 'all'));
    expect(find.text('Presentation Pack'), findsNothing);
    expect(find.byType(FoilPack).evaluate().length, lessThan(10));
    await t.ensureVisible(find.text('Starter Pack'));
    await t.tap(find.text('Starter Pack'));
    await t.pumpAndSettle();
    expect(find.text('Open pack · 10 coins'), findsOneWidget);
    expect(t.binding.hasScheduledFrame, isFalse);
    await expectLater(find.byKey(const ValueKey('surface')), matchesGoldenFile('goldens/pack_purchase.png'));
    expect(t.takeException(), isNull);
  });
  testWidgets('home tabs collapse into a menu only during cards and return to the shelf', (t) async {
    await mount(
      t,
      const Column(
        children: [
          AppHeader(play: true),
          Expanded(child: PlayScreen()),
        ],
      ),
    );
    expect(find.text('Parlays'), findsOneWidget);
    expect(find.text('Contests'), findsOneWidget);
    expect(find.text('All sports'), findsOneWidget);
    final container = ProviderScope.containerOf(t.element(find.byType(PlayScreen)));
    await t.tap(find.text('NFL'));
    await t.pumpAndSettle();
    expect(container.read(playModeProvider).sport, 'nfl');
    await t.tap(find.text('Parlays'));
    await t.pumpAndSettle();
    expect(container.read(playModeProvider).parlay, isTrue);
    expect(container.read(playCardsProvider), isFalse);
    expect(find.text('Packs'), findsOneWidget);
    expect(find.text('3×'), findsOneWidget);
    await t.tap(find.text('Packs'));
    await t.pumpAndSettle();
    container.read(playCardsProvider.notifier).set(true);
    await t.pumpAndSettle();
    expect(find.text('Parlays'), findsNothing);
    await t.tap(find.bySemanticsLabel('Packs, change mode and sport'));
    await t.pumpAndSettle();
    expect(find.text('Parlays'), findsOneWidget);
    await t.tap(find.text('Packs').last);
    await t.pumpAndSettle();
    expect(container.read(playCardsProvider), isFalse);
    expect(find.text('All sports'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('earned Diamond is styled and opens full-size with sharing and selling', (t) async {
    await mount(t, const ProfileScreen(initialTab: 1));
    final tile = find.byType(CardTile);
    await t.ensureVisible(tile);
    await t.pumpAndSettle();
    expect(t.widget<CardTile>(tile).finish, 'diamond');
    await t.tap(tile);
    await t.pumpAndSettle();
    expect(find.byType(CollectionCardView), findsOneWidget);
    final card = t.widget<SportCard>(find.descendant(of: find.byType(CollectionCardView), matching: find.byType(SportCard)));
    expect(card.finish, 'diamond');
    expect(card.width, greaterThan(300));
    expect(find.text('Share card'), findsOneWidget);
    expect(find.text('Sell Diamond edition'), findsOneWidget);
    await expectLater(find.byKey(const ValueKey('surface')), matchesGoldenFile('goldens/collection_diamond_detail.png'));
    await t.tap(find.byType(CloseButton));
    await t.pumpAndSettle();
    expect(find.byType(CardTile), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('wager buttons clamp to balance, exact entry validates and zero is allowed', (t) async {
    var value = 25;
    await mount(
      t,
      StatefulBuilder(
        builder: (_, update) => Center(
          child: WagerControl(value: value, max: 63, dark: true, onChanged: (v) => update(() => value = v)),
        ),
      ),
    );
    await t.tap(find.byTooltip('Increase wager by 25'));
    await t.pump();
    expect(value, 50);
    await t.tap(find.byTooltip('Increase wager by 25'));
    await t.pump();
    expect(value, 63);
    await t.tap(find.text('63'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '64');
    await t.tap(find.text('Set wager'));
    await t.pump();
    expect(find.text('Enter 0–63 coins.'), findsOneWidget);
    expect(value, 63);
    await t.enterText(find.byType(TextField), '37');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();
    expect(value, 37);
    await t.tap(find.byTooltip('Decrease wager by 25'));
    await t.pump();
    expect(value, 12);
    await t.tap(find.byTooltip('Decrease wager by 25'));
    await t.pump();
    expect(value, 0);
    expect(t.takeException(), isNull);
  });
  testWidgets('invite retry preserves its command and offers explicit browser share and copy', (t) async {
    commands.clear();
    failInvite = true;
    final card = CardSpec.fromJson({
      'playerId': 1,
      'fullName': 'Bijan Robinson',
      'teamAbbr': 'ATL',
      'league': 'nfl',
      'jerseyNumber': '7',
      'colorway': {'base': 'B32028'},
    });
    await mount(
      t,
      Builder(
        builder: (ctx) => TextButton(
          onPressed: () => challengeShare(ctx, card: card, marketId: 2),
          child: const Text('Share card'),
        ),
      ),
    );
    await t.tap(find.text('Share card'));
    await t.pumpAndSettle();
    await t.tap(find.text('Create invite link'));
    await t.pumpAndSettle();
    expect(find.text('This feature needs the latest server update. Please try again shortly.'), findsOneWidget);
    failInvite = false;
    await t.tap(find.text('Create invite link'));
    await t.pumpAndSettle();
    expect(commands, hasLength(2));
    expect(commands[0], commands[1]);
    expect(find.text('Send by text or link'), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
    await expectLater(find.byKey(const ValueKey('surface')), matchesGoldenFile('goldens/card_share.png'));
    expect(t.takeException(), isNull);
  });
}
