//
//  SubtitleConfigView.swift
//  TinyCord Watch App
//

import SwiftUI

struct SubtitleConfigView: View {
    @ObservedObject private var appSettings = AppSettings.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Subtitle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    appSettings.subtitleMode = .latestMessage
                } label: {
                    HStack {
                        Image(systemName: "message.fill")
                        Text("Latest Message")
                            .font(.system(size: 12))
                        Spacer()
                        if appSettings.subtitleMode == .latestMessage {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(themeManager.color)
                        }
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.bordered)
                .tint(themeManager.themeActionButtons && appSettings.subtitleMode == .latestMessage ? themeManager.color : Color(white: 0.25))

                Button {
                    appSettings.subtitleMode = .username
                } label: {
                    HStack {
                        Image(systemName: "at")
                        Text("@username")
                            .font(.system(size: 12))
                        Spacer()
                        if appSettings.subtitleMode == .username {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(themeManager.color)
                        }
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.bordered)
                .tint(themeManager.themeActionButtons && appSettings.subtitleMode == .username ? themeManager.color : Color(white: 0.25))

                Divider()
                    .padding(.vertical, 4)

                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("Unread conversations will always display the latest message so you never miss what was said.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
            .padding()
        }
        .navigationTitle {
            Text("Subtitle")
                .foregroundStyle(themeManager.color)
                .fontWeight(.semibold)
        }
    }
}
