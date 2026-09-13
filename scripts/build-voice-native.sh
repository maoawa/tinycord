#!/bin/bash
set -euo pipefail
voice_root="$(cd "$(dirname "$0")/.." && pwd)"
voice_sdk="${1:-watchos}"
voice_arch="${2:-arm64_32}"
case "$voice_sdk:$voice_arch" in
  watchos:arm64_32|watchos:arm64|watchsimulator:arm64|watchsimulator:x86_64|macosx:arm64) ;;
  *) echo "Unsupported voice build: $voice_sdk/$voice_arch" >&2; exit 1 ;;
esac
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v cmake >/dev/null || { echo "Install CMake to build the voice dependencies." >&2; exit 1; }
command -v ninja >/dev/null || { echo "Install Ninja to build the voice dependencies." >&2; exit 1; }
python3 "$voice_root/scripts/fetch-voice-native.py"
voice_build="$voice_root/VoiceNative/build/$voice_sdk/$voice_arch"
voice_system=watchOS
voice_minimum=10.0
if [ "$voice_sdk" = macosx ]; then voice_system=Darwin; voice_minimum=14.0; fi
cmake -S "$voice_root/VoiceNative" -B "$voice_build" -G Ninja \
  -DCMAKE_SYSTEM_NAME="$voice_system" \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$voice_sdk" --show-sdk-path)" \
  -DCMAKE_OSX_ARCHITECTURES="$voice_arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$voice_minimum" \
  -DCMAKE_BUILD_TYPE=Release -DVOICE_SOURCES="$voice_root/VoiceNative/sources"
cmake --build "$voice_build" --target VoiceNative --parallel 6
