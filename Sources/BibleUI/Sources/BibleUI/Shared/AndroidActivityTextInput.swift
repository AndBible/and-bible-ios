// AndroidActivityTextInput.swift -- Shared owner-themed AppCompat activity input

import SwiftUI

/**
 Renders the shared single-line text-entry treatment used inside app-owned Android activities.

 Unlike a native `Form` field or the dialog-specific input component, this control inherits its
 colors from the owning reader/workspace activity. It centralizes the plain AppCompat geometry,
 underline, placeholder contrast, and minimum touch height so feature activities do not reconstruct
 text fields from screenshots or fall back to iOS rounded controls.

 Inputs: localized placeholder, text binding, owner-resolved foreground/fill/border colors, and a
 stable accessibility identifier. Search-like owners may also supply focus, keyboard-submit, and
 autocorrection policy without rebuilding the field treatment locally.

 Output: one app-owned, single-line activity text field.

 Side effects: mutates only the supplied text binding.

 Failure modes: validation and focus policy remain with the owning activity.
 */
struct AndroidActivityTextInput: View {
    /// Localized hint shown while the field is empty.
    let placeholder: String

    /// Owner-controlled text value.
    @Binding var text: String

    /// Owner-resolved primary text color.
    let foregroundColor: Color

    /// Owner-resolved subtle input fill.
    let backgroundColor: Color

    /// Owner-resolved inactive underline color.
    let borderColor: Color

    /// Stable UI-test and accessibility identity.
    let accessibilityIdentifier: String

    /// Optional owner focus binding for Android activities that explicitly focus or dismiss input.
    let focus: FocusState<Bool>.Binding?

    /// Whether the platform should expose a Search return-key treatment.
    let usesSearchSubmitLabel: Bool

    /// Whether spell correction and automatic capitalization should be disabled.
    let usesLiteralInputBehavior: Bool

    /// Optional command invoked by the field's keyboard submit action.
    let onSubmit: (() -> Void)?

    /**
     Creates one shared activity field without mutating focus or text.

     - Parameters:
       - placeholder: Localized empty-state hint.
       - text: Owner-controlled value.
       - foregroundColor: Owner palette primary text.
       - backgroundColor: Owner palette subtle field fill.
       - borderColor: Owner palette inactive underline.
       - accessibilityIdentifier: Stable UI-test identity.
       - focus: Optional focus-state binding used by Search-like activities.
       - usesSearchSubmitLabel: Whether the keyboard return key is labeled Search.
       - usesLiteralInputBehavior: Whether autocorrection and capitalization are disabled.
       - onSubmit: Optional keyboard-submit command.
     - Side effects: none during initialization.
     - Failure modes: none; omitted behavior parameters preserve the existing passive field.
     */
    init(
        placeholder: String,
        text: Binding<String>,
        foregroundColor: Color,
        backgroundColor: Color,
        borderColor: Color,
        accessibilityIdentifier: String,
        focus: FocusState<Bool>.Binding? = nil,
        usesSearchSubmitLabel: Bool = false,
        usesLiteralInputBehavior: Bool = false,
        onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        _text = text
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        self.accessibilityIdentifier = accessibilityIdentifier
        self.focus = focus
        self.usesSearchSubmitLabel = usesSearchSubmitLabel
        self.usesLiteralInputBehavior = usesLiteralInputBehavior
        self.onSubmit = onSubmit
    }

    /**
     Builds the shared AppCompat-style field.

     - Returns: A plain, single-line field with owner palette and Android-sized padding.
     - Side effects: Editing writes through `text`.
     - Failure modes: Empty and malformed values remain visible for caller validation.
     */
    @ViewBuilder
    var body: some View {
        if let focus {
            configuredField
                .focused(focus)
        } else {
            configuredField
        }
    }

    /// Applies the common activity geometry plus optional owner keyboard behavior.
    private var configuredField: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 10)
            .frame(minHeight: 48)
            .background(backgroundColor)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(borderColor)
                    .frame(height: 1)
            }
            .accessibilityIdentifier(accessibilityIdentifier)
            .modifier(AndroidActivityTextInputBehavior(
                usesSearchSubmitLabel: usesSearchSubmitLabel,
                usesLiteralInputBehavior: usesLiteralInputBehavior
            ))
            .onSubmit {
                onSubmit?()
            }
    }
}

/** Applies optional platform input policy while keeping the shared field cross-platform. */
private struct AndroidActivityTextInputBehavior: ViewModifier {
    let usesSearchSubmitLabel: Bool
    let usesLiteralInputBehavior: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(iOS)
        if usesSearchSubmitLabel {
            literalBehavior(for: content)
                .submitLabel(.search)
        } else {
            literalBehavior(for: content)
        }
#else
        content
#endif
    }

#if os(iOS)
    /** Applies literal-query input policy only for owners that explicitly request it. */
    @ViewBuilder
    private func literalBehavior(for content: Content) -> some View {
        if usesLiteralInputBehavior {
            content
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        } else {
            content
        }
    }
#endif
}
