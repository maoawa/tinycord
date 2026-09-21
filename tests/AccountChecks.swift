import Foundation

final class MemoryAccountStorage: AccountStorage {
    var data: Data?
    var failWrites = false
    func read() throws -> Data? { data }
    func write(_ data: Data) throws {
        if failWrites { throw KeychainAccountStorage.StorageError() }
        self.data = data
    }
}

// Small transport fixtures keep these checks independent of SwiftUI and WatchKit.
public struct DiscordChannel: Decodable { let id: String }
public struct DiscordMessage: Decodable { let id: String }
public struct DiscordRelationship: Decodable { let id: String }
public final class EndpointConfig: @unchecked Sendable {
    public static let shared = EndpointConfig()
    public var apiBaseURL = "https://test.invalid/api/v10"
    func apiURL(path: String) -> URL? { URL(string: apiBaseURL + path) }
}

final class AccountURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var pending: [AccountURLProtocol] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.pending.append(self); Self.lock.unlock()
    }
    override func stopLoading() {}
    static var count: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    static func at(_ index: Int) -> AccountURLProtocol { lock.lock(); defer { lock.unlock() }; return pending[index] }
    func respond(_ status: Int, _ body: String, headers: [String: String] = [:]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
struct AccountChecks {
    @MainActor static func main() async throws {
        let suite = "TinyCord.AccountChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = MemoryAccountStorage()
        defaults.set("legacy-token", forKey: "tinycord_auth_token")
        let auth = AuthStore(defaults: defaults, storage: storage)
        precondition(auth.token == "legacy-token" && auth.accounts.count == 1)
        precondition(defaults.string(forKey: "tinycord_auth_token") == nil)
        let firstID = auth.activeAccountID!
        let firstSession = auth.sessionID
        precondition(auth.setCredentials(token: " legacy-token "))
        precondition(auth.sessionID == firstSession && auth.accounts.count == 1)
        let user = try JSONDecoder().decode(DiscordUser.self, from: Data(#"{"id":"101","username":"alice"}"#.utf8))
        auth.updateCurrentUser(user, forSession: firstSession)
        precondition(auth.currentUser?.id == "101")
        precondition(auth.setCredentials(token: "second-token", isBot: true))
        let secondID = auth.activeAccountID!
        precondition(auth.currentUser == nil && auth.authHeaderValue == "Bot second-token")
        auth.updateCurrentUser(user, forSession: firstSession)
        precondition(auth.currentUser == nil, "Old profile responses must not overwrite the active account")
        auth.setCredentials(token: "legacy-token", activate: false)
        precondition(auth.activeAccountID == secondID, "Repeated phone sync must not switch back")
        precondition(auth.selectAccount(id: firstID))
        precondition(auth.currentUser?.id == "101" && auth.sessionID != firstSession)
        storage.failWrites = true
        precondition(!auth.selectAccount(id: secondID) && auth.activeAccountID == firstID)
        precondition(!auth.removeAccount(id: firstID) && auth.accounts.count == 2)
        storage.failWrites = false
        auth.setCredentials(token: "replacement-token")
        auth.updateCurrentUser(user, forSession: auth.sessionID)
        precondition(auth.accounts.count == 2 && !auth.accounts.contains { $0.token == "legacy-token" })
        let restored = AuthStore(defaults: defaults, storage: storage)
        precondition(restored.token == "replacement-token" && restored.accounts.count == 2)
        restored.logout()
        precondition(!restored.isAuthenticated && restored.accounts.count == 1)
        precondition(restored.selectAccount(id: secondID) && restored.isBotToken)

        let failedStorage = MemoryAccountStorage()
        failedStorage.failWrites = true
        defaults.set("must-survive", forKey: "tinycord_auth_token")
        let failedMigration = AuthStore(defaults: defaults, storage: failedStorage)
        precondition(!failedMigration.isAuthenticated && defaults.string(forKey: "tinycord_auth_token") == "must-survive")
        precondition(!failedMigration.setCredentials(token: "do-not-overwrite"))
        defaults.removeObject(forKey: "tinycord_auth_token")
        print("PASS: account migration, deduplication, restoration, failed writes, removal, and stale profiles")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = DiscordAPIClient(session: session, authStore: auth, endpointConfig: .shared)
        let scoped = client.scopedToCurrentAccount()
        let profileTask = Task { try await scoped.getCurrentUser() }
        try await waitForCount(1)
        auth.selectAccount(id: secondID)
        AccountURLProtocol.at(0).respond(200, #"{"id":"999","username":"wrong-account"}"#)
        do { _ = try await profileTask.value; preconditionFailure("Expected stale response cancellation") }
        catch is CancellationError {}
        precondition(auth.currentUser == nil)
        do { _ = try await scoped.sendMessage(channelId: "1", content: "must not send"); preconditionFailure() }
        catch is CancellationError {}
        precondition(AccountURLProtocol.count == 1)

        let captchaTask = Task { try await client.uploadAttachment(channelId: "1", fileData: Data([1]), filename: "voice.ogg", mimeType: "audio/ogg", isVoiceMessage: true) }
        try await waitForCount(2)
        AccountURLProtocol.at(1).respond(400, #"{"captcha_key":["captcha-required"],"captcha_sitekey":"synthetic"}"#)
        do { _ = try await captchaTask.value; preconditionFailure() }
        catch DiscordAPIError.captchaRequired {}
        precondition(AccountURLProtocol.count == 2, "CAPTCHA must not cause an upload fallback")

        let uncertain = Task { try await client.uploadAttachment(channelId: "1", fileData: Data([1]), filename: "voice.ogg", mimeType: "audio/ogg", isVoiceMessage: true) }
        try await waitForCount(3)
        let pending = AccountURLProtocol.at(2)
        pending.client?.urlProtocol(pending, didFailWithError: URLError(.networkConnectionLost))
        do { _ = try await uncertain.value; preconditionFailure() } catch DiscordAPIError.networkError {}
        precondition(AccountURLProtocol.count == 3, "Uncertain delivery must not resend the upload")

        let rateLimited = Task { try await client.sendMessage(channelId: "1", content: "test") }
        try await waitForCount(4)
        AccountURLProtocol.at(3).respond(429, "{}", headers: ["Retry-After": "0.1"])
        try await Task.sleep(for: .milliseconds(50))
        auth.setCredentials(token: "third-token")
        do { _ = try await rateLimited.value; preconditionFailure() } catch is CancellationError {}
        precondition(AccountURLProtocol.count == 4, "Account switches cancel pending rate-limit retries")
        print("PASS: request isolation, stale responses, CAPTCHA handling, and bounded upload retries")
    }

    static func waitForCount(_ count: Int) async throws {
        for _ in 0..<200 {
            if AccountURLProtocol.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Expected mocked request did not start")
    }
}
