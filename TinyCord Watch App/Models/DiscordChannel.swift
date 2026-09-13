//
//  DiscordChannel.swift
//  TinyCord Watch App
//

import Foundation

public struct DiscordChannel: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let type: Int
    public let name: String?
    public let recipients: [DiscordUser]?
    public let icon: String?
    public var lastMessageId: String?
    public let lastPinTimestamp: String?

    // Display cache; explicit read/unread changes are confirmed by Discord first.
    public var lastMessageSnippet: String?
    public var lastMessageTime: Date?
    public var hasUnread: Bool = false
    public var lastMessageAuthorId: String?
    public var lastMessageAuthorName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case name
        case recipients
        case icon
        case lastMessageId = "last_message_id"
        case lastPinTimestamp = "last_pin_timestamp"
    }

    public var isGroup: Bool {
        type == 3
    }

    public var isDM: Bool {
        type == 1
    }

    public func recipientUser(currentUserId: String?) -> DiscordUser? {
        if let currentUserId {
            return recipients?.first(where: { $0.id != currentUserId }) ?? recipients?.first
        }
        return recipients?.first
    }

    public func displayName(currentUserId: String?) -> String {
        if isGroup {
            if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
            if let recs = recipients {
                let otherRecs = currentUserId != nil ? recs.filter { $0.id != currentUserId } : recs
                if !otherRecs.isEmpty {
                    return otherRecs.map(\.displayName).joined(separator: ", ")
                }
            }
            return "Group Chat"
        } else {
            return recipientUser(currentUserId: currentUserId)?.displayName ?? "Direct Message"
        }
    }

    public func displaySubtitle(currentUserId: String?) -> String {
        if isGroup {
            let count = recipients?.count ?? 0
            return "\(count) members"
        } else {
            return recipientUser(currentUserId: currentUserId)?.handle ?? ""
        }
    }

    public func displaySnippet(currentUserId: String?) -> String? {
        guard var snippet = lastMessageSnippet, !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        snippet = DiscordMessage.replaceMentions(in: snippet, mentions: recipients)
        if isGroup {
            let isOwn = (lastMessageAuthorId != nil && lastMessageAuthorId == currentUserId)
            if !isOwn {
                let name = lastMessageAuthorName ?? (lastMessageAuthorId != nil ? recipients?.first(where: { $0.id == lastMessageAuthorId })?.displayName : nil)
                if let name, !name.isEmpty {
                    if snippet.hasPrefix("\(name): ") {
                        return snippet
                    }
                    return "\(name): \(snippet)"
                }
            }
        }
        return snippet
    }

    public func avatarURL(cdnBase: String) -> URL? {
        let trimmedBase = cdnBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if isGroup {
            if let icon, !icon.isEmpty {
                return URL(string: "\(trimmedBase)/channel-icons/\(id)/\(icon).png?size=128")
            }
            return nil
        } else {
            return recipients?.first?.avatarURL(cdnBase: trimmedBase)
        }
    }
}
