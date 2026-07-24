// AndroidMultiselectDialogContent.swift -- Shared app-owned Android multiselect content

import SwiftUI

/** One visible row supplied to the shared Android multiselect dialog content. */
struct AndroidMultiselectDialogRow<ID: Hashable>: Identifiable {
    /// Exact owner identity retained independently of localized display text.
    let id: ID

    /// Localized label shown beside the checkbox.
    let title: String

    /// Whether this row may be selected.
    let isEnabled: Bool

    /// Stable UI-test identifier for the complete row.
    let accessibilityIdentifier: String

    /** Creates immutable row metadata without reading or mutating dialog selection. */
    init(
        id: ID,
        title: String,
        isEnabled: Bool = true,
        accessibilityIdentifier: String
    ) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

/**
 Renders the reusable content contract behind Android `Dialogs.multiselect` surfaces.

 Module backup, database-section restore, bookmark export, and other multi-choice workflows share
 the same AppCompat title, checkbox rows, neutral Select all/none behavior, adaptive action row, and
 palette. The caller owns initial selection and decides what an empty OK result means; this view
 returns enabled selected identities in visible order.

 Inputs: localized title, ordered rows, selection binding, busy state, identifiers, and explicit
 Cancel/OK callbacks

 Output: dialog content intended for one shared `AndroidDialogWindow`

 Side effects: row and neutral actions mutate `selectedIDs`; Cancel/OK invoke owner callbacks

 Failure modes: disabled rows are never returned; busy state guards every action
 */
struct AndroidMultiselectDialogContent<ID: Hashable>: View {
    /// Active AppCompat appearance used by the globally managed dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let rows: [AndroidMultiselectDialogRow<ID>]
    @Binding var selectedIDs: Set<ID>
    let isBusy: Bool
    let accessibilityIdentifier: String
    let accessibilityPrefix: String
    let onCancel: () -> Void
    let onConfirm: ([ID]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 12)

            AndroidAdaptiveDialogScrollView(
                accessibilityIdentifier: "\(accessibilityPrefix)List"
            ) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        AndroidCheckboxRow(
                            title: row.title,
                            isOn: selectionBinding(for: row),
                            isEnabled: row.isEnabled && !isBusy,
                            foregroundColor: AndroidDialogSurfacePalette.primaryText(for: colorScheme),
                            accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme),
                            accessibilityIdentifier: row.accessibilityIdentifier
                        )
                        .padding(.horizontal, 18)
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                horizontalActions
                verticalActions
            }
        }
        .frame(maxWidth: 520)
        .overlay(alignment: .topLeading) {
            // A container identifier propagates through `ViewThatFits` on current iOS releases and
            // replaces the neutral, Cancel, and OK identifiers. Export the dialog identity on a
            // noninteractive sibling so every shared action retains its own semantic contract.
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier(accessibilityIdentifier)
                .accessibilityLabel(accessibilityIdentifier)
                .allowsHitTesting(false)
        }
    }

    /** Android AlertDialog placement with the neutral action leading and decisions trailing. */
    private var horizontalActions: some View {
        HStack(spacing: 18) {
            selectionToggleButton
            Spacer(minLength: 12)
            cancelButton
            confirmationButton
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    /** Narrow-width action fallback that preserves semantic order without truncating translations. */
    private var verticalActions: some View {
        VStack(alignment: .trailing, spacing: 14) {
            selectionToggleButton
            cancelButton
            confirmationButton
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    /** Neutral action that toggles every enabled visible row without dismissing. */
    private var selectionToggleButton: some View {
        dialogActionButton(
            title: allSelectableRowsSelected
                ? String(localized: "select_none", defaultValue: "Select none")
                : String(localized: "select_all", defaultValue: "Select all"),
            accessibilityIdentifier: "\(accessibilityPrefix)SelectToggleButton"
        ) {
            guard !isBusy else { return }
            toggleAllSelections()
        }
        .disabled(isBusy || selectableRows.isEmpty)
        .accessibilityValue(allSelectableRowsSelected ? "selectNone" : "selectAll")
    }

    /** Negative action that discards the caller-owned draft. */
    private var cancelButton: some View {
        dialogActionButton(
            title: String(localized: "cancel"),
            accessibilityIdentifier: "\(accessibilityPrefix)CancelButton"
        ) {
            guard !isBusy else { return }
            onCancel()
        }
        .disabled(isBusy)
    }

    /** Positive action that returns selected enabled identities in visible order. */
    private var confirmationButton: some View {
        dialogActionButton(
            title: String(localized: "okay", defaultValue: "OK"),
            accessibilityIdentifier: "\(accessibilityPrefix)ApplyButton"
        ) {
            guard !isBusy else { return }
            onConfirm(selectedIDsInDisplayOrder)
        }
        .disabled(isBusy)
    }

    /** Builds one AppCompat text action using the shared dialog accent. */
    private func dialogActionButton(
        title: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /** Enabled rows participating in Select all/none and confirmation. */
    private var selectableRows: [AndroidMultiselectDialogRow<ID>] {
        rows.filter(\.isEnabled)
    }

    /** Whether every enabled visible row is selected and at least one such row exists. */
    private var allSelectableRowsSelected: Bool {
        !selectableRows.isEmpty && selectableRows.allSatisfy { selectedIDs.contains($0.id) }
    }

    /** Enabled selected identities in the exact order visible to the user. */
    private var selectedIDsInDisplayOrder: [ID] {
        selectableRows.filter { selectedIDs.contains($0.id) }.map(\.id)
    }

    /** Produces a mutable checkbox binding for one exact row identity. */
    private func selectionBinding(for row: AndroidMultiselectDialogRow<ID>) -> Binding<Bool> {
        Binding(
            get: { row.isEnabled && selectedIDs.contains(row.id) },
            set: { isSelected in
                guard row.isEnabled else { return }
                if isSelected { selectedIDs.insert(row.id) }
                else { selectedIDs.remove(row.id) }
            }
        )
    }

    /** Applies Android's non-dismissing Select all/none mutation to enabled rows. */
    private func toggleAllSelections() {
        selectedIDs = Self.toggledAllSelection(
            in: rows,
            selectedIDs: selectedIDs
        )
    }

    /**
     Applies Android's reusable Select all/none mutation without presentation state.

     - Parameters:
       - rows: Ordered visible multiselect rows.
       - selectedIDs: Exact identities selected before the neutral action.
     - Returns: A selection with all enabled rows removed when all were selected, or added when any
       enabled row was unselected. Disabled identities are preserved but never introduced.
     - Side effects: none.
     - Failure modes: With no enabled rows, returns the input unchanged.
     */
    static func toggledAllSelection(
        in rows: [AndroidMultiselectDialogRow<ID>],
        selectedIDs: Set<ID>
    ) -> Set<ID> {
        let enabledIDs = rows.filter(\.isEnabled).map(\.id)
        guard !enabledIDs.isEmpty else { return selectedIDs }

        var result = selectedIDs
        if enabledIDs.allSatisfy(result.contains) {
            result.subtract(enabledIDs)
        } else {
            result.formUnion(enabledIDs)
        }
        return result
    }
}
