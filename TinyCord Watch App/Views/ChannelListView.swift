//
//  ChannelListView.swift
//  TinyCord Watch App
//

import SwiftUI

struct ChannelListView: View {
    @StateObject private var viewModel = ChannelListViewModel()
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var presenceClient = PresenceClient.shared
    @EnvironmentObject var authStore: AuthStore
    @State private var showSettings = false
    @State private var showNewMessage = false
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                if viewModel.isLoading && viewModel.channels.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                if let error = viewModel.errorMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Error loading chats")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task {
                                await viewModel.loadChannels()
                            }
                        }
                        .font(.system(size: 11))
                    }
                    .padding(.vertical, 4)
                }

                ForEach(viewModel.filteredChannels) { channel in
                    NavigationLink(value: channel) {
                        ChannelRowView(
                            channel: channel,
                            currentUserId: authStore.currentUser?.id,
                            isTyping: viewModel.typingChannelIds.contains(channel.id)
                        )
                    }

                }

                if !viewModel.isLoading && viewModel.channels.isEmpty && viewModel.errorMessage == nil {
                    VStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text("No direct messages found")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle {
                Text("DMs")
                    .foregroundStyle(themeManager.color)
                    .fontWeight(.semibold)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        if let user = authStore.currentUser,
                           let avatarURL = user.avatarURL(cdnBase: EndpointConfig.shared.cdnBaseURL, size: 128) {
                            CachedAsyncImage(url: avatarURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 30, height: 30)
                                        .clipShape(Circle())
                                default:
                                    Image(systemName: "gearshape.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.white)
                                        .frame(width: 30, height: 30)
                                        .background(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))
                                        .clipShape(Circle())
                                }
                            }
                        } else {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))
                                .clipShape(Circle())
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
                    .overlay(alignment: .bottomTrailing) {
                        if presenceClient.state == .connected {
                            Circle()
                                .fill(.green)
                                .frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                                .accessibilityHidden(true)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityValue(presenceClient.state == .connected ? "Active on Apple Watch" : "")
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()

                    Button {
                        showNewMessage = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))
                }
            }
            .navigationDestination(for: DiscordChannel.self) { channel in
                ChatView(channel: channel) { messageID in
                    viewModel.markAsRead(channelId: channel.id, messageId: messageID)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showNewMessage) {
                NewMessageView(existingChannels: viewModel.channels) { selectedChannel in
                    if !viewModel.channels.contains(where: { $0.id == selectedChannel.id }) {
                        viewModel.channels.insert(selectedChannel, at: 0)
                    }
                    navPath.append(selectedChannel)
                }
            }
            .task {
                await viewModel.loadChannels()
            }
            .alert("Discord read state", isPresented: Binding(
                get: { viewModel.readStateError != nil },
                set: { if !$0 { viewModel.readStateError = nil } }
            )) {
                Button("OK", role: .cancel) { viewModel.readStateError = nil }
            } message: {
                Text(viewModel.readStateError ?? "")
            }
            .refreshable {
                await viewModel.loadChannels()
            }
        }
    }
}
