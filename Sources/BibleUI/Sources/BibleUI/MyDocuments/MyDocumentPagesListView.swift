// MyDocumentPagesListView.swift -- Android-parity page management for one My Document

import BibleCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/**
 Manages one document's pages with explicit page-level Save/Cancel behavior.
 */
struct MyDocumentPagesListView: View {
    @Environment(\.dismiss) private var dismiss

    let documentID: UUID
    @Binding var session: MyDocumentManagementSession
    let onSave: () -> Bool
    let onOpenPage: (String, String) -> Void

    @State private var baselinePages: [MyDocumentPageDraft]?
    @State private var editorRequest: MyDocumentPageEditorRequest?
    @State private var isImporting = false
    @State private var pendingDeletePage: MyDocumentPageDraft?
    @State private var pendingOpenPage: MyDocumentPageDraft?
    @State private var showsDirtyDecision = false
    @State private var pendingExitAfterDecision = false
    @State private var exportURLs: [URL] = []
    @State private var showsExport = false
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

    var body: some View {
        Group {
            if let document {
                List {
                    if pages.isEmpty {
                        ContentUnavailableView(
                            document.name,
                            systemImage: "doc.text",
                            description: Text(
                                String(
                                    localized: "my_document_pages_empty",
                                    defaultValue: "No pages in this document."
                                )
                            )
                        )
                    } else {
                        ForEach(pages) { page in
                            pageRow(page, document: document)
                        }
                        .onMove { offsets, destination in
                            do {
                                try session.movePages(
                                    documentID: documentID,
                                    fromOffsets: offsets,
                                    toOffset: destination
                                )
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
                .navigationTitle(document.name)
            } else {
                ContentUnavailableView(
                    String(localized: "my_documents", defaultValue: "My Documents"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(String(
                        localized: "error_key_not_in_document",
                        defaultValue: "Not found in document"
                    ))
                )
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationBarBackButtonHidden(true)
        .toolbar { pageToolbar }
        .onAppear {
            if baselinePages == nil { baselinePages = pages }
        }
        .sheet(item: $editorRequest) { request in
            MyDocumentPageEditor(request: request) { title, type, content in
                applyEditor(request, title: title, contentType: type, content: content)
            }
        }
        .sheet(isPresented: $showsExport) {
            ShareSheet(items: exportURLs.map { $0 as Any })
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.plainText, .html, .text],
            allowsMultipleSelection: false,
            onCompletion: importPage
        )
        .confirmationDialog(
            String(localized: "my_document_save_changes", defaultValue: "Save changes?"),
            isPresented: $showsDirtyDecision,
            titleVisibility: .visible
        ) {
            Button(String(localized: "save")) { saveAndContinue() }
            Button(String(localized: "no", defaultValue: "Don't Save"), role: .destructive) {
                discardAndContinue()
            }
            Button(String(localized: "cancel"), role: .cancel) {
                pendingOpenPage = nil
                pendingExitAfterDecision = false
            }
        }
        .confirmationDialog(
            String(
                format: String(
                    localized: "my_document_page_delete_confirmation",
                    defaultValue: "Delete %@?"
                ),
                pendingDeletePage?.title ?? ""
            ),
            isPresented: Binding(
                get: { pendingDeletePage != nil },
                set: { if !$0 { pendingDeletePage = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "delete"), role: .destructive) {
                deletePendingPage()
            }
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
        .accessibilityIdentifier("myDocumentPagesScreen")
    }

    @ToolbarContentBuilder
    private var pageToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                requestExit()
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel(String(localized: "cancel"))
        }
        ToolbarItemGroup(placement: .primaryAction) {
            #if os(iOS)
            EditButton()
            #endif
            Menu {
                Button {
                    editorRequest = MyDocumentPageEditorRequest(
                        pageID: nil,
                        title: String(
                            localized: "my_document_create_page_title",
                            defaultValue: "Create page"
                        ),
                        initialTitle: String(
                            format: String(
                                localized: "my_document_new_page_name",
                                defaultValue: "Page %d"
                            ),
                            pages.count + 1
                        ),
                        initialContentType: .markdown,
                        initialContent: ""
                    )
                } label: {
                    Label(
                        String(localized: "my_document_create_page_title", defaultValue: "New page"),
                        systemImage: "plus"
                    )
                }
                Button {
                    isImporting = true
                } label: {
                    Label(String(localized: "import"), systemImage: "square.and.arrow.down")
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(String(
                localized: "my_document_create_page_title",
                defaultValue: "New page"
            ))

            Button(String(localized: "save")) {
                if onSave() {
                    baselinePages = pages
                    dismiss()
                }
            }
            .disabled(!hasPageChanges)
        }
    }

    @ViewBuilder
    private func pageRow(_ page: MyDocumentPageDraft, document: MyDocumentDraft) -> some View {
        HStack(spacing: 12) {
            Button {
                requestOpen(page)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.title.isEmpty ? page.pageKey : page.title)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(page.contentType.rawValue)
                        if page.sourcePromptId != nil {
                            Image(systemName: "sparkles")
                                .accessibilityLabel("AI")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    editorRequest = MyDocumentPageEditorRequest(
                        pageID: page.id,
                        title: String(
                            localized: "my_document_page_rename_title",
                            defaultValue: "Edit page"
                        ),
                        initialTitle: page.title,
                        initialContentType: page.contentType,
                        initialContent: page.content
                    )
                } label: {
                    Label(String(localized: "rename"), systemImage: "pencil")
                }
                Button {
                    export(page, document: document)
                } label: {
                    Label(String(localized: "export"), systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    pendingDeletePage = page
                } label: {
                    Label(String(localized: "delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(String(localized: "system_items1", defaultValue: "More"))
        }
        .accessibilityIdentifier("myDocumentsPageRow::\(accessibilitySegment(document.initials))::\(accessibilitySegment(page.pageKey))")
        .accessibilityValue("pageKey=\(page.pageKey);contentType=\(page.contentType.rawValue)")
    }

    private func applyEditor(
        _ request: MyDocumentPageEditorRequest,
        title: String,
        contentType: MyDocumentContentType,
        content: String
    ) {
        do {
            if let pageID = request.pageID {
                try session.updatePage(
                    documentID: documentID,
                    pageID: pageID,
                    title: title,
                    contentType: contentType,
                    content: content
                )
            } else {
                let pageID = try session.createPage(
                    documentID: documentID,
                    title: title,
                    contentType: contentType
                )
                try session.updatePage(
                    documentID: documentID,
                    pageID: pageID,
                    title: title,
                    contentType: contentType,
                    content: content
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

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

    private func export(_ page: MyDocumentPageDraft, document: MyDocumentDraft) {
        do {
            exportURLs = try MyDocumentNativeFileTransfer.exportURLs(
                for: [MyDocumentTransferService.exportPage(page)],
                directoryName: document.name
            )
            showsExport = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deletePendingPage() {
        guard let page = pendingDeletePage else { return }
        pendingDeletePage = nil
        do {
            try session.deletePage(documentID: documentID, pageID: page.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requestOpen(_ page: MyDocumentPageDraft) {
        guard session.isDirty else {
            open(page)
            return
        }
        pendingOpenPage = page
        pendingExitAfterDecision = false
        showsDirtyDecision = true
    }

    private func requestExit() {
        guard hasPageChanges else {
            dismiss()
            return
        }
        pendingOpenPage = nil
        pendingExitAfterDecision = true
        showsDirtyDecision = true
    }

    private func saveAndContinue() {
        guard onSave() else { return }
        baselinePages = pages
        continuePendingAction()
    }

    private func discardAndContinue() {
        // The parent enters page management only from a clean session. Restoring that complete
        // baseline also resets the parent document timestamp changed by every page mutation.
        session.discardChanges()
        continuePendingAction()
    }

    private func continuePendingAction() {
        if pendingExitAfterDecision {
            pendingExitAfterDecision = false
            dismiss()
            return
        }
        if let pendingOpenPage {
            self.pendingOpenPage = nil
            if let persistedPage = pages.first(where: { $0.id == pendingOpenPage.id }) {
                open(persistedPage)
            }
        }
    }

    private func open(_ page: MyDocumentPageDraft) {
        guard let document else { return }
        onOpenPage(document.initials, page.pageKey)
    }

    private func accessibilitySegment(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}
