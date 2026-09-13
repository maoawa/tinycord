#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
bash scripts/build-voice-native.sh macosx arm64
check_dir=$(mktemp -d)
trap 'rm -rf -- "$check_dir"' EXIT
xcrun swiftc -parse-as-library -import-objc-header VoiceNative/include/TinyCordVoiceNative.h \
    "TinyCord Watch App/Models/DiscordUser.swift" \
    "TinyCord Watch App/Models/DiscordAttachment.swift" \
    "TinyCord Watch App/Models/DiscordEmbed.swift" \
    "TinyCord Watch App/Models/DiscordStickerItem.swift" \
    "TinyCord Watch App/Models/EndpointProfile.swift" \
    "TinyCord Watch App/Models/DiscordMessage.swift" \
    "TinyCord Watch App/Services/OggOpusRecording.swift" \
    tests/MessageRecordingChecks.swift \
    -L VoiceNative/build/macosx/arm64 -lVoiceNative -lc++ \
    -o "$check_dir/message-recording-check"
"$check_dir/message-recording-check"
