// AIPromptDialogPresentation.swift -- Android prompt-management AlertDialog surfaces

import BibleCore
import SwiftUI

/** Actions exposed by Android's long-press prompt menu. */
enum AIPromptRowAction: String, Hashable {
    /// Hides one code-owned built-in prompt from prompt management.
    case hide
    /// Creates an editable user copy of any persisted or effective prompt.
    case copy
    /// Swaps the prompt with its previous editable category sibling.
    case moveUp
    /// Swaps the prompt with its next editable category sibling.
    case moveDown
    /// Opens Android's category-choice dialog.
    case moveToCategory
    /// Opens Android's prompt-deletion confirmation.
    case delete

    /// Exact Android-localized label shown in the action list.
    var title: String {
        switch self {
        case .hide:
            return String(localized: "ai_hide_prompt", defaultValue: "Hide")
        case .copy:
            return String(localized: "copy", defaultValue: "Copy")
        case .moveUp:
            return String(localized: "move_category_up", defaultValue: "Move up")
        case .moveDown:
            return String(localized: "move_category_down", defaultValue: "Move down")
        case .moveToCategory:
            return String(localized: "move_to_category", defaultValue: "Move to category…")
        case .delete:
            return String(localized: "delete", defaultValue: "Delete")
        }
    }
}

/** Actions exposed by Android's long-press category menu. */
enum AIPromptCategoryAction: String, Hashable {
    /// Swaps the category with the preceding mutable category.
    case moveUp
    /// Swaps the category with the following mutable category.
    case moveDown
    /// Hides the category from AI action surfaces.
    case hide
    /// Restores the category to AI action surfaces.
    case show
    /// Opens Android's category-name editor.
    case rename
    /// Opens Android's two-disposition category-deletion dialog.
    case delete

    /// Exact Android-localized label shown in the action list.
    var title: String {
        switch self {
        case .moveUp:
            return String(localized: "move_category_up", defaultValue: "Move up")
        case .moveDown:
            return String(localized: "move_category_down", defaultValue: "Move down")
        case .hide:
            return String(localized: "hide_category", defaultValue: "Hide from AI actions")
        case .show:
            return String(localized: "show_category", defaultValue: "Show in AI actions")
        case .rename:
            return String(localized: "rename", defaultValue: "Rename")
        case .delete:
            return String(localized: "delete_category", defaultValue: "Delete category")
        }
    }
}

/** Pure visibility rules copied from Android's prompt and category long-press menus. */
enum AIPromptDialogBehavior {
    /**
     Resolves Android's ordered prompt action list for one source and sibling position.

     - Parameters:
       - origin: Source ownership controlling hide and mutation availability.
       - canMoveUp: Whether an editable category sibling precedes the prompt.
       - canMoveDown: Whether an editable category sibling follows the prompt.
     - Returns: Actions in `AiSettingsActivity.showPromptContextMenu()` order.
     - Side effects: None.
     - Failure modes: None; unsupported mutations are omitted.
     */
    static func promptActions(
        origin: PromptOrigin,
        canMoveUp: Bool,
        canMoveDown: Bool
    ) -> [AIPromptRowAction] {
        var actions: [AIPromptRowAction] = []
        if origin == .builtIn {
            actions.append(.hide)
        }
        actions.append(.copy)
        guard origin == .user else { return actions }
        if canMoveUp { actions.append(.moveUp) }
        if canMoveDown { actions.append(.moveDown) }
        actions.append(.moveToCategory)
        actions.append(.delete)
        return actions
    }

    /**
     Resolves Android's ordered category action list.

     - Parameters:
       - isBuiltIn: Whether the category is code-owned and limited to visibility changes.
       - isHidden: Current effective visibility state.
       - canMoveUp: Whether a mutable category precedes this category.
       - canMoveDown: Whether a mutable category follows this category.
     - Returns: Actions in `AiSettingsActivity.showCategoryContextMenu()` order.
     - Side effects: None.
     - Failure modes: None; built-in mutation actions are omitted.
     */
    static func categoryActions(
        isBuiltIn: Bool,
        isHidden: Bool,
        canMoveUp: Bool,
        canMoveDown: Bool
    ) -> [AIPromptCategoryAction] {
        var actions: [AIPromptCategoryAction] = []
        if !isBuiltIn {
            if canMoveUp { actions.append(.moveUp) }
            if canMoveDown { actions.append(.moveDown) }
        }
        actions.append(isHidden ? .show : .hide)
        if !isBuiltIn {
            actions.append(.rename)
            actions.append(.delete)
        }
        return actions
    }
}

/** Immutable prompt action-list identity retained while its centered dialog is visible. */
struct AIPromptActionDialogContext: Equatable {
    /// Effective prompt identity used by the selected mutation.
    let promptID: UUID
    /// Prompt name used as Android's dialog title.
    let promptName: String
    /// Ordered source-appropriate actions.
    let actions: [AIPromptRowAction]
}

/** Immutable category action-list identity retained while its centered dialog is visible. */
struct AIPromptCategoryDialogContext: Equatable {
    /// Persisted category identity used by the selected mutation.
    let categoryID: UUID
    /// Category name used as Android's dialog title.
    let categoryName: String
    /// Whether visibility uses the built-in global override path.
    let isBuiltIn: Bool
    /// Ordered source-appropriate actions.
    let actions: [AIPromptCategoryAction]
}

/**
 Blocking, app-owned dimmer that centers one prompt-specific Android AlertDialog panel.

 The underlying navigation destination stays mounted but inaccessible. Tapping the dimmer invokes
 Android's cancellable-dialog dismissal callback; panel taps never pass through to the list.
 */
struct AIPromptDialogOverlay<Content: View>: View {
    /// Current appearance used for Android's light and dark dimmer strength.
    @Environment(\.colorScheme) private var colorScheme

    /// Dismissal callback for Android's outside-tap cancellation behavior.
    let onDismiss: () -> Void
    /// Dialog panel rendered above the dimmer.
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(colorScheme == .dark ? 0.62 : 0.38)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                    .accessibilityHidden(true)

                content()
                    .frame(maxHeight: geometry.size.height * 0.9)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(30)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("aiPromptDialogOverlay")
    }
}

/** Android AppCompat-shaped prompt dialog surface with an optional action-button region. */
private struct AIPromptAlertDialogSurface<Content: View, Actions: View>: View {
    /// Current appearance for Android's explicit dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    /// Optional localized title; message-only dialogs omit the title region.
    let title: String?
    /// Whether Android supplied negative or positive buttons for this dialog.
    let showsActionRegion: Bool
    /// Dialog-specific content.
    @ViewBuilder let content: () -> Content
    /// Android-ordered negative and positive actions.
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
            }

            content()

            if showsActionRegion {
                HStack(spacing: 6) {
                    actions()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: 430)
        .background(
            AndroidDialogSurfacePalette.background(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .shadow(color: .black.opacity(0.3), radius: 18, x: 0, y: 10)
        .tint(AndroidDialogSurfacePalette.accent(for: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/** Centered Android `setItems` action list used only after a prompt or category long press. */
struct AIPromptActionListDialog<Action: Hashable>: View {
    /// Current appearance for Android's row text and separators.
    @Environment(\.colorScheme) private var colorScheme

    /// Prompt or category name displayed as the AlertDialog title.
    let title: String
    /// Ordered available actions.
    let actions: [Action]
    /// Localized row-label resolver.
    let label: (Action) -> String
    /// Selection callback; the parent owns dismissal and any chained dialog.
    let onSelect: (Action) -> Void

    var body: some View {
        AIPromptAlertDialogSurface(title: title, showsActionRegion: false) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                        Button { onSelect(action) } label: {
                            Text(label(action))
                                .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < actions.count - 1 {
                            Divider()
                                .padding(.leading, 20)
                        }
                    }
                }
            }
            .frame(maxHeight: 520)
        } actions: {
            EmptyView()
        }
        .accessibilityIdentifier("aiPromptActionListDialog")
    }
}

/** Android `setItems` choice dialog with the platform's explicit Cancel action. */
struct AIPromptChoiceDialog<Choice: Hashable>: View {
    /// Current appearance for Android's row text.
    @Environment(\.colorScheme) private var colorScheme

    /// Localized dialog title.
    let title: String
    /// Ordered available choices.
    let choices: [Choice]
    /// Localized choice-label resolver.
    let label: (Choice) -> String
    /// Selection callback; the parent owns mutation and dismissal.
    let onSelect: (Choice) -> Void
    /// Negative-button callback.
    let onCancel: () -> Void

    var body: some View {
        AIPromptAlertDialogSurface(title: title, showsActionRegion: true) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        Button { onSelect(choice) } label: {
                            Text(label(choice))
                                .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < choices.count - 1 {
                            Divider()
                                .padding(.leading, 20)
                        }
                    }
                }
            }
            .frame(maxHeight: 520)
        } actions: {
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "cancel", defaultValue: "Cancel"),
                action: onCancel
            )
        }
        .accessibilityIdentifier("aiPromptChoiceDialog")
    }
}

/** Android prompt/category name editor with draft-only text and explicit OK/Cancel actions. */
struct AIPromptTextInputDialog: View {
    /// Current appearance for Android's field treatment.
    @Environment(\.colorScheme) private var colorScheme

    /// Localized dialog title.
    let title: String
    /// Localized field hint.
    let hint: String
    /// Parent-owned draft; cancellation does not persist it.
    @Binding var text: String
    /// Positive-button callback.
    let onSave: () -> Void
    /// Negative-button callback.
    let onCancel: () -> Void

    /// Whether Android's non-empty trimmed-name requirement is currently satisfied.
    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        AIPromptAlertDialogSurface(title: title, showsActionRegion: true) {
            TextField(hint, text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    AndroidDialogSurfacePalette.fieldBackground(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(AndroidDialogSurfacePalette.fieldBorder(for: colorScheme), lineWidth: 1)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        } actions: {
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "cancel", defaultValue: "Cancel"),
                action: onCancel
            )
            AIAndroidDialogAction(
                title: String(localized: "okay", defaultValue: "OK"),
                isEnabled: canSave,
                action: onSave
            )
        }
        .accessibilityIdentifier("aiPromptTextInputDialog")
    }
}

/** Android prompt-management confirmation with source-localized message and button labels. */
struct AIPromptConfirmationDialog: View {
    /// Optional Android title; `nil` represents a message-only confirmation.
    let title: String?
    /// Localized confirmation message.
    let message: String
    /// Localized negative-button label.
    let negativeTitle: String
    /// Localized positive-button label.
    let positiveTitle: String
    /// Negative-button callback.
    let onCancel: () -> Void
    /// Positive-button callback.
    let onConfirm: () -> Void

    var body: some View {
        AIPromptAlertDialogSurface(title: title, showsActionRegion: true) {
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, title == nil ? 20 : 8)
                .padding(.bottom, 8)
        } actions: {
            Spacer()
            AIAndroidDialogAction(title: negativeTitle, action: onCancel)
            AIAndroidDialogAction(title: positiveTitle, action: onConfirm)
        }
        .accessibilityIdentifier("aiPromptConfirmationDialog")
    }
}
