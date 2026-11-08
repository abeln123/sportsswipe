import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/format.dart' as f;
import '../core/theme.dart';
import '../screens/picks_screen.dart';
import '../state/pick_queue.dart';
import '../state/play.dart';
import '../state/receipt.dart';
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
    if (!kIsWeb || size.width < 560) return child;
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
                child: Stack(
                  children: [
                    Positioned.fill(child: child),
                    const Positioned(top: 0, left: 0, right: 0, child: _StatusBar()),
                  ],
                ),
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
      child: Stack(
        children: [
          const Positioned(
            left: 34,
            top: 14,
            child: Text(
              '9:41',
              style: TextStyle(color: C.text, fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ),
          Align(
            alignment: const Alignment(0, 0.2),
            child: Container(
              width: 118,
              height: 30,
              decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(20)),
            ),
          ),
          const Positioned(right: 30, top: 14, child: Icon(Icons.signal_cellular_alt, size: 16, color: C.text)),
        ],
      ),
    ),
  );
}

/// Top bar with one Play menu on the left and the coin balance on the right.
class AppHeader extends ConsumerWidget {
  const AppHeader({super.key, this.play = false});
  final bool play;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balance = ref.watch(displayBalanceProvider);
    final loaded = ref.watch(summaryProvider).loaded;
    final mode = ref.watch(playModeProvider);
    final open = ref.watch(playMenuProvider);
    void toggle() => ref.read(playMenuProvider.notifier).toggle();
    return SizedBox(
      height: 48,
      child: Padding(
        padding: EdgeInsets.only(left: play ? 8 : 16, right: play ? 4 : 16),
        child: Row(
          children: [
            if (play)
              Semantics(
                button: true,
                expanded: open,
                label: '${mode.place}, change mode and sport',
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: toggle,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                    child: Center(child: _MenuGlyph(open: open)),
                  ),
                ),
              ),
            const Spacer(),
            Semantics(
              label: 'Coin balance ${f.coins(balance)}',
              excludeSemantics: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CoinGlyph(),
                  const SizedBox(width: 6),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      loaded ? f.coins(balance) : '—',
                      key: ValueKey(loaded ? balance : -1),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: C.text,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A plain coin mark: a ring with a small inner ring.
class CoinGlyph extends StatelessWidget {
  const CoinGlyph({super.key, this.size = 16, this.color = C.dim});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: color, width: 1.6),
    ),
    child: Center(
      child: Container(
        width: size * 0.42,
        height: size * 0.42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 1.2),
        ),
      ),
    ),
  );
}

/// Three lines that fold into an X while the menu is open.
class _MenuGlyph extends StatelessWidget {
  const _MenuGlyph({required this.open});
  final bool open;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: open ? 1 : 0),
    duration: const Duration(milliseconds: 220),
    curve: Curves.easeOutCubic,
    builder: (context, t, _) => CustomPaint(size: const Size(22, 16), painter: _MenuPainter(t)),
  );
}

class _MenuPainter extends CustomPainter {
  _MenuPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = C.text
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final w = size.width, h = size.height, c = h / 2;
    canvas.save();
    canvas.translate(w / 2, c);
    // Top and bottom lines rotate into an X; the middle one fades.
    for (final (dy, sign) in [(-c + 1, 1.0), (c - 1, -1.0)]) {
      canvas.save();
      canvas.translate(0, dy * (1 - t));
      canvas.rotate(sign * t * 0.785);
      canvas.drawLine(Offset(-w / 2 + 1, 0), Offset(w / 2 - 1, 0), p);
      canvas.restore();
    }
    p.color = C.text.withValues(alpha: 1 - t);
    canvas.drawLine(Offset(-w / 2 + 1 + t * 6, 0), Offset(w / 2 - 1 - t * 6, 0), p);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MenuPainter old) => old.t != t;
}

/// Two offset trading cards; the front one fills in when Play is selected.
class PlayGlyph extends StatelessWidget {
  const PlayGlyph({super.key, required this.selected, required this.color});
  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(24, 24), painter: _PlayPainter(selected, color));
}

class _PlayPainter extends CustomPainter {
  _PlayPainter(this.selected, this.color);
  final bool selected;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeJoin = StrokeJoin.round;
    void card(Offset c, double angle, {bool fill = false}) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(angle);
      final r = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: 12.5, height: 17), const Radius.circular(2.2));
      if (fill) {
        canvas.drawRRect(r, Paint()..color = color);
      } else {
        // Clear what is behind so the front card reads as on top.
        canvas.drawRRect(r, Paint()..color = C.bg);
        canvas.drawRRect(r, stroke);
      }
      canvas.restore();
    }

    card(const Offset(9.5, 11), -0.2);
    card(const Offset(14.5, 13), 0.12, fill: selected);
  }

  @override
  bool shouldRepaint(_PlayPainter old) => old.selected != selected || old.color != color;
}

/// The latest pick, quietly, above the tabs: what it was, then whether it can
/// still be undone, is going out, or went through.
class ReceiptBar extends ConsumerWidget {
  const ReceiptBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(receiptProvider);
    final still = MediaQuery.of(context).disableAnimations;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      transitionBuilder: (child, a) => still
          ? FadeTransition(opacity: a, child: child)
          : FadeTransition(
              opacity: a,
              child: SizeTransition(sizeFactor: a, alignment: Alignment.bottomCenter, child: child),
            ),
      child: r == null
          ? const SizedBox(key: ValueKey('none'), width: double.infinity)
          : Container(
              key: ValueKey(r.commandId),
              height: 40,
              padding: const EdgeInsets.only(left: 16, right: 6),
              decoration: const BoxDecoration(
                color: C.bg,
                border: Border(top: BorderSide(color: C.line)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      r.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5, color: C.text),
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: KeyedSubtree(key: ValueKey(r.status), child: _trailing(r, ref)),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _trailing(Receipt r, WidgetRef ref) => switch (r.status) {
    'holding' => TextButton(
      onPressed: () => ref.read(receiptProvider.notifier).undo(),
      style: TextButton.styleFrom(minimumSize: const Size(56, 40), foregroundColor: C.text),
      child: const Text(
        'Undo',
        style: TextStyle(fontWeight: FontWeight.w700, decoration: TextDecoration.underline),
      ),
    ),
    'slow' => const Padding(
      padding: EdgeInsets.only(right: 10),
      child: Text('Submitting…', style: TextStyle(fontSize: 13, color: C.dim)),
    ),
    'submitted' => const Padding(
      padding: EdgeInsets.only(right: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_rounded, size: 16, color: C.green),
          SizedBox(width: 4),
          Text(
            'Pick submitted',
            style: TextStyle(fontSize: 13, color: C.green, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    ),
    'rejected' => Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Text(r.error ?? 'Not accepted', style: const TextStyle(fontSize: 13, color: C.danger)),
    ),
    _ => const SizedBox(width: 10),
  };
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with SingleTickerProviderStateMixin {
  late final AppLifecycleListener _life;
  late final AnimationController _tabFade = AnimationController(vsync: this, duration: const Duration(milliseconds: 180), value: 1);
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
      // The receipt bar already reports its own pick.
      if (ref.read(receiptProvider)?.commandId == e.intent.commandId) return;
      final msg = switch (e.code) {
        'pick_closed' => 'Pick closed · no coins used.',
        'insufficient_coins' => 'Not enough coins · no coins used.',
        _ => e.message.isEmpty ? 'Pick not accepted.' : e.message,
      };
      toast(context, msg, ok: false);
    });
    // Picks are graded by the worker; check for new results periodically.
    _poll = Timer.periodic(const Duration(seconds: 45), (_) => ref.read(summaryProvider.notifier).refresh());
    _warmTabs();
  }

  /// Loads what each tab shows first, so switching tabs is instant.
  void _warmTabs() {
    final me = ref.read(sessionProvider).value;
    for (final path in [
      '/packs?sport=all',
      '/deck?sport=all&limit=20',
      '/contests/current',
      '/me/picks?status=pending',
      '/friends',
      '/friend-requests',
      '/leagues',
      '/threads',
      '/me/collection',
      '/analyst/suggestions',
      if (me != null) '/profiles/${me.id}/stats',
    ]) {
      api.prefetch(path);
    }
  }

  void _goBranch(int i) {
    ref.read(playMenuProvider.notifier).close();
    if (i != widget.shell.currentIndex) _tabFade.forward(from: 0);
    widget.shell.goBranch(i, initialLocation: i == widget.shell.currentIndex);
  }

  @override
  void dispose() {
    _tabFade.dispose();
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
    // Only results that have settled and not been seen yet.
    final badge = summary.unrevealed;
    final current = widget.shell.currentIndex;
    const items = [
      (Icons.style_outlined, 'Play'),
      (Icons.receipt_long_outlined, 'My picks'),
      (Icons.chat_outlined, 'AI'),
      (Icons.people_outline, 'Social'),
      (Icons.person_outline, 'Profile'),
    ];
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            AppHeader(play: current == 0),
            Expanded(
              child: FadeTransition(
                opacity: CurvedAnimation(parent: _tabFade, curve: Curves.easeOut),
                child: SlideTransition(
                  position: Tween(
                    begin: const Offset(0, 0.012),
                    end: Offset.zero,
                  ).animate(CurvedAnimation(parent: _tabFade, curve: Curves.easeOutCubic)),
                  child: widget.shell,
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ReceiptBar(),
          Container(
            decoration: const BoxDecoration(
              color: C.bg,
              border: Border(top: BorderSide(color: C.line)),
            ),
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: 66,
                child: Row(
                  children: [
                    for (var i = 0; i < items.length; i++)
                      Expanded(
                        child: InkWell(
                          onTap: () => _goBranch(i),
                          child: Semantics(
                            selected: i == widget.shell.currentIndex,
                            label: i == 1 && badge > 0 ? '${items[i].$2}, $badge new ${badge == 1 ? 'result' : 'results'}' : items[i].$2,
                            button: true,
                            excludeSemantics: true,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    if (i == 0)
                                      PlayGlyph(selected: current == 0, color: current == 0 ? C.green : C.dim)
                                    else
                                      Icon(items[i].$1, color: i == current ? C.green : C.dim, size: 24),
                                    if (i == 1 && badge > 0)
                                      Positioned(
                                        right: -16,
                                        top: -8,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                          color: const Color(0xFFD5F5C8),
                                          child: Text(
                                            '$badge',
                                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF0D2416)),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  items[i].$2,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: i == widget.shell.currentIndex ? FontWeight.w700 : FontWeight.w500,
                                    color: i == widget.shell.currentIndex ? C.green : C.dim,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
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
