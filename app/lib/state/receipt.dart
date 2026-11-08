import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pick_queue.dart';

/// The one-line acknowledgment above the tabs for the most recent pick.
@immutable
class Receipt {
  const Receipt({required this.commandId, required this.text, this.onUndo, this.status = 'holding', this.error});
  final String commandId;

  /// "[Athlete] · Over 70.5 · 200 coins"
  final String text;
  final VoidCallback? onUndo;

  /// holding (undo still possible), sending, slow, submitted, rejected.
  final String status;
  final String? error;

  Receipt copyWith({String? status, String? error}) =>
      Receipt(commandId: commandId, text: text, onUndo: onUndo, status: status ?? this.status, error: error ?? this.error);
}

class ReceiptNotifier extends Notifier<Receipt?> {
  StreamSubscription<QueueEvent>? _sub;
  Timer? _hide;
  Timer? _slow;

  @override
  Receipt? build() {
    _sub = ref.read(pickQueueProvider.notifier).events.listen(_onEvent);
    ref.listen(pickQueueProvider, (_, queue) => _track(queue));
    ref.onDispose(() {
      _sub?.cancel();
      _hide?.cancel();
      _slow?.cancel();
    });
    return null;
  }

  void show(String commandId, String text, {VoidCallback? onUndo}) {
    _hide?.cancel();
    _slow?.cancel();
    state = Receipt(commandId: commandId, text: text, onUndo: onUndo);
  }

  /// Undo pressed: the pick is withdrawn and the receipt goes away.
  void undo() {
    final r = state;
    if (r == null || r.status != 'holding') return;
    if (ref.read(pickQueueProvider.notifier).undo(r.commandId)) {
      r.onUndo?.call();
      state = null;
    }
  }

  void clear() => state = null;

  void _track(List<PendingIntent> queue) {
    final r = state;
    if (r == null || r.status == 'submitted' || r.status == 'rejected') return;
    final i = queue.where((e) => e.commandId == r.commandId).firstOrNull;
    if (i == null) return;
    if (i.state == 'checking' && r.status != 'slow') {
      state = r.copyWith(status: 'slow');
    } else if (i.state == 'sending' && r.status == 'holding') {
      state = r.copyWith(status: 'sending');
      // A normal send is quick; only say "Submitting" when it is not.
      _slow?.cancel();
      _slow = Timer(const Duration(milliseconds: 900), () {
        if (state?.commandId == r.commandId && state?.status == 'sending') state = state!.copyWith(status: 'slow');
      });
    }
  }

  void _onEvent(QueueEvent e) {
    final r = state;
    if (r == null || r.commandId != e.intent.commandId) return;
    _slow?.cancel();
    state = e.rejected
        ? r.copyWith(
            status: 'rejected',
            error: switch (e.code) {
              'pick_closed' => 'Pick closed · no coins used',
              'insufficient_coins' => 'Not enough coins · no coins used',
              _ => 'Not accepted · no coins used',
            })
        : r.copyWith(status: 'submitted');
    _hide?.cancel();
    _hide = Timer(Duration(seconds: e.rejected ? 5 : 3), () {
      if (state?.commandId == r.commandId) state = null;
    });
  }
}

final receiptProvider = NotifierProvider<ReceiptNotifier, Receipt?>(ReceiptNotifier.new);
