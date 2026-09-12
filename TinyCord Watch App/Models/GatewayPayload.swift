//
//  GatewayPayload.swift
//  TinyCord Watch App
//

import Foundation

public enum GatewayOpcode: Int, Codable, Sendable {
    case dispatch = 0
    case heartbeat = 1
    case identify = 2
    case presenceUpdate = 3
    case voiceStateUpdate = 4
    case resume = 6
    case reconnect = 7
    case requestGuildMembers = 8
    case invalidSession = 9
    case hello = 10
    case heartbeatAck = 11
}

public struct GatewayMessage: Codable, Sendable {
    public let op: Int
    public let s: Int?
    public let t: String?
    // We retain the raw data chunk to decode dynamically based on event
}

public struct GatewayHelloData: Codable, Sendable {
    public let heartbeatInterval: Double

    enum CodingKeys: String, CodingKey {
        case heartbeatInterval = "heartbeat_interval"
    }
}

public struct GatewayReadyData: Codable, Sendable {
    public let v: Int
    public let user: DiscordUser
    public let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case v
        case user
        case sessionId = "session_id"
    }
}

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
