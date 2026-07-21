// MyDocumentMetadataEditor.swift -- Document create/rename/description editor

import SwiftUI

/**
 Value request presented by the My Documents manager for document metadata editing.
 */
struct MyDocumentMetadataEditorRequest: Identifiable {
    let id = UUID()
    let documentID: UUID?
    let title: String
    let initialName: String
    let initialDescription: String
    let importsPendingFiles: Bool
}

/**
 Edits one document's name and description without touching persistence until Save.
 */
struct MyDocumentMetadataEditor: View {
    @Environment(\.dismiss) private var dismiss

    let request: MyDocumentMetadataEditorRequest
    let onSave: (String, String?) -> Void

    @State private var name: String
    @State private var documentDescription: String

    init(
        request: MyDocumentMetadataEditorRequest,
        onSave: @escaping (String, String?) -> Void
    ) {
        self.request = request
        self.onSave = onSave
        _name = State(initialValue: request.initialName)
        _documentDescription = State(initialValue: request.initialDescription)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(
                    String(localized: "name", defaultValue: "Name"),
                    text: $name
                )
                TextField(
                    String(localized: "description", defaultValue: "Description"),
                    text: $documentDescription,
                    axis: .vertical
                )
                .lineLimit(3...6)
            }
            .navigationTitle(request.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "save")) {
                        onSave(name, documentDescription)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 340, minHeight: 260)
    }
}
