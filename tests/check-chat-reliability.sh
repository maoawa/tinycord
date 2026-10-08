#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
check_dir=$(mktemp -d)
trap 'rm -rf -- "$check_dir"' EXIT
xcrun swiftc -parse-as-library \
    "TinyCord Watch App/Models/DiscordUser.swift" \
    "TinyCord Watch App/Models/DiscordChannel.swift" \
    "TinyCord Watch App/Models/DiscordAttachment.swift" \
    "TinyCord Watch App/Models/DiscordEmbed.swift" \
    "TinyCord Watch App/Models/DiscordStickerItem.swift" \
    "TinyCord Watch App/Models/EndpointProfile.swift" \
    "TinyCord Watch App/Models/DiscordMessage.swift" \
    "TinyCord Watch App/Models/DiscordRelationship.swift" \
    "TinyCord Watch App/Models/GatewayPayload.swift" \
    "TinyCord Watch App/Services/AccountStorage.swift" \
    "TinyCord Watch App/Services/AuthStore.swift" \
    "TinyCord Watch App/Services/DiscordReadState.swift" \
    "TinyCord Watch App/Services/DiscordAPIClient.swift" \
    "TinyCord Watch App/Services/PersistentCacheStore.swift" \
    "TinyCord Watch App/Services/AvatarCache.swift" \
    "TinyCord Watch App/Services/ChatHistoryCache.swift" \
    "TinyCord Watch App/ViewModels/ChatViewModel.swift" \
    tests/ChatReliabilityChecks.swift -o "$check_dir/check"
"$check_dir/check"
