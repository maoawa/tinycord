import Foundation
import Combine

public enum PresenceConnectionState: String, Sendable {
    case disconnected, connecting, connected, reconnecting
}

/// Never follow redirects with a Discord token or a relay session credential.
private final class PresenceSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest,
                               completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The Watch uses ordinary HTTPS. Only the Ubuntu service opens a WebSocket.
@MainActor
public final class PresenceClient: ObservableObject {
    public static let shared = PresenceClient()
    @Published public private(set) var state: PresenceConnectionState = .disconnected
    @Published public private(set) var lastError: String?
    @Published public private(set) var connectionPhase = "REST polling"

    public let messageCreatePublisher = PassthroughSubject<DiscordMessage, Never>()
    public let messageDeletePublisher = PassthroughSubject<GatewayMessageDeleteData, Never>()
    public let typingStartPublisher = PassthroughSubject<GatewayTypingData, Never>()
    public let resyncPublisher = PassthroughSubject<Void, Never>()

    private struct RelaySession {
        let baseURL: URL
        let credential: String
    }

    private var relay: RelaySession?
    private var work: Task<Void, Never>?
    private var isActive = false
    private var generation = UUID()
    private let authStore: AuthStore
    private let endpointConfig: EndpointConfig
    private let session: URLSession

    public init(authStore: AuthStore? = nil, endpointConfig: EndpointConfig? = nil) {
        self.authStore = authStore ?? .shared
        self.endpointConfig = endpointConfig ?? .shared
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 35
        session = URLSession(configuration: config, delegate: PresenceSessionDelegate(), delegateQueue: nil)
    }

    public func setActive(_ active: Bool) {
        isActive = active
        if active { connect() } else { disconnect() }
    }

    public func connect() {
        guard work == nil else { return }
        reconnect(force: true)
    }

    public func reconnect(force: Bool = false) {
        if !force, work != nil { return }
        disconnect()
        guard isActive, authStore.isAuthenticated, endpointConfig.presenceEnabled else { return }
        guard let base = EndpointProfile.validatedPresenceURL(endpointConfig.activeProfile.presenceServerURL) else {
            lastError = "Enter a valid https:// TinyCord Companion address in Endpoints."
            return
        }
        let currentGeneration = generation
        work = Task { [weak self] in
            guard let self else { return }
            var failures = 0
            while !Task.isCancelled, self.generation == currentGeneration {
                self.state = failures == 0 ? .connecting : .reconnecting
                self.connectionPhase = "Connecting to TinyCord Companion…"
                // Two UUIDs provide an unguessable, per-use credential. No token in URLs.
                let relay = RelaySession(baseURL: base, credential: UUID().uuidString + UUID().uuidString)
                self.relay = relay
                do {
                    try await self.authenticate(relay)
                    try Task.checkCancellation()
                    guard self.generation == currentGeneration else { return }
                    self.state = .connected
                    self.connectionPhase = "Active on Apple Watch"
                    self.lastError = nil
                    failures = 0
                    self.resyncPublisher.send(())
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await self.renewLease(relay) }
                        group.addTask { try await self.receiveEvents(relay) }
                        defer { group.cancelAll() }
                        try await group.next()
                    }
                } catch {
                    guard !Task.isCancelled, self.generation == currentGeneration else { return }
                    self.lastError = error.localizedDescription
                }
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                self.state = .reconnecting
                self.connectionPhase = "REST polling; retrying presence…"
                await self.endSession(relay)
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                self.relay = nil
                failures += 1
                if failures >= 4 {
                    self.state = .disconnected
                    self.connectionPhase = "REST polling"
                    self.work = nil
                    return
                }
                do { try await Task.sleep(nanoseconds: UInt64(min(30, 3 * (1 << failures))) * 1_000_000_000) }
                catch { return }
            }
        }
    }

    public func disconnect() {
        generation = UUID()
        work?.cancel()
        work = nil
        if let oldRelay = relay {
            // Best effort on scene suspension; the server lease is the fallback.
            Task { await endSession(oldRelay) }
        }
        relay = nil
        state = .disconnected
        connectionPhase = "REST polling"
        lastError = nil
    }

    private func authenticate(_ relay: RelaySession) async throws {
        guard let token = authStore.token, !token.isEmpty else { throw RelayError(message: "Sign in first.") }
        let body = try JSONSerialization.data(withJSONObject: ["token": token, "isBot": authStore.isBotToken])
        let data = try await request(relay, path: "v1/session", method: "POST", body: body)
        let response = try JSONDecoder().decode(RelayStatus.self, from: data)
        guard response.state == "connected" else { throw RelayError(message: "Companion session is not ready.") }
    }

    private func renewLease(_ relay: RelaySession) async throws {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            _ = try await request(relay, path: "v1/session", method: "PUT")
        }
    }

    private func receiveEvents(_ relay: RelaySession) async throws {
        var cursor = 0
        while !Task.isCancelled {
            let data = try await request(relay, path: "v1/events", method: "GET", after: cursor)
            try Task.checkCancellation()
            let response = try JSONDecoder().decode(EventResponse.self, from: data)
            guard response.state == "connected" else { throw RelayError(message: "Gateway disconnected. Reconnecting through HTTPS…") }
            if response.reset { resyncPublisher.send(()) }
            for event in response.events where event.id > cursor {
                if let message = event.message { messageCreatePublisher.send(message) }
                if let deletion = event.deletion { messageDeletePublisher.send(deletion) }
                if let typing = event.typing { typingStartPublisher.send(typing) }
            }
            cursor = response.cursor
        }
    }

    private func endSession(_ relay: RelaySession) async {
        _ = try? await request(relay, path: "v1/session", method: "DELETE")
    }

    private func request(_ relay: RelaySession, path: String, method: String,
                         body: Data? = nil, after: Int? = nil) async throws -> Data {
        var components = URLComponents(url: relay.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if let after { components.queryItems = [URLQueryItem(name: "after", value: String(after))] }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(relay.credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayError(message: "Invalid Companion response.") }
        guard (200..<300).contains(http.statusCode) else {
            // Don't display arbitrary server bodies, which may contain credentials.
            throw RelayError(message: "TinyCord Companion returned HTTP \(http.statusCode). Check its address and connection.")
        }
        return data
    }

    private struct RelayError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct RelayStatus: Decodable { let state: String }
    private struct EventResponse: Decodable {
        let state: String
        let events: [RelayEvent]
        let cursor: Int
        let reset: Bool
    }
    private struct RelayEvent: Decodable {
        let id: Int
        var message: DiscordMessage?
        var deletion: GatewayMessageDeleteData?
        var typing: GatewayTypingData?
        enum CodingKeys: String, CodingKey { case id, type, data }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(Int.self, forKey: .id)
            switch try values.decode(String.self, forKey: .type) {
            case "MESSAGE_CREATE": message = try values.decode(DiscordMessage.self, forKey: .data)
            case "MESSAGE_DELETE": deletion = try values.decode(GatewayMessageDeleteData.self, forKey: .data)
            case "TYPING_START": typing = try values.decode(GatewayTypingData.self, forKey: .data)
            default: break
            }
        }
    }
}
