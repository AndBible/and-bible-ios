// AndroidActivityCommitBar.swift -- Shared Android activity Dismiss/Save action row

import SwiftUI

/**
 Renders the persistent two-action button bar used by Android management activities.

 Android's My Documents and page-management activities keep Dismiss and Save at the bottom of the
 activity instead of placing adaptive actions in an iOS navigation toolbar. The owner supplies its
 resolved content-surface colors and commands; this component owns only the repeated AppCompat
 button geometry, uppercase treatment, disabled state, and accessibility identifiers.

 Inputs:
 - localized dismiss and commit titles
 - owner-resolved surface, accent, and disabled colors
 - commit availability and explicit action closures

 Output: one fixed-height, app-owned activity action bar

 Side effects: invokes only the tapped owner action

 Failure modes: none
 */
struct AndroidActivityCommitBar: View {
    let dismissTitle: String
    let commitTitle: String
    let backgroundColor: Color
    let accentColor: Color
    let disabledColor: Color
    let isCommitEnabled: Bool
    let accessibilityPrefix: String
    let onDismiss: () -> Void
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            actionButton(
                title: dismissTitle,
                color: accentColor,
                accessibilityIdentifier: "\(accessibilityPrefix)DismissButton",
                action: onDismiss
            )

            actionButton(
                title: commitTitle,
                color: isCommitEnabled ? accentColor : disabledColor,
                accessibilityIdentifier: "\(accessibilityPrefix)SaveButton",
                action: onCommit
            )
            .disabled(!isCommitEnabled)
        }
        .frame(height: 58)
        .background(backgroundColor)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(accessibilityPrefix)CommitBar")
    }

    /** Builds one equal-width AppCompat-style text action. */
    private func actionButton(
        title: String,
        color: Color,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/**
 Renders Android's single full-width activity button bar action.

 Search and other activities whose XML uses `Widget.AppCompat.Button.ButtonBar.AlertDialog` expose
 one persistent bottom command rather than a raised iOS-style button. The owner supplies palette,
 enabled state, and behavior; this component shares the same height, typography, and flat action
 treatment as `AndroidActivityCommitBar`.
 */
struct AndroidActivitySingleActionBar: View {
    let title: String
    let backgroundColor: Color
    let accentColor: Color
    let disabledColor: Color
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? accentColor : disabledColor)
        .disabled(!isEnabled)
        .frame(height: 58)
        .background(backgroundColor)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
