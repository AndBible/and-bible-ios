import SwiftUI
import SwordKit

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

 Inputs: localized prompt copy, cipher-key binding, and owner commands

 Output: one app-owned Android text-entry dialog shared by Choose Document and Downloads

 Side effects: edits the supplied key and invokes only explicit caller actions

 Failure modes: Empty OK submissions remain manager-free but proceed to the shared retry decision
 */
struct ModulePickerUnlockDialog: View {
    let title: String
    let message: String
    @Binding var cipherKey: String
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
                    accessibilityIdentifier: "androidModulePickerUnlockDialogPassphrase",
                    focusAndSelectAllOnAppear: true
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
            unlockActionButton(
                title: String(localized: "show_unlock_info", defaultValue: "Module & unlock info"),
                identifier: "androidModulePickerUnlockDialogAction::info",
                action: onShowUnlockInfo
            )
            unlockActionButton(
                title: String(localized: "okay", defaultValue: "OK"),
                identifier: "androidModulePickerUnlockDialogAction::okay",
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
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.trailing)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
        .accessibilityIdentifier(identifier)
    }
}

/**
 Presents Android's complete one-module passphrase and retry decision for every app entrypoint.

 The bound `ModuleUnlockSession` owns only credential input and dialog state. Full picker, Downloads,
 and startup retain their own selection, refresh, dismissal, and multi-module queue responsibilities
 through the terminal callbacks.

 Inputs:
 - one bound exact-module credential session
 - manager adapter and surface-owned accepted/declined callbacks

 Output: passphrase, About, or Yes/No retry presentation using the shared Android dialog components

 Side effects:
 - submits one non-empty key through the session's manager adapter; empty OK enters retry without
   invoking the manager
 - invokes exactly one terminal callback after the session records its terminal outcome

 Failure modes:
 - rejection and Cancel retain the same module behind explicit retry confirmation
 - stale actions after completion are ignored by `ModuleUnlockSession`
 */
struct ModuleUnlockFlowView: View {
    /// Surface-owned session retained across every dialog phase.
    @Binding var session: ModuleUnlockSession?

    /// Manager adapter that validates and persists one exact key submission.
    let unlockModule: (String, String) -> Bool

    /// Surface-specific accepted work such as refresh, selection, or queue advancement.
    let onAccepted: (ModuleInfo) -> Void

    /// Surface-specific decline work such as retaining a picker or advancing a startup queue.
    let onDeclined: (ModuleInfo) -> Void

    var body: some View {
        let information = informationPresentation
        Color.clear
            .allowsHitTesting(false)
            .overlay {
                if let presentedSession = session {
                    switch presentedSession.presentation {
                    case .passphrase:
                        ModulePickerUnlockDialog(
                            title: ModuleUnlockActionCoordinator.promptTitle(for: presentedSession.module),
                            message: String(
                                localized: "enter_module_passphrase",
                                defaultValue: "Enter the module passphrase."
                            ),
                            cipherKey: cipherKeyBinding(for: presentedSession.id),
                            onUnlock: { self.submitPassphrase(expectedID: presentedSession.id) },
                            onShowUnlockInfo: {
                                self.showUnlockInformation(expectedID: presentedSession.id)
                            },
                            onCancel: { self.cancelPassphrase(expectedID: presentedSession.id) }
                        )
                    case .retryConfirmation:
                        ModulePickerDecisionDialog(
                            title: String(
                                localized: "try_again_passphrase",
                                defaultValue: "Passphrase did not work, try again?"
                            ),
                            message: "",
                            actions: [
                                .init(
                                    id: "yes",
                                    title: String(localized: "yes", defaultValue: "Yes"),
                                    role: nil,
                                    perform: { self.retryPassphrase(expectedID: presentedSession.id) }
                                ),
                                .init(
                                    id: "no",
                                    title: String(localized: "no", defaultValue: "No"),
                                    role: nil,
                                    perform: { self.declinePassphrase(expectedID: presentedSession.id) }
                                ),
                            ]
                        )
                    case .information, .completed:
                        EmptyView()
                    }
                }
            }
            .moduleBrowserModuleDetailsDialog(details: information?.details) {
                guard let expectedID = information?.sessionID else { return }
                mutateSession(expectedID: expectedID) { current in
                    current.resumeAfterInformation()
                }
            }
    }

    /// Immutable About payload and session identity captured by one rendered presentation.
    private struct InformationPresentation {
        let sessionID: ModuleUnlockSession.ID
        let details: ModuleBrowserModuleDetails
    }

    /// Derives About entirely from the exact session phase instead of duplicating presenter state.
    private var informationPresentation: InformationPresentation? {
        guard let session, session.presentation == .information else { return nil }
        return InformationPresentation(
            sessionID: session.id,
            details: ModuleBrowserModuleDetails(installedModule: session.module)
        )
    }

    /** Binds input only to the exact session that created the rendered text field. */
    private func cipherKeyBinding(for expectedID: ModuleUnlockSession.ID) -> Binding<String> {
        Binding(
            get: {
                guard self.session?.id == expectedID else { return "" }
                return self.session?.cipherKey ?? ""
            },
            set: { newValue in
                self.mutateSession(expectedID: expectedID) { current in
                    current.cipherKey = newValue
                }
            }
        )
    }

    /// Applies one command at the session's optional owner boundary with stale-ID rejection.
    @discardableResult
    private func mutateSession(
        expectedID: ModuleUnlockSession.ID,
        mutation: (inout ModuleUnlockSession) -> Void
    ) -> Bool {
        var owner = session
        let didMutate = ModuleUnlockSession.mutateOwnedSession(
            &owner,
            expectedID: expectedID,
            mutation: mutation
        )
        guard didMutate else { return false }
        session = owner
        return true
    }

    /** Submits one passphrase and forwards acceptance only after manager validation succeeds. */
    private func submitPassphrase(expectedID: ModuleUnlockSession.ID) {
        var outcome: ModuleUnlockSession.Outcome?
        var module: ModuleInfo?
        guard mutateSession(expectedID: expectedID, mutation: { current in
            module = current.module
            outcome = current.submit(unlockModule: unlockModule)
        }), outcome == .accepted, let module else { return }
        onAccepted(module)
    }

    /** Converts passphrase cancellation into Android's explicit same-module retry decision. */
    private func cancelPassphrase(expectedID: ModuleUnlockSession.ID) {
        mutateSession(expectedID: expectedID) { current in
            current.cancelPassphrase()
        }
    }

    /** Returns the retry decision to the same exact module's persisted-key passphrase editor. */
    private func retryPassphrase(expectedID: ModuleUnlockSession.ID) {
        mutateSession(expectedID: expectedID) { current in
            current.retry()
        }
    }

    /** Reports a decline only after the session records its terminal outcome. */
    private func declinePassphrase(expectedID: ModuleUnlockSession.ID) {
        var outcome: ModuleUnlockSession.Outcome?
        var module: ModuleInfo?
        guard mutateSession(expectedID: expectedID, mutation: { current in
            module = current.module
            outcome = current.decline()
        }), outcome == .declined, let module else { return }
        onDeclined(module)
    }

    /** Presents module metadata without validating, completing, or replacing the current session. */
    private func showUnlockInformation(expectedID: ModuleUnlockSession.ID) {
        mutateSession(expectedID: expectedID) { current in
            current.prepareForInformation()
        }
    }
}
