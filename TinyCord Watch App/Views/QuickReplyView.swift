//
//  QuickReplyView.swift
//  TinyCord Watch App
//

import SwiftUI

struct QuickReplyView: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var appSettings = AppSettings.shared

    private let emojis = ["👍", "❤️", "😂", "🎉", "🔥", "👀", "🥺", "🚀", "💯", "🙏"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Reactions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 36))], spacing: 6) {
                    ForEach(emojis, id: \.self) { emoji in
                        Button {
                            onSelect(emoji)
                            dismiss()
                        } label: {
                            Text(emoji)
                                .font(.system(size: 22))
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.borderless)
                        .background(Color.gray.opacity(0.2))
                        .clipShape(Circle())
                    }
                }
                .padding(.horizontal)

                Divider()
                    .padding(.vertical, 4)

                Text("Quick Messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                ForEach(Array(appSettings.quickReplies.enumerated()), id: \.offset) { _, phrase in
                    Button {
                        onSelect(phrase)
                        dismiss()
                    } label: {
                        HStack {
                            Text(phrase)
                                .font(.system(size: 13))
                            Spacer()
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(themeManager.color)
                                .font(.system(size: 14))
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical, 6)
        }
        .navigationTitle {
            Text("Quick Reply")
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
        }
    }
}
