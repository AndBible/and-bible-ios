// AndroidSingleChoiceDialog.swift -- Shared app-owned ListPreference dialog

import SwiftUI

/** Immutable value/label pair rendered by `AndroidSingleChoiceDialog`. */
struct AndroidSingleChoiceOption<Value: Hashable>: Identifiable {
    let id: String
    let value: Value
    let title: String
}

/**
 Renders Android's `AlertDialog.setSingleChoiceItems` interaction without native iOS pickers.

 The dialog composes the shared window and radio rows. Selecting an option immediately calls the
 owner and dismisses through owner state, matching Android `ListPreference`; Cancel and outside taps
 leave the original value unchanged.

 Inputs: localized title, current value, Android-order options, selection/cancel commands

 Output: one centered app-owned single-choice dialog

 Side effects: an option invokes `onSelect` once; Cancel/outside taps invoke `onCancel`

 Failure modes: empty option arrays render an empty list with a functional Cancel action
 */
struct AndroidSingleChoiceDialog<Value: Hashable>: View {
    let title: String
    let selectedValue: Value
    let options: [AndroidSingleChoiceOption<Value>]
    let accessibilityIdentifier: String
    let onSelect: (Value) -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: accessibilityIdentifier,
            onOutsideTap: onCancel
        ) {
            AndroidDialogScaffold(title: title) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(options) { option in
                            AndroidRadioRow(
                                title: option.title,
                                value: option.value,
                                selection: selectionBinding,
                                foregroundColor: AndroidDialogSurfacePalette.primaryText(for: colorScheme),
                                secondaryColor: AndroidDialogSurfacePalette.secondaryText(for: colorScheme),
                                accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme),
                                accessibilityIdentifier: "\(accessibilityIdentifier)Choice::\(option.id)"
                            )
                            Divider()
                                .overlay(AndroidDialogSurfacePalette.secondaryText(for: colorScheme).opacity(0.2))
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .frame(maxHeight: 320)
            } actions: {
                AndroidDialogTextAction(
                    title: String(localized: "cancel", defaultValue: "Cancel"),
                    accessibilityIdentifier: "\(accessibilityIdentifier)CancelButton",
                    action: onCancel
                )
            }
        }
    }

    /// Radio-row binding whose setter immediately commits Android's selected list item.
    private var selectionBinding: Binding<Value> {
        Binding(get: { selectedValue }, set: onSelect)
    }
}
