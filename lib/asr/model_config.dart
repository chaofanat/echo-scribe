import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import '../utils/audio.dart';

/// Bundled streaming model: bilingual zh-en zipformer with built-in
/// punctuation, int8 quantized (~128 MB). Fetched from the sherpa-onnx
/// GitHub release with scripts/download_model.ps1.
///
/// To switch models: change this directory plus the file names below (see
/// the upstream flutter-examples/streaming_asr/lib/online_model.dart for
/// the configs of other models).
const bundledModelAssetDir =
    'assets/models/sherpa-onnx-x-asr-960ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05';

/// Loads the bundled model files out of assets and returns the recognizer
/// model config pointing at the extracted copies.
Future<sherpa_onnx.OnlineModelConfig> loadBundledModelConfig() async {
  return sherpa_onnx.OnlineModelConfig(
    transducer: sherpa_onnx.OnlineTransducerModelConfig(
      encoder: await copyAssetFile('$bundledModelAssetDir/encoder.int8.onnx'),
      decoder: await copyAssetFile('$bundledModelAssetDir/decoder.onnx'),
      joiner: await copyAssetFile('$bundledModelAssetDir/joiner.int8.onnx'),
    ),
    tokens: await copyAssetFile('$bundledModelAssetDir/tokens.txt'),
    modelType: 'zipformer2',
    debug: false,
  );
}
