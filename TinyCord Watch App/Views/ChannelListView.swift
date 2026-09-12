//
//  ChannelListView.swift
//  TinyCord Watch App
//

import SwiftUI

struct ChannelListView: View {
    @StateObject private var viewModel = ChannelListViewModel()
    @ObservedObject private var themeManager = ThemeManager.shared
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            viewModel.toggleUnread(channelId: channel.id)
                        } label: {
                            Label(
                                channel.hasUnread ? "Read" : "Unread",
                                systemImage: channel.hasUnread ? "envelope.open.fill" : "envelope.badge.fill"
                            )
                        }
                        .tint(channel.hasUnread ? Color.gray : Color.blue)
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
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(.white)
                    }
                    .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))
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
                ChatView(channel: channel).onAppear {
                    viewModel.markAsRead(channelId: channel.id)
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
            .refreshable {
                await viewModel.loadChannels()
            }
        }
    }
}
