//
//  SettingsView.swift
//  TinyCord Watch App
//

import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var gatewayClient = DiscordGatewayClient.shared
    @ObservedObject private var syncService = WatchSyncService.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var appSettings = AppSettings.shared
    @ObservedObject private var endpointConfig = EndpointConfig.shared
    @EnvironmentObject var authStore: AuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var showTokenEditSheet = false
    @State private var cacheFootprint: String = MediaCacheService.shared.formattedDiskCacheSize()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                // User profile card
                if let user = authStore.currentUser {
                    VStack(spacing: 4) {
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

                        Text(user.displayName)
                            .font(.system(size: 14, weight: .bold))

                        Text(user.handle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                // Gateway connection status
                HStack {
                    Circle()
                        .fill(gatewayStatusColor)
                        .frame(width: 8, height: 8)
                    Text(gatewayStatusText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if gatewayClient.state == .disconnected && EndpointConfig.shared.enableGateway {
                        Button("Retry") {
                            gatewayClient.connect()
                        }
                        .font(.system(size: 9))
                        .buttonStyle(.borderless)
                        .foregroundStyle(themeManager.themeActionButtons ? themeManager.color : .secondary)
                    }
                }
                .padding(.horizontal, 4)

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

                Divider()

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
                        Text("Custom Endpoints")
                            .font(.system(size: 12))
                        Spacer()
                        Text(endpointConfig.activeProfile.name)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.bordered)
                .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))

                // Edit Token
                Button {
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
        .sheet(isPresented: $showTokenEditSheet) {
            ScrollView {
                VStack(spacing: 10) {
                    Text("Discord Token")
                        .font(.headline)

                    TextField("Token", text: $viewModel.token)
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

    private var gatewayStatusText: String {
        if !EndpointConfig.shared.enableGateway {
            return "Real-Time: Off (REST)"
        }
        switch gatewayClient.state {
        case .connected:
            return "Real-Time: Connected"
        case .connecting:
            return "Real-Time: Connecting..."
        case .reconnecting:
            return "Real-Time: Reconnecting..."
        case .disconnected:
            if let error = gatewayClient.lastError {
                return "Real-Time: \(error)"
            }
            return "Real-Time: Polling Mode"
        }
    }

    private var gatewayStatusColor: Color {
        if !EndpointConfig.shared.enableGateway {
            return .gray
        }
        switch gatewayClient.state {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .disconnected:
            return .gray
        }
    }
}
