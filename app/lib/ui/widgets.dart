import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/format.dart' as f;
import '../core/theme.dart';

class PrimaryButton extends StatelessWidget {
  const PrimaryButton(this.label, {super.key, required this.onPressed, this.busy = false, this.focusRing = false});

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final bool focusRing;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return Container(
      padding: focusRing ? const EdgeInsets.all(3) : EdgeInsets.zero,
      decoration: focusRing
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: C.green, width: 1.5),
            )
          : null,
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: TextButton(
          onPressed: enabled ? onPressed : null,
          style: TextButton.styleFrom(
            backgroundColor: enabled ? C.green : C.disabled,
            foregroundColor: enabled ? const Color(0xFF0D2416) : C.dim,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, fontFamily: 'Inter'),
          ),
          child: busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0D2416)))
              : Text(label),
        ),
      ),
    );
  }
}

class GhostButton extends StatelessWidget {
  const GhostButton(this.label, {super.key, required this.onPressed, this.color = C.text, this.bold = false});

  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final bool bold;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: color,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: Text(label, style: TextStyle(fontSize: 15, fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
      );
}

/// "Label →" link style used throughout the screens.
class ArrowLink extends StatelessWidget {
  const ArrowLink(this.label, {super.key, required this.onTap, this.color = C.text});

  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('$label →', style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 14)),
        ),
      );
}

/// Underlined text tabs (Pending / Settled, Friends / Messages / Leagues).
class UnderTabs extends StatelessWidget {
  const UnderTabs({super.key, required this.labels, required this.index, required this.onChanged, this.counts, this.trailing});

  final List<String> labels;
  final List<int>? counts;
  final int index;
  final ValueChanged<int> onChanged;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final compact = trailing != null;
    return Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < labels.length; i++)
            InkWell(
              onTap: () => onChanged(i),
              child: Container(
                padding: EdgeInsets.fromLTRB(compact ? 2 : 6, 12, compact ? 6 : 14, 10),
                margin: EdgeInsets.only(right: compact ? 6 : 10),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: i == index ? C.green : Colors.transparent, width: 2)),
                ),
                child: Row(children: [
                  Text(labels[i],
                      style: TextStyle(
                          fontSize: compact ? 14.5 : 15,
                          fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                          color: i == index ? (counts == null ? C.green : C.text) : C.dim)),
                  if (counts != null) ...[
                    const SizedBox(width: 10),
                    Text('${counts![i]}', style: const TextStyle(fontSize: 13, color: C.dim, fontWeight: FontWeight.w600)),
                  ],
                ]),
              ),
            ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class PageTitle extends StatelessWidget {
  const PageTitle(this.title, [this.subtitle, Key? key]) : super(key: key);
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: T.h1),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(subtitle!, style: T.dim),
          ],
        ]),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(children: [
          Icon(icon, color: C.dim, size: 36),
          const SizedBox(height: 14),
          Text(title, style: T.h2, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(body, style: T.dim, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 40), action!],
        ]),
      );
}

class Hr extends StatelessWidget {
  const Hr({super.key, this.v = 18});
  final double v;
  @override
  Widget build(BuildContext context) => Container(height: 1, color: C.line, margin: EdgeInsets.symmetric(vertical: v));
}

/// Initials block with a colored left rule (friends, profile).
class InitialsBadge extends StatelessWidget {
  const InitialsBadge(this.initials, {super.key, this.color = const Color(0xFF8CC8E8), this.size = 18});
  final String initials;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: size * 0.6, vertical: size * 0.5),
        decoration: BoxDecoration(border: Border(left: BorderSide(color: color, width: 2))),
        child: Text(initials, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: size)),
      );
}

String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
}

/// Three-segment progress: locked, live, final.
class StageBar extends StatelessWidget {
  const StageBar({super.key, required this.stage});
  final String stage;

  @override
  Widget build(BuildContext context) {
    final n = switch (stage) { 'final' => 3, 'live' => 2, _ => 1 };
    return Row(children: [
      for (var i = 0; i < 3; i++) ...[
        if (i > 0) const SizedBox(width: 3),
        Expanded(child: Container(height: 3, color: i < n ? const Color(0xFFA9C9B7) : const Color(0xFF34474A))),
      ],
    ]);
  }
}

class SideText extends StatelessWidget {
  const SideText({super.key, required this.side, required this.line, this.rest, this.size = 15, this.label});
  final String side;
  final double line;
  final String? rest;
  final double size;

  /// Replaces "Over 24.5" for game lines, e.g. "BUF -3.5".
  final String? label;

  @override
  Widget build(BuildContext context) => Text.rich(
        TextSpan(children: [
          TextSpan(
            text: label ?? '${f.cap(side)} ${f.line(line)}',
            style: TextStyle(color: side == 'over' ? C.over : C.under, fontWeight: FontWeight.w700, fontSize: size),
          ),
          if (rest != null) TextSpan(text: '  $rest', style: TextStyle(color: C.text, fontSize: size)),
        ]),
      );
}

Future<R?> showSheet<R>(BuildContext context, Widget Function(BuildContext) builder) {
  return showModalBottomSheet<R>(
    context: context,
    isScrollControlled: true,
    backgroundColor: C.sheet,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      side: BorderSide(color: C.line),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.9),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, 28, 24, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: builder(ctx),
        ),
      ),
    ),
  );
}

void toast(BuildContext context, String message, {String? action, VoidCallback? onAction, bool ok = true, Duration? duration}) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(
    SnackBar(
      duration: duration ?? const Duration(seconds: 4),
      content: Row(
        children: [
          Icon(ok ? Icons.check : Icons.info_outline, size: 18, color: ok ? C.green : C.danger),
          const SizedBox(width: 14),
          Expanded(child: Text(message)),
        ],
      ),
      action: action == null ? null : SnackBarAction(label: action, textColor: C.text, onPressed: onAction ?? () {}),
    ),
  );
}

/// A bounded coin amount: step by 25 or enter an exact value.
class WagerControl extends StatelessWidget {
  const WagerControl({super.key, required this.value, required this.max, required this.onChanged, this.dark = false});
  final int value, max;
  final ValueChanged<int> onChanged;
  final bool dark;
  static const step = 25;
  int get cap => max.clamp(0, 100000);

  Future<void> _edit(BuildContext context) async {
    final result = await showDialog<int>(
      context: context,
      builder: (_) => _WagerEntry(value: value, max: cap),
    );
    if (result != null) onChanged(result.clamp(0, cap));
  }

  @override
  Widget build(BuildContext context) {
    final fg = dark ? C.text : C.ink;
    return Focus(
      onKeyEvent: (_, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
          onChanged((value + step).clamp(0, cap));
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
          onChanged((value - step).clamp(0, cap));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Decrease wager by 25',
            constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
            onPressed: value > 0 ? () => onChanged((value - step).clamp(0, cap)) : null,
            icon: Icon(Icons.remove, color: fg.withValues(alpha: value > 0 ? 1 : .3), size: 20),
          ),
          Semantics(
            label: 'Enter coin wager',
            value: '$value coins',
            button: true,
            child: InkWell(
              onTap: () => _edit(context),
              child: Container(
                constraints: const BoxConstraints(minWidth: 60, minHeight: 54),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: fg.withValues(alpha: .3))),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      f.coins(value),
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: fg),
                    ),
                    Text('coins', style: TextStyle(fontSize: 11, color: fg.withValues(alpha: .7))),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Increase wager by 25',
            constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
            onPressed: value < cap ? () => onChanged((value + step).clamp(0, cap)) : null,
            icon: Icon(Icons.add, color: fg.withValues(alpha: value < cap ? 1 : .3), size: 20),
          ),
        ],
      ),
    );
  }
}

class _WagerEntry extends StatefulWidget {
  const _WagerEntry({required this.value, required this.max});
  final int value, max;
  @override
  State<_WagerEntry> createState() => _WagerEntryState();
}

class _WagerEntryState extends State<_WagerEntry> {
  late final _amount = TextEditingController(text: '${widget.value}');
  String? _error;
  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = int.tryParse(_amount.text);
    if (amount == null || amount < 0 || amount > widget.max) {
      setState(() => _error = 'Enter 0–${f.coins(widget.max)} coins.');
      return;
    }
    Navigator.pop(context, amount);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Coin wager'),
    content: TextField(
      controller: _amount,
      autofocus: true,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
      decoration: InputDecoration(labelText: 'Amount', suffixText: 'coins', errorText: _error),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(onPressed: _submit, child: const Text('Set wager')),
    ],
  );
}

class Labeled extends StatelessWidget {
  const Labeled(this.label, this.value, {super.key, this.suffix, this.valueColor = C.text});
  final String label;
  final String value;
  final String? suffix;
  final Color valueColor;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: T.small.copyWith(fontSize: 13)),
        const SizedBox(height: 6),
        Text.rich(TextSpan(children: [
          TextSpan(text: value, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: valueColor)),
          if (suffix != null) TextSpan(text: suffix, style: const TextStyle(fontSize: 15, color: C.dim)),
        ])),
      ]);
}

/// Placeholder shown while a screen loads: the rough shape of the content
/// with a moving sheen, instead of a spinner.
class Loading extends StatelessWidget {
  const Loading({super.key}) : card = false;
  const Loading.card({super.key}) : card = true;
  final bool card;

  @override
  Widget build(BuildContext context) {
    if (card) {
      return Shimmer(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
          child: Center(child: AspectRatio(aspectRatio: 0.62, child: Container(decoration: _block(18)))),
        ),
      );
    }
    return Shimmer(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        children: [
          FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: 0.45, child: Container(height: 26, decoration: _block(6))),
          const SizedBox(height: 10),
          FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: 0.7, child: Container(height: 14, decoration: _block(4))),
          const SizedBox(height: 24),
          for (var i = 0; i < 5; i++) ...[
            Row(children: [
              Container(width: 40, height: 40, decoration: _block(20)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  FractionallySizedBox(widthFactor: i.isEven ? 0.6 : 0.45, child: Container(height: 13, decoration: _block(4))),
                  const SizedBox(height: 8),
                  FractionallySizedBox(widthFactor: i.isEven ? 0.35 : 0.5, child: Container(height: 11, decoration: _block(4))),
                ]),
              ),
            ]),
            const SizedBox(height: 22),
          ],
        ],
      ),
    );
  }

  static BoxDecoration _block(double r) => BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(r));
}

/// Sweeps a soft highlight across its child, for skeleton placeholders.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _c,
          child: widget.child,
          builder: (context, child) => ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (r) {
              final x = -1.0 + 3.0 * _c.value;
              return LinearGradient(
                begin: Alignment(x - 1, -0.3),
                end: Alignment(x, 0.3),
                colors: const [Color(0x00FFFFFF), Color(0x14FFFFFF), Color(0x00FFFFFF)],
              ).createShader(r);
            },
            child: child,
          ),
        ),
      );
}

/// Folds a bar away (height and opacity) when [visible] turns false.
class Collapse extends StatelessWidget {
  const Collapse({super.key, required this.visible, required this.child, this.alignment = Alignment.topCenter});
  final bool visible;
  final Widget child;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(end: visible ? 1 : 0),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        child: child,
        builder: (context, t, child) => t == 0
            ? const SizedBox.shrink()
            : ClipRect(
                child: Align(
                  alignment: alignment,
                  heightFactor: t,
                  child: Opacity(opacity: t, child: IgnorePointer(ignoring: !visible, child: child)),
                ),
              ),
      );
}

class ErrorText extends StatelessWidget {
  const ErrorText(this.error, {super.key, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    final text = error is ApiException ? (error as ApiException).message : 'Could not load this view right now.';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: T.dim, textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 8),
            GhostButton('Try again', onPressed: onRetry, color: C.green),
          ],
        ],
      ),
    );
  }
}
