#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
check_dir=$(mktemp -d)
trap 'rm -rf -- "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
    "TinyCord Watch App/Services/ChatMediaLoadingPolicy.swift" \
    "TinyCord Watch App/Services/ChatMediaLoader.swift" \
    tests/ChatMediaLoadingChecks.swift -o "$check_dir/chat-media-check"
"$check_dir/chat-media-check"
