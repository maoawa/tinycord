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

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gateway WebSocket URL")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text(endpointConfig.gatewayURL)
                            .font(.system(size: 9))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Toggle("Real-Time Push (Gateway)", isOn: $endpointConfig.enableGateway)
                        .font(.system(size: 11))
                    Text("Instant WebSocket push vs. REST polling")
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
    }
}
