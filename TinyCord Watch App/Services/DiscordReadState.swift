import Foundation

/// Discord's user-account read cursor. Moving it back one snowflake makes the
/// selected message unread; acknowledging the latest message marks the chat read.
struct DiscordReadStateRequest {
    let path: String
    let body: Data

    init(channelID: String, latestMessageID: String, unread: Bool) throws {
        guard let channel = UInt64(channelID), channel > 0,
              let latest = UInt64(latestMessageID), latest > 0 else {
            throw DiscordReadStateError(message: "Invalid channel or message ID.")
        }
        let cursor = unread ? latest - 1 : latest
        path = "/channels/\(channel)/messages/\(cursor)/ack"
        // Do not manufacture a mention badge when marking ordinary messages unread.
        let payload: [String: Any] = unread
            ? ["manual": true]
            : ["token": NSNull()]
        body = try JSONSerialization.data(withJSONObject: payload)
    }
}

struct DiscordReadStateError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum DiscordReadStateHTTP {
    /// ACKs can return an empty 204 or JSON. Neither requires decoding a message.
    /// Never treat auth, rate-limit or proxy failures as a successful mutation.
    static func send(_ request: URLRequest, session: URLSession, isRetry: Bool = false,
                     sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async throws {
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || DiscordRequestCancellation.isCancellation(error) { throw CancellationError() }
            // One bounded retry for a transient connection loss. Offline and
            // authentication failures wait for a later foreground attempt.
            if !isRetry, let failure = error as? URLError,
               [.timedOut, .networkConnectionLost].contains(failure.code) {
                try await sleep(0.75)
                return try await send(request, session: session, isRetry: true, sleep: sleep)
            }
            throw error
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw DiscordReadStateError(message: "Invalid read-state response.")
        }
        switch http.statusCode {
        case 200..<300: return
        case 401:
            throw DiscordReadStateError(message: "Discord rejected your token. Sign in again.")
        case 403:
            throw DiscordReadStateError(message: "Discord did not allow this read-state change.")
        case 429:
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                ?? (json?["retry_after"] as? Double)
            if !isRetry, let delay = retryAfter, delay.isFinite, (0...10).contains(delay) {
                try await sleep(delay + 0.25)
                return try await send(request, session: session, isRetry: true, sleep: sleep)
            }
            throw DiscordReadStateError(message: "Discord rate limited the change. Try again shortly.")
        default:
            throw DiscordReadStateError(message: "Read-state update failed (HTTP \(http.statusCode)).")
        }
    }
}


/// Cancellation is navigation/lifecycle control flow, not a failed read update.
nonisolated enum DiscordRequestCancellation {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        var current = error as NSError
        for _ in 0..<4 {
            if current.domain == NSURLErrorDomain && current.code == NSURLErrorCancelled { return true }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            current = underlying
        }
        return false
    }
}

/// Owns acknowledgements independently of transient SwiftUI navigation tasks.
/// Only enqueue messages actually loaded in the foreground conversation.
@MainActor
final class DiscordReadAcknowledgements {
    typealias Send = (String, String) async throws -> Void
    private let send: Send
    private let onSuccess: (String, String) -> Void
    private let onFailure: (String, Error) -> Void
    private let debounce: () async throws -> Void
    private let now: () -> Date
    private var pending: [String: String] = [:]
    private var confirmed: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var failures: [String: (cursor: String, retryAt: Date)] = [:]
    private var generation = UUID()

    init(send: @escaping Send,
         onSuccess: @escaping (String, String) -> Void,
         onFailure: @escaping (String, Error) -> Void,
         debounce: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(300)) },
         now: @escaping () -> Date = Date.init) {
        self.send = send
        self.onSuccess = onSuccess
        self.onFailure = onFailure
        self.debounce = debounce
        self.now = now
    }

    func enqueue(channelID: String, messageID: String) {
        guard let channel = UInt64(channelID), channel > 0,
              let cursor = UInt64(messageID), cursor > 0 else { return }
        if let acknowledged = confirmed[channelID], Self.covers(acknowledged, messageID) { return }
        if let queued = pending[channelID], Self.covers(queued, messageID) { return }
        if let failure = failures[channelID], Self.covers(failure.cursor, messageID),
           now() < failure.retryAt { return }
        pending[channelID] = messageID
        guard tasks[channelID] == nil else { return }
        let requestGeneration = generation
        tasks[channelID] = Task { [weak self, debounce] in
            do { try await debounce() }
            catch {
                self?.clearPending(channelID, generation: requestGeneration)
                return
            }
            await self?.drain(channelID, generation: requestGeneration)
        }
    }

    /// Called when credentials or the selected endpoint change. An old response
    /// must never clear another account's badge or reuse its confirmed cursors.
    func reset() {
        generation = UUID()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        pending.removeAll()
        confirmed.removeAll()
        failures.removeAll()
    }

    private func clearPending(_ channelID: String, generation expected: UUID) {
        guard generation == expected else { return }
        tasks[channelID] = nil
        pending[channelID] = nil
    }

    private func drain(_ channelID: String, generation expected: UUID) async {
        defer { clearPending(channelID, generation: expected) }
        while generation == expected, !Task.isCancelled, let cursor = pending[channelID] {
            do {
                try await send(channelID, cursor)
                guard generation == expected, !Task.isCancelled else { return }
                confirmed[channelID] = cursor
                failures[channelID] = nil
                onSuccess(channelID, cursor)
                if pending[channelID] == cursor { return }
                // A newer message arrived during the ACK; send only the newest.
                try await debounce()
            } catch {
                guard generation == expected, !Task.isCancelled,
                      !DiscordRequestCancellation.isCancellation(error) else { return }
                failures[channelID] = (cursor, now().addingTimeInterval(30))
                onFailure(channelID, error)
                return
            }
        }
    }

    static func covers(_ acknowledged: String, _ message: String) -> Bool {
        guard let ack = UInt64(acknowledged), let latest = UInt64(message) else { return false }
        return ack >= latest
    }
}
