import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A saved recording: a WAV file plus a sidecar `.json` file (same stem)
/// holding its title, transcript and duration.
class Recording {
  Recording({
    required this.wavPath,
    required this.title,
    required this.createdAt,
    required this.duration,
    required this.transcript,
  });

  final String wavPath;

  String title;
  final DateTime createdAt;
  final Duration duration;
  final String transcript;

  String get id => p.basenameWithoutExtension(wavPath);

  String get sidecarPath => p.join(p.dirname(wavPath), '$id.json');

  Map<String, Object?> toJson() => {
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'durationMs': duration.inMilliseconds,
        'transcript': transcript,
      };

  static Recording fromJson(String wavPath, Map<String, Object?> json) =>
      Recording(
        wavPath: wavPath,
        title: json['title'] as String? ?? p.basenameWithoutExtension(wavPath),
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '') ??
                File(wavPath).lastModifiedSync(),
        duration:
            Duration(milliseconds: json['durationMs'] as int? ?? 0),
        transcript: json['transcript'] as String? ?? '',
      );
}

/// Lists, renames and deletes recordings in a directory.
class RecordingsRepository {
  RecordingsRepository(this.dir);

  /// Directory holding the `rec-*.wav` / `rec-*.json` pairs.
  final String dir;

  /// All recordings in [dir], newest first. WAVs without a sidecar (e.g.
  /// from a crashed session) are still listed with fallback metadata.
  Future<List<Recording>> list() async {
    final directory = Directory(dir);
    if (!await directory.exists()) return [];

    final recordings = <Recording>[];
    await for (final entity in directory.list()) {
      if (entity is! File || p.extension(entity.path) != '.wav') continue;
      final wavPath = entity.path;
      var recording = Recording(
        wavPath: wavPath,
        title: p.basenameWithoutExtension(wavPath),
        createdAt: entity.lastModifiedSync(),
        duration: Duration.zero,
        transcript: '',
      );
      final sidecar = File(p.join(dir, '${p.basenameWithoutExtension(wavPath)}.json'));
      if (await sidecar.exists()) {
        try {
          final json = jsonDecode(await sidecar.readAsString());
          recording = Recording.fromJson(wavPath, json as Map<String, Object?>);
        } on FormatException {
          // Corrupt sidecar: fall back to file-derived metadata.
        }
      }
      recordings.add(recording);
    }
    recordings.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return recordings;
  }

  /// Updates the recording's title (stored in the sidecar only; the audio
  /// file keeps its original name).
  Future<void> rename(Recording recording, String newTitle) async {
    final sidecar = File(recording.sidecarPath);
    final data = Map<String, Object?>.from(await _readOrBuild(recording))
      ..['title'] = newTitle;
    await sidecar.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    recording.title = newTitle;
  }

  /// Deletes the WAV file and its sidecar.
  Future<void> delete(Recording recording) async {
    await File(recording.wavPath).delete();
    final sidecar = File(recording.sidecarPath);
    if (await sidecar.exists()) await sidecar.delete();
  }

  Future<Map<String, Object?>> _readOrBuild(Recording recording) async {
    final sidecar = File(recording.sidecarPath);
    if (await sidecar.exists()) {
      try {
        return jsonDecode(await sidecar.readAsString()) as Map<String, Object?>;
      } on FormatException {
        // fall through
      }
    }
    return recording.toJson();
  }
}
