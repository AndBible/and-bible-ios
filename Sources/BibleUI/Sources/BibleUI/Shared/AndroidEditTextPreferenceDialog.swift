// AndroidEditTextPreferenceDialog.swift -- Shared AppCompat EditTextPreference window

import SwiftUI

/**
 Canonical app-owned editor for Android `EditTextPreference` rows.

 The dialog stages edits until OK, retains invalid input with an inline error, and dismisses without
 mutation on Cancel or outside tap. Owners provide validation and persistence instead of rebuilding
 dialog geometry or silently adopting native iOS sheets and alerts.
 */
struct AndroidEditTextPreferenceDialog: View {
    let title: String
    let placeholder: String
    let isSecure: Bool
    let accessibilityIdentifier: String
    let validator: ((String) -> String?)?
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: String
    @State private var validationMessage: String?

    /**
     Creates a staged Android text-preference editor.

     - Parameters:
       - title: Localized preference title.
       - initialText: Current persisted value copied into the draft.
       - placeholder: Localized field placeholder.
       - isSecure: Whether the underlying text engine masks the draft.
       - accessibilityIdentifier: Stable dialog identity used to derive field/action IDs.
       - validator: Optional pure validator returning localized error copy.
       - onCancel: Owner dismissal without persistence.
       - onSave: Owner commit called once after validation succeeds.
     - Side effects: Mutates only local draft state until `onSave` is invoked.
     - Failure modes: Validator failures remain visible and keep the dialog open.
     */
    init(
        title: String,
        initialText: String,
        placeholder: String,
        isSecure: Bool = false,
        accessibilityIdentifier: String,
        validator: ((String) -> String?)? = nil,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.isSecure = isSecure
        self.accessibilityIdentifier = accessibilityIdentifier
        self.validator = validator
        self.onCancel = onCancel
        self.onSave = onSave
        _draft = State(initialValue: initialText)
    }

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: accessibilityIdentifier,
            onOutsideTap: onCancel
        ) {
            AndroidDialogScaffold(title: title) {
                VStack(alignment: .leading, spacing: 12) {
                    AndroidDialogTextInput(
                        placeholder: placeholder,
                        text: $draft,
                        colorScheme: colorScheme,
                        isMultiline: false,
                        isSecure: isSecure,
                        accessibilityIdentifier: "\(accessibilityIdentifier)Field"
                    )
                    .onSubmit(commit)

                    if let validationMessage {
                        Text(validationMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("\(accessibilityIdentifier)ValidationMessage")
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            } actions: {
                AndroidDialogTextAction(
                    title: String(localized: "cancel"),
                    accessibilityIdentifier: "\(accessibilityIdentifier)Action::cancel",
                    action: onCancel
                )
                AndroidDialogTextAction(
                    title: String(localized: "okay", defaultValue: "OK"),
                    accessibilityIdentifier: "\(accessibilityIdentifier)Action::confirm",
                    action: commit
                )
            }
        }
    }

    /** Validates and commits the current draft without dismissing on failure. */
    private func commit() {
        if let validationMessage = validator?(draft) {
            self.validationMessage = validationMessage
            return
        }
        validationMessage = nil
        onSave(draft)
    }
}
