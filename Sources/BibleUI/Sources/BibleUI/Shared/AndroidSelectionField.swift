// AndroidSelectionField.swift -- Shared app-owned Spinner/ListPreference trigger

import SwiftUI

/**
 Renders the application-owned trigger used for Android Spinner and ListPreference selections.

 The control keeps the field label, current localized value, exact Android drop-down indicator,
 enabled emphasis, and full-width hit target consistent across prompt, provider, model, and other
 management activities. The owner presents a shared app-owned choice dialog or anchored popup and
 commits selection state; this trigger never invokes native `Picker`, `Menu`, popover, or sheet UI.

 Inputs: localized title/value/optional summary, enabled state, owner palette, identifier, action

 Output: one full-width Android selection field

 Side effects: invokes the supplied action after an enabled tap

 Failure modes: none; an empty value remains visible as an empty selection line
 */
struct AndroidSelectionField: View {
    let title: String
    let value: String
    let summary: String?
    let isEnabled: Bool
    let foregroundColor: Color
    let secondaryColor: Color
    let backgroundColor: Color
    let borderColor: Color
    let accessibilityIdentifier: String
    let action: () -> Void

    /** Creates one reusable selection trigger without changing owner state. */
    init(
        title: String,
        value: String,
        summary: String? = nil,
        isEnabled: Bool = true,
        palette: ReaderThemeSurfacePalette,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.value = value
        self.summary = summary
        self.isEnabled = isEnabled
        foregroundColor = palette.foregroundColor
        secondaryColor = palette.secondaryForegroundColor
        backgroundColor = palette.secondaryForegroundColor.opacity(0.08)
        borderColor = palette.inactiveBorderColor
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    /** Creates the same shared trigger for a dialog-owned palette without inventing a reader. */
    init(
        title: String,
        value: String,
        summary: String? = nil,
        isEnabled: Bool = true,
        foregroundColor: Color,
        secondaryColor: Color,
        backgroundColor: Color,
        borderColor: Color,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.value = value
        self.summary = summary
        self.isEnabled = isEnabled
        self.foregroundColor = foregroundColor
        self.secondaryColor = secondaryColor
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(foregroundColor)

            Button {
                guard isEnabled else { return }
                action()
            } label: {
                HStack(spacing: 8) {
                    Text(value)
                        .font(.system(size: 16))
                        .foregroundStyle(foregroundColor)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    AndBibleIconView(name: "PromptExpandIndicator", size: 20)
                        .foregroundStyle(secondaryColor)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 48)
                .background(backgroundColor)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(borderColor)
                        .frame(height: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel(title)
            .accessibilityValue(value)
            .accessibilityIdentifier(accessibilityIdentifier)

            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}
