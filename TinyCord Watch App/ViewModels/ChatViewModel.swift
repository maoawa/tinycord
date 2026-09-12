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
    @Published public var replyingTo: DiscordMessage?
    @Published public var typingUserNames: [String] = []
    @Published public var isLoadingOlder: Bool = false
    @Published public var hasMoreHistory: Bool = true

    private let apiClient: DiscordAPIClient
    private let gatewayClient: DiscordGatewayClient
    private let authStore: AuthStore
    private var cancellables = Set<AnyCancellable>()
    private var typingResetTask: Task<Void, Never>?

    public init(
        channel: DiscordChannel,
        apiClient: DiscordAPIClient = .shared,
        gatewayClient: DiscordGatewayClient = .shared,
        authStore: AuthStore = .shared
    ) {
        self.channel = channel
        self.apiClient = apiClient
        self.gatewayClient = gatewayClient
        self.authStore = authStore

        setupGatewaySubscriptions()
    }

    private func setupGatewaySubscriptions() {
        // Real-time new messages
        gatewayClient.messageCreatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                if message.channelId == self.channel.id {
                    self.appendMessage(message)
                }
            }
            .store(in: &cancellables)

        // Real-time message deletion
        gatewayClient.messageDeletePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] del in
                guard let self else { return }
                if del.channelId == self.channel.id {
                    self.messages.removeAll { $0.id == del.id }
                }
            }
            .store(in: &cancellables)

        // Real-time typing indicators
        gatewayClient.typingStartPublisher
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
        isLoading = true
        errorMessage = nil

        // Ensure current user profile is available to accurately mark outgoing messages
        if authStore.currentUser == nil {
            _ = try? await apiClient.getCurrentUser()
        }

        do {
            var fetched = try await apiClient.getMessages(channelId: channel.id, limit: 40)
            // Discord returns messages newest first; reverse so oldest is at the top, newest at bottom
            fetched.reverse()
            self.messages = fetched.map(markedAsOutgoing)
            self.hasMoreHistory = fetched.count >= 40
            self.isLoading = false
            startPollingIfNeeded()
        } catch {
            self.isLoading = false
            self.errorMessage = error.localizedDescription
        }
    }

    /// Fetches the next page of older messages and prepends them.
    public func loadOlderMessages() async {
        guard !isLoadingOlder, hasMoreHistory, let oldest = messages.first else { return }

        isLoadingOlder = true
        defer { isLoadingOlder = false }

        do {
            var older = try await apiClient.getMessages(channelId: channel.id, limit: 40, before: oldest.id)
            if older.isEmpty {
                hasMoreHistory = false
                return
            }
            older.reverse()
            if older.count < 40 {
                hasMoreHistory = false
            }
            let existingIds = Set(messages.map(\.id))
            let fresh = older.map(markedAsOutgoing).filter { !existingIds.contains($0.id) }
            messages.insert(contentsOf: fresh, at: 0)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    public func startPollingIfNeeded() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, !Task.isCancelled else { break }
                // If Gateway is not connected (e.g. endpoint blocks WS or firewall), poll via REST
                if self.gatewayClient.state != .connected {
                    await self.pollLatestMessages()
                }
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
                if !self.messages.contains(where: { $0.id == msg.id }) {
                    self.appendMessage(msg)
                }
            }
        } catch {
            // Ignore poll errors quietly
        }
    }

    private func markedAsOutgoing(_ message: DiscordMessage) -> DiscordMessage {
        var msg = message
        if let currentUserId = authStore.currentUser?.id {
            msg.isOutgoing = (msg.author.id == currentUserId)
        }
        return msg
    }

    public func sendMessage(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let tempId = "temp_\(UUID().uuidString)"
        let replyTarget = replyingTo
        let replyId = replyTarget?.id

        let author = authStore.currentUser ?? DiscordUser(
            id: "me",
            username: "Me",
            discriminator: nil,
            globalName: "Me",
            avatar: nil,
            bot: false,
            system: false,
            accentColor: nil,
            banner: nil
        )

        let optimisticMessage = DiscordMessage(
            id: tempId,
            channelId: channel.id,
            author: author,
            content: trimmed,
            timestamp: DiscordMessage.isoFormatterStandard.string(from: Date()),
            editedTimestamp: nil,
            attachments: nil,
            embeds: nil,
            messageReference: replyId != nil ? MessageReference(messageId: replyId, channelId: channel.id, guildId: nil) : nil,
            referencedMessage: replyTarget != nil ? ReferencedMessageWrapper(message: replyTarget) : nil,
            reactions: nil,
            pinned: false,
            isOutgoing: true,
            sendStatus: .sending
        )

        // Immediately show preview
        self.messages.append(optimisticMessage)
        self.replyingTo = nil
        self.isSending = true

        do {
            let sent = try await apiClient.sendMessage(
                channelId: channel.id,
                content: trimmed,
                replyToMessageId: replyId
            )
            self.isSending = false
            let marked = markedAsOutgoing(sent)

            if let index = self.messages.firstIndex(where: { $0.id == tempId }) {
                if self.messages.contains(where: { $0.id == marked.id && $0.id != tempId }) {
                    self.messages.remove(at: index)
                } else {
                    self.messages[index] = marked
                }
            } else if !self.messages.contains(where: { $0.id == marked.id }) {
                self.messages.append(marked)
            }

            // Notify Gateway listeners so channel snippet & position update immediately
            DiscordGatewayClient.shared.messageCreatePublisher.send(marked)
        } catch {
            self.isSending = false
            self.errorMessage = error.localizedDescription

            if let index = self.messages.firstIndex(where: { $0.id == tempId }) {
                self.messages[index].sendStatus = .failed
            }
        }
    }

    public func retrySendMessage(_ message: DiscordMessage) async {
        guard message.sendStatus == .failed else { return }

        if let index = self.messages.firstIndex(where: { $0.id == message.id }) {
            self.messages[index].sendStatus = .sending
        }

        let replyId = message.messageReference?.messageId
        do {
            let sent = try await apiClient.sendMessage(
                channelId: channel.id,
                content: message.content,
                replyToMessageId: replyId
            )
            let marked = markedAsOutgoing(sent)
            if let index = self.messages.firstIndex(where: { $0.id == message.id }) {
                if self.messages.contains(where: { $0.id == marked.id && $0.id != message.id }) {
                    self.messages.remove(at: index)
                } else {
                    self.messages[index] = marked
                }
            } else if !self.messages.contains(where: { $0.id == marked.id }) {
                self.messages.append(marked)
            }
        } catch {
            if let index = self.messages.firstIndex(where: { $0.id == message.id }) {
                self.messages[index].sendStatus = .failed
            }
            self.errorMessage = error.localizedDescription
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

    public func sendPhotoMessage(imageData: Data, filename: String = "photo.jpg") async {
        let tempId = "temp_\(UUID().uuidString)"
        let replyTarget = replyingTo
        let replyId = replyTarget?.id

        let author = authStore.currentUser ?? DiscordUser(
            id: "me",
            username: "Me",
            discriminator: nil,
            globalName: "Me",
            avatar: nil,
            bot: false,
            system: false,
            accentColor: nil,
            banner: nil
        )

        let optimisticMessage = DiscordMessage(
            id: tempId,
            channelId: channel.id,
            author: author,
            content: "📷 Photo",
            timestamp: DiscordMessage.isoFormatterStandard.string(from: Date()),
            editedTimestamp: nil,
            attachments: nil,
            embeds: nil,
            messageReference: replyId != nil ? MessageReference(messageId: replyId, channelId: channel.id, guildId: nil) : nil,
            referencedMessage: replyTarget != nil ? ReferencedMessageWrapper(message: replyTarget) : nil,
            reactions: nil,
            pinned: false,
            isOutgoing: true,
            sendStatus: .sending
        )

        self.messages.append(optimisticMessage)
        self.replyingTo = nil
        self.isSending = true

        do {
            let sent = try await apiClient.uploadAttachment(
                channelId: channel.id,
                fileData: imageData,
                filename: filename,
                mimeType: "image/jpeg",
                replyToMessageId: replyId
            )
            self.isSending = false
            let marked = markedAsOutgoing(sent)

            if let index = self.messages.firstIndex(where: { $0.id == tempId }) {
                if self.messages.contains(where: { $0.id == marked.id && $0.id != tempId }) {
                    self.messages.remove(at: index)
                } else {
                    self.messages[index] = marked
                }
            } else if !self.messages.contains(where: { $0.id == marked.id }) {
                self.messages.append(marked)
            }

            DiscordGatewayClient.shared.messageCreatePublisher.send(marked)
        } catch {
            self.isSending = false
            self.errorMessage = error.localizedDescription
            if let index = self.messages.firstIndex(where: { $0.id == tempId }) {
                self.messages[index].sendStatus = .failed
            }
        }
    }

    public func sendVoiceMessage(audioData: Data, durationSecs: Float, filename: String = "voice-message.m4a") async {
        let tempId = "temp_\(UUID().uuidString)"
        let replyTarget = replyingTo
        let replyId = replyTarget?.id

        let author = authStore.currentUser ?? DiscordUser(
            id: "me",
            username: "Me",
            discriminator: nil,
            globalName: "Me",
            avatar: nil,
            bot: false,
            system: false,
            accentColor: nil,
            banner: nil
        )

        let optimisticMessage = DiscordMessage(
            id: tempId,
            channelId: channel.id,
            author: author,
            content: "🎤 Voice Message (\(Int(durationSecs))s)",
            timestamp: DiscordMessage.isoFormatterStandard.string(from: Date()),
            editedTimestamp: nil,
            attachments: nil,
            embeds: nil,
            messageReference: replyId != nil ? MessageReference(messageId: replyId, channelId: channel.id, guildId: nil) : nil,
            referencedMessage: replyTarget != nil ? ReferencedMessageWrapper(message: replyTarget) : nil,
            reactions: nil,
            pinned: false,
            isOutgoing: true,
            sendStatus: .sending
        )

        self.messages.append(optimisticMessage)
        self.replyingTo = nil
        self.isSending = true

        do {
            let sent = try await apiClient.uploadAttachment(
                channelId: channel.id,
                fileData: audioData,
                filename: filename,
                mimeType: "audio/m4a",
                replyToMessageId: replyId,
                isVoiceMessage: true,
                durationSecs: durationSecs
            )
            self.isSending = false
            let marked = markedAsOutgoing(sent)

            if let index = self.messages.firstIndex(where: { $0.id == tempId }) {
                if self.messages.contains(where: { $0.id == marked.id && $0.id != tempId }) {
                    self.messages.remove(at: index)
                } else {
                    self.messages[index] = marked
                }
            } else if !self.messages.contains(where: { $0.id == marked.id }) {
                self.messages.append(marked)
            }

            DiscordGatewayClient.shared.messageCreatePublisher.send(marked)
        } catch {
            self.isSending = false
            self.errorMessage = error.localizedDescription
            if let index = self.messages.firstIndex(where: { $0.id == tempId }) {
                self.messages[index].sendStatus = .failed
            }
        }
    }

    private func appendMessage(_ message: DiscordMessage) {
        // Prevent duplicate entries
        if messages.contains(where: { $0.id == message.id }) {
            return
        }

        let msg = markedAsOutgoing(message)

        // If an optimistic sending message matches this outgoing message, replace it
        if msg.isOutgoing, let tempIndex = messages.firstIndex(where: { $0.sendStatus == .sending && $0.content == msg.content }) {
            messages[tempIndex] = msg
            return
        }

        messages.append(msg)

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
            guard let self else { return }
            self.typingUserNames.removeAll()
        }
    }
}
