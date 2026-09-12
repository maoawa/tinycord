//
//  AuthStore.swift
//  TinyCord Watch App
//

import Foundation
import Combine

public final class AuthStore: ObservableObject, @unchecked Sendable {
    public static let shared = AuthStore()

    private enum Keys {
        static let token = "tinycord_auth_token"
        static let isBotToken = "tinycord_is_bot_token"
        static let cachedUser = "tinycord_cached_user"
    }

    private let defaults = UserDefaults.standard

    @Published public var token: String? {
        didSet {
            if let token, !token.isEmpty {
                defaults.set(token, forKey: Keys.token)
            } else {
                defaults.removeObject(forKey: Keys.token)
            }
        }
    }

    @Published public var isBotToken: Bool {
        didSet {
            defaults.set(isBotToken, forKey: Keys.isBotToken)
        }
    }

    @Published public var currentUser: DiscordUser? {
        didSet {
            if let currentUser, let data = try? JSONEncoder().encode(currentUser) {
                defaults.set(data, forKey: Keys.cachedUser)
            } else {
                defaults.removeObject(forKey: Keys.cachedUser)
            }
        }
    }

    public var isAuthenticated: Bool {
        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    public init() {
        self.token = defaults.string(forKey: Keys.token)
        self.isBotToken = defaults.bool(forKey: Keys.isBotToken)

        if let userData = defaults.data(forKey: Keys.cachedUser),
           let user = try? JSONDecoder().decode(DiscordUser.self, from: userData) {
            self.currentUser = user
        }
    }

    public func setCredentials(token: String, isBot: Bool = false) {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isBotToken = isBot
        self.token = clean
    }

    public func logout() {
        self.token = nil
        self.currentUser = nil
        self.isBotToken = false
        defaults.removeObject(forKey: Keys.token)
        defaults.removeObject(forKey: Keys.cachedUser)
        defaults.removeObject(forKey: Keys.isBotToken)
    }

    public var authHeaderValue: String? {
        guard let token, !token.isEmpty else { return nil }
        if isBotToken {
            return "Bot \(token)"
        }
        return token
    }
}
