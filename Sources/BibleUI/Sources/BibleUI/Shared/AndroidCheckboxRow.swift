// AndroidCheckboxRow.swift -- Shared app-owned Android checkbox row

import SwiftUI

/**
 Renders an AppCompat-style checkbox row without platform `Toggle` presentation.

 Labels, archive selection, and other management routes can reuse the same square checked state,
 palette, hit target, and accessibility semantics while retaining ownership of the bound value.

 Inputs: localized title, Boolean binding, enabled state, owner colors, and optional identifier

 Output: one fully tappable checkbox row

 Side effects: toggles the bound Boolean after an enabled tap

 Failure modes: none; disabled rows ignore taps
 */
struct AndroidCheckboxRow: View {
    /// Localized row title.
    let title: String

    /// Caller-owned checked state.
    @Binding var isOn: Bool

    /// Whether the row accepts input.
    let isEnabled: Bool

    /// Main title color.
    let foregroundColor: Color

    /// Checked-state accent.
    let accentColor: Color

    /// Optional UI-test identifier.
    let accessibilityIdentifier: String?

    /** Creates one reusable Android checkbox row without side effects. */
    init(
        title: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        foregroundColor: Color,
        accentColor: Color,
        accessibilityIdentifier: String? = nil
    ) {
        self.title = title
        _isOn = isOn
        self.isEnabled = isEnabled
        self.foregroundColor = foregroundColor
        self.accentColor = accentColor
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        Button {
            guard isEnabled else { return }
            isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                AndroidCheckboxIndicator(
                    isOn: isOn,
                    uncheckedColor: foregroundColor.opacity(0.58),
                    accentColor: accentColor
                )
                Text(title)
                    .font(.system(size: 17))
                    .foregroundStyle(foregroundColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? String(localized: "on") : String(localized: "off"))
        .modifier(AndroidOptionalAccessibilityIdentifier(identifier: accessibilityIdentifier))
    }
}

/**
 Renders the shared visual state used by every app-owned Android checkbox control.

 The indicator is presentation-only so compact table rows can reuse exactly the same checked and
 unchecked treatment as `AndroidCheckboxRow` without nesting a second row-level button.

 Inputs: checked state plus owner-resolved unchecked and accent colors

 Output: one fixed-size checkbox indicator

 Side effects: none

 Failure modes: none
 */
struct AndroidCheckboxIndicator: View {
    /// Whether the Android checkbox is checked.
    let isOn: Bool

    /// Border/icon color for the unchecked state.
    let uncheckedColor: Color

    /// AppCompat accent used by the checked state.
    let accentColor: Color

    var body: some View {
        Image(systemName: isOn ? "checkmark.square.fill" : "square")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(isOn ? accentColor : uncheckedColor)
            .frame(width: 30, height: 30)
    }
}

/// Applies a stable identifier only when a reusable control caller supplied one.
private struct AndroidOptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
