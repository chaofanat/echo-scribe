/// Which device a recording captures from. Stored in the sidecar as [id] so
/// recordings made as 系统内录 or imported files stay recognizable in the
/// library.
enum AudioSource {
  microphone('mic'),
  systemAudio('system'),
  imported('import');

  const AudioSource(this.id);

  final String id;

  /// Parses a sidecar value; anything unknown (or from older recordings that
  /// predate the field) reads as a microphone recording.
  static AudioSource fromId(String? id) {
    if (id == systemAudio.id) return systemAudio;
    if (id == imported.id) return imported;
    return microphone;
  }
}
