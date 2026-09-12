//
//  ContentView.swift
//  TinyCord Watch App
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authStore: AuthStore

    var body: some View {
        if authStore.isAuthenticated {
            ChannelListView()
        } else {
            LoginView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthStore.shared)
        .environmentObject(EndpointConfig.shared)
}
