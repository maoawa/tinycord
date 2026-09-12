//
//  ChannelListViewModel.swift
//  TinyCord Watch App
//

import Foundation
import SwiftUI
import Combine

@MainActor
public final class ChannelListViewModel: ObservableObject {
    @Published public var channels: [DiscordChannel] = []
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String?
    @Published public var searchText: String = ""
    @Published public private(set) var typingChannelIds: Set<String> = []

    private let apiClient: DiscordAPIClient
    private let gatewayClient: DiscordGatewayClient
    private let authStore: AuthStore
    private let endpointConfig: EndpointConfig
    private var cancellables = Set<AnyCancellable>()
    private var typingExpiryTasks: [String: Task<Void, Never>] = [:]
    private var snippetFetchTask: Task<Void, Never>?

    private let cachedSnippetsKey = "tinycord_cached_channel_snippets"
    private var cachedSnippets: [String: CachedSnippetData] = [:]

    public struct CachedSnippetData: Codable {
        public let lastMessageId: String?
        public let snippet: String
        public let timestamp: Date?
        public var authorId: String?
        public var authorName: String?

        public init(
            lastMessageId: String?,
            snippet: String,
            timestamp: Date?,
            authorId: String? = nil,
            authorName: String? = nil
        ) {
            self.lastMessageId = lastMessageId
            self.snippet = snippet
            self.timestamp = timestamp
            self.authorId = authorId
            self.authorName = authorName
        }
    }

    public init(
        apiClient: DiscordAPIClient = .shared,
        gatewayClient: DiscordGatewayClient = .shared,
        authStore: AuthStore = .shared,
        endpointConfig: EndpointConfig = .shared
    ) {
        self.apiClient = apiClient
        self.gatewayClient = gatewayClient
        self.authStore = authStore
        self.endpointConfig = endpointConfig

        loadCachedSnippets()
        setupSubscriptions()
    }

    private func loadCachedSnippets() {
        if let data = UserDefaults.standard.data(forKey: cachedSnippetsKey),
           let decoded = try? JSONDecoder().decode([String: CachedSnippetData].self, from: data) {
            self.cachedSnippets = decoded
        }
    }

    public func saveSnippet(
        channelId: String,
        messageId: String?,
        snippet: String,
        timestamp: Date?,
        authorId: String? = nil,
        authorName: String? = nil
    ) {
        let entry = CachedSnippetData(
            lastMessageId: messageId,
            snippet: snippet,
            timestamp: timestamp,
            authorId: authorId,
            authorName: authorName
        )
        cachedSnippets[channelId] = entry
        if let encoded = try? JSONEncoder().encode(cachedSnippets) {
            UserDefaults.standard.set(encoded, forKey: cachedSnippetsKey)
        }
    }

    private func setupSubscriptions() {
        // Gateway message listener
        gatewayClient.messageCreatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.handleIncomingMessage(message)
            }
            .store(in: &cancellables)

        // Gateway typing listener
        gatewayClient.typingStartPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] typing in
                self?.handleTyping(typing)
            }
            .store(in: &cancellables)
    }

    public var filteredChannels: [DiscordChannel] {
        let currentUserId = authStore.currentUser?.id
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return channels
        }
        let lower = searchText.lowercased()
        return channels.filter { channel in
            let name = channel.displayName(currentUserId: currentUserId).lowercased()
            let subtitle = channel.displaySubtitle(currentUserId: currentUserId).lowercased()
            return name.contains(lower) || subtitle.contains(lower)
        }
    }

    public func loadChannels() async {
        guard authStore.isAuthenticated else { return }

        isLoading = true
        errorMessage = nil

        do {
            // Load user profile if not present
            if authStore.currentUser == nil {
                _ = try? await apiClient.getCurrentUser()
            }

            var fetched = try await apiClient.getDMChannels()

            // Sort channels by lastMessageId descending (Discord Snowflake IDs are chronologically sortable)
            fetched.sort { c1, c2 in
                let id1 = c1.lastMessageId ?? "0"
                let id2 = c2.lastMessageId ?? "0"
                return id1.compare(id2, options: .numeric) == .orderedDescending
            }

            // Preserve client-side unread states and cached snippets across refreshes
            let existingUnreads = Set(channels.filter(\.hasUnread).map(\.id))

            for i in 0..<fetched.count {
                let id = fetched[i].id
                if existingUnreads.contains(id) {
                    fetched[i].hasUnread = true
                }
                if let cached = cachedSnippets[id] {
                    fetched[i].lastMessageSnippet = cached.snippet
                    fetched[i].lastMessageTime = cached.timestamp
                    fetched[i].lastMessageAuthorId = cached.authorId
                    fetched[i].lastMessageAuthorName = cached.authorName
                }
            }

            self.channels = fetched
            self.isLoading = false

            // Connect Gateway for live push updates
            if endpointConfig.enableGateway {
                gatewayClient.connect()
            }

            // Fetch real latest messages from API for recent channels
            fetchLatestMessagesForChannels()
        } catch {
            self.isLoading = false
            self.errorMessage = error.localizedDescription
        }
    }

    private func fetchLatestMessagesForChannels() {
        snippetFetchTask?.cancel()
        snippetFetchTask = Task { [weak self] in
            guard let self else { return }
            let channelsToFetch = Array(self.channels.prefix(15))

            for channel in channelsToFetch {
                if Task.isCancelled { break }

                // Check if already cached with matching message ID and author info (if group)
                if let cached = self.cachedSnippets[channel.id],
                   let lastId = channel.lastMessageId,
                   !lastId.isEmpty,
                   cached.lastMessageId == lastId,
                   (!channel.isGroup || cached.authorId != nil || cached.authorName != nil) {
                    continue
                }

                guard let lastId = channel.lastMessageId, !lastId.isEmpty else { continue }

                do {
                    let msgs = try await self.apiClient.getMessages(channelId: channel.id, limit: 1)
                    guard !Task.isCancelled, let latest = msgs.first else { continue }

                    await MainActor.run {
                        if let index = self.channels.firstIndex(where: { $0.id == channel.id }) {
                            self.channels[index].lastMessageSnippet = latest.displaySnippet
                            self.channels[index].lastMessageTime = latest.parsedDate
                            self.channels[index].lastMessageAuthorId = latest.author.id
                            self.channels[index].lastMessageAuthorName = latest.author.displayName
                            self.saveSnippet(
                                channelId: channel.id,
                                messageId: latest.id,
                                snippet: latest.displaySnippet,
                                timestamp: latest.parsedDate,
                                authorId: latest.author.id,
                                authorName: latest.author.displayName
                            )
                        }
                    }
                } catch {
                    // Ignore per-channel errors
                }

                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private func handleIncomingMessage(_ message: DiscordMessage) {
        let channelId = message.channelId
        // Our own messages synced from other devices shouldn't flag unread.
        let isOwnMessage = message.author.id == authStore.currentUser?.id
        if let index = channels.firstIndex(where: { $0.id == channelId }) {
            var channel = channels.remove(at: index)
            channel.lastMessageSnippet = message.displaySnippet
            channel.lastMessageTime = message.parsedDate
            channel.lastMessageAuthorId = message.author.id
            channel.lastMessageAuthorName = message.author.displayName
            if !isOwnMessage {
                channel.hasUnread = true
            }
            saveSnippet(
                channelId: channelId,
                messageId: message.id,
                snippet: message.displaySnippet,
                timestamp: message.parsedDate,
                authorId: message.author.id,
                authorName: message.author.displayName
            )
            // Bring active channel to the top
            channels.insert(channel, at: 0)
        }
        if !isOwnMessage {
            typingChannelIds.remove(channelId)
        }
    }

    private func handleTyping(_ typing: GatewayTypingData) {
        guard typing.userId != authStore.currentUser?.id else { return }
        typingChannelIds.insert(typing.channelId)
        typingExpiryTasks[typing.channelId]?.cancel()
        typingExpiryTasks[typing.channelId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.typingChannelIds.remove(typing.channelId)
            self.typingExpiryTasks.removeValue(forKey: typing.channelId)
        }
    }

    public func markAsRead(channelId: String) {
        if let index = channels.firstIndex(where: { $0.id == channelId }) {
            channels[index].hasUnread = false
        }
    }

    public func markAsUnread(channelId: String) {
        if let index = channels.firstIndex(where: { $0.id == channelId }) {
            channels[index].hasUnread = true
        }
    }

    public func toggleUnread(channelId: String) {
        if let index = channels.firstIndex(where: { $0.id == channelId }) {
            channels[index].hasUnread.toggle()
        }
    }
}
