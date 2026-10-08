//
//  ChatViewModel.swift
//  TinyCord Watch App
//

import Foundation
import SwiftUI
import Combine
#if canImport(WatchKit)
import WatchKit
#endif

@MainActor
public final class ChatViewModel: ObservableObject {
    public let channel: DiscordChannel

    @Published public var messages: [DiscordMessage] = []
    @Published public var isLoading: Bool = false
    @Published public var isSending: Bool = false
    @Published public var errorMessage: String?
    @Published public private(set) var pendingSaveError: String?
    @Published public private(set) var localSendID: String?
    @Published public var replyingTo: DiscordMessage?
    @Published public var typingUserNames: [String] = []
    @Published public var isLoadingOlder: Bool = false
    @Published public var hasMoreHistory: Bool = true
    @Published public private(set) var hasLoadedMessages = false
    private let historyCache: ChatHistoryCache
    private var pendingPayloads: [String: OutgoingMessagePayload] = [:]
    private var loadedAccountToken: String?
    private var loadedAPIBase: String?
    private var loadedProfileID: String?

    /// Excludes optimistic local messages, which have no Discord read cursor.
    public var readCursorMessageID: String? {
        guard hasLoadedMessages, loadedAccountToken == authStore.token,
              loadedAPIBase == EndpointConfig.shared.apiBaseURL,
              loadedProfileID == EndpointConfig.shared.selectedProfileId else { return nil }
        return messages.last { $0.sendStatus == .sent && (UInt64($0.id) ?? 0) > 0 }?.id
    }

    private let apiClient: DiscordAPIClient
    private let presenceClient: PresenceClient
    private let authStore: AuthStore
    private var cancellables = Set<AnyCancellable>()
    private var typingResetTask: Task<Void, Never>?
    private var needsHistoryRefresh = false
    private var deletedDuringRefresh = Set<String>()

    public init(
        channel: DiscordChannel,
        apiClient: DiscordAPIClient = .shared,
        presenceClient: PresenceClient? = nil,
        authStore: AuthStore = .shared,
        cacheDirectory: URL? = nil
    ) {
        self.channel = channel
        self.apiClient = apiClient.scopedToCurrentAccount()
        self.presenceClient = presenceClient ?? .shared
        self.authStore = authStore
        self.historyCache = ChatHistoryCache(accountID: authStore.activeAccountID, apiBase: EndpointConfig.shared.apiBaseURL,
                                             root: cacheDirectory ?? PersistentCacheStore.root)
        historyCache.rememberChannel(channel)
        if let cached = historyCache.load(channelID: channel.id) {
            pendingPayloads = cached.pending
            messages = cached.restoredMessages.map(markedAsOutgoing)
            hasMoreHistory = cached.hasMoreHistory
            hasLoadedMessages = true
            loadedAccountToken = authStore.token
            loadedAPIBase = EndpointConfig.shared.apiBaseURL
            loadedProfileID = EndpointConfig.shared.selectedProfileId
        }
        setupPresenceSubscriptions()
    }

    private func setupPresenceSubscriptions() {
        presenceClient.resyncPublisher
            .sink { [weak self] in
                // A lost event window may include deletions or more than ten
                // messages. Reload the current page instead of only appending.
                Task { @MainActor in await self?.loadMessages() }
            }
            .store(in: &cancellables)

        // Real-time new messages
        presenceClient.messageCreatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                if (try? self.apiClient.checkAccount()) != nil, message.channelId == self.channel.id {
                    self.appendMessage(message)
                }
            }
            .store(in: &cancellables)

        // Real-time message deletion
        presenceClient.messageDeletePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] del in
                guard let self else { return }
                if (try? self.apiClient.checkAccount()) != nil, del.channelId == self.channel.id {
                    if self.isLoading { self.deletedDuringRefresh.insert(del.id) }
                    self.messages.removeAll { $0.id == del.id }
                    self.saveHistory()
                }
            }
            .store(in: &cancellables)

        // Real-time typing indicators
        presenceClient.typingStartPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] typing in
                guard let self else { return }
                if typing.channelId == self.channel.id && typing.userId != self.authStore.currentUser?.id {
                    self.handleTyping(userId: typing.userId)
                }
            }
            .store(in: &cancellables)
    }

    private var pollTask: Task<Void, Never>?

    public func loadMessages() async {
        guard !isLoading, (try? apiClient.checkAccount()) != nil else { return }
        isLoading = true
        deletedDuringRefresh.removeAll()
        let existingIDs = Set(messages.map(\.id))
        errorMessage = nil
        let accountToken = authStore.token
        let apiBase = EndpointConfig.shared.apiBaseURL
        let profileID = EndpointConfig.shared.selectedProfileId

        do {
            // Stop here if this token is rejected instead of issuing more requests.
            if authStore.currentUser == nil {
                _ = try await apiClient.getCurrentUser()
            }
            var fetched = try await apiClient.getMessages(channelId: channel.id, limit: 40)
            try Task.checkCancellation()
            guard accountToken == authStore.token, apiBase == EndpointConfig.shared.apiBaseURL,
                  profileID == EndpointConfig.shared.selectedProfileId else {
                isLoading = false
                return
            }
            // Discord returns messages newest first; reverse so oldest is at the top, newest at bottom
            fetched.reverse()
            let pageCount = fetched.count
            fetched.removeAll { deletedDuringRefresh.contains($0.id) }
            let fetchedIDs = Set(fetched.map(\.id))
            let liveArrivals = messages.filter {
                $0.sendStatus == .sent && !existingIDs.contains($0.id) && !fetchedIDs.contains($0.id)
            }
            let merged = CachedChat.mergingLatest(fetched.map(markedAsOutgoing), into: messages, pageSize: 40, fetchedCount: pageCount)
            let mergedIDs = Set(merged.map(\.id))
            let confirmed = (merged.filter { $0.sendStatus == .sent } + liveArrivals.filter { !mergedIDs.contains($0.id) })
                .sorted { (UInt64($0.id) ?? 0) < (UInt64($1.id) ?? 0) }
            self.messages = confirmed + merged.filter { $0.sendStatus != .sent }
            self.hasMoreHistory = pageCount >= 40 && (hasMoreHistory || confirmed.count <= pageCount + liveArrivals.count)
            needsHistoryRefresh = false
            saveHistory()
            self.loadedAccountToken = accountToken
            self.loadedAPIBase = apiBase
            self.loadedProfileID = profileID
            self.hasLoadedMessages = true
            self.isLoading = false
            startPollingIfNeeded()
        } catch {
            self.isLoading = false
            guard !Task.isCancelled, !DiscordRequestCancellation.isCancellation(error) else { return }
            self.errorMessage = messages.isEmpty ? error.localizedDescription : "Showing saved messages. " + error.localizedDescription
            if case DiscordAPIError.unauthorized = error { stopPolling() }
            else if case DiscordAPIError.captchaRequired = error { stopPolling() }
            else { needsHistoryRefresh = true; startPollingIfNeeded() }
        }
    }

    private func saveHistory() {
        guard (try? apiClient.checkAccount()) != nil else { return }
        let saved = historyCache.save(channelID: channel.id, messages: messages, pending: pendingPayloads, hasMoreHistory: hasMoreHistory)
        pendingSaveError = saved ? nil : "Couldn't save the unsent attachment. Keep this chat open to retry."
    }

    /// Fetches the next page of older messages and prepends them.
    public func loadOlderMessages() async {
        guard !isLoadingOlder, hasMoreHistory, let oldest = messages.first(where: { $0.sendStatus == .sent }) else { return }

        isLoadingOlder = true
        defer { isLoadingOlder = false }

        do {
            var older = try await apiClient.getMessages(channelId: channel.id, limit: 40, before: oldest.id)
            if older.isEmpty {
                hasMoreHistory = false
                saveHistory()
                return
            }
            older.reverse()
            if older.count < 40 {
                hasMoreHistory = false
            }
            let existingIds = Set(messages.map(\.id))
            let fresh = older.map(markedAsOutgoing).filter { !existingIds.contains($0.id) }
            messages.insert(contentsOf: fresh, at: 0)
            saveHistory()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    public func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, !Task.isCancelled else { break }
                // REST remains the fallback when TinyCord Companion is unavailable.
                if self.presenceClient.state != .connected || self.needsHistoryRefresh {
                    if self.needsHistoryRefresh { await self.loadMessages() }
                    else { await self.pollLatestMessages() }
                }
                // Companion does not forward MESSAGE_UPDATE. Refresh unfinished
                // call records over HTTPS even while its event stream is healthy.
                await self.refreshCallRecords()
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollLatestMessages() async {
        do {
            let fresh = try await apiClient.getMessages(channelId: channel.id, limit: 10)
            for msg in fresh.reversed() {
                if let index = self.messages.firstIndex(where: { $0.id == msg.id }) {
                    self.messages[index] = markedAsOutgoing(msg)
                } else {
                    self.appendMessage(msg)
                }
            }
            saveHistory()
        } catch DiscordAPIError.unauthorized {
            stopPolling()
            errorMessage = "Your token is no longer valid. Check your account in Discord, then update it in Settings."
        } catch DiscordAPIError.captchaRequired {
            stopPolling()
            errorMessage = DiscordAPIError.captchaRequired.localizedDescription
        } catch {
            // Transient read failures can wait for the next foreground poll.
        }
    }

    private func markedAsOutgoing(_ message: DiscordMessage) -> DiscordMessage {
        var msg = message
        if let currentUserId = authStore.currentUser?.id {
            msg.isOutgoing = msg.sendStatus != .sent || msg.author.id == currentUserId
        }
        return msg
    }

    private func refreshCallRecords() async {
        let pending = messages.filter { $0.isCall && $0.call != nil && $0.call?.endedTimestamp == nil }.suffix(3)
        for message in pending {
            guard !Task.isCancelled else { return }
            guard let updated = try? await apiClient.getMessage(channelId: channel.id, messageId: message.id),
                  !Task.isCancelled,
                  let index = messages.firstIndex(where: { $0.id == message.id }) else { continue }
            messages[index] = markedAsOutgoing(updated)
            saveHistory()
        }
    }

    public func sendMessage(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await enqueue(.text(trimmed), preview: trimmed)
    }

    public func sendPhotoMessage(imageData: Data, filename: String = "photo.jpg") async {
        await enqueue(.attachment(data: imageData, filename: filename, mimeType: "image/jpeg",
                                  isVoiceMessage: false, durationSecs: nil), preview: "📷 Photo")
    }

    public func sendVoiceMessage(audioData: Data, durationSecs: Float, filename: String = "voice-message.m4a") async {
        await enqueue(.attachment(data: audioData, filename: filename, mimeType: "audio/m4a",
                                  isVoiceMessage: true, durationSecs: durationSecs),
                      preview: "🎤 Voice Message (\(Int(durationSecs))s)")
    }

    private func enqueue(_ payload: OutgoingMessagePayload, preview: String) async {
        guard (try? apiClient.checkAccount()) != nil else { return }
        let tempID = "temp_\(UUID().uuidString)"
        let target = replyingTo
        let author = authStore.currentUser ?? DiscordUser(id: "me", username: "Me", discriminator: nil,
            globalName: "Me", avatar: nil, bot: false, system: false, accentColor: nil, banner: nil)
        let message = DiscordMessage(id: tempID, channelId: channel.id, author: author, content: preview,
            timestamp: DiscordMessage.isoFormatterStandard.string(from: Date()),
            messageReference: target.map { MessageReference(messageId: $0.id, channelId: channel.id, guildId: nil) },
            referencedMessage: target.map { ReferencedMessageWrapper(message: $0) },
            isOutgoing: true, sendStatus: .sending)
        pendingPayloads[tempID] = payload
        messages.append(message)
        localSendID = tempID
        replyingTo = nil
        saveHistory()
        await transmit(message, payload: payload)
    }

    public func retrySendMessage(_ message: DiscordMessage) async {
        // Consult the live row so repeated taps cannot upload the same file twice.
        guard let current = messages.first(where: { $0.id == message.id }), current.sendStatus == .failed else { return }
        guard let payload = pendingPayloads[current.id] else {
            errorMessage = "The original message is unavailable. Please compose it again."
            return
        }
        await transmit(current, payload: payload)
    }

    public func discardFailedMessage(_ message: DiscordMessage) {
        guard messages.contains(where: { $0.id == message.id && $0.sendStatus == .failed }) else { return }
        messages.removeAll { $0.id == message.id }
        pendingPayloads.removeValue(forKey: message.id)
        saveHistory()
    }

    private func transmit(_ message: DiscordMessage, payload: OutgoingMessagePayload) async {
        guard let index = messages.firstIndex(where: { $0.id == message.id }),
              (try? apiClient.checkAccount()) != nil else { return }
        messages[index].sendStatus = .sending
        isSending = true
        errorMessage = nil
        defer { isSending = messages.contains { $0.sendStatus == .sending } }
        do {
            let sent = try await payload.send(using: apiClient, channelID: channel.id,
                                              replyID: message.messageReference?.messageId)
            try apiClient.checkAccount()
            let marked = markedAsOutgoing(sent)
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                if messages.contains(where: { $0.id == marked.id }) { messages.remove(at: index) }
                else { messages[index] = marked }
            } else if !messages.contains(where: { $0.id == marked.id }) {
                messages.append(marked)
            }
            pendingPayloads.removeValue(forKey: message.id)
            saveHistory()
            presenceClient.messageCreatePublisher.send(marked)
        } catch {
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index].sendStatus = .failed
            }
            saveHistory()
            if !DiscordRequestCancellation.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    public func sendQuickReply(_ text: String) async {
        await sendMessage(text: text)
    }

    public func addReaction(to message: DiscordMessage, emoji: String) async {
        do {
            try await apiClient.addReaction(channelId: channel.id, messageId: message.id, emoji: emoji)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func appendMessage(_ message: DiscordMessage) {
        // Prevent duplicate entries
        if messages.contains(where: { $0.id == message.id }) {
            return
        }

        let msg = markedAsOutgoing(message)

        messages.append(msg)
        saveHistory()

        #if canImport(WatchKit)
        if !msg.isOutgoing {
            WKInterfaceDevice.current().play(.notification)
        }
        #endif
    }

    private func handleTyping(userId: String) {
        let name = channel.recipients?.first(where: { $0.id == userId })?.displayName ?? "Someone"
        if !typingUserNames.contains(name) {
            typingUserNames.append(name)
        }

        typingResetTask?.cancel()
        typingResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.typingUserNames.removeAll()
        }
    }
}
