//
//  LoginView.swift
//  TinyCord Watch App
//

import SwiftUI

struct LoginView: View {
    @State private var showTokenInput = false
    @State private var enteredToken = ""
    @State private var isBot = false
    @ObservedObject private var themeManager = ThemeManager.shared
    @EnvironmentObject var authStore: AuthStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(themeManager.color)
                        .padding(.top, 4)

                    VStack(spacing: 2) {
                        Text("TinyCord")
                            .font(.headline)
                            .fontWeight(.bold)
                        Text("Discord on your wrist")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 8) {
                        Button {
                            showTokenInput = true
                        } label: {
                            Label("Enter Token", systemImage: "key.fill")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(themeManager.color)

                        NavigationLink(destination: EndpointConfigView()) {
                            Label("Custom Endpoints", systemImage: "network")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)

                    VStack(spacing: 4) {
                        Label("Or sync from iPhone companion app", systemImage: "iphone.and.arrow.forward")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal)
            }
            .navigationTitle {
                Text("TinyCord")
                    .foregroundStyle(themeManager.color)
                    .fontWeight(.semibold)
            }
            .sheet(isPresented: $showTokenInput) {
                ScrollView {
                    VStack(spacing: 10) {
                        Text("Discord Token")
                            .font(.headline)

                        TextField("Paste Token", text: $enteredToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Toggle("Bot Token", isOn: $isBot)
                            .font(.system(size: 12))

                        Button("Log In") {
                            authStore.setCredentials(token: enteredToken, isBot: isBot)
                            showTokenInput = false
                        }
                        .disabled(enteredToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .buttonStyle(.borderedProminent)
                        .tint(themeManager.color)
                    }
                    .padding()
                }
            }
        }
    }
}
