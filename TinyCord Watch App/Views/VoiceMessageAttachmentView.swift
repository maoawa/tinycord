import SwiftUI

struct VoiceMessageAttachmentView: View {
    let attachment: DiscordAttachment
    let url: URL?
    let isVoiceMessage: Bool
    @ObservedObject private var playback = VoiceMessagePlayback.shared
    @ObservedObject private var call = VoiceCallController.shared
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.scenePhase) private var scenePhase

    private var selected: Bool { playback.attachmentID == attachment.id }
    private var playing: Bool { selected && playback.isPlaying }
    private var loading: Bool { selected && playback.isLoading }
    private var duration: Double {
        if selected && playback.duration > 0 { return playback.duration }
        return attachment.durationSecs ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if loading { playback.stop(ifMatching: attachment.id) }
                else { playback.toggle(attachment: attachment, url: url) }
            } label: {
                HStack(spacing: 8) {
                    Group {
                        if loading {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                        }
                    }
                    .frame(width: 24, height: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isVoiceMessage ? "Voice message" : attachment.filename)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        if !attachment.waveformLevels.isEmpty {
                            HStack(spacing: 2) {
                                ForEach(Array(attachment.waveformLevels.enumerated()), id: \.offset) { index, level in
                                    Capsule()
                                        .fill(.white.opacity(selected && duration > 0 &&
                                              Double(index) / Double(attachment.waveformLevels.count) < playback.position / duration ? 1 : 0.45))
                                        .frame(maxWidth: 3)
                                        .frame(height: max(2, level * 16))
                                }
                            }
                            .frame(height: 16)
                            .accessibilityHidden(true)
                        } else {
                            ProgressView(value: selected ? playback.position : 0, total: max(1, duration))
                                .tint(.white)
                                .accessibilityHidden(true)
                        }
                        Text(loading ? "Loading…" : timeLabel)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 40)
                .foregroundStyle(.white)
            }
            .buttonStyle(.bordered)
            .tint(theme.themeActionButtons ? theme.color : Color(white: 0.25))
            .disabled(call.active)
            .accessibilityLabel(loading ? "Cancel loading" : playing ? "Pause recording" : "Play recording")
            .accessibilityValue(timeLabel)
            if call.active {
                Text("Playback available after the call")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else if selected, let error = playback.error {
                Text(error).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .onDisappear { playback.stop(ifMatching: attachment.id) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { playback.stop(ifMatching: attachment.id) }
        }
        .onChange(of: url) { _, _ in playback.stop(ifMatching: attachment.id) }
    }

    private var timeLabel: String {
        if selected && (playback.position > 0 || playing) {
            return "\(formatted(playback.position)) / \(formatted(duration))"
        }
        return duration > 0 ? formatted(duration) : "Tap to play"
    }

    private func formatted(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 31_536_000 else { return "–:––" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
