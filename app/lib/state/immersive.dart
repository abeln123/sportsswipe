import 'package:flutter_riverpod/flutter_riverpod.dart';

/// True while someone is swiping a deck: the shell hides its menus so the
/// card has the whole screen. Swiping down on the card turns it off.
class Immersive extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) {
    if (state != value) state = value;
  }
}

final immersiveProvider = NotifierProvider<Immersive, bool>(Immersive.new);
