//
//  SettingsViewModel.swift
//  TinyCord Watch App
//

import Foundation
import SwiftUI
import Combine

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var token: String = ""
    @Published public var isBot: Bool = false
    @Published public var apiBaseURL: String = ""
    @Published public var cdnBaseURL: String = ""
    @Published public var gatewayURL: String = ""
    @Published public var baseHostInput: String = ""
    @Published public var enableGateway: Bool = true

    @Published public var isTesting: Bool = false
    @Published public var testResultMessage: String?
    @Published public var isTestSuccessful: Bool = false

    private let authStore: AuthStore
    private let endpointConfig: EndpointConfig
    private let apiClient: DiscordAPIClient

    public init(
        authStore: AuthStore = .shared,
        endpointConfig: EndpointConfig = .shared,
        apiClient: DiscordAPIClient = .shared
    ) {
        self.authStore = authStore
        self.endpointConfig = endpointConfig
        self.apiClient = apiClient

        loadCurrentValues()
    }

    public func loadCurrentValues() {
        self.token = authStore.token ?? ""
        self.isBot = authStore.isBotToken
        self.apiBaseURL = endpointConfig.apiBaseURL
        self.cdnBaseURL = endpointConfig.cdnBaseURL
        self.gatewayURL = endpointConfig.gatewayURL
        self.enableGateway = endpointConfig.enableGateway
    }

    public func saveSettings() {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanToken.isEmpty {
            authStore.setCredentials(token: cleanToken, isBot: isBot)
        }

        endpointConfig.apiBaseURL = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        endpointConfig.cdnBaseURL = cdnBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        endpointConfig.gatewayURL = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        endpointConfig.enableGateway = enableGateway

        if enableGateway && authStore.isAuthenticated {
            // Force a fresh socket so new endpoints/credentials take effect
            DiscordGatewayClient.shared.reconnect(force: true)
        } else {
            DiscordGatewayClient.shared.disconnect()
        }
    }

    public func applyBaseHost() {
        let trimmed = baseHostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        endpointConfig.applyBaseHost(trimmed)
        self.apiBaseURL = endpointConfig.apiBaseURL
        self.cdnBaseURL = endpointConfig.cdnBaseURL
        self.gatewayURL = endpointConfig.gatewayURL
    }

    public func resetToOfficialDiscord() {
        endpointConfig.resetToOfficial()
        self.apiBaseURL = endpointConfig.apiBaseURL
        self.cdnBaseURL = endpointConfig.cdnBaseURL
        self.gatewayURL = endpointConfig.gatewayURL
    }

    public func testConnection() async {
        isTesting = true
        testResultMessage = nil
        isTestSuccessful = false

        // Temporarily apply current inputs to verify
        saveSettings()

        guard authStore.isAuthenticated else {
            isTesting = false
            isTestSuccessful = false
            testResultMessage = "Please enter a token first."
            return
        }

        do {
            let user = try await apiClient.getCurrentUser()
            self.isTesting = false
            self.isTestSuccessful = true
            self.testResultMessage = "Connected as \(user.displayName) (\(user.handle))"
        } catch {
            self.isTesting = false
            self.isTestSuccessful = false
            self.testResultMessage = error.localizedDescription
        }
    }

    public func logout() {
        authStore.logout()
        DiscordGatewayClient.shared.disconnect()
        self.token = ""
        self.testResultMessage = nil
    }
}
