//
//  DiscordUser.swift
//  TinyCord Watch App
//

import Foundation

public struct DiscordUser: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let username: String
    public let discriminator: String?
    public let globalName: String?
    public let avatar: String?
    public let bot: Bool?
    public let system: Bool?
    public let accentColor: Int?
    public let banner: String?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case discriminator
        case globalName = "global_name"
        case avatar
        case bot
        case system
        case accentColor = "accent_color"
        case banner
    }

    public var displayName: String {
        if let globalName, !globalName.isEmpty {
            return globalName
        }
        return username
    }

    public var handle: String {
        if let discriminator, discriminator != "0", !discriminator.isEmpty {
            return "\(username)#\(discriminator)"
        }
        return "@\(username)"
    }

    public func avatarURL(cdnBase: String, size: Int = 128) -> URL? {
        let base = cdnBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let avatar, !avatar.isEmpty {
            let ext = avatar.hasPrefix("a_") ? "gif" : "png"
            return URL(string: "\(base)/avatars/\(id)/\(avatar).\(ext)?size=\(size)")
        }

        // Default Discord avatar formula
        let defaultIndex: Int
        if let discriminator, let discInt = Int(discriminator), discInt > 0 {
            defaultIndex = discInt % 5
        } else if let idInt = Int(id.suffix(4)) {
            defaultIndex = (idInt >> 22) % 6
        } else {
            defaultIndex = 0
        }
        return URL(string: "\(base)/embed/avatars/\(defaultIndex).png")
    }
}
