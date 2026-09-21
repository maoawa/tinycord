import Foundation

private final class ReadStateProtocol: URLProtocol, @unchecked Sendable {
    static var status = 204
    static var networkFailure = false
    static var networkCode: URLError.Code = .notConnectedToInternet
    static var retryAfter: String?
    static var requestCount = 0
    static var received: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        Self.received = request
        if Self.networkFailure {
            client?.urlProtocol(self, didFailWithError: URLError(Self.networkCode))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: Self.retryAfter.map { ["Retry-After": $0] })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if Self.status == 200 {
            client?.urlProtocol(self, didLoad: Data("{\"token\":null}".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct ReadStateChecks {
    @MainActor
    static func main() async throws {
        let message = "123456789012345678"
        let read = try DiscordReadStateRequest(channelID: "100", latestMessageID: message, unread: false)
        let unread = try DiscordReadStateRequest(channelID: "100", latestMessageID: message, unread: true)
        precondition(read.path == "/channels/100/messages/123456789012345678/ack")
        precondition(unread.path == "/channels/100/messages/123456789012345677/ack")
        let readBody = try JSONSerialization.jsonObject(with: read.body) as! [String: Any]
        let unreadBody = try JSONSerialization.jsonObject(with: unread.body) as! [String: Any]
        precondition(readBody["token"] is NSNull)
        precondition(unreadBody["manual"] as? Bool == true)
        precondition(unreadBody["mention_count"] == nil)
        precondition(unreadBody["token"] == nil)
        for invalid in ["0", "", "not-an-id", "../messages", "18446744073709551616"] {
            do {
                _ = try DiscordReadStateRequest(channelID: "100", latestMessageID: invalid, unread: true)
                preconditionFailure("Invalid cursor accepted")
            } catch {}
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadStateProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://discord.example.com/api/v10" + unread.path)!)
        request.httpMethod = "POST"
        request.httpBody = unread.body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for status in [200, 204] {
            ReadStateProtocol.status = status
            try await DiscordReadStateHTTP.send(request, session: session)
            precondition(ReadStateProtocol.received?.httpMethod == "POST")
            precondition(ReadStateProtocol.received?.url?.path.hasSuffix("/123456789012345677/ack") == true)
        }
        for status in [401, 403, 429, 500, 502] {
            ReadStateProtocol.status = status
            do {
                try await DiscordReadStateHTTP.send(request, session: session)
                preconditionFailure("HTTP \(status) accepted as success")
            } catch {}
        }
        ReadStateProtocol.networkFailure = true
        do {
            try await DiscordReadStateHTTP.send(request, session: session)
            preconditionFailure("Offline mutation accepted")
        } catch {}
        ReadStateProtocol.networkCode = .cancelled
        let beforeCancellation = ReadStateProtocol.requestCount
        do {
            try await DiscordReadStateHTTP.send(request, session: session)
            preconditionFailure("Cancelled request accepted")
        } catch {
            precondition(error is CancellationError)
        }
        precondition(ReadStateProtocol.requestCount == beforeCancellation + 1, "Cancellation must not retry")
        let wrapped = NSError(domain: "Transport", code: 1,
                              userInfo: [NSUnderlyingErrorKey: URLError(.cancelled)])
        precondition(DiscordRequestCancellation.isCancellation(wrapped))
        precondition(!DiscordRequestCancellation.isCancellation(URLError(.notConnectedToInternet)))

        for code in [URLError.Code.timedOut, .networkConnectionLost] {
            ReadStateProtocol.networkCode = code
            ReadStateProtocol.networkFailure = true
            ReadStateProtocol.status = 204
            let before = ReadStateProtocol.requestCount
            var delays: [TimeInterval] = []
            try await DiscordReadStateHTTP.send(request, session: session, sleep: { delay in
                delays.append(delay)
                ReadStateProtocol.networkFailure = false
            })
            precondition(delays == [0.75] && ReadStateProtocol.requestCount == before + 2)
        }
        ReadStateProtocol.status = 429
        ReadStateProtocol.retryAfter = "0.5"
        var delays: [TimeInterval] = []
        try await DiscordReadStateHTTP.send(request, session: session, sleep: { delay in
            delays.append(delay)
            ReadStateProtocol.status = 204
        })
        precondition(delays == [0.75], "Short rate limit should be honored")
        for retry in ["-1", "nan", "20", "0"] {
            ReadStateProtocol.status = 429
            ReadStateProtocol.retryAfter = retry
            let before = ReadStateProtocol.requestCount
            var sleeps = 0
            do {
                try await DiscordReadStateHTTP.send(request, session: session, sleep: { _ in sleeps += 1 })
                preconditionFailure("Persistent rate limit accepted")
            } catch {}
            precondition(sleeps == (retry == "0" ? 1 : 0), "Only one bounded rate-limit retry")
            precondition(ReadStateProtocol.requestCount - before == (retry == "0" ? 2 : 1))
        }
        ReadStateProtocol.retryAfter = "1"
        let beforeSleepCancellation = ReadStateProtocol.requestCount
        do {
            try await DiscordReadStateHTTP.send(request, session: session, sleep: { _ in throw CancellationError() })
            preconditionFailure("Cancelled backoff accepted")
        } catch { precondition(error is CancellationError) }
        precondition(ReadStateProtocol.requestCount == beforeSleepCancellation + 1)

        await acknowledgementLifecycleChecks()
        print("PASS: read-state HTTP, cancellation, bounded retries, coalescing, confirmed cursors, account reset, and unread races.")
    }

    @MainActor
    static func eventually(_ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Timed out waiting for acknowledgement test")
    }

    @MainActor
    static func acknowledgementLifecycleChecks() async {
        let debounce = ReadStateGate()
        let response = ReadStateGate()
        var sent: [String] = [], confirmed: [String] = []
        var badgeUnread = true
        var latest = "101"
        let acknowledgements = DiscordReadAcknowledgements(send: { _, cursor in
            sent.append(cursor)
            if sent.count == 1 { await response.wait() }
        }, onSuccess: { _, cursor in
            confirmed.append(cursor)
            badgeUnread = !DiscordReadAcknowledgements.covers(cursor, latest)
        }, onFailure: { _, _ in preconditionFailure("Unexpected failure") }, debounce: { await debounce.wait() })
        let navigation = Task {
            acknowledgements.enqueue(channelID: "100", messageID: "100")
            acknowledgements.enqueue(channelID: "100", messageID: "101")
            acknowledgements.enqueue(channelID: "100", messageID: "100")
        }
        await navigation.value
        navigation.cancel()
        await eventually { debounce.waiting }
        debounce.resume()
        await eventually { response.waiting }
        precondition(sent == ["101"] && confirmed.isEmpty && badgeUnread)
        latest = "103"
        acknowledgements.enqueue(channelID: "100", messageID: "102")
        acknowledgements.enqueue(channelID: "100", messageID: "103")
        response.resume()
        await eventually { debounce.waiting }
        precondition(confirmed == ["101"] && badgeUnread, "A newer message must keep its unread badge")
        debounce.resume()
        await eventually { confirmed == ["101", "103"] }
        precondition(!badgeUnread && sent == ["101", "103"])
        acknowledgements.enqueue(channelID: "100", messageID: "103")
        acknowledgements.enqueue(channelID: "100", messageID: "102")
        acknowledgements.enqueue(channelID: "100", messageID: "temp_123")
        for _ in 0..<10 { await Task.yield() }
        precondition(!debounce.waiting && sent.count == 2, "Reopening confirmed history must not send another ACK")
        acknowledgements.reset()

        var attempts = 0, successes = 0, errors = 0
        let cancellations = DiscordReadAcknowledgements(send: { _, _ in
            attempts += 1
            if attempts == 1 { throw URLError(.cancelled) }
        }, onSuccess: { _, _ in successes += 1 }, onFailure: { _, _ in errors += 1 }, debounce: {})
        cancellations.enqueue(channelID: "100", messageID: "200")
        await eventually { attempts == 1 }
        cancellations.enqueue(channelID: "100", messageID: "200")
        await eventually { successes == 1 }
        precondition(errors == 0 && attempts == 2, "Cancellation stays silent and leaves cursor retryable")
        cancellations.reset()

        let staleResponse = ReadStateGate()
        var oldConfirmed = 0
        let resettable = DiscordReadAcknowledgements(send: { _, _ in await staleResponse.wait() },
            onSuccess: { _, _ in oldConfirmed += 1 }, onFailure: { _, _ in errors += 1 }, debounce: {})
        resettable.enqueue(channelID: "100", messageID: "300")
        await eventually { staleResponse.waiting }
        resettable.reset()
        staleResponse.resume()
        for _ in 0..<10 { await Task.yield() }
        precondition(oldConfirmed == 0 && errors == 0, "Response from previous account must be discarded")
        resettable.enqueue(channelID: "100", messageID: "300")
        await eventually { staleResponse.waiting }
        staleResponse.resume()
        await eventually { oldConfirmed == 1 }
        resettable.reset()

        var date = Date(timeIntervalSince1970: 1_000)
        var failedAttempts = 0, visibleErrors = 0
        let failures = DiscordReadAcknowledgements(send: { _, _ in
            failedAttempts += 1
            throw URLError(.notConnectedToInternet)
        }, onSuccess: { _, _ in preconditionFailure("Failed ACK confirmed") },
           onFailure: { _, _ in visibleErrors += 1 }, debounce: {}, now: { date })
        failures.enqueue(channelID: "100", messageID: "400")
        await eventually { visibleErrors == 1 }
        failures.enqueue(channelID: "100", messageID: "400")
        for _ in 0..<10 { await Task.yield() }
        precondition(failedAttempts == 1, "Repeated view updates must not flood errors")
        date.addTimeInterval(31)
        failures.enqueue(channelID: "100", messageID: "400")
        await eventually { visibleErrors == 2 }
        failures.reset()
    }
}

@MainActor
private final class ReadStateGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
