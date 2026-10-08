import Foundation

/// The display text is never used as the payload of an attachment retry.
enum OutgoingMessagePayload: Codable, Sendable {
    case text(String)
    case attachment(data: Data, filename: String, mimeType: String, isVoiceMessage: Bool, durationSecs: Float?)

    func send(using api: DiscordAPIClient, channelID: String, replyID: String?) async throws -> DiscordMessage {
        switch self {
        case .text(let text):
            return try await api.sendMessage(channelId: channelID, content: text, replyToMessageId: replyID)
        case let .attachment(data, filename, mimeType, voice, duration):
            return try await api.uploadAttachment(channelId: channelID, fileData: data, filename: filename,
                mimeType: mimeType, replyToMessageId: replyID, isVoiceMessage: voice, durationSecs: duration)
        }
    }
}

struct CachedChat: Codable {
    var messages: [DiscordMessage]
    var pending: [String: OutgoingMessagePayload]
    var hasMoreHistory: Bool

    var restoredMessages: [DiscordMessage] {
        messages.map { message in
            var restored = message
            // A terminated upload cannot still be in progress after reopening.
            if pending[message.id] != nil {
                restored.sendStatus = .failed
                restored.isOutgoing = true
            }
            return restored
        }
    }

    static func mergingLatest(_ latest: [DiscordMessage], into existing: [DiscordMessage], pageSize: Int,
                              fetchedCount: Int? = nil) -> [DiscordMessage] {
        let pending = existing.filter { $0.sendStatus != .sent }
        let oldest = latest.compactMap { UInt64($0.id) }.min() ?? 0
        let latestIDs = Set(latest.map(\.id))
        let overlaps = existing.contains { $0.sendStatus == .sent && latestIDs.contains($0.id) }
        let older = (fetchedCount ?? latest.count) >= pageSize && overlaps ? existing.filter {
            $0.sendStatus == .sent && (UInt64($0.id) ?? .max) < oldest
        } : []
        return older + latest + pending
    }
}

final class ChatHistoryCache {
    private let store: PersistentCacheStore
    private let outbox: PersistentCacheStore
    private let channels: PersistentCacheStore
    private let scope: String

    init(accountID: UUID?, apiBase: String, root: URL = PersistentCacheStore.root) {
        let account = root.appendingPathComponent("accounts/\(accountID?.uuidString ?? "signed-out")")
        store = PersistentCacheStore(directory: account.appendingPathComponent("history"), byteLimit: 20 * 1024 * 1024)
        channels = PersistentCacheStore(directory: account.appendingPathComponent("channels"), byteLimit: 2 * 1024 * 1024)
        // Unsent user content is not disposable cache data. Never evict it to
        // make room for downloaded history, avatars, or other channels.
        outbox = PersistentCacheStore(directory: account.appendingPathComponent("outbox"), byteLimit: .max)
        scope = apiBase
    }

    func load(channelID: String) -> CachedChat? {
        let key = "\(scope)/chat/\(channelID)"
        let history = store.read(key).flatMap { try? JSONDecoder().decode(CachedChat.self, from: $0) }
        let unsent = outbox.read(key).flatMap { try? JSONDecoder().decode(CachedChat.self, from: $0) }
        guard history != nil || unsent != nil else { return nil }
        return CachedChat(messages: (history?.messages ?? []) + (unsent?.messages ?? []),
                          pending: unsent?.pending ?? [:], hasMoreHistory: history?.hasMoreHistory ?? true)
    }

    @discardableResult
    func save(channelID: String, messages: [DiscordMessage], pending: [String: OutgoingMessagePayload], hasMoreHistory: Bool) -> Bool {
        let sent = messages.filter { $0.sendStatus == .sent }
        let snapshot = CachedChat(messages: Array(sent.suffix(200)), pending: [:],
                                  hasMoreHistory: hasMoreHistory || sent.count > 200)
        let key = "\(scope)/chat/\(channelID)"
        if let data = try? JSONEncoder().encode(snapshot) { store.write(data, key: key) }
        let unsent = messages.filter { $0.sendStatus != .sent }
        if unsent.isEmpty {
            outbox.remove(key)
            return true
        }
        let ids = Set(unsent.map(\.id))
        let pendingSnapshot = CachedChat(messages: unsent, pending: pending.filter { ids.contains($0.key) }, hasMoreHistory: true)
        guard let data = try? JSONEncoder().encode(pendingSnapshot) else { return false }
        return outbox.write(data, key: key)
    }

    func loadChannels() -> [DiscordChannel] {
        guard let data = channels.read("\(scope)/channels") else { return [] }
        return (try? JSONDecoder().decode([DiscordChannel].self, from: data)) ?? []
    }

    func saveChannels(_ channels: [DiscordChannel]) {
        guard let data = try? JSONEncoder().encode(channels) else { return }
        self.channels.write(data, key: "\(scope)/channels")
    }

    func rememberChannel(_ channel: DiscordChannel) {
        var saved = loadChannels()
        guard !saved.contains(where: { $0.id == channel.id }) else { return }
        saved.insert(channel, at: 0)
        saveChannels(saved)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(store.size + channels.size), countStyle: .file)
    }

    func clearDownloadedHistory() {
        store.clear()
        // Keep navigation metadata so unsent messages remain reachable offline.
    }
}
