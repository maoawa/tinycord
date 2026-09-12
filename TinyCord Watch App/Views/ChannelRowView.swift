//
//  ChannelRowView.swift
//  TinyCord Watch App
//

import SwiftUI

struct ChannelRowView: View {
    let channel: DiscordChannel
    let currentUserId: String?
    var isTyping: Bool = false
    @ObservedObject var endpointConfig = EndpointConfig.shared
    @ObservedObject var themeManager = ThemeManager.shared
    @ObservedObject var appSettings = AppSettings.shared

    var body: some View {
        HStack(spacing: 8) {
            // Avatar / Icon
            ZStack {
                if let avatarURL = channel.avatarURL(cdnBase: endpointConfig.cdnBaseURL) {
                    CachedAsyncImage(url: avatarURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        default:
                            avatarFallback
                        }
                    }
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())
                } else {
                    avatarFallback
                }

                // Group indicator badge
                if channel.isGroup {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 8))
                        .padding(2)
                        .background(Color.black.opacity(0.8))
                        .clipShape(Circle())
                        .offset(x: 10, y: 10)
                }
            }
            .frame(width: 34, height: 34)

            // Titles & Snippet
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(channel.displayName(currentUserId: currentUserId))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    Spacer()

                    if let time = channel.lastMessageTime {
                        Text(formatShortDate(time))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    if isTyping {
                        Text("typing...")
                            .font(.system(size: 11))
                            .foregroundStyle(themeManager.color)
                            .lineLimit(1)
                    } else if channel.hasUnread, let snippet = channel.displaySnippet(currentUserId: currentUserId), !snippet.isEmpty {
                        // Unread conversation always displays the latest message
                        Text(snippet)
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    } else if appSettings.showLatestMessage, let snippet = channel.displaySnippet(currentUserId: currentUserId), !snippet.isEmpty {
                        Text(snippet)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(channel.displaySubtitle(currentUserId: currentUserId))
                            .font(.system(size: 10))
                            .foregroundStyle(channel.hasUnread ? .white : .secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if channel.hasUnread {
                        Circle()
                            .fill(themeManager.color)
                            .frame(width: 7, height: 7)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var avatarFallback: some View {
        Circle()
            .fill(channel.isGroup ? themeManager.color.opacity(0.8) : Color.gray.opacity(0.5))
            .frame(width: 34, height: 34)
            .overlay {
                if channel.isGroup {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                } else {
                    let firstLetter = channel.displayName(currentUserId: currentUserId).prefix(1).uppercased()
                    Text(firstLetter.isEmpty ? "?" : String(firstLetter))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }

    private func formatShortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d"
            return formatter.string(from: date)
        }
    }
}
