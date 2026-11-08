import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'screens/ai_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/invite_screen.dart';
import 'screens/picks_screen.dart';
import 'screens/play/contest_entry_screen.dart';
import 'screens/play/play_screen.dart';
import 'screens/profile/admin_screen.dart';
import 'screens/profile/sell_collectible_screen.dart';
import 'screens/profile/profile_screen.dart';
import 'screens/profile/user_profile_screen.dart';
import 'screens/social/league_screen.dart';
import 'screens/social/social_screen.dart';
import 'screens/social/thread_screen.dart';
import 'screens/social/head_to_head_screen.dart';
import 'state/session.dart';
import 'ui/shell.dart';

const _public = ['/login', '/invite', '/duel'];

String? _redirect(BuildContext context, GoRouterState state) {
  final loc = state.uri.toString();
  final path = state.uri.path;
  final authed = authListenable.value;
  if (authed == null) {
    return path == '/loading' ? null : '/loading?next=${Uri.encodeComponent(loc)}';
  }
  final next = state.uri.queryParameters['next'];
  if (path == '/loading') return authed ? (next ?? '/play') : '/login${next != null ? '?next=${Uri.encodeComponent(next)}' : ''}';
  if (!authed && !_public.any(path.startsWith)) return '/login?next=${Uri.encodeComponent(loc)}';
  if (authed && path == '/login') return next ?? '/play';
  if (path == '/') return '/play';
  return null;
}

final router = GoRouter(
  initialLocation: '/play',
  refreshListenable: authListenable,
  redirect: _redirect,
  routes: [
    GoRoute(path: '/', redirect: (_, _) => '/play'),
    GoRoute(path: '/loading', builder: (_, _) => const Scaffold()),
    GoRoute(
      path: '/login',
      builder: (_, s) => AuthScreen(next: s.uri.queryParameters['next']),
    ),
    GoRoute(
      path: '/invite/:token',
      builder: (_, s) => InviteScreen(token: s.pathParameters['token']!),
    ),
    GoRoute(
      path: '/duel/:token',
      builder: (_, s) => HeadToHeadInviteScreen(token: s.pathParameters['token']!),
    ),
    StatefulShellRoute.indexedStack(
      builder: (_, _, shell) => AppShell(shell: shell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/play',
              builder: (_, _) => const PlayScreen(),
              routes: [
                GoRoute(
                  path: 'contest/:dayId',
                  builder: (_, s) => ContestEntryScreen(dayId: int.parse(s.pathParameters['dayId']!)),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/picks', builder: (_, _) => const PicksScreen())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/ai', builder: (_, _) => const AiScreen())],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/social',
              builder: (_, s) => SocialScreen(initialTab: int.tryParse(s.uri.queryParameters['tab'] ?? '') ?? 0),
              routes: [
                GoRoute(
                  path: 'head-to-head/:id',
                  builder: (_, s) => HeadToHeadScreen(id: s.pathParameters['id']!),
                ),
                GoRoute(
                  path: 'thread/:id',
                  builder: (_, s) => ThreadScreen(threadId: s.pathParameters['id']!, title: s.uri.queryParameters['title'] ?? 'Messages'),
                ),
                GoRoute(
                  path: 'league/:id',
                  builder: (_, s) => LeagueScreen(leagueId: s.pathParameters['id']!),
                ),
                GoRoute(
                  path: 'user/:id',
                  builder: (_, s) => UserProfileScreen(userId: s.pathParameters['id']!),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/profile',
              builder: (_, s) => ProfileScreen(initialTab: int.tryParse(s.uri.queryParameters['tab'] ?? '') ?? 0),
              routes: [
                GoRoute(path: 'admin', builder: (_, _) => const AdminScreen()),
                GoRoute(
                  path: 'sell/:playerId',
                  builder: (_, s) => SellCollectibleScreen(
                    playerId: int.parse(s.pathParameters['playerId']!),
                    presentation: s.uri.queryParameters['presentation'] == 'true',
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  ],
);
