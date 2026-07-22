// AndroidModuleBackupExportSheet.swift -- Android module backup export selection UI

import SwiftUI
import BibleCore
import SwordKit

/**
 Presents every Android-registerable installed family for module backup export.

 Android asks the user which installed documents to include before creating
 `AndBibleModulesBackup.abmd.zip`. This sheet consumes the exporter's canonical all-family catalog,
 defaulting to every listed module selected and allowing the user to switch
 between all and none before exporting.

 Data dependencies:
 - `modules` is the canonical installed-content catalog gathered from `AndroidModuleBackupService`
 - `onExport` receives selected module initials in display order

 Side effects:
 - mutates local selection state as the user toggles modules
 - invokes `onCancel` or `onExport` in response to toolbar actions

 Failure modes:
 - empty selections disable the Export command so the parent never receives an invalid request
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

    /// Current selected Android identities without Swift's canonical Unicode normalization.
    @State private var selectedModuleIdentities: Set<SQLiteDocumentIdentity>

    /**
     Creates one export-selection sheet.

     - Parameters:
       - modules: Installed SWORD modules eligible for export.
       - isExporting: Parent-owned progress state that disables controls while archive writing runs.
       - onCancel: Dismiss callback.
       - onExport: Export callback receiving selected initials.
     - Side effects: Initializes local selection state with every module selected, matching
       Android's selected-by-default backup dialog.
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
        _selectedModuleIdentities = State(initialValue: Set(modules.map(\.id)))
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
     Builds the selectable module list and export/cancel toolbar actions.
     */
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(selectionToggleTitle) {
                        toggleAllSelections()
                    }
                    .disabled(isExporting || modules.isEmpty)
                    .accessibilityIdentifier("androidModuleBackupExportSelectToggleButton")
                }

                Section {
                    ForEach(modules) { module in
                        Toggle(isOn: binding(for: module.initials)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(module.displayName.isEmpty ? module.initials : module.displayName)
                                    .font(.body)
                                Text(moduleDetail(for: module))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(isExporting)
                        .accessibilityIdentifier("androidModuleBackupExportRow::\(module.initials)")
                    }
                } header: {
                    Text(String(localized: "android_module_backup_export_modules", defaultValue: "Select modules"))
                }
            }
            .accessibilityIdentifier("androidModuleBackupExportSheet")
            .navigationTitle(String(localized: "android_module_backup_export_title", defaultValue: "Module Backup"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onExport(selectedModuleNamesInDisplayOrder)
                    } label: {
                        if isExporting {
                            ProgressView()
                        } else {
                            Text(String(localized: "export"))
                        }
                    }
                    .accessibilityIdentifier("androidModuleBackupExportApplyButton")
                    .disabled(isExporting || selectedModuleNamesInDisplayOrder.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(isExporting)
    }

    /**
     Selected module initials in the same order shown to the user.

     - Returns: Selected initials filtered through `modules` display order.
     - Side effects: none.
     - Failure modes: none.
     */
    private var selectedModuleNamesInDisplayOrder: [String] {
        Self.selectedModuleNames(
            inDisplayOrder: modules,
            selectedIdentities: selectedModuleIdentities
        )
    }

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
        selectedIdentities: Set<SQLiteDocumentIdentity>
    ) -> [String] {
        modules.filter { selectedIdentities.contains($0.id) }.map(\.initials)
    }

    /**
     Title for the Android-style select-all/select-none control.

     - Returns: "Select none" when all modules are selected, otherwise "Select all".
     - Side effects: none.
     - Failure modes: none.
     */
    private var selectionToggleTitle: String {
        if selectedModuleIdentities.count == modules.count {
            return String(localized: "select_none", defaultValue: "Select none")
        }
        return String(localized: "select_all", defaultValue: "Select all")
    }

    /**
     Produces a mutable selection binding for one module row.

     - Parameter moduleName: Module initials whose selected state should be exposed.
     - Returns: Binding that adds or removes the module from `selectedModuleIdentities`.
     - Side effects: Writes local sheet selection state when the user toggles a row.
     - Failure modes: none.
     */
    private func binding(for moduleName: String) -> Binding<Bool> {
        let identity = SQLiteDocumentIdentity(moduleName)
        return Binding(
            get: { selectedModuleIdentities.contains(identity) },
            set: { isSelected in
                if isSelected {
                    selectedModuleIdentities.insert(identity)
                } else {
                    selectedModuleIdentities.remove(identity)
                }
            }
        )
    }

    /**
     Toggles between all modules selected and no modules selected.

     Side effects:
     - mutates `selectedModuleIdentities`

     Failure modes:
     - empty module lists remain empty; the toolbar button is disabled for that state.
     */
    private func toggleAllSelections() {
        if selectedModuleIdentities.count == modules.count {
            selectedModuleIdentities.removeAll()
        } else {
            selectedModuleIdentities = Set(modules.map(\.id))
        }
    }

    /**
     Builds Android-like row detail text from module initials, category, and language.

     - Parameter module: Installed module shown in the export sheet.
     - Returns: Compact detail text that distinguishes similarly named modules.
     - Side effects: none.
     - Failure modes: none.
     */
    private func moduleDetail(for module: AndroidModuleBackupInstalledContent) -> String {
        let language = module.language.isEmpty ? "?" : module.language
        return "\(module.initials), \(language), \(familyName(module.family))"
    }

    /** Returns a compact user-visible family label for one canonical catalog row. */
    private func familyName(_ family: AndroidModuleBackupContentFamily) -> String {
        switch family {
        case .swordConfiguration, .swordPayload:
            return "SWORD"
        case .myBible:
            return "MyBible"
        case .mySword:
            return "MySword"
        case .eSword:
            return "e-Sword"
        case .epub:
            return "EPUB"
        case .ttf:
            return "Font"
        case .background:
            return "Background"
        case .prompts:
            return "Prompt pack"
        }
    }
}

/**
 Renders Android's module multiselect as an app-owned dialog window.

 Inputs and outputs mirror `AndroidModuleBackupExportSheet`; the wrapper owns only the dimmed
 window surface and prevents accidental dismissal while the parent writes an archive. Taps outside
 the dialog invoke `onCancel` only when export work is idle.
 */
struct AndroidModuleBackupExportDialog<Content: View>: View {
    /// Whether the parent is currently writing the selected module archive.
    let isExporting: Bool

    /// Callback used to dismiss the dialog when no export is in progress.
    let onCancel: () -> Void

    /// Selection content shared by the settings and reader entry points.
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black
                .opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture {
                    guard !isExporting else { return }
                    onCancel()
                }

            content()
                .frame(maxWidth: 640, maxHeight: 700)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 20)
                .padding(24)
        }
        .accessibilityIdentifier("androidModuleBackupExportDialog")
    }
}
