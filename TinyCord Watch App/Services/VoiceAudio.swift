import AVFoundation
import Foundation
import OSLog

nonisolated struct VoiceAudioStartFailure: LocalizedError {
    enum Stage: String { case voiceProcessing = "voice processing", engineStart = "audio engine" }
    let stage: Stage
    let domain: String
    let code: Int

    init(_ stage: Stage, _ error: Error) {
        self.stage = stage
        let error = error as NSError
        domain = error.domain; code = error.code
    }

    var errorDescription: String? {
        "Could not start \(stage.rawValue). (\(domain), code \(code))"
    }
}

/// A failed voice-processing Audio Unit must be discarded before trying the
/// normal I/O unit. No retries for missing routes, conversion errors, or calls
/// that have already started. Both attempts still require CallKit activation.
nonisolated enum VoiceAudioStartup {
    static func start(attempt: (Bool) throws -> Void, reset: () -> Void,
                      onFallback: (VoiceAudioStartFailure) -> Void) throws -> Bool {
        do { try attempt(true); return true }
        catch {
            reset()
            guard let failure = error as? VoiceAudioStartFailure else { throw error }
            onFallback(failure)
            do { try attempt(false); return false }
            catch { reset(); throw error }
        }
    }
}

@MainActor
final class VoiceOpus {
    private let encoder: OpaquePointer
    private let decoder: OpaquePointer
    init() throws {
        var error: Int32 = 0
        guard let encoder = opus_encoder_create(48_000, 2, OPUS_APPLICATION_VOIP, &error), error == OPUS_OK else {
            throw VoiceCallError.message("Could not create the voice encoder.")
        }
        guard let decoder = opus_decoder_create(48_000, 2, &error), error == OPUS_OK else {
            opus_encoder_destroy(encoder)
            throw VoiceCallError.message("Could not create the voice decoder.")
        }
        self.encoder = encoder; self.decoder = decoder
    }
    deinit { opus_encoder_destroy(encoder); opus_decoder_destroy(decoder) }
    func encode(_ pcm: [Float]) -> Data? {
        guard pcm.count == 1_920 else { return nil }
        var output = [UInt8](repeating: 0, count: 4_000)
        let count = opus_encode_float(encoder, pcm, 960, &output, Int32(output.count))
        return count > 0 ? Data(output.prefix(Int(count))) : nil
    }
    func decode(_ packet: Data?) -> [Float]? {
        var output = [Float](repeating: 0, count: 11_520)
        let count: Int32
        if let packet {
            count = packet.withUnsafeBytes {
                opus_decode_float(decoder, $0.bindMemory(to: UInt8.self).baseAddress, Int32(packet.count), &output, 5_760, 0)
            }
        } else {
            count = opus_decode_float(decoder, nil, 0, &output, 960, 0)
        }
        return count > 0 ? Array(output.prefix(Int(count) * 2)) : nil
    }
}

/// Fixed-capacity, interleaved stereo FIFO shared with the audio render thread.
/// Each position represents one frame (two samples), never a callback or packet.
nonisolated final class VoicePCMBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float]
    private var readIndex = 0
    private var count = 0
    let capacityFrames: Int

    init(capacityFrames: Int = 12_000) {
        self.capacityFrames = capacityFrames
        storage = Array(repeating: 0, count: capacityFrames * 2)
    }
    var bufferedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        readIndex = 0; count = 0
    }
    func append(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        let frames = min(samples.count / 2, capacityFrames)
        let start = samples.count / 2 - frames
        // Bound latency when a consumer stalls; subsequent consumption is still
        // paced in real time, never a burst of packets with compressed timestamps.
        let overflow = max(0, count + frames - capacityFrames)
        readIndex = (readIndex + overflow) % capacityFrames
        count -= overflow
        for frame in 0..<frames {
            let index = ((readIndex + count + frame) % capacityFrames) * 2
            storage[index] = samples[(start + frame) * 2]
            storage[index + 1] = samples[(start + frame) * 2 + 1]
        }
        count += frames
    }
    func take(frames: Int) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard count >= frames else { return nil }
        var result = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let index = ((readIndex + frame) % capacityFrames) * 2
            result[frame * 2] = storage[index]
            result[frame * 2 + 1] = storage[index + 1]
        }
        readIndex = (readIndex + frames) % capacityFrames; count -= frames
        return result
    }
    /// No allocations or task scheduling on the audio render thread.
    func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        lock.lock(); defer { lock.unlock() }
        let available = min(frames, count)
        for channel in 0..<buffers.count {
            guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffers[channel].mNumberChannels)
            for frame in 0..<frames {
                for lane in 0..<channels {
                    let sample: Float = frame < available
                        ? storage[((readIndex + frame) % capacityFrames) * 2 + min(channel + lane, 1)] : 0
                    data[frame * channels + lane] = sample.isFinite ? sample : 0
                }
            }
        }
        readIndex = (readIndex + available) % capacityFrames; count -= available
    }
}

/// Convert the actual callback format to explicit planar stereo, then interleave
/// using floatChannelData/stride. No assumptions about AudioBufferList layout.
nonisolated final class VoiceCaptureConverter {
    private let converter: AVAudioConverter
    let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    init(format: AVAudioFormat) throws {
        inputFormat = format
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw VoiceCallError.message("Could not convert the microphone format for voice audio.")
        }
        converter.primeMethod = .none
        self.converter = converter
    }
    func convert(_ input: AVAudioPCMBuffer) -> [Float] {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 48_000 / input.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard status != .error, error == nil, let channels = output.floatChannelData else { return [] }
        var samples = [Float](repeating: 0, count: Int(output.frameLength) * 2)
        for frame in 0..<Int(output.frameLength) {
            samples[frame * 2] = channels[0][frame * output.stride]
            samples[frame * 2 + 1] = channels[1][frame * output.stride]
        }
        return samples
    }
}

/// Audio callbacks never access the call coordinator directly. A bounded serial
/// conversion queue drops excess capture instead of building up call latency.
nonisolated final class VoiceAudioIO: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private let control = DispatchQueue(label: "TinyCord.voice.audio-control", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.candyrect.tinycord", category: "VoiceAudio")
    private let queue = DispatchQueue(label: "TinyCord.voice.capture")
    private let slots = DispatchSemaphore(value: 3)
    private let playback = VoicePCMBuffer()
    private var converter: VoiceCaptureConverter?
    var bufferedPlaybackFrames: Int { playback.bufferedFrames }
    private var tapped = false
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!

    /// Returns false when the route needs standard I/O without echo cancellation.
    func start(onFrame: @escaping @Sendable ([Float]) -> Void) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            control.async {
                self.stopGraph()
                do {
                    let processed = try VoiceAudioStartup.start(attempt: { processing in
                        try self.startGraph(voiceProcessing: processing, onFrame: onFrame)
                    }, reset: { self.stopGraph() }, onFallback: { failure in
                        self.logger.warning("Voice-processing attempt failed: \(failure.domain, privacy: .public), code \(failure.code). Retrying a fresh audio graph.")
                    })
                    continuation.resume(returning: processed)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func startGraph(voiceProcessing: Bool, onFrame: @escaping @Sendable ([Float]) -> Void) throws {
        let engine = AVAudioEngine()
        let playback = self.playback
        let source = AVAudioSourceNode(format: outputFormat) { _, _, frames, buffers in
            playback.render(frames: Int(frames), into: UnsafeMutableAudioBufferListPointer(buffers))
            return noErr
        }
        self.engine = engine; self.sourceNode = source
        let input = engine.inputNode
        // Materialize both sides before enabling the duplex voice-processing unit.
        let output = engine.outputNode
        if voiceProcessing {
            do { try input.setVoiceProcessingEnabled(true) }
            catch { throw VoiceAudioStartFailure(.voiceProcessing, error) }
        }
        let format = input.outputFormat(forBus: 0)
        let hardwareOutput = output.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceCallError.message("No microphone audio route is available. Connect headphones and try again.")
        }
        guard hardwareOutput.sampleRate > 0, hardwareOutput.channelCount > 0 else {
            throw VoiceCallError.message("No call output route is available. Connect headphones and try again.")
        }
        logger.notice("Audio route: input \(format.sampleRate) Hz / \(format.channelCount) channels, output \(hardwareOutput.sampleRate) Hz / \(hardwareOutput.channelCount) channels; voice processing: \(voiceProcessing)")
        self.converter = try VoiceCaptureConverter(format: format)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: outputFormat)
        // Opus stays 48 kHz stereo. The mixer adapts it to the Watch's route.
        // Voice-processing I/O requires matching input and output client formats.
        engine.connect(engine.mainMixerNode, to: output, format: voiceProcessing ? format : hardwareOutput)
        input.installTap(onBus: 0, bufferSize: 960, format: format) { [weak self] buffer, _ in
            guard let self, self.slots.wait(timeout: .now()) == .success else { return }
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                self.slots.signal(); return
            }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in 0 ..< source.count {
                if let src = source[index].mData, let dst = destination[index].mData {
                    memcpy(dst, src, Int(source[index].mDataByteSize))
                }
            }
            self.queue.async {
                defer { self.slots.signal() }
                // Routes may negotiate a different rate after engine startup.
                if self.converter?.inputFormat != copy.format {
                    self.converter = try? VoiceCaptureConverter(format: copy.format)
                }
                guard let samples = self.converter?.convert(copy), !samples.isEmpty else { return }
                onFrame(samples)
            }
        }
        tapped = true
        engine.prepare()
        do { try engine.start() }
        catch { throw VoiceAudioStartFailure(.engineStart, error) }
    }

    func play(_ samples: [Float]) {
        playback.append(samples)
    }

    func stop() { control.async { self.stopGraph() } }

    private func stopGraph() {
        if tapped { engine?.inputNode.removeTap(onBus: 0); tapped = false }
        engine?.stop()
        queue.sync { converter = nil }
        playback.clear()
        sourceNode = nil; engine = nil
    }
    deinit { stopGraph() }
}
