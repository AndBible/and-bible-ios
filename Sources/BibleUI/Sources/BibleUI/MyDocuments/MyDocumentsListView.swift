// MyDocumentsListView.swift -- Android-parity My Documents library management

import BibleCore
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/**
 Manages the complete My Documents library with explicit Save and Cancel boundaries.

 Android exposes document creation, multi-file import, rename/description editing, delete, reorder,
 export, and a nested page manager. This view provides the same workflows over a value-based
 `MyDocumentManagementSession`; SwiftData is touched only by Save, so Cancel reliably discards
 creates, imports, deletes, reorders, and edits together.

 - Side effects: Loads SwiftData on first appearance, writes one transactional graph on Save,
   imports security-scoped text files, and creates temporary export files for native sharing.
 - Failure modes: Validation, UTF-8 import, export, and persistence failures are shown to the user
   and leave the current draft available for correction or retry.
 */
public struct MyDocumentsListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let reservedInitials: Set<String>
    private let onDismiss: (() -> Void)?
    private let onLibrarySaved: (() -> Void)?
    private let onOpenPage: (String, String) -> Void

    @State private var session = MyDocumentManagementSession(documents: [])
    @State private var didLoad = false
    @State private var metadataEditorRequest: MyDocumentMetadataEditorRequest?
    @State private var pendingImportFiles: [MyDocumentImportFile] = []
    @State private var isImportingDocument = false
    @State private var pendingDeleteDocument: MyDocumentDraft?
    @State private var pendingOpenDocumentID: UUID?
    @State private var activeDocumentID: UUID?
    @State private var showsCloseDecision = false
    @State private var showsOpenDocumentDecision = false
    @State private var exportURLs: [URL] = []
    @State private var showsExport = false
    @State private var errorMessage: String?

    /**
     Creates the My Documents manager.

     - Parameters:
       - reservedInitials: Installed module initials unavailable to generated My Documents.
       - onDismiss: Optional owner callback used when the manager is a reader-stack destination.
       - onLibrarySaved: Optional callback that refreshes readers after persistence succeeds.
       - onOpenPage: Opens a persisted page in the owning reader pane.
     - Side effects: None until the view appears or the user invokes a workflow.
     - Failure modes: None.
     */
    public init(
        reservedInitials: Set<String> = [],
        onDismiss: (() -> Void)? = nil,
        onLibrarySaved: (() -> Void)? = nil,
        onOpenPage: @escaping (String, String) -> Void
    ) {
        self.reservedInitials = reservedInitials
        self.onDismiss = onDismiss
        self.onLibrarySaved = onLibrarySaved
        self.onOpenPage = onOpenPage
    }

    /** Builds the document library, editing surfaces, and explicit transaction controls. */
    public var body: some View {
        Group {
            if session.documents.isEmpty {
                ContentUnavailableView(
                    String(localized: "my_documents", defaultValue: "My Documents"),
                    systemImage: "doc.text",
                    description: Text(
                        String(
                            localized: "my_documents_empty",
                            defaultValue: "No documents yet. Tap + to create one."
                        )
                    )
                )
                .accessibilityIdentifier("myDocumentsListScreen")
                .accessibilityValue(myDocumentsAccessibilityValue)
            } else {
                List {
                    ForEach(session.documents) { document in
                        Button {
                            requestOpenDocument(document.id)
                        } label: {
                            MyDocumentRow(document: document)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(documentRowIdentifier(for: document))
                        .accessibilityLabel(document.name)
                        .accessibilityValue(
                            "initials=\(document.initials);pages=\(document.pages.count)"
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteDocument = document
                            } label: {
                                Label(String(localized: "delete"), systemImage: "trash")
                            }
                            Button {
                                edit(document)
                            } label: {
                                Label(String(localized: "rename"), systemImage: "pencil")
                            }
                            .tint(.accentColor)
                        }
                        .contextMenu {
                            Button {
                                edit(document)
                            } label: {
                                Label(String(localized: "rename"), systemImage: "pencil")
                            }
                            Button {
                                export(document)
                            } label: {
                                Label(String(localized: "export"), systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                pendingDeleteDocument = document
                            } label: {
                                Label(String(localized: "delete"), systemImage: "trash")
                            }
                        }
                    }
                    .onMove { offsets, destination in
                        session.moveDocuments(fromOffsets: offsets, toOffset: destination)
                    }
                }
                .accessibilityIdentifier("myDocumentsListScreen")
                .accessibilityValue(myDocumentsAccessibilityValue)
            }
        }
        .overlay(alignment: .topLeading) { myDocumentsListStateExport }
        .navigationTitle(String(localized: "my_documents", defaultValue: "My Documents"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationBarBackButtonHidden(true)
        .toolbar { documentToolbar }
        .onAppear(perform: loadSessionIfNeeded)
        .navigationDestination(item: $activeDocumentID) { documentID in
            MyDocumentPagesListView(
                documentID: documentID,
                session: $session,
                onSave: saveSession,
                onOpenPage: onOpenPage
            )
        }
        .overlay {
            if let request = metadataEditorRequest {
                AndroidMyDocumentMetadataDialog(
                    request: request,
                    onDismiss: { metadataEditorRequest = nil },
                    onSave: { name, description in
                        applyMetadataEditor(request, name: name, description: description)
                        metadataEditorRequest = nil
                    }
                )
            }
        }
        .sheet(isPresented: $showsExport) {
            ShareSheet(items: exportURLs.map { $0 as Any })
        }
        .fileImporter(
            isPresented: $isImportingDocument,
            allowedContentTypes: [.plainText, .html, .text],
            allowsMultipleSelection: true,
            onCompletion: prepareDocumentImport
        )
        .confirmationDialog(
            String(localized: "my_document_save_changes", defaultValue: "Save changes?"),
            isPresented: $showsCloseDecision,
            titleVisibility: .visible
        ) {
            Button(String(localized: "save")) {
                if saveSession() { close() }
            }
            Button(String(localized: "no", defaultValue: "Don't Save"), role: .destructive) {
                session.discardChanges()
                close()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            String(localized: "my_document_save_changes", defaultValue: "Save changes?"),
            isPresented: $showsOpenDocumentDecision,
            titleVisibility: .visible
        ) {
            Button(String(localized: "save")) {
                if saveSession() { openPendingDocument() }
            }
            Button(String(localized: "no", defaultValue: "Don't Save"), role: .destructive) {
                session.discardChanges()
                openPendingDocument()
            }
            Button(String(localized: "cancel"), role: .cancel) {
                pendingOpenDocumentID = nil
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { pendingDeleteDocument != nil },
                set: { if !$0 { pendingDeleteDocument = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "delete"), role: .destructive, action: deletePendingDocument)
            Button(String(localized: "cancel"), role: .cancel) {}
        }
        .alert(
            String(localized: "errorTitle", defaultValue: "Error occurred"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(String(localized: "okay", defaultValue: "OK")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private var documentToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "cancel"), action: requestClose)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            #if os(iOS)
            EditButton()
            #endif
            Menu {
                Button(action: createDocument) {
                    Label(
                        String(localized: "my_document_create_title", defaultValue: "Create new document"),
                        systemImage: "doc.badge.plus"
                    )
                }
                Button { isImportingDocument = true } label: {
                    Label(
                        String(localized: "my_document_import_document", defaultValue: "Import files as document"),
                        systemImage: "square.and.arrow.down"
                    )
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(String(
                localized: "my_document_create_title",
                defaultValue: "Create new document"
            ))

            Button(String(localized: "save")) {
                if saveSession() { close() }
            }
            .disabled(!session.isDirty)
        }
    }

    private var deleteConfirmationTitle: String {
        String(
            format: String(
                localized: "my_document_delete_confirmation",
                defaultValue: "Delete document \"%@\"?"
            ),
            pendingDeleteDocument?.name ?? ""
        )
    }

    private var myDocumentsAccessibilityValue: String {
        let baseState = "total=\(session.documents.count);dirty=\(session.isDirty)"
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else {
            return baseState
        }
        let rowTokens = session.documents
            .prefix(UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit)
            .map { "|\(myDocumentsAccessibilitySegment($0.initials))|" }
            .joined(separator: ",")
        return "\(baseState);rows=\(rowTokens)"
    }

    @ViewBuilder
    private var myDocumentsListStateExport: some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            Text(myDocumentsAccessibilityValue)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier("myDocumentsListStateExport")
                .accessibilityValue(myDocumentsAccessibilityValue)
        }
    }

    private func loadSessionIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        do {
            session = try MyDocumentLibraryStore(modelContext: modelContext).loadSession()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createDocument() {
        metadataEditorRequest = MyDocumentMetadataEditorRequest(
            documentID: nil,
            title: String(localized: "my_document_create_title", defaultValue: "Create new document"),
            initialName: String(
                format: String(localized: "my_document_new_name", defaultValue: "Document %d"),
                session.documents.count + 1
            ),
            initialDescription: "",
            importsPendingFiles: false
        )
    }

    private func edit(_ document: MyDocumentDraft) {
        metadataEditorRequest = MyDocumentMetadataEditorRequest(
            documentID: document.id,
            title: String(localized: "my_document_rename_title", defaultValue: "Rename document"),
            initialName: document.name,
            initialDescription: document.documentDescription ?? "",
            importsPendingFiles: false
        )
    }

    private func applyMetadataEditor(
        _ request: MyDocumentMetadataEditorRequest,
        name: String,
        description: String?
    ) {
        do {
            if request.importsPendingFiles {
                let documentID = try session.importDocument(
                    name: name,
                    files: pendingImportFiles,
                    reservedInitials: reservedInitials
                )
                try session.setDocumentDescription(id: documentID, description: description)
                pendingImportFiles = []
            } else if let documentID = request.documentID {
                try session.renameDocument(id: documentID, name: name)
                try session.setDocumentDescription(id: documentID, description: description)
            } else {
                _ = try session.createDocument(
                    name: name,
                    documentDescription: description,
                    reservedInitials: reservedInitials
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareDocumentImport(_ result: Result<[URL], Error>) {
        do {
            let files = try MyDocumentNativeFileTransfer.importFiles(at: result.get())
            guard !files.isEmpty else { throw MyDocumentManagementError.emptyImport }
            pendingImportFiles = files
            metadataEditorRequest = MyDocumentMetadataEditorRequest(
                documentID: nil,
                title: String(
                    localized: "my_document_import_document",
                    defaultValue: "Import files as document"
                ),
                initialName: String(
                    format: String(localized: "my_document_new_name", defaultValue: "Document %d"),
                    session.documents.count + 1
                ),
                initialDescription: "",
                importsPendingFiles: true
            )
        } catch {
            pendingImportFiles = []
            errorMessage = error.localizedDescription
        }
    }

    private func export(_ document: MyDocumentDraft) {
        do {
            exportURLs = try MyDocumentNativeFileTransfer.exportURLs(
                for: MyDocumentTransferService.exportDocument(document),
                directoryName: document.name
            )
            showsExport = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deletePendingDocument() {
        guard let document = pendingDeleteDocument else { return }
        pendingDeleteDocument = nil
        do {
            try session.deleteDocument(id: document.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveSession() -> Bool {
        var candidate = session
        do {
            try MyDocumentLibraryStore(modelContext: modelContext).save(
                &candidate,
                reservedInitials: reservedInitials
            )
            session = candidate
            onLibrarySaved?()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func requestOpenDocument(_ documentID: UUID) {
        guard session.isDirty else {
            activeDocumentID = documentID
            return
        }
        pendingOpenDocumentID = documentID
        showsOpenDocumentDecision = true
    }

    private func openPendingDocument() {
        guard let documentID = pendingOpenDocumentID else { return }
        pendingOpenDocumentID = nil
        if session.document(id: documentID) != nil {
            activeDocumentID = documentID
        }
    }

    private func requestClose() {
        if session.isDirty {
            showsCloseDecision = true
        } else {
            close()
        }
    }

    private func close() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private func documentRowIdentifier(for document: MyDocumentDraft) -> String {
        "myDocumentsDocumentRow::\(myDocumentsAccessibilitySegment(document.initials))"
    }
}

/** Android-style document row showing the name and description, without internal key metadata. */
private struct MyDocumentRow: View {
    let document: MyDocumentDraft

    private var descriptionText: String {
        guard let description = document.documentDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else {
            return String(localized: "my_document_no_description", defaultValue: "No description")
        }
        return description
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: document.sourcePromptId != nil
                ? "sparkles"
                : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(document.name)
                    .foregroundStyle(.primary)
                Text(descriptionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

/** Sanitizes My Documents values into stable UI-test tokens. */
private func myDocumentsAccessibilitySegment(_ value: String) -> String {
    value.replacingOccurrences(
        of: "[^A-Za-z0-9]+",
        with: "_",
        options: .regularExpression
    )
    .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}
