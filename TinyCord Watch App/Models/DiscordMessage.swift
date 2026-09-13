//
//  DiscordMessage.swift
//  TinyCord Watch App
//

import Foundation
import SwiftUI

public struct DiscordReaction: Codable, Hashable, Sendable {
    public let count: Int
    public let me: Bool
    public let emoji: ReactionEmoji

    public struct ReactionEmoji: Codable, Hashable, Sendable {
        public let id: String?
        public let name: String?
    }
}

public struct MessageReference: Codable, Hashable, Sendable {
    public let messageId: String?
    public let channelId: String?
    public let guildId: String?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case channelId = "channel_id"
        case guildId = "guild_id"
    }
}

public final class ReferencedMessageWrapper: Codable, Hashable, Sendable {
    public let message: DiscordMessage?

    public init(message: DiscordMessage?) {
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.message = try? container.decode(DiscordMessage.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(message)
    }

    public static func == (lhs: ReferencedMessageWrapper, rhs: ReferencedMessageWrapper) -> Bool {
        lhs.message?.id == rhs.message?.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(message?.id)
    }
}

public enum SendStatus: String, Codable, Hashable, Sendable {
    case sending
    case sent
    case failed
}

public struct DiscordMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let channelId: String
    public let author: DiscordUser
    public let content: String
    public let timestamp: String
    public let editedTimestamp: String?
    public let attachments: [DiscordAttachment]?
    public let embeds: [DiscordEmbed]?
    public let messageReference: MessageReference?
    public let referencedMessage: ReferencedMessageWrapper?
    public let reactions: [DiscordReaction]?
    public let pinned: Bool?
    public let stickerItems: [DiscordStickerItem]?
    public let mentions: [DiscordUser]?

    public var isOutgoing: Bool = false
    public var sendStatus: SendStatus = .sent

    public init(
        id: String,
        channelId: String,
        author: DiscordUser,
        content: String,
        timestamp: String,
        editedTimestamp: String? = nil,
        attachments: [DiscordAttachment]? = nil,
        embeds: [DiscordEmbed]? = nil,
        messageReference: MessageReference? = nil,
        referencedMessage: ReferencedMessageWrapper? = nil,
        reactions: [DiscordReaction]? = nil,
        pinned: Bool? = nil,
        stickerItems: [DiscordStickerItem]? = nil,
        mentions: [DiscordUser]? = nil,
        isOutgoing: Bool = false,
        sendStatus: SendStatus = .sent
    ) {
        self.id = id
        self.channelId = channelId
        self.author = author
        self.content = content
        self.timestamp = timestamp
        self.editedTimestamp = editedTimestamp
        self.attachments = attachments
        self.embeds = embeds
        self.messageReference = messageReference
        self.referencedMessage = referencedMessage
        self.reactions = reactions
        self.pinned = pinned
        self.stickerItems = stickerItems
        self.mentions = mentions
        self.isOutgoing = isOutgoing
        self.sendStatus = sendStatus
    }

    enum CodingKeys: String, CodingKey {
        case id
        case channelId = "channel_id"
        case author
        case content
        case timestamp
        case editedTimestamp = "edited_timestamp"
        case attachments
        case embeds
        case messageReference = "message_reference"
        case referencedMessage = "referenced_message"
        case reactions
        case pinned
        case stickerItems = "sticker_items"
        case mentions
    }

    public static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static let isoFormatterStandard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    public var parsedDate: Date {
        if let d = Self.isoFormatterWithFractional.date(from: timestamp) {
            return d
        }
        if let d = Self.isoFormatterStandard.date(from: timestamp) {
            return d
        }
        return Date()
    }

    public var formattedTime: String {
        Self.timeOnlyFormatter.string(from: parsedDate)
    }

    public static func isMediaURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        let pathLower = url.path.lowercased()
        let mediaExtensions = [".gif", ".png", ".jpg", ".jpeg", ".webp", ".bmp"]

        if mediaExtensions.contains(where: { pathLower.hasSuffix($0) }) {
            return true
        }
        if let host = url.host?.lowercased() {
            if host.contains("tenor.com") || host.contains("giphy.com") || host.contains("klipy.com") {
                return true
            }
            if (host.contains("discordapp.com") || host.contains("discordapp.net") || host.contains("discord.com")) &&
               (lower.contains("/attachments/") || lower.contains("/ephemeral-attachments/")) {
                if mediaExtensions.contains(where: { pathLower.hasSuffix($0) }) {
                    return true
                }
            }
        }
        return false
    }

    public var extractedURLs: [URL] {
        guard !content.isEmpty else { return [] }
        let pattern = #"https?://[^\s]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        let nsString = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsString.length))
        return matches.compactMap { match in
            let str = nsString.substring(with: match.range)
            return URL(string: str)
        }
    }

    public var directMediaURLs: [URL] {
        extractedURLs.filter { Self.isMediaURL($0) }
    }

    public var webCardURLs: [URL] {
        let mediaSet = Set(directMediaURLs)
        return extractedURLs.filter { !mediaSet.contains($0) }
    }

    public func resolvedDisplayName(forUserId userId: String, channelRecipients: [DiscordUser]? = nil) -> String {
        if let user = mentions?.first(where: { $0.id == userId }) {
            return user.displayName
        }
        if let user = channelRecipients?.first(where: { $0.id == userId }) {
            return user.displayName
        }
        if author.id == userId {
            return author.displayName
        }
        return "User"
    }

    public static func replaceMentions(in rawText: String, mentions: [DiscordUser]?, author: DiscordUser? = nil) -> String {
        guard !rawText.isEmpty else { return rawText }
        var result = rawText

        let userPattern = #"<@!?([0-9]+)>"#
        if let regex = try? NSRegularExpression(pattern: userPattern) {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                guard match.numberOfRanges > 1 else { continue }
                let idRange = match.range(at: 1)
                let userId = nsString.substring(with: idRange)
                let name = mentions?.first(where: { $0.id == userId })?.displayName
                    ?? (author?.id == userId ? author?.displayName : nil)
                    ?? "User"
                if let fullRange = Range(match.range, in: result) {
                    result.replaceSubrange(fullRange, with: "@\(name)")
                }
            }
        }

        let rolePattern = #"<@&([0-9]+)>"#
        if let regex = try? NSRegularExpression(pattern: rolePattern) {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                if let fullRange = Range(match.range, in: result) {
                    result.replaceSubrange(fullRange, with: "@role")
                }
            }
        }

        let channelPattern = #"<#([0-9]+)>"#
        if let regex = try? NSRegularExpression(pattern: channelPattern) {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                if let fullRange = Range(match.range, in: result) {
                    result.replaceSubrange(fullRange, with: "#channel")
                }
            }
        }

        return result
    }

    public func resolveMentions(in rawText: String, channelRecipients: [DiscordUser]? = nil) -> String {
        var allUsers = mentions ?? []
        if let recs = channelRecipients {
            allUsers.append(contentsOf: recs)
        }
        return Self.replaceMentions(in: rawText, mentions: allUsers, author: author)
    }

    public var cleanedTextContent: String {
        var text = content
        // Remove direct media URLs from text body so standalone GIF/photos don't show raw text links
        for url in directMediaURLs {
            text = text.replacingOccurrences(of: url.absoluteString, with: "")
        }
        // Remove URLs matching media embeds
        if let embeds {
            for embed in embeds where embed.isMediaEmbed {
                if let u = embed.url {
                    text = text.replacingOccurrences(of: u, with: "")
                }
            }
        }
        // Resolve mentions in plain text so snippets and previews show clean names
        text = resolveMentions(in: text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func attributedContent(
        themeColor: Color,
        isOutgoing: Bool = false,
        currentUserId: String? = nil,
        channelRecipients: [DiscordUser]? = nil
    ) -> AttributedString {
        var baseText = content
        for url in directMediaURLs {
            baseText = baseText.replacingOccurrences(of: url.absoluteString, with: "")
        }
        if let embeds {
            for embed in embeds where embed.isMediaEmbed {
                if let u = embed.url {
                    baseText = baseText.replacingOccurrences(of: u, with: "")
                }
            }
        }
        baseText = baseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseText.isEmpty else { return AttributedString("") }

        // Match user mentions, role mentions, channel mentions, @everyone, @here
        let pattern = #"<@!?([0-9]+)>|<@&([0-9]+)>|<#([0-9]+)>|(@everyone|@here)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            var plain = AttributedString(baseText)
            plain.font = .system(size: 13)
            plain.foregroundColor = .white
            return plain
        }

        let nsString = baseText as NSString
        let matches = regex.matches(in: baseText, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else {
            var plain = AttributedString(baseText)
            plain.font = .system(size: 13)
            plain.foregroundColor = .white
            return plain
        }

        var result = AttributedString()
        var lastIndex = 0

        for match in matches {
            if match.range.location > lastIndex {
                let textBefore = nsString.substring(with: NSRange(location: lastIndex, length: match.range.location - lastIndex))
                var plainChunk = AttributedString(textBefore)
                plainChunk.font = .system(size: 13)
                plainChunk.foregroundColor = .white
                result.append(plainChunk)
            }

            let userRange = match.range(at: 1)
            let roleRange = match.range(at: 2)
            let chRange = match.range(at: 3)
            let evRange = match.range(at: 4)

            if userRange.location != NSNotFound {
                let userId = nsString.substring(with: userRange)
                let name = resolvedDisplayName(forUserId: userId, channelRecipients: channelRecipients)
                let isMe = (currentUserId != nil && userId == currentUserId)

                var mentionAttr = AttributedString("@\(name)")
                mentionAttr.font = .system(size: 13, weight: .bold)
                if isMe {
                    mentionAttr.foregroundColor = Color(red: 1.0, green: 0.88, blue: 0.35)
                } else if isOutgoing {
                    mentionAttr.foregroundColor = .white
                } else {
                    mentionAttr.foregroundColor = themeColor
                }
                result.append(mentionAttr)
            } else if roleRange.location != NSNotFound {
                var roleAttr = AttributedString("@role")
                roleAttr.font = .system(size: 13, weight: .bold)
                roleAttr.foregroundColor = isOutgoing ? .white : themeColor
                result.append(roleAttr)
            } else if chRange.location != NSNotFound {
                var chAttr = AttributedString("#channel")
                chAttr.font = .system(size: 13, weight: .bold)
                chAttr.foregroundColor = isOutgoing ? Color.white.opacity(0.85) : .secondary
                result.append(chAttr)
            } else if evRange.location != NSNotFound {
                let evText = nsString.substring(with: evRange)
                var evAttr = AttributedString(evText)
                evAttr.font = .system(size: 13, weight: .bold)
                evAttr.foregroundColor = Color(red: 1.0, green: 0.88, blue: 0.35)
                result.append(evAttr)
            }

            lastIndex = match.range.location + match.range.length
        }

        if lastIndex < nsString.length {
            let remaining = nsString.substring(with: NSRange(location: lastIndex, length: nsString.length - lastIndex))
            var plainChunk = AttributedString(remaining)
            plainChunk.font = .system(size: 13)
            plainChunk.foregroundColor = .white
            result.append(plainChunk)
        }

        return result
    }

    public var displaySnippet: String {
        // If message has stickers
        if let stickers = stickerItems, !stickers.isEmpty {
            return "👾 Sticker"
        }

        // If message has attachments
        if let atts = attachments, !atts.isEmpty {
            if atts.first?.isImage == true {
                return atts.first?.filename.lowercased().hasSuffix(".gif") == true ? "GIF" : "📷 Photo"
            }
            return "📎 Attachment"
        }

        // If message is or has a media embed
        if let embeds, let first = embeds.first {
            if first.isMediaEmbed {
                return "GIF"
            }
        }

        // If message content is solely a direct media link
        if !directMediaURLs.isEmpty && cleanedTextContent.isEmpty {
            let first = directMediaURLs.first
            let isGif = first?.path.lowercased().hasSuffix(".gif") == true ||
                        first?.host?.contains("tenor") == true ||
                        first?.host?.contains("giphy") == true ||
                        first?.host?.contains("klipy") == true
            return isGif ? "GIF" : "📷 Photo"
        }

        let cleaned = cleanedTextContent
        if !cleaned.isEmpty {
            return cleaned.replacingOccurrences(of: "\n", with: " ")
        }

        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content.replacingOccurrences(of: "\n", with: " ")
        }

        if let embeds = embeds, !embeds.isEmpty {
            return embeds.first?.title ?? "Embed"
        }

        return "Message"
    }
}
