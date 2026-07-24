// MyDocumentsListView.swift -- App-owned Android My Documents activity

import BibleCore
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/**
 Manages the complete My Documents library with Android's activity structure and transaction rules.

 Presentation mirrors `MyDocumentsActivity`: an app-owned action bar, + command, anchored Import
 overflow, draggable flat rows, per-row popup commands, centered empty message, and persistent
 Dismiss/Save actions. The stronger value-based `MyDocumentManagementSession` remains the single
 mutation owner, so iOS can honor Android's explicit boundaries without Android's intermediate DB
 writes leaking through Cancel.

 Side effects:
 - loads and transactionally saves the SwiftData document graph
 - reads security-scoped imports and hands completed exports to the platform file destination
 - invokes the reader owner only after a persisted page is selected

 Failure modes:
 - validation, transfer, and persistence errors stay on the app-owned route for retry
 - protected AI Documents remain visible and cannot be deleted while they contain pages
 */
public struct MyDocumentsListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let reservedInitials: Set<String>
    private let surfacePalette: ReaderThemeSurfacePalette
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
    @State private var showsOverflowMenu = false
    @State private var activeDocumentMenuID: UUID?
    @State private var documentExportDocuments: [MyDocumentExportDocument] = []
    @State private var showsDocumentFileExporter = false
    @State private var toastMessage: String?
    @State private var errorMessage: String?

    /**
     Creates a standalone My Documents route using the application palette.

     - Parameters:
       - reservedInitials: Installed module initials unavailable to generated My Documents.
       - onDismiss: Optional owner callback used when the manager is a reader destination.
       - onLibrarySaved: Optional callback that refreshes readers after persistence succeeds.
       - onOpenPage: Opens a persisted page in the owning reader pane.
     */
    public init(
        reservedInitials: Set<String> = [],
        onDismiss: (() -> Void)? = nil,
        onLibrarySaved: (() -> Void)? = nil,
        onOpenPage: @escaping (String, String) -> Void
    ) {
        self.reservedInitials = reservedInitials
        surfacePalette = .standard
        self.onDismiss = onDismiss
        self.onLibrarySaved = onLibrarySaved
        self.onOpenPage = onOpenPage
    }

    /** Creates a reader-owned route using its resolved workspace/window palette. */
    init(
        reservedInitials: Set<String>,
        surfacePalette: ReaderThemeSurfacePalette,
        onDismiss: (() -> Void)?,
        onLibrarySaved: (() -> Void)?,
        onOpenPage: @escaping (String, String) -> Void
    ) {
        self.reservedInitials = reservedInitials
        self.surfacePalette = surfacePalette
        self.onDismiss = onDismiss
        self.onLibrarySaved = onLibrarySaved
        self.onOpenPage = onOpenPage
    }

    /** Builds either the document activity or its app-owned nested Pages activity. */
    public var body: some View {
        ZStack {
            surfacePalette.backgroundColor.ignoresSafeArea()

            if let activeDocumentID {
                MyDocumentPagesListView(
                    documentID: activeDocumentID,
                    session: $session,
                    surfacePalette: surfacePalette,
                    onDismiss: { self.activeDocumentID = nil },
                    onSave: saveSession,
                    onOpenPage: onOpenPage
                )
            } else {
                libraryActivity
            }
        }
        .onAppear(perform: loadSessionIfNeeded)
        .fileImporter(
            isPresented: $isImportingDocument,
            allowedContentTypes: [.plainText, .html, .text],
            allowsMultipleSelection: true,
            onCompletion: prepareDocumentImport
        )
        .fileExporter(
            isPresented: $showsDocumentFileExporter,
            documents: documentExportDocuments,
            contentTypes: [.plainText, .html, .text],
            onCompletion: completeDocumentExport
        )
        .overlay { dialogLayer }
        .androidToastFeedback(toastMessage, bottomPadding: 72)
        #if os(iOS)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    /// Android's complete top/content/bottom activity hierarchy.
    private var libraryActivity: some View {
        AndroidMyDocumentsActivityView(
            documents: session.documents,
            surfacePalette: surfacePalette,
            isDirty: session.isDirty,
            accessibilityValue: myDocumentsAccessibilityValue,
            showsOverflowMenu: $showsOverflowMenu,
            activeDocumentMenuID: $activeDocumentMenuID,
            onBack: requestClose,
            onCreate: createDocument,
            onImport: { isImportingDocument = true },
            onDismiss: discardAndClose,
            onSave: saveAndClose,
            onOpen: requestOpenDocument,
            onRename: beginRename,
            onEditDescription: beginDescriptionEdit,
            onExport: export,
            onDelete: requestDelete,
            onMove: { moveDocument($0, before: $1) }
        )
        .overlay(alignment: .topLeading) { myDocumentsListStateExport }
    }

    /// Highest-priority app-owned dialog retained over the activity surface.
    @ViewBuilder
    private var dialogLayer: some View {
        if let request = metadataEditorRequest {
            AndroidMyDocumentMetadataDialog(
                request: request,
                onDismiss: { metadataEditorRequest = nil },
                onSave: { value in
                    applyMetadataEditor(request, value: value)
                    metadataEditorRequest = nil
                }
            )
        } else if showsCloseDecision {
            saveChangesDialog(
                onDiscard: { session.discardChanges(); close() },
                onSave: { if saveSession() { close() } },
                onCancel: { showsCloseDecision = false }
            )
        } else if showsOpenDocumentDecision {
            saveChangesDialog(
                onDiscard: { session.discardChanges(); openPendingDocument() },
                onSave: { if saveSession() { openPendingDocument() } },
                onCancel: {
                    pendingOpenDocumentID = nil
                    showsOpenDocumentDecision = false
                }
            )
        } else if pendingDeleteDocument != nil {
            AndroidDecisionDialog(
                title: "",
                message: deleteConfirmationTitle,
                actions: [
                    .init(id: "no", title: String(localized: "no"), style: .normal) {
                        pendingDeleteDocument = nil
                    },
                    .init(id: "yes", title: String(localized: "yes"), style: .normal) {
                        deletePendingDocument()
                    },
                ],
                accessibilityIdentifier: "myDocumentsDeleteDialog"
            )
        } else if let errorMessage {
            AndroidDecisionDialog(
                title: "",
                message: errorMessage,
                actions: [
                    .init(
                        id: "okay",
                        title: String(localized: "okay", defaultValue: "OK"),
                        style: .normal
                    ) { self.errorMessage = nil },
                ],
                accessibilityIdentifier: "myDocumentsErrorDialog"
            )
        }
    }

    /// Builds Android's three-action Save changes dialog in platform button order.
    private func saveChangesDialog(
        onDiscard: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        AndroidDecisionDialog(
            title: "",
            message: String(localized: "my_document_save_changes", defaultValue: "Save changes?"),
            actions: [
                .init(id: "cancel", title: String(localized: "cancel"), style: .normal, perform: onCancel),
                .init(id: "no", title: String(localized: "no"), style: .normal, perform: onDiscard),
                .init(id: "yes", title: String(localized: "yes"), style: .normal, perform: onSave),
            ],
            accessibilityIdentifier: "myDocumentsSaveChangesDialog"
        )
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
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else { return baseState }
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

    /** Loads the value session once and leaves failures on the owning activity. */
    private func loadSessionIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        do {
            session = try MyDocumentLibraryStore(modelContext: modelContext).loadSession()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /** Opens Android's create-name dialog without inventing a description field. */
    private func createDocument() {
        closePopups()
        metadataEditorRequest = MyDocumentMetadataEditorRequest(
            purpose: .create,
            title: String(localized: "my_document_create_title", defaultValue: "Create new document"),
            initialValue: String(
                format: String(localized: "my_document_new_name", defaultValue: "Document %d"),
                session.documents.count + 1
            )
        )
    }

    /** Opens Android's rename-only dialog for one draft document. */
    private func beginRename(_ document: MyDocumentDraft) {
        closePopups()
        metadataEditorRequest = MyDocumentMetadataEditorRequest(
            purpose: .rename(documentID: document.id),
            title: String(localized: "my_document_rename_title", defaultValue: "Rename document"),
            initialValue: document.name
        )
    }

    /** Opens Android's independent description editor for one draft document. */
    private func beginDescriptionEdit(_ document: MyDocumentDraft) {
        closePopups()
        metadataEditorRequest = MyDocumentMetadataEditorRequest(
            purpose: .editDescription(documentID: document.id),
            title: String(
                localized: "my_document_edit_description",
                defaultValue: "Edit description"
            ),
            initialValue: document.documentDescription ?? ""
        )
    }

    /** Applies exactly the mutation represented by one Android text-entry request. */
    private func applyMetadataEditor(_ request: MyDocumentMetadataEditorRequest, value: String) {
        do {
            switch request.purpose {
            case .create:
                _ = try session.createDocument(name: value, reservedInitials: reservedInitials)
            case .rename(let documentID):
                try session.renameDocument(id: documentID, name: value)
            case .editDescription(let documentID):
                try session.setDocumentDescription(id: documentID, description: value)
            case .importDocument:
                _ = try session.importDocument(
                    name: value,
                    files: pendingImportFiles,
                    reservedInitials: reservedInitials
                )
                pendingImportFiles = []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /** Stages Android's sorted multi-file import, then asks for the new document name. */
    private func prepareDocumentImport(_ result: Result<[URL], Error>) {
        do {
            let files = try MyDocumentNativeFileTransfer.importFiles(at: result.get())
            guard !files.isEmpty else { throw MyDocumentManagementError.emptyImport }
            pendingImportFiles = files
            metadataEditorRequest = MyDocumentMetadataEditorRequest(
                purpose: .importDocument,
                title: String(
                    localized: "my_document_create_title",
                    defaultValue: "Create new document"
                ),
                initialValue: String(
                    format: String(localized: "my_document_new_name", defaultValue: "Document %d"),
                    session.documents.count + 1
                )
            )
        } catch {
            pendingImportFiles = []
            errorMessage = error.localizedDescription
        }
    }

    /** Starts Android's directory-style export as individually named page files. */
    private func export(_ document: MyDocumentDraft) {
        closePopups()
        let files = MyDocumentTransferService.exportDocument(document)
        guard !files.isEmpty else { return }
        documentExportDocuments = files.map(MyDocumentExportDocument.init(file:))
        showsDocumentFileExporter = true
    }

    /** Converts the system file handoff result into Android toast/error feedback. */
    private func completeDocumentExport(_ result: Result<[URL], Error>) {
        switch result {
        case .success:
            showToast(String(
                localized: "my_document_export_success",
                defaultValue: "Pages exported successfully"
            ))
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    /** Preserves Android's protected AI Documents check before confirmation. */
    private func requestDelete(_ document: MyDocumentDraft) {
        closePopups()
        if document.initials == MyDocumentManagementSession.aiDocumentsInitials,
           !document.pages.isEmpty {
            errorMessage = String(
                localized: "my_document_cannot_delete_ai_documents",
                defaultValue: "AI Documents cannot be deleted while it contains pages. Delete the pages first."
            )
        } else {
            pendingDeleteDocument = document
        }
    }

    /** Deletes the confirmed draft and retains failures on the route. */
    private func deletePendingDocument() {
        guard let document = pendingDeleteDocument else { return }
        pendingDeleteDocument = nil
        do {
            try session.deleteDocument(id: document.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /** Persists the complete draft graph transactionally and advances its clean baseline. */
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

    /** Matches Android's dirty prompt before opening the nested Pages activity. */
    private func requestOpenDocument(_ documentID: UUID) {
        closePopups()
        guard session.isDirty else {
            activeDocumentID = documentID
            return
        }
        pendingOpenDocumentID = documentID
        showsOpenDocumentDecision = true
    }

    /** Opens a still-existing pending document after Save or Discard. */
    private func openPendingDocument() {
        showsOpenDocumentDecision = false
        guard let documentID = pendingOpenDocumentID else { return }
        pendingOpenDocumentID = nil
        if session.document(id: documentID) != nil {
            activeDocumentID = documentID
        }
    }

    /** Android Up prompts when dirty; its persistent Dismiss action does not. */
    private func requestClose() {
        closePopups()
        if session.isDirty {
            showsCloseDecision = true
        } else {
            close()
        }
    }

    /** Discards the complete draft when Android's persistent Dismiss action is tapped. */
    private func discardAndClose() {
        session.discardChanges()
        close()
    }

    /** Saves and closes only after the transactional store accepts the complete draft. */
    private func saveAndClose() {
        if saveSession() { close() }
    }

    /** Returns ownership to the reader route or standalone SwiftUI host. */
    private func close() {
        if let onDismiss { onDismiss() } else { dismiss() }
    }

    /** Dismisses both popup owners before opening another route or dialog. */
    private func closePopups() {
        showsOverflowMenu = false
        activeDocumentMenuID = nil
    }

    /** Reorders by stable drag payload while delegating AI pinning/order normalization to BibleCore. */
    private func moveDocument(_ payloads: [String], before targetID: UUID) -> Bool {
        guard let payload = payloads.first,
              let sourceID = UUID(uuidString: payload),
              sourceID != targetID,
              let sourceIndex = session.documents.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = session.documents.firstIndex(where: { $0.id == targetID }) else {
            return false
        }
        let destination = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        session.moveDocuments(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destination)
        return true
    }

    /** Shows one Android short toast and removes only the same still-current message. */
    private func showToast(_ message: String) {
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(AndroidToastFeedback.shortDuration))
            if toastMessage == message { toastMessage = nil }
        }
    }

}
