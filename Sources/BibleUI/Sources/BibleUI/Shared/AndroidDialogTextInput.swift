// AndroidDialogTextInput.swift -- Shared AppCompat-style dialog text input

import SwiftUI

/**
 Renders the application's shared text-entry treatment inside app-owned Android dialogs.

 The control centralizes the AppCompat dialog field fill, border, foreground, and multiline
 geometry so feature dialogs do not fall back to iOS rounded fields, Forms, or local color guesses.
 Focus and validation remain with the owning dialog.

 Inputs: localized placeholder, text binding, active color scheme, and multiline policy

 Output: one app-owned text field using the shared Android dialog palette

 Side effects: mutates only the supplied text binding

 Failure modes: none; validation is intentionally delegated to the owner
 */
struct AndroidDialogTextInput: View {
    let placeholder: String
    @Binding var text: String
    let colorScheme: ColorScheme
    let isMultiline: Bool
    let isSecure: Bool
    let accessibilityIdentifier: String

    /** Creates one shared dialog input, optionally masking secure preference values. */
    init(
        placeholder: String,
        text: Binding<String>,
        colorScheme: ColorScheme,
        isMultiline: Bool,
        isSecure: Bool = false,
        accessibilityIdentifier: String
    ) {
        self.placeholder = placeholder
        _text = text
        self.colorScheme = colorScheme
        self.isMultiline = isMultiline
        self.isSecure = isSecure
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        input
        .textFieldStyle(.plain)
        .lineLimit(isMultiline ? 3...6 : 1...1)
        .padding(10)
        .background(AndroidDialogSurfacePalette.fieldBackground(for: colorScheme))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(AndroidDialogSurfacePalette.fieldBorder(for: colorScheme), lineWidth: 1)
        }
        .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /// Selects the secure or plain system text engine while retaining shared app-owned chrome.
    @ViewBuilder
    private var input: some View {
        if isSecure {
            SecureField(placeholder, text: $text)
        } else {
            TextField(
                placeholder,
                text: $text,
                axis: isMultiline ? .vertical : .horizontal
            )
        }
    }
}
