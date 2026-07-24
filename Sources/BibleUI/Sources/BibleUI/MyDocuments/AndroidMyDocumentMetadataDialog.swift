// AndroidMyDocumentMetadataDialog.swift -- App-owned document text-entry window

import SwiftUI

/** Owns Android's AlertDialog-equivalent window for My Documents text-entry commands. */
struct AndroidMyDocumentMetadataDialog: View {
    @Environment(\.colorScheme) private var colorScheme

    let request: MyDocumentMetadataEditorRequest
    let onDismiss: () -> Void
    let onSave: (String) -> Void

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidMyDocumentMetadataDialog",
            onOutsideTap: onDismiss
        ) {
            MyDocumentMetadataEditor(
                request: request,
                onSave: onSave,
                onCancel: onDismiss
            )
        }
    }
}
