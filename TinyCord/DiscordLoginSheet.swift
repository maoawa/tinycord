//
//  DiscordLoginSheet.swift
//  TinyCord
//

import SwiftUI

public struct DiscordLoginSheet: View {
    public let onTokenCaptured: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var tokenCaptured = false

    public init(onTokenCaptured: @escaping (String) -> Void) {
        self.onTokenCaptured = onTokenCaptured
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Info Banner
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Log into your Discord account")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Use password, 2FA, or scan QR code. Your token is captured and stored securely only on device.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(UIColor.secondarySystemBackground))

                Divider()

                // Web View
                DiscordLoginWebView(
                    loginURL: URL(string: "https://discord.com/login")!,
                    onTokenCaptured: { token in
                        guard !tokenCaptured else { return }
                        tokenCaptured = true

                        // Haptic feedback
                        UINotificationFeedbackGenerator().notificationOccurred(.success)

                        onTokenCaptured(token)
                        dismiss()
                    },
                    onLoadingChanged: { loading in
                        isLoading = loading
                    }
                )
            }
            .navigationTitle("Discord Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
