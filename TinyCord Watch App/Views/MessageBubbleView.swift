//
//  MessageBubbleView.swift
//  TinyCord Watch App
//

import SwiftUI

struct MessageActionsSheet: View {
    let message: DiscordMessage
    let onReply: (DiscordMessage, String) -> Void
    let onReact: (DiscordMessage, String) -> Void
    var onRetry: ((DiscordMessage) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var showAllReactions = false

    private let presetEmojis = ["👍", "❤️", "😂", "🎉", "🔥", "👀", "🥺", "🚀"]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Retry if message failed to send
                if message.sendStatus == .failed {
                    Button {
                        dismiss()
                        onRetry?(message)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(.red)
                            Text("Retry Send")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.red)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                }

                // Reply Button directly invokes keyboard and sends
                TextFieldLink(prompt: Text("Reply...")) {
                    HStack {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 13))
                        Text("Reply")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                } onSubmit: { text in
                    dismiss()
                    onReply(message, text)
                }
                .buttonStyle(.borderedProminent)
                .tint(themeManager.color)

                // Emojis only - 4 columns, clean tap targets without text
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(presetEmojis, id: \.self) { emoji in
                        Button {
                            dismiss()
                            onReact(message, emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 20))
                                .frame(height: 38)
                                .frame(maxWidth: .infinity)
                                .background(Color.gray.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // More reactions button
                Button {
                    showAllReactions = true
                } label: {
                    HStack {
                        Image(systemName: "face.smiling")
                            .foregroundStyle(.yellow)
                        Text("More Reactions...")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .navigationTitle("Actions")
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
        }
        .sheet(isPresented: $showAllReactions) {
            AllReactionsSheet(message: message) { msg, emoji in
                dismiss()
                onReact(msg, emoji)
            }
        }
    }
}

struct MessageBubbleView: View {
    let message: DiscordMessage
    var channelRecipients: [DiscordUser]? = nil
    let onReply: (DiscordMessage, String) -> Void
    let onReact: (DiscordMessage, String) -> Void
    var onRetry: ((DiscordMessage) -> Void)? = nil

    @EnvironmentObject var authStore: AuthStore
    @ObservedObject var endpointConfig = EndpointConfig.shared
    @ObservedObject var themeManager = ThemeManager.shared
    @State private var showActionsSheet = false

    private var isOutgoing: Bool {
        if message.isOutgoing { return true }
        if let myId = authStore.currentUser?.id {
            return message.author.id == myId
        }
        return false
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            if isOutgoing {
                Spacer(minLength: 20)
                if message.sendStatus == .failed {
                    Button {
                        onRetry?(message)
                    } label: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 3) {
                // Reply reference header
                if let ref = message.referencedMessage?.message {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text("\(ref.author.displayName): \(ref.displaySnippet)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 4)
                }

                // Main bubble container
                VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
                    // Author header (only for incoming messages)
                    if !isOutgoing {
                        HStack(spacing: 5) {
                            // Little profile photo of other party with memory/disk cache
                            if let avatarURL = message.author.avatarURL(cdnBase: endpointConfig.cdnBaseURL, size: 64) {
                                CachedAsyncImage(url: avatarURL) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable().scaledToFill()
                                    default:
                                        Circle().fill(Color.gray.opacity(0.4))
                                    }
                                }
                                .frame(width: 14, height: 14)
                                .clipShape(Circle())
                            }

                            Text(message.author.displayName)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(themeManager.color)

                            if message.author.bot == true {
                                Text("BOT")
                                    .font(.system(size: 8, weight: .black))
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(themeManager.color.opacity(0.8))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }

                            Spacer()

                            Text(message.formattedTime)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 2)
                    }

                    // Text Content: natural leading alignment, hides standalone media URLs, highlights mentions
                    if !message.cleanedTextContent.isEmpty {
                        Text(message.attributedContent(themeColor: themeManager.color, isOutgoing: isOutgoing, currentUserId: authStore.currentUser?.id, channelRecipients: channelRecipients))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Attachments
                    if let attachments = message.attachments, !attachments.isEmpty {
                        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                            ForEach(attachments) { att in
                                AttachmentView(attachment: att)
                            }
                        }
                    }

                    // Stickers
                    if let stickers = message.stickerItems, !stickers.isEmpty {
                        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                            ForEach(stickers) { sticker in
                                if let stickerURL = sticker.stickerURL(cdnBase: endpointConfig.cdnBaseURL) {
                                    InlineMediaView(url: stickerURL)
                                }
                            }
                        }
                    }

                    // Media Embeds (Tenor, Giphy, Image GIFVs)
                    if let embeds = message.embeds {
                        let mediaEmbeds = embeds.filter(\.isMediaEmbed)
                        if !mediaEmbeds.isEmpty {
                            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                                ForEach(mediaEmbeds.indices, id: \.self) { idx in
                                    if let mediaURL = mediaEmbeds[idx].mediaURL(cdnBase: endpointConfig.cdnBaseURL) {
                                        InlineMediaView(url: mediaURL)
                                    }
                                }
                            }
                        }
                    }

                    // Direct Media URLs (pasted GIFs / photos not in embeds or attachments)
                    let mediaEmbedURLs = Set(message.embeds?.compactMap { $0.url.flatMap { URL(string: $0) } } ?? [])
                    let unhandledMediaURLs = message.directMediaURLs.filter { !mediaEmbedURLs.contains($0) }
                    if !unhandledMediaURLs.isEmpty {
                        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                            ForEach(unhandledMediaURLs, id: \.self) { mediaURL in
                                InlineMediaView(url: mediaURL)
                            }
                        }
                    }

                    // Interactive Web Cards for general links
                    if !message.webCardURLs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(message.webCardURLs, id: \.self) { webURL in
                                let matchingEmbed = message.embeds?.first(where: {
                                    $0.url == webURL.absoluteString || ($0.url != nil && webURL.absoluteString.contains($0.url!))
                                })
                                WebLinkCardView(url: webURL, embed: matchingEmbed)
                            }
                        }
                    }

                    // Non-media embeds not covered by webCardURLs
                    if let embeds = message.embeds {
                        let otherEmbeds = embeds.filter { $0.isWebLinkEmbed && ($0.url == nil || !message.webCardURLs.contains(URL(string: $0.url!)!)) }
                        if !otherEmbeds.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(otherEmbeds.indices, id: \.self) { idx in
                                    let embed = otherEmbeds[idx]
                                    if let uStr = embed.url, let u = URL(string: uStr) {
                                        WebLinkCardView(url: u, embed: embed)
                                    } else if let title = embed.title, !title.isEmpty {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(title)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(themeManager.color)
                                            if let desc = embed.description, !desc.isEmpty {
                                                Text(desc)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(3)
                                            }
                                        }
                                        .padding(6)
                                        .background(Color.white.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }
                        }
                    }

                    // Time for outgoing message (hugs right side without greedy spacer)
                    if isOutgoing {
                        HStack(spacing: 3) {
                            if message.sendStatus == .sending {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 8, height: 8)
                            } else if message.sendStatus == .failed {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.red)
                            }

                            Text(message.formattedTime)
                                .font(.system(size: 8))
                                .foregroundStyle(message.sendStatus == .failed ? .red.opacity(0.9) : .white.opacity(0.75))
                        }
                        .padding(.top, 1)
                    }

                    // Reactions row
                    if let reactions = message.reactions, !reactions.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(reactions.indices, id: \.self) { idx in
                                let reaction = reactions[idx]
                                let emojiText = reaction.emoji.name ?? "👍"
                                HStack(spacing: 2) {
                                    Text(emojiText)
                                        .font(.system(size: 10))
                                    Text("\(reaction.count)")
                                        .font(.system(size: 9))
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(reaction.me ? themeManager.color.opacity(0.4) : Color.gray.opacity(0.25))
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    isOutgoing
                        ? themeManager.color.opacity(message.sendStatus == .sending ? 0.7 : 1.0)
                        : Color(white: 0.18)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if !isOutgoing {
                Spacer(minLength: 20)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            showActionsSheet = true
        }
        .sheet(isPresented: $showActionsSheet) {
            MessageActionsSheet(
                message: message,
                onReply: onReply,
                onReact: onReact,
                onRetry: onRetry
            )
        }
    }
}

public struct InlineMediaView: View {
    let url: URL
    @State private var isFullScreen = false

    public init(url: URL) {
        self.url = url
    }

    public var body: some View {
        Button {
            isFullScreen = true
        } label: {
            CachedGIFImageView(
                url: url,
                targetSize: CGSize(width: 135, height: 110),
                contentMode: .fill,
                cornerRadius: 8
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isFullScreen) {
            PhotoDetailView(imageURL: url)
        }
    }
}

