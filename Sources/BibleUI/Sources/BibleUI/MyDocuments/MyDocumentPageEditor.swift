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
    @Environment(\.colorScheme) private var colorScheme

    let request: MyDocumentPageEditorRequest
    let onCancel: () -> Void
    let onSave: (String, MyDocumentContentType, String) -> Void

    @State private var pageTitle: String
    @State private var contentType: MyDocumentContentType
    @State private var content: String

    init(
        request: MyDocumentPageEditorRequest,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, MyDocumentContentType, String) -> Void
    ) {
        self.request = request
        self.onCancel = onCancel
        self.onSave = onSave
        _pageTitle = State(initialValue: request.initialTitle)
        _contentType = State(initialValue: request.initialContentType)
        _content = State(initialValue: request.initialContent)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 16) {
                Text(request.title)
                    .font(.headline)
                    .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))

                TextField(
                    String(localized: "name", defaultValue: "Name"),
                    text: $pageTitle
                )
                .textFieldStyle(.roundedBorder)

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
                    .frame(minHeight: 260)
                    .padding(6)
                    .background(AndroidDialogSurfacePalette.fieldBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("myDocumentPageContentEditor")

                HStack {
                    Spacer()
                    Button(String(localized: "cancel"), action: onCancel)
                        .accessibilityIdentifier("myDocumentPageEditorCancelButton")
                    Button(String(localized: "save")) {
                        onSave(pageTitle, contentType, content)
                    }
                    .disabled(pageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
                    .accessibilityIdentifier("myDocumentPageEditorSaveButton")
                }
            }
            .padding(24)
            .frame(maxWidth: 680)
            .background(AndroidDialogSurfacePalette.background(for: colorScheme), in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 16)
            .padding(24)
        }
        .accessibilityIdentifier("androidMyDocumentPageEditorDialog")
    }
}
