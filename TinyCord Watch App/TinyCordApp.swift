//
//  TinyCordApp.swift
//  TinyCord Watch App
//

import SwiftUI

@main
struct TinyCord_Watch_AppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var authStore = AuthStore.shared
    @StateObject private var endpointConfig = EndpointConfig.shared
    @StateObject private var themeManager = ThemeManager.shared

    init() {
        WatchSyncService.shared.activate()
        // Register the CallKit provider at launch. This creates no call or
        // network socket; transports still wait for CallKit audio activation.
        _ = VoiceCallController.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(themeManager.color)
                .environmentObject(authStore)
                .environmentObject(endpointConfig)
                .environmentObject(themeManager)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: PresenceClient.shared.setActive(true)
                    case .background: PresenceClient.shared.setActive(false)
                    case .inactive: break // Wrist-down/dimmed foreground is not leaving the app.
                    @unknown default: break
                    }
                }
                .onChange(of: authStore.isAuthenticated) { _, authenticated in
                    if authenticated { PresenceClient.shared.connect() }
                    else { PresenceClient.shared.disconnect() }
                }
        }
    }
}
