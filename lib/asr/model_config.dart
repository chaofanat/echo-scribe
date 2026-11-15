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

/// Bundled speaker-diarization models (offline, run after recording stops):
/// pyannote segmentation (~6 MB) + 3D-Speaker CAM++ zh-en embedding (~28 MB,
/// stronger separation on short utterances than the ERES2Net-base zh model).
/// Same download script as the ASR model.
const pyannoteSegmentationAssetDir =
    'assets/models/sherpa-onnx-pyannote-segmentation-3-0';
const speakerEmbeddingAssetPath =
    'assets/models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx';

/// Filesystem locations of the extracted bundled ASR model. Useful for
/// background isolates (file import), which cannot touch rootBundle but can
/// build a recognizer config from these paths.
class AsrModelFiles {
  const AsrModelFiles({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
  });

  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
}

/// Extracts the bundled ASR model files out of assets (idempotent) and
/// returns where they live on disk.
Future<AsrModelFiles> extractBundledAsrModel() async {
  return AsrModelFiles(
    encoder: await copyAssetFile('$bundledModelAssetDir/encoder.int8.onnx'),
    decoder: await copyAssetFile('$bundledModelAssetDir/decoder.onnx'),
    joiner: await copyAssetFile('$bundledModelAssetDir/joiner.int8.onnx'),
    tokens: await copyAssetFile('$bundledModelAssetDir/tokens.txt'),
  );
}

/// Loads the bundled model files out of assets and returns the recognizer
/// model config pointing at the extracted copies.
Future<sherpa_onnx.OnlineModelConfig> loadBundledModelConfig() async {
  return asrModelConfig(await extractBundledAsrModel());
}

/// Builds a recognizer model config from already-extracted model files.
sherpa_onnx.OnlineModelConfig asrModelConfig(AsrModelFiles files) {
  return sherpa_onnx.OnlineModelConfig(
    transducer: sherpa_onnx.OnlineTransducerModelConfig(
      encoder: files.encoder,
      decoder: files.decoder,
      joiner: files.joiner,
    ),
    tokens: files.tokens,
    modelType: 'zipformer2',
    debug: false,
  );
}

/// Loads the bundled diarization model files out of assets and returns the
/// diarizer config pointing at the extracted copies.
Future<sherpa_onnx.OfflineSpeakerDiarizationConfig>
    loadBundledDiarizationConfig() async {
  return sherpa_onnx.OfflineSpeakerDiarizationConfig(
    segmentation: sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
      pyannote: sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
        model: await copyAssetFile('$pyannoteSegmentationAssetDir/model.onnx'),
      ),
      numThreads: 2,
      debug: false,
    ),
    embedding: sherpa_onnx.SpeakerEmbeddingExtractorConfig(
      model: await copyAssetFile(speakerEmbeddingAssetPath),
      numThreads: 2,
      debug: false,
    ),
  );
}
