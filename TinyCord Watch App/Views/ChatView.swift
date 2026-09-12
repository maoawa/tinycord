//
//  ChatView.swift
//  TinyCord Watch App
//

import SwiftUI
import PhotosUI

struct ChatView: View {
    @StateObject var viewModel: ChatViewModel
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var showQuickReplySheet = false
    @State private var showVoiceMessageSheet = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @EnvironmentObject var authStore: AuthStore
    @Environment(\.dismiss) private var dismiss

    init(channel: DiscordChannel) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(channel: channel))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    // Load earlier history
                    if viewModel.hasMoreHistory && !viewModel.messages.isEmpty {
                        Button {
                            Task {
                                await viewModel.loadOlderMessages()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if viewModel.isLoadingOlder {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                } else {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 9))
                                }
                                Text("Load earlier")
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))
                        .disabled(viewModel.isLoadingOlder)
                    }

                    if viewModel.isLoading && viewModel.messages.isEmpty {
                        ProgressView()
                            .padding()
                    }

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .padding()
                    }

                    // Message list
                    ForEach(viewModel.messages) { message in
                        MessageBubbleView(
                            message: message,
                            channelRecipients: viewModel.channel.recipients,
                            onReply: { target, text in
                                Task {
                                    viewModel.replyingTo = target
                                    await viewModel.sendMessage(text: text)
                                }
                            },
                            onReact: { target, emoji in
                                Task {
                                    await viewModel.addReaction(to: target, emoji: emoji)
                                }
                            },
                            onRetry: { target in
                                Task {
                                    await viewModel.retrySendMessage(target)
                                }
                            }
                        )
                        .id(message.id)
                    }

                    // Real-time typing indicators
                    if !viewModel.typingUserNames.isEmpty {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("\(viewModel.typingUserNames.joined(separator: ", ")) typing...")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }

                    // Bottom anchor for auto-scrolling
                    Color.clear
                        .frame(height: 1)
                        .id("bottom_anchor")
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 60)
            }
            .navigationBarBackButtonHidden(true)
            .navigationTitle {
                Text(viewModel.channel.displayName(currentUserId: authStore.currentUser?.id))
                    .foregroundStyle(themeManager.color)
                    .fontWeight(.semibold)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    // Quick reply presets
                    Button {
                        showQuickReplySheet = true
                    } label: {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                    }
                    .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))

                    Spacer()

                    HStack(spacing: 6) {
                        // Gallery button
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Image(systemName: "photo")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                        }
                        .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))

                        // Voice message button
                        Button {
                            showVoiceMessageSheet = true
                        } label: {
                            Image(systemName: "waveform")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                        }
                        .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))

                        // Compose message directly invokes watch keyboard / dictation
                        TextFieldLink(prompt: Text("Message...")) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                        } onSubmit: { text in
                            Task {
                                await viewModel.sendMessage(text: text)
                            }
                        }
                        .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))
                    }
                }
            }
            .task {
                await viewModel.loadMessages()
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.messages.last?.id) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: selectedPhotoItem) { newItem in
                guard let newItem else { return }
                selectedPhotoItem = nil
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        if let uiImage = UIImage(data: data),
                           let compressed = uiImage.jpegData(compressionQuality: 0.75) {
                            await viewModel.sendPhotoMessage(imageData: compressed, filename: "photo.jpg")
                        } else {
                            await viewModel.sendPhotoMessage(imageData: data, filename: "photo.jpg")
                        }
                    }
                }
            }
            .sheet(isPresented: $showQuickReplySheet) {
                QuickReplyView { selected in
                    Task {
                        await viewModel.sendQuickReply(selected)
                    }
                }
            }
            .sheet(isPresented: $showVoiceMessageSheet) {
                VoiceMessageRecorderView { audioData, durationSecs in
                    Task {
                        await viewModel.sendVoiceMessage(audioData: audioData, durationSecs: durationSecs)
                    }
                }
            }
            .onDisappear {
                viewModel.stopPolling()
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("bottom_anchor", anchor: .bottom)
        }
    }
}
