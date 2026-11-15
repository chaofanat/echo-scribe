/// Which device a recording captures from. Stored in the sidecar as [id] so
/// recordings made as 系统内录 stay recognizable in the library.
enum AudioSource {
  microphone('mic'),
  systemAudio('system');

  const AudioSource(this.id);

  final String id;

  /// Parses a sidecar value; anything unknown (or from older recordings that
  /// predate the field) reads as a microphone recording.
  static AudioSource fromId(String? id) =>
      id == systemAudio.id ? systemAudio : microphone;
}
