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
        let ext: String
        switch formatType {
        case 1, 2: ext = "png" // PNG / APNG
        case 3: ext = "json" // Lottie, not a PNG on Discord's CDN
        case 4: ext = "gif"
        default: return nil
        }
        return URL(string: "\(trimmed)/stickers/\(id).\(ext)")
    }

    public func displayURL(cdnBase: String, companionURL: String?) -> URL? {
        guard formatType == 3 else { return stickerURL(cdnBase: cdnBase) }
        guard let companionURL, let base = EndpointProfile.validatedPresenceURL(companionURL),
              (17...20).contains(id.count), id.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return base.appendingPathComponent("v1/stickers/\(id).png")
    }
}
