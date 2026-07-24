// AndroidRadioRow.swift -- Shared app-owned AppCompat radio row

import SwiftUI

/**
 Renders a full-width Android radio option without native iOS picker or toggle presentation.

 Backup/Restore, Search, AI configuration, and other Android-derived workflows use the same
 selected indicator, palette ownership, wide hit target, and accessibility semantics. The owner
 supplies an optional supporting description and the exact application/workspace colors.

 Inputs: localized title/description, represented value, selection binding, owner colors, enabled
 state, and stable accessibility identifier

 Output: one app-owned AppCompat-style radio row

 Side effects: writes the represented value into `selection` after an enabled tap

 Failure modes: none; disabled rows ignore taps
 */
struct AndroidRadioRow<Value: Equatable>: View {
    let title: String
    let description: String?
    let value: Value
    @Binding var selection: Value
    let isEnabled: Bool
    let foregroundColor: Color
    let secondaryColor: Color
    let accentColor: Color
    let titleFont: Font
    let accessibilityIdentifier: String?

    /** Creates one shared radio row without mutating the supplied selection. */
    init(
        title: String,
        description: String? = nil,
        value: Value,
        selection: Binding<Value>,
        isEnabled: Bool = true,
        foregroundColor: Color,
        secondaryColor: Color,
        accentColor: Color,
        titleFont: Font = .system(size: 17),
        accessibilityIdentifier: String? = nil
    ) {
        self.title = title
        self.description = description
        self.value = value
        _selection = selection
        self.isEnabled = isEnabled
        self.foregroundColor = foregroundColor
        self.secondaryColor = secondaryColor
        self.accentColor = accentColor
        self.titleFont = titleFont
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        Button {
            guard isEnabled else { return }
            selection = value
        } label: {
            HStack(alignment: .top, spacing: 12) {
                AndroidRadioIndicator(
                    isSelected: isSelected,
                    secondaryColor: secondaryColor,
                    accentColor: accentColor
                )
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(foregroundColor)
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 15))
                            .foregroundStyle(secondaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityValue(
            isSelected
                ? String(localized: "selected", defaultValue: "Selected")
                : String(localized: "not_selected", defaultValue: "Not selected")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .modifier(AndroidRadioRowAccessibilityIdentifier(identifier: accessibilityIdentifier))
    }

    /** Whether this row's value matches the caller-owned radio-group selection. */
    private var isSelected: Bool { selection == value }
}

/** Shared presentation-only AppCompat radio indicator for row and inline radio groups. */
struct AndroidRadioIndicator: View {
    let isSelected: Bool
    let secondaryColor: Color
    let accentColor: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(isSelected ? accentColor : secondaryColor, lineWidth: 2)
            if isSelected {
                Circle()
                    .fill(accentColor)
                    .padding(5)
            }
        }
        .frame(width: 22, height: 22)
    }
}

/**
 Renders one equal-width option inside Android's horizontal radio groups.

 Prompt tool permissions and other compact three-state controls reuse the same indicator and
 palette as full-width radio dialogs while keeping Android's side-by-side layout. The option owns
 only selection; category logic and persistence remain with the feature.
 */
struct AndroidInlineRadioOption<Value: Equatable>: View {
    let title: String
    let value: Value
    @Binding var selection: Value
    let isEnabled: Bool
    let foregroundColor: Color
    let secondaryColor: Color
    let accentColor: Color
    let accessibilityIdentifier: String

    var body: some View {
        Button {
            guard isEnabled else { return }
            selection = value
        } label: {
            HStack(alignment: .top, spacing: 6) {
                AndroidRadioIndicator(
                    isSelected: selection == value,
                    secondaryColor: secondaryColor,
                    accentColor: accentColor
                )
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(foregroundColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityValue(
            selection == value
                ? String(localized: "selected", defaultValue: "Selected")
                : String(localized: "not_selected", defaultValue: "Not selected")
        )
        .accessibilityAddTraits(selection == value ? .isSelected : [])
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Applies a stable identifier only when a reusable radio-row caller supplied one.
private struct AndroidRadioRowAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
