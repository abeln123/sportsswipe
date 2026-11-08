import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';

class Me {
  Me(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get displayName => json['displayName'] as String? ?? '';
  String get handleTag => json['handleTag'] as String? ?? '';
  String get bio => json['bio'] as String? ?? '';
  bool get isAdmin => json['isAdmin'] == true;
  int? get favoriteTeamId => (json['favoriteTeamId'] as num?)?.toInt();
  String get visibility => json['visibility'] as String? ?? 'friends';
  String get initials {
    final parts = displayName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
  }
}

/// Lets go_router re-run redirects when the session changes.
final authListenable = ValueNotifier<bool?>(null);

class SessionNotifier extends AsyncNotifier<Me?> {
  @override
  Future<Me?> build() async {
    await api.loadToken();
    final r = await api.raw('GET', '/auth/me');
    final me = r.ok ? Me(r.map) : null;
    authListenable.value = me != null;
    return me;
  }

  Future<void> _set(Map<String, dynamic> body) async {
    await api.setToken(body['sessionToken'] as String?);
    state = AsyncData(Me(body));
    authListenable.value = true;
  }

  Future<void> login(String email, String password) async {
    await _set(await api.post('/auth/login', {'email': email, 'password': password}));
  }

  Future<void> signup(String email, String password, String displayName) async {
    await _set(await api.post('/auth/signup', {'email': email, 'password': password, 'displayName': displayName}));
  }

  Future<void> refreshMe() async {
    final r = await api.raw('GET', '/auth/me');
    if (r.ok) state = AsyncData(Me(r.map));
  }

  Future<void> logout() async {
    await api.raw('POST', '/auth/logout', body: {});
    await api.setToken(null);
    state = const AsyncData(null);
    authListenable.value = false;
  }
}

final sessionProvider = AsyncNotifierProvider<SessionNotifier, Me?>(SessionNotifier.new);

class Summary {
  const Summary({this.balance = 0, this.pending = 0, this.unrevealed = 0, this.isAdmin = false, this.loaded = false});
  final int balance;
  final int pending;
  final int unrevealed;
  final bool isAdmin;
  final bool loaded;
}

/// Header coins and the My picks badge. Refreshed after every receipt.
class SummaryNotifier extends Notifier<Summary> {
  @override
  Summary build() {
    final me = ref.watch(sessionProvider).value;
    if (me != null) Future.microtask(refresh);
    return const Summary();
  }

  Future<void> refresh() async {
    final r = await api.raw('GET', '/me/summary');
    if (!r.ok) return;
    final m = r.map;
    state = Summary(
      balance: (m['balance'] as num).toInt(),
      pending: (m['pendingCount'] as num).toInt(),
      unrevealed: (m['unrevealedCount'] as num).toInt(),
      isAdmin: m['isAdmin'] == true,
      loaded: true,
    );
  }

  void applyBalance(int balance) {
    state = Summary(
      balance: balance,
      pending: state.pending,
      unrevealed: state.unrevealed,
      isAdmin: state.isAdmin,
      loaded: true,
    );
  }
}

final summaryProvider = NotifierProvider<SummaryNotifier, Summary>(SummaryNotifier.new);
