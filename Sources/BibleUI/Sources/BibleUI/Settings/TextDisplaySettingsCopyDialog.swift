// TextDisplaySettingsCopyDialog.swift -- Selective text-settings copy dialog

import SwiftUI

/**
 Android-style multi-choice dialog for copying text-display settings.

 Android opens `chooseSettingsToCopy` before copying settings to a window, workspace, or global
 defaults. SwiftUI does not provide checkboxes inside `Alert`, so this view supplies the same
 functional contract as a centered dialog panel: unchecked by default, selectable rows, Select
 all/none, Cancel, and OK.
 */
struct TextDisplaySettingsCopyDialog: View {
    /// Current appearance used by the shared Android dialog window.
    @Environment(\.colorScheme) private var colorScheme

    /// Owner context retained for automation; Android does not render a target subtitle here.
    let targetTitle: String
    let onCancel: () -> Void
    let onConfirm: (Set<TextDisplaySettingsCopyField>) -> Void

    @State private var selectedFields: Set<TextDisplaySettingsCopyField> = []

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "textDisplaySettingsCopyDialog",
            onOutsideTap: onCancel
        ) {
            AndroidMultiselectDialogContent(
                title: localized("copy_settings_title", default: "Which settings do you want to copy?"),
                rows: TextDisplaySettingsCopyField.allCases.map { field in
                    AndroidMultiselectDialogRow(
                        id: field,
                        title: field.title,
                        accessibilityIdentifier: "textDisplaySettingsCopyField::\(field.id)"
                    )
                },
                selectedIDs: $selectedFields,
                isBusy: false,
                accessibilityIdentifier: "textDisplaySettingsCopyDialogContent",
                accessibilityPrefix: "textDisplaySettingsCopy",
                onCancel: onCancel,
                onConfirm: { onConfirm(Set($0)) }
            )
        }
    }

    /** Resolves one localized Android resource with an explicit English fallback. */
    private func localized(_ key: String, default defaultValue: String) -> String {
        let value = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? defaultValue : value
    }
}
