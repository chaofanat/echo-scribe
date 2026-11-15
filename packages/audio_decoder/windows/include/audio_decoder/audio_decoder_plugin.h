#ifndef FLUTTER_PLUGIN_AUDIO_DECODER_PLUGIN_H_
#define FLUTTER_PLUGIN_AUDIO_DECODER_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

namespace audio_decoder {

// Registration stub so the plugin hooks into the standard Windows plugin
// machinery; the real entry points are the FFI exports in audio_decoder.dll.
class AudioDecoderPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows *registrar);

  AudioDecoderPlugin();

  virtual ~AudioDecoderPlugin();

  AudioDecoderPlugin(const AudioDecoderPlugin &) = delete;
  AudioDecoderPlugin &operator=(const AudioDecoderPlugin &) = delete;
};

}  // namespace audio_decoder

#endif  // FLUTTER_PLUGIN_AUDIO_DECODER_PLUGIN_H_
