// AndroidDialogTextInput.swift -- Shared AppCompat-style dialog text input

import SwiftUI
import UIKit

/**
 Renders the application's shared text-entry treatment inside app-owned Android dialogs.

 The control centralizes the AppCompat dialog field fill, border, foreground, and multiline
 geometry so feature dialogs do not fall back to iOS rounded fields, Forms, or local color guesses.
 Focus and validation remain with the owning dialog. The encrypted-module prompt may opt into
 UIKit's public first-responder and text-selection APIs so an existing key is focused and selected
 when the field joins a window on iOS 17.

 Inputs: localized placeholder, text binding, active color scheme, multiline policy, and optional
 first-window-attachment selection

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
    let focusAndSelectAllOnAppear: Bool

    /** Creates one shared dialog input, optionally masking secure preference values. */
    init(
        placeholder: String,
        text: Binding<String>,
        colorScheme: ColorScheme,
        isMultiline: Bool,
        isSecure: Bool = false,
        accessibilityIdentifier: String,
        focusAndSelectAllOnAppear: Bool = false
    ) {
        self.placeholder = placeholder
        _text = text
        self.colorScheme = colorScheme
        self.isMultiline = isMultiline
        self.isSecure = isSecure
        self.accessibilityIdentifier = accessibilityIdentifier
        self.focusAndSelectAllOnAppear = focusAndSelectAllOnAppear
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
        if focusAndSelectAllOnAppear && !isMultiline && !isSecure {
            AndroidDialogSelectAllTextFieldRepresentable(
                placeholder: placeholder,
                text: $text,
                colorScheme: colorScheme,
                accessibilityIdentifier: accessibilityIdentifier
            )
        } else if isSecure {
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

/**
 A plain UIKit field whose one-time window-attachment behavior matches Android's prompt selection.

 `didMoveToWindow`, `becomeFirstResponder()`, and `selectAll(_:)` are public UIKit lifecycle and
 editing APIs available on iOS 17. The field owns only selection state; edited text remains owned by
 the caller's binding through the representable coordinator.
 */
final class AndroidDialogSelectAllTextField: UITextField {
    /// Enables focus and full selection on the first non-nil window attachment.
    var selectAllOnFirstWindowAttachment = false

    /// Prevents later hierarchy moves from overwriting an explicit user selection.
    private var didApplyInitialSelection = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil,
              selectAllOnFirstWindowAttachment,
              !didApplyInitialSelection else { return }
        didApplyInitialSelection = true
        _ = becomeFirstResponder()
        selectAll(nil)
    }
}

/// Bridges the one UIKit-only selection lifecycle to the existing SwiftUI credential binding.
private struct AndroidDialogSelectAllTextFieldRepresentable: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let colorScheme: ColorScheme
    let accessibilityIdentifier: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> AndroidDialogSelectAllTextField {
        let field = AndroidDialogSelectAllTextField()
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        field.accessibilityIdentifier = accessibilityIdentifier
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        applyPresentation(to: field)
        field.text = text
        field.selectAllOnFirstWindowAttachment = true
        return field
    }

    func updateUIView(_ field: AndroidDialogSelectAllTextField, context: Context) {
        context.coordinator.text = $text
        if field.text != text {
            field.text = text
        }
        field.placeholder = placeholder
        field.accessibilityIdentifier = accessibilityIdentifier
        applyPresentation(to: field)
    }

    /**
     Keeps the UIKit-backed single-line editor at its intrinsic text-field height inside SwiftUI.

     The dialog supplies the available width, while UIKit remains authoritative for the control's
     vertical size. Without this bridge, a flexible dialog proposal can stretch the editor through
     the viewport instead of rendering one ordinary input line.
     */
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView field: AndroidDialogSelectAllTextField,
        context: Context
    ) -> CGSize? {
        let intrinsicSize = field.intrinsicContentSize
        return CGSize(
            width: proposal.width ?? intrinsicSize.width,
            height: intrinsicSize.height
        )
    }

    private func applyPresentation(to field: UITextField) {
        field.textColor = UIColor(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
        field.tintColor = UIColor(AndroidDialogSurfacePalette.accent(for: colorScheme))
    }

    final class Coordinator: NSObject {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func editingChanged(_ sender: UITextField) {
            text.wrappedValue = sender.text ?? ""
        }
    }
}
