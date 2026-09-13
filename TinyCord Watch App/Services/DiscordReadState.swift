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
    static func send(_ request: URLRequest, session: URLSession) async throws {
        let (_, response) = try await session.data(for: request)
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
            throw DiscordReadStateError(message: "Discord rate limited the change. Try again shortly.")
        default:
            throw DiscordReadStateError(message: "Read-state update failed (HTTP \(http.statusCode)).")
        }
    }
}
