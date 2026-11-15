import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'recognizer.dart';

enum SessionStatus { idle, recording }

/// Coordinates microphone capture, streaming recognition and WAV saving for a
/// single recording. Notifies listeners on every state change.
///
/// The [recognizer] is supplied from outside so its loaded model survives
/// across sessions.
class RecordingSession extends ChangeNotifier {
  RecordingSession(this._recognizer);

  final StreamingRecognizer _recognizer;

  SessionStatus status = SessionStatus.idle;
  String partial = '';
  final List<String> segments = [];
  Duration elapsed = Duration.zero;
  String? savedFile;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audioSub;
  Timer? _ticker;
  RandomAccessFile? _wav;
  String? _wavPath;
  int _pcmBytes = 0;

  /// Full transcript: finalized segments joined, plus the trailing partial.
  String get transcript => segments.join() + partial;

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

    final file = File(_wavPath!);
    _wav = await file.open(mode: FileMode.write);
    await _wav!.writeFrom(_wavHeader(dataBytes: 0));
    _pcmBytes = 0;

    segments.clear();
    partial = '';
    elapsed = Duration.zero;
    savedFile = null;
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
    if (tail.isNotEmpty) {
      segments.add(tail);
    } else if (partial.isNotEmpty) {
      segments.add(partial);
    }
    partial = '';

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
    }

    _recognizer.resetStream();
    notifyListeners();
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
        case AsrFinal(:final text):
          segments.add(text);
          partial = '';
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
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
