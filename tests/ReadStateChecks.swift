import Foundation

private final class ReadStateProtocol: URLProtocol, @unchecked Sendable {
    static var status = 204
    static var networkFailure = false
    static var received: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.received = request
        if Self.networkFailure {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
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
        print("Discord read/unread cursor, ACK payload, 200/204, auth/rate-limit/server errors and offline checks passed.")
    }
}
