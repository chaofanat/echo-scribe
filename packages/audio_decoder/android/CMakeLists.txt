cmake_minimum_required(VERSION 3.18)
project(audio_decoder)

# Same decoder as the Windows build; sources live in ../src.
add_library(audio_decoder SHARED
    ../src/audio_decoder.cpp
)
target_include_directories(audio_decoder PRIVATE
    ../src
)

find_library(log-lib log)

target_link_libraries(audio_decoder
    ${log-lib}
)

set_target_properties(audio_decoder PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
)
