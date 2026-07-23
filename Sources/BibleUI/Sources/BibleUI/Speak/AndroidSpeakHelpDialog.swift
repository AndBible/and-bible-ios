// AndroidSpeakHelpDialog.swift -- Android Speak help dialogs

import SwiftUI

/** Android source-defined content variants for Speak activity help. */
enum AndroidSpeakHelpMode: Equatable {
    /// `BibleSpeakActivity.onHelpButtonClick` title and tutorial link.
    case playback

    /// `SpeakSettingsActivity.onHelpButtonClick` bookmarking explanations and tutorial link.
    case advanced
}

/**
 Renders Android's Speak help messages in the shared app-owned dialog window.

 The text and playlist URL come from Android's `BibleSpeakActivity`, `SpeakSettingsActivity`, and
 `CommonUtils.speakPlayList`. The shared dialog owns palette, scrim, geometry, outside dismissal,
 and positive-action styling; this feature supplies only Android's semantic content.
 */
struct AndroidSpeakHelpDialog: View {
    /// Android help message variant.
    let mode: AndroidSpeakHelpMode

    /// Owner dismissal callback.
    let onDismiss: () -> Void

    /// Active AppCompat DayNight color scheme.
    @Environment(\.colorScheme) private var colorScheme

    /// Exact playlist constant used by both Android Speak activities.
    private let tutorialURL = URL(
        string: "https://www.youtube.com/playlist?list=PLD-W_Iw-N2Ml4arSb_fDBYqgiYtVPmjFo"
    )!

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: mode == .playback
                ? "speakHelpDialog"
                : "advancedSpeakHelpDialog",
            onOutsideTap: onDismiss
        ) {
            VStack(alignment: .leading, spacing: 18) {
                ScrollView {
                    helpContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 520)

                HStack {
                    Spacer()
                    Button(String(localized: "okay", defaultValue: "OK"), action: onDismiss)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("speakHelpOKButton")
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
        }
    }

    /// Builds the exact main or advanced Android Speak help sequence.
    @ViewBuilder
    private var helpContent: some View {
        switch mode {
        case .playback:
            VStack(alignment: .leading, spacing: 18) {
                Text(String(localized: "speak", defaultValue: "Speak"))
                    .font(.system(size: 18, weight: .bold))
                tutorialLink
            }
        case .advanced:
            VStack(alignment: .leading, spacing: 18) {
                Text(String(localized: "conf_speak_auto_bookmark", defaultValue: "Automatically add Speak bookmark"))
                    .font(.system(size: 18, weight: .bold))
                tutorialLink
                Text(String(
                    localized: "speak_help_auto_bookmark",
                    defaultValue: "A Speak bookmark is added automatically when speaking is paused or stopped."
                ))
                Text(String(
                    localized: "conf_save_playback_settings_to_bookmarks",
                    defaultValue: "Save playback settings to bookmarks"
                ))
                .font(.system(size: 18, weight: .bold))
                Text(String(
                    localized: "speak_help_playback_settings",
                    defaultValue: "Playback settings can be stored in Speak bookmarks and restored when speaking resumes from them."
                ))
                Text(String(
                    localized: "speak_help_playback_settings_example",
                    defaultValue: "For example, a bookmark can retain title, footnote, and chapter-change playback choices."
                ))
            }
        }
    }

    /// Android's shared Speak tutorial playlist link.
    private var tutorialLink: some View {
        Link(
            String(localized: "watch_tutorial_video", defaultValue: "Watch tutorial video (English)"),
            destination: tutorialURL
        )
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
    }
}
