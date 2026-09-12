//
//  DiscordEmbed.swift
//  TinyCord Watch App
//

import Foundation

public struct DiscordEmbed: Codable, Hashable, Sendable {
    public let title: String?
    public let type: String?
    public let description: String?
    public let url: String?
    public let timestamp: String?
    public let color: Int?
    public let footer: EmbedFooter?
    public let image: EmbedMedia?
    public let thumbnail: EmbedMedia?
    public let video: EmbedMedia?
    public let author: EmbedAuthor?
    public let fields: [EmbedField]?

    public var isMediaEmbed: Bool {
        if type == "gifv" || type == "image" {
            return true
        }
        // If it has image/thumbnail but no meaningful text description or title, treat as media
        if image != nil || thumbnail != nil {
            let hasTitle = title != nil && !title!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasDesc = description != nil && !description!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasDesc && (!hasTitle || title?.lowercased().contains("gif") == true) {
                return true
            }
        }
        return false
    }

    public func mediaURL(cdnBase: String) -> URL? {
        if let thumb = thumbnail?.resolvedURL(cdnBase: cdnBase) {
            return thumb
        }
        if let img = image?.resolvedURL(cdnBase: cdnBase) {
            return img
        }
        if let vid = video?.resolvedURL(cdnBase: cdnBase) {
            return vid
        }
        return nil
    }

    public var isWebLinkEmbed: Bool {
        guard !isMediaEmbed else { return false }
        return (url != nil && !url!.isEmpty) || (title != nil && !title!.isEmpty)
    }

    public struct EmbedFooter: Codable, Hashable, Sendable {
        public let text: String
        public let iconUrl: String?
        public let proxyIconUrl: String?

        enum CodingKeys: String, CodingKey {
            case text
            case iconUrl = "icon_url"
            case proxyIconUrl = "proxy_icon_url"
        }
    }

    public struct EmbedMedia: Codable, Hashable, Sendable {
        public let url: String?
        public let proxyUrl: String?
        public let height: Int?
        public let width: Int?

        enum CodingKeys: String, CodingKey {
            case url
            case proxyUrl = "proxy_url"
            case height
            case width
        }

        public func resolvedURL(cdnBase: String) -> URL? {
            guard let url else { return nil }
            let trimmedBase = cdnBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmedBase.contains("discordapp.com") && !trimmedBase.contains("discord.com") {
                if let parsed = URL(string: url), let host = parsed.host, host.contains("discord") {
                    let pathAndQuery = parsed.path + (parsed.query.map { "?\($0)" } ?? "")
                    return URL(string: "\(trimmedBase)\(pathAndQuery)")
                }
            }
            return URL(string: url)
        }
    }

    public struct EmbedAuthor: Codable, Hashable, Sendable {
        public let name: String
        public let url: String?
        public let iconUrl: String?
        public let proxyIconUrl: String?

        enum CodingKeys: String, CodingKey {
            case name
            case url
            case iconUrl = "icon_url"
            case proxyIconUrl = "proxy_icon_url"
        }
    }

    public struct EmbedField: Codable, Hashable, Sendable {
        public let name: String
        public let value: String
        public let inline: Bool?
    }
}
