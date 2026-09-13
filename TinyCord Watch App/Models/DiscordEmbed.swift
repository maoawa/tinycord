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
    public let provider: EmbedProvider?
    public let author: EmbedAuthor?
    public let fields: [EmbedField]?

    public var preferredWidth: Int? {
        image?.width ?? thumbnail?.width ?? video?.width
    }

    public var preferredHeight: Int? {
        image?.height ?? thumbnail?.height ?? video?.height
    }

    public var isMediaEmbed: Bool {
        if type == "gifv" || type == "image" {
            return true
        }
        if let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }) {
            if host.contains("tenor.com") || host.contains("giphy.com") || host.contains("klipy.com") {
                return true
            }
        }
        if let provName = provider?.name?.lowercased() {
            if provName.contains("tenor") || provName.contains("giphy") || provName.contains("klipy") {
                return true
            }
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
        // 1. If embed URL is from Klipy/Tenor/Giphy, return the provider URL so resolver fetches the native animated .gif
        if let urlStr = url, let u = URL(string: urlStr) {
            let host = u.host?.lowercased() ?? ""
            if host.contains("klipy.com") || host.contains("tenor.com") || host.contains("giphy.com") {
                return u
            }
        }
        if let provName = provider?.name?.lowercased(),
           provName.contains("klipy") || provName.contains("tenor") || provName.contains("giphy"),
           let urlStr = url, let u = URL(string: urlStr) {
            return u
        }

        // 2. Prefer direct GIF/PNG/JPEG images (natively supported on watchOS)
        if let img = image?.resolvedURL(cdnBase: cdnBase) {
            let p = img.path.lowercased()
            if p.hasSuffix(".gif") || p.hasSuffix(".png") || p.hasSuffix(".jpg") || p.hasSuffix(".jpeg") {
                return img
            }
        }
        if let thumb = thumbnail?.resolvedURL(cdnBase: cdnBase) {
            let p = thumb.path.lowercased()
            if p.hasSuffix(".gif") || p.hasSuffix(".png") || p.hasSuffix(".jpg") || p.hasSuffix(".jpeg") {
                return thumb
            }
        }

        // 3. Fallbacks for image, thumbnail, or video
        if let img = image?.resolvedURL(cdnBase: cdnBase), Self.isImageOrAnimURL(img) {
            return img
        }
        if let thumb = thumbnail?.resolvedURL(cdnBase: cdnBase), Self.isImageOrAnimURL(thumb) {
            return thumb
        }
        if let vid = video?.resolvedURL(cdnBase: cdnBase), Self.isImageOrAnimURL(vid) {
            return vid
        }
        return nil
    }

    private static func isImageOrAnimURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let nonImageExtensions = [".mp4", ".webm", ".mov", ".m4v", ".mkv", ".avi", ".webp"]
        return !nonImageExtensions.contains(where: { path.hasSuffix($0) })
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
            var candidate = url
            // If url doesn't have an image extension but proxyUrl is available, prefer proxyUrl
            if let u = url, let parsed = URL(string: u) {
                let path = parsed.path.lowercased()
                let hasImgExt = [".gif", ".webp", ".png", ".jpg", ".jpeg"].contains(where: { path.hasSuffix($0) })
                if !hasImgExt, let p = proxyUrl {
                    candidate = p
                }
            } else if candidate == nil {
                candidate = proxyUrl
            }
            guard let rawStr = candidate else { return nil }
            let trimmedBase = cdnBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmedBase.contains("discordapp.com") && !trimmedBase.contains("discord.com") {
                if let parsed = URL(string: rawStr), let host = parsed.host, host.contains("discord") {
                    let pathAndQuery = parsed.path + (parsed.query.map { "?\($0)" } ?? "")
                    return URL(string: "\(trimmedBase)\(pathAndQuery)")
                }
            }
            return URL(string: rawStr)
        }
    }

    public struct EmbedProvider: Codable, Hashable, Sendable {
        public let name: String?
        public let url: String?
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
