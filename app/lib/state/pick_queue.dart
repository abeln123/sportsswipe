import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/api.dart';
import 'session.dart';

const undoWindow = Duration(seconds: 5);
const _uuid = Uuid();

/// A locked pick that has not been confirmed by the server yet. It keeps the
/// same command id across retries and app restarts.
class PendingIntent {
  PendingIntent({
    required this.commandId,
    required this.path,
    required this.payload,
    required this.stake,
    required this.label,
    required this.sendAt,
    this.state = 'holding',
  });

  factory PendingIntent.fromJson(Map<String, dynamic> j) => PendingIntent(
        commandId: j['commandId'] as String,
        path: j['path'] as String,
        payload: (j['payload'] as Map).cast<String, dynamic>(),
        stake: (j['stake'] as num).toInt(),
        label: j['label'] as String,
        sendAt: DateTime.parse(j['sendAt'] as String),
        state: j['state'] as String? ?? 'holding',
      );

  final String commandId;
  final String path;
  final Map<String, dynamic> payload;
  final int stake;
  final String label;
  final DateTime sendAt;

  /// holding (undo window), sending, checking (outcome unknown).
  String state;

  Map<String, dynamic> toJson() => {
        'commandId': commandId,
        'path': path,
        'payload': payload,
        'stake': stake,
        'label': label,
        'sendAt': sendAt.toIso8601String(),
        'state': state,
      };
}

class QueueEvent {
  QueueEvent.accepted(this.intent, this.body) : rejected = false;
  QueueEvent.rejected(this.intent, this.body) : rejected = true;
  final PendingIntent intent;
  final Map<String, dynamic> body;
  final bool rejected;
  String get message => body['message']?.toString() ?? '';
  String? get code => body['code']?.toString();
}

class PickQueue extends Notifier<List<PendingIntent>> {
  final _events = StreamController<QueueEvent>.broadcast();
  final _timers = <String, Timer>{};
  final _inFlight = <String>{};
  String? _userId;

  Stream<QueueEvent> get events => _events.stream;

  @override
  List<PendingIntent> build() {
    final me = ref.watch(sessionProvider).value;
    _userId = me?.id;
    ref.onDispose(() {
      for (final t in _timers.values) {
        t.cancel();
      }
    });
    if (_userId != null) Future.microtask(_restore);
    return [];
  }

  String get _key => 'ss.queue.$_userId';

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    final items = (jsonDecode(raw) as List).map((e) => PendingIntent.fromJson((e as Map).cast<String, dynamic>())).toList();
    state = items;
    // Anything restored after a restart is past its undo window: send now.
    for (final i in items) {
      _send(i);
    }
  }

  Future<void> _persist() async {
    if (_userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(state.map((e) => e.toJson()).toList()));
  }

  /// Coins committed locally but not yet confirmed; subtracted from the
  /// displayed balance while waiting.
  int get pendingStake => state.fold(0, (s, i) => s + i.stake);

  String add({required String path, required Map<String, dynamic> payload, required int stake, required String label}) {
    final id = _uuid.v4();
    final intent = PendingIntent(
      commandId: id,
      path: path,
      payload: {...payload, 'commandId': id},
      stake: stake,
      label: label,
      sendAt: DateTime.now().add(undoWindow),
    );
    state = [...state, intent];
    _persist();
    _timers[id] = Timer(undoWindow, () => _send(intent));
    return id;
  }

  bool undo(String commandId) {
    final i = state.where((e) => e.commandId == commandId).firstOrNull;
    if (i == null || i.state != 'holding') return false;
    _timers.remove(commandId)?.cancel();
    state = state.where((e) => e.commandId != commandId).toList();
    _persist();
    return true;
  }

  /// Sends every held pick now (deck finished or app backgrounded).
  void flush() {
    for (final i in [...state]) {
      if (i.state == 'holding') {
        _timers.remove(i.commandId)?.cancel();
        _send(i);
      }
    }
  }

  void _update() {
    state = [...state];
    _persist();
  }

  Future<void> _send(PendingIntent i, {int attempt = 0}) async {
    if (_inFlight.contains(i.commandId)) return;
    _inFlight.add(i.commandId);
    i.state = attempt == 0 ? 'sending' : 'checking';
    _update();
    final r = await api.raw('POST', i.path, body: i.payload);
    _inFlight.remove(i.commandId);
    if (r.status == 0 || r.status >= 500) {
      // Unknown outcome: keep the intent and retry the same command id.
      i.state = 'checking';
      _update();
      final delay = Duration(seconds: [2, 4, 8, 15, 30][attempt.clamp(0, 4)]);
      _timers[i.commandId] = Timer(delay, () => _send(i, attempt: attempt + 1));
      return;
    }
    state = state.where((e) => e.commandId != i.commandId).toList();
    _persist();
    final body = r.map;
    if (r.ok) {
      final balance = (body['balance'] as num?)?.toInt();
      if (balance != null) ref.read(summaryProvider.notifier).applyBalance(balance);
      _events.add(QueueEvent.accepted(i, body));
    } else {
      _events.add(QueueEvent.rejected(i, body));
    }
    ref.read(summaryProvider.notifier).refresh();
  }
}

final pickQueueProvider = NotifierProvider<PickQueue, List<PendingIntent>>(PickQueue.new);

/// Header balance net of pending debits.
final displayBalanceProvider = Provider<int>((ref) {
  final s = ref.watch(summaryProvider);
  final pending = ref.watch(pickQueueProvider).fold<int>(0, (a, i) => a + i.stake);
  return s.balance - pending;
});
