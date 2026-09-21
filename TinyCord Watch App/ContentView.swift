//
//  ContentView.swift
//  TinyCord Watch App
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authStore: AuthStore
    @EnvironmentObject var endpointConfig: EndpointConfig
    @ObservedObject private var call = VoiceCallController.shared

    var body: some View {
        Group {
            if authStore.isAuthenticated {
                ChannelListView()
                    .id("\(authStore.sessionID):\(endpointConfig.apiBaseURL)")
            } else {
                LoginView()
            }
        }
        .alert("Saved Accounts", isPresented: Binding(
            get: { authStore.storageError != nil }, set: { if !$0 { authStore.storageError = nil } }
        )) {
            Button("OK", role: .cancel) { authStore.storageError = nil }
        } message: {
            Text(authStore.storageError ?? "")
        }
        .alert("Call failed", isPresented: Binding(get: { call.error != nil }, set: { if !$0 { call.dismissError() } })) {
            Button("OK") { call.dismissError() }
        } message: {
            Text(call.error ?? "")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthStore.shared)
        .environmentObject(EndpointConfig.shared)
}
