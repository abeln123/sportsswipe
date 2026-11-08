import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'core/theme.dart';
import 'router.dart';
import 'state/session.dart';
import 'ui/shell.dart';

void main() {
  usePathUrlStrategy();
  runApp(const ProviderScope(child: SportsSwipeApp()));
}

class SportsSwipeApp extends ConsumerWidget {
  const SportsSwipeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Resolving the session drives the router's redirect.
    ref.watch(sessionProvider);
    return MaterialApp.router(
      title: 'Sports Swipe',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      routerConfig: router,
      builder: (context, child) => PhoneFrame(child: child ?? const SizedBox()),
    );
  }
}
