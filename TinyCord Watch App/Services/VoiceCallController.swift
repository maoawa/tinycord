import AVFoundation
import CallKit
import Combine
import Foundation
import OSLog

@MainActor
final class VoiceCallController: NSObject, ObservableObject, CXProviderDelegate {
    static let shared = VoiceCallController()
    @Published private(set) var active = false
    @Published private(set) var status = "Ready to call"
    @Published private(set) var error: String?
    @Published private(set) var audioNotice: String?
    @Published private(set) var muted = false
    @Published private(set) var connectedAt: Date?
    @Published private(set) var channelID: String?
    @Published private(set) var name = ""
    private let provider: CXProvider
    private let callController = CXCallController()
    private var callID: UUID?
    private var transport: VoiceCallTransport?
    private var pending: (channel: DiscordChannel, token: String, userID: String, peerID: String, profile: EndpointProfile)?
    private var subscriptions: Set<AnyCancellable> = []
    private var startTimeout: Task<Void, Never>?
    private var callStartedUptime = ProcessInfo.processInfo.systemUptime
    private let logger = Logger(subsystem: "com.candyrect.tinycord", category: "VoiceCall")

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
        // Settings can be synced from iPhone during a call. End before using any
        // replacement credential or profile; a new call takes a fresh snapshot.
        AuthStore.shared.$token.dropFirst().sink { [weak self] _ in self?.configurationChanged() }.store(in: &subscriptions)
        AuthStore.shared.$isBotToken.dropFirst().sink { [weak self] _ in self?.configurationChanged() }.store(in: &subscriptions)
        EndpointConfig.shared.$selectedProfileId.dropFirst().sink { [weak self] _ in self?.configurationChanged() }.store(in: &subscriptions)
        EndpointConfig.shared.$profiles.dropFirst().sink { [weak self] _ in self?.configurationChanged() }.store(in: &subscriptions)
    }

    func start(_ channel: DiscordChannel) {
        guard !active else { return }
        error = nil; audioNotice = nil; connectedAt = nil; muted = false
        let auth = AuthStore.shared
        guard channel.isDM, !auth.isBotToken, let token = auth.token,
              let selfID = auth.currentUser?.id,
              let peerID = channel.recipientUser(currentUserId: selfID)?.id, peerID != selfID else {
            error = "The prototype supports outgoing one-to-one calls with a user account."; return
        }
        let profile = EndpointConfig.shared.activeProfile
        guard profile.callGatewayURL != nil else { error = "Enter a valid WSS call Gateway in Endpoints."; return }
        guard let api = URLComponents(string: profile.apiBaseURL), api.scheme == "https", api.host != nil,
              api.user == nil, api.password == nil else { error = "Voice calls require an HTTPS API endpoint."; return }
        let id = UUID()
        VoiceMessagePlayback.shared.stop()
        callStartedUptime = ProcessInfo.processInfo.systemUptime
        callID = id; active = true; channelID = channel.id
        name = channel.displayName(currentUserId: selfID)
        status = "Requesting microphone…"
        pending = (channel, token, selfID, peerID, profile)
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            Task { @MainActor [weak self] in
                guard let self, self.callID == id else { return }
                guard allowed else { self.finish("Microphone access is required for calls."); return }
                // watchOS can show the handle itself in failed-call/redial UI.
                // Discord routing uses pending.peerID, independently of this label.
                let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: self.name))
                action.isVideo = false
                self.status = "Requesting system call…"
                self.logger.notice("Requesting CallKit start transaction")
                self.waitForStartup(id: id, message: "watchOS did not process the call request. Reopen TinyCord and try again.")
                self.callController.request(CXTransaction(action: action)) { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, self.callID == id else { return }
                        if let error { self.finish(Self.startFailureMessage(error), report: false) }
                    }
                }
            }
        }
    }

    private func waitForStartup(id: UUID, message: String) {
        startTimeout?.cancel()
        startTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.callID == id, self.transport == nil else { return }
            self.logger.error("Call startup timed out before any Discord connection")
            self.finish(message)
        }
    }

    private static var audioActivationFailure: String {
        #if targetEnvironment(simulator)
        "The Watch simulator did not activate CallKit audio. Test this call on a physical Apple Watch. Discord was not contacted."
        #else
        "watchOS did not activate call audio. Check the audio route and other active calls, then try again. Discord was not contacted."
        #endif
    }

    func end() {
        guard let id = callID else { return }
        status = "Ending call…"
        Task { [weak self] in
            guard let self, self.callID == id else { return }
            await self.transport?.leave()
            guard self.callID == id else { return }
            self.finish(nil, report: false)
            self.callController.request(CXTransaction(action: CXEndCallAction(call: id))) { [weak self] error in
                if error != nil {
                    Task { @MainActor [weak self] in self?.provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded) }
                }
            }
        }
    }

    func dismissError() { error = nil }

    func toggleMute() {
        guard let id = callID else { return }
        let action = CXSetMutedCallAction(call: id, muted: !muted)
        callController.request(CXTransaction(action: action)) { _ in }
    }

    private func configurationChanged() {
        if active { finish("Call ended because the account or endpoint configuration changed.") }
    }

    private static func startFailureMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == CXErrorDomainRequestTransaction {
            switch nsError.code {
            case CXErrorCodeRequestTransactionError.unentitled.rawValue:
                return "CallKit denied call access. Rebuild and reinstall TinyCord with Audio and VoIP background modes. (CallKit 1)"
            case CXErrorCodeRequestTransactionError.unknownCallProvider.rawValue:
                return "The call provider is unavailable. Reopen TinyCord and try again. (CallKit 2)"
            case CXErrorCodeRequestTransactionError.maximumCallGroupsReached.rawValue:
                return "End the other active call before starting this one. (CallKit 7)"
            default:
                return "watchOS rejected the call request. (CallKit \(nsError.code))"
            }
        }
        // Keep diagnostics useful without exposing framework userInfo/payloads.
        return "watchOS could not start this call. (\(nsError.domain), code \(nsError.code))"
    }

    private func finish(_ message: String?, report: Bool = true) {
        logger.notice("Ending call; failed: \(message != nil, privacy: .public)")
        let id = callID
        callID = nil; active = false
        startTimeout?.cancel(); startTimeout = nil
        transport?.stop(); transport = nil; pending = nil
        connectedAt = nil; muted = false
        error = message; audioNotice = nil; status = message == nil ? "Call ended" : "Call failed"
        if report, let id { provider.reportCall(with: id, endedAt: Date(), reason: message == nil ? .remoteEnded : .failed) }
    }

    func providerDidReset(_ provider: CXProvider) { finish(nil, report: false) }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard callID == action.callUUID, pending != nil else { action.fail(); return }
        do {
            // CallKit owns activation. Do not open either socket here.
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat)
            let update = CXCallUpdate()
            update.localizedCallerName = name
            update.remoteHandle = action.handle
            update.hasVideo = false
            update.supportsHolding = false; update.supportsGrouping = false
            update.supportsUngrouping = false; update.supportsDTMF = false
            provider.reportCall(with: action.callUUID, updated: update)
            status = "Waiting for call audio…"
            logger.notice("CallKit accepted start; waiting for audio activation")
            waitForStartup(id: action.callUUID, message: Self.audioActivationFailure)
            action.fulfill()
        } catch { action.fail(); finish("Could not configure the call audio route.") }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        guard let id = callID, let pending, transport == nil else { return }
        logger.notice("CallKit audio activated; starting call-only transport")
        do {
            let transport = try VoiceCallTransport(channelID: pending.channel.id, selfID: pending.userID,
                peerID: pending.peerID, token: pending.token, profile: pending.profile)
            self.transport = transport; self.pending = nil
            transport.muted = muted
            transport.onAudioNotice = { [weak self] notice in
                guard self?.callID == id else { return }
                self?.audioNotice = notice
            }
            transport.onState = { [weak self] text in
                guard let self, self.callID == id else { return }
                self.status = text
                // States are app-authored labels, never remote payloads or credentials.
                let elapsed = ProcessInfo.processInfo.systemUptime - self.callStartedUptime
                self.logger.notice("Call stage at \(elapsed, privacy: .public)s: \(text, privacy: .public)")
            }
            transport.onConnected = { [weak self] in
                guard let self, self.callID == id else { return }
                self.connectedAt = Date()
                self.provider.reportOutgoingCall(with: id, connectedAt: self.connectedAt)
            }
            transport.onEnd = { [weak self] message in
                guard self?.callID == id else { return }; self?.finish(message)
            }
            startTimeout?.cancel(); startTimeout = nil
            provider.reportOutgoingCall(with: id, startedConnectingAt: Date())
            try transport.start()
        } catch {
            let nsError = error as NSError
            logger.error("Call startup error: \(nsError.domain, privacy: .public), code \(nsError.code)")
            finish((error as? VoiceCallError)?.errorDescription
                ?? (error as? VoiceAudioStartFailure)?.errorDescription
                ?? "Could not start call audio. (\(nsError.domain), code \(nsError.code))")
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        logger.notice("CallKit audio deactivated")
        if active, transport != nil { finish("Call audio was interrupted. Start another call to reconnect.") }
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard callID == action.callUUID else { action.fulfill(); return }
        Task { [weak self] in
            guard let self else { action.fulfill(); return }
            await self.transport?.leave()
            if self.callID == action.callUUID { self.finish(nil, report: false) }
            action.fulfill()
        }
    }
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard callID == action.callUUID else { action.fail(); return }
        muted = action.isMuted; transport?.muted = muted; action.fulfill()
    }
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        guard let action = action as? CXCallAction, callID == action.callUUID else { return }
        finish("The call action timed out.")
    }
}
