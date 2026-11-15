#define MINIAUDIO_IMPLEMENTATION
// miniaudio.h pulls in <windows.h>, whose min/max macros would break
// std::min/std::max below; must be defined before the first include.
#if defined(_WIN32) && !defined(NOMINMAX)
#define NOMINMAX
#endif
#include "miniaudio.h"

#include "audio_decoder.h"

#include <cstdlib>
#include <string>

#ifdef _WIN32
#include <windows.h>

// The C API speaks UTF-8; Windows file APIs want UTF-16.
static std::wstring utf8_to_wide(const char *utf8) {
  const int len =
      MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
  if (len <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(len), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide.data(), len);
  return std::wstring(wide.data(), wide.size() - 1);  // strip the NUL
}
#endif

int32_t ad_decode_file(const char *utf8_path, int32_t target_rate,
                       int16_t **out_samples, int64_t *out_frame_count) {
  if (utf8_path == nullptr || out_samples == nullptr ||
      out_frame_count == nullptr || target_rate <= 0) {
    return MA_INVALID_ARGS;
  }
  *out_samples = nullptr;
  *out_frame_count = 0;

  // miniaudio converts format/channels/rate while decoding.
  const ma_decoder_config config =
      ma_decoder_config_init(ma_format_s16, 1, (ma_uint32)target_rate);

  ma_decoder decoder;
#ifdef _WIN32
  const std::wstring wide = utf8_to_wide(utf8_path);
  ma_result result = ma_decoder_init_file_w(wide.c_str(), &config, &decoder);
#else
  ma_result result = ma_decoder_init_file(utf8_path, &config, &decoder);
#endif
  if (result != MA_SUCCESS) return result;

  // Stream in 1-second chunks: the total length is unknown (or an estimate)
  // for some formats, so the buffer grows as needed.
  const ma_uint64 chunkFrames = (ma_uint64)target_rate;
  size_t capacity = (size_t)chunkFrames;
  size_t frames = 0;
  int16_t *buffer = (int16_t *)malloc(capacity * sizeof(int16_t));
  if (buffer == nullptr) {
    ma_decoder_uninit(&decoder);
    return MA_OUT_OF_MEMORY;
  }

  for (;;) {
    if (frames == capacity) {
      capacity *= 2;
      int16_t *grown = (int16_t *)realloc(buffer, capacity * sizeof(int16_t));
      if (grown == nullptr) {
        free(buffer);
        ma_decoder_uninit(&decoder);
        return MA_OUT_OF_MEMORY;
      }
      buffer = grown;
    }
    ma_uint64 read = 0;
    result = ma_decoder_read_pcm_frames(&decoder, buffer + frames,
                                        chunkFrames, &read);
    frames += (size_t)read;
    // MA_AT_END still delivers the final frames in this call; anything else
    // is a real decode error.
    if (result == MA_AT_END) break;
    if (result != MA_SUCCESS) {
      free(buffer);
      ma_decoder_uninit(&decoder);
      return result;
    }
    if (read == 0) break;  // defensive; end of stream
  }
  ma_decoder_uninit(&decoder);

  if (frames == 0) {
    free(buffer);
    return MA_INVALID_FILE;
  }

  *out_samples = buffer;
  *out_frame_count = (int64_t)frames;
  return MA_SUCCESS;
}

void ad_free_buffer(int16_t *buffer) { free(buffer); }
