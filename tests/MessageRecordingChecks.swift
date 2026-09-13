import AVFoundation
import Foundation

@main
enum MessageRecordingChecks {
    static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        func decode(_ extra: [String: Any] = [:]) throws -> DiscordMessage {
            var payload: [String: Any] = [
                "id": "123", "channel_id": "456", "author": ["id": "caller", "username": "Marshall"],
                "content": "", "timestamp": "2026-09-14T01:00:00.000000+00:00"
            ]
            payload.merge(extra) { _, new in new }
            return try JSONDecoder().decode(DiscordMessage.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let old = try decode(["content": "Hello"])
        check(old.type == nil && !old.isCall && !old.isVoiceMessage, "Old cached messages still decode")
        check(old.displaySnippet == "Hello", "Ordinary text remains unchanged")
        let joined = try decode(["type": 3, "call": [
            "participants": ["caller", "me"], "ended_timestamp": "2026-09-14T01:01:03+00:00"
        ]])
        check(joined.callSummary(currentUserID: "me") == "Marshall started a call · 1:03", "Call duration")
        check(!joined.isMissedCall(currentUserID: "me"), "Joined incoming call is not missed")
        check(joined.callSummary(currentUserID: "caller") == "You started a call · 1:03", "Own call")
        let missed = try decode(["type": 3, "call": [
            "participants": ["caller"], "ended_timestamp": "2026-09-14T01:00:03Z"
        ]])
        check(missed.callSummary(currentUserID: "me") == "Missed call from Marshall · 0:03", "Missed incoming call")
        check(!missed.isMissedCall(currentUserID: "caller"), "Unanswered outgoing call isn't an incoming missed call")
        check(!missed.isMissedCall(currentUserID: nil), "Do not infer missed calls without viewer identity")
        let ongoing = try decode(["type": 3, "call": ["participants": ["caller"]]])
        check(ongoing.callSummary(currentUserID: "me").contains("Ongoing"), "Unfinished call")
        let missing = try decode(["type": 3])
        check(missing.displaySnippet.contains("started a call"), "Missing metadata never leaves a blank bubble")
        let invalid = try decode(["type": 3, "call": ["ended_timestamp": "bad date"]])
        check(invalid.callSummary(currentUserID: "me").hasSuffix("Ended"), "Invalid timestamps are not invented durations")
        let unknownParticipants = try decode(["type": 3, "call": ["ended_timestamp": "2026-09-14T01:00:03Z"]])
        check(!unknownParticipants.isMissedCall(currentUserID: "me"), "Missing participant list isn't a missed call")
        let recording = try decode(["flags": 8192, "attachments": [[
            "id": "voice", "filename": "voice-message.m4a", "size": 41_000,
            "url": "https://cdn.discordapp.com/attachments/channel/file/voice-message.m4a?ex=123&hm=signature",
            "content_type": "audio/mp4", "duration_secs": 3.25, "waveform": "AID/"
        ]]])
        let attachment = recording.attachments![0]
        check(recording.isVoiceMessage && attachment.isAudio, "Discord voice flag and audio recognized")
        check(attachment.durationSecs == 3.25 && attachment.waveformLevels.count == 3, "Duration and waveform preserved")
        check(attachment.waveformLevels.last == 1, "Waveform normalized")
        check(recording.displaySnippet == "🎤 Voice message", "Reply/list preview describes the recording")
        check(attachment.resolvedURL(cdnBase: "https://cdn.example.test")?.absoluteString ==
              "https://cdn.example.test/attachments/channel/file/voice-message.m4a?ex=123&hm=signature",
              "Custom CDN preserves signed query")
        let roundtrip = try JSONDecoder().decode(DiscordMessage.self, from: JSONEncoder().encode(recording))
        check(roundtrip == recording, "New metadata survives caching")
        let fallback = try decode(["attachments": [[
            "id": "voice", "filename": "voice-message.m4a", "size": 100, "url": "https://example.test/audio"
        ]]])
        check(fallback.isVoiceMessage && fallback.attachments![0].isAudio, "Legacy unflagged Watch recording still playable")
        let flagged = try decode(["flags": 8192])
        check(flagged.isVoiceMessage, "Voice flag alone is respected")
        let generic = try decode(["attachments": [[
            "id": "file", "filename": "document.pdf", "size": 100, "url": "https://example.test/doc"
        ]]])
        check(!generic.attachments![0].isAudio && generic.displaySnippet == "📎 Attachment", "Other attachments unchanged")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let aacURL = directory.appendingPathComponent("watch.audio")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "tests/Fixtures/voice/watch.m4a"), to: aacURL)
        let aac = try AVAudioPlayer(contentsOf: aacURL)
        check(abs(aac.duration - 1) < 0.05, "Watch M4A/AAC opens by content even without its original extension")
        for (name, channels) in [("mono", 1), ("stereo", 2)] {
            let data = try Data(contentsOf: URL(fileURLWithPath: "tests/Fixtures/voice/\(name).ogg"))
            let url = directory.appendingPathComponent("\(name).wav")
            try OggOpusRecording.convert(data, to: url)
            let file = try AVAudioFile(forReading: url)
            check(file.length == 48_000, "Pre-skip and EOS padding must give exactly one second")
            check(file.processingFormat.sampleRate == 48_000, "Playback sample rate")
            check(file.processingFormat.channelCount == channels, "Channel count")
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
            try file.read(into: buffer)
            let samples = buffer.floatChannelData![0]
            var crossings = 0
            for index in 4_801..<43_200 {
                if samples[index - 1] <= 0 && samples[index] > 0 { crossings += 1 }
                check(abs(samples[index]) < 0.3, "Decoded sine must not clip or distort")
            }
            check(abs(crossings - 800) <= 2, "One-kHz pitch and real-time speed")
            let player = try AVAudioPlayer(contentsOf: url)
            check(abs(player.duration - 1) < 0.001, "Apple audio player opens converted recording at original duration")
            for bad in [Data(data.dropLast()), Data(data.prefix(26)), corrupted(data)] {
                let badURL = directory.appendingPathComponent("invalid.wav")
                do {
                    try OggOpusRecording.convert(bad, to: badURL)
                    preconditionFailure("Damaged Ogg was accepted")
                } catch {
                    check(!FileManager.default.fileExists(atPath: badURL.path), "Failed conversion cleans partial file")
                }
            }
        }
        print("PASS: message metadata, call summaries, legacy recordings, CDN URLs, mono/stereo Opus duration/pitch, damaged files.")
    }

    static func corrupted(_ data: Data) -> Data {
        var result = data
        result[result.count - 10] ^= 0x40
        return result
    }
}
