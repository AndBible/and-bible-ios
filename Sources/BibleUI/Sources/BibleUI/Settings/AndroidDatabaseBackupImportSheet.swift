// AndroidDatabaseBackupImportSheet.swift -- Android backup category selection UI

import BibleCore
import SwiftUI

/**
 Presents Android `.abdb.zip` database backup sections before iOS applies them.

 Android exposes database backup restore as a category picker plus a Restore-or-Import choice. This
 SwiftUI sheet mirrors that behavioral contract while keeping unsupported Android database sections
 visible and disabled, so users can distinguish "not present" from "present but not safely mapped by
 this iOS build."

 Data dependencies:
 - `archive` supplies validated manifest and database section metadata staged by
   `AndroidDatabaseBackupService`
 - `onApply` receives supported user selections after destructive restore confirmation, when needed

 Side effects:
 - mutates local sheet state for selected categories and modes
 - invokes `onCancel` from the explicit Cancel button; parent sheet dismissal cleanup handles
   interactive dismissal when no apply is running
 - invokes `onApply` only after the user confirms selections that include Restore mode
 - disables interactive dismissal while `isApplying` is true so staged database files cannot be
   cleaned up while the parent is applying them

 Failure modes:
 - unsupported sections are disabled in the UI and cannot be emitted in `onApply`
 - empty selections keep the Apply command disabled
 */
struct AndroidDatabaseBackupImportSheet: View {
    /// Loaded Android backup archive whose validated sections are shown for selection.
    let archive: AndroidDatabaseBackupArchive

    /// Whether the parent view is currently applying selected sections.
    let isApplying: Bool

    /// Callback used to dismiss the sheet without applying data.
    let onCancel: () -> Void

    /// Callback used to apply selected supported sections.
    let onApply: ([AndroidDatabaseBackupSelection]) -> Void

    /// Supported categories currently selected by the user.
    @State private var selectedCategories: Set<AndroidDatabaseBackupCategory>

    /// Per-category operation modes for supported sections.
    @State private var modesByCategory: [AndroidDatabaseBackupCategory: AndroidDatabaseBackupApplyMode]

    /// Whether the destructive Restore confirmation alert is visible.
    @State private var showRestoreConfirmation = false

    /**
     Creates a category-selection sheet for one validated Android backup archive.

     - Parameters:
       - archive: Loaded archive whose section metadata drives the form.
       - isApplying: Parent-owned progress state that disables controls while a batch is running.
       - onCancel: Dismiss callback.
       - onApply: Apply callback receiving supported selections.
     - Side effects: initializes local selection state with every supported section selected.
     - Failure modes: This initializer cannot fail; unsupported sections are intentionally omitted
       from the selected set.
     */
    init(
        archive: AndroidDatabaseBackupArchive,
        isApplying: Bool,
        onCancel: @escaping () -> Void,
        onApply: @escaping ([AndroidDatabaseBackupSelection]) -> Void
    ) {
        self.archive = archive
        self.isApplying = isApplying
        self.onCancel = onCancel
        self.onApply = onApply

        let supportedCategories = archive.sections
            .filter { $0.support.isSupported }
            .map(\.category)
        _selectedCategories = State(initialValue: Set(supportedCategories))
        _modesByCategory = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: supportedCategories.map { ($0, AndroidDatabaseBackupApplyMode.restore) }
            )
        )
    }

    /**
     Builds the Android manifest summary, selectable sections, and destructive confirmation.
     */
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let manifest = archive.manifest {
                        LabeledContent(
                            String(localized: "android_backup_manifest_version", defaultValue: "Manifest version"),
                            value: "\(manifest.manifestVersion)"
                        )
                        if let andBibleVersion = manifest.andBibleVersion {
                            LabeledContent(
                                String(localized: "android_backup_app_version", defaultValue: "Android app version"),
                                value: "\(andBibleVersion)"
                            )
                        }
                    }
                    LabeledContent(
                        String(localized: "android_backup_sections", defaultValue: "Sections"),
                        value: "\(archive.sections.count)"
                    )
                } header: {
                    Text(String(localized: "android_backup_archive", defaultValue: "Android backup archive"))
                } footer: {
                    Text(
                        String(
                            localized: "android_backup_import_footer",
                            defaultValue: "Restore replaces selected local data. Import keeps existing local rows and adds backup rows that do not already exist."
                        )
                    )
                }

                Section {
                    ForEach(archive.sections) { section in
                        AndroidDatabaseBackupSectionRow(
                            section: section,
                            isApplying: isApplying,
                            isSelected: bindingForSelection(section.category),
                            mode: bindingForMode(section.category)
                        )
                    }
                } header: {
                    Text(String(localized: "android_backup_select_sections", defaultValue: "Select sections"))
                }
            }
            .accessibilityIdentifier("androidDatabaseBackupImportSheet")
            .navigationTitle(String(localized: "android_backup_restore_title", defaultValue: "Android Backup"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) {
                        onCancel()
                    }
                    .disabled(isApplying)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submit()
                    } label: {
                        if isApplying {
                            ProgressView()
                        } else {
                            Text(String(localized: "apply", defaultValue: "Apply"))
                        }
                    }
                    .accessibilityIdentifier("androidDatabaseBackupApplyButton")
                    .disabled(isApplying || selectedSelections.isEmpty)
                }
            }
            .alert(
                String(localized: "android_backup_restore_confirm_title", defaultValue: "Restore selected sections?"),
                isPresented: $showRestoreConfirmation
            ) {
                Button(String(localized: "cancel"), role: .cancel) {}
                Button(String(localized: "restore"), role: .destructive) {
                    onApply(selectedSelections)
                }
            } message: {
                Text(
                    String(
                        localized: "android_backup_restore_confirm_message",
                        defaultValue: "Restore replaces the selected local data with the Android backup. Import selections in the same batch will remain non-destructive."
                    )
                )
            }
        }
        .interactiveDismissDisabled(isApplying)
    }

    /**
     Current supported selections in the loader-provided section display order.

     - Returns: Selected section/mode pairs filtered to supported categories.
     - Side effects: none.
     - Failure modes: Missing mode state falls back to Restore, matching the sheet's default.
     */
    private var selectedSelections: [AndroidDatabaseBackupSelection] {
        archive.sections.compactMap { section in
            guard section.support.isSupported,
                  selectedCategories.contains(section.category) else {
                return nil
            }
            let supportedModes = section.category.supportedApplyModes
            let selectedMode = modesByCategory[section.category] ?? supportedModes.first ?? .restore
            return AndroidDatabaseBackupSelection(
                category: section.category,
                mode: supportedModes.contains(selectedMode) ? selectedMode : supportedModes.first ?? .restore
            )
        }
    }

    /**
     Submits the selected sections, requiring confirmation if any selection is destructive.

     - Side effects: either presents the destructive confirmation alert or invokes `onApply`.
     - Failure modes: Empty selections are ignored; the Apply button is disabled for that state.
     */
    private func submit() {
        let selections = selectedSelections
        guard !selections.isEmpty else {
            return
        }
        if selections.contains(where: { $0.mode == .restore }) {
            showRestoreConfirmation = true
        } else {
            onApply(selections)
        }
    }

    /**
     Produces a mutable binding for one category selection toggle.

     - Parameter category: Category whose selected state should be exposed.
     - Returns: Binding that adds or removes the category from `selectedCategories`.
     - Side effects: writes local sheet state when the user toggles a supported section.
     - Failure modes: none.
     */
    private func bindingForSelection(_ category: AndroidDatabaseBackupCategory) -> Binding<Bool> {
        Binding(
            get: { selectedCategories.contains(category) },
            set: { isSelected in
                if isSelected {
                    selectedCategories.insert(category)
                } else {
                    selectedCategories.remove(category)
                }
            }
        )
    }

    /**
     Produces a mutable binding for one category's Restore/Import picker.

     - Parameter category: Category whose mode should be exposed.
     - Returns: Binding backed by `modesByCategory`.
     - Side effects: writes local sheet state when the user changes operation mode.
     - Failure modes: Missing values read as Restore.
     */
    private func bindingForMode(_ category: AndroidDatabaseBackupCategory) -> Binding<AndroidDatabaseBackupApplyMode> {
        Binding(
            get: { modesByCategory[category] ?? .restore },
            set: { modesByCategory[category] = $0 }
        )
    }
}

/**
 Renders one Android backup section with support status, selection state, and operation mode.

 Supported rows expose a toggle and segmented Restore/Import picker until the parent begins an
 apply operation. While applying, rows stay readable but controls are disabled so local selection
 edits cannot diverge from the already-submitted apply snapshot. Unsupported rows stay visible with
 the exact reason supplied by `AndroidDatabaseBackupService`, preserving Android backup
 transparency without allowing unsafe partial restores.
 */
private struct AndroidDatabaseBackupSectionRow: View {
    /// Validated section metadata for one Android backup database.
    let section: AndroidDatabaseBackupSection

    /// Whether the parent sheet is applying a submitted selection snapshot.
    let isApplying: Bool

    /// Selection binding owned by the parent sheet.
    @Binding var isSelected: Bool

    /// Restore/import mode binding owned by the parent sheet.
    @Binding var mode: AndroidDatabaseBackupApplyMode

    /**
     Builds the row content for one Android backup section.
     */
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if section.support.isSupported {
                Toggle(isOn: $isSelected) {
                    sectionLabel
                }
                .accessibilityIdentifier("androidBackupSectionToggle.\(section.category.rawValue)")

                if isSelected, section.category.supportedApplyModes.count > 1 {
                    Picker(
                        String(localized: "android_backup_mode", defaultValue: "Mode"),
                        selection: $mode
                    ) {
                        ForEach(section.category.supportedApplyModes) { mode in
                            Text(mode.localizedBackupModeName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("androidBackupSectionMode.\(section.category.rawValue)")
                }
            } else {
                sectionLabel
                if let explanation = section.support.localizedBackupExplanation(for: section.category) {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(isApplying || !section.support.isSupported)
    }

    /**
     Shared section label showing category name, database version, and manifest presence.
     */
    private var sectionLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.category.localizedBackupSectionName)
                .font(.headline)
            Text(detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /**
     Human-readable metadata summary for the row.
     */
    private var detailText: String {
        let pieces = section.hasDatabaseFile
            ? [
                String(
                    localized: "android_backup_database_version",
                    defaultValue: "Database version \(section.databaseVersion)"
                ),
            ]
            : [
                String(
                    localized: "android_backup_manifest_category",
                    defaultValue: "Manifest category"
                ),
            ]
        return pieces.joined(separator: " • ")
    }
}
