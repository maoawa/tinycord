import Foundation
import Combine

final class MemoryChatAccounts: AccountStorage {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

public final class EndpointConfig: @unchecked Sendable {
    public static let shared = EndpointConfig()
    public var apiBaseURL = "https://test.invalid/api/v10"
    public var selectedProfileId = "test"
    func apiURL(path: String) -> URL? { URL(string: apiBaseURL + path) }
}

@MainActor public final class PresenceClient {
    public static let shared = PresenceClient()
    enum State { case connected, disconnected }
    var state = State.connected
    let messageCreatePublisher = PassthroughSubject<DiscordMessage, Never>()
    let messageDeletePublisher = PassthroughSubject<GatewayMessageDeleteData, Never>()
    let typingStartPublisher = PassthroughSubject<GatewayTypingData, Never>()
    let resyncPublisher = PassthroughSubject<Void, Never>()
}

final class ChatURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var pending: [ChatURLProtocol] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.pending.append(self); Self.lock.unlock()
    }
    override func stopLoading() {}
    static var count: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    static func at(_ index: Int) -> ChatURLProtocol { lock.lock(); defer { lock.unlock() }; return pending[index] }
    func respond(_ status: Int, _ body: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    var body: Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

@main struct ChatReliabilityChecks {
    static func message(_ id: String, content: String = "hello", timestamp: String = "2026-10-09T00:00:00Z") -> DiscordMessage {
        DiscordMessage(id: id, channelId: "channel", author: user, content: content, timestamp: timestamp)
    }
    static let user = try! JSONDecoder().decode(DiscordUser.self, from: Data(#"{"id":"101","username":"Sat"}"#.utf8))
    @MainActor static func waitForRequest(_ count: Int) async {
        for _ in 0..<200 {
            if ChatURLProtocol.count >= count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Missing request \(count)")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PersistentCacheStore(directory: root.appendingPathComponent("lru"), byteLimit: 8)
        disk.write(Data("aaaa".utf8), key: "a")
        disk.write(Data("bbbb".utf8), key: "b")
        // Force old dates to show that reads retain expired-looking offline content.
        let aURL = disk.directory.appendingPathComponent(PersistentCacheStore.key("a"))
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: aURL.path)
        precondition(disk.read("a") == Data("aaaa".utf8))
        disk.write(Data("cccc".utf8), key: "c")
        precondition(disk.read("b") == nil && disk.read("a") != nil && disk.size == 8)
        precondition(!disk.write(Data(repeating: 0, count: 9), key: "too-large"))
        let reopened = PersistentCacheStore(directory: disk.directory, byteLimit: 8)
        precondition(reopened.read("a") != nil)
        let avatar64 = AvatarCacheIdentity(URL(string: "https://cdn.test/avatars/101/hash.png?size=64")!)!
        let avatar128 = AvatarCacheIdentity(URL(string: "https://cdn.test/avatars/101/hash.png?size=128")!)!
        let changedAvatar = AvatarCacheIdentity(URL(string: "https://cdn.test/avatars/101/new.png?size=128")!)!
        let otherUser = AvatarCacheIdentity(URL(string: "https://cdn.test/avatars/102/hash.png")!)!
        let avatars = AvatarCache(root: root)
        avatars.save(Data("image".utf8), for: avatar64)
        precondition(avatar64.key == avatar128.key)
        let coldAvatars = AvatarCache(root: root)
        precondition(coldAvatars.data(for: avatar128) == Data("image".utf8))
        precondition(coldAvatars.data(for: changedAvatar) == nil)
        precondition(coldAvatars.data(for: changedAvatar, fallback: true) == Data("image".utf8))
        precondition(coldAvatars.data(for: otherUser, fallback: true) == nil)
        print("PASS: persistent LRU budget, age-independent reads, cold avatars, size normalization and fallback isolation")

        let suite = "TinyCord.ChatChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = AuthStore(defaults: defaults, storage: MemoryChatAccounts())
        auth.setCredentials(token: "test-token")
        auth.updateCurrentUser(user, forSession: auth.sessionID)
        let endpoint = EndpointConfig.shared
        let cache = ChatHistoryCache(accountID: auth.activeAccountID, apiBase: endpoint.apiBaseURL, root: root)
        let channel = try JSONDecoder().decode(DiscordChannel.self, from: Data(#"{"id":"channel","type":1,"recipients":[{"id":"102","username":"friend"}]}"#.utf8))
        cache.saveChannels([channel])
        cache.save(channelID: channel.id, messages: (1...250).map { message(String($0)) }, pending: [:], hasMoreHistory: false)
        let history = cache.load(channelID: channel.id)!
        precondition(history.messages.count == 200 && history.messages.first?.id == "51" && history.hasMoreHistory)
        precondition(cache.loadChannels().first?.recipients?.first?.username == "friend")
        precondition(ChatHistoryCache(accountID: UUID(), apiBase: endpoint.apiBaseURL, root: root).load(channelID: channel.id) == nil)
        precondition(ChatHistoryCache(accountID: auth.activeAccountID, apiBase: "https://other.test", root: root).loadChannels().isEmpty)
        var unsent = message("temp_test"); unsent.sendStatus = .failed
        let merged = CachedChat.mergingLatest([message("249", content: "edited"), message("251")], into: history.messages + [unsent], pageSize: 2)
        precondition(merged.contains { $0.id == "249" && $0.content == "edited" })
        precondition(!merged.contains { $0.id == "250" } && merged.last?.id == "temp_test")
        let concurrentDeletion = CachedChat.mergingLatest([message("249")], into: history.messages.filter { $0.id != "250" }, pageSize: 2, fetchedCount: 2)
        precondition(concurrentDeletion.first?.id == "51", "A deletion during a full-page refresh must not erase older history")
        let disconnected = CachedChat.mergingLatest([message("300"), message("301")], into: history.messages, pageSize: 2)
        precondition(disconnected.count == 2, "Do not stitch together history with an unfillable gap")
        print("PASS: cached channels and history, 200-message cap, account/endpoint isolation, refresh edits/deletions and gaps")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatURLProtocol.self]
        let api = DiscordAPIClient(session: URLSession(configuration: config), authStore: auth, endpointConfig: endpoint)
        let presence = PresenceClient()
        var vm: ChatViewModel? = ChatViewModel(channel: channel, apiClient: api, presenceClient: presence, authStore: auth, cacheDirectory: root)
        precondition(vm!.messages.count == 200, "Show saved messages before networking")
        vm!.replyingTo = message("249")
        let audio = Data([0, 1, 2, 3, 255, 254, 42])
        let firstSend = Task { await vm!.sendVoiceMessage(audioData: audio, durationSecs: 4.25, filename: "recording.m4a") }
        await waitForRequest(1)
        ChatURLProtocol.at(0).respond(500, Data("temporary failure".utf8))
        await waitForRequest(2)
        ChatURLProtocol.at(1).respond(200, Data("[]".utf8))
        await firstSend.value
        let failedID = vm!.messages.last!.id
        precondition(vm!.messages.last!.sendStatus == .failed)
        cache.clearDownloadedHistory()
        precondition(cache.load(channelID: channel.id)!.pending[failedID] != nil)
        precondition(cache.loadChannels().count == 1, "Clearing history must leave the outbox reachable offline")
        // Recreate the whole view model: original bytes must not be held only in RAM.
        vm!.stopPolling(); vm = nil
        let retryVM = ChatViewModel(channel: channel, apiClient: api, presenceClient: presence, authStore: auth, cacheDirectory: root)
        let failed = retryVM.messages.last!
        precondition(failed.id == failedID && failed.sendStatus == .failed)
        let retry = Task { await retryVM.retrySendMessage(failed) }
        await waitForRequest(3)
        let upload = ChatURLProtocol.at(2)
        let body = upload.body
        let text = String(decoding: body, as: UTF8.self)
        precondition(upload.request.value(forHTTPHeaderField: "Content-Type")!.hasPrefix("multipart/form-data"))
        precondition(body.range(of: audio) != nil && text.contains("recording.m4a") && text.contains("audio/m4a"))
        precondition(text.contains("8192") && text.contains("4.25") && text.contains("249"))
        precondition(text.contains(failed.nonce ?? ""), "Retries must reuse the original client nonce")
        precondition((failed.nonce?.count ?? 26) <= 25, "Discord message nonces must be at most 25 characters")
        precondition(!text.contains("Voice Message"), "Never post the optimistic voice label as text")
        await retryVM.retrySendMessage(failed)
        precondition(ChatURLProtocol.count == 3, "A second tap while uploading cannot resend")
        upload.respond(200, try JSONEncoder().encode(message("252", content: "")))
        await retry.value
        precondition(!retryVM.messages.contains { $0.id == failedID })
        precondition(cache.load(channelID: channel.id)!.pending.isEmpty)
        print("PASS: failed voice retry after reopen uses original bytes, filename, duration, flags and reply; double taps suppressed; success clears outbox")

        let offlineRead = Task { await retryVM.loadMessages() }
        await waitForRequest(4)
        ChatURLProtocol.at(3).respond(503, Data("offline".utf8))
        await offlineRead.value
        precondition(!retryVM.messages.isEmpty && retryVM.errorMessage!.contains("Showing saved messages"))
        retryVM.stopPolling()
        let photo = Data([42, 12, 254])
        let photoSend = Task { await retryVM.sendPhotoMessage(imageData: photo, filename: "my-photo.jpg") }
        await waitForRequest(5)
        ChatURLProtocol.at(4).respond(500, Data())
        await waitForRequest(6)
        ChatURLProtocol.at(5).respond(200, Data("[]".utf8))
        await photoSend.value
        let failedPhoto = retryVM.messages.last!
        let refresh = Task { await retryVM.loadMessages() }
        await waitForRequest(7)
        ChatURLProtocol.at(6).respond(200, try JSONEncoder().encode([message("252")]))
        await refresh.value
        precondition(retryVM.messages.contains { $0.id == failedPhoto.id && $0.sendStatus == .failed })
        let photoRetry = Task { await retryVM.retrySendMessage(failedPhoto) }
        await waitForRequest(8)
        let photoBody = ChatURLProtocol.at(7).body
        precondition(photoBody.range(of: photo) != nil && String(decoding: photoBody, as: UTF8.self).contains("my-photo.jpg"))
        ChatURLProtocol.at(7).respond(200, try JSONEncoder().encode(message("253")))
        await photoRetry.value
        retryVM.stopPolling()
        let beforeIncoming = retryVM.localSendID
        let raceRefresh = Task { await retryVM.loadMessages() }
        await waitForRequest(9)
        presence.messageCreatePublisher.send(message("254"))
        presence.messageDeletePublisher.send(GatewayMessageDeleteData(id: "252", channelId: "channel"))
        try? await Task.sleep(nanoseconds: 20_000_000)
        ChatURLProtocol.at(8).respond(200, try JSONEncoder().encode([message("253"), message("252")]))
        await raceRefresh.value
        precondition(retryVM.messages.contains { $0.id == "254" })
        precondition(!retryVM.messages.contains { $0.id == "252" })
        precondition(retryVM.localSendID == beforeIncoming, "Incoming messages must not request a local-send scroll")
        retryVM.stopPolling()
        let textSend = Task { await retryVM.sendMessage(text: "ordinary text") }
        await waitForRequest(10)
        ChatURLProtocol.at(9).respond(500, Data())
        await waitForRequest(11)
        ChatURLProtocol.at(10).respond(200, Data("[]".utf8))
        await textSend.value
        let failedText = retryVM.messages.last!
        let textRetry = Task { await retryVM.retrySendMessage(failedText) }
        await waitForRequest(12)
        let textJSON = try JSONSerialization.jsonObject(with: ChatURLProtocol.at(11).body) as! [String: Any]
        precondition(textJSON["content"] as? String == "ordinary text")
        ChatURLProtocol.at(11).respond(500, Data())
        await waitForRequest(13)
        ChatURLProtocol.at(12).respond(200, Data("[]".utf8))
        await textRetry.value
        retryVM.discardFailedMessage(failedText)
        precondition(cache.load(channelID: channel.id)!.pending.isEmpty)
        precondition(!retryVM.messages.contains { $0.id == failedText.id })
        let staleSend = Task { await retryVM.sendPhotoMessage(imageData: photo) }
        await waitForRequest(14)
        auth.setCredentials(token: "other-account")
        ChatURLProtocol.at(13).respond(200, try JSONEncoder().encode(message("255")))
        await staleSend.value
        precondition(!retryVM.messages.contains { $0.id == "255" })

        // Two watchOS submit callbacks for one text must share one POST.
        let duplicateSuite = "TinyCord.ChatDuplicate.\(UUID())"
        let duplicateDefaults = UserDefaults(suiteName: duplicateSuite)!
        let duplicateAuth = AuthStore(defaults: duplicateDefaults, storage: MemoryChatAccounts())
        duplicateAuth.setCredentials(token: "duplicate-token")
        duplicateAuth.updateCurrentUser(user, forSession: duplicateAuth.sessionID)
        let duplicatePresence = PresenceClient()
        let duplicateVM = ChatViewModel(channel: channel, apiClient: DiscordAPIClient(session: URLSession(configuration: config), authStore: duplicateAuth, endpointConfig: endpoint), presenceClient: duplicatePresence, authStore: duplicateAuth, cacheDirectory: root.appendingPathComponent("duplicate"))
        let requestBase = ChatURLProtocol.count
        let duplicateOne = Task { await duplicateVM.sendMessage(text: "one submit") }
        let duplicateTwo = Task { await duplicateVM.sendMessage(text: "one submit") }
        await waitForRequest(requestBase + 1)
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(ChatURLProtocol.count == requestBase + 1, "Duplicate submit callbacks must be coalesced")
        ChatURLProtocol.at(requestBase).respond(200, try JSONEncoder().encode(message("256", content: "one submit")))
        await duplicateOne.value
        await duplicateTwo.value
        precondition(duplicateVM.messages.filter { $0.content == "one submit" }.count == 1)
        duplicateDefaults.removePersistentDomain(forName: duplicateSuite)
        print("PASS: duplicate submit callbacks coalesce into one POST and one visible message")

        // If Discord accepted a POST but the client receives an error, the
        // reconciliation pass adopts the delivered message instead of exposing
        // a failed row that invites a second send.
        let acceptedText = "accepted after error"
        let acceptedSend = Task { await duplicateVM.sendMessage(text: acceptedText) }
        await waitForRequest(requestBase + 2)
        ChatURLProtocol.at(requestBase + 1).respond(500, Data("response lost".utf8))
        await waitForRequest(requestBase + 3)
        let deliveredTimestamp = DiscordMessage.isoFormatterStandard.string(from: Date())
        ChatURLProtocol.at(requestBase + 2).respond(200, try JSONEncoder().encode([message("257", content: acceptedText, timestamp: deliveredTimestamp)]))
        await acceptedSend.value
        precondition(duplicateVM.messages.contains { $0.id == "257" && $0.sendStatus == .sent })
        precondition(!duplicateVM.messages.contains { $0.sendStatus == .failed && $0.content == acceptedText })
        print("PASS: accepted POST followed by a client error is reconciled without a duplicate retry")
        // Unsend is limited to confirmed, recent messages authored by this account.
        let sentNow = DiscordMessage.isoFormatterStandard.string(from: Date())
        let now = Date()
        let recent = message("258", timestamp: sentNow)
        precondition(recent.canBeRemoved(by: user.id, at: now))
        precondition(!recent.canBeRemoved(by: "102", at: now))
        precondition(!recent.canBeRemoved(by: user.id, at: now.addingTimeInterval(901)))
        precondition(!recent.canBeRemoved(by: user.id, at: now.addingTimeInterval(-60)))
        precondition(!message("259", timestamp: "invalid").canBeRemoved(by: user.id))
        precondition(!message("temp_1", timestamp: sentNow).canBeRemoved(by: user.id))
        var notSent = recent; notSent.sendStatus = .failed
        precondition(!notSent.canBeRemoved(by: user.id))
        let call = DiscordMessage(id: "260", channelId: channel.id, author: user, content: "", timestamp: sentNow, type: 3)
        precondition(!call.canBeRemoved(by: user.id))
        precondition(!retryVM.canRemoveMessage(message("261", timestamp: "2020-01-01T00:00:00Z")))
        auth.setCredentials(token: "test-token")
        auth.updateCurrentUser(user, forSession: auth.sessionID)
        let removeVM = ChatViewModel(channel: channel, apiClient: api, presenceClient: presence, authStore: auth, cacheDirectory: root)
        removeVM.messages.append(recent)
        cache.save(channelID: channel.id, messages: removeVM.messages, pending: [:], hasMoreHistory: false)
        precondition(removeVM.canRemoveMessage(recent))
        let failedRemoveBase = ChatURLProtocol.count
        let failedRemove = Task { await removeVM.removeMessage(recent) }
        await waitForRequest(failedRemoveBase + 1)
        precondition(ChatURLProtocol.at(failedRemoveBase).request.httpMethod == "DELETE")
        precondition(ChatURLProtocol.at(failedRemoveBase).request.url!.path.hasSuffix("/channels/channel/messages/258"))
        await removeVM.removeMessage(recent)
        precondition(ChatURLProtocol.count == failedRemoveBase + 1, "Two taps must not issue two DELETEs")
        ChatURLProtocol.at(failedRemoveBase).respond(403, Data("forbidden".utf8))
        await failedRemove.value
        precondition(removeVM.messages.contains { $0.id == recent.id }, "Failed removal must preserve the message")
        precondition(cache.load(channelID: channel.id)!.messages.contains { $0.id == recent.id })
        precondition(removeVM.errorMessage?.contains("remove message") == true)
        let acceptedRemoveBase = ChatURLProtocol.count
        let acceptedRemove = Task { await removeVM.removeMessage(recent) }
        await waitForRequest(acceptedRemoveBase + 1)
        ChatURLProtocol.at(acceptedRemoveBase).respond(204, Data())
        await acceptedRemove.value
        precondition(!removeVM.messages.contains { $0.id == recent.id })
        precondition(!cache.load(channelID: channel.id)!.messages.contains { $0.id == recent.id })
        precondition(ChatURLProtocol.count == acceptedRemoveBase + 1)
        let numericNonceJSON = Data("{\"id\":\"262\",\"nonce\":12345,\"channel_id\":\"channel\",\"author\":{\"id\":\"102\",\"username\":\"Friend\",\"bot\":false},\"content\":\"nonce\",\"timestamp\":\"2026-10-11T00:00:00Z\"}".utf8)
        let numericNonce = try JSONDecoder().decode(DiscordMessage.self, from: numericNonceJSON)
        precondition(numericNonce.nonce == "12345", "Numeric Discord nonces must decode without breaking message sends")

        print("PASS: remove eligibility, confirmation-independent server deletion, duplicate guard, 403 preservation, 204 cache eviction")
        print("PASS: concurrent refresh arrivals/deletions, no incoming scroll request, text retry/discard and stale-account isolation")
        print("PASS: offline refresh keeps history, online refresh preserves failed uploads, photo retry uploads the image")
    }
}
