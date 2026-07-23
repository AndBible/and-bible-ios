// AndroidActivityListComponents.swift -- Shared AppCompat activity list primitives

import SwiftUI

/**
 Renders one selectable row in an app-owned Android activity list.

 Android dictionary, general-book, EPUB TOC, and EPUB search activities all use ordinary
 `ListView` rows separated by the application's content-surface divider. This component owns that
 repeated hit target, padding, divider, and palette projection so feature screens do not substitute
 native iOS `List` styling or independently redraw Android rows.

 Inputs: owner-resolved palette, stable identity, selection command, and feature row content

 Output: one full-width app-owned list button with Android-compatible minimum height

 Side effects: invokes the supplied selection command after a direct tap

 Failure modes: none; feature content controls its own truncation and accessibility labels
 */
struct AndroidActivityListRow<Content: View>: View {
    /// Palette inherited from the launching reader window or workspace.
    let palette: ReaderThemeSurfacePalette

    /// Stable UI-test identity for the complete row.
    let accessibilityIdentifier: String

    /// Feature-owned selection command.
    let action: () -> Void

    /// Feature-owned row label.
    private let content: Content

    /** Creates a shared activity row without invoking its command. */
    init(
        palette: ReaderThemeSurfacePalette,
        accessibilityIdentifier: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.palette = palette
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.foregroundColor)
        .background(palette.backgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.inactiveBorderColor)
                .frame(height: 1)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/**
 Renders Android's in-activity loading state using the shared Material progress indicator.

 Inputs are a localized status message, owner-resolved palette, and stable identity. The view fills
 the remaining activity viewport while retaining the same globally shared indicator implementation
 used by app-owned progress dialogs.

 Output: centered indicator and optional status text on the owner content surface

 Side effects: advances the indicator animation unless Reduce Motion is enabled

 Failure modes: an empty message omits the label without changing progress semantics
 */
struct AndroidActivityLoadingView: View {
    let message: String
    let palette: ReaderThemeSurfacePalette
    let accessibilityIdentifier: String

    var body: some View {
        VStack(spacing: 14) {
            AndroidIndeterminateProgressIndicator(
                trackColor: palette.inactiveBorderColor,
                accentColor: palette.controlAccentColor
            )
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 16))
                    .foregroundStyle(palette.secondaryForegroundColor)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(palette.backgroundColor)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/**
 Renders Android's plain empty-list message without iOS `ContentUnavailableView` illustration.

 Inputs are localized primary/optional supporting text plus the owner palette. The component owns
 only shared empty-list typography and centering; navigation and recovery remain feature-owned.

 Output: a viewport-filling, app-owned empty list state

 Side effects: none

 Failure modes: a nil or empty detail omits the supporting line
 */
struct AndroidActivityEmptyListView: View {
    let title: String
    let detail: String?
    let palette: ReaderThemeSurfacePalette
    let accessibilityIdentifier: String

    /** Creates a plain empty-list state without altering activity navigation. */
    init(
        title: String,
        detail: String? = nil,
        palette: ReaderThemeSurfacePalette,
        accessibilityIdentifier: String
    ) {
        self.title = title
        self.detail = detail
        self.palette = palette
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(palette.foregroundColor)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.secondaryForegroundColor)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(palette.backgroundColor)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
