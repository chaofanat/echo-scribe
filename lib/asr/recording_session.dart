import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'diarizer.dart';
import 'recognizer.dart';
import 'transcript_segment.dart';

enum SessionStatus { idle, recording }

/// Coordinates microphone capture, streaming recognition and WAV saving for a
/// single recording. Notifies listeners on every state change.
///
/// The [recognizer] is supplied from outside so its loaded model survives
/// across sessions. An optional [diarizer] enables speaker labeling, which
/// runs asynchronously after the recording stops.
class RecordingSession extends ChangeNotifier {
  RecordingSession(this._recognizer, [this._diarizer, this.expectedSpeakers = 0]);

  final StreamingRecognizer _recognizer;
  final SpeakerDiarizer? _diarizer;

  /// Speaker count hint for clustering: 0 = detect automatically, N > 0
  /// forces N speakers (recommended when the count is known — auto mode
  /// tends to merge similar voices into one cluster).
  final int expectedSpeakers;

  SessionStatus status = SessionStatus.idle;
  String partial = '';
  final List<TranscriptSegment> segments = [];
  Duration elapsed = Duration.zero;
  String? savedFile;

  /// True while speaker diarization is running on the finished recording.
  bool diarizing = false;

  /// Number of distinct speakers found (0 until diarization succeeds).
  int speakerCount = 0;

  /// Distinct speakers produced by the last clustering run; can exceed
  /// [speakerCount] when some clusters never win a sentence (e.g. the
  /// forced count was higher than the number of audible voices).
  int speakerClusters = 0;

  /// Set when the last diarization run failed; null otherwise.
  String? diarizeError;

  /// Raw speaker turns of the last successful diarization run.
  List<SpeakerTurn> speakerTurns = const [];

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audioSub;
  Timer? _ticker;
  RandomAccessFile? _wav;
  String? _wavPath;
  DateTime? _startedAt;
  int _pcmBytes = 0;
  bool _disposed = false;
  Duration _recordedDuration = Duration.zero;

  /// Full transcript: finalized segments joined, plus the trailing partial.
  String get transcript =>
      segments.map((segment) => segment.text).join() + partial;

  /// Transcript with "说话人N：" prefixes once diarization found more than
  /// one speaker; the plain transcript otherwise.
  String get labeledTranscript =>
      speakerCount > 1 ? joinLabeledTranscript(segments) : transcript;

  Future<void> start() async {
    if (status == SessionStatus.recording) return;

    final recorder = AudioRecorder();
    if (!await recorder.hasPermission()) {
      recorder.dispose();
      throw Exception('未获得麦克风权限');
    }

    final dir = await getApplicationDocumentsDirectory();
    final recordingsDir = p.join(dir.path, 'EchoScribe', 'recordings');
    await Directory(recordingsDir).create(recursive: true);
    final now = DateTime.now();
    final stamp =
        '${now.year}${_two(now.month)}${_two(now.day)}-${_two(now.hour)}'
        '${_two(now.minute)}${_two(now.second)}';
    _wavPath = p.join(recordingsDir, 'rec-$stamp.wav');
    _startedAt = now;

    final file = File(_wavPath!);
    _wav = await file.open(mode: FileMode.write);
    await _wav!.writeFrom(_wavHeader(dataBytes: 0));
    _pcmBytes = 0;

    segments.clear();
    partial = '';
    elapsed = Duration.zero;
    savedFile = null;
    diarizing = false;
    speakerCount = 0;
    speakerClusters = 0;
    diarizeError = null;
    speakerTurns = const [];
    _recorder = recorder;
    status = SessionStatus.recording;
    notifyListeners();

    const config = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
    );
    final stream = await recorder.startStream(config);
    _audioSub = stream.listen(_onAudio, onError: (Object e) => debugPrint('record stream error: $e'));
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      elapsed += const Duration(seconds: 1);
      notifyListeners();
    });
  }

  Future<void> stop() async {
    if (status != SessionStatus.recording) return;
    status = SessionStatus.idle;

    await _audioSub?.cancel();
    _audioSub = null;
    _ticker?.cancel();
    _ticker = null;
    await _recorder?.stop();
    _recorder?.dispose();
    _recorder = null;

    // Flush the recognizer so the last (not yet finalized) segment lands in
    // the transcript too.
    final tail = _recognizer.finish();
    if (tail != null) {
      _addFinal(tail.text, tail.startSec, tail.endSec);
    } else if (partial.isNotEmpty) {
      final start = segments.isEmpty ? 0.0 : segments.last.endSec;
      _addFinal(partial, start, _pcmBytes / 32000);
    }
    partial = '';
    _recordedDuration = DateTime.now().difference(_startedAt!);

    // Patch the RIFF sizes now that the final length is known.
    final wav = _wav;
    if (wav != null) {
      await wav.setPosition(4);
      await wav.writeFrom(_u32(36 + _pcmBytes));
      await wav.setPosition(40);
      await wav.writeFrom(_u32(_pcmBytes));
      await wav.close();
      _wav = null;
      savedFile = _wavPath;
      await _writeSidecar();
    }

    _recognizer.resetStream();
    _notify();
    await _runDiarization();
  }

  /// Runs speaker diarization on the finished WAV and rewrites the sidecar
  /// with the labeled segments. Failures are non-fatal: the recording and
  /// its transcript are already saved at this point.
  Future<void> _runDiarization() async {
    final diarizer = _diarizer;
    final wavPath = _wavPath;
    if (diarizer == null || wavPath == null || segments.isEmpty) return;

    diarizing = true;
    diarizeError = null;
    _notify();
    try {
      final turns = await diarizer.analyze(
        wavPath,
        numClusters: expectedSpeakers,
      );
      if (turns.isNotEmpty) {
        speakerTurns = turns;
        speakerClusters = turns.map((turn) => turn.speaker).toSet().length;
        speakerCount = attributeSpeakers(segments, turns);
        await _writeSidecar();
      }
    } catch (e) {
      diarizeError = '说话人分析失败：$e';
      debugPrint('speaker diarization failed: $e');
    } finally {
      diarizing = false;
      _notify();
    }
  }

  Future<void> _writeSidecar() async {
    final wavPath = _wavPath!;
    final stem = p.basenameWithoutExtension(wavPath);
    final sidecar = File(p.join(p.dirname(wavPath), '$stem.json'));
    await sidecar.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'title': stem,
        'createdAt': _startedAt!.toIso8601String(),
        'durationMs': _recordedDuration.inMilliseconds,
        'transcript': segments.map((segment) => segment.text).join(),
        'segments': [for (final segment in segments) segment.toJson()],
        'speakerCount': speakerCount,
        // Raw diarization output, kept for diagnostics/re-analysis.
        'speakerTurns': [for (final turn in speakerTurns) turn.toJson()],
      }),
    );
  }

  Future<void> _onAudio(Uint8List bytes) async {
    final wav = _wav;
    if (wav != null) {
      await wav.writeFrom(bytes);
      _pcmBytes += bytes.length;
    }
    for (final event in _recognizer.feedPcm(bytes)) {
      switch (event) {
        case AsrPartial(:final text):
          partial = text;
        case AsrFinal(:final text, :final startSec, :final endSec):
          _addFinal(text, startSec, endSec);
          partial = '';
      }
    }
    _notify();
  }

  /// Records a finalized utterance, split at sentence punctuation so speaker
  /// attribution works at sentence granularity.
  void _addFinal(String text, double startSec, double endSec) {
    segments.addAll(splitAtSentenceEnds(
      TranscriptSegment(text: text, startSec: startSec, endSec: endSec),
    ));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static Uint8List _u32(int value) {
    final b = ByteData(4)..setUint32(0, value, Endian.little);
    return b.buffer.asUint8List();
  }

  /// 44-byte canonical WAV header for 16 kHz mono PCM16, with placeholder
  /// sizes that get patched in [stop].
  static Uint8List _wavHeader({required int dataBytes}) {
    final header = ByteData(44);
    const ascii = 'RIFF';
    for (var i = 0; i < 4; i++) {
      header.setUint8(i, ascii.codeUnitAt(i));
    }
    header.setUint32(4, 36 + dataBytes, Endian.little);
    header.setUint8(8, 0x57); // W
    header.setUint8(9, 0x41); // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E
    header.setUint8(12, 0x66); // 'fmt '
    header.setUint8(13, 0x6d);
    header.setUint8(14, 0x74);
    header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little); // fmt chunk size
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, 1, Endian.little); // mono
    header.setUint32(24, 16000, Endian.little); // sample rate
    header.setUint32(28, 32000, Endian.little); // byte rate
    header.setUint16(32, 2, Endian.little); // block align
    header.setUint16(34, 16, Endian.little); // bits per sample
    header.setUint8(36, 0x64); // 'data'
    header.setUint8(37, 0x61);
    header.setUint8(38, 0x74);
    header.setUint8(39, 0x61);
    header.setUint32(40, dataBytes, Endian.little);
    return header.buffer.asUint8List();
  }
}
