//
//  DiscordStickerItem.swift
//  TinyCord Watch App
//

import Foundation

public struct DiscordStickerItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let formatType: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case formatType = "format_type"
    }

    public func stickerURL(cdnBase: String) -> URL? {
        let trimmed = cdnBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let ext = formatType == 4 ? "gif" : "png"
        return URL(string: "\(trimmed)/stickers/\(id).\(ext)")
    }
}
