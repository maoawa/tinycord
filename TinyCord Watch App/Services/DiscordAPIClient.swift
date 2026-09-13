//
//  DiscordAPIClient.swift
//  TinyCord Watch App
//

import Foundation

public enum DiscordAPIError: LocalizedError, Sendable {
    case unauthenticated
    case invalidURL(String)
    case unauthorized
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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DiscordAPIError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DiscordAPIError.serverError(statusCode: -1, message: "Non-HTTP response")
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
            if !isRetry, let retrySec, retrySec <= 10 {
                try? await Task.sleep(nanoseconds: UInt64((retrySec + 0.25) * 1_000_000_000))
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
        let request = try makeRequest(path: "/users/@me")
        let user: DiscordUser = try await execute(request)
        await MainActor.run {
            authStore.currentUser = user
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
            if isVoiceMessage {
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
