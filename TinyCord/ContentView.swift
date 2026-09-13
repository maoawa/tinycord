//
//  ContentView.swift
//  TinyCord
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var syncService = PhoneSyncService.shared

    @AppStorage("ios_discord_token") private var token: String = ""
    @AppStorage("ios_is_bot") private var isBot: Bool = false
    @AppStorage("ios_api_base") private var apiBaseURL: String = "https://discord.com/api/v10"
    @AppStorage("ios_cdn_base") private var cdnBaseURL: String = "https://cdn.discordapp.com"
    @AppStorage("ios_gateway_url") private var gatewayURL: String = "wss://gateway.discord.gg/?v=10&encoding=json"

    @State private var isTesting: Bool = false
    @State private var testResult: String?
    @State private var testSucceeded: Bool = false
    @State private var showToken: Bool = false
    @State private var showLoginSheet: Bool = false
    @State private var userProfile: DiscordProfile?

    // Custom Endpoint Profiles
    @State private var endpointProfiles: [EndpointProfile] = []
    @State private var selectedProfileId: String = EndpointProfile.official.id
    @State private var profileToEdit: EndpointProfile? = nil
    @State private var showEditorSheet: Bool = false
    @State private var quickReplies: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                // Profile Section
                Section {
                    if let userProfile {
                        HStack(spacing: 12) {
                            if let avatarURL = userProfile.avatarURL(cdnBase: cdnBaseURL) {
                                AsyncImage(url: avatarURL) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable().scaledToFill()
                                    default:
                                        Circle().fill(Color.gray.opacity(0.2))
                                    }
                                }
                                .frame(width: 48, height: 48)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                            } else {
                                Circle()
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 48, height: 48)
                                    .overlay {
                                        Image(systemName: "person.fill")
                                            .font(.system(size: 22))
                                            .foregroundStyle(.secondary)
                                    }
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(userProfile.displayName)
                                        .font(.headline)
                                        .lineLimit(1)

                                    if userProfile.bot == true || isBot {
                                        Text("BOT")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.blue.opacity(0.8))
                                            .foregroundStyle(.white)
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                }

                                Text(userProfile.handle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 7, height: 7)
                                Text("Logged In")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())
                            .fixedSize()
                        }
                        .padding(.vertical, 4)
                    } else {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.gray.opacity(0.15))
                                .frame(width: 48, height: 48)
                                .overlay {
                                    Image(systemName: "person.crop.circle.badge.questionmark")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.secondary)
                                }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Not Connected")
                                    .font(.headline)
                                Text("Log in or enter a token below to connect")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Account Section
                Section(header: Text("Discord Credentials")) {
                    Button {
                        showLoginSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Log in to Discord (Auto-Detect Token)")
                                .fontWeight(.medium)
                        }
                    }

                    HStack {
                        if showToken {
                            TextField("Discord Token", text: $token)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("Discord Token", text: $token)
                        }

                        Button {
                            showToken.toggle()
                        } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            if let paste = UIPasteboard.general.string {
                                token = paste.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                    }

                    Toggle("It's a bot account", isOn: $isBot)
                }

                // Test Connection Section
                Section {
                    Button {
                        Task {
                            await testConnection()
                        }
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .padding(.trailing, 4)
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                            }
                            Text("Test Connection")
                        }
                    }

                    if let testResult {
                        Text(testResult)
                            .font(.body)
                            .foregroundStyle(testSucceeded ? .green : .red)
                    }
                }

                // Apple Watch Settings Section
                Section(header: Text("Apple Watch Settings")) {
                    NavigationLink {
                        QuickRepliesManagerView(
                            quickReplies: $quickReplies,
                            onSave: {
                                saveQuickReplies()
                            }
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 18))
                                .foregroundStyle(Color.blue)
                                .frame(width: 24)

                            Text("Quick Messages")
                                .font(.body)

                            Spacer()

                            Text("\(quickReplies.count)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Custom Endpoints Section
                Section(
                    header: Text("Custom Endpoints"),
                    footer: Text("The selected endpoint profile is used for connection testing. Profiles are synced to your Apple Watch where you can switch between them.")
                ) {
                    ForEach(endpointProfiles) { profile in
                        HStack(spacing: 12) {
                            Image(systemName: profile.isOfficial ? "globe" : "server.rack")
                                .font(.system(size: 18))
                                .foregroundStyle(profile.id == selectedProfileId ? Color.blue : Color.secondary)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(profile.name)
                                        .font(.body)
                                        .fontWeight(profile.id == selectedProfileId ? .semibold : .regular)

                                    if profile.isOfficial {
                                        Text("Default")
                                            .font(.system(size: 10, weight: .bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.15))
                                            .foregroundStyle(.secondary)
                                            .clipShape(Capsule())
                                    }
                                }

                                Text(profile.hostDisplay)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if profile.id == selectedProfileId {
                                Image(systemName: "checkmark")
                                    .fontWeight(.bold)
                                    .foregroundStyle(Color.blue)
                            }

                            if !profile.isOfficial {
                                Button {
                                    profileToEdit = profile
                                    showEditorSheet = true
                                } label: {
                                    Image(systemName: "slider.horizontal.3")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectProfile(profile)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !profile.isOfficial {
                                Button(role: .destructive) {
                                    deleteProfile(profile)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    profileToEdit = profile
                                    showEditorSheet = true
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                    }

                    Button {
                        profileToEdit = nil
                        showEditorSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Endpoint Profile")
                        }
                    }
                }

                // Apple Watch Status Section
                Section(header: Text("Apple Watch")) {
                    HStack {
                        Image(systemName: "applewatch")
                            .font(.title2)
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(syncService.isPaired ? "Apple Watch Paired" : "No Watch Paired")
                                .font(.headline)
                            Text(syncService.syncStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Circle()
                            .fill(syncService.isWatchReachable ? Color.green : Color.orange)
                            .frame(width: 10, height: 10)
                    }
                    .padding(.vertical, 4)

                    Button {
                        syncService.syncToWatch(
                            token: token,
                            isBot: isBot,
                            apiBaseURL: apiBaseURL,
                            cdnBaseURL: cdnBaseURL,
                            gatewayURL: gatewayURL,
                            endpointProfiles: endpointProfiles,
                            selectedProfileId: selectedProfileId,
                            quickReplies: quickReplies
                        )
                    } label: {
                        HStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 15, weight: .bold))
                            Text("Sync to Apple Watch")
                                .fontWeight(.bold)
                            Spacer()
                        }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("TinyCord")
            .onAppear {
                loadProfiles()
                loadQuickReplies()
                loadCachedProfile()
                autoSyncToWatch()
                if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && userProfile == nil {
                    Task { await testConnection() }
                }
            }
            .onChange(of: token) { newToken in
                if newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    userProfile = nil
                    UserDefaults.standard.removeObject(forKey: "ios_cached_user_profile")
                } else {
                    Task { await testConnection() }
                }
                autoSyncToWatch()
            }
            .onChange(of: isBot) { _ in
                autoSyncToWatch()
            }
            .sheet(isPresented: $showLoginSheet) {
                DiscordLoginSheet { capturedToken in
                    token = capturedToken
                    isBot = false
                    Task {
                        await testConnection()
                        autoSyncToWatch()
                    }
                }
            }
            .sheet(isPresented: $showEditorSheet) {
                EndpointProfileEditorSheet(
                    profile: profileToEdit,
                    onSave: { savedProfile in
                        saveProfileFromEditor(savedProfile)
                    },
                    onDelete: { deletedProfile in
                        deleteProfile(deletedProfile)
                    }
                )
            }
        }
    }

    private func loadProfiles() {
        var list: [EndpointProfile] = []
        if let data = UserDefaults.standard.data(forKey: "ios_endpoint_profiles"),
           let decoded = try? JSONDecoder().decode([EndpointProfile].self, from: data) {
            list = decoded
        }

        // Guarantee official profile is always first and unmodified
        list.removeAll { $0.id == EndpointProfile.official.id }
        list.insert(EndpointProfile.official, at: 0)
        self.endpointProfiles = list

        let savedSelected = UserDefaults.standard.string(forKey: "ios_selected_profile_id")
        if let savedSelected, list.contains(where: { $0.id == savedSelected }) {
            self.selectedProfileId = savedSelected
        } else {
            self.selectedProfileId = EndpointProfile.official.id
        }

        let active = list.first(where: { $0.id == self.selectedProfileId }) ?? EndpointProfile.official
        self.apiBaseURL = active.apiBaseURL
        self.cdnBaseURL = active.cdnBaseURL
        self.gatewayURL = active.gatewayURL
    }

    private func saveProfiles() {
        var list = endpointProfiles.filter { $0.id != EndpointProfile.official.id }
        list.insert(EndpointProfile.official, at: 0)
        self.endpointProfiles = list

        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: "ios_endpoint_profiles")
        }
        UserDefaults.standard.set(selectedProfileId, forKey: "ios_selected_profile_id")

        let active = list.first(where: { $0.id == self.selectedProfileId }) ?? EndpointProfile.official
        self.apiBaseURL = active.apiBaseURL
        self.cdnBaseURL = active.cdnBaseURL
        self.gatewayURL = active.gatewayURL

        autoSyncToWatch()
    }

    private func selectProfile(_ profile: EndpointProfile) {
        self.selectedProfileId = profile.id
        self.apiBaseURL = profile.apiBaseURL
        self.cdnBaseURL = profile.cdnBaseURL
        self.gatewayURL = profile.gatewayURL
        saveProfiles()
    }

    private func deleteProfile(_ profile: EndpointProfile) {
        guard !profile.isOfficial else { return }
        endpointProfiles.removeAll { $0.id == profile.id }
        if selectedProfileId == profile.id {
            selectedProfileId = EndpointProfile.official.id
        }
        saveProfiles()
    }

    private func saveProfileFromEditor(_ profile: EndpointProfile) {
        if let index = endpointProfiles.firstIndex(where: { $0.id == profile.id }) {
            guard !endpointProfiles[index].isOfficial else { return }
            endpointProfiles[index] = profile
        } else {
            endpointProfiles.append(profile)
            selectedProfileId = profile.id
        }
        saveProfiles()
    }

    private func loadCachedProfile() {
        if let data = UserDefaults.standard.data(forKey: "ios_cached_user_profile"),
           let decoded = try? JSONDecoder().decode(DiscordProfile.self, from: data) {
            self.userProfile = decoded
        }
    }

    private func autoSyncToWatch() {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else { return }
        syncService.syncToWatch(
            token: cleanToken,
            isBot: isBot,
            apiBaseURL: apiBaseURL,
            cdnBaseURL: cdnBaseURL,
            gatewayURL: gatewayURL,
            endpointProfiles: endpointProfiles,
            selectedProfileId: selectedProfileId,
            quickReplies: quickReplies
        )
    }

    private func loadQuickReplies() {
        if let saved = UserDefaults.standard.stringArray(forKey: "ios_quick_replies"), !saved.isEmpty {
            self.quickReplies = saved
        } else {
            self.quickReplies = QuickRepliesManagerView.defaultQuickReplies
        }
    }

    private func saveQuickReplies() {
        UserDefaults.standard.set(quickReplies, forKey: "ios_quick_replies")
        autoSyncToWatch()
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        testSucceeded = false

        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else {
            isTesting = false
            testResult = "Please enter a token"
            return
        }

        let cleanBase = apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleanBase)/users/@me") else {
            isTesting = false
            testResult = "Invalid API URL"
            return
        }

        var request = URLRequest(url: url)
        let auth = isBot ? "Bot \(cleanToken)" : cleanToken
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                isTesting = false
                testResult = "Non-HTTP response"
                return
            }

            if http.statusCode == 200 {
                if let profile = try? JSONDecoder().decode(DiscordProfile.self, from: data) {
                    self.userProfile = profile
                    if let encoded = try? JSONEncoder().encode(profile) {
                        UserDefaults.standard.set(encoded, forKey: "ios_cached_user_profile")
                    }
                    isTesting = false
                    testSucceeded = true
                    testResult = "Success! Verified account: @\(profile.username)"
                } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let username = json["username"] as? String {
                    isTesting = false
                    testSucceeded = true
                    testResult = "Success! Verified account: @\(username)"
                } else {
                    isTesting = false
                    testSucceeded = true
                    testResult = "Success! (HTTP 200)"
                }
            } else if http.statusCode == 401 {
                isTesting = false
                userProfile = nil
                UserDefaults.standard.removeObject(forKey: "ios_cached_user_profile")
                testResult = "Error 401: Unauthorized token"
            } else {
                isTesting = false
                testResult = "Error \(http.statusCode)"
            }
        } catch {
            isTesting = false
            testResult = "Network Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Endpoint Profile Editor Sheet

struct EndpointProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: EndpointProfile?
    let onSave: (EndpointProfile) -> Void
    let onDelete: ((EndpointProfile) -> Void)?

    @State private var name: String = ""
    @State private var apiBaseURL: String = ""
    @State private var cdnBaseURL: String = ""
    @State private var gatewayURL: String = ""
    @State private var presenceEnabled = false
    @State private var presenceServerURL = ""
    @State private var baseHostInput: String = ""
    @State private var showDeleteConfirmation: Bool = false

    init(profile: EndpointProfile?, onSave: @escaping (EndpointProfile) -> Void, onDelete: ((EndpointProfile) -> Void)? = nil) {
        self.profile = profile
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: profile?.name ?? "")
        _apiBaseURL = State(initialValue: profile?.apiBaseURL ?? "")
        _cdnBaseURL = State(initialValue: profile?.cdnBaseURL ?? "")
        _gatewayURL = State(initialValue: profile?.gatewayURL ?? "")
        _presenceEnabled = State(initialValue: profile?.presenceEnabled ?? false)
        _presenceServerURL = State(initialValue: profile?.presenceServerURL ?? "")
    }

    var isEditing: Bool { profile != nil }

    var isValid: Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanApi = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanName.isEmpty && !cleanApi.isEmpty && cleanApi.lowercased().hasPrefix("http")
            && (gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || EndpointProfile.validatedGatewayURL(gatewayURL) != nil)
            && (!presenceEnabled || EndpointProfile.validatedPresenceURL(presenceServerURL) != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Profile Info")) {
                    TextField("Profile Name (e.g. My Proxy)", text: $name)
                }

                Section(
                    header: Text("Quick Host Setup"),
                    footer: Text("Enter a domain like proxy.example.com to generate API, CDN and call Gateway endpoints, plus Companion when enabled.")
                ) {
                    HStack {
                        TextField("e.g. discord.example.com", text: $baseHostInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button("Auto-fill") {
                            autoFillFromHost()
                        }
                        .disabled(baseHostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section(header: Text("Endpoints Configuration")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Base URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("https://...", text: $apiBaseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("CDN Base URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("https://...", text: $cdnBaseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                }

                Section(header: Text("Voice Call Gateway"),
                        footer: Text("WSS is used only during a voice call. Leave blank for Discord's official Gateway. Presence and live messages continue through Companion. The separate Voice Gateway and UDP audio connect to Discord directly.")) {
                    TextField("wss://gateway.example.com/?v=10&encoding=json", text: $gatewayURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !gatewayURL.isEmpty && EndpointProfile.validatedGatewayURL(gatewayURL) == nil {
                        Text("Enter a WSS URL without credentials or a fragment.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section(
                    header: Text("TinyCord Companion"),
                    footer: Text("Show “Active on Apple Watch” while using TinyCord and receive live updates. Use a Companion server you trust: it briefly receives your Discord token to connect, then discards it. HTTPS is required.")
                ) {
                    Toggle("Use TinyCord Companion", isOn: $presenceEnabled)
                    if presenceEnabled {
                        TextField("https://companion.example.com", text: $presenceServerURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !presenceServerURL.isEmpty && EndpointProfile.validatedPresenceURL(presenceServerURL) == nil {
                            Text("Enter an HTTPS address with no path, query or credentials.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                if isEditing && onDelete != nil {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("Delete Profile")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Profile" : "Add Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let id = profile?.id ?? UUID().uuidString
                        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanApi = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanCdn = cdnBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanGw = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)

                        let updated = EndpointProfile(
                            id: id,
                            name: cleanName,
                            apiBaseURL: cleanApi,
                            cdnBaseURL: cleanCdn.isEmpty ? cleanApi : cleanCdn,
                            gatewayURL: cleanGw,
                            isOfficial: false,
                            presenceEnabled: presenceEnabled,
                            presenceServerURL: presenceServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
            .confirmationDialog("Are you sure you want to delete this endpoint profile?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete Profile", role: .destructive) {
                    if let profile, let onDelete {
                        onDelete(profile)
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func autoFillFromHost() {
        var trimmed = baseHostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("https://") {
            trimmed = String(trimmed.dropFirst("https://".count))
        } else if trimmed.lowercased().hasPrefix("http://") {
            trimmed = String(trimmed.dropFirst("http://".count))
        } else if trimmed.lowercased().hasPrefix("wss://") {
            trimmed = String(trimmed.dropFirst("wss://".count))
        } else if trimmed.lowercased().hasPrefix("ws://") {
            trimmed = String(trimmed.dropFirst("ws://".count))
        }
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if trimmed.lowercased().hasPrefix("companion.") {
            trimmed = String(trimmed.dropFirst(10))
        } else if trimmed.lowercased().hasPrefix("cdn.") {
            trimmed = String(trimmed.dropFirst(4))
        } else if trimmed.lowercased().hasPrefix("gateway.") {
            trimmed = String(trimmed.dropFirst(8))
        } else if trimmed.lowercased().hasPrefix("api.") {
            trimmed = String(trimmed.dropFirst(4))
        }

        guard !trimmed.isEmpty else { return }

        apiBaseURL = "https://\(trimmed)/api/v10"
        cdnBaseURL = "https://cdn.\(trimmed)"
        gatewayURL = "wss://gateway.\(trimmed)/?v=10&encoding=json"
        if presenceEnabled {
            presenceServerURL = "https://companion.\(trimmed)"
        }

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = trimmed
        }
    }
}

// MARK: - Discord Profile Model

public struct DiscordProfile: Codable, Equatable {
    public let id: String
    public let username: String
    public let globalName: String?
    public let avatar: String?
    public let discriminator: String?
    public let bot: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case globalName = "global_name"
        case avatar
        case discriminator
        case bot
    }

    public var displayName: String {
        if let globalName, !globalName.isEmpty {
            return globalName
        }
        return username
    }

    public var handle: String {
        if let discriminator, discriminator != "0", !discriminator.isEmpty {
            return "\(username)#\(discriminator)"
        }
        return "@\(username)"
    }

    public func avatarURL(cdnBase: String) -> URL? {
        let base = cdnBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let avatar, !avatar.isEmpty {
            let ext = avatar.hasPrefix("a_") ? "gif" : "png"
            return URL(string: "\(base)/avatars/\(id)/\(avatar).\(ext)?size=160")
        }
        let defaultIndex: Int
        if let discriminator, let discInt = Int(discriminator), discInt > 0 {
            defaultIndex = discInt % 5
        } else if let idInt = Int(id.suffix(4)) {
            defaultIndex = (idInt >> 22) % 6
        } else {
            defaultIndex = 0
        }
        return URL(string: "\(base)/embed/avatars/\(defaultIndex).png")
    }
}

#Preview {
    ContentView()
}
