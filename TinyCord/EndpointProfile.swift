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
    public var presenceEnabled: Bool
    public var presenceServerURL: String
    public var isOfficial: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        apiBaseURL: String,
        cdnBaseURL: String,
        gatewayURL: String,
        isOfficial: Bool = false,
        presenceEnabled: Bool = false,
        presenceServerURL: String = ""
    ) {
        self.id = id
        self.name = name
        self.apiBaseURL = apiBaseURL
        self.cdnBaseURL = cdnBaseURL
        self.gatewayURL = gatewayURL
        self.isOfficial = isOfficial
        self.presenceEnabled = presenceEnabled
        self.presenceServerURL = presenceServerURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, apiBaseURL, cdnBaseURL, gatewayURL, isOfficial
        case presenceEnabled, presenceServerURL
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        apiBaseURL = try values.decode(String.self, forKey: .apiBaseURL)
        cdnBaseURL = try values.decode(String.self, forKey: .cdnBaseURL)
        // Older profiles may omit the call-only Gateway endpoint.
        gatewayURL = try values.decodeIfPresent(String.self, forKey: .gatewayURL) ?? ""
        isOfficial = try values.decodeIfPresent(Bool.self, forKey: .isOfficial) ?? false
        presenceEnabled = try values.decodeIfPresent(Bool.self, forKey: .presenceEnabled) ?? false
        presenceServerURL = try values.decodeIfPresent(String.self, forKey: .presenceServerURL) ?? ""
    }

    /// Accept an HTTPS origin only; credentials, redirects, paths and queries
    /// must never decide where an authentication request is sent.
    public static func validatedPresenceURL(_ address: String) -> URL? {
        let clean = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: clean), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!),
              let url = parts.url else { return nil }
        return url
    }

    /// A call Gateway may use a proxy path, but never plaintext, userinfo, or a
    /// fragment. Normalize the wire format because the client decodes JSON v10.
    public static func validatedGatewayURL(_ address: String) -> URL? {
        let clean = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: clean), parts.scheme?.lowercased() == "wss",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!) else { return nil }
        var query = parts.queryItems ?? []
        query.removeAll { ["v", "encoding", "compress"].contains($0.name) }
        query += [URLQueryItem(name: "v", value: "10"), URLQueryItem(name: "encoding", value: "json")]
        parts.queryItems = query
        return parts.url
    }

    public var callGatewayURL: URL? {
        Self.validatedGatewayURL(gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? Self.official.gatewayURL : gatewayURL)
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
