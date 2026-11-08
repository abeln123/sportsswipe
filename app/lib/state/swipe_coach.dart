import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session.dart';

/// Whether to show the first-run swipe tutorial. Stored per account so every
/// new person signing up on a shared phone sees it once.
class SwipeCoach extends Notifier<bool> {
  String? _userId;

  @override
  bool build() {
    _userId = ref.watch(sessionProvider).value?.id;
    if (_userId != null) _load(_userId!);
    return false;
  }

  String _key(String id) => 'ss.coach.$id';

  Future<void> _load(String id) async {
    final prefs = await SharedPreferences.getInstance();
    if (_userId == id && prefs.getBool(_key(id)) != true) state = true;
  }

  Future<void> done() async {
    if (!state) return;
    state = false;
    final id = _userId;
    if (id == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key(id), true);
  }
}

final swipeCoachProvider = NotifierProvider<SwipeCoach, bool>(SwipeCoach.new);
