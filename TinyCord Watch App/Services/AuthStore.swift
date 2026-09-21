import Foundation
import Combine

public struct SavedAccount: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    var token: String
    public var isBot: Bool
    public var user: DiscordUser?

    public var displayName: String { user?.displayName ?? (isBot ? "Bot account" : "Unverified account") }
}

public final class AuthStore: ObservableObject, @unchecked Sendable {
    public static let shared = AuthStore()

    private struct Vault: Codable, Equatable {
        var accounts: [SavedAccount] = []
        var activeID: UUID?
    }
    private let storage: any AccountStorage
    private let defaults: UserDefaults
    private var vault = Vault()
    private var storageReady = false

    @Published public private(set) var accounts: [SavedAccount] = []
    @Published public private(set) var activeAccountID: UUID?
    /// Changes even on A → B → A, invalidating old requests and view models.
    @Published public private(set) var sessionID = UUID()
    @Published public private(set) var token: String?
    @Published public private(set) var isBotToken = false
    @Published public private(set) var currentUser: DiscordUser?
    @Published public var storageError: String?

    public var isAuthenticated: Bool { token?.isEmpty == false }

    public convenience init() {
        self.init(defaults: .standard, storage: KeychainAccountStorage())
    }

    init(defaults: UserDefaults, storage: any AccountStorage) {
        self.defaults = defaults
        self.storage = storage
        do {
            if let data = try storage.read() {
                vault = try JSONDecoder().decode(Vault.self, from: data)
            } else if let legacy = defaults.string(forKey: "tinycord_auth_token"), !legacy.isEmpty {
                let user = defaults.data(forKey: "tinycord_cached_user").flatMap {
                    try? JSONDecoder().decode(DiscordUser.self, from: $0)
                }
                let account = SavedAccount(id: UUID(), token: legacy,
                                           isBot: defaults.bool(forKey: "tinycord_is_bot_token"), user: user)
                vault = Vault(accounts: [account], activeID: account.id)
                try storage.write(JSONEncoder().encode(vault))
            }
            storageReady = true
            removeLegacyCredentials()
            apply(vault)
        } catch {
            storageError = error.localizedDescription
        }
    }

    /// Repeated iPhone syncs update a saved entry without forcing an account switch.
    @discardableResult
    public func setCredentials(token: String, isBot: Bool = false, activate: Bool = true) -> Bool {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        var next = vault
        let account: SavedAccount
        if let existing = next.accounts.first(where: { $0.token == clean && $0.isBot == isBot }) {
            account = existing
        } else {
            account = SavedAccount(id: UUID(), token: clean, isBot: isBot, user: nil)
            next.accounts.append(account)
        }
        if activate || next.activeID == nil { next.activeID = account.id }
        return commit(next)
    }

    @discardableResult
    public func selectAccount(id: UUID) -> Bool {
        guard vault.accounts.contains(where: { $0.id == id }) else { return false }
        var next = vault
        next.activeID = id
        return commit(next)
    }

    @discardableResult
    public func removeAccount(id: UUID) -> Bool {
        var next = vault
        next.accounts.removeAll { $0.id == id }
        if next.activeID == id { next.activeID = nil }
        guard commit(next) else { return false }
        // Snippets belong to the removed account, not to the next person signing in.
        let prefix = "tinycord_cached_channel_snippets.\(id.uuidString)."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
        return true
    }

    public func logout() {
        if let id = activeAccountID { _ = removeAccount(id: id) }
    }

    public func updateCurrentUser(_ user: DiscordUser, forSession id: UUID) {
        guard sessionID == id, let index = vault.accounts.firstIndex(where: { $0.id == activeAccountID }) else { return }
        var next = vault
        next.accounts[index].user = user
        // A newly issued token for the same verified user replaces its old entry.
        let activeID = next.activeID
        next.accounts.removeAll { $0.id != activeID && $0.user?.id == user.id && $0.isBot == isBotToken }
        _ = commit(next)
    }

    private func commit(_ next: Vault) -> Bool {
        guard storageReady else {
            storageError = "Saved accounts are unavailable. Unlock your watch and reopen TinyCord."
            return false
        }
        if next == vault { return true }
        do {
            try storage.write(JSONEncoder().encode(next))
            apply(next)
            storageError = nil
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    private func apply(_ next: Vault) {
        let account = next.accounts.first { $0.id == next.activeID }
        let changed = token != account?.token || isBotToken != (account?.isBot ?? false) || activeAccountID != account?.id
        vault = next
        accounts = next.accounts
        activeAccountID = account?.id
        currentUser = account?.user
        if changed {
            isBotToken = account?.isBot ?? false
            token = account?.token
            sessionID = UUID()
        }
    }

    private func removeLegacyCredentials() {
        for key in ["tinycord_auth_token", "tinycord_is_bot_token", "tinycord_cached_user", "tinycord_cached_channel_snippets"] {
            defaults.removeObject(forKey: key)
        }
    }

    public var authHeaderValue: String? {
        guard let token, !token.isEmpty else { return nil }
        return isBotToken ? "Bot \(token)" : token
    }
}
