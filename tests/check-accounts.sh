#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
check_dir=$(mktemp -d)
trap 'rm -rf -- "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/modules" \
    "TinyCord Watch App/Models/DiscordUser.swift" \
    "TinyCord Watch App/Services/AccountStorage.swift" \
    "TinyCord Watch App/Services/AuthStore.swift" \
    "TinyCord Watch App/Services/DiscordReadState.swift" \
    "TinyCord Watch App/Services/DiscordAPIClient.swift" \
    tests/AccountChecks.swift -o "$check_dir/check"
"$check_dir/check"
