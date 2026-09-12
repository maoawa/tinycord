//
//  VoiceMessageRecorderView.swift
//  TinyCord Watch App
//

import SwiftUI
import AVFoundation
import WatchKit

struct VoiceMessageRecorderView: View {
    let onSend: (Data, Float) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var isRecording: Bool = false
    @State private var isRecorded: Bool = false
    @State private var isPlaying: Bool = false
    @State private var elapsed: TimeInterval = 0
    @State private var audioLevels: [CGFloat] = Array(repeating: 0.2, count: 7)

    @State private var recorder: AVAudioRecorder?
    @State private var player: AVAudioPlayer?
    @State private var timer: Timer?
    @State private var recordingURL: URL?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Timer & Status
                HStack(spacing: 6) {
                    Circle()
                        .fill(isRecording ? Color.red : (isRecorded ? Color.green : Color.gray))
                        .frame(width: 8, height: 8)

                    Text(formattedTime(elapsed))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))

                    Text("/ 1:00")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)

                // Waveform / Meter visual
                HStack(spacing: 4) {
                    ForEach(0..<audioLevels.count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isRecording ? themeManager.color : Color.gray.opacity(0.5))
                            .frame(width: 4, height: max(6, audioLevels[i] * 32))
                            .animation(.easeInOut(duration: 0.1), value: audioLevels[i])
                    }
                }
                .frame(height: 36)

                // Action Controls
                if isRecording {
                    // Stop button
                    Button {
                        stopRecording()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .foregroundStyle(.red)
                            Text("Stop & Review")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red.opacity(0.3))

                    Button {
                        cancelRecording()
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                } else if isRecorded {
                    // Preview playback & retake
                    HStack(spacing: 12) {
                        Button {
                            togglePlayback()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14))
                        }
                        .frame(width: 38, height: 38)
                        .buttonStyle(.bordered)
                        .tint(themeManager.themeActionButtons ? themeManager.color : Color(white: 0.25))

                        Button {
                            retakeRecording()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 14))
                        }
                        .frame(width: 38, height: 38)
                        .buttonStyle(.bordered)
                        .tint(Color(white: 0.25))
                    }

                    // Send Button
                    Button {
                        sendAudio()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                            Text("Send Voice Message")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(themeManager.color)
                    .padding(.top, 2)

                    Button {
                        cancelRecording()
                    } label: {
                        Text("Discard")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle {
            Text("Voice Message")
                .foregroundStyle(themeManager.color)
                .fontWeight(.semibold)
        }
        .onAppear {
            startRecording()
        }
        .onDisappear {
            cleanup()
        }
    }

    private func formattedTime(_ time: TimeInterval) -> String {
        let seconds = Int(time) % 60
        let minutes = Int(time) / 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func startRecording() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default)
            try audioSession.setActive(true)
        } catch {
            print("[VoiceRecorder] Audio session error: \(error.localizedDescription)")
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("voice_\(UUID().uuidString).m4a")
        self.recordingURL = fileURL

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let newRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            newRecorder.isMeteringEnabled = true
            newRecorder.record()
            self.recorder = newRecorder
            self.isRecording = true
            self.isRecorded = false
            self.elapsed = 0
            WKInterfaceDevice.current().play(.start)

            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                guard let rec = self.recorder, rec.isRecording else { return }
                rec.updateMeters()
                self.elapsed = rec.currentTime

                // Update visual levels
                let power = rec.averagePower(forChannel: 0)
                let normalized = max(0.1, min(1.0, CGFloat((power + 50) / 50)))
                self.audioLevels.removeFirst()
                self.audioLevels.append(normalized)

                // Enforce 60s maximum duration
                if self.elapsed >= 60.0 {
                    self.stopRecording()
                }
            }
        } catch {
            print("[VoiceRecorder] Recording init error: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        isRecording = false
        isRecorded = true
        WKInterfaceDevice.current().play(.stop)

        // Reset levels
        audioLevels = Array(repeating: 0.25, count: 7)
    }

    private func retakeRecording() {
        cleanupPlayer()
        cleanupFile()
        startRecording()
    }

    private func cancelRecording() {
        cleanup()
        dismiss()
    }

    private func togglePlayback() {
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            guard let url = recordingURL else { return }
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playback, mode: .default)
                try audioSession.setActive(true)

                let p = try AVAudioPlayer(contentsOf: url)
                self.player = p
                p.play()
                isPlaying = true

                // Reset playing state after playback completes
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(p.duration * 1_000_000_000))
                    await MainActor.run {
                        self.isPlaying = false
                    }
                }
            } catch {
                print("[VoiceRecorder] Playback error: \(error.localizedDescription)")
            }
        }
    }

    private func sendAudio() {
        cleanupPlayer()
        guard let url = recordingURL, let data = try? Data(contentsOf: url), !data.isEmpty else {
            dismiss()
            return
        }

        let durationSecs = Float(elapsed)
        onSend(data, durationSecs)
        cleanupFile()
        dismiss()
    }

    private func cleanupPlayer() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    private func cleanupFile() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        cleanupPlayer()
        cleanupFile()
    }
}
