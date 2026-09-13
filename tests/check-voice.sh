#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-voice-native.sh macosx arm64
cmake --build VoiceNative/build/macosx/arm64 --target VoiceTestSupport --parallel 6
voice_check_dir=$(mktemp -d)
trap 'rm -rf "$voice_check_dir"' EXIT
xcrun nm -g VoiceNative/build/macosx/arm64/libVoiceNative.a > "$voice_check_dir/symbols" 2>/dev/null
if rg -i 'xchacha|hchacha|tinycord_xchacha' "$voice_check_dir/symbols"; then
    echo "Removed XChaCha implementation remains in the native archive" >&2
    exit 1
fi
echo "PASS: no XChaCha/HChaCha implementation in the native archive."
xcrun swiftc -parse-as-library -import-objc-header tests/VoiceTestSupport.h \
    "TinyCord Watch App/Services/VoiceWire.swift" \
    "TinyCord Watch App/Services/VoiceDAVE.swift" \
    "TinyCord Watch App/Services/VoiceAudio.swift" tests/VoiceChecks.swift \
    -L VoiceNative/build/macosx/arm64 -lVoiceTestSupport -lVoiceNative -lc++ \
    -o "$voice_check_dir/check"
"$voice_check_dir/check"
