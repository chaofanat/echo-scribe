import 'dart:isolate';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'model_config.dart';
import 'transcript_segment.dart';

/// A time span attributed to one speaker (0-based), in seconds.
class SpeakerTurn {
  const SpeakerTurn({
    required this.startSec,
    required this.endSec,
    required this.speaker,
  });

  final double startSec;
  final double endSec;
  final int speaker;

  Map<String, Object?> toJson() =>
      {'start': startSec, 'end': endSec, 'speaker': speaker};
}

/// Offline speaker diarization over a finished recording.
///
/// The heavy work (model load + segmentation + embedding + clustering) runs
/// in a background isolate; the native diarizer is created per run inside
/// that isolate, so nothing native crosses the isolate boundary.
class SpeakerDiarizer {
  SpeakerDiarizer._(this._config);

  final sherpa_onnx.OfflineSpeakerDiarizationConfig _config;

  /// Extracts the bundled diarization models from assets; call once and
  /// reuse.
  static Future<SpeakerDiarizer> create() async {
    return SpeakerDiarizer._(await loadBundledDiarizationConfig());
  }

  /// Runs diarization on [wavPath] and returns the speaker turns sorted by
  /// start time. [numClusters] > 0 forces that speaker count in clustering
  /// (the upstream-recommended usage when the count is known — auto-counting
  /// tends to merge similar voices). Throws on failure (unreadable WAV,
  /// model error).
  Future<List<SpeakerTurn>> analyze(String wavPath, {int numClusters = -1}) async {
    var config = _config;
    if (numClusters > 0) {
      config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation: config.segmentation,
        embedding: config.embedding,
        clustering: sherpa_onnx.FastClusteringConfig(
          numClusters: numClusters,
          threshold: config.clustering.threshold,
        ),
        minDurationOn: config.minDurationOn,
        minDurationOff: config.minDurationOff,
      );
    }
    return Isolate.run(() => _diarize(wavPath, config));
  }
}

List<SpeakerTurn> _diarize(
    String wavPath, sherpa_onnx.OfflineSpeakerDiarizationConfig config) {
  sherpa_onnx.initBindings();
  final wave = sherpa_onnx.readWave(wavPath);
  if (wave.samples.isEmpty) {
    throw Exception('无法读取录音文件: $wavPath');
  }
  if (wave.sampleRate != 16000) {
    throw Exception('录音采样率 ${wave.sampleRate} 不支持，需要 16000 Hz');
  }

  final diarizer = sherpa_onnx.OfflineSpeakerDiarization(config);
  try {
    return [
      for (final s in diarizer.process(samples: wave.samples))
        SpeakerTurn(startSec: s.start, endSec: s.end, speaker: s.speaker),
    ];
  } finally {
    diarizer.free();
  }
}

/// Attributes each segment to the speaker turn it overlaps the most, then
/// relabels speakers 0..n-1 in order of first appearance. Returns the number
/// of distinct speakers found (segments with no overlapping turn keep a null
/// speaker and don't count).
int attributeSpeakers(List<TranscriptSegment> segments, List<SpeakerTurn> turns) {
  for (final segment in segments) {
    var bestSpeaker = -1;
    var bestOverlap = 0.0;
    for (final turn in turns) {
      final overlap = _overlapSec(segment, turn);
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        bestSpeaker = turn.speaker;
      }
    }
    segment.speaker = bestSpeaker >= 0 ? bestSpeaker : null;
  }

  // Set literals keep insertion order, so speakers are numbered by first
  // appearance.
  final used = <int>{
    for (final s in segments)
      if (s.speaker != null) s.speaker!,
  };
  var next = 0;
  final renumber = <int, int>{for (final speaker in used) speaker: next++};
  for (final segment in segments) {
    final speaker = segment.speaker;
    if (speaker != null) segment.speaker = renumber[speaker];
  }
  return used.length;
}

double _overlapSec(TranscriptSegment segment, SpeakerTurn turn) {
  final start = segment.startSec > turn.startSec ? segment.startSec : turn.startSec;
  final end = segment.endSec < turn.endSec ? segment.endSec : turn.endSec;
  return end > start ? end - start : 0;
}
