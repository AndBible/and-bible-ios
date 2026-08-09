// AndroidSpeakTransportView.swift -- Shared app-owned speech transport widget

import BibleCore
import SwiftUI

/**
 Reuses Android's `SpeakTransportWidget` contract across the reader and both Speak activities.

 The widget owns status text, the compact speed seek bar, exact packaged Android transport
 drawables, and transport action ordering. Feature hosts decide only whether the bookmark and
 configuration commands are available and supply their app-owned presentation callbacks.

 Inputs: observable speech service, owner-resolved reader palette, fallback status text, and
 optional bookmark/configuration commands.

 Output: one app-owned transport bar with Android's status, speed, and button rows.

 Side effects: updates speech speed and invokes `SpeakService` transport methods after taps.

 Failure modes: absent bookmark/configuration callbacks omit those optional Android buttons.
 */
struct AndroidSpeakTransportView: View {
    /// Shared speech session and transport owner.
    @ObservedObject var speakService: SpeakService

    /// Workspace/window palette inherited from the reader surface.
    let surfacePalette: ReaderThemeSurfacePalette

    /// Reader reference used only when the service has not yet published a title.
    let fallbackStatus: String

    /// Opens Android's Speak-bookmark selection dialog when bookmarks exist.
    let onShowBookmarks: (() -> Void)?

    /// Opens the full Speak configuration activity from the reader transport.
    let onShowConfiguration: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(statusText)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .foregroundStyle(surfacePalette.foregroundColor)
                    .frame(maxWidth: .infinity, alignment: .leading)

                AndroidSeekBar(
                    value: speedPercentBinding,
                    range: 10...300,
                    step: 1,
                    palette: surfacePalette,
                    accessibilityIdentifier: "speakTransportSpeed",
                    accessibilityLabel: String(localized: "speak_speed_title", defaultValue: "Speech speed")
                )
                .frame(maxWidth: 150)
            }
            .padding(.horizontal, 12)

            HStack(spacing: 0) {
                if !speakService.resumeBookmarks.isEmpty, let onShowBookmarks {
                    transportButton(
                        asset: "SpeakBookmark",
                        label: String(localized: "bookmarks", defaultValue: "Bookmarks"),
                        identifier: "speakTransportBookmarks",
                        action: onShowBookmarks
                    )
                }
                transportButton(
                    asset: "SpeakFastRewind",
                    label: String(localized: "rewind", defaultValue: "Rewind"),
                    identifier: "speakTransportRewind",
                    action: speakService.rewind
                )
                transportButton(
                    asset: "SpeakPrevious",
                    label: String(localized: "speak_previous", defaultValue: "Previous"),
                    identifier: "speakTransportPrevious",
                    action: speakService.previousUnit
                )
                transportButton(
                    asset: "SpeakStop",
                    label: String(localized: "stop", defaultValue: "Stop"),
                    identifier: "speakTransportStop",
                    action: speakService.stop
                )
                transportButton(
                    asset: speakService.isSpeaking && !speakService.isPaused
                        ? "SpeakPause"
                        : "SpeakPlay",
                    label: playPauseAccessibilityLabel,
                    identifier: "speakTransportPlayPause",
                    action: playPause
                )
                transportButton(
                    asset: "SpeakNext",
                    label: String(localized: "speak_next", defaultValue: "Next"),
                    identifier: "speakTransportNext",
                    action: speakService.nextUnit
                )
                transportButton(
                    asset: "SpeakFastForward",
                    label: String(localized: "forward", defaultValue: "Forward"),
                    identifier: "speakTransportForward",
                    action: speakService.forward
                )
                if let onShowConfiguration {
                    transportButton(
                        asset: "SpeakSettings",
                        label: String(localized: "speak", defaultValue: "Speak"),
                        identifier: "speakTransportConfiguration",
                        action: onShowConfiguration
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 5)
        .background(surfacePalette.backgroundColor)
        .overlay(alignment: .top) {
            Divider().overlay(surfacePalette.inactiveBorderColor)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("androidSpeakTransport")
    }

    /// Android status text prefers the active provider title, then the reader reference.
    private var statusText: String {
        let title = speakService.currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty {
            return title
        }
        return fallbackStatus
    }

    /// Projects Android's persisted percentage into the shared seek bar.
    private var speedPercentBinding: Binding<Double> {
        Binding(
            get: { speakService.userSpeed * 100 },
            set: { speakService.userSpeed = $0 / 100 }
        )
    }

    /// Localized dynamic label for Android's combined play/pause button.
    private var playPauseAccessibilityLabel: String {
        if speakService.isSpeaking && !speakService.isPaused {
            return String(localized: "pause", defaultValue: "Pause")
        }
        return String(localized: "speak", defaultValue: "Speak")
    }

    /**
     Executes Android's play/pause state machine.

     - Side effects: resumes, pauses, or starts the shared speech service.
     - Failure modes: provider preparation failures remain owned and published by `SpeakService`.
     */
    private func playPause() {
        if speakService.isPaused {
            speakService.resume()
        } else if speakService.isSpeaking {
            speakService.pause()
        } else {
            speakService.play()
        }
    }

    /**
     Creates one exact-asset Android transport action with an equal-width touch target.

     - Parameters describe the packaged drawable, localized label, stable identity, and command.
     - Returns: Plain app-owned icon button.
     - Side effects: invokes `action` after a direct tap.
     - Failure modes: a missing asset uses SwiftUI's normal missing-image rendering.
     */
    private func transportButton(
        asset: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            AndBibleIconView(name: asset, size: 24)
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(surfacePalette.foregroundColor)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
