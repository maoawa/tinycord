//
//  EndpointProfile.swift
//  TinyCord Watch App
//

import Foundation

public struct EndpointProfile: Identifiable, Codable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var apiBaseURL: String
    public var cdnBaseURL: String
    public var gatewayURL: String
    public var isOfficial: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        apiBaseURL: String,
        cdnBaseURL: String,
        gatewayURL: String,
        isOfficial: Bool = false
    ) {
        self.id = id
        self.name = name
        self.apiBaseURL = apiBaseURL
        self.cdnBaseURL = cdnBaseURL
        self.gatewayURL = gatewayURL
        self.isOfficial = isOfficial
    }

    public static let official = EndpointProfile(
        id: "official",
        name: "Official Discord",
        apiBaseURL: "https://discord.com/api/v10",
        cdnBaseURL: "https://cdn.discordapp.com",
        gatewayURL: "wss://gateway.discord.gg/?v=10&encoding=json",
        isOfficial: true
    )

    public var hostDisplay: String {
        if let url = URL(string: apiBaseURL), let host = url.host {
            return host
        }
        return apiBaseURL
    }
}
