//
//  AllReactionsSheet.swift
//  TinyCord Watch App
//

import SwiftUI

struct AllReactionsSheet: View {
    let message: DiscordMessage
    let onReact: (DiscordMessage, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeManager = ThemeManager.shared

    private struct Category: Identifiable {
        let id = UUID()
        let name: String
        let emojis: [String]
    }

    private let categories: [Category] = [
        Category(name: "Popular", emojis: [
            "👍", "👎", "❤️", "🔥", "😂", "🎉", "👀", "🥺",
            "🚀", "💯", "🙏", "✨", "💀", "😭", "😍", "🥳"
        ]),
        Category(name: "Smileys", emojis: [
            "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂",
            "🙂", "🙃", "😉", "😊", "😇", "🥰", "😍", "🤩",
            "😘", "😗", "😋", "😛", "😜", "🤪", "😝", "🤑",
            "🤗", "🤭", "🤫", "🤔", "🤐", "🤨", "😐", "😑",
            "😶", "😏", "😒", "🙄", "😬", "🤥", "😌", "😔",
            "😪", "🤤", "😴", "😷", "🤒", "🤕", "🤢", "🤮",
            "🤧", "🥵", "🥶", "🥴", "😵", "🤯", "🤠", "🥳",
            "😎", "🤓", "🧐", "😕", "😟", "🙁", "😮", "😯",
            "😲", "😳", "🥺", "😦", "😧", "😨", "😰", "😥",
            "😢", "😭", "😱", "😖", "😣", "😞", "😓", "😩",
            "😫", "🥱", "😤", "😡", "😠", "🤬", "💀", "💩",
            "🤡", "👻", "👽", "🤖", "🎃"
        ]),
        Category(name: "Gestures", emojis: [
            "👍", "👎", "👊", "✊", "🤛", "🤜", "🤞", "✌️",
            "🤟", "🤘", "👌", "🤏", "👈", "👉", "👆", "👇",
            "☝️", "✋", "🤚", "🖐", "🖖", "👋", "🤙", "💪",
            "🦾", "✍️", "🙏", "🦶", "🦵", "👂", "👃", "🧠",
            "👀", "👁", "👅", "👄"
        ]),
        Category(name: "Hearts", emojis: [
            "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍",
            "🤎", "💔", "❣️", "💕", "💞", "💓", "💗", "💖",
            "💘", "💝", "💟"
        ]),
        Category(name: "Fun & Symbols", emojis: [
            "🔥", "✨", "🌟", "💫", "💥", "💢", "💦", "💧",
            "💤", "💨", "🎉", "🎊", "🎈", "🎂", "🎁", "🏆",
            "🥇", "🥈", "🥉", "🎯", "🎮", "🕹", "🎲", "🎳",
            "🎨", "🎤", "🎧", "🎬", "🚀", "🛸", "🚨", "⚠️",
            "✅", "❌", "💯", "💎", "💡", "💰", "☕️", "🍕",
            "🍔", "🍟", "🍻", "🥂", "🍿"
        ])
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(categories) { category in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 34))], spacing: 4) {
                            ForEach(category.emojis, id: \.self) { emoji in
                                Button {
                                    dismiss()
                                    onReact(message, emoji)
                                } label: {
                                    Text(emoji)
                                        .font(.system(size: 20))
                                        .frame(width: 34, height: 34)
                                }
                                .buttonStyle(.borderless)
                                .background(Color.gray.opacity(0.18))
                                .clipShape(Circle())
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .navigationTitle {
            Text("Reactions")
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
