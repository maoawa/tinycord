//
//  EndpointConfig.swift
//  TinyCord Watch App
//

import Foundation
import Combine

public final class EndpointConfig: ObservableObject, @unchecked Sendable {
    public static let shared = EndpointConfig()

    public static let defaultAPIBase = "https://discord.com/api/v10"
    public static let defaultCDNBase = "https://cdn.discordapp.com"
    public static let defaultGateway = "wss://gateway.discord.gg/?v=10&encoding=json"

    private enum Keys {
        static let apiBase = "tinycord_api_base_url"
        static let cdnBase = "tinycord_cdn_base_url"
        static let gateway = "tinycord_gateway_url"
        static let useGateway = "tinycord_enable_gateway"
        static let profiles = "tinycord_endpoint_profiles"
        static let selectedProfileId = "tinycord_selected_profile_id"
    }

    private let defaults = UserDefaults.standard

    @Published public var profiles: [EndpointProfile]
    @Published public var selectedProfileId: String

    @Published public var apiBaseURL: String {
        didSet {
            defaults.set(apiBaseURL, forKey: Keys.apiBase)
        }
    }

    @Published public var cdnBaseURL: String {
        didSet {
            defaults.set(cdnBaseURL, forKey: Keys.cdnBase)
        }
    }

    @Published public var gatewayURL: String {
        didSet {
            defaults.set(gatewayURL, forKey: Keys.gateway)
        }
    }

    @Published public var enableGateway: Bool {
        didSet {
            defaults.set(enableGateway, forKey: Keys.useGateway)
        }
    }

    public init() {
        var loadedProfiles: [EndpointProfile] = []
        if let data = defaults.data(forKey: Keys.profiles),
           let decoded = try? JSONDecoder().decode([EndpointProfile].self, from: data) {
            loadedProfiles = decoded
        }
        // Ensure Official Discord is always at index 0 and marked isOfficial
        loadedProfiles.removeAll { $0.id == EndpointProfile.official.id }
        loadedProfiles.insert(EndpointProfile.official, at: 0)
        self.profiles = loadedProfiles

        let targetSelectedId: String
        let savedSelectedId = defaults.string(forKey: Keys.selectedProfileId)
        if let savedSelectedId, loadedProfiles.contains(where: { $0.id == savedSelectedId }) {
            targetSelectedId = savedSelectedId
        } else {
            targetSelectedId = EndpointProfile.official.id
        }
        self.selectedProfileId = targetSelectedId

        let currentProfile = loadedProfiles.first(where: { $0.id == targetSelectedId }) ?? EndpointProfile.official

        let savedApi = defaults.string(forKey: Keys.apiBase)
        self.apiBaseURL = (savedApi?.isEmpty == false) ? savedApi! : currentProfile.apiBaseURL

        let savedCdn = defaults.string(forKey: Keys.cdnBase)
        self.cdnBaseURL = (savedCdn?.isEmpty == false) ? savedCdn! : currentProfile.cdnBaseURL

        let savedGw = defaults.string(forKey: Keys.gateway)
        self.gatewayURL = (savedGw?.isEmpty == false) ? savedGw! : currentProfile.gatewayURL

        if defaults.object(forKey: Keys.useGateway) != nil {
            self.enableGateway = defaults.bool(forKey: Keys.useGateway)
        } else {
            self.enableGateway = true
        }
    }

    public var activeProfile: EndpointProfile {
        profiles.first(where: { $0.id == selectedProfileId }) ?? EndpointProfile.official
    }

    public var isOfficialDiscord: Bool {
        selectedProfileId == EndpointProfile.official.id ||
        (apiBaseURL.contains("discord.com") && cdnBaseURL.contains("discordapp.com"))
    }

    public func selectProfile(id: String) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        self.selectedProfileId = id
        defaults.set(id, forKey: Keys.selectedProfileId)

        self.apiBaseURL = profile.apiBaseURL
        self.cdnBaseURL = profile.cdnBaseURL
        self.gatewayURL = profile.gatewayURL

        if enableGateway && AuthStore.shared.isAuthenticated {
            DiscordGatewayClient.shared.reconnect(force: true)
        }
    }

    public func updateProfiles(_ newProfiles: [EndpointProfile], selectedId: String? = nil) {
        var sanitized = newProfiles.filter { $0.id != EndpointProfile.official.id }
        sanitized.insert(EndpointProfile.official, at: 0)
        self.profiles = sanitized

        if let data = try? JSONEncoder().encode(sanitized) {
            defaults.set(data, forKey: Keys.profiles)
        }

        let targetId = selectedId ?? self.selectedProfileId
        if sanitized.contains(where: { $0.id == targetId }) {
            selectProfile(id: targetId)
        } else {
            selectProfile(id: EndpointProfile.official.id)
        }
    }

    public func resetToOfficial() {
        selectProfile(id: EndpointProfile.official.id)
    }

    public func applyBaseHost(_ hostString: String) {
        var trimmed = hostString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("https://") {
            trimmed = String(trimmed.dropFirst("https://".count))
        } else if trimmed.lowercased().hasPrefix("http://") {
            trimmed = String(trimmed.dropFirst("http://".count))
        } else if trimmed.lowercased().hasPrefix("wss://") {
            trimmed = String(trimmed.dropFirst("wss://".count))
        } else if trimmed.lowercased().hasPrefix("ws://") {
            trimmed = String(trimmed.dropFirst("ws://".count))
        }
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if trimmed.lowercased().hasPrefix("cdn.") {
            trimmed = String(trimmed.dropFirst(4))
        } else if trimmed.lowercased().hasPrefix("gateway.") {
            trimmed = String(trimmed.dropFirst(8))
        } else if trimmed.lowercased().hasPrefix("api.") {
            trimmed = String(trimmed.dropFirst(4))
        }

        guard !trimmed.isEmpty else { return }

        // Mapping:
        // discord.com -> <host>
        // cdn.discordapp.com -> cdn.<host>
        // gateway.discord.gg -> gateway.<host>
        apiBaseURL = "https://\(trimmed)/api/v10"
        cdnBaseURL = "https://cdn.\(trimmed)"
        gatewayURL = "wss://gateway.\(trimmed)/?v=10&encoding=json"
    }

    public func apiURL(path: String) -> URL? {
        let base = apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: "\(base)\(cleanPath)")
    }

    public func rewriteCDNURL(_ originalString: String) -> URL? {
        let trimmedBase = cdnBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedBase != Self.defaultCDNBase {
            if let originalURL = URL(string: originalString), let host = originalURL.host,
               (host == "cdn.discordapp.com" || host == "media.discordapp.net") {
                let pathAndQuery = originalURL.path + (originalURL.query.map { "?\($0)" } ?? "")
                return URL(string: "\(trimmedBase)\(pathAndQuery)")
            }
        }
        return URL(string: originalString)
    }
}
