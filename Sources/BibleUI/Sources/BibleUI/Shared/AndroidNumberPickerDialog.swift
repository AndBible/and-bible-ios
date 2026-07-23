// AndroidNumberPickerDialog.swift -- Shared app-owned integer picker dialog

import SwiftUI

/**
 Presents Android's bounded integer `NumberPicker` interaction without an iOS picker or sheet.

 The shared dialog stages a candidate independently from the persisted value. Tapping a number
 changes only the staged selection; OK commits once and Cancel/outside taps discard it. A compact
 scrollable number column preserves the bounded Android interaction for ranges such as Speak's
 1-through-120 minute sleep timer.

 Inputs: localized title, valid integer range, initial value, and commit/cancel callbacks.

 Output: one centered app-owned Android dialog with a scrollable number column.

 Side effects: invokes `onConfirm` only from OK and `onCancel` from Cancel/outside dismissal.

 Failure modes: an out-of-range initial value is clamped; an invalid descending range is not
 representable by `ClosedRange<Int>`.
 */
struct AndroidNumberPickerDialog: View {
    /// Localized Android dialog title.
    let title: String

    /// Inclusive selectable integer range.
    let range: ClosedRange<Int>

    /// Stable UI automation identity.
    let accessibilityIdentifier: String

    /// Commits the staged integer.
    let onConfirm: (Int) -> Void

    /// Discards the staged integer.
    let onCancel: () -> Void

    /// Staged candidate isolated from owner persistence until OK.
    @State private var selection: Int

    /// Active application scheme for shared AppCompat dialog colors.
    @Environment(\.colorScheme) private var colorScheme

    /** Creates one staged Android number picker. */
    init(
        title: String,
        range: ClosedRange<Int>,
        initialValue: Int,
        accessibilityIdentifier: String,
        onConfirm: @escaping (Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.range = range
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _selection = State(initialValue: min(max(initialValue, range.lowerBound), range.upperBound))
    }

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: accessibilityIdentifier,
            onOutsideTap: onCancel
        ) {
            AndroidDialogScaffold(title: title) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(range), id: \.self) { value in
                                numberRow(value)
                                    .id(value)
                            }
                        }
                    }
                    .frame(width: 150, height: 264)
                    .background(AndroidDialogSurfacePalette.fieldBackground(for: colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(AndroidDialogSurfacePalette.fieldBorder(for: colorScheme))
                    }
                    .frame(maxWidth: .infinity)
                    .onAppear {
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            } actions: {
                AndroidDialogTextAction(
                    title: String(localized: "cancel", defaultValue: "Cancel"),
                    accessibilityIdentifier: "\(accessibilityIdentifier)CancelButton",
                    action: onCancel
                )
                AndroidDialogTextAction(
                    title: String(localized: "okay", defaultValue: "OK"),
                    accessibilityIdentifier: "\(accessibilityIdentifier)OKButton"
                ) {
                    onConfirm(selection)
                }
            }
        }
    }

    /** Creates one selectable number row inside the shared dialog. */
    private func numberRow(_ value: Int) -> some View {
        Button {
            selection = value
        } label: {
            Text("\(value)")
                .font(.system(size: selection == value ? 22 : 18, weight: selection == value ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(
                    selection == value
                        ? AndroidDialogSurfacePalette.accent(for: colorScheme)
                        : AndroidDialogSurfacePalette.primaryText(for: colorScheme)
                )
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    selection == value
                        ? AndroidDialogSurfacePalette.accent(for: colorScheme).opacity(0.12)
                        : Color.clear
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(value)")
        .accessibilityValue(selection == value ? String(localized: "selected", defaultValue: "Selected") : "")
        .accessibilityIdentifier("\(accessibilityIdentifier)Value::\(value)")
    }
}
