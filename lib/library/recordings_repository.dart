import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../asr/capture_source.dart';
import '../asr/transcript_segment.dart';

/// A saved recording: a WAV file plus a sidecar `.json` file (same stem)
/// holding its title, transcript, duration and (once diarization has run)
/// speaker-labeled segments.
class Recording {
  Recording({
    required this.wavPath,
    required this.title,
    required this.createdAt,
    required this.duration,
    required this.transcript,
    this.segments = const [],
    this.speakerCount = 0,
    this.source = AudioSource.microphone,
    this.tags = const [],
  });

  final String wavPath;

  String title;
  final DateTime createdAt;
  final Duration duration;
  final String transcript;

  /// Whether this recording came from the microphone or system-audio
  /// loopback; microphone for recordings predating the field.
  final AudioSource source;

  /// User-assigned tags, used for filtering in the library.
  final List<String> tags;

  /// Time-spans and speaker attribution per finalized segment; empty for
  /// recordings made before diarization (or when it failed).
  final List<TranscriptSegment> segments;

  /// Number of distinct speakers found; 0 when diarization hasn't run.
  final int speakerCount;

  String get id => p.basenameWithoutExtension(wavPath);

  String get sidecarPath => p.join(p.dirname(wavPath), '$id.json');

  /// Transcript with "说话人N：" prefixes when more than one speaker was
  /// found; one line per sentence (segments are already sentence-granular)
  /// or the plain transcript for legacy recordings without segments.
  String get displayTranscript {
    if (speakerCount > 1) return joinLabeledTranscript(segments);
    if (segments.isEmpty) return transcript;
    return segments.map((segment) => segment.text).join('\n');
  }

  Map<String, Object?> toJson() => {
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'durationMs': duration.inMilliseconds,
        'transcript': transcript,
        'segments': [for (final segment in segments) segment.toJson()],
        'speakerCount': speakerCount,
        'source': source.id,
        'tags': tags,
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
        segments: parseSegments(json['segments']),
        speakerCount: json['speakerCount'] as int? ?? 0,
        source: AudioSource.fromId(json['source'] as String?),
        tags: (json['tags'] as List<Object?>? ?? const [])
            .whereType<String>()
            .toList(growable: false),
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

  /// Replaces the recording's tags in the sidecar. Callers reload the list
  /// afterwards ([Recording.tags] is immutable).
  Future<void> updateTags(Recording recording, List<String> tags) async {
    final sidecar = File(recording.sidecarPath);
    final data = Map<String, Object?>.from(await _readOrBuild(recording))
      ..['tags'] = tags;
    await sidecar.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
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

  /// Replaces the speaker-labeled segments in the sidecar; used when a
  /// recording is re-analyzed with a different speaker count. [speakerTurns]
  /// (serialized diarization output) is optional.
  Future<void> updateSegments(
    Recording recording,
    List<TranscriptSegment> segments,
    int speakerCount, [
    List<Map<String, Object?>>? speakerTurns,
  ]) async {
    final sidecar = File(recording.sidecarPath);
    final data = Map<String, Object?>.from(await _readOrBuild(recording))
      ..['segments'] = [for (final segment in segments) segment.toJson()]
      ..['speakerCount'] = speakerCount;
    if (speakerTurns != null) {
      data['speakerTurns'] = [for (final turn in speakerTurns) Map<String, Object?>.from(turn)];
    }
    await sidecar.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
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
