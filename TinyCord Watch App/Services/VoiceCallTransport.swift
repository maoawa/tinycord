import Foundation
import Network
import OSLog

private final class VoiceURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Created ONLY from CallKit's didActivate callback. No presence or message
/// publishers, idle connections, resume loops, or background keepalive leases.
@MainActor
final class VoiceCallTransport {
    private let channelID: String
    private let selfID: String
    private let peerID: String
    private var token: String?
    private let profile: EndpointProfile
    private let session: URLSession
    private var mainSocket: URLSessionWebSocketTask?
    private var voiceSocket: URLSessionWebSocketTask?
    private var tasks: [Task<Void, Never>] = []
    private var udp: NWConnection?
    private var stopped = false
    private var mainSequence: Int?
    private var voiceSequence = -1
    private var mainAck = true
    private var voiceAck = true
    private var voiceSessionID: String?
    private var voiceServer: (URL, String)?
    private var ssrc: UInt32 = 0
    private var transportMode = VoicePacketCipher.aesMode
    private var cipher: VoicePacketCipher?
    private let dave: VoiceDAVE
    private let opus: VoiceOpus
    private let audio = VoiceAudioIO()
    private var jitter = VoiceJitterBuffer()
    private var remoteSSRC: UInt32?
    private var discoveryDone = false
    private var ringSent = false
    private var connected = false
    private var speakingReady = false
    private var audioReady = false
    private let setupLogger = Logger(subsystem: "com.candyrect.tinycord", category: "VoiceSetup")
    private var waitingTransitions: Set<UInt16> = []
    private var mainHelloReceived = false
    private var voiceHelloReceived = false
    private var outboundFrames = 0
    private let capture = VoicePCMBuffer(capacityFrames: 9_600)
    var muted = false
    var onState: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onEnd: ((String?) -> Void)?
    var onAudioNotice: ((String) -> Void)?

    init(channelID: String, selfID: String, peerID: String, token: String, profile: EndpointProfile) throws {
        self.channelID = channelID; self.selfID = selfID; self.peerID = peerID
        self.token = token; self.profile = profile
        dave = try VoiceDAVE(channelID: channelID, selfID: selfID, peerID: peerID)
        opus = try VoiceOpus()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config, delegate: VoiceURLSessionDelegate(), delegateQueue: nil)
    }

    func start() throws {
        guard mainSocket == nil, !stopped, let url = profile.callGatewayURL else {
            throw VoiceCallError.message("Configure a valid WSS call Gateway.")
        }
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 16 * 1_024 * 1_024
        mainSocket = socket; socket.resume()
        onState?("Connecting to call Gateway…")
        receive(socket, voice: false)
        tasks.append(Task { [weak self] in
            guard let self, !self.stopped else { return }
            let capture = self.capture
            do {
                let audioStart = ProcessInfo.processInfo.systemUptime
                let processed = try await self.audio.start { capture.append($0) }
                guard !self.stopped, !Task.isCancelled else { self.audio.stop(); return }
                self.audioReady = true
                let elapsed = ProcessInfo.processInfo.systemUptime - audioStart
                self.setupLogger.notice("Audio setup completed in \(elapsed, privacy: .public)s")
                if !processed {
                    self.onAudioNotice?("Use headphones to avoid echo. Voice processing is unavailable on this audio route.")
                }
                self.checkConnected()
            } catch {
                guard !self.stopped, !Task.isCancelled else { return }
                self.fail((error as? VoiceCallError)?.errorDescription
                    ?? (error as? VoiceAudioStartFailure)?.errorDescription ?? "Could not start call audio.")
            }
        })
        tasks.append(Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self, !self.connected else { return }
            self.fail("Call timed out before encrypted audio connected.")
        })
        tasks.append(Task { [weak self] in
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                deadline += .milliseconds(20)
                do { try await clock.sleep(until: deadline) } catch { return }
                guard let self, !self.stopped else { return }
                // Never catch up with a burst after executor suspension.
                if clock.now > deadline + .milliseconds(20) {
                    let lag = deadline.duration(to: clock.now).components
                    let skipped = lag.seconds * 50 + lag.attoseconds / 20_000_000_000_000_000
                    self.cipher?.advanceAudioClock(slots: UInt32(truncatingIfNeeded: skipped))
                    self.capture.clear()
                    deadline = clock.now
                }
                if self.connected, self.speakingReady {
                    if let pcm = self.capture.take(frames: 960), !self.muted, self.outboundFrames < 3 {
                        self.sendAudio(pcm)
                    } else {
                        self.cipher?.advanceAudioClock()
                    }
                } else { self.capture.clear() }
                // The hardware render callback consumes PCM at 48 kHz. Fill a
                // short runway by duration; a 60ms Opus packet is not a 20ms tick.
                for _ in 0..<6 where self.audioReady && self.audio.bufferedPlaybackFrames < 2_880 {
                    let next = self.jitter.pop()
                    guard next.play else { break }
                    if let pcm = self.opus.decode(next.frame) { self.audio.play(pcm) }
                }
            }
        })
    }

    private func receive(_ socket: URLSessionWebSocketTask, voice: Bool) {
        tasks.append(Task { [weak self, weak socket] in
            guard let socket else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, !self.stopped else { return }
                    switch message {
                    case .string(let text):
                        guard let bytes = text.data(using: .utf8),
                              let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { continue }
                        if voice { try await self.voiceEvent(json) } else { try await self.mainEvent(json) }
                    case .data(let bytes):
                        if voice, bytes.count >= 3 {
                            self.voiceSequence = Int(bytes.voiceUInt16(0))
                            let result = try self.dave.consume(op: Int(bytes[2]), data: Data(bytes.dropFirst(3)), ssrc: self.ssrc)
                            // Invalid-transition notification must precede the replacement key package.
                            if let (op, id) = result.json { try await self.send(socket, op: op, data: ["transition_id": Int(id)]) }
                            for packet in result.binary { try await socket.send(.data(packet)) }
                            self.checkConnected()
                        }
                    @unknown default: break
                    }
                }
            } catch {
                guard let self, !self.stopped, !Task.isCancelled else { return }
                let detail = (error as? VoiceCallError)?.errorDescription
                self.fail(detail ?? (voice ? "Voice Gateway disconnected. Start another call." : "Call Gateway disconnected. Start another call."))
            }
        })
    }

    private func send(_ socket: URLSessionWebSocketTask, op: Int, data: Any) async throws {
        guard !stopped else { throw CancellationError() }
        let bytes = try JSONSerialization.data(withJSONObject: ["op": op, "d": data])
        try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
    }

    private func heartbeat(_ socket: URLSessionWebSocketTask, milliseconds: Double, voice: Bool) throws {
        guard milliseconds.isFinite, milliseconds >= 100, milliseconds <= 120_000 else {
            throw VoiceCallError.message("Invalid Gateway heartbeat interval.")
        }
        tasks.append(Task { [weak self, weak socket] in
            // Send immediately, then require an ACK before the next heartbeat.
            while !Task.isCancelled {
                guard let self, let socket, !self.stopped else { return }
                do {
                    guard voice ? self.voiceAck : self.mainAck else {
                        self.fail("Call connection stopped responding."); return
                    }
                    if voice {
                        self.voiceAck = false
                        try await self.send(socket, op: 3, data: VoiceHeartbeat.payload(sequence: self.voiceSequence))
                    } else {
                        self.mainAck = false
                        try await self.send(socket, op: 1, data: self.mainSequence.map { $0 as Any } ?? NSNull())
                    }
                    try await Task.sleep(for: .milliseconds(milliseconds))
                } catch {
                    if !Task.isCancelled { self.fail("Call heartbeat failed.") }
                    return
                }
            }
        })
    }

    private func mainEvent(_ json: [String: Any]) async throws {
        guard let socket = mainSocket, let op = json["op"] as? Int else { return }
        if let seq = json["s"] as? Int { mainSequence = seq }
        let data = json["d"] as? [String: Any] ?? [:]
        switch op {
        case 10:
            guard !mainHelloReceived else { throw VoiceCallError.message("Unexpected repeated call Gateway hello.") }
            mainHelloReceived = true
            guard let interval = data["heartbeat_interval"] as? Double, let token else { throw VoiceCallError.message("Invalid call Gateway hello.") }
            try heartbeat(socket, milliseconds: interval, voice: false)
            try await send(socket, op: 2, data: ["token": token, "compress": false,
                "properties": ["os": "iOS", "browser": "Discord iOS", "device": "iPhone"]])
        case 11: mainAck = true
        case 1: try await send(socket, op: 1, data: mainSequence.map { $0 as Any } ?? NSNull())
        case 7, 9: throw VoiceCallError.message("Discord ended the call session. Start another call.")
        case 0:
            switch json["t"] as? String {
            case "READY":
                guard (data["user"] as? [String: Any])?["id"] as? String == selfID else {
                    throw VoiceCallError.message("The call account changed. Sign in again.")
                }
                onState?("Joining the DM call…")
                try await send(socket, op: 4, data: ["guild_id": NSNull(), "channel_id": channelID,
                    "self_mute": false, "self_deaf": false, "self_video": false])
            case "VOICE_STATE_UPDATE":
                guard data["user_id"] as? String == selfID else { return }
                if data["channel_id"] is NSNull { onEnd?(nil); return }
                guard data["channel_id"] as? String == channelID else {
                    throw VoiceCallError.message("Your voice call moved to another channel.")
                }
                voiceSessionID = data["session_id"] as? String
                try startVoiceIfReady()
                requestRing()
            case "VOICE_SERVER_UPDATE":
                guard data["channel_id"] as? String == channelID else { return }
                guard let endpoint = data["endpoint"] as? String, let url = VoiceEndpoint.url(endpoint),
                      let credential = data["token"] as? String else {
                    throw VoiceCallError.message("Discord did not provide a supported voice server.")
                }
                guard voiceSocket == nil else { throw VoiceCallError.message("Voice server changed. Start another call.") }
                voiceServer = (url, credential)
                try startVoiceIfReady()
            case "CALL_DELETE":
                if data["channel_id"] as? String == channelID { onEnd?(nil) }
            default: break // Companion alone owns message/typing delivery and presence.
            }
        default: break
        }
    }

    private func startVoiceIfReady() throws {
        guard voiceSocket == nil, let (url, _) = voiceServer, voiceSessionID != nil, !stopped else { return }
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 1_024 * 1_024
        voiceSocket = socket; socket.resume()
        onState?("Connecting to voice server…")
        receive(socket, voice: true)
    }

    private func voiceEvent(_ json: [String: Any]) async throws {
        guard let socket = voiceSocket, let op = json["op"] as? Int else { return }
        if let seq = json["seq"] as? Int { voiceSequence = seq }
        let data = json["d"] as? [String: Any] ?? [:]
        switch op {
        case 8:
            guard !voiceHelloReceived else { throw VoiceCallError.message("Unexpected repeated voice Gateway hello.") }
            voiceHelloReceived = true
            guard let interval = data["heartbeat_interval"] as? Double,
                  let voiceSessionID, let (_, credential) = voiceServer else { throw VoiceCallError.message("Invalid voice hello.") }
            try heartbeat(socket, milliseconds: min(interval, 5_000), voice: true)
            try await send(socket, op: 0, data: ["server_id": channelID, "user_id": selfID,
                "session_id": voiceSessionID, "token": credential, "video": false,
                "max_dave_protocol_version": Int(daveMaxSupportedProtocolVersion())])
            voiceServer = nil // Discard voice authentication bytes after IDENTIFY.
        case 6: voiceAck = true
        case 2:
            guard udp == nil, let number = data["ssrc"] as? UInt32, let ip = data["ip"] as? String,
                  let port = data["port"] as? UInt16, port > 0,
                  let modes = data["modes"] as? [String],
                  modes.contains(VoicePacketCipher.aesMode) else {
                throw VoiceCallError.message("This voice server does not offer AES-GCM. Try another call.")
            }
            transportMode = VoicePacketCipher.aesMode
            ssrc = number
            startUDP(ip: ip, port: port)
        case 4:
            guard data["mode"] as? String == transportMode,
                  let key = data["secret_key"] as? [UInt8], let version = data["dave_protocol_version"] as? Int else {
                throw VoiceCallError.message("Invalid encrypted voice session.")
            }
            cipher = try VoicePacketCipher(key: Data(key), ssrc: ssrc, mode: transportMode)
            // An empty call can initially negotiate transport-only encryption
            // while waiting for the other participant. Ring, but send no audio;
            // a later DAVE prepare-epoch/MLS transition must enable media.
            if version > 0 {
                if let packet = try dave.configure(version: version) { try await socket.send(.data(packet)) }
            } else if version != 0 { throw VoiceCallError.message("Invalid voice encryption version.") }
            // Ringing begins after our DM voice-state join, independently of UDP setup.
        case 5:
            if data["user_id"] as? String == peerID { remoteSSRC = data["ssrc"] as? UInt32 }
        case 12:
            if data["user_id"] as? String == peerID { remoteSSRC = data["audio_ssrc"] as? UInt32 }
        case 13:
            if data["user_id"] as? String == peerID, connected { onEnd?(nil) }
        case 21:
            guard !connected, data["protocol_version"] as? Int == 0,
                  let transition = data["transition_id"] as? UInt16, waitingTransitions.count < 8 else {
                // Never downgrade an established encrypted call.
                throw VoiceCallError.message("Discord requested an unsupported encryption transition.")
            }
            if transition != 0 {
                waitingTransitions.insert(transition)
                try await send(socket, op: 23, data: ["transition_id": Int(transition)])
            }
        case 22:
            guard let transition = data["transition_id"] as? UInt16 else { throw VoiceCallError.message("Invalid encryption transition.") }
            if waitingTransitions.remove(transition) != nil { return } // Still waiting for DAVE; no media.
            try dave.execute(transition); checkConnected()
        case 24:
            guard let version = data["protocol_version"] as? Int,
                  let epoch = data["epoch"] as? Int, epoch == 1 else {
                throw VoiceCallError.message("Unsupported encryption epoch change. Start another call.")
            }
            if let packet = try dave.configure(version: version) { try await socket.send(.data(packet)) }
        default: break
        }
    }

    private func startUDP(ip: String, port: UInt16) {
        guard IPv4Address(ip) != nil || IPv6Address(ip) != nil else { fail("Invalid voice server IP."); return }
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        udp = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, !self.stopped else { return }
                switch state {
                case .ready:
                    var packet = Data(); packet.appendVoice(UInt16(1)); packet.appendVoice(UInt16(70))
                    packet.appendVoice(self.ssrc); packet.append(Data(repeating: 0, count: 66))
                    connection.send(content: packet, completion: .contentProcessed { _ in })
                    self.receiveUDP(connection)
                case .failed: self.fail("UDP voice connection failed.")
                default: break
                }
            }
        }
        connection.start(queue: DispatchQueue(label: "TinyCord.voice.udp"))
    }

    private func receiveUDP(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] bytes, _, _, error in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, !self.stopped else { return }
                if error != nil { self.fail("Voice audio connection was lost."); return }
                if let bytes {
                    do { try await self.udpPacket(bytes) }
                    catch { self.fail((error as? VoiceCallError)?.errorDescription ?? "Voice negotiation failed."); return }
                }
                self.receiveUDP(connection)
            }
        }
    }

    private func udpPacket(_ bytes: Data) async throws {
        if !discoveryDone {
            guard bytes.count == 74, bytes.voiceUInt16(0) == 2,
                  bytes.voiceUInt16(2) == 70, bytes.voiceUInt32(4) == ssrc,
                  let end = bytes[8..<72].firstIndex(of: 0),
                  let address = String(data: bytes[8..<end], encoding: .utf8),
                  IPv4Address(address) != nil || IPv6Address(address) != nil,
                  let socket = voiceSocket else { return }
            let port = bytes.voiceUInt16(72)
            guard port > 0 else { return }
            discoveryDone = true
            try await send(socket, op: 1, data: ["protocol": "udp", "data": [
                "address": address, "port": port, "mode": transportMode]])
            return
        }
        guard let cipher else { return }
        // Authentication failures are packet loss, not fatal call errors.
        guard let packet = try? cipher.open(bytes), packet.ssrc == remoteSSRC,
              let plain = dave.decrypt(packet.frame, user: peerID) else { return }
        jitter.insert(sequence: packet.sequence, frame: plain)
    }

    private func requestRing() {
        guard !ringSent, !stopped else { return }
        ringSent = true
        tasks.append(Task { [weak self] in
            guard let self, !self.stopped else { return }
            do { try await self.ring() }
            catch {
                guard !self.stopped, !Task.isCancelled else { return }
                self.fail((error as? VoiceCallError)?.errorDescription ?? "Discord could not ring this recipient.")
            }
        })
    }

    private func ring() async throws {
        guard !stopped, let token,
              let url = URL(string: profile.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/channels/\(channelID)/call/ring") else { return }
        onState?("Requesting recipient ring…")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["recipients": [peerID]])
        let (_, response) = try await session.data(for: request)
        guard !stopped else { return }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VoiceCallError.message("Discord could not ring this recipient.")
        }
        self.token = nil
        if !connected { onState?("Ringing — connecting voice…") }
    }

    private func checkConnected() {
        guard !connected, !stopped, audioReady, cipher != nil, dave.ready else { return }
        connected = true; onState?("Encrypted call"); onConnected?()
        if let socket = voiceSocket {
            tasks.append(Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.send(socket, op: 5, data: ["speaking": 1, "delay": 0, "ssrc": self.ssrc])
                    if !self.stopped { self.capture.clear(); self.speakingReady = true }
                }
                catch { if !self.stopped { self.fail("Could not start voice audio.") } }
            })
        }
    }

    private func sendAudio(_ samples: [Float]) {
        guard !stopped, !muted, connected, speakingReady, outboundFrames < 3, let cipher, let udp,
              let frame = opus.encode(samples), let encrypted = dave.encrypt(frame, ssrc: ssrc) else { return }
        do {
            let packet = try cipher.seal(encrypted)
            outboundFrames += 1
            udp.send(content: packet, completion: .contentProcessed { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    self.outboundFrames -= 1
                    if error != nil { self.fail("Voice audio send failed.") }
                }
            })
        } catch { fail("Voice encryption failed.") }
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        onEnd?(message)
        stop()
    }

    /// Send the explicit DM leave while CallKit still owns the call, then close
    /// all transports. A stalled network gets at most 300ms to flush the leave.
    func leave() async {
        muted = true
        audio.stop()
        guard let socket = mainSocket, !stopped else { stop(); return }
        let bytes = try? JSONSerialization.data(withJSONObject: ["op": 4, "d": [
            "guild_id": NSNull(), "channel_id": NSNull(), "self_mute": false, "self_deaf": false]])
        guard let bytes else { stop(); return }
        await withCheckedContinuation { continuation in
            var finished = false
            let complete: @MainActor () -> Void = { [self] in
                guard !finished else { return }
                finished = true; stop(); continuation.resume()
            }
            socket.send(.string(String(decoding: bytes, as: UTF8.self))) { _ in
                Task { @MainActor in complete() }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                complete()
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        token = nil; voiceServer = nil
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        // Closing both sockets tears down Discord's call state. No reconnect or
        // persistent main Gateway survives CallKit deactivation/end.
        mainSocket?.cancel(with: .normalClosure, reason: nil); mainSocket = nil
        voiceSocket?.cancel(with: .normalClosure, reason: nil); voiceSocket = nil
        udp?.cancel(); udp = nil
        session.invalidateAndCancel()
        audio.stop(); capture.clear(); cipher = nil
    }
}
