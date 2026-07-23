// AndroidTextDisplayHelpDialog.swift -- Scope-specific Text Options help

import SwiftUI

/**
 Presents Android `TextDisplaySettingsActivity.help()` in the shared app-owned dialog window.

 Android varies the explanation and reset inheritance target across global, workspace, and window
 scopes. This view keeps that behavior centralized, renders the same exact reset/workspace assets as
 the live activity, and uses Android localization keys instead of screenshot-derived copy.

 Inputs: current text-display scope and owner dismissal callback

 Output: one scrollable AppCompat help dialog with tutorial and project-support links

 Side effects: opens explicitly tapped links and invokes `onDismiss` after outside-tap or OK

 Failure modes: none; URLs are compile-time Android constants
 */
struct AndroidTextDisplayHelpDialog: View {
    let scope: TextDisplaySettingsScope
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidTextDisplayHelpDialog",
            onOutsideTap: onDismiss
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Link(
                            String(
                                localized: "watch_tutorial_video",
                                defaultValue: "Watch tutorial video (English)"
                            ),
                            destination: URL(
                                string: "https://www.youtube.com/playlist?list=PLD-W_Iw-N2Mmiq_X6G-vDhoAIq9sDnrIQ"
                            )!
                        )
                        .italic()

                        scopeExplanation

                        resetExplanation

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            AndBibleIconView(name: "DrawerSponsorDevelopment", size: 22)
                                .foregroundStyle(AndroidDialogSurfacePalette.secondaryText(for: colorScheme))
                            Text(String(localized: "buy_development2", defaultValue: "Support project") + ":")
                                .fontWeight(.semibold)
                            Link(
                                String(localized: "buy_development", defaultValue: "Buy development work"),
                                destination: URL(string: "https://shop.andbible.org")!
                            )
                        }
                    }
                    .font(.system(size: 17))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Spacer()
                    Button(String(localized: "okay", defaultValue: "OK"), action: onDismiss)
                        .font(.system(size: 17, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
                        .accessibilityIdentifier("androidTextDisplayHelpOKButton")
                }
            }
            .padding(24)
            .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
        }
    }

    /// Android's localized title for the current settings owner.
    private var title: String {
        switch scope {
        case .global:
            String(localized: "global_text_options_help_title", defaultValue: "Global text options")
        case .workspace:
            String(localized: "workspace_text_options_help_title", defaultValue: "Workspace text options")
        case .window:
            String(localized: "window_text_options_help_title", defaultValue: "Window text options")
        }
    }

    /// Scope-specific inheritance explanation from Android string resources.
    @ViewBuilder
    private var scopeExplanation: some View {
        switch scope {
        case .global:
            Text(
                String(
                    localized: "global_text_options_help1",
                    defaultValue: "These are the global default settings for all workspaces. Each workspace can override these with its own settings."
                )
            )
        case .workspace:
            Text(
                String(localized: "workspace_text_options_help1")
                    + " "
                    + String(localized: "workspace_text_options_help2")
            )
        case .window:
            iconExplanation(
                asset: "WorkspaceOverride",
                format: String(
                    localized: "window_text_options_help1",
                    defaultValue: "%@ icon indicates that the setting comes from the workspace settings."
                )
            )
        }
    }

    /// Android's reset-button explanation with the correct inheritance destination.
    private var resetExplanation: some View {
        let resetTarget = scope == .window
            ? String(
                localized: "reset_workspace_defaults",
                defaultValue: "workspace default values"
            )
            : String(localized: "reset_defaults", defaultValue: "default values")
        let format = String(
            localized: "text_options_reset_help",
            defaultValue: "Use %1$@ button to reset all these settings back to %2$@."
        )
        let text = String(format: format, "", resetTarget)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .top, spacing: 8) {
            AndBibleIconView(name: "ActivityReset", size: 22)
                .foregroundStyle(AndroidDialogSurfacePalette.secondaryText(for: colorScheme))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /** Renders one inline Android drawable placeholder as the exact shared vector asset. */
    private func iconExplanation(asset: String, format: String) -> some View {
        let text = String(format: format, "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .top, spacing: 8) {
            AndBibleIconView(name: asset, size: 22)
                .foregroundStyle(AndroidDialogSurfacePalette.secondaryText(for: colorScheme))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
