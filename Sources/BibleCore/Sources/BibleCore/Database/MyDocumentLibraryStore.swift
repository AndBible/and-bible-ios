// MyDocumentLibraryStore.swift -- Transactional My Documents management persistence

import Foundation
import SwiftData

/**
 Loads and transactionally commits value-based My Documents management sessions.

 The store is separate from `MyDocumentStore`, whose public surface is reader/bridge oriented. It
 computes the user's baseline-to-draft delta, applies that delta in one SwiftData save, and preserves
 rows or independent field updates written by sync or AI work after the session loaded. Explicit
 Cancel therefore remains side-effect free, while failed Save cannot publish a partial reorder or
 import.

 Each operation uses a fresh context from the supplied context's container. This keeps a My
 Documents Save or rollback from committing or discarding unrelated pending scene changes.
 */
@MainActor
public final class MyDocumentLibraryStore {
    private let modelContainer: ModelContainer

    public init(modelContext: ModelContext) {
        self.modelContainer = modelContext.container
    }

    /**
     Loads a clean management session from all persisted My Documents rows.

     - Returns: Value graph ordered by Android `orderNumber` fields with deterministic tie-breakers.
     - Side effects: Reads SwiftData only.
     - Failure modes: Propagates SwiftData fetch errors as `persistenceFailed`.
     */
    public func loadSession() throws -> MyDocumentManagementSession {
        let modelContext = ModelContext(modelContainer)
        do {
            let documents = try modelContext.fetch(FetchDescriptor<MyDocument>())
            return MyDocumentManagementSession(documents: documents.map(Self.draft(from:)))
        } catch {
            throw MyDocumentManagementError.persistenceFailed(error.localizedDescription)
        }
    }

    /**
     Applies the session delta atomically and marks it clean only after SwiftData saves.

     - Parameters:
       - session: Editable session to persist and advance to a clean baseline.
       - reservedInitials: Installed non-MyDocument module initials. New documents may not collide.
     - Side effects: Inserts, updates, and deletes only rows/fields changed from the session baseline,
       saves once, then refreshes the session to include concurrent rows.
     - Failure modes: Validation failures leave the context untouched; persistence failures roll the
       context back and preserve the session's dirty baseline.
     */
    public func save(
        _ session: inout MyDocumentManagementSession,
        reservedInitials: Set<String> = []
    ) throws {
        let modelContext = ModelContext(modelContainer)
        let drafts = session.documents
        let baseline = session.persistedBaseline
        let persistedDocuments: [MyDocument]
        let persistedPages: [MyDocumentPage]
        do {
            persistedDocuments = try modelContext.fetch(FetchDescriptor<MyDocument>())
            persistedPages = try modelContext.fetch(FetchDescriptor<MyDocumentPage>())
        } catch {
            throw MyDocumentManagementError.persistenceFailed(error.localizedDescription)
        }

        try validate(
            drafts,
            baseline: baseline,
            persistedDocuments: persistedDocuments,
            persistedPages: persistedPages,
            reservedInitials: reservedInitials
        )

        let persistedDocumentByID = dictionaryByID(persistedDocuments, id: \.id)
        let persistedPageByID = dictionaryByID(persistedPages, id: \.id)
        let baselineDocumentByID = dictionaryByID(baseline, id: \.id)
        let baselinePageByID = dictionaryByID(baseline.flatMap(\.pages), id: \.id)
        let draftDocumentIDs = Set(drafts.map(\.id))
        let draftPageIDs = Set(drafts.flatMap(\.pages).map(\.id))
        let deletedDocumentIDs = Set(baselineDocumentByID.keys).subtracting(draftDocumentIDs)
        let deletedPageIDs = Set(baselinePageByID.keys).subtracting(draftPageIDs)

        do {
            for document in persistedDocuments where deletedDocumentIDs.contains(document.id) {
                modelContext.delete(document)
            }

            for page in persistedPages
            where deletedPageIDs.contains(page.id)
                && page.document.map({ !deletedDocumentIDs.contains($0.id) }) != false {
                modelContext.delete(page)
            }

            for draft in drafts {
                let baselineDocument = baselineDocumentByID[draft.id]
                let document: MyDocument
                if let persistedDocument = persistedDocumentByID[draft.id] {
                    document = persistedDocument
                } else if baselineDocument == nil {
                    document = MyDocument(
                        id: draft.id,
                        name: draft.name,
                        documentDescription: draft.documentDescription,
                        initials: draft.initials,
                        orderNumber: draft.orderNumber,
                        createdAt: draft.createdAt,
                        updatedAt: draft.updatedAt,
                        sourcePromptId: draft.sourcePromptId
                    )
                    document.pages = []
                    modelContext.insert(document)
                } else {
                    // A concurrent deletion wins over stale edits, matching Android DAO updates.
                    continue
                }
                applyDocumentChanges(from: draft, baseline: baselineDocument, to: document)

                for pageDraft in draft.pages {
                    let baselinePage = baselinePageByID[pageDraft.id]
                    let page: MyDocumentPage
                    if let persistedPage = persistedPageByID[pageDraft.id] {
                        page = persistedPage
                    } else if baselinePage == nil {
                        page = MyDocumentPage(
                            id: pageDraft.id,
                            title: pageDraft.title,
                            pageKey: pageDraft.pageKey,
                            contentType: pageDraft.contentType,
                            orderNumber: pageDraft.orderNumber,
                            createdAt: pageDraft.createdAt,
                            updatedAt: pageDraft.updatedAt,
                            sourcePromptId: pageDraft.sourcePromptId,
                            languageCode: pageDraft.languageCode
                        )
                        page.document = document
                        document.pages = (document.pages ?? []) + [page]
                        modelContext.insert(page)
                    } else {
                        // Do not resurrect a page removed by a concurrent sync.
                        continue
                    }
                    applyPageChanges(
                        from: pageDraft,
                        baseline: baselinePage,
                        to: page,
                        parent: document,
                        modelContext: modelContext
                    )
                }
            }

            try RemoteSyncMutationJournalService.savePendingGraphChanges(
                for: .myDocuments,
                modelContext: modelContext
            )
            if let refreshedDocuments = try? modelContext.fetch(FetchDescriptor<MyDocument>()) {
                session = MyDocumentManagementSession(
                    documents: refreshedDocuments.map(Self.draft(from:))
                )
            } else {
                session.acceptSavedChanges()
            }
        } catch let error as MyDocumentManagementError {
            modelContext.rollback()
            throw error
        } catch {
            modelContext.rollback()
            throw MyDocumentManagementError.persistenceFailed(error.localizedDescription)
        }
    }

    private func validate(
        _ drafts: [MyDocumentDraft],
        baseline: [MyDocumentDraft],
        persistedDocuments: [MyDocument],
        persistedPages: [MyDocumentPage],
        reservedInitials: Set<String>
    ) throws {
        var seenInitials = Set<String>()
        let baselineDocumentIDs = Set(baseline.map(\.id))
        let draftDocumentIDs = Set(drafts.map(\.id))
        let deletedDocumentIDs = baselineDocumentIDs.subtracting(draftDocumentIDs)
        let baselinePageIDs = Set(baseline.flatMap(\.pages).map(\.id))
        let draftPageIDs = Set(drafts.flatMap(\.pages).map(\.id))
        let deletedPageIDs = baselinePageIDs.subtracting(draftPageIDs)
        for document in drafts {
            guard !document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MyDocumentManagementError.emptyDocumentName
            }
            guard seenInitials.insert(document.initials).inserted else {
                throw MyDocumentManagementError.duplicateInitials(document.initials)
            }
            if !baselineDocumentIDs.contains(document.id), reservedInitials.contains(document.initials) {
                throw MyDocumentManagementError.duplicateInitials(document.initials)
            }
            if persistedDocuments.contains(where: {
                $0.initials == document.initials
                    && $0.id != document.id
                    && !deletedDocumentIDs.contains($0.id)
            }) {
                throw MyDocumentManagementError.duplicateInitials(document.initials)
            }

            var pageKeys = Set<String>()
            for page in document.pages {
                guard !page.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MyDocumentManagementError.emptyPageTitle
                }
                guard pageKeys.insert(page.pageKey).inserted else {
                    throw MyDocumentManagementError.duplicatePageKey(
                        documentInitials: document.initials,
                        pageKey: page.pageKey
                    )
                }
                if persistedPages.contains(where: {
                    $0.document?.id == document.id
                        && $0.pageKey == page.pageKey
                        && $0.id != page.id
                        && !deletedPageIDs.contains($0.id)
                }) {
                    throw MyDocumentManagementError.duplicatePageKey(
                        documentInitials: document.initials,
                        pageKey: page.pageKey
                    )
                }
            }
        }

        if persistedDocuments.contains(where: {
            $0.initials == MyDocumentManagementSession.aiDocumentsInitials
                && deletedDocumentIDs.contains($0.id)
                && ($0.pages ?? []).isEmpty == false
        }) {
            throw MyDocumentManagementError.cannotDeleteNonemptyAIDocument
        }
    }

    private func applyDocumentChanges(
        from draft: MyDocumentDraft,
        baseline: MyDocumentDraft?,
        to document: MyDocument
    ) {
        if baseline == nil || baseline?.name != draft.name { document.name = draft.name }
        if baseline == nil || baseline?.documentDescription != draft.documentDescription {
            document.documentDescription = draft.documentDescription
        }
        if baseline == nil || baseline?.initials != draft.initials { document.initials = draft.initials }
        if baseline == nil || baseline?.orderNumber != draft.orderNumber {
            document.orderNumber = draft.orderNumber
        }
        if baseline == nil || baseline?.createdAt != draft.createdAt { document.createdAt = draft.createdAt }
        if baseline == nil || baseline?.updatedAt != draft.updatedAt { document.updatedAt = draft.updatedAt }
        if baseline == nil || baseline?.sourcePromptId != draft.sourcePromptId {
            document.sourcePromptId = draft.sourcePromptId
        }
    }

    private func applyPageChanges(
        from draft: MyDocumentPageDraft,
        baseline: MyDocumentPageDraft?,
        to page: MyDocumentPage,
        parent document: MyDocument,
        modelContext: ModelContext
    ) {
        page.document = document
        if baseline == nil || baseline?.title != draft.title { page.title = draft.title }
        if baseline == nil || baseline?.pageKey != draft.pageKey { page.pageKey = draft.pageKey }
        if baseline == nil || baseline?.contentType != draft.contentType { page.contentType = draft.contentType }
        if baseline == nil || baseline?.orderNumber != draft.orderNumber { page.orderNumber = draft.orderNumber }
        if baseline == nil || baseline?.createdAt != draft.createdAt { page.createdAt = draft.createdAt }
        if baseline == nil || baseline?.updatedAt != draft.updatedAt { page.updatedAt = draft.updatedAt }
        if baseline == nil || baseline?.sourcePromptId != draft.sourcePromptId {
            page.sourcePromptId = draft.sourcePromptId
        }
        if baseline == nil || baseline?.languageCode != draft.languageCode {
            page.languageCode = draft.languageCode
        }

        if baseline == nil || baseline?.content != draft.content {
            if let pageContent = page.pageContent {
                pageContent.content = draft.content
            } else {
                let pageContent = MyDocumentPageContent(pageId: page.id, content: draft.content)
                pageContent.page = page
                page.pageContent = pageContent
                modelContext.insert(pageContent)
            }
        }
    }

    private func dictionaryByID<Element, ID: Hashable>(
        _ values: [Element],
        id: KeyPath<Element, ID>
    ) -> [ID: Element] {
        Dictionary(values.map { ($0[keyPath: id], $0) }, uniquingKeysWith: { current, _ in current })
    }

    private static func draft(from document: MyDocument) -> MyDocumentDraft {
        MyDocumentDraft(
            id: document.id,
            name: document.name,
            documentDescription: document.documentDescription,
            initials: document.initials,
            orderNumber: document.orderNumber,
            createdAt: document.createdAt,
            updatedAt: document.updatedAt,
            sourcePromptId: document.sourcePromptId,
            pages: (document.pages ?? []).map { page in
                MyDocumentPageDraft(
                    id: page.id,
                    title: page.title,
                    pageKey: page.pageKey,
                    contentType: page.contentType,
                    orderNumber: page.orderNumber,
                    createdAt: page.createdAt,
                    updatedAt: page.updatedAt,
                    sourcePromptId: page.sourcePromptId,
                    languageCode: page.languageCode,
                    content: page.pageContent?.content ?? ""
                )
            }
        )
    }
}
