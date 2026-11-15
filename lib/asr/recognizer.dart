import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import '../utils/audio.dart';
import 'model_config.dart';

/// Events produced while audio is fed into the recognizer.
sealed class AsrEvent {}

/// Live partial text for the segment currently being decoded.
class AsrPartial extends AsrEvent {
  AsrPartial(this.text);

  final String text;
}

/// The current segment was finalized (endpoint / sentence end detected).
/// [startSec]/[endSec] locate the segment in the recording, from the amount
/// of audio fed since the session started.
class AsrFinal extends AsrEvent {
  AsrFinal(this.text, this.startSec, this.endSec);

  final String text;
  final double startSec;
  final double endSec;
}

/// Thin wrapper around the sherpa_onnx streaming recognizer.
///
/// The recognizer (and its loaded model) is meant to be created once and
/// reused across recordings; call [resetStream] after each session.
class StreamingRecognizer {
  StreamingRecognizer._(this._recognizer, this._stream);

  final sherpa_onnx.OnlineRecognizer _recognizer;
  sherpa_onnx.OnlineStream _stream;

  /// Seconds of audio fed since the session started (16 kHz mono PCM16 =>
  /// 32000 bytes per second). Drives the [AsrFinal] time spans.
  double _fedSec = 0;

  /// Where the current (not yet finalized) utterance started.
  double _utteranceStartSec = 0;

  /// Loads the bundled model and prepares a fresh decoding stream.
  static Future<StreamingRecognizer> create() async {
    sherpa_onnx.initBindings();
    final config = sherpa_onnx.OnlineRecognizerConfig(
      model: await loadBundledModelConfig(),
      ruleFsts: '',
      // Endpoint rules stay at the sherpa defaults (2.4/1.2s trailing
      // silence): frequent resets degrade recognition (lost cross-utterance
      // context), and sentence-level splitting for speaker attribution is
      // handled by splitAtSentenceEnds on the punctuation instead.
    );
    final recognizer = sherpa_onnx.OnlineRecognizer(config);
    return StreamingRecognizer._(recognizer, recognizer.createStream());
  }

  /// Feeds 16 kHz mono PCM16 samples, runs decoding until the recognizer
  /// buffer is drained and yields the resulting events.
  Iterable<AsrEvent> feedPcm(Uint8List pcm) sync* {
    _fedSec += pcm.length / 32000;
    _stream.acceptWaveform(
      samples: convertBytesToFloat32(pcm),
      sampleRate: 16000,
    );
    while (_recognizer.isReady(_stream)) {
      _recognizer.decode(_stream);
    }

    final text = _recognizer.getResult(_stream).text;
    if (text.isNotEmpty) {
      yield AsrPartial(text);
    }

    if (_recognizer.isEndpoint(_stream)) {
      _recognizer.reset(_stream);
      if (text.isNotEmpty) {
        yield AsrFinal(text, _utteranceStartSec, _fedSec);
      }
      _utteranceStartSec = _fedSec;
    }
  }

  /// Flushes the trailing decoding context after the audio input ends and
  /// returns the final event for the current segment, or null when its text
  /// is empty. [resetStream] must be called afterwards to reuse the
  /// recognizer.
  AsrFinal? finish() {
    _stream.inputFinished();
    while (_recognizer.isReady(_stream)) {
      _recognizer.decode(_stream);
    }
    final text = _recognizer.getResult(_stream).text;
    return text.isEmpty ? null : AsrFinal(text, _utteranceStartSec, _fedSec);
  }

  /// Drops the decoding state so the next session starts from a clean stream.
  void resetStream() {
    _stream.free();
    _stream = _recognizer.createStream();
    _fedSec = 0;
    _utteranceStartSec = 0;
  }

  void dispose() {
    _stream.free();
    _recognizer.free();
  }
}
