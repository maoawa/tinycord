import Foundation
import CryptoKit

/// Unix milliseconds exceed a 32-bit Int on arm64_32 Apple Watches.
/// Keep the timestamp wide all the way through Foundation's JSON encoder.
enum VoiceHeartbeat {
    static func payload(at date: Date = Date(), sequence: Int) -> [String: Any] {
        ["t": Int64(date.timeIntervalSince1970 * 1_000), "seq_ack": sequence]
    }
}

enum VoiceCallError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

extension Data {
    func voiceUInt16(_ offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) << 8 | UInt16(self[startIndex + offset + 1])
    }
    func voiceUInt32(_ offset: Int) -> UInt32 {
        UInt32(voiceUInt16(offset)) << 16 | UInt32(voiceUInt16(offset + 2))
    }
    mutating func appendVoice<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}

/// Discord's transport encryption wraps an already DAVE-encrypted Opus frame.
/// AES-GCM only; fail when a server does not support this transport.
final class VoicePacketCipher {
    private let key: SymmetricKey
    let mode: String
    static let aesMode = "aead_aes256_gcm_rtpsize"
    private var nonceCounter: UInt32 = 0
    private var sequence: UInt16 = .random(in: .min ... .max)
    private var timestamp: UInt32 = .random(in: .min ... .max)
    let ssrc: UInt32

    init(key: Data, ssrc: UInt32, mode: String = VoicePacketCipher.aesMode) throws {
        guard key.count == 32, mode == Self.aesMode else { throw VoiceCallError.message("Invalid voice encryption key or mode.") }
        self.key = SymmetricKey(data: key)
        self.mode = mode
        self.ssrc = ssrc
    }

    func advanceAudioClock(slots: UInt32 = 1) { timestamp &+= 960 &* slots }

    func seal(_ frame: Data) throws -> Data {
        guard nonceCounter < .max else { throw VoiceCallError.message("Voice key expired. Start a new call.") }
        var header = Data([0x80, 0x78])
        header.appendVoice(sequence)
        header.appendVoice(timestamp)
        header.appendVoice(ssrc)
        var suffix = Data(); suffix.appendVoice(nonceCounter)
        let ciphertext: Data
        do {
            let nonce = try AES.GCM.Nonce(data: suffix + Data(repeating: 0, count: 8))
            let box = try AES.GCM.seal(frame, using: key, nonce: nonce, authenticating: header)
            ciphertext = box.ciphertext + box.tag
        }
        nonceCounter += 1; sequence &+= 1; timestamp &+= 960
        return header + ciphertext + suffix
    }

    func open(_ packet: Data) throws -> (ssrc: UInt32, sequence: UInt16, frame: Data)? {
        guard packet.count >= 32, packet[0] >> 6 == 2,
              packet[1] & 0x7f == 0x78 else { return nil } // Ignore RTCP and other payloads.
        var headerSize = 12 + Int(packet[0] & 0x0f) * 4
        var extensionSize = 0
        if packet[0] & 0x10 != 0 {
            guard packet.count >= headerSize + 24 else { return nil }
            extensionSize = Int(packet.voiceUInt16(headerSize + 2)) * 4
            headerSize += 4
        }
        guard packet.count >= headerSize + 20 else { return nil }
        var plain: Data
        do {
            let nonce = try AES.GCM.Nonce(data: packet.suffix(4) + Data(repeating: 0, count: 8))
            let box = try AES.GCM.SealedBox(nonce: nonce,
                ciphertext: packet[headerSize ..< packet.count - 20],
                tag: packet[(packet.count - 20) ..< packet.count - 4])
            plain = try AES.GCM.open(box, using: key, authenticating: packet.prefix(headerSize))
        }
        guard extensionSize <= plain.count else { return nil }
        plain = Data(plain.dropFirst(extensionSize))
        if packet[0] & 0x20 != 0 {
            guard let padding = plain.last, padding > 0, Int(padding) <= plain.count else { return nil }
            plain = Data(plain.dropLast(Int(padding)))
        }
        return (packet.voiceUInt32(8), packet.voiceUInt16(2), plain)
    }


}

/// A bounded 60ms reorder buffer. Late/duplicate packets are discarded; a
/// missing frame becomes Opus packet-loss concealment at the playout deadline.
struct VoiceJitterBuffer {
    private var next: UInt16?
    private var packets: [UInt16: Data] = [:]
    private var warming = 3
    private var misses = 0
    mutating func insert(sequence: UInt16, frame: Data) {
        if next == nil { next = sequence }
        guard let expected = next else { return }
        let distance = Int(Int16(bitPattern: sequence &- expected))
        guard distance >= 0 else { return }
        if distance > 25 { packets.removeAll(); next = sequence; warming = 3 }
        guard packets.count < 25 else { return }
        packets[sequence] = frame
    }
    mutating func pop() -> (play: Bool, frame: Data?) {
        guard let expected = next else { return (false, nil) }
        if warming > 0 { warming -= 1; return (false, nil) }
        let frame = packets.removeValue(forKey: expected)
        next = expected &+ 1
        misses = frame == nil ? misses + 1 : 0
        if misses > 10 { self = VoiceJitterBuffer(); return (false, nil) }
        return (true, frame)
    }
}

enum VoiceEndpoint {
    /// Voice endpoints come from Discord, independently of the custom main
    /// Gateway. Do not forward a voice token to arbitrary Gateway-supplied hosts.
    static func url(_ endpoint: String) -> URL? {
        guard var parts = URLComponents(string: "wss://" + endpoint),
              let host = parts.host?.lowercased(),
              host.hasSuffix(".discord.media") || host.hasSuffix(".discord.gg"),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", parts.query == nil,
              parts.port == nil || (1...65535).contains(parts.port!) else { return nil }
        parts.queryItems = [URLQueryItem(name: "v", value: "8")]
        return parts.url
    }
}
