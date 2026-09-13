//
//  NewMessageView.swift
//  TinyCord Watch App
//

import SwiftUI

struct NewMessageView: View {
    let existingChannels: [DiscordChannel]
    let onSelectChannel: (DiscordChannel) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authStore: AuthStore
    @ObservedObject var endpointConfig = EndpointConfig.shared
    @ObservedObject var themeManager = ThemeManager.shared

    @State private var relationships: [DiscordRelationship] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var openingUserId: String? = nil

    private var allFriends: [DiscordRelationship] {
        relationships
            .filter(\.isFriend)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var filteredFriends: [DiscordRelationship] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allFriends }
        return allFriends.filter { rel in
            rel.displayName.localizedCaseInsensitiveContains(query) ||
            rel.user.username.localizedCaseInsensitiveContains(query) ||
            (rel.user.globalName?.localizedCaseInsensitiveContains(query) == true) ||
            rel.user.handle.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Error loading friends")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task {
                                await loadFriends()
                            }
                        }
                        .font(.system(size: 11))
                    }
                    .padding(.vertical, 4)
                } else if allFriends.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text("No friends found")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .listRowBackground(Color.clear)
                } else if filteredFriends.isEmpty && !searchText.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                        Text("No results for \"\(searchText)\"")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(filteredFriends) { rel in
                            Button {
                                openChat(with: rel.user)
                            } label: {
                                HStack(spacing: 8) {
                                    // Avatar
                                    if let avatarURL = rel.user.avatarURL(cdnBase: endpointConfig.cdnBaseURL, size: 64) {
                                        CachedAsyncImage(url: avatarURL) { phase in
                                            switch phase {
                                            case .success(let img):
                                                img.resizable().scaledToFill()
                                            default:
                                                Circle().fill(Color.gray.opacity(0.3))
                                            }
                                        }
                                        .frame(width: 32, height: 32)
                                        .clipShape(Circle())
                                    } else {
                                        Circle()
                                            .fill(themeManager.color.opacity(0.3))
                                            .frame(width: 32, height: 32)
                                            .overlay {
                                                Text(String(rel.displayName.prefix(1)).uppercased())
                                                    .font(.system(size: 13, weight: .bold))
                                                    .foregroundStyle(themeManager.color)
                                            }
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(rel.displayName)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        Text(rel.user.handle)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    if openingUserId == rel.user.id {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .disabled(openingUserId != nil)
                        }
                    } header: {
                        Text(searchText.isEmpty ? "Friends (\(filteredFriends.count))" : "Results (\(filteredFriends.count))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search friends")
            .navigationTitle {
                Text("New Message")
                    .foregroundStyle(themeManager.color)
                    .fontWeight(.semibold)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white)
                    }
                    .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))
                }

                ToolbarItem(placement: .topBarTrailing) {
                    TextFieldLink(prompt: Text("Search friends...")) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.white)
                    } onSubmit: { text in
                        searchText = text
                    }
                    .accessibilityLabel("Search friends")
                    .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))
                }
            }
            .task {
                await loadFriends()
            }
        }
    }

    private func loadFriends() async {
        isLoading = true
        errorMessage = nil
        do {
            let rels = try await DiscordAPIClient.shared.getRelationships()
            self.relationships = rels
            self.isLoading = false
        } catch {
            self.isLoading = false
            self.errorMessage = error.localizedDescription
        }
    }

    private func openChat(with user: DiscordUser) {
        openingUserId = user.id
        Task {
            do {
                let channel = try await DiscordAPIClient.shared.createOrGetDMChannel(recipientId: user.id)
                WKInterfaceDevice.current().play(.click)
                await MainActor.run {
                    openingUserId = nil
                    dismiss()
                    onSelectChannel(channel)
                }
            } catch {
                await MainActor.run {
                    openingUserId = nil
                    errorMessage = "Failed to open chat: \(error.localizedDescription)"
                }
            }
        }
    }
}
