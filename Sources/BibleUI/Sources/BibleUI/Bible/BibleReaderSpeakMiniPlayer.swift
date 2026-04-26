import BibleCore
import SwiftUI

/**
 Compact speech-control bar shown while text-to-speech is active.

 The reader coordinator decides when the mini-player is visible. This view observes
 `SpeakService` directly so play/pause/title changes update without bloating `BibleReaderView`.
 */
struct BibleReaderSpeakMiniPlayer: View {
    @ObservedObject var speakService: SpeakService
    let currentReference: String
    let onShowControls: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onShowControls) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Text(speakService.currentTitle ?? currentReference)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(speakService.currentTitle ?? currentReference)
            .accessibilityHint(String(localized: "speak_open_controls", defaultValue: "Open speech controls"))

            Button {
                speakService.skipBackward()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.body)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(String(localized: "speak_skip_backward", defaultValue: "Skip backward"))

            Button {
                if speakService.isPaused {
                    speakService.resume()
                } else {
                    speakService.pause()
                }
            } label: {
                Image(systemName: speakService.isPaused ? "play.fill" : "pause.fill")
                    .font(.body)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(playPauseAccessibilityLabel)

            Button {
                speakService.skipForward()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.body)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(String(localized: "speak_skip_forward", defaultValue: "Skip forward"))

            Button {
                speakService.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.body)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(String(localized: "stop"))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var playPauseAccessibilityLabel: String {
        if speakService.isPaused {
            return String(localized: "speak_resume", defaultValue: "Resume")
        }
        return String(localized: "pause")
    }
}
