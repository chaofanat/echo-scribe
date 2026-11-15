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
class AsrFinal extends AsrEvent {
  AsrFinal(this.text);

  final String text;
}

/// Thin wrapper around the sherpa_onnx streaming recognizer.
///
/// The recognizer (and its loaded model) is meant to be created once and
/// reused across recordings; call [resetStream] after each session.
class StreamingRecognizer {
  StreamingRecognizer._(this._recognizer, this._stream);

  final sherpa_onnx.OnlineRecognizer _recognizer;
  sherpa_onnx.OnlineStream _stream;

  /// Loads the bundled model and prepares a fresh decoding stream.
  static Future<StreamingRecognizer> create() async {
    sherpa_onnx.initBindings();
    final config = sherpa_onnx.OnlineRecognizerConfig(
      model: await loadBundledModelConfig(),
      ruleFsts: '',
    );
    final recognizer = sherpa_onnx.OnlineRecognizer(config);
    return StreamingRecognizer._(recognizer, recognizer.createStream());
  }

  /// Feeds 16 kHz mono PCM16 samples, runs decoding until the recognizer
  /// buffer is drained and yields the resulting events.
  Iterable<AsrEvent> feedPcm(Uint8List pcm) sync* {
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
        yield AsrFinal(text);
      }
    }
  }

  /// Flushes the trailing decoding context after the audio input ends and
  /// returns the complete text of the current segment. [resetStream] must be
  /// called afterwards to reuse the recognizer.
  String finish() {
    _stream.inputFinished();
    while (_recognizer.isReady(_stream)) {
      _recognizer.decode(_stream);
    }
    return _recognizer.getResult(_stream).text;
  }

  /// Drops the decoding state so the next session starts from a clean stream.
  void resetStream() {
    _stream.free();
    _stream = _recognizer.createStream();
  }

  void dispose() {
    _stream.free();
    _recognizer.free();
  }
}
