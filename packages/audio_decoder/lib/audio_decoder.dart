import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Raised when the native decoder cannot handle a file.
class AudioDecodeException implements Exception {
  AudioDecodeException(this.code, this.path);

  /// miniaudio ma_result code.
  final int code;
  final String path;

  @override
  String toString() {
    if (code == -7) return '文件不存在：$path'; // MA_DOES_NOT_EXIST
    if (code == -13) {
      return '暂不支持该音频格式（支持 WAV/MP3/FLAC）：$path'; // MA_INVALID_FILE
    }
    return '音频解码失败（错误码 $code）：$path';
  }
}

/// Decodes an audio file (WAV/MP3/FLAC) to mono PCM16 at [sampleRate] using
/// the bundled miniaudio library. Runs on a background isolate so large
/// files never block the UI.
Future<Uint8List> decodeToPcm16(String path, {int sampleRate = 16000}) {
  return Isolate.run(() => _decode(path, sampleRate));
}

Uint8List _decode(String path, int sampleRate) {
  final lib = DynamicLibrary.open('audio_decoder.dll');
  final decode = lib.lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32, Pointer<Pointer<Int16>>,
          Pointer<Int64>),
      int Function(Pointer<Utf8>, int, Pointer<Pointer<Int16>>,
          Pointer<Int64>)>('ad_decode_file');
  final freeBuffer = lib.lookupFunction<Void Function(Pointer<Int16>),
      void Function(Pointer<Int16>)>('ad_free_buffer');

  final pathPtr = path.toNativeUtf8();
  final outSamples = malloc<Pointer<Int16>>();
  final outCount = malloc<Int64>();
  try {
    final code = decode(pathPtr, sampleRate, outSamples, outCount);
    if (code != 0) throw AudioDecodeException(code, path);
    final samples = outSamples.value;
    try {
      // Detach from native memory: copy, then hand the buffer back.
      final view = samples.cast<Uint8>().asTypedList(outCount.value * 2);
      return Uint8List.fromList(view);
    } finally {
      freeBuffer(samples);
    }
  } finally {
    malloc.free(pathPtr);
    malloc.free(outSamples);
    malloc.free(outCount);
  }
}
