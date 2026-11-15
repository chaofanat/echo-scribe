#ifndef AUDIO_DECODER_H_
#define AUDIO_DECODER_H_

#include <stdint.h>

#if defined(_WIN32)
#define AD_API __declspec(dllexport)
#else
#define AD_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Decodes an audio file (WAV/MP3/FLAC) to mono PCM16 at target_rate frames
// per second. Returns a miniaudio ma_result code (0 = success). On success
// *out_samples points to a malloc'd buffer holding *out_frame_count int16
// frames that the caller must release with ad_free_buffer. On failure
// *out_samples is NULL.
AD_API int32_t ad_decode_file(const char *utf8_path, int32_t target_rate,
                              int16_t **out_samples,
                              int64_t *out_frame_count);

// Releases a buffer returned by ad_decode_file.
AD_API void ad_free_buffer(int16_t *buffer);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AUDIO_DECODER_H_
