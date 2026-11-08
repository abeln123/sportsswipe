import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where the player is inside the Play tab.
@immutable
class PlayMode {
  const PlayMode({this.contests = false, this.parlay = false, this.sport = 'all', this.revision = 0});
  final bool contests;
  final bool parlay;
  final String sport;
  final int revision;

  /// The header label: the one piece of Play navigation always on screen.
  String get place => contests
      ? 'Contests'
      : parlay
      ? 'Parlays'
      : 'Packs';

  PlayMode copyWith({bool? contests, bool? parlay, String? sport, int? revision}) => PlayMode(
    contests: contests ?? this.contests,
    parlay: parlay ?? this.parlay,
    sport: sport ?? this.sport,
    revision: revision ?? this.revision,
  );
}

class PlayModeNotifier extends Notifier<PlayMode> {
  @override
  PlayMode build() => const PlayMode();
  void set(PlayMode m) => state = m;
}

final playModeProvider = NotifierProvider<PlayModeNotifier, PlayMode>(PlayModeNotifier.new);

/// Whether the Play menu (mode and sport) is open under the header.
class PlayMenu extends Notifier<bool> {
  @override
  bool build() => false;
  void open() => state = true;
  void close() {
    if (state) state = false;
  }

  void toggle() => state = !state;
}

final playMenuProvider = NotifierProvider<PlayMenu, bool>(PlayMenu.new);

/// How far the card is being pulled down, in pixels. The closed menu follows
/// it out of the header.
final playMenuPull = ValueNotifier<double>(0);

/// Compact navigation is used only while a card session is on screen.
class PlayCards extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) {
    if (state != value) state = value;
  }
}

final playCardsProvider = NotifierProvider<PlayCards, bool>(PlayCards.new);
