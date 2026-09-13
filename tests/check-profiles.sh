#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
check_dir=$(mktemp -d)
trap 'rm -rf -- "$check_dir"' EXIT
for source in "TinyCord/EndpointProfile.swift" "TinyCord Watch App/Models/EndpointProfile.swift"; do
    xcrun swiftc -parse-as-library "$source" tests/EndpointProfileChecks.swift -o "$check_dir/profile-check"
    "$check_dir/profile-check"
done
xcrun swiftc -parse-as-library "TinyCord Watch App/Models/EndpointProfile.swift" \
    "TinyCord Watch App/Models/DiscordStickerItem.swift" tests/StickerChecks.swift -o "$check_dir/sticker-check"
"$check_dir/sticker-check"
