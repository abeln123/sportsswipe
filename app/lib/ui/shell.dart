import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart' as f;
import '../core/theme.dart';
import '../screens/picks_screen.dart';
import '../state/pick_queue.dart';
import '../state/session.dart';
import 'widgets.dart';

/// On wide screens the app renders inside a phone-sized frame so the web
/// build reads as a simulation of the mobile app.
class PhoneFrame extends StatelessWidget {
  const PhoneFrame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    if (size.width < 560) return child;
    final h = (size.height - 48).clamp(640.0, 900.0);
    return ColoredBox(
      color: const Color(0xFF06110E),
      child: Center(
        child: Container(
          width: 410,
          height: h,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(54),
            border: Border.all(color: const Color(0xFF34434D), width: 6),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 40, offset: Offset(0, 20))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(48),
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                size: Size(398, h - 12),
                padding: const EdgeInsets.only(top: 44, bottom: 18),
                viewPadding: const EdgeInsets.only(top: 44, bottom: 18),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: Stack(children: [
                  Positioned.fill(child: child),
                  const Positioned(top: 0, left: 0, right: 0, child: _StatusBar()),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar();
  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: SizedBox(
          height: 44,
          child: Stack(children: [
            const Positioned(
              left: 34,
              top: 14,
              child: Text('9:41', style: TextStyle(color: C.text, fontWeight: FontWeight.w700, fontSize: 15)),
            ),
            Align(
              alignment: const Alignment(0, 0.2),
              child: Container(width: 118, height: 30, decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(20))),
            ),
            const Positioned(right: 30, top: 14, child: Icon(Icons.signal_cellular_alt, size: 16, color: C.text)),
          ]),
        ),
      );
}

class AppHeader extends ConsumerWidget {
  const AppHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balance = ref.watch(displayBalanceProvider);
    final loaded = ref.watch(summaryProvider).loaded;
    return Container(
      height: 62,
      padding: const EdgeInsets.only(left: 20),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
      child: Row(children: [
        Transform(transform: Matrix4.skewX(-0.3), child: Container(width: 12, height: 20, color: C.green)),
        const SizedBox(width: 10),
        const Text('Sports Swipe', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: C.text)),
        const Spacer(),
        Container(width: 1, color: C.line, margin: const EdgeInsets.symmetric(vertical: 8)),
        Semantics(
          label: 'Coin balance ${f.coins(balance)}',
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 20, 0),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Coins', style: TextStyle(fontSize: 12, color: C.dim)),
              Text(loaded ? f.coins(balance) : '—', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: C.text)),
            ]),
          ),
        ),
      ]),
    );
  }
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  late final AppLifecycleListener _life;
  StreamSubscription<QueueEvent>? _events;
  Timer? _poll;
  bool _showingResults = false;

  @override
  void initState() {
    super.initState();
    // Held picks go out immediately when the app is hidden.
    _life = AppLifecycleListener(
      onHide: () => ref.read(pickQueueProvider.notifier).flush(),
      onPause: () => ref.read(pickQueueProvider.notifier).flush(),
      onResume: () => ref.read(summaryProvider.notifier).refresh(),
    );
    _events = ref.read(pickQueueProvider.notifier).events.listen((e) {
      if (!mounted || !e.rejected) return;
      final msg = switch (e.code) {
        'pick_closed' => 'Pick closed · no coins used.',
        'insufficient_coins' => 'Not enough coins · no coins used.',
        _ => e.message.isEmpty ? 'Pick not accepted.' : e.message,
      };
      toast(context, msg, ok: false);
    });
    // Picks are graded by the worker; check for new results periodically.
    _poll = Timer.periodic(const Duration(seconds: 45), (_) => ref.read(summaryProvider.notifier).refresh());
  }

  @override
  void dispose() {
    _life.dispose();
    _events?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _maybeShowResults(Summary s) async {
    if (_showingResults || s.unrevealed == 0) return;
    _showingResults = true;
    try {
      await showResultsSheet(context, ref);
    } finally {
      _showingResults = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(summaryProvider, (prev, next) {
      if (next.unrevealed > (prev?.unrevealed ?? 0)) _maybeShowResults(next);
    });
    final summary = ref.watch(summaryProvider);
    final queued = ref.watch(pickQueueProvider).length;
    final badge = summary.pending + queued;
    const items = [
      (Icons.crop_portrait_rounded, 'Play'),
      (Icons.receipt_long_outlined, 'My picks'),
      (Icons.people_outline, 'Social'),
      (Icons.chat_outlined, 'AI'),
      (Icons.person_outline, 'Profile'),
    ];
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          const AppHeader(),
          Expanded(child: widget.shell),
        ]),
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(color: C.bg, border: Border(top: BorderSide(color: C.line))),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 66,
            child: Row(children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => widget.shell.goBranch(i, initialLocation: i == widget.shell.currentIndex),
                    child: Semantics(
                      selected: i == widget.shell.currentIndex,
                      label: i == 1 && badge > 0 ? '${items[i].$2}, $badge pending' : items[i].$2,
                      button: true,
                      excludeSemantics: true,
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Stack(clipBehavior: Clip.none, children: [
                          Icon(items[i].$1, color: i == widget.shell.currentIndex ? C.green : C.dim, size: 24),
                          if (i == 1 && badge > 0)
                            Positioned(
                              right: -16,
                              top: -8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                color: const Color(0xFFD5F5C8),
                                child: Text('$badge', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF0D2416))),
                              ),
                            ),
                        ]),
                        const SizedBox(height: 6),
                        Text(items[i].$2,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: i == widget.shell.currentIndex ? FontWeight.w700 : FontWeight.w500,
                              color: i == widget.shell.currentIndex ? C.green : C.dim,
                            )),
                      ]),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Screen scaffold for pushed routes inside a tab (keeps header + nav).
class TabPage extends StatelessWidget {
  const TabPage({super.key, required this.children, this.back, this.onRefresh, this.controller});
  final List<Widget> children;
  final String? back;
  final Future<void> Function()? onRefresh;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        if (back != null)
          Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              onTap: () => context.canPop() ? context.pop() : context.go('/play'),
              child: Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text('← $back', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              ),
            ),
          ),
        ...children,
      ],
    );
    if (onRefresh == null) return list;
    return RefreshIndicator(onRefresh: onRefresh!, color: C.green, child: list);
  }
}
