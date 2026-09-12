//
//  TinyCordApp.swift
//  TinyCord Watch App
//

import SwiftUI

@main
struct TinyCord_Watch_AppApp: App {
    @StateObject private var authStore = AuthStore.shared
    @StateObject private var endpointConfig = EndpointConfig.shared
    @StateObject private var themeManager = ThemeManager.shared

    init() {
        WatchSyncService.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(themeManager.color)
                .environmentObject(authStore)
                .environmentObject(endpointConfig)
                .environmentObject(themeManager)
        }
    }
}
