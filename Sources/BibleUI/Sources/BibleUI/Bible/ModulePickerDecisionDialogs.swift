import SwiftUI

/**
 Adapts module-selection decisions to the application's canonical Android dialog.

 Module picker and Downloads call sites retain their domain-specific action model while this
 adapter delegates scrim, palette, geometry, typography, and action accessibility to
 `AndroidDecisionDialog`. This prevents the two document activities from drawing a separate
 approximation of the same AppCompat surface.

 Inputs: localized title/message and ordered semantic module actions

 Output: one shared app-owned Android decision dialog

 Side effects: invokes only the selected caller-owned action

 Failure modes: none
 */
struct ModulePickerDecisionDialog: View {
    /// Domain action retained for source compatibility with module picker and Downloads callers.
    struct Action: Identifiable {
        let id: String
        let title: String
        let role: ButtonRole?
        let perform: () -> Void
    }

    let title: String
    let message: String
    let actions: [Action]

    /// Projects module actions into the shared Android decision-dialog contract.
    var body: some View {
        AndroidDecisionDialog(
            title: title,
            message: message,
            actions: actions.map { action in
                AndroidDecisionDialog.Action(
                    id: action.id,
                    title: action.title,
                    style: action.role == .destructive ? .destructive : .normal,
                    perform: action.perform
                )
            },
            accessibilityIdentifier: "androidModulePickerDecisionDialog"
        )
    }
}

/**
 Renders encrypted-module unlock through the shared AppCompat dialog primitives.

 Inputs: localized prompt copy, cipher-key binding, optional information action, and owner commands

 Output: one app-owned Android text-entry dialog shared by Choose Document and Downloads

 Side effects: edits the supplied key and invokes only explicit caller actions

 Failure modes: Unlock remains disabled while the key is empty; validation stays with the owner
 */
struct ModulePickerUnlockDialog: View {
    let title: String
    let message: String
    @Binding var cipherKey: String
    let showUnlockInfo: Bool
    let onUnlock: () -> Void
    let onShowUnlockInfo: () -> Void
    let onCancel: () -> Void

    /// Active AppCompat palette source shared with every other app-owned dialog.
    @Environment(\.colorScheme) private var colorScheme

    /// Composes the unlock prompt without native alert, material-card, or rounded-field styling.
    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidModulePickerUnlockDialog",
            allowsOutsideDismissal: false,
            onOutsideTap: {}
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))

                Text(message)
                    .font(.system(size: 17))
                    .foregroundStyle(AndroidDialogSurfacePalette.secondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                AndroidDialogTextInput(
                    placeholder: String(localized: "passphrase", defaultValue: "Passphrase"),
                    text: $cipherKey,
                    colorScheme: colorScheme,
                    isMultiline: false,
                    accessibilityIdentifier: "androidModulePickerUnlockDialogPassphrase"
                )

                ViewThatFits(in: .horizontal) {
                    unlockActions(axis: .horizontal)
                    unlockActions(axis: .vertical)
                }
            }
            .padding(22)
            .frame(maxWidth: 500)
        }
    }

    /// Axis choices used by the adaptive Android action layout.
    private enum UnlockActionAxis {
        case horizontal
        case vertical
    }

    /** Builds Android dialog actions in source order with stable semantic identifiers. */
    @ViewBuilder
    private func unlockActions(axis: UnlockActionAxis) -> some View {
        let actions = Group {
            unlockActionButton(
                title: String(localized: "cancel"),
                identifier: "androidModulePickerUnlockDialogAction::cancel",
                action: onCancel
            )
            if showUnlockInfo {
                unlockActionButton(
                    title: String(localized: "show_unlock_info", defaultValue: "Module & unlock info"),
                    identifier: "androidModulePickerUnlockDialogAction::info",
                    action: onShowUnlockInfo
                )
            }
            unlockActionButton(
                title: String(localized: "unlock", defaultValue: "Unlock"),
                identifier: "androidModulePickerUnlockDialogAction::unlock",
                isEnabled: !cipherKey.isEmpty,
                action: onUnlock
            )
        }

        switch axis {
        case .horizontal:
            HStack(spacing: 18) {
                Spacer(minLength: 0)
                actions
            }
        case .vertical:
            VStack(alignment: .trailing, spacing: 14) {
                actions
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /** Builds one shared-palette text action without native button chrome. */
    private func unlockActionButton(
        title: String,
        identifier: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.trailing)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
        .accessibilityIdentifier(identifier)
    }
}
