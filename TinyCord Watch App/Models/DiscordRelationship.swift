//
//  DiscordRelationship.swift
//  TinyCord Watch App
//

import Foundation

public struct DiscordRelationship: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let type: Int // 1 = friend, 2 = blocked, 3 = incoming request, 4 = outgoing request
    public let nickname: String?
    public let user: DiscordUser

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case nickname
        case user
    }

    public var isFriend: Bool {
        type == 1
    }

    public var displayName: String {
        if let nickname, !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nickname
        }
        return user.displayName
    }
}
