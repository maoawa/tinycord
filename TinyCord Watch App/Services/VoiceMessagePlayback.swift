import AVFoundation
import Combine
import Foundation

/// One recording at a time. Downloads only on tap, never using the Discord token.
@MainActor
final class VoiceMessagePlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoiceMessagePlayback()
    @Published private(set) var attachmentID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var error: String?
    private var player: AVAudioPlayer?
    private var localURL: URL?
    private var loadTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var requestID = UUID()
    private var ownsAudioSession = false
    private var subscriptions = Set<AnyCancellable>()

    private override init() {
        super.init()
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let kind = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      kind == AVAudioSession.InterruptionType.began.rawValue else { return }
                self?.stop()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                self?.stop()
            }.store(in: &subscriptions)
        EndpointConfig.shared.$selectedProfileId.dropFirst().sink { [weak self] _ in self?.stop() }.store(in: &subscriptions)
        EndpointConfig.shared.$cdnBaseURL.dropFirst().sink { [weak self] _ in self?.stop() }.store(in: &subscriptions)
        AuthStore.shared.$token.dropFirst().sink { [weak self] _ in self?.stop() }.store(in: &subscriptions)
    }

    func toggle(attachment: DiscordAttachment, url: URL?) {
        guard !VoiceCallController.shared.active else { return }
        if attachmentID == attachment.id, let player {
            if isPlaying {
                player.pause()
                isPlaying = false
                progressTask?.cancel()
            } else {
                do { try play(player) } catch { fail(error) }
            }
            return
        }
        stop()
        attachmentID = attachment.id
        guard let url, url.scheme?.lowercased() == "https" else {
            error = "This recording needs a valid HTTPS address."
            return
        }
        guard attachment.size >= 0, attachment.size <= OggOpusRecording.maximumBytes else {
            error = VoiceRecordingError.tooLarge.localizedDescription
            return
        }
        isLoading = true
        let request = requestID
        loadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try await Self.download(url)
            }
            do {
                let file = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, self.requestID == request,
                      !VoiceCallController.shared.active else {
                    try? FileManager.default.removeItem(at: file)
                    return
                }
                self.localURL = file
                let player = try AVAudioPlayer(contentsOf: file)
                player.delegate = self
                self.player = player
                self.duration = player.duration
                self.isLoading = false
                try self.play(player)
            } catch {
                guard let self, self.requestID == request, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    private func play(_ player: AVAudioPlayer) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        ownsAudioSession = true
        if player.currentTime >= player.duration { player.currentTime = 0 }
        guard player.play() else { throw VoiceRecordingError.invalidAudio }
        isPlaying = true
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, let player = self.player, self.isPlaying else { return }
                self.position = player.currentTime
            }
        }
    }

    func stop(ifMatching id: String? = nil) {
        if let id, id != attachmentID { return }
        requestID = UUID()
        loadTask?.cancel(); loadTask = nil
        progressTask?.cancel(); progressTask = nil
        player?.stop(); player = nil
        if let localURL { try? FileManager.default.removeItem(at: localURL) }
        localURL = nil
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
        attachmentID = nil; error = nil
        isLoading = false; isPlaying = false; position = 0; duration = 0
    }

    private func fail(_ failure: Error) {
        let id = attachmentID
        stop()
        attachmentID = id
        error = (failure as? VoiceRecordingError)?.localizedDescription
            ?? "Couldn’t play this recording. Tap to retry."
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            if !flag { self.fail(VoiceRecordingError.invalidAudio); return }
            self.isPlaying = false
            self.position = 0
            player.currentTime = 0
            self.progressTask?.cancel()
            if self.ownsAudioSession {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                self.ownsAudioSession = false
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.fail(VoiceRecordingError.invalidAudio)
        }
    }

    private nonisolated static func download(_ url: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.url?.scheme?.lowercased() == "https" else { throw VoiceRecordingError.downloadFailed }
        guard response.expectedContentLength <= Int64(OggOpusRecording.maximumBytes) else {
            throw VoiceRecordingError.tooLarge
        }
        var data = Data()
        for try await byte in stream {
            if data.count % 16_384 == 0 { try Task.checkCancellation() }
            guard data.count < OggOpusRecording.maximumBytes else { throw VoiceRecordingError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard !data.isEmpty else { throw VoiceRecordingError.invalidAudio }
        let isOgg = OggOpusRecording.isOgg(data)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-\(UUID().uuidString)")
            .appendingPathExtension(isOgg ? "wav" : "audio")
        do {
            if isOgg { try OggOpusRecording.convert(data, to: file) }
            else { try data.write(to: file, options: .atomic) }
            try Task.checkCancellation()
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}
