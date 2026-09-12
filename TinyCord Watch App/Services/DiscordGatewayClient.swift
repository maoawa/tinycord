//
//  DiscordGatewayClient.swift
//  TinyCord Watch App
//

import Foundation
import Combine

public enum GatewayConnectionState: String, Sendable {
    case disconnected = "Disconnected"
    case connecting = "Connecting..."
    case connected = "Connected"
    case reconnecting = "Reconnecting..."
}

public final class DiscordGatewayClient: ObservableObject, @unchecked Sendable {
    public static let shared = DiscordGatewayClient()

    /// Gateway intents: direct messages, DM reactions, DM typing, message content.
    /// Without these, the gateway will not dispatch any DM events.
    private static let intents: Int = (1 << 12) | (1 << 13) | (1 << 14) | (1 << 15)

    @Published public private(set) var state: GatewayConnectionState = .disconnected
    @Published public private(set) var lastError: String?

    // Event subjects
    public let messageCreatePublisher = PassthroughSubject<DiscordMessage, Never>()
    public let messageDeletePublisher = PassthroughSubject<GatewayMessageDeleteData, Never>()
    public let typingStartPublisher = PassthroughSubject<GatewayTypingData, Never>()

    private var webSocketTask: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var lastSequence: Int?
    private var sessionId: String?
    private var isIntentionallyDisconnected = false
    private var reconnectAttempt = 0

    // Reused across reconnects so we don't leak a session per attempt
    private lazy var session = URLSession(configuration: .default)

    private let authStore: AuthStore
    private let endpointConfig: EndpointConfig

    public init(authStore: AuthStore = .shared, endpointConfig: EndpointConfig = .shared) {
        self.authStore = authStore
        self.endpointConfig = endpointConfig
    }

    public func connect() {
        reconnectAttempt = 0
        // Already live; avoid stacking parallel sockets.
        if state == .connected || state == .connecting, webSocketTask != nil {
            return
        }
        reconnect(force: true)
    }

    /// Tears down any existing socket and opens a fresh one.
    /// Use after credentials or endpoint configuration changed.
    public func reconnect(force: Bool = false) {
        guard endpointConfig.enableGateway else {
            disconnect()
            return
        }
        guard let token = authStore.token, !token.isEmpty else {
            disconnect()
            return
        }
        guard let url = URL(string: endpointConfig.gatewayURL) else {
            lastError = "Invalid Gateway URL: \(endpointConfig.gatewayURL)"
            updateState(.disconnected)
            return
        }

        if force {
            reconnectAttempt = 0
        }

        isIntentionallyDisconnected = false
        if !force, reconnectAttempt == 0, webSocketTask != nil {
            // A socket is already open and healthy enough.
            return
        }
        reconnectTask?.cancel()
        teardownSocket()

        updateState(.connecting)

        var request = URLRequest(url: url)
        request.timeoutInterval = 20.0
        request.setValue("TinyCord/1.0 (watchOS; Apple Watch)", forHTTPHeaderField: "User-Agent")

        let task = session.webSocketTask(with: request)
        // Allow large gateway payloads (e.g. Discord READY event can exceed 3-4 MB)
        task.maximumMessageSize = 32 * 1024 * 1024
        self.webSocketTask = task
        task.resume()

        startReceiving()
    }

    public func disconnect() {
        isIntentionallyDisconnected = true
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownSocket()
        updateState(.disconnected)
    }

    /// Cancels tasks and closes the socket without touching the
    /// intentional-disconnect flag, so reconnects stay clean.
    private func teardownSocket() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    private func updateState(_ newState: GatewayConnectionState) {
        Task { @MainActor in
            self.state = newState
        }
    }

    private func startReceiving() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let task = self.webSocketTask else { break }

                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        self.handleIncomingText(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleIncomingText(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled, !self.isIntentionallyDisconnected {
                        self.handleDisconnect(error: error)
                    }
                    break
                }
            }
        }
    }

    private func handleIncomingText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = json["op"] as? Int else {
            return
        }

        if let s = json["s"] as? Int {
            self.lastSequence = s
        }

        switch op {
        case GatewayOpcode.hello.rawValue:
            if let d = json["d"] as? [String: Any],
               let interval = d["heartbeat_interval"] as? Double {
                startHeartbeat(intervalMs: interval)
                sendIdentify()
            }

        case GatewayOpcode.heartbeatAck.rawValue:
            break

        case GatewayOpcode.dispatch.rawValue:
            let eventName = json["t"] as? String
            handleDispatchEvent(eventName: eventName, data: json["d"])

        case GatewayOpcode.reconnect.rawValue:
            scheduleReconnect(baseDelay: 1.0)

        case GatewayOpcode.invalidSession.rawValue:
            sessionId = nil
            scheduleReconnect(baseDelay: 5.0)

        default:
            break
        }
    }

    private func handleDispatchEvent(eventName: String?, data: Any?) {
        guard let eventName else { return }

        switch eventName {
        case "READY":
            reconnectAttempt = 0
            lastError = nil
            updateState(.connected)
            if let dict = data as? [String: Any],
               let session = dict["session_id"] as? String {
                self.sessionId = session
            }

        case "MESSAGE_CREATE":
            if let data,
               let jsonData = try? JSONSerialization.data(withJSONObject: data),
               let msg = try? JSONDecoder().decode(DiscordMessage.self, from: jsonData) {
                Task { @MainActor in
                    self.messageCreatePublisher.send(msg)
                }
            }

        case "MESSAGE_DELETE":
            if let data,
               let jsonData = try? JSONSerialization.data(withJSONObject: data),
               let del = try? JSONDecoder().decode(GatewayMessageDeleteData.self, from: jsonData) {
                Task { @MainActor in
                    self.messageDeletePublisher.send(del)
                }
            }

        case "TYPING_START":
            if let data,
               let jsonData = try? JSONSerialization.data(withJSONObject: data),
               let typing = try? JSONDecoder().decode(GatewayTypingData.self, from: jsonData) {
                Task { @MainActor in
                    self.typingStartPublisher.send(typing)
                }
            }

        default:
            break
        }
    }

    private func startHeartbeat(intervalMs: Double) {
        heartbeatTask?.cancel()
        let intervalSeconds = max(1.0, intervalMs / 1000.0)

        heartbeatTask = Task { [weak self] in
            // Discord expects the first heartbeat within interval * jitter.
            try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * Double.random(in: 0...1) * 1_000_000_000))
            while !Task.isCancelled {
                guard let self else { break }
                self.sendHeartbeat()
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }
    }

    private func sendHeartbeat() {
        let payload: [String: Any?] = [
            "op": GatewayOpcode.heartbeat.rawValue,
            "d": lastSequence
        ]
        sendJSON(payload)
    }

    private func sendIdentify() {
        guard let token = authStore.token else { return }

        var d: [String: Any] = [
            "token": token
        ]

        if authStore.isBotToken {
            d["intents"] = Self.intents
            d["properties"] = [
                "os": "watchOS",
                "browser": "TinyCord",
                "device": "Apple Watch"
            ]
        } else {
            // User tokens must NOT send intents (Discord Gateway drops with 4004 if present)
            // and must provide standard client properties
            d["properties"] = [
                "os": "Mac OS X",
                "browser": "Discord Client",
                "device": "",
                "system_locale": "en-US",
                "browser_user_agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "browser_version": "120.0.0.0",
                "os_version": "10.15.7",
                "release_channel": "stable",
                "client_build_number": 260000
            ]
            d["presence"] = [
                "status": "online",
                "since": 0,
                "activities": [] as [Any],
                "afk": false
            ]
        }

        let payload: [String: Any] = [
            "op": GatewayOpcode.identify.rawValue,
            "d": d
        ]
        sendJSON(payload)
    }

    private func sendJSON(_ dict: [String: Any?]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8) else {
            return
        }

        webSocketTask?.send(.string(string)) { error in
            if let error {
                print("[Gateway] Send error: \(error.localizedDescription)")
            }
        }
    }

    private func handleDisconnect(error: Error? = nil) {
        guard !isIntentionallyDisconnected else { return }

        if let error {
            print("[Gateway] Disconnected with error: \(error.localizedDescription)")
        }

        // If gateway fails repeatedly (e.g. endpoint blocks WebSockets or network issues),
        // gracefully drop to disconnected so the app stays on reliable REST polling.
        if reconnectAttempt >= 4 {
            updateState(.disconnected)
            Task { @MainActor in
                self.lastError = "Gateway unavailable. Using REST polling."
            }
            return
        }

        updateState(.reconnecting)
        scheduleReconnect()
    }

    /// Exponential backoff (3s, 6s, 12s, ... capped at 30s) with a little jitter.
    private func scheduleReconnect(baseDelay: Double? = nil) {
        reconnectTask?.cancel()
        let delay: Double
        if let baseDelay {
            delay = baseDelay
        } else {
            let backoff = min(3.0 * pow(2.0, Double(reconnectAttempt)), 30.0)
            delay = backoff * Double.random(in: 0.8...1.2)
            reconnectAttempt += 1
        }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isIntentionallyDisconnected else { return }
            self.reconnect(force: true)
        }
    }
}
