import Foundation
import CryptoKit
import AVFoundation

@main
struct VoiceChecks {
    @MainActor static func main() throws {
        // Watch taps can deliver 100ms chunks at 24kHz mono. Preserve a full
        // second and its pitch while converting and splitting into 20ms packets.
        for (rate, channels, interleaved) in [(24_000.0, 1 as AVAudioChannelCount, false),
                                             (44_100.0, 2, true), (48_000.0, 2, false)] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                       channels: channels, interleaved: interleaved)!
            let converter = try VoiceCaptureConverter(format: format)
            let fifo = VoicePCMBuffer()
            var all: [Float] = []
            var packetCount = 0
            for chunk in 0..<10 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(rate / 10))!
                buffer.frameLength = buffer.frameCapacity
                let planes = buffer.floatChannelData!
                for frame in 0..<Int(buffer.frameLength) {
                    for channel in 0..<Int(channels) {
                        let frequency = channel == 0 ? 440.0 : 880.0
                        planes[interleaved ? 0 : channel][frame * buffer.stride + (interleaved ? channel : 0)] = Float(0.2 * sin(2 * .pi * frequency * Double(chunk * Int(buffer.frameLength) + frame) / rate))
                    }
                }
                let converted = converter.convert(buffer)
                all += converted
                fifo.append(converted)
                while fifo.take(frames: 960) != nil { packetCount += 1 }
            }
            // The streaming resampler retains its filter tail (128 frames for
            // the 24kHz case) until more input arrives; allow under 5.4ms, not
            // the hundreds of milliseconds previously lost by the packet cap.
            precondition(abs(all.count / 2 - 48_000) < 256, "Capture must retain one second within the resampler filter delay: rate=\(rate), frames=\(all.count / 2)")
            precondition(packetCount >= 49 && packetCount <= 50, "Do not drop all but three frames from each tap")
            for channel in 0..<2 {
                var crossings = 0
                for frame in 961..<(all.count / 2) {
                    if all[(frame - 1) * 2 + channel] <= 0 && all[frame * 2 + channel] > 0 { crossings += 1 }
                }
                let frequency = channel == 0 || channels == 1 ? 440 : 880
                let expected = (all.count / 2 - 960) * frequency / 48_000
                precondition(abs(crossings - expected) < 4, "PCM conversion must preserve pitch and channel layout: rate=\(rate), channel=\(channel), crossings=\(crossings), expected=\(expected)")
            }
        }
        // The renderer must consume exact sample counts irrespective of packet
        // duration, preserve planar channels and produce silence on underrun.
        let playback = VoicePCMBuffer(capacityFrames: 6_000)
        let stereo: [Float] = (0..<2_880).flatMap { frame in [Float(frame) / 10_000, -Float(frame) / 10_000] }
        playback.append(stereo)
        let renderFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        var rendered = 0
        for frames in [128, 512, 960, 1_280, 960] {
            let buffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: UInt32(frames))!
            buffer.frameLength = buffer.frameCapacity
            playback.render(frames: frames, into: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
            for frame in 0..<frames {
                for channel in 0..<2 {
                    let expected: Float = rendered + frame < 2_880 ? stereo[(rendered + frame) * 2 + channel] : 0
                    precondition(buffer.floatChannelData![channel][frame] == expected)
                }
            }
            rendered += frames
        }
        precondition(playback.bufferedFrames == 0)
        let offlineFIFO = VoicePCMBuffer(capacityFrames: 48_000)
        let tone: [Float] = (0..<48_000).flatMap { frame in
            let value = Float(0.2 * sin(2 * .pi * 440 * Double(frame) / 48_000))
            return [value, value]
        }
        offlineFIFO.append(tone)
        let engine = AVAudioEngine()
        let node = AVAudioSourceNode(format: renderFormat) { _, _, frames, buffers in
            offlineFIFO.render(frames: Int(frames), into: UnsafeMutableAudioBufferListPointer(buffers))
            return noErr
        }
        let deviceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: renderFormat)
        try engine.enableManualRenderingMode(.offline, format: deviceFormat, maximumFrameCount: 2_400)
        try engine.start()
        var deviceSamples: [Float] = []
        for _ in 0..<10 {
            let output = AVAudioPCMBuffer(pcmFormat: deviceFormat, frameCapacity: 2_400)!
            let status = try engine.renderOffline(2_400, to: output)
            precondition(status == .success)
            deviceSamples += Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        }
        engine.stop()
        var deviceCrossings = 0
        for index in 1..<deviceSamples.count {
            if deviceSamples[index - 1] <= 0 && deviceSamples[index] > 0 { deviceCrossings += 1 }
        }
        precondition(deviceSamples.count == 24_000 && abs(deviceCrossings - 440) < 4,
                     "48kHz stereo source must play at the correct pitch on 24kHz mono output")
        precondition(deviceSamples.allSatisfy { $0.isFinite && abs($0) < 0.5 })
        print("PASS: 24/44.1/48kHz capture preserves duration, pitch and channels; 100ms taps retain all packets; renderer follows sample counts and silences underruns.")
        print("PASS: actual offline audio engine renders 48kHz stereo as 24kHz mono with unchanged pitch and duration.")
        var opusError: Int32 = 0
        let durationEncoder = opus_encoder_create(48_000, 2, OPUS_APPLICATION_VOIP, &opusError)!
        defer { opus_encoder_destroy(durationEncoder) }
        let durationDecoder = try VoiceOpus()
        for frames in [480, 960, 2_880] {
            let input = Array(tone.prefix(frames * 2))
            var packet = [UInt8](repeating: 0, count: 4_000)
            let length = opus_encode_float(durationEncoder, input, Int32(frames), &packet, Int32(packet.count))
            precondition(length > 0)
            let pcm = durationDecoder.decode(Data(packet.prefix(Int(length))))!
            precondition(pcm.count == frames * 2)
            precondition(pcm.allSatisfy { $0.isFinite && abs($0) < 0.5 })
        }
        print("PASS: 10/20/60ms Opus packets retain their decoded duration and bounded sample levels.")
        // Series 7 uses arm64_32: a current Unix-millisecond timestamp traps if
        // narrowed to Int. Verify its width and exact value through the wire JSON.
        for milliseconds: Int64 in [1_789_344_000_000, 2_147_483_648_000] {
            precondition(Int32(exactly: milliseconds) == nil)
            let heartbeat = VoiceHeartbeat.payload(at: Date(timeIntervalSince1970: Double(milliseconds) / 1_000), sequence: -1)
            precondition(heartbeat["t"] is Int64)
            let encoded = try JSONSerialization.data(withJSONObject: ["op": 3, "d": heartbeat])
            let decoded = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            let data = decoded["d"] as! [String: Any]
            precondition((data["t"] as? NSNumber)?.int64Value == milliseconds)
            precondition(data["seq_ack"] as? Int == -1)
        }
        print("PASS: voice heartbeat preserves 64-bit millisecond timestamps through JSON for arm64_32 Watches.")
        // Inject Audio Unit failures without touching a microphone or a recipient.
        var audioEvents: [String] = []
        let processed = try VoiceAudioStartup.start(attempt: { enabled in
            audioEvents.append(enabled ? "processed" : "standard")
        }, reset: { audioEvents.append("reset") }, onFallback: { _ in audioEvents.append("fallback") })
        precondition(processed && audioEvents == ["processed"])
        for stage in [VoiceAudioStartFailure.Stage.voiceProcessing, .engineStart] {
            audioEvents = []
            let result = try VoiceAudioStartup.start(attempt: { enabled in
                audioEvents.append(enabled ? "processed" : "standard")
                if enabled { throw VoiceAudioStartFailure(stage, NSError(domain: NSOSStatusErrorDomain, code: -10868)) }
            }, reset: { audioEvents.append("reset") }, onFallback: { failure in
                precondition(failure.code == -10868)
                audioEvents.append("fallback")
            })
            precondition(!result && audioEvents == ["processed", "reset", "fallback", "standard"])
        }
        audioEvents = []
        do {
            _ = try VoiceAudioStartup.start(attempt: { enabled in
                audioEvents.append(enabled ? "processed" : "standard")
                throw VoiceAudioStartFailure(.engineStart, NSError(domain: NSOSStatusErrorDomain, code: enabled ? -10868 : -50,
                    userInfo: [NSLocalizedDescriptionKey: "private framework payload"]))
            }, reset: { audioEvents.append("reset") }, onFallback: { _ in audioEvents.append("fallback") })
            preconditionFailure("Both failed audio attempts must propagate failure")
        } catch let failure as VoiceAudioStartFailure {
            precondition(failure.code == -50)
            precondition(failure.errorDescription!.contains("audio engine"))
            precondition(!failure.errorDescription!.contains("private framework payload"))
        }
        precondition(audioEvents == ["processed", "reset", "fallback", "standard", "reset"])
        audioEvents = []
        do {
            _ = try VoiceAudioStartup.start(attempt: { _ in
                audioEvents.append("attempt")
                throw VoiceCallError.message("No microphone route")
            }, reset: { audioEvents.append("reset") }, onFallback: { _ in preconditionFailure("Do not retry a missing route") })
            preconditionFailure("Missing route must fail")
        } catch is VoiceCallError {}
        precondition(audioEvents == ["attempt", "reset"])
        print("PASS: audio startup fallback, fresh-graph cleanup, bounded retries and redacted error diagnostics.")
        func bytes(_ call: (UnsafeMutablePointer<Int>) -> UnsafeMutablePointer<UInt8>?) -> Data {
            var length = 0
            let pointer = call(&length)!
            defer { voice_test_free(pointer) }
            return Data(bytes: pointer, count: length)
        }
        let sender = voice_test_sender_create(123456)!
        defer { voice_test_sender_destroy(sender) }
        let alice = try VoiceDAVE(channelID: "123456", selfID: "1001", peerID: "1002")
        let bob = try VoiceDAVE(channelID: "123456", selfID: "1002", peerID: "1001")
        // External-sender and session-description events are valid in either order.
        let external = bytes { voice_test_external(sender, $0) }
        _ = try alice.consume(op: 25, data: external, ssrc: 111)
        let alicePackage = try alice.configure(version: 1)
        let bobPackage = try bob.configure(version: 1)
        precondition(alicePackage != nil && bobPackage == nil)
        let package = try bob.consume(op: 25, data: external, ssrc: 222).binary[0].dropFirst()
        let proposal = bytes { out in package.withUnsafeBytes {
            voice_test_proposal(sender, $0.bindMemory(to: UInt8.self).baseAddress, package.count, out)
        } }
        let commitWelcome = try alice.consume(op: 27, data: proposal, ssrc: 111).binary[0].dropFirst()
        let commit = bytes { out in commitWelcome.withUnsafeBytes {
            voice_test_split(sender, $0.bindMemory(to: UInt8.self).baseAddress, commitWelcome.count, 0, out)
        } }
        let welcome = bytes { out in commitWelcome.withUnsafeBytes {
            voice_test_split(sender, $0.bindMemory(to: UInt8.self).baseAddress, commitWelcome.count, 1, out)
        } }
        var transition = Data(); transition.appendVoice(UInt16(7))
        _ = try alice.consume(op: 29, data: transition + commit, ssrc: 111)
        _ = try bob.consume(op: 30, data: transition + welcome, ssrc: 222)
        precondition(!alice.ready && !bob.ready)
        precondition(alice.encrypt(Data([1]), ssrc: 111) == nil)
        try alice.execute(7); try bob.execute(7)
        let codec = try VoiceOpus()
        let pcm: [Float] = (0..<1920).map { Float(sin(Double($0 / 2) * 2 * .pi * 440 / 48000) * 0.2) }
        let encoded = codec.encode(pcm)!
        let encrypted = alice.encrypt(encoded, ssrc: 111)!
        precondition(encrypted != encoded)
        let transport = try VoicePacketCipher(key: Data(repeating: 17, count: 32), ssrc: 111)
        let packet = try transport.seal(encrypted)
        let opened = try transport.open(packet)!
        precondition(opened.ssrc == 111)
        let decoded = bob.decrypt(opened.frame, user: "1001")!
        precondition(decoded == encoded)
        precondition(codec.decode(decoded)?.count == 1920)
        precondition(bob.decrypt(opened.frame, user: "9999") == nil)
        var tampered = packet; tampered[13] ^= 1
        do { _ = try transport.open(tampered); preconditionFailure("Tampered transport accepted") } catch {}
        do {
            _ = try VoicePacketCipher(key: Data(repeating: 8, count: 32), ssrc: 111, mode: "aead_xchacha20_poly1305_rtpsize")
            preconditionFailure("Removed XChaCha mode must be rejected")
        } catch is VoiceCallError {}
        // Discord RTP-size mode authenticates CSRCs and the extension preamble,
        // then encrypts extension data together with the media payload.
        var header = Data([0x91, 0x78])
        header.appendVoice(UInt16(22)); header.appendVoice(UInt32(960)); header.appendVoice(UInt32(111))
        header.appendVoice(UInt32(333)); header.appendVoice(UInt16(0xbede)); header.appendVoice(UInt16(1))
        var nonceSuffix = Data(); nonceSuffix.appendVoice(UInt32(77))
        let nonce = try AES.GCM.Nonce(data: nonceSuffix + Data(repeating: 0, count: 8))
        let extensionBody = Data([0x10, 0x7f, 0, 0])
        let extensionBox = try AES.GCM.seal(extensionBody + encrypted,
            using: SymmetricKey(data: Data(repeating: 17, count: 32)), nonce: nonce, authenticating: header)
        let extensionPacket = header + extensionBox.ciphertext + extensionBox.tag + nonceSuffix
        let extensionOpened = try transport.open(extensionPacket)
        precondition(extensionOpened?.frame == encrypted)
        for length in 0..<32 {
            let short = try transport.open(Data(repeating: 0, count: length))
            precondition(short == nil)
        }
        var damaged = alice.encrypt(encoded, ssrc: 111)!; damaged[0] ^= 1
        precondition(bob.decrypt(damaged, user: "1001") == nil)
        let back = bob.encrypt(encoded, ssrc: 222)!
        precondition(alice.decrypt(back, user: "1002") == encoded)
        do { _ = try alice.configure(version: 0); preconditionFailure("Plaintext downgrade accepted") } catch {}

        var jitter = VoiceJitterBuffer()
        let timingCipher = try VoicePacketCipher(key: Data(repeating: 7, count: 32), ssrc: 99)
        let beforeGap = try timingCipher.seal(Data([1]))
        timingCipher.advanceAudioClock(slots: 3)
        let afterGap = try timingCipher.seal(Data([2]))
        precondition(afterGap.voiceUInt32(4) &- beforeGap.voiceUInt32(4) == 3_840)
        precondition(afterGap.voiceUInt16(2) &- beforeGap.voiceUInt16(2) == 1)
        // A muted or dropped slot advances media time without pretending that
        // another RTP packet was sent.
        jitter.insert(sequence: 65535, frame: Data([1]))
        jitter.insert(sequence: 1, frame: Data([3]))
        jitter.insert(sequence: 0, frame: Data([2]))
        for _ in 0..<3 { precondition(!jitter.pop().play) }
        for expected: UInt8 in [1, 2, 3] { precondition(jitter.pop().frame == Data([expected])) }
        jitter.insert(sequence: 0, frame: Data([9])) // late replay
        precondition(jitter.pop().frame == nil)
        precondition(VoiceEndpoint.url("test.discord.media:443") != nil)
        for invalid in ["discord.media.evil.test", "user@voice.discord.media", "voice.discord.media/path", "voice.discord.media?token=x"] {
            precondition(VoiceEndpoint.url(invalid) == nil)
        }
        print("PASS: real two-member MLS handshake, transition gating, bidirectional DAVE/Opus/AES-GCM audio, tamper rejection, jitter wraparound and endpoint isolation.")
    }
}
