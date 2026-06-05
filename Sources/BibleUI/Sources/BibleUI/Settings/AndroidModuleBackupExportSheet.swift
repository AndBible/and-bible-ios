// AndroidModuleBackupExportSheet.swift -- Android module backup export selection UI

import SwiftUI
import SwordKit

/**
 Presents installed SWORD modules for Android-compatible module backup export.

 Android asks the user which installed documents to include before creating
 `AndBibleModulesBackup.abmd.zip`. This sheet mirrors that behavior for the SWORD-backed module
 types iOS can export, defaulting to every listed module selected and allowing the user to switch
 between all and none before exporting.

 Data dependencies:
 - `modules` is the installed SWORD module list gathered by the parent from `SwordManager`
 - `onExport` receives selected module initials in display order

 Side effects:
 - mutates local selection state as the user toggles modules
 - invokes `onCancel` or `onExport` in response to toolbar actions

 Failure modes:
 - empty selections disable the Export command so the parent never receives an invalid request
 - unsupported Android-only module formats are not listed because they are not represented by
   SWORD `ModuleInfo` entries on iOS
 */
struct AndroidModuleBackupExportSheet: View {
    /// Installed SWORD modules eligible for Android-compatible export.
    let modules: [ModuleInfo]

    /// Whether the parent is currently writing the backup archive.
    let isExporting: Bool

    /// Callback used to dismiss without exporting.
    let onCancel: () -> Void

    /// Callback receiving selected module initials in display order.
    let onExport: ([String]) -> Void

    /// Current selected module initials.
    @State private var selectedModuleNames: Set<String>

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
        modules: [ModuleInfo],
        isExporting: Bool,
        onCancel: @escaping () -> Void,
        onExport: @escaping ([String]) -> Void
    ) {
        self.modules = modules
        self.isExporting = isExporting
        self.onCancel = onCancel
        self.onExport = onExport
        _selectedModuleNames = State(initialValue: Set(modules.map(\.name)))
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
                    ForEach(modules, id: \.name) { module in
                        Toggle(isOn: binding(for: module.name)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(module.description.isEmpty ? module.name : module.description)
                                    .font(.body)
                                Text(moduleDetail(for: module))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(isExporting)
                        .accessibilityIdentifier("androidModuleBackupExportRow::\(module.name)")
                    }
                } header: {
                    Text(String(localized: "android_module_backup_export_modules", defaultValue: "Select modules"))
                } footer: {
                    Text(
                        String(
                            localized: "android_module_backup_export_footer",
                            defaultValue: "Only SWORD-backed modules can be exported in an Android-compatible module backup on iOS."
                        )
                    )
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
                    .disabled(isExporting)
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
        modules.map(\.name).filter(selectedModuleNames.contains)
    }

    /**
     Title for the Android-style select-all/select-none control.

     - Returns: "Select none" when all modules are selected, otherwise "Select all".
     - Side effects: none.
     - Failure modes: none.
     */
    private var selectionToggleTitle: String {
        if selectedModuleNames.count == modules.count {
            return String(localized: "select_none", defaultValue: "Select none")
        }
        return String(localized: "select_all", defaultValue: "Select all")
    }

    /**
     Produces a mutable selection binding for one module row.

     - Parameter moduleName: Module initials whose selected state should be exposed.
     - Returns: Binding that adds or removes the module from `selectedModuleNames`.
     - Side effects: Writes local sheet selection state when the user toggles a row.
     - Failure modes: none.
     */
    private func binding(for moduleName: String) -> Binding<Bool> {
        Binding(
            get: { selectedModuleNames.contains(moduleName) },
            set: { isSelected in
                if isSelected {
                    selectedModuleNames.insert(moduleName)
                } else {
                    selectedModuleNames.remove(moduleName)
                }
            }
        )
    }

    /**
     Toggles between all modules selected and no modules selected.

     Side effects:
     - mutates `selectedModuleNames`

     Failure modes:
     - empty module lists remain empty; the toolbar button is disabled for that state.
     */
    private func toggleAllSelections() {
        if selectedModuleNames.count == modules.count {
            selectedModuleNames.removeAll()
        } else {
            selectedModuleNames = Set(modules.map(\.name))
        }
    }

    /**
     Builds Android-like row detail text from module initials, category, and language.

     - Parameter module: Installed module shown in the export sheet.
     - Returns: Compact detail text that distinguishes similarly named modules.
     - Side effects: none.
     - Failure modes: none.
     */
    private func moduleDetail(for module: ModuleInfo) -> String {
        let language = module.language.isEmpty ? "?" : module.language
        return "\(module.name), \(language), \(module.category.rawValue)"
    }
}
