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
    }

    public func saveSettings() {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanToken.isEmpty {
            authStore.setCredentials(token: cleanToken, isBot: isBot)
        }

        if endpointConfig.presenceEnabled && authStore.isAuthenticated {
            PresenceClient.shared.reconnect(force: true)
        } else if !endpointConfig.presenceEnabled {
            PresenceClient.shared.disconnect()
        }
    }

    public func testConnection() async {
        isTesting = true
        testResultMessage = nil
        isTestSuccessful = false

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
            self.testResultMessage = "REST connected as \(user.displayName) (\(user.handle))"

            if endpointConfig.presenceEnabled {
                PresenceClient.shared.reconnect(force: true)
            }
        } catch {
            self.isTesting = false
            self.isTestSuccessful = false
            self.testResultMessage = error.localizedDescription
        }
    }

    public func logout() {
        authStore.logout()
        PresenceClient.shared.disconnect()
        self.token = ""
        self.testResultMessage = nil
    }
}
