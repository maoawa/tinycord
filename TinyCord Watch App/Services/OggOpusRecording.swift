import Foundation

nonisolated enum VoiceRecordingError: LocalizedError {
    case invalidAudio, tooLarge, downloadFailed
    var errorDescription: String? {
        switch self {
        case .invalidAudio: return "This audio format couldn’t be played."
        case .tooLarge: return "This recording is too large to play on the Watch."
        case .downloadFailed: return "Couldn’t download the recording. Tap to retry."
        }
    }
}

/// Discord recordings can be Ogg/Opus, which AVAudioPlayer cannot reliably open
/// on watchOS. Demux one mono/stereo Opus stream and write PCM incrementally.
/// Uses the existing libopus; no new codec or cryptography dependency.
nonisolated enum OggOpusRecording {
    static let maximumBytes = 16 * 1_024 * 1_024
    static let maximumFrames = 48_000 * 60 * 20

    static func isOgg(_ data: Data) -> Bool { data.starts(with: Array("OggS".utf8)) }

    static func convert(_ data: Data, to url: URL) throws {
        guard data.count <= maximumBytes else { throw VoiceRecordingError.tooLarge }
        let bytes = [UInt8](data)
        guard isOgg(data) else { throw VoiceRecordingError.invalidAudio }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        var succeeded = false
        defer {
            try? file.close()
            if !succeeded { try? FileManager.default.removeItem(at: url) }
        }
        try file.write(contentsOf: Data(repeating: 0, count: 44))
        var decoder: OpaquePointer?
        defer { if let decoder { opus_decoder_destroy(decoder) } }
        var offset = 0, packet = [UInt8](), packetIndex = 0
        var serial: UInt32?, nextSequence: UInt32 = 0
        var channels = 0, preSkip = 0, decodedFrames = 0, writtenFrames = 0
        var gain: Float = 1
        var ended = false

        func readLE(_ start: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | UInt64(bytes[start + $1]) << ($1 * 8) }
        }

        while offset < bytes.count {
            try Task.checkCancellation()
            guard !ended, bytes.count - offset >= 27,
                  Array(bytes[offset..<offset + 4]) == Array("OggS".utf8),
                  bytes[offset + 4] == 0 else { throw VoiceRecordingError.invalidAudio }
            let flags = bytes[offset + 5]
            let granule = readLE(offset + 6, 8)
            let pageSerial = UInt32(readLE(offset + 14, 4))
            let sequence = UInt32(readLE(offset + 18, 4))
            if serial == nil {
                guard flags & 2 != 0, sequence == 0 else { throw VoiceRecordingError.invalidAudio }
                serial = pageSerial
            } else if flags & 2 != 0 { throw VoiceRecordingError.invalidAudio }
            guard serial == pageSerial, sequence == nextSequence,
                  (flags & 1 != 0) == !packet.isEmpty else { throw VoiceRecordingError.invalidAudio }
            nextSequence &+= 1
            let segments = Int(bytes[offset + 26])
            let bodyStart = offset + 27 + segments
            guard bodyStart <= bytes.count else { throw VoiceRecordingError.invalidAudio }
            let bodyLength = bytes[offset + 27..<bodyStart].reduce(0) { $0 + Int($1) }
            let pageEnd = bodyStart + bodyLength
            guard pageEnd <= bytes.count else { throw VoiceRecordingError.invalidAudio }
            // Ogg's checksum detects damaged pages before feeding their packets to Opus.
            var crc: UInt32 = 0
            for index in offset..<pageEnd {
                let byte: UInt8 = (offset + 22..<offset + 26).contains(index) ? 0 : bytes[index]
                crc ^= UInt32(byte) << 24
                for _ in 0..<8 { crc = (crc << 1) ^ (crc & 0x80000000 != 0 ? 0x04c11db7 : 0) }
            }
            guard crc == UInt32(readLE(offset + 22, 4)) else { throw VoiceRecordingError.invalidAudio }
            var cursor = bodyStart
            for lace in bytes[offset + 27..<bodyStart] {
                let length = Int(lace)
                packet.append(contentsOf: bytes[cursor..<cursor + length])
                cursor += length
                guard packet.count <= 65_536 else { throw VoiceRecordingError.invalidAudio }
                if length == 255 { continue }
                if packetIndex == 0 {
                    guard packet.count >= 19, packet.starts(with: Array("OpusHead".utf8)),
                          packet[8] > 0, packet[8] < 16,
                          packet[9] == 1 || packet[9] == 2, packet[18] == 0 else {
                        throw VoiceRecordingError.invalidAudio
                    }
                    channels = Int(packet[9])
                    preSkip = Int(packet[10]) | Int(packet[11]) << 8
                    let gainQ8 = Int16(bitPattern: UInt16(packet[16]) | UInt16(packet[17]) << 8)
                    gain = pow(10, Float(gainQ8) / (20 * 256))
                    var error: Int32 = 0
                    decoder = opus_decoder_create(48_000, Int32(channels), &error)
                    guard decoder != nil, error == OPUS_OK else { throw VoiceRecordingError.invalidAudio }
                } else if packetIndex == 1 {
                    guard packet.starts(with: Array("OpusTags".utf8)) else { throw VoiceRecordingError.invalidAudio }
                } else {
                    guard let decoder, !packet.isEmpty else { throw VoiceRecordingError.invalidAudio }
                    var pcm = [Float](repeating: 0, count: 5_760 * channels)
                    let frames = Int(opus_decode_float(decoder, packet, Int32(packet.count), &pcm, 5_760, 0))
                    guard frames > 0 else { throw VoiceRecordingError.invalidAudio }
                    guard decodedFrames + frames <= maximumFrames + preSkip else { throw VoiceRecordingError.tooLarge }
                    let skip = min(frames, max(0, preSkip - decodedFrames))
                    decodedFrames += frames
                    var output = Data(capacity: (frames - skip) * channels * 2)
                    for sample in pcm[(skip * channels)..<(frames * channels)] {
                        let scaled = sample * gain
                        guard scaled.isFinite else { throw VoiceRecordingError.invalidAudio }
                        let value = Int16((max(-1, min(1, scaled)) * 32_767).rounded())
                        let bits = UInt16(bitPattern: value)
                        output.append(UInt8(truncatingIfNeeded: bits))
                        output.append(UInt8(truncatingIfNeeded: bits >> 8))
                    }
                    try file.write(contentsOf: output)
                    writtenFrames += frames - skip
                }
                packet.removeAll(keepingCapacity: true)
                packetIndex += 1
            }
            if flags & 4 != 0 {
                guard packet.isEmpty, packetIndex > 2, granule != UInt64.max,
                      granule >= UInt64(preSkip), granule <= UInt64(decodedFrames) else {
                    throw VoiceRecordingError.invalidAudio
                }
                // Opus has encoder lookahead and end padding. Neither is audible.
                writtenFrames = Int(granule) - preSkip
                ended = true
            }
            offset = pageEnd
        }
        guard ended, writtenFrames > 0 else { throw VoiceRecordingError.invalidAudio }
        let byteCount = writtenFrames * channels * 2
        try file.truncate(atOffset: UInt64(44 + byteCount))
        var header = Data()
        func ascii(_ text: String) { header.append(contentsOf: text.utf8) }
        func little(_ value: Int, _ count: Int) {
            for index in 0..<count { header.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        ascii("RIFF"); little(36 + byteCount, 4); ascii("WAVEfmt "); little(16, 4)
        little(1, 2); little(channels, 2); little(48_000, 4)
        little(48_000 * channels * 2, 4); little(channels * 2, 2); little(16, 2)
        ascii("data"); little(byteCount, 4)
        try file.seek(toOffset: 0)
        try file.write(contentsOf: header)
        succeeded = true
    }
}
