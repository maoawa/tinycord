import Foundation

/// Confined to the call's main actor. Ephemeral MLS identity; no key persistence
/// and no plaintext fallback. libdave validates external proposals and MLS state.
@MainActor
final class VoiceDAVE {
    private let session: DAVESessionHandle
    private let selfID: String
    private let groupID: UInt64
    private let recognized: Set<String>
    private var externalSender: Data?
    private var initialized = false
    private var keyPackageSent = false
    private var encryptor: DAVEEncryptorHandle?
    private var pending: [UInt16: DAVEEncryptorHandle] = [:]
    private var decryptors: [String: DAVEDecryptorHandle] = [:]
    private var recoveries = 0
    private var roster: Set<String> = []
    private(set) var ready = false

    init(channelID: String, selfID: String, peerID: String) throws {
        daveSetLogSinkCallback { _, _, _, _ in }
        guard let groupID = UInt64(channelID), groupID > 0,
              let handle = daveSessionCreate(nil, nil, { _, _, _ in }, nil) else {
            throw VoiceCallError.message("Could not create voice encryption session.")
        }
        self.session = handle; self.groupID = groupID; self.selfID = selfID
        recognized = [selfID, peerID]
        // Native log callbacks deliberately discard messages and payload details.
        daveSetLogSinkCallback { _, _, _, _ in }
    }

    deinit {
        if let encryptor { daveEncryptorDestroy(encryptor) }
        for value in pending.values { daveEncryptorDestroy(value) }
        for value in decryptors.values { daveDecryptorDestroy(value) }
        daveSessionDestroy(session)
    }

    func configure(version: Int) throws -> Data? {
        guard version > 0, version <= Int(daveMaxSupportedProtocolVersion()) else {
            throw VoiceCallError.message("This call did not negotiate supported DAVE encryption.")
        }
        selfID.withCString { daveSessionInit(session, UInt16(version), groupID, $0) }
        initialized = true; keyPackageSent = false; ready = false
        // libdave preserves its previous roster across Init and returns deltas
        // against it on the next commit, so preserve our matching roster too.
        for value in pending.values { daveEncryptorDestroy(value) }
        pending.removeAll()
        if let externalSender { setExternalSender(externalSender) }
        return keyPackage()
    }

    private func setExternalSender(_ data: Data) {
        data.withUnsafeBytes { daveSessionSetExternalSender(session, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
    }

    private func keyPackage() -> Data? {
        guard initialized, externalSender != nil, !keyPackageSent else { return nil }
        var pointer: UnsafeMutablePointer<UInt8>?; var length = 0
        daveSessionGetMarshalledKeyPackage(session, &pointer, &length)
        guard let pointer, length > 0 else { return nil }
        defer { daveFree(pointer) }
        keyPackageSent = true
        return Data([26]) + Data(bytes: pointer, count: length)
    }

    private func withRecognized<T>(_ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>?, Int) -> T) -> T {
        let owned = recognized.sorted().map { strdup($0)! }
        defer { owned.forEach { free($0) } }
        var pointers = owned.map { Optional(UnsafePointer<CChar>($0)) }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress, $0.count) }
    }

    /// Returns binary writes plus an optional JSON transition acknowledgement.
    func consume(op: Int, data: Data, ssrc: UInt32) throws -> (binary: [Data], json: (Int, UInt16)?) {
        if op == 25 {
            externalSender = data
            if initialized { setExternalSender(data) }
            return (keyPackage().map { [$0] } ?? [], nil)
        }
        guard initialized else { throw VoiceCallError.message("Voice encryption events arrived out of order.") }
        if op == 27 {
            var pointer: UnsafeMutablePointer<UInt8>?; var length = 0
            withRecognized { ids, count in
                data.withUnsafeBytes {
                    daveSessionProcessProposals(session, $0.bindMemory(to: UInt8.self).baseAddress,
                                                data.count, ids, count, &pointer, &length)
                }
            }
            guard let pointer else { return ([], nil) }
            defer { daveFree(pointer) }
            return (length > 0 ? [Data([28]) + Data(bytes: pointer, count: length)] : [], nil)
        }
        guard [29, 30].contains(op), data.count > 2 else { return ([], nil) }
        let transition = data.voiceUInt16(0)
        let payload = Data(data.dropFirst(2))
        var rosterPointer: UnsafeMutablePointer<UInt64>?; var count = 0
        defer { if let rosterPointer { daveFree(rosterPointer) } }
        var valid = false
        if op == 29 {
            let result = payload.withUnsafeBytes {
                daveSessionProcessCommit(session, $0.bindMemory(to: UInt8.self).baseAddress, payload.count)
            }
            if let result {
                defer { daveCommitResultDestroy(result) }
                if daveCommitResultIsIgnored(result) { return ([], nil) }
                valid = !daveCommitResultIsFailed(result)
                if valid {
                    daveCommitResultGetRosterMemberIds(result, &rosterPointer, &count)
                    try applyRoster(rosterPointer, count: count) { member, pointer, length in
                        daveCommitResultGetRosterMemberSignature(result, member, pointer, length)
                    }
                }
            }
        } else {
            let result = withRecognized { ids, count in
                payload.withUnsafeBytes {
                    daveSessionProcessWelcome(session, $0.bindMemory(to: UInt8.self).baseAddress, payload.count, ids, count)
                }
            }
            if let result {
                defer { daveWelcomeResultDestroy(result) }
                valid = true
                daveWelcomeResultGetRosterMemberIds(result, &rosterPointer, &count)
                try applyRoster(rosterPointer, count: count) { member, pointer, length in
                    daveWelcomeResultGetRosterMemberSignature(result, member, pointer, length)
                }
            }
        }
        guard valid else {
            recoveries += 1
            guard recoveries <= 2 else { throw VoiceCallError.message("Could not establish encrypted voice. Try another call.") }
            let packet = try configure(version: Int(daveSessionGetProtocolVersion(session)))
            return (packet.map { [$0] } ?? [], (31, transition))
        }
        guard roster.isSubset(of: recognized), roster.contains(selfID) else {
            throw VoiceCallError.message("Voice encryption participant verification failed.")
        }
        guard pending.count < 8, let next = daveEncryptorCreate(),
              let ratchet = selfID.withCString({ daveSessionGetKeyRatchet(session, $0) }) else {
            throw VoiceCallError.message("Could not prepare voice encryption keys.")
        }
        daveEncryptorSetKeyRatchet(next, ratchet); daveKeyRatchetDestroy(ratchet)
        daveEncryptorSetPassthroughMode(next, false)
        daveEncryptorAssignSsrcToCodec(next, ssrc, DAVE_CODEC_OPUS)
        if let old = pending.updateValue(next, forKey: transition) { daveEncryptorDestroy(old) }
        for user in roster where user != selfID {
            guard let ratchet = user.withCString({ daveSessionGetKeyRatchet(session, $0) }) else { continue }
            defer { daveKeyRatchetDestroy(ratchet) }
            guard let decoder = decryptors[user] ?? daveDecryptorCreate() else { continue }
            decryptors[user] = decoder
            daveDecryptorTransitionToKeyRatchet(decoder, ratchet)
        }
        if transition == 0 { try execute(transition) }
        return ([], transition == 0 ? nil : (23, transition))
    }

    private func applyRoster(_ pointer: UnsafeMutablePointer<UInt64>?, count: Int,
        signature: (UInt64, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, UnsafeMutablePointer<Int>) -> Void) throws {
        guard count <= 2 else { throw VoiceCallError.message("Unexpected voice encryption roster.") }
        guard let pointer else { return }
        // libdave returns roster CHANGES. An empty signature removes a member.
        for member in UnsafeBufferPointer(start: pointer, count: count) {
            let user = String(member)
            guard recognized.contains(user) else { throw VoiceCallError.message("Unexpected encrypted call participant.") }
            var bytes: UnsafeMutablePointer<UInt8>?; var length = 0
            signature(member, &bytes, &length)
            if let bytes { daveFree(bytes) }
            if length > 0 { roster.insert(user) }
            else {
                roster.remove(user)
                if let decoder = decryptors.removeValue(forKey: user) { daveDecryptorDestroy(decoder) }
            }
        }
    }

    func execute(_ transition: UInt16) throws {
        guard let next = pending.removeValue(forKey: transition) else {
            throw VoiceCallError.message("Unprepared voice encryption transition.")
        }
        if let encryptor { daveEncryptorDestroy(encryptor) }
        encryptor = next; ready = true
    }

    func encrypt(_ frame: Data, ssrc: UInt32) -> Data? {
        guard ready, let encryptor else { return nil }
        var result = Data(count: daveEncryptorGetMaxCiphertextByteSize(encryptor, DAVE_MEDIA_TYPE_AUDIO, frame.count))
        var written = 0
        let capacity = result.count
        let code = result.withUnsafeMutableBytes { output in frame.withUnsafeBytes { input in
            daveEncryptorEncrypt(encryptor, DAVE_MEDIA_TYPE_AUDIO, ssrc,
                input.bindMemory(to: UInt8.self).baseAddress, frame.count,
                output.bindMemory(to: UInt8.self).baseAddress, capacity, &written)
        } }
        guard code == DAVE_ENCRYPTOR_RESULT_CODE_SUCCESS else { return nil }
        return result.prefix(written)
    }

    func decrypt(_ frame: Data, user: String) -> Data? {
        guard let decoder = decryptors[user] else { return nil }
        var result = Data(count: frame.count); var written = 0
        let code = result.withUnsafeMutableBytes { output in frame.withUnsafeBytes { input in
            daveDecryptorDecrypt(decoder, DAVE_MEDIA_TYPE_AUDIO,
                input.bindMemory(to: UInt8.self).baseAddress, frame.count,
                output.bindMemory(to: UInt8.self).baseAddress, frame.count, &written)
        } }
        guard code == DAVE_DECRYPTOR_RESULT_CODE_SUCCESS else { return nil }
        return result.prefix(written)
    }
}
