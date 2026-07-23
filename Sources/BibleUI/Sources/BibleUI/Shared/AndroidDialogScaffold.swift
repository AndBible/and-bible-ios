// AndroidDialogScaffold.swift -- Shared AlertDialog content and action primitives

import SwiftUI

/**
 Composes the title, custom body, and trailing action regions inside `AndroidDialogWindow`.

 Feature dialogs retain their semantic controls while this scaffold owns the repeated AppCompat
 typography, spacing, action placement, and globally managed dialog palette. The scaffold does not
 draw a scrim or card; callers must place it inside the shared `AndroidDialogWindow` so every dialog
 keeps one presentation owner.

 Inputs: localized title plus feature-owned body and action views

 Output: one palette-aware AlertDialog content hierarchy

 Side effects: none; supplied controls own their commands

 Failure modes: none; long bodies must supply their own scroll container
 */
struct AndroidDialogScaffold<Content: View, Actions: View>: View {
    /// Localized AlertDialog title; empty titles omit the heading region.
    let title: String

    /// Feature-specific content between title and actions.
    private let content: Content

    /// Whether the Android dialog owns a trailing action-button region.
    private let showsActionRegion: Bool

    /// Android-ordered neutral, negative, and positive commands.
    private let actions: Actions

    /// Current appearance used only through the central AppCompat palette.
    @Environment(\.colorScheme) private var colorScheme

    /**
     Creates one shared AlertDialog content hierarchy.

     - Parameters:
       - title: Localized heading, or an empty string when Android omits the title.
       - showsActionRegion: Whether to reserve Android's trailing action-button region.
       - content: Feature-specific body controls.
       - actions: Android-ordered action controls.
     - Side effects: none until a supplied control is activated.
     - Failure modes: none.
     */
    init(
        title: String,
        showsActionRegion: Bool = true,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.showsActionRegion = showsActionRegion
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.top, 22)
                    .padding(.bottom, 12)
            }

            content

            if showsActionRegion {
                HStack(spacing: 8) {
                    actions
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: 500)
        .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
        .tint(AndroidDialogSurfacePalette.accent(for: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/**
 Renders one standard AppCompat AlertDialog text action.

 Inputs: localized title, enabled/destructive emphasis, stable identifier, and command

 Output: one uppercase trailing dialog action using the global dialog accent

 Side effects: invokes `action` after an enabled tap

 Failure modes: disabled actions ignore input
 */
struct AndroidDialogTextAction: View {
    let title: String
    let isEnabled: Bool
    let isDestructive: Bool
    let accessibilityIdentifier: String?
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /** Creates one shared text action without invoking its command. */
    init(
        title: String,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .textCase(.uppercase)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            isDestructive
                ? Color.red
                : AndroidDialogSurfacePalette.accent(for: colorScheme)
        )
        .opacity(isEnabled ? 1 : 0.42)
        .disabled(!isEnabled)
        .modifier(AndroidDialogOptionalIdentifier(identifier: accessibilityIdentifier))
    }
}

/**
 Renders the full-width, sentence-case command row used by Android custom AlertDialog layouts.

 Agent permissions and similar dialogs use button-bar rows rather than trailing uppercase actions.
 Centralizing that treatment prevents feature code from substituting raised cards or native iOS
 list rows for Android's transparent, palette-owned command controls.

 Inputs: localized title, destructive/enabled emphasis, stable identifier, and command

 Output: one full-width app-owned dialog command row

 Side effects: invokes `action` after an enabled tap

 Failure modes: disabled actions ignore input
 */
struct AndroidDialogListActionRow: View {
    let title: String
    let isEnabled: Bool
    let isDestructive: Bool
    let accessibilityIdentifier: String?
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /** Creates one transparent Android dialog command row without invoking it. */
    init(
        title: String,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(
                    isDestructive
                        ? Color.red
                        : AndroidDialogSurfacePalette.accent(for: colorScheme)
                )
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.42)
        .disabled(!isEnabled)
        .modifier(AndroidDialogOptionalIdentifier(identifier: accessibilityIdentifier))
    }
}

/// Applies a stable automation identifier only when a shared dialog control supplied one.
private struct AndroidDialogOptionalIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
