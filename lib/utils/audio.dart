import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Copies a bundled asset file into the app support directory and returns the
/// resulting path. The copy is skipped when the file is already there with the
/// same size. Mirrors the official sherpa-onnx flutter example.
Future<String> copyAssetFile(String src) async {
  final dir = await getApplicationSupportDirectory();
  final target = p.join(dir.path, p.basename(src));
  final data = await rootBundle.load(src);
  final file = File(target);
  if (!file.existsSync() || file.lengthSync() != data.lengthInBytes) {
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
  }
  return target;
}

/// Converts interleaved little-endian 16-bit PCM samples to normalized floats.
Float32List convertBytesToFloat32(Uint8List bytes) {
  final values = Float32List(bytes.length ~/ 2);
  final data = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
  for (var i = 0; i < bytes.length; i += 2) {
    values[i ~/ 2] = data.getInt16(i, Endian.little) / 32768.0;
  }
  return values;
}

/// 44-byte canonical WAV header for 16 kHz mono PCM16. Shared by live
/// recordings and imported files so every WAV in the library has the same
/// shape downstream code (diarization readWave, playback) can rely on.
Uint8List wavHeader() {
  final header = ByteData(44);
  const ascii = 'RIFF';
  for (var i = 0; i < 4; i++) {
    header.setUint8(i, ascii.codeUnitAt(i));
  }
  header.setUint32(4, 36, Endian.little); // patched by the writer
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
  header.setUint32(40, 0, Endian.little); // patched by the writer
  return header.buffer.asUint8List();
}
