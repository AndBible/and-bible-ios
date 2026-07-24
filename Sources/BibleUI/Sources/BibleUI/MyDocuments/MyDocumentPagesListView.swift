// MyDocumentPagesListView.swift -- App-owned Android document Pages activity

import BibleCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/**
 Manages one document's pages using Android's Pages activity presentation and behavior.

 The route owns an app bar, promoted New-page action, anchored Import overflow, draggable flat rows,
 per-page popup menus, a text-only empty state, and persistent Dismiss/Save actions. It mutates the
 parent's value session and delegates persistence to one parent callback, preserving a deterministic
 page-level Save/Discard boundary without native iOS List, Menu, toolbar, or navigation chrome.

 Side effects:
 - mutates the bound draft session
 - invokes the parent's transactional Save callback
 - reads one security-scoped import or hands a completed export/share to the platform
 - opens a persisted page in the owning reader

 Failure modes: missing documents and workflow errors remain visible on the app-owned route
 */
struct MyDocumentPagesListView: View {
    let documentID: UUID
    @Binding var session: MyDocumentManagementSession
    let surfacePalette: ReaderThemeSurfacePalette
    let onDismiss: () -> Void
    let onSave: () -> Bool
    let onOpenPage: (String, String) -> Void

    @State private var baselinePages: [MyDocumentPageDraft]?
    @State private var editorRequest: MyDocumentPageEditorRequest?
    @State private var isImporting = false
    @State private var pendingDeletePage: MyDocumentPageDraft?
    @State private var pendingOpenPage: MyDocumentPageDraft?
    @State private var showsDirtyDecision = false
    @State private var pendingExitAfterDecision = false
    @State private var showsOverflowMenu = false
    @State private var activePageMenuID: UUID?
    @State private var pageExportDocument: MyDocumentExportDocument?
    @State private var exportURLs: [URL] = []
    @State private var showsExportDestinationDecision = false
    @State private var showsPageFileExporter = false
    @State private var showsShareSheet = false
    @State private var errorMessage: String?

    private var document: MyDocumentDraft? {
        session.document(id: documentID)
    }

    private var pages: [MyDocumentPageDraft] {
        document?.pages ?? []
    }

    private var hasPageChanges: Bool {
        guard let baselinePages else { return false }
        return pages != baselinePages
    }

    /** Builds the complete app-owned activity and its legitimate platform file handoffs. */
    var body: some View {
        AndroidMyDocumentPagesActivityView(
            document: document,
            pages: pages,
            surfacePalette: surfacePalette,
            hasChanges: hasPageChanges,
            accessibilityValue: myDocumentPagesAccessibilityValue,
            showsOverflowMenu: $showsOverflowMenu,
            activePageMenuID: $activePageMenuID,
            onBack: requestExit,
            onCreate: beginCreatePage,
            onImport: { isImporting = true },
            onDismiss: discardAndExit,
            onSave: saveAndExit,
            onOpen: requestOpen,
            onRename: beginRenamePage,
            onExport: beginExport,
            onDelete: { pendingDeletePage = $0 },
            onMove: { movePage($0, before: $1) }
        )
        .overlay(alignment: .topLeading) { myDocumentPagesStateExport }
        .onAppear {
            if baselinePages == nil { baselinePages = pages }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.plainText, .html, .text],
            allowsMultipleSelection: false,
            onCompletion: importPage
        )
        .fileExporter(
            isPresented: $showsPageFileExporter,
            document: pageExportDocument,
            contentTypes: pageExportDocument.map { [$0.contentType] } ?? [.text],
            defaultFilename: pageExportDocument?.fileName,
            onCompletion: completePageFileExport
        )
        .sheet(isPresented: $showsShareSheet, onDismiss: clearPageExport) {
            ShareSheet(items: exportURLs.map { $0 as Any })
        }
        .overlay { dialogLayer }
        #if os(iOS)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    /// Highest-priority app-owned page dialog.
    @ViewBuilder
    private var dialogLayer: some View {
        if let editorRequest {
            MyDocumentPageEditor(
                request: editorRequest,
                onCancel: { self.editorRequest = nil }
            ) { title, type in
                applyEditor(editorRequest, title: title, contentType: type)
                self.editorRequest = nil
            }
        } else if showsDirtyDecision {
            AndroidDecisionDialog(
                title: "",
                message: String(
                    localized: "my_document_save_changes",
                    defaultValue: "Save changes?"
                ),
                actions: [
                    .init(id: "cancel", title: String(localized: "cancel"), style: .normal) {
                        pendingOpenPage = nil
                        pendingExitAfterDecision = false
                        showsDirtyDecision = false
                    },
                    .init(id: "no", title: String(localized: "no"), style: .normal) {
                        discardAndContinue()
                    },
                    .init(id: "yes", title: String(localized: "yes"), style: .normal) {
                        saveAndContinue()
                    },
                ],
                accessibilityIdentifier: "myDocumentPagesSaveChangesDialog"
            )
        } else if pendingDeletePage != nil {
            AndroidDecisionDialog(
                title: "",
                message: pageDeleteConfirmation,
                actions: [
                    .init(id: "no", title: String(localized: "no"), style: .normal) {
                        pendingDeletePage = nil
                    },
                    .init(id: "yes", title: String(localized: "yes"), style: .normal) {
                        deletePendingPage()
                    },
                ],
                accessibilityIdentifier: "myDocumentPagesDeleteDialog"
            )
        } else if showsExportDestinationDecision {
            AndroidDecisionDialog(
                title: String(
                    localized: "backup_backup_title",
                    defaultValue: "Backup to where?"
                ),
                message: String(
                    localized: "backup_backup_message",
                    defaultValue: "Backup to phone or elsewhere via Share function (email, Google Drive etc.)?"
                ),
                actions: [
                    .init(id: "cancel", title: String(localized: "cancel"), style: .normal) {
                        showsExportDestinationDecision = false
                        clearPageExport()
                    },
                    .init(
                        id: "phone",
                        title: String(
                            localized: "backup_phone_storage",
                            defaultValue: "Phone storage"
                        ),
                        style: .normal
                    ) {
                        showsExportDestinationDecision = false
                        showsPageFileExporter = true
                    },
                    .init(id: "share", title: String(localized: "share"), style: .normal) {
                        sharePreparedPageExport()
                    },
                ],
                accessibilityIdentifier: "myDocumentPagesExportDestinationDialog"
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
                accessibilityIdentifier: "myDocumentPagesErrorDialog"
            )
        }
    }

    private var pageDeleteConfirmation: String {
        String(
            format: String(
                localized: "my_document_page_delete_confirmation",
                defaultValue: "Delete page \"%@\"?"
            ),
            pendingDeletePage?.title ?? ""
        )
    }

    private var myDocumentPagesAccessibilityValue: String {
        let baseState = "document=\(document?.initials ?? "missing");total=\(pages.count);dirty=\(hasPageChanges)"
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else { return baseState }
        let rowTokens = pages
            .prefix(UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit)
            .map { "|\(myDocumentsAccessibilitySegment($0.pageKey))|" }
            .joined(separator: ",")
        return "\(baseState);rows=\(rowTokens)"
    }

    @ViewBuilder
    private var myDocumentPagesStateExport: some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            Text(myDocumentPagesAccessibilityValue)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier("myDocumentPagesStateExport")
                .accessibilityValue(myDocumentPagesAccessibilityValue)
        }
    }

    /** Starts Android's create-page dialog with MARKDOWN selected by default. */
    private func beginCreatePage() {
        closePopups()
        editorRequest = MyDocumentPageEditorRequest(
            pageID: nil,
            title: String(
                localized: "my_document_create_page_title",
                defaultValue: "New page"
            ),
            initialTitle: String(
                format: String(
                    localized: "my_document_new_page_name",
                    defaultValue: "Page %d"
                ),
                pages.count + 1
            ),
            initialContentType: .markdown
        )
    }

    /** Starts Android's rename-only page dialog without exposing raw content. */
    private func beginRenamePage(_ page: MyDocumentPageDraft) {
        closePopups()
        editorRequest = MyDocumentPageEditorRequest(
            pageID: page.id,
            title: String(
                localized: "my_document_page_rename_title",
                defaultValue: "Rename page"
            ),
            initialTitle: page.title,
            initialContentType: page.contentType
        )
    }

    /** Applies Create or Rename while preserving existing body/type data for Rename. */
    private func applyEditor(
        _ request: MyDocumentPageEditorRequest,
        title: String,
        contentType: MyDocumentContentType
    ) {
        do {
            if let pageID = request.pageID,
               let page = pages.first(where: { $0.id == pageID }) {
                try session.updatePage(
                    documentID: documentID,
                    pageID: pageID,
                    title: title,
                    contentType: page.contentType,
                    content: page.content
                )
            } else {
                _ = try session.createPage(
                    documentID: documentID,
                    title: title,
                    contentType: contentType
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /** Imports Android's one selected Markdown/HTML file into the draft page collection. */
    private func importPage(_ result: Result<[URL], Error>) {
        do {
            guard let file = try MyDocumentNativeFileTransfer.importFiles(at: result.get()).first else {
                throw MyDocumentManagementError.emptyImport
            }
            _ = try session.importPage(documentID: documentID, file: file)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /** Prepares one deterministic page export before Android's shared Save-or-Share decision. */
    private func beginExport(_ page: MyDocumentPageDraft) {
        closePopups()
        pageExportDocument = MyDocumentExportDocument(
            file: MyDocumentTransferService.exportPage(page)
        )
        showsExportDestinationDecision = true
    }

    /** Materializes a temporary URL only after the user explicitly selects Android's Share action. */
    private func sharePreparedPageExport() {
        showsExportDestinationDecision = false
        guard let document, let pageExportDocument else { return }
        do {
            exportURLs = try MyDocumentNativeFileTransfer.exportURLs(
                for: [MyDocumentExportFile(
                    fileName: pageExportDocument.fileName,
                    contentType: pageExportDocument.contentType == .html
                        ? "text/html"
                        : "text/markdown",
                    content: pageExportDocument.content
                )],
                directoryName: document.name
            )
            showsShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /** Handles the final system Files handoff without presenting app content as an iOS sheet. */
    private func completePageFileExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            clearPageExport()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    /** Releases transient export records after Save, Share dismissal, or Cancel. */
    private func clearPageExport() {
        pageExportDocument = nil
        exportURLs = []
    }

    /** Deletes the confirmed page from the draft collection. */
    private func deletePendingPage() {
        guard let page = pendingDeletePage else { return }
        pendingDeletePage = nil
        do {
            try session.deletePage(documentID: documentID, pageID: page.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /** Matches Android's dirty prompt before returning one selected page to the reader. */
    private func requestOpen(_ page: MyDocumentPageDraft) {
        closePopups()
        guard hasPageChanges else {
            open(page)
            return
        }
        pendingOpenPage = page
        pendingExitAfterDecision = false
        showsDirtyDecision = true
    }

    /** Android Up prompts on dirty state; persistent Dismiss discards immediately. */
    private func requestExit() {
        closePopups()
        guard hasPageChanges else {
            onDismiss()
            return
        }
        pendingOpenPage = nil
        pendingExitAfterDecision = true
        showsDirtyDecision = true
    }

    /** Persists the parent session and resumes the pending Exit/Open command. */
    private func saveAndContinue() {
        guard onSave() else { return }
        baselinePages = pages
        showsDirtyDecision = false
        continuePendingAction()
    }

    /** Restores the clean parent baseline and resumes the pending Exit/Open command. */
    private func discardAndContinue() {
        session.discardChanges()
        baselinePages = pages
        showsDirtyDecision = false
        continuePendingAction()
    }

    /** Completes the exact activity action that originally triggered the dirty decision. */
    private func continuePendingAction() {
        if pendingExitAfterDecision {
            pendingExitAfterDecision = false
            onDismiss()
            return
        }
        if let pendingOpenPage {
            self.pendingOpenPage = nil
            if let persistedPage = pages.first(where: { $0.id == pendingOpenPage.id }) {
                open(persistedPage)
            }
        }
    }

    /** Persistent Dismiss restores the parent baseline and closes without another prompt. */
    private func discardAndExit() {
        session.discardChanges()
        baselinePages = pages
        onDismiss()
    }

    /** Persistent Save closes only after the parent transaction succeeds. */
    private func saveAndExit() {
        guard onSave() else { return }
        baselinePages = pages
        onDismiss()
    }

    /** Returns one stable Android document/page key to the owning reader. */
    private func open(_ page: MyDocumentPageDraft) {
        guard let document else { return }
        onOpenPage(document.initials, page.pageKey)
    }

    /** Closes both popup owners before opening another activity surface. */
    private func closePopups() {
        showsOverflowMenu = false
        activePageMenuID = nil
    }

    /** Reorders a stable drag payload before one target row and lets BibleCore normalize order. */
    private func movePage(_ payloads: [String], before targetID: UUID) -> Bool {
        guard let payload = payloads.first,
              let sourceID = UUID(uuidString: payload),
              sourceID != targetID,
              let sourceIndex = pages.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = pages.firstIndex(where: { $0.id == targetID }) else {
            return false
        }
        let destination = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        do {
            try session.movePages(
                documentID: documentID,
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: destination
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

}
