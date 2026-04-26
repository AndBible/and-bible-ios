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
        Button(action: onShowControls) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Text(speakService.currentTitle ?? currentReference)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer()

                Button {
                    speakService.skipBackward()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }

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

                Button {
                    speakService.skipForward()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }

                Button {
                    speakService.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
    }
}
