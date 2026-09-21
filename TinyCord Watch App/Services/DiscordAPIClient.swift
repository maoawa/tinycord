//
//  DiscordAPIClient.swift
//  TinyCord Watch App
//

import Foundation

public enum DiscordAPIError: LocalizedError, Sendable {
    case unauthenticated
    case invalidURL(String)
    case unauthorized
    case captchaRequired
    case forbidden
    case rateLimited(retryAfter: Double?)
    case serverError(statusCode: Int, message: String)
    case decodingError(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .unauthenticated:
            return "No token provided. Please log in."
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .unauthorized:
            return "Invalid or expired token."
        case .captchaRequired:
            return "Discord requires CAPTCHA verification. Open the official Discord app on your iPhone to check your account before trying again."
        case .forbidden:
            return "Access forbidden (403)."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limited. Retry after \(String(format: "%.1f", retryAfter))s"
            }
            return "Rate limited by Discord."
        case .serverError(let code, let msg):
            return "Server error (\(code)): \(msg)"
        case .decodingError(let details):
            return "Failed to parse data: \(details)"
        case .networkError(let msg):
            return "Network connection failed: \(msg)"
        }
    }
}

public final class DiscordAPIClient: @unchecked Sendable {
    public static let shared = DiscordAPIClient()

    private let session: URLSession
    private let authStore: AuthStore
    private let endpointConfig: EndpointConfig
    private var expectedSessionID: UUID?
    private var expectedAPIBase: String?

    /// View models retain a client bound to the account that created them.
    public func scopedToCurrentAccount() -> DiscordAPIClient {
        let client = DiscordAPIClient(session: session, authStore: authStore, endpointConfig: endpointConfig)
        client.expectedSessionID = authStore.sessionID
        client.expectedAPIBase = endpointConfig.apiBaseURL
        return client
    }

    public func checkAccount() throws {
        try Task.checkCancellation()
        if let expectedSessionID, expectedSessionID != authStore.sessionID { throw CancellationError() }
        if let expectedAPIBase, expectedAPIBase != endpointConfig.apiBaseURL { throw CancellationError() }
    }

    public init(
        session: URLSession = .shared,
        authStore: AuthStore = .shared,
        endpointConfig: EndpointConfig = .shared
    ) {
        self.session = session
        self.authStore = authStore
        self.endpointConfig = endpointConfig
    }

    private func makeRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem]? = nil,
        bodyData: Data? = nil
    ) throws -> URLRequest {
        try checkAccount()
        guard let baseURL = endpointConfig.apiURL(path: path) else {
            throw DiscordAPIError.invalidURL(path)
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)
        if let queryItems, !queryItems.isEmpty {
            components?.queryItems = queryItems
        }

        guard let finalURL = components?.url else {
            throw DiscordAPIError.invalidURL(baseURL.absoluteString)
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.timeoutInterval = 15.0

        if let authHeader = authStore.authHeaderValue {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        } else {
            throw DiscordAPIError.unauthenticated
        }

        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Custom user-agent friendly for custom endpoints and Discord gateway/REST
        request.setValue("TinyCord/1.0 (watchOS; Apple Watch; +https://github.com/maoawa/TinyCord)", forHTTPHeaderField: "User-Agent")

        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }

        return request
    }

    private func execute<T: Decodable>(_ request: URLRequest, isRetry: Bool = false) async throws -> T {
        try checkAccount()
        let requestSessionID = authStore.sessionID
        guard request.value(forHTTPHeaderField: "Authorization") == authStore.authHeaderValue else { throw CancellationError() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || DiscordRequestCancellation.isCancellation(error) { throw CancellationError() }
            throw DiscordAPIError.networkError(error.localizedDescription)
        }

        try checkAccount()
        guard requestSessionID == authStore.sessionID else { throw CancellationError() }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DiscordAPIError.serverError(statusCode: -1, message: "Non-HTTP response")
        }

        if httpResponse.statusCode == 400,
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           body["captcha_key"] != nil {
            throw DiscordAPIError.captchaRequired
        }

        switch httpResponse.statusCode {
        case 200...299:
            do {
                let decoder = JSONDecoder()
                return try decoder.decode(T.self, from: data)
            } catch {
                let preview = String(data: data.prefix(200), encoding: .utf8) ?? ""
                throw DiscordAPIError.decodingError("\(error.localizedDescription) - Response preview: \(preview)")
            }

        case 401:
            throw DiscordAPIError.unauthorized

        case 403:
            throw DiscordAPIError.forbidden

        case 429:
            let retryHeader = httpResponse.value(forHTTPHeaderField: "Retry-After")
            let retrySec = retryHeader.flatMap { Double($0) }
            // Honor short rate limits transparently instead of surfacing an error.
            if !isRetry, let retrySec, retrySec.isFinite, (0...10).contains(retrySec) {
                try await Task.sleep(for: .seconds(retrySec + 0.25))
                try checkAccount()
                guard requestSessionID == authStore.sessionID else { throw CancellationError() }
                return try await execute(request, isRetry: true)
            }
            throw DiscordAPIError.rateLimited(retryAfter: retrySec)

        default:
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw DiscordAPIError.serverError(statusCode: httpResponse.statusCode, message: errorText)
        }
    }

    // MARK: - API Methods

    public func getCurrentUser() async throws -> DiscordUser {
        let requestSessionID = authStore.sessionID
        let request = try makeRequest(path: "/users/@me")
        let user: DiscordUser = try await execute(request)
        await MainActor.run {
            authStore.updateCurrentUser(user, forSession: requestSessionID)
        }
        return user
    }

    public func getDMChannels() async throws -> [DiscordChannel] {
        let request = try makeRequest(path: "/users/@me/channels")
        let channels: [DiscordChannel] = try await execute(request)
        return channels
    }

    public func getRelationships() async throws -> [DiscordRelationship] {
        let request = try makeRequest(path: "/users/@me/relationships")
        let relationships: [DiscordRelationship] = try await execute(request)
        return relationships
    }

    public func createOrGetDMChannel(recipientId: String) async throws -> DiscordChannel {
        let bodyDict = ["recipient_id": recipientId]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyDict)
        let request = try makeRequest(
            path: "/users/@me/channels",
            method: "POST",
            bodyData: bodyData
        )
        let channel: DiscordChannel = try await execute(request)
        return channel
    }

    public func getMessages(channelId: String, limit: Int = 50, before: String? = nil) async throws -> [DiscordMessage] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "\(min(limit, 100))")
        ]
        if let before {
            query.append(URLQueryItem(name: "before", value: before))
        }

        let request = try makeRequest(path: "/channels/\(channelId)/messages", queryItems: query)
        let messages: [DiscordMessage] = try await execute(request)
        return messages
    }

    public func getMessage(channelId: String, messageId: String) async throws -> DiscordMessage {
        let request = try makeRequest(path: "/channels/\(channelId)/messages/\(messageId)")
        return try await execute(request)
    }

    /// Uses the same authenticated Discord REST endpoint as messaging, not local storage.
    public func setChannelUnread(channelId: String, latestMessageId: String, unread: Bool) async throws {
        guard !authStore.isBotToken else {
            throw DiscordReadStateError(message: "Read/unread syncing requires a Discord user account, not a bot token.")
        }
        let update = try DiscordReadStateRequest(channelID: channelId, latestMessageID: latestMessageId, unread: unread)
        let request = try makeRequest(path: update.path, method: "POST", bodyData: update.body)
        try await DiscordReadStateHTTP.send(request, session: session)
    }

    public func sendMessage(
        channelId: String,
        content: String,
        replyToMessageId: String? = nil
    ) async throws -> DiscordMessage {
        var payload: [String: Any] = [
            "content": content
        ]

        if let replyToMessageId {
            payload["message_reference"] = [
                "message_id": replyToMessageId
            ]
        }

        let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [])
        let request = try makeRequest(
            path: "/channels/\(channelId)/messages",
            method: "POST",
            bodyData: bodyData
        )

        let sentMessage: DiscordMessage = try await execute(request)
        return sentMessage
    }

    public func triggerTyping(channelId: String) async {
        guard let request = try? makeRequest(path: "/channels/\(channelId)/typing", method: "POST") else {
            return
        }
        _ = try? await session.data(for: request)
    }

    public func addReaction(channelId: String, messageId: String, emoji: String) async throws {
        guard let encodedEmoji = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return
        }
        let request = try makeRequest(
            path: "/channels/\(channelId)/messages/\(messageId)/reactions/\(encodedEmoji)/@me",
            method: "PUT"
        )
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw DiscordAPIError.unauthorized
        }
    }

    public func uploadAttachment(
        channelId: String,
        fileData: Data,
        filename: String,
        mimeType: String,
        content: String = "",
        replyToMessageId: String? = nil,
        isVoiceMessage: Bool = false,
        durationSecs: Float? = nil
    ) async throws -> DiscordMessage {
        try checkAccount()
        let uploadSessionID = authStore.sessionID
        let uploadAPIBase = endpointConfig.apiBaseURL
        let boundary = "Boundary-\(UUID().uuidString)"
        let path = "/channels/\(channelId)/messages"
        guard let url = endpointConfig.apiURL(path: path) else {
            throw DiscordAPIError.invalidURL(path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let authHeader = authStore.authHeaderValue {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        } else {
            throw DiscordAPIError.unauthenticated
        }
        request.setValue("TinyCord/1.0 (watchOS; Apple Watch; +https://github.com/maoawa/TinyCord)", forHTTPHeaderField: "User-Agent")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body = Data()

        // 1. JSON payload part
        var payload: [String: Any] = [
            "content": content
        ]

        var attachmentDict: [String: Any] = [
            "id": 0,
            "filename": filename
        ]
        if isVoiceMessage {
            payload["flags"] = 8192 // IS_VOICE_MESSAGE
            if let durationSecs {
                attachmentDict["duration_secs"] = durationSecs
                attachmentDict["waveform"] = "AAAA"
            }
        }
        payload["attachments"] = [attachmentDict]

        if let replyToMessageId {
            payload["message_reference"] = [
                "message_id": replyToMessageId
            ]
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"payload_json\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
            body.append(jsonData)
            body.append("\r\n".data(using: .utf8)!)
        }

        // 2. Binary file part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files[0]\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        // 3. End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        do {
            let sentMessage: DiscordMessage = try await execute(request)
            return sentMessage
        } catch {
            // Only an explicit invalid-flags response proves this voice payload
            // was rejected. Never resend on CAPTCHA, auth, rate limits, or an
            // ambiguous network failure (which may already have sent the audio).
            if isVoiceMessage, case DiscordAPIError.serverError(let status, let message) = error,
               status == 400, let data = message.data(using: .utf8),
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errors = body["errors"] as? [String: Any], errors["flags"] != nil {
                try checkAccount()
                guard uploadSessionID == authStore.sessionID,
                      uploadAPIBase == endpointConfig.apiBaseURL else { throw CancellationError() }
                // Retry without voice flags as standard audio attachment
                return try await uploadAttachment(
                    channelId: channelId,
                    fileData: fileData,
                    filename: filename,
                    mimeType: mimeType,
                    content: content,
                    replyToMessageId: replyToMessageId,
                    isVoiceMessage: false
                )
            }
            throw error
        }
    }
}
