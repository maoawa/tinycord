//
//  DiscordAttachment.swift
//  TinyCord Watch App
//

import Foundation

public struct DiscordAttachment: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let filename: String
    public let size: Int
    public let url: String
    public let proxyUrl: String?
    public let width: Int?
    public let height: Int?
    public let contentType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case filename
        case size
        case url
        case proxyUrl = "proxy_url"
        case width
        case height
        case contentType = "content_type"
    }

    public var isImage: Bool {
        if let contentType, contentType.lowercased().hasPrefix("image/") {
            return true
        }
        let lower = filename.lowercased()
        return lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") ||
               lower.hasSuffix(".gif") || lower.hasSuffix(".webp")
    }

    public func resolvedURL(cdnBase: String) -> URL? {
        let trimmedBase = cdnBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // If CDN base is custom, rewrite standard discord cdn url
        if !trimmedBase.contains("discordapp.com") && !trimmedBase.contains("discord.com") {
            if let parsed = URL(string: url), let host = parsed.host, host.contains("discord") {
                let pathAndQuery = parsed.path + (parsed.query.map { "?\($0)" } ?? "")
                return URL(string: "\(trimmedBase)\(pathAndQuery)")
            }
        }
        return URL(string: url)
    }
}
