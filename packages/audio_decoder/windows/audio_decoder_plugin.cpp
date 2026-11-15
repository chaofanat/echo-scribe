#include "include/audio_decoder/audio_decoder_plugin.h"

namespace audio_decoder {

// static
void AudioDecoderPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  // FFI-only plugin: nothing to wire up, but registration keeps the plugin
  // on the standard Windows plugin path.
  registrar->AddPlugin(std::make_unique<AudioDecoderPlugin>());
}

AudioDecoderPlugin::AudioDecoderPlugin() {}

AudioDecoderPlugin::~AudioDecoderPlugin() {}

}  // namespace audio_decoder
