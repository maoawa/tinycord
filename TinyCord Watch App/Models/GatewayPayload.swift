//
//  GatewayPayload.swift
//  TinyCord Watch App
//

import Foundation

public struct GatewayTypingData: Codable, Sendable {
    public let channelId: String
    public let userId: String
    public let timestamp: Int

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case userId = "user_id"
        case timestamp
    }
}

public struct GatewayMessageDeleteData: Codable, Sendable {
    public let id: String
    public let channelId: String

    enum CodingKeys: String, CodingKey {
        case id
        case channelId = "channel_id"
    }
}
