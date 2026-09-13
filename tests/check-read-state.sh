#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
check_dir=$(mktemp -d)
trap 'rm -rf -- "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
    "TinyCord Watch App/Services/DiscordReadState.swift" \
    tests/ReadStateChecks.swift -o "$check_dir/read-state-check"
"$check_dir/read-state-check"
