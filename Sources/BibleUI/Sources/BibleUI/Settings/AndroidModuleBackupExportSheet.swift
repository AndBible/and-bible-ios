// AndroidModuleBackupExportSheet.swift -- Android module backup export selection UI

import SwiftUI
import BibleCore
import SwordKit

/**
 Presents every Android-registerable installed family for module backup export.

 Android asks the user which installed documents to include before creating
 `AndBibleModulesBackup.abmd.zip`. This view consumes the exporter's canonical all-family catalog
 and mirrors Android `Dialogs.multiselect`: every row starts unchecked, the neutral action toggles
 all rows without dismissing, and OK returns the selected rows in visible order.

 Data dependencies:
 - `modules` is the canonical installed-content catalog gathered from `AndroidModuleBackupService`
 - `onExport` receives selected module initials in display order

 Side effects:
 - mutates local selection state as the user toggles modules
 - invokes `onCancel` or `onExport` in response to Android dialog actions

 Failure modes:
 - confirming an empty selection follows Android's empty-result path and dismisses without export
 - catalog discovery failures are handled by the parent before this sheet is presented
 */
struct AndroidModuleBackupExportSheet: View {
    /// Installed all-family content eligible for Android-compatible export.
    let modules: [AndroidModuleBackupInstalledContent]

    /// Whether the parent is currently writing the backup archive.
    let isExporting: Bool

    /// Callback used to dismiss without exporting.
    let onCancel: () -> Void

    /// Callback receiving selected module initials in display order.
    let onExport: ([String]) -> Void

    /// Draft checked identities, intentionally empty when the Android multiselect first appears.
    @State private var selectedModuleIdentities: Set<SwordJavaExactStringIdentity>

    /**
     Creates one export-selection sheet.

     - Parameters:
       - modules: Installed SWORD modules eligible for export.
       - isExporting: Parent-owned progress state that disables controls while archive writing runs.
       - onCancel: Dismiss callback.
       - onExport: Export callback receiving selected initials.
     - Side effects: Initializes an empty draft because Android omits `preSelected` for module
       backup and `Dialogs.multiselect` therefore starts every row unchecked.
     - Failure modes: This initializer cannot fail.
     */
    init(
        modules: [AndroidModuleBackupInstalledContent],
        isExporting: Bool,
        onCancel: @escaping () -> Void,
        onExport: @escaping ([String]) -> Void
    ) {
        self.modules = modules
        self.isExporting = isExporting
        self.onCancel = onCancel
        self.onExport = onExport
        _selectedModuleIdentities = State(initialValue: Self.initialSelectedModuleIdentities)
    }

    /**
     Preserves the reader picker's SWORD-only backup entry point while the Settings picker uses the
     canonical all-family catalog.

     - Parameters:
       - modules: Installed SWORD rows already selected by the reader picker.
       - isExporting: Parent-owned progress state that disables controls while archive writing runs.
       - onCancel: Dismiss callback.
       - onExport: Export callback receiving selected initials.
     - Side effects: Converts immutable presentation metadata into canonical SWORD-family rows.
     - Failure modes: This initializer cannot fail.
     */
    init(
        modules: [ModuleInfo],
        isExporting: Bool,
        onCancel: @escaping () -> Void,
        onExport: @escaping ([String]) -> Void
    ) {
        self.init(
            modules: modules.map {
                AndroidModuleBackupInstalledContent(
                    initials: $0.name,
                    displayName: $0.description,
                    language: $0.language,
                    family: .swordConfiguration
                )
            },
            isExporting: isExporting,
            onCancel: onCancel,
            onExport: onExport
        )
    }

    /**
     Builds Android's title, app-owned checkbox list, neutral selection action, and Cancel/OK row.

     Side effects: Row and neutral-action taps mutate only the draft selection; Cancel and OK
     invoke the parent callbacks.

    Failure modes: While export is active every action is guarded and disabled. OK with no checked
     rows follows Android's empty-result path by dismissing without calling the export callback.
     */
    var body: some View {
        AndroidMultiselectDialogContent(
            title: String(
                localized: "backup_modules_title",
                defaultValue: "Select which modules to backup"
            ),
            rows: Self.multiselectRows(for: modules),
            selectedIDs: $selectedModuleIdentities,
            isBusy: isExporting,
            accessibilityIdentifier: "androidModuleBackupExportSheet",
            accessibilityPrefix: "androidModuleBackupExport",
            onCancel: cancelIfIdle,
            onConfirm: confirmIfIdle
        )
    }

    /**
     Cancels the Android multiselect only while no archive writer owns the dialog.

     - Side effects: Invokes `onCancel` while idle.
     - Failure modes: Export-in-progress actions are ignored.
     */
    private func cancelIfIdle() {
        guard !isExporting else { return }
        onCancel()
    }

    /**
     Resolves the shared multiselect result to module initials and starts export while idle.

     - Parameter selectedIdentities: Enabled checked identities in visible order.
     - Side effects: Invokes `onExport`, or `onCancel` for Android's empty-result path.
     - Failure modes: Export-in-progress actions are ignored; identities absent from the canonical
       catalog are ignored by `selectedModuleNames`.
     */
    private func confirmIfIdle(_ selectedIdentities: [SwordJavaExactStringIdentity]) {
        guard !isExporting else { return }
        let selectedModuleNames = Self.selectedModuleNames(
            inDisplayOrder: modules,
            selectedIdentities: Set(selectedIdentities)
        )
        guard !selectedModuleNames.isEmpty else {
            onCancel()
            return
        }
        onExport(selectedModuleNames)
    }

    /**
     Android's initial module-backup draft.

     - Returns: An empty exact-identity set because `backupModulesViaIntent` does not supply
       `preSelected` to `Dialogs.multiselect`.
     - Side effects: none.
     - Failure modes: none.
     */
    static var initialSelectedModuleIdentities: Set<SwordJavaExactStringIdentity> { [] }

    /**
     Resolves exact Android identities through the canonical picker order.

     - Parameters:
       - modules: Canonical all-family rows in their visible order.
       - selectedIdentities: Android-compatible identities currently selected by the user.
     - Returns: Selected archive identities in visible order, without Unicode normalization.
     - Side effects: none.
     - Failure modes: none; identities absent from the catalog are ignored.
     */
    static func selectedModuleNames(
        inDisplayOrder modules: [AndroidModuleBackupInstalledContent],
        selectedIdentities: Set<SwordJavaExactStringIdentity>
    ) -> [String] {
        modules.filter { selectedIdentities.contains($0.id) }.map(\.initials)
    }

    /**
     Adapts canonical module metadata to the reusable app-owned multiselect contract.

     - Parameter modules: Canonical all-family rows in display order.
     - Returns: Shared checkbox rows retaining exact Android identities and visible labels.
     - Side effects: Resolves localized row formatting through `moduleRowTitle`.
     - Failure modes: none.
     */
    static func multiselectRows(
        for modules: [AndroidModuleBackupInstalledContent]
    ) -> [AndroidMultiselectDialogRow<SwordJavaExactStringIdentity>] {
        modules.map { module in
            AndroidMultiselectDialogRow(
                id: module.id,
                title: moduleRowTitle(for: module),
                accessibilityIdentifier: "androidModuleBackupExportRow::\(module.initials)"
            )
        }
    }

    /**
     Builds Android's exact visible module label using `something_with_parenthesis`.

     - Parameter module: Installed module shown in the export sheet.
     - Returns: `name (initials, language)` with locale-specific punctuation supplied by Android's
       shared format string.
     - Side effects: none.
     - Failure modes: Empty display names fall back to initials; empty language codes remain empty
       exactly as supplied by the installed-content catalog.
     */
    static func moduleRowTitle(for module: AndroidModuleBackupInstalledContent) -> String {
        let displayName = module.displayName.isEmpty ? module.initials : module.displayName
        return String(
            format: String(
                localized: "something_with_parenthesis",
                defaultValue: "%@ (%@)"
            ),
            displayName,
            "\(module.initials), \(module.language)"
        )
    }
}

/**
 Renders Android's module multiselect as an app-owned dialog window.

 Inputs and outputs mirror `AndroidModuleBackupExportSheet`; the wrapper owns only the dimmed
 window surface and prevents accidental dismissal while the parent writes an archive. Taps outside
 the dialog invoke `onCancel` only when export work is idle.
 */
struct AndroidModuleBackupExportDialog<Content: View>: View {
    /// Active application scheme supplied to the canonical AppCompat dialog surface.
    @Environment(\.colorScheme) private var colorScheme

    /// Whether the parent is currently writing the selected module archive.
    let isExporting: Bool

    /// Callback used to dismiss the dialog when no export is in progress.
    let onCancel: () -> Void

    /// Selection content shared by the settings and reader entry points.
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isExporting {
            AndroidIndeterminateProgressDialog(
                accessibilityIdentifier: "androidModuleBackupExportProgressDialog"
            )
        } else {
            AndroidDialogWindow(
                colorScheme: colorScheme,
                accessibilityIdentifier: "androidModuleBackupExportDialog",
                allowsOutsideDismissal: true,
                onOutsideTap: dismissIfIdle
            ) {
                content()
            }
        }
    }

    /**
     Dismisses on an accepted scrim tap only while no archive write owns the dialog.

     Side effects: Invokes the caller's cancellation callback while idle.

     Failure modes: Export-in-progress taps are ignored so a detached writer cannot outlive owner
     state cleanup.
     */
    private func dismissIfIdle() {
        guard !isExporting else { return }
        onCancel()
    }
}
