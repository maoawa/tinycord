//
//  TinyCordApp.swift
//  TinyCord
//

import SwiftUI

@main
struct TinyCordApp: App {
    init() {
        PhoneSyncService.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
