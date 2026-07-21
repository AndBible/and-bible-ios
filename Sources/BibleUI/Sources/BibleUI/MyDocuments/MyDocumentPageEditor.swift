// MyDocumentPageEditor.swift -- Raw Markdown/HTML page editor

import BibleCore
import SwiftUI

/**
 Page editor input used for both create and edit workflows.
 */
struct MyDocumentPageEditorRequest: Identifiable {
    let id = UUID()
    let pageID: UUID?
    let title: String
    let initialTitle: String
    let initialContentType: MyDocumentContentType
    let initialContent: String
}

/**
 Edits raw My Documents content while preserving an explicit Save/Cancel boundary.

 The content-type control intentionally exposes Markdown and HTML only, matching Android's native
 create-page dialog. Existing OSIS pages can still be renamed or edited without silently changing
 their stored type.
 */
struct MyDocumentPageEditor: View {
    @Environment(\.dismiss) private var dismiss

    let request: MyDocumentPageEditorRequest
    let onSave: (String, MyDocumentContentType, String) -> Void

    @State private var pageTitle: String
    @State private var contentType: MyDocumentContentType
    @State private var content: String

    init(
        request: MyDocumentPageEditorRequest,
        onSave: @escaping (String, MyDocumentContentType, String) -> Void
    ) {
        self.request = request
        self.onSave = onSave
        _pageTitle = State(initialValue: request.initialTitle)
        _contentType = State(initialValue: request.initialContentType)
        _content = State(initialValue: request.initialContent)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(
                    String(localized: "name", defaultValue: "Name"),
                    text: $pageTitle
                )

                Picker(
                    String(localized: "my_document_content_type_label", defaultValue: "Content type"),
                    selection: $contentType
                ) {
                    Text("Markdown").tag(MyDocumentContentType.markdown)
                    Text("HTML").tag(MyDocumentContentType.html)
                    if request.initialContentType == .osis {
                        Text("OSIS").tag(MyDocumentContentType.osis)
                    }
                }
                .pickerStyle(.segmented)

                TextEditor(text: $content)
                    .font(.body.monospaced())
                    .frame(minHeight: 280)
                    .accessibilityIdentifier("myDocumentPageContentEditor")
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
                        onSave(pageTitle, contentType, content)
                        dismiss()
                    }
                    .disabled(pageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }
}
