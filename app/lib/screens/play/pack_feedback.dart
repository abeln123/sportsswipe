import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preloaded, short material cues. Playback failures never interrupt a purchase.
class PackFeedback {
  static final instance = PackFeedback();
  final _players = <String, AudioPlayer>{};
  Future<void>? _loading;
  bool sound = true;
  bool haptics = true;

  Future<void> preload() => _loading ??= _load();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    sound = prefs.getBool('pack.sound') ?? true;
    haptics = prefs.getBool('pack.haptics') ?? true;
    for (final cue in ['grip', 'tear', 'brush', 'square', 'swoosh']) {
      try {
        final player = AudioPlayer();
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setVolume(
          switch (cue) {
            'brush' => .25,
            'swoosh' => .32,
            _ => .45,
          },
        );
        await player.setSourceAsset('audio/$cue.wav');
        _players[cue] = player;
      } catch (_) {
        /* Audio can be unavailable on a device or in a browser. */
      }
    }
  }

  Future<void> play(String cue) async {
    if (!sound) return;
    try {
      final player = _players[cue];
      await player?.seek(Duration.zero);
      await player?.resume();
    } catch (_) {}
  }

  Future<void> stop() async {
    for (final player in _players.values) {
      try {
        await player.stop();
      } catch (_) {}
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pack.sound', sound);
    await prefs.setBool('pack.haptics', haptics);
    if (!sound) await stop();
  }
}
