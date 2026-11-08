import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sportsswipe/core/api.dart';
import 'package:sportsswipe/core/theme.dart';
import 'package:sportsswipe/state/session.dart';
import 'package:sportsswipe/screens/social/social_screen.dart';

class TestSession extends SessionNotifier {
  @override
  Future<Me?> build() async => Me({'id': 'me', 'displayName': 'Alex Rivera', 'handleTag': 'ALEX#1234'});
}

void main() {
  var incoming = false, requested = false, accepted = false;
  final person = {'userId': 'friend', 'displayName': 'Jordan Lee', 'handleTag': 'JORDAN#1234', 'requestId': 1};
  setUpAll(() async {
    http.runWithClient(
      () => api.base,
      () => MockClient((request) async {
        final path = request.url.path;
        Object body = {};
        if (path == '/v1/friends') body = {'friends': <Object>[]};
        if (path == '/v1/friend-requests' && request.method == 'GET') {
          body = {
            'incoming': incoming && !accepted ? [person] : [],
            'outgoing': [],
          };
        }
        if (path == '/v1/me/collection') body = {'cards': <Object>[]};
        if (path == '/v1/users/search') {
          body = {
            'users': [
              {...person, 'relation': requested ? 'requested' : 'none'},
            ],
          };
        }
        if (path == '/v1/friend-requests' && request.method == 'POST') {
          requested = true;
          body = {'relation': 'requested'};
        }
        if (path == '/v1/friend-requests/1/accept') {
          accepted = true;
          body = {'relation': 'friend'};
        }
        return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
      }),
    );
    for (final e in {'Inter': 'Inter.ttf', kCondensed: 'BarlowCondensed-ExtraBold.ttf'}.entries) {
      final font = FontLoader(e.key)..addFont(Future.value(ByteData.sublistView(File('assets/fonts/${e.value}').readAsBytesSync())));
      await font.load();
    }
  });
  setUp(() {
    incoming = false;
    requested = false;
    accepted = false;
  });
  Future<void> mount(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWith(TestSession.new)],
        child: MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('social'),
              child: const ColoredBox(color: C.bg, child: SocialScreen()),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('first friend screen has identity invite and quiet search', (t) async {
    await mount(t);
    expect(find.text('Alex Rivera'), findsOneWidget);
    expect(find.text('Invite a friend'), findsOneWidget);
    expect(find.text('Your friends · 0'), findsNothing);
    expect(find.text('Find by name or handle'), findsOneWidget);
    await expectLater(find.byKey(const ValueKey('social')), matchesGoldenFile('goldens/social_first_friend.png'));
    expect(t.takeException(), isNull);
  });
  testWidgets('keyboard search and Add update to Requested in place', (t) async {
    await mount(t);
    await t.enterText(find.byType(TextField), 'Jordan');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('Add'));
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();
    expect(find.text('Requested'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('acceptance makes Message immediately available', (t) async {
    incoming = true;
    await mount(t);
    await t.ensureVisible(find.text('Accept'));
    await t.tap(find.text('Accept'));
    await t.pumpAndSettle();
    expect(find.byTooltip('Message Jordan Lee'), findsOneWidget);
    expect(find.text('Accept'), findsNothing);
    expect(find.text('Invite a friend'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
