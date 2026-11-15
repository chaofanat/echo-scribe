import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_decoder/audio_decoder.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import '../asr/model_config.dart';
import '../utils/audio.dart';

/// One finalized utterance from an imported file, located on the file's
/// timeline in seconds.
class ImportedUtterance {
  const ImportedUtterance(this.text, this.startSec, this.endSec);

  final String text;
  final double startSec;
  final double endSec;
}

/// Outcome of a file import: the written WAV plus the recognized utterances.
class ImportResult {
  const ImportResult({required this.wavPath, required this.duration, required this.utterances});

  final String wavPath;
  final Duration duration;
  final List<ImportedUtterance> utterances;
}

/// Transcribes an existing audio file (WAV/MP3/FLAC) into the library's
/// 16 kHz mono WAV format. Decoding and recognition both run off the UI
/// isolate; [onProgress] reports 0..1 as audio is consumed.
class FileImporter {
  FileImporter(this._modelFiles);

  final AsrModelFiles _modelFiles;

  /// Decodes [sourcePath], writes the converted WAV to [targetWavPath] and
  /// streams it through the recognizer.
  Future<ImportResult> importFile(
    String sourcePath,
    String targetWavPath, {
    void Function(double progress)? onProgress,
  }) async {
    final pcm = await decodeToPcm16(sourcePath);
    if (pcm.isEmpty) {
      throw AudioDecodeException(-13, sourcePath);
    }
    final wavPath = await Isolate.run(() {
      final sink = File(targetWavPath).openSync(mode: FileMode.write);
      try {
        sink.writeFromSync(wavHeader());
        sink.writeFromSync(pcm);
        // Patch the RIFF/data sizes now that the length is final.
        sink.setPositionSync(4);
        sink.writeFromSync(_u32(36 + pcm.length));
        sink.setPositionSync(40);
        sink.writeFromSync(_u32(pcm.length));
      } finally {
        sink.closeSync();
      }
      return targetWavPath;
    });

    final utterances = await _recognize(wavPath, onProgress: onProgress);
    return ImportResult(
      wavPath: wavPath,
      duration: Duration(milliseconds: pcm.length ~/ 32),
      utterances: utterances,
    );
  }

  /// Runs the streaming recognizer over the whole WAV in a background
  /// isolate. The model must be (re)created there: sherpa_onnx bindings and
  /// the OnlineRecognizer instance are isolate-bound, and rootBundle is
  /// unavailable, hence the file-path-based config.
  Future<List<ImportedUtterance>> _recognize(
    String wavPath, {
    void Function(double progress)? onProgress,
  }) async {
    final config = sherpa_onnx.OnlineRecognizerConfig(
      model: asrModelConfig(_modelFiles),
      ruleFsts: '',
    );
    final port = ReceivePort();
    final errorPort = ReceivePort();
    await Isolate.spawn(
      _recognizeWorker,
      _RecognizeArgs(config, wavPath, port.sendPort),
      errorsAreFatal: true,
      onError: errorPort.sendPort,
    );
    final completer = Completer<List<ImportedUtterance>>();
    final sub = port.listen((message) {
      if (message is double) {
        onProgress?.call(message);
      } else if (message is String) {
        if (!completer.isCompleted) completer.completeError(message);
      } else if (message is List<ImportedUtterance>) {
        if (!completer.isCompleted) completer.complete(message);
      }
    });
    // The worker reports its own failures over [port]; this only fires if
    // the isolate itself dies (so the future never hangs).
    final errorSub = errorPort.listen((_) {
      if (!completer.isCompleted) completer.completeError('导入转写异常退出');
    });
    final result = await completer.future;
    await sub.cancel();
    await errorSub.cancel();
    port.close();
    errorPort.close();
    return result;
  }
}

class _RecognizeArgs {
  const _RecognizeArgs(this.config, this.wavPath, this.replyTo);

  final sherpa_onnx.OnlineRecognizerConfig config;
  final String wavPath;
  final SendPort replyTo;
}

void _recognizeWorker(_RecognizeArgs args) {
  final port = args.replyTo;
  try {
    sherpa_onnx.initBindings();
    final recognizer = sherpa_onnx.OnlineRecognizer(args.config);
    final stream = recognizer.createStream();

    final bytes = File(args.wavPath).readAsBytesSync();
    // Skip the 44-byte header written by importFile; the PCM payload is
    // 16 kHz mono PCM16.
    final pcm = Uint8List.sublistView(bytes, 44);
    const chunkBytes = 32000; // 1 second of audio

    var utteranceStart = 0.0;
    var fedSec = 0.0;
    var lastReported = -1.0;
    final utterances = <ImportedUtterance>[];

    for (var offset = 0; offset < pcm.length; offset += chunkBytes) {
      final piece = Uint8List.sublistView(
        pcm,
        offset,
        math.min(offset + chunkBytes, pcm.length),
      );
      fedSec += piece.length / 32000;
      stream.acceptWaveform(
        samples: convertBytesToFloat32(piece),
        sampleRate: 16000,
      );
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
      }

      final text = recognizer.getResult(stream).text;
      if (recognizer.isEndpoint(stream)) {
        recognizer.reset(stream);
        if (text.isNotEmpty) {
          utterances.add(ImportedUtterance(text, utteranceStart, fedSec));
        }
        utteranceStart = fedSec;
      }

      final progress = (offset + chunkBytes) / pcm.length;
      if (progress - lastReported >= 0.05 || progress >= 1) {
        lastReported = progress;
        port.send(math.min(progress, 1.0));
      }
    }

    // Flush the trailing decoding context.
    stream.inputFinished();
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    final tail = recognizer.getResult(stream).text;
    if (tail.isNotEmpty) {
      utterances.add(ImportedUtterance(tail, utteranceStart, fedSec));
    }

    stream.free();
    recognizer.free();
    port.send(utterances);
  } catch (e) {
    port.send('导入转写失败：$e');
  }
}

Uint8List _u32(int value) {
  final b = ByteData(4)..setUint32(0, value, Endian.little);
  return b.buffer.asUint8List();
}
