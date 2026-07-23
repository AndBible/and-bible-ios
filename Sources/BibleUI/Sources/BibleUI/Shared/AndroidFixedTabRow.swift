// AndroidFixedTabRow.swift -- Shared app-owned fixed Material tab presentation

import SwiftUI

/**
 Describes one selection in a fixed Android Material tab row.

 The item carries semantic selection identity and already-localized visible text. Keeping this model
 independent of any feature lets activity screens share the same tab geometry and indicator behavior
 without routing presentation through iOS segmented pickers.

 Inputs: stable identifier, semantic value, and localized title

 Output: immutable tab-row data

 Side effects: none

 Failure modes: duplicate identifiers are a caller contract violation and produce ordinary SwiftUI
 `ForEach` identity ambiguity
 */
struct AndroidFixedTabItem<Selection: Hashable>: Identifiable {
    /// Stable automation and diffing identity.
    let id: String

    /// Semantic value assigned when the item is tapped.
    let value: Selection

    /// Localized visible label.
    let title: String
}

/**
 Renders Android's fixed, fill-width Material tab row as an application-owned control.

 The component owns the repeated equal-width buttons, active text emphasis, bottom indicator, and
 minimum interaction height. The activity owner supplies its workspace/window surface colors while
 the selected indicator uses the central AppCompat accent. This keeps tabs aligned with global
 appearance state instead of sampling screenshots or inventing feature-local colors.

 Inputs: ordered tab items, selected value binding, owner surface colors, and shared accent

 Output: one fixed-height app-owned tab selector

 Side effects: direct taps update `selection`

 Failure modes: a selected value absent from `items` renders every item inactive until the owner
 supplies a valid selection
 */
struct AndroidFixedTabRow<Selection: Hashable>: View {
    /// Android-order tab definitions.
    let items: [AndroidFixedTabItem<Selection>]

    /// Parent-owned active tab.
    @Binding var selection: Selection

    /// Activity-owned tab surface.
    let backgroundColor: Color

    /// Activity-owned primary text.
    let foregroundColor: Color

    /// Activity-owned inactive text.
    let secondaryForegroundColor: Color

    /// Global AppCompat selection accent.
    let accentColor: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    selection = item.value
                } label: {
                    VStack(spacing: 0) {
                        Text(item.title)
                            .font(.system(size: 15, weight: selection == item.value ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Rectangle()
                            .fill(selection == item.value ? accentColor : Color.clear)
                            .frame(height: 2)
                    }
                    .foregroundStyle(
                        selection == item.value ? foregroundColor : secondaryForegroundColor
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item.value ? .isSelected : [])
                .accessibilityIdentifier("androidFixedTab::\(item.id)")
            }
        }
        .frame(height: 48)
        .background(backgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(secondaryForegroundColor.opacity(0.18))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("androidFixedTabRow")
    }
}
