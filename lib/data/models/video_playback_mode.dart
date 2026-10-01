enum VideoPlaybackMode {
  playOnce,
  loop,
  playAndAdvance;

  static VideoPlaybackMode fromJson(String? value) => switch (value) {
    'loop' => VideoPlaybackMode.loop,
    'playAndAdvance' => VideoPlaybackMode.playAndAdvance,
    _ => VideoPlaybackMode.playOnce,
  };
}
