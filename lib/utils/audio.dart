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
