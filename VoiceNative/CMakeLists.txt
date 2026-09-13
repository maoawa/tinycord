cmake_minimum_required(VERSION 3.20)
project(TinyCordVoiceNative LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(CMAKE_MACOSX_BUNDLE OFF)
# Portable C avoids unsupported assembly on arm64_32 watch devices.
set(OPENSSL_NO_ASM ON CACHE BOOL "" FORCE)
add_subdirectory("${VOICE_SOURCES}/boringssl" boringssl EXCLUDE_FROM_ALL)
# The regular ChaCha20-Poly1305 implementation remains available to standard MLS
# suites. Omit the extended-nonce XChaCha functions even from the static archive.
find_package(Python3 COMPONENTS Interpreter REQUIRED)
execute_process(COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/prepare-voice-crypto.py"
    "${VOICE_SOURCES}/boringssl" "${CMAKE_CURRENT_BINARY_DIR}/standard-crypto"
    COMMAND_ERROR_IS_FATAL ANY)
get_target_property(VOICE_CRYPTO_SOURCES crypto SOURCES)
list(FILTER VOICE_CRYPTO_SOURCES EXCLUDE REGEX "crypto/(cipher_extra/e_chacha20poly1305|chacha/chacha)\\.c$")
list(APPEND VOICE_CRYPTO_SOURCES
    "${CMAKE_CURRENT_BINARY_DIR}/standard-crypto/e_chacha20poly1305.c"
    "${CMAKE_CURRENT_BINARY_DIR}/standard-crypto/chacha.c")
set_property(TARGET crypto PROPERTY SOURCES ${VOICE_CRYPTO_SOURCES})

set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
add_subdirectory("${VOICE_SOURCES}/opus" opus EXCLUDE_FROM_ALL)

file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/include/namespace.h" "#pragma once\n#define MLS_NAMESPACE mlspp\n")
file(GLOB MLS_SOURCES "${VOICE_SOURCES}/mlspp/src/*.cpp"
    "${VOICE_SOURCES}/mlspp/lib/bytes/src/*.cpp"
    "${VOICE_SOURCES}/mlspp/lib/tls_syntax/src/*.cpp"
    "${VOICE_SOURCES}/mlspp/lib/hpke/src/*.cpp")
file(GLOB_RECURSE DAVE_SOURCES "${VOICE_SOURCES}/libdave/cpp/src/*.cpp")
list(FILTER DAVE_SOURCES EXCLUDE REGEX ".*(persisted_key|_win\\.cpp|_wasm\\.cpp|_apple\\.cpp|openssl_cryptor).*")
list(APPEND DAVE_SOURCES "${VOICE_SOURCES}/libdave/cpp/src/mls/persisted_key_pair_null.cpp")
add_library(VoiceProtocol STATIC ${MLS_SOURCES} ${DAVE_SOURCES})
target_compile_definitions(VoiceProtocol PRIVATE WITH_BORINGSSL DISABLE_GREASE)
target_include_directories(VoiceProtocol PRIVATE
    "${CMAKE_CURRENT_BINARY_DIR}/include"
    "${VOICE_SOURCES}/boringssl/include"
    "${VOICE_SOURCES}/json/single_include"
    "${VOICE_SOURCES}/mlspp/include"
    "${VOICE_SOURCES}/mlspp/third_party"
    "${VOICE_SOURCES}/mlspp/lib/bytes/include"
    "${VOICE_SOURCES}/mlspp/lib/tls_syntax/include"
    "${VOICE_SOURCES}/mlspp/lib/hpke/include"
    "${VOICE_SOURCES}/libdave/cpp/includes"
    "${VOICE_SOURCES}/libdave/cpp/src")
target_link_libraries(VoiceProtocol PRIVATE crypto opus)
add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/libVoiceNative.a"
    COMMAND /usr/bin/libtool -static -o "${CMAKE_CURRENT_BINARY_DIR}/libVoiceNative.a"
        $<TARGET_FILE:VoiceProtocol> $<TARGET_FILE:crypto> $<TARGET_FILE:opus>
    DEPENDS VoiceProtocol crypto opus)
add_custom_target(VoiceNative ALL DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/libVoiceNative.a")

# Synthetic external sender for native MLS integration tests; never linked into
# the shipping Watch archive.
if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    add_library(VoiceTestSupport STATIC EXCLUDE_FROM_ALL
        "../tests/VoiceTestSupport.cpp" "${VOICE_SOURCES}/libdave/cpp/test/external_sender.cpp")
    get_target_property(VOICE_INCLUDES VoiceProtocol INCLUDE_DIRECTORIES)
    target_include_directories(VoiceTestSupport PRIVATE ${VOICE_INCLUDES} "${VOICE_SOURCES}/libdave/cpp/test")
    target_compile_definitions(VoiceTestSupport PRIVATE WITH_BORINGSSL)
endif()
