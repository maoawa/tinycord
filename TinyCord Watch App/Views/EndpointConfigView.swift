//
//  EndpointConfigView.swift
//  TinyCord Watch App
//

import SwiftUI
import WatchKit

struct EndpointConfigView: View {
    @ObservedObject private var endpointConfig = EndpointConfig.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showHostSheet = false
    @State private var inputHost: String = ""
    @State private var presenceEnabled = false
    @State private var presenceServerURL = ""
    @State private var editingPresence = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Profile Switcher Section
                VStack(spacing: 6) {
                    Text("Endpoint Profiles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(endpointConfig.profiles) { profile in
                        Button {
                            endpointConfig.selectProfile(id: profile.id)
                            WKInterfaceDevice.current().play(.click)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Image(systemName: profile.isOfficial ? "globe" : "server.rack")
                                            .font(.system(size: 10))
                                            .foregroundStyle(profile.id == endpointConfig.selectedProfileId ? themeManager.color : .secondary)

                                        Text(profile.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(1)
                                    }

                                    Text(profile.hostDisplay)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if profile.id == endpointConfig.selectedProfileId {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(themeManager.color)
                                }
                            }
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.bordered)
                        .tint(profile.id == endpointConfig.selectedProfileId ? (themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25)) : Color(white: 0.15))
                    }

                    Button {
                        inputHost = endpointConfig.activeProfile.hostDisplay
                        presenceEnabled = false
                        presenceServerURL = ""
                        editingPresence = false
                        showHostSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 10))
                            Text("Set Custom Host...")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.bordered)
                    .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))
                }

                Divider()

                // Active Profile Details
                VStack(spacing: 8) {
                    Text("Active Configuration")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("API Base URL")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text(endpointConfig.apiBaseURL)
                            .font(.system(size: 9))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("CDN Base URL")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text(endpointConfig.cdnBaseURL)
                            .font(.system(size: 9))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(endpointConfig.presenceEnabled ? "TinyCord Companion: \(endpointConfig.presenceHostDisplay)" : "Updates via REST polling")
                        .font(.system(size: 9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !endpointConfig.activeProfile.isOfficial {
                        Button("Configure Companion") {
                            inputHost = endpointConfig.activeProfile.hostDisplay
                            presenceEnabled = endpointConfig.activeProfile.presenceEnabled
                            presenceServerURL = endpointConfig.activeProfile.presenceServerURL
                            editingPresence = true
                            showHostSheet = true
                        }
                        .font(.system(size: 11))
                    }
                    Text("Companion shows your presence while TinyCord is active.")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("Add and manage custom endpoint profiles in TinyCord on your iPhone.")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }
            .padding()
        }
        .navigationTitle {
            Text("Endpoints")
                .foregroundStyle(themeManager.color)
                .fontWeight(.semibold)
        }
        .sheet(isPresented: $showHostSheet) {
            ScrollView {
                VStack(spacing: 10) {
                    Text(editingPresence ? "TinyCord Companion" : "Set Custom Host")
                        .font(.headline)

                    if !editingPresence {
                        Text("Enter base domain, e.g. proxy.example.com")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        TextField("Domain", text: $inputHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Toggle("Use Companion", isOn: $presenceEnabled)
                    if presenceEnabled {
                        TextField("https://companion.example.com", text: $presenceServerURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Auto-fill") {
                            autoFillCompanion()
                        }
                        .font(.system(size: 11))
                        Text("Use a server you trust. It receives your token briefly to connect, then discards it.")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        if !presenceServerURL.isEmpty && EndpointProfile.validatedPresenceURL(presenceServerURL) == nil {
                            Text("An HTTPS address without a path or query is required.")
                                .font(.system(size: 9))
                                .foregroundStyle(.red)
                        }
                    }

                    Button(editingPresence ? "Save" : "Save & Switch") {
                        let trimmed = inputHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        if editingPresence {
                            endpointConfig.updatePresence(enabled: presenceEnabled, address: presenceServerURL)
                        } else if !trimmed.isEmpty {
                            endpointConfig.applyBaseHost(trimmed, presenceEnabled: presenceEnabled, presenceServerURL: presenceServerURL)
                        }
                        showHostSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(themeManager.color)
                    .disabled((!editingPresence && inputHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                              || (presenceEnabled && EndpointProfile.validatedPresenceURL(presenceServerURL) == nil))
                }
                .padding()
            }
        }
    }

    private func autoFillCompanion() {
        let input = inputHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = input.contains("://") ? input : "https://\(input)"
        guard let url = URL(string: address), var host = url.host, !host.isEmpty else { return }
        for prefix in ["companion.", "gateway.", "cdn.", "api."] where host.lowercased().hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
            break
        }
        presenceServerURL = "https://companion.\(host)"
    }
}
