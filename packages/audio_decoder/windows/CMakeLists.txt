cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "audio_decoder")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "audio_decoder_plugin")

add_library(${PLUGIN_NAME} SHARED
  "${PLUGIN_NAME}.cpp"
)

# The shared library for miniaudio; its C entry points (ad_decode_file,
# ad_free_buffer) are resolved via dart:ffi. Sources live in ../src, shared
# with the Android build.
add_library(audio_decoder SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/audio_decoder.cpp"
)
target_include_directories(audio_decoder PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../src"
)

# Apply standard settings
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

set_target_properties(audio_decoder PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  CXX_EXTENSIONS OFF
  # ad_decode_file/ad_free_buffer carry __declspec(dllexport) in the header,
  # which is what the Dart FFI lookups resolve against.
)

# List of absolute paths to libraries that should be bundled with the plugin
set(audio_decoder_bundled_libraries
  "$<TARGET_FILE:audio_decoder>"
  PARENT_SCOPE
)
