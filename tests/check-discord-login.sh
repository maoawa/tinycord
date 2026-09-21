#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
check_dir=$(mktemp -d)
trap 'rm -rf -- "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/modules" TinyCord/DiscordLoginPolicy.swift tests/DiscordLoginPolicyChecks.swift -o "$check_dir/check"
"$check_dir/check" "$check_dir/login.js"
node tests/DiscordLoginFormChecks.cjs "$check_dir/login.js"
