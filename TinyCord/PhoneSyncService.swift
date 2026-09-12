//
//  PhoneSyncService.swift
//  TinyCord
//

import Foundation
import WatchConnectivity
import Combine

public final class PhoneSyncService: NSObject, ObservableObject, WCSessionDelegate, @unchecked Sendable {
    public static let shared = PhoneSyncService()

    @Published public private(set) var isPaired: Bool = false
    @Published public private(set) var isWatchAppInstalled: Bool = false
    @Published public private(set) var isWatchReachable: Bool = false
    @Published public private(set) var syncStatusMessage: String = "Ready"

    public override init() {
        super.init()
    }

    public func activate() {
        guard WCSession.isSupported() else {
            syncStatusMessage = "WatchConnectivity not supported"
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    public func syncToWatch(
        token: String,
        isBot: Bool,
        apiBaseURL: String,
        cdnBaseURL: String,
        gatewayURL: String,
        endpointProfiles: [EndpointProfile] = [],
        selectedProfileId: String? = nil,
        quickReplies: [String] = []
    ) {
        guard WCSession.isSupported() else {
            syncStatusMessage = "WCSession not supported"
            return
        }

        let session = WCSession.default
        var payload: [String: Any] = [
            "token": token,
            "isBot": isBot,
            "apiBaseURL": apiBaseURL,
            "cdnBaseURL": cdnBaseURL,
            "gatewayURL": gatewayURL
        ]

        if !endpointProfiles.isEmpty, let profilesData = try? JSONEncoder().encode(endpointProfiles) {
            payload["endpointProfilesData"] = profilesData
        }

        if let selectedProfileId, !selectedProfileId.isEmpty {
            payload["selectedProfileId"] = selectedProfileId
        }

        if !quickReplies.isEmpty {
            payload["quickReplies"] = quickReplies
        }

        // Try transferApplicationContext first (persisted even when watch app is suspended)
        do {
            try session.updateApplicationContext(payload)
            syncStatusMessage = "Synced to Watch (Application Context)"
        } catch {
            syncStatusMessage = "Sync error: \(error.localizedDescription)"
        }

        // If watch is active and reachable, send live message
        if session.isReachable {
            session.sendMessage(payload) { _ in
                DispatchQueue.main.async {
                    self.syncStatusMessage = "Synced directly to active Watch!"
                }
            } errorHandler: { error in
                print("[PhoneSync] Live message failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - WCSessionDelegate

    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            self.isWatchReachable = session.isReachable
        }
    }

    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    public func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            self.isWatchReachable = session.isReachable
        }
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isWatchReachable = session.isReachable
        }
    }
}
