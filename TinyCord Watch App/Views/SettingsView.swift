//
//  SettingsView.swift
//  TinyCord Watch App
//

import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var presenceClient = PresenceClient.shared
    @ObservedObject private var syncService = WatchSyncService.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var appSettings = AppSettings.shared
    @ObservedObject private var endpointConfig = EndpointConfig.shared
    @EnvironmentObject var authStore: AuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var showAccounts = false
    @State private var showTokenEditSheet = false
    @State private var cacheFootprint: String = MediaCacheService.shared.formattedDiskCacheSize()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                // User profile card
                if let user = authStore.currentUser {
                    VStack(spacing: 4) {
                        Button { showAccounts = true } label: {
                            if let avatarURL = user.avatarURL(cdnBase: EndpointConfig.shared.cdnBaseURL) {
                                CachedAsyncImage(url: avatarURL) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable().scaledToFill()
                                    default:
                                        Circle().fill(Color.gray.opacity(0.3))
                                    }
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                            }
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottomTrailing) {
                            if authStore.accounts.count > 1 {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(4)
                                    .background(themeManager.color, in: Circle())
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel("Switch account")

                        Text(user.displayName)
                            .font(.system(size: 14, weight: .bold))

                        Text(user.handle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                // TinyCord Companion status
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Circle()
                            .fill(presenceStatusColor)
                            .frame(width: 8, height: 8)
                        Text(presenceStatusText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if presenceClient.state != .connected && EndpointConfig.shared.presenceEnabled {
                            Button("Retry") {
                                presenceClient.reconnect(force: true)
                            }
                            .font(.system(size: 9))
                            .buttonStyle(.borderless)
                            .foregroundStyle(themeManager.themeActionButtons ? themeManager.color : .secondary)
                        }
                    }

                    if EndpointConfig.shared.presenceEnabled {
                        if presenceClient.state != .connected {
                            HStack(spacing: 3) {
                                Text("Phase:")
                                    .foregroundStyle(.secondary.opacity(0.6))
                                Text(presenceClient.connectionPhase)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(.system(size: 8))
                        }
                    }

                    if let error = presenceClient.lastError, presenceClient.state != .connected && EndpointConfig.shared.presenceEnabled {
                        Text(error)
                            .font(.system(size: 8))
                            .foregroundStyle(.red.opacity(0.85))
                            .lineLimit(3)
                    }
                }
                .padding(.horizontal, 4)

                // Theme
                NavigationLink(destination: ThemePickerView()) {
                    HStack {
                        Image(systemName: "paintpalette")
                        Text("Theme")
                            .font(.system(size: 12))
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(themeManager.color)
                                .frame(width: 8, height: 8)
                            Text(themeManager.currentTheme.displayName)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.bordered)
                .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))

                // Subtitle Display Setting: Choices like custom endpoints
                NavigationLink(destination: SubtitleConfigView()) {
                    HStack {
                        Image(systemName: "text.bubble")
                        Text("Subtitle")
                            .font(.system(size: 12))
                        Spacer()
                        Text(appSettings.subtitleMode.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.bordered)
                .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))

                // Navigation to Endpoints
                NavigationLink(destination: EndpointConfigView()) {
                    HStack {
                        Image(systemName: "network")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Custom Endpoints")
                                .font(.system(size: 12))
                            Text(endpointConfig.activeProfile.name)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.white)
                }
                .buttonStyle(.bordered)
                .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))

                // Test Connection Button
                Button {
                    Task {
                        await viewModel.testConnection()
                    }
                } label: {
                    HStack {
                        if viewModel.isTesting {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                        Text("Test Connection")
                            .font(.system(size: 12))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.white)
                }
                .buttonStyle(.bordered)
                .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))

                if let msg = viewModel.testResultMessage {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(viewModel.isTestSuccessful ? .green : .red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Button { showAccounts = true } label: {
                    Label("Accounts (\(authStore.accounts.count))", systemImage: "person.2")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                // Edit Token
                Button {
                    viewModel.loadCurrentValues()
                    showTokenEditSheet = true
                } label: {
                    HStack {
                        Image(systemName: "key.fill")
                        Text("Update Token")
                            .font(.system(size: 12))
                        Spacer()
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.bordered)
                .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))

                // Media Cache & Cleanup
                Button {
                    MediaCacheService.shared.clearCache()
                    cacheFootprint = MediaCacheService.shared.formattedDiskCacheSize()
                } label: {
                    HStack {
                        Image(systemName: "photo.stack")
                        Text("Media Cache")
                            .font(.system(size: 12))
                        Spacer()
                        Text(cacheFootprint)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.bordered)
                .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))

                // iPhone Sync info
                HStack(spacing: 4) {
                    Image(systemName: "iphone")
                        .font(.system(size: 10))
                    Text(syncService.syncStatusMessage)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)

                Divider()

                // Logout
                Button(role: .destructive) {
                    viewModel.logout()
                } label: {
                    Text("Log Out")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding()
        }
        .navigationTitle {
            Text("Settings")
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
        .sheet(isPresented: $showAccounts) {
            NavigationStack { AccountPickerView() }
        }
        .sheet(isPresented: $showTokenEditSheet) {
            ScrollView {
                VStack(spacing: 10) {
                    Text("Discord Token")
                        .font(.headline)

                    SecureField("Token", text: $viewModel.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Toggle("Bot Token", isOn: $viewModel.isBot)
                        .font(.system(size: 11))

                    Button("Save") {
                        viewModel.saveSettings()
                        showTokenEditSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(themeManager.color)
                }
                .padding()
            }
        }
    }

    private var presenceStatusText: String {
        if !EndpointConfig.shared.presenceEnabled {
            return "Updates: REST polling"
        }
        switch presenceClient.state {
        case .connected:
            return "Active on Apple Watch"
        case .connecting:
            return "Connecting to Companion"
        case .reconnecting:
            return "Reconnecting to Companion"
        case .disconnected:
            return "Companion disconnected"
        }
    }

    private var presenceStatusColor: Color {
        if !EndpointConfig.shared.presenceEnabled {
            return .gray
        }
        switch presenceClient.state {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .disconnected:
            return .gray
        }
    }
}
