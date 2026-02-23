// SpeakControlView.swift — Text-to-Speech playback controls

import SwiftUI
import BibleCore
import AVFoundation

/// TTS playback controls with speed presets, sleep timer, and Now Playing metadata.
public struct SpeakControlView: View {
    @ObservedObject var speakService: SpeakService
    @State private var speed: Double

    private let speedPresets: [(label: String, value: Double)] = [
        ("0.75x", 0.75),
        ("1.0x", 1.0),
        ("1.25x", 1.25),
        ("1.5x", 1.5),
    ]

    private let sleepPresets: [Int] = [5, 10, 15, 30, 60]

    public init(speakService: SpeakService) {
        self.speakService = speakService
        self._speed = State(initialValue: speakService.userSpeed)
    }

    public var body: some View {
        VStack(spacing: 20) {
            // Header: title + state
            VStack(spacing: 4) {
                if let title = speakService.currentTitle {
                    Text(title)
                        .font(.headline)
                } else {
                    Text(speakService.isSpeaking ? String(localized: "speak_now_speaking") : String(localized: "speak_stopped"))
                        .font(.headline)
                }
                if let subtitle = speakService.currentSubtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Transport controls
            HStack(spacing: 24) {
                Button(action: { speakService.skipBackward() }) {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                }

                Button(action: {
                    if speakService.isSpeaking {
                        if speakService.isPaused {
                            speakService.resume()
                        } else {
                            speakService.pause()
                        }
                    }
                }) {
                    Image(systemName: speakService.isPaused ? "play.fill" : "pause.fill")
                        .font(.title)
                }
                .disabled(!speakService.isSpeaking)

                Button(action: { speakService.skipForward() }) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }

                Button(action: { speakService.stop() }) {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                }
            }

            // Speed slider + presets
            VStack(spacing: 8) {
                HStack {
                    Text(String(localized: "speak_speed"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(String(format: "%.1fx", speed))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(value: $speed, in: 0.5...2.0, step: 0.1)
                    .onChange(of: speed) { _, newValue in
                        speakService.userSpeed = newValue
                    }

                HStack(spacing: 8) {
                    ForEach(speedPresets, id: \.value) { preset in
                        Button(preset.label) {
                            speed = preset.value
                            speakService.userSpeed = preset.value
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .tint(abs(speed - preset.value) < 0.05 ? .accentColor : .secondary)
                    }
                }
            }
            .padding(.horizontal)

            // Sleep timer
            VStack(spacing: 8) {
                HStack {
                    Text(String(localized: "speak_sleep_timer"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let remaining = speakService.sleepTimerRemaining {
                        Text("\(Int(remaining / 60)):\(String(format: "%02d", Int(remaining) % 60))")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 8) {
                    ForEach(sleepPresets, id: \.self) { minutes in
                        Button("\(minutes)m") {
                            speakService.setSleepTimer(minutes: minutes)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .tint(isTimerActiveFor(minutes) ? .orange : .secondary)
                    }

                    if speakService.sleepTimerRemaining != nil {
                        Button {
                            speakService.setSleepTimer(minutes: nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding()
    }

    private var stateLabel: String {
        if !speakService.isSpeaking { return String(localized: "speak_stopped") }
        if speakService.isPaused { return String(localized: "speak_paused") }
        return String(localized: "speak_playing")
    }

    private func isTimerActiveFor(_ minutes: Int) -> Bool {
        guard let remaining = speakService.sleepTimerRemaining else { return false }
        let target = TimeInterval(minutes * 60)
        return remaining > 0 && remaining <= target && remaining > target - 60
    }
}
