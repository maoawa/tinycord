//
//  ChatView.swift
//  TinyCord Watch App
//

import SwiftUI
import PhotosUI

struct ChatView: View {
    @StateObject var viewModel: ChatViewModel
    @StateObject private var mediaLoader = ChatMediaLoader()
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var showQuickReplySheet = false
    @State private var showVoiceMessageSheet = false
    @State private var showCallConfirmation = false
    @State private var showCallActions = false
    @ObservedObject private var voiceCall = VoiceCallController.shared
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @EnvironmentObject var authStore: AuthStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    private let onMessagesDisplayed: (String) -> Void

    init(channel: DiscordChannel, onMessagesDisplayed: @escaping (String) -> Void = { _ in }) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(channel: channel))
        self.onMessagesDisplayed = onMessagesDisplayed
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
                                .frame(width: 12, height: 12)
                            Text("\(viewModel.typingUserNames.joined(separator: ", ")) typing...")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }

                    // Bottom anchor for auto-scrolling
                    Color.clear
                        .frame(height: 1)
                        .id("bottom_anchor")
                        .background {
                            if !viewModel.messages.isEmpty && !viewModel.isLoading {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: ChatMediaLayoutKey.self,
                                        value: ChatMediaLayout(bottom: geometry.frame(in: .global)))
                                }
                            }
                        }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 60)
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ChatMediaLayoutKey.self,
                        value: ChatMediaLayout(viewport: geometry.frame(in: .global)))
                }
            }
            .defaultScrollAnchor(.bottom)
            .onPreferenceChange(ChatMediaLayoutKey.self) { layout in
                mediaLoader.update(layout)
            }
            .environment(\.chatMediaLoader, mediaLoader)
            .navigationBarBackButtonHidden(true)
            .navigationTitle {
                Text(viewModel.channel.displayName(currentUserId: authStore.currentUser?.id))
                    .foregroundStyle(themeManager.color)
                    .fontWeight(.semibold)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.channel.isDM && !authStore.isBotToken {
                        Button {
                            if voiceCall.active { showCallActions = true }
                            else { showCallConfirmation = true }
                        } label: {
                            Image(systemName: voiceCall.active ? "phone.fill" : "phone")
                                .foregroundStyle(.white)
                        }
                        .tint(themeManager.actionButtonColor)
                        .accessibilityLabel(voiceCall.active ? "Call controls" : "Voice call")
                    }
                }
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
                        .disabled(voiceCall.active)

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
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
                acknowledgeDisplayedMessages()
            }
            .onAppear {
                isVisible = true
                acknowledgeDisplayedMessages()
            }
            .onChange(of: viewModel.readCursorMessageID) { _, _ in acknowledgeDisplayedMessages() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { acknowledgeDisplayedMessages() }
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
            .alert("Call \(viewModel.channel.displayName(currentUserId: authStore.currentUser?.id))?", isPresented: $showCallConfirmation) {
                Button("Call") { voiceCall.start(viewModel.channel) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Start a voice call?")
            }
            .confirmationDialog("Call with \(voiceCall.name)", isPresented: $showCallActions, titleVisibility: .visible) {
                Button(voiceCall.muted ? "Unmute" : "Mute", action: voiceCall.toggleMute)
                Button("End Call", role: .destructive, action: voiceCall.end)
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showVoiceMessageSheet) {
                VoiceMessageRecorderView { audioData, durationSecs in
                    Task {
                        await viewModel.sendVoiceMessage(audioData: audioData, durationSecs: durationSecs)
                    }
                }
            }
            .onDisappear {
                isVisible = false
                viewModel.stopPolling()
            }
        }
        .modifier(MessageLinkBrowserModifier())
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("bottom_anchor", anchor: .bottom)
        }
    }

    private func acknowledgeDisplayedMessages() {
        guard isVisible, scenePhase == .active, let messageID = viewModel.readCursorMessageID else { return }
        onMessagesDisplayed(messageID)
    }
}
