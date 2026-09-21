//
//  WatchSyncService.swift
//  TinyCord Watch App
//

import Foundation
import WatchConnectivity
import Combine

public final class WatchSyncService: NSObject, ObservableObject, WCSessionDelegate, @unchecked Sendable {
    public static let shared = WatchSyncService()

    @Published public private(set) var lastSyncDate: Date?
    @Published public private(set) var syncStatusMessage: String = "Ready"

    private let authStore: AuthStore
    private let endpointConfig: EndpointConfig

    public init(authStore: AuthStore = .shared, endpointConfig: EndpointConfig = .shared) {
        self.authStore = authStore
        self.endpointConfig = endpointConfig
        super.init()
    }

    public func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - WCSessionDelegate

    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            print("[WatchSync] Activation failed: \(error.localizedDescription)")
        } else {
            print("[WatchSync] Activated with state: \(activationState.rawValue)")
        }
    }

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            self.applyContext(applicationContext)
        }
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        DispatchQueue.main.async {
            self.applyContext(userInfo)
        }
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async {
            self.applyContext(message)
            replyHandler(["status": "success"])
        }
    }

    private func applyContext(_ dict: [String: Any]) {
        let previousSession = authStore.sessionID
        let previousConfiguration = [endpointConfig.apiBaseURL, endpointConfig.cdnBaseURL, endpointConfig.gatewayURL]
        var profileReconnected = false
        if let token = dict["token"] as? String, !token.isEmpty {
            let isBot = dict["isBot"] as? Bool ?? false
            let known = authStore.accounts.contains { $0.token == token.trimmingCharacters(in: .whitespacesAndNewlines) && $0.isBot == isBot }
            authStore.setCredentials(token: token, isBot: isBot, activate: !known)
        }

        if let profilesData = dict["endpointProfilesData"] as? Data,
           let profiles = try? JSONDecoder().decode([EndpointProfile].self, from: profilesData) {
            let selectedId = dict["selectedProfileId"] as? String
            if profiles != endpointConfig.profiles || (selectedId != nil && selectedId != endpointConfig.selectedProfileId) {
                endpointConfig.updateProfiles(profiles, selectedId: selectedId)
                profileReconnected = true
            }
        } else {
            if let apiBase = dict["apiBaseURL"] as? String, !apiBase.isEmpty {
                endpointConfig.apiBaseURL = apiBase
            }

            if let cdnBase = dict["cdnBaseURL"] as? String, !cdnBase.isEmpty {
                endpointConfig.cdnBaseURL = cdnBase
            }

            if let gw = dict["gatewayURL"] as? String, !gw.isEmpty {
                endpointConfig.gatewayURL = gw
            }
        }

        if let replies = dict["quickReplies"] as? [String], !replies.isEmpty {
            AppSettings.shared.quickReplies = replies
        }

        self.lastSyncDate = Date()
        self.syncStatusMessage = "Synced from iPhone"

        // Reconcile Companion with the freshly synced profile and credentials
        if authStore.isAuthenticated, previousSession == authStore.sessionID, !profileReconnected,
           previousConfiguration != [endpointConfig.apiBaseURL, endpointConfig.cdnBaseURL, endpointConfig.gatewayURL] {
            PresenceClient.shared.reconnect(force: true)
        }
    }
}
