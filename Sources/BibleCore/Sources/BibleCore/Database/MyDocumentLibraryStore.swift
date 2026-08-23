// MyDocumentLibraryStore.swift -- Transactional My Documents management persistence

import Foundation
import SwiftData
import SwordKit

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
    /** Exact effective registry identity of one admitted My Documents owner. */
    private struct RegistrationOwnerFingerprint: Equatable {
        /// Stable row identity distinguishes an unchanged owner from a replacement owner.
        let id: UUID

        /// Java-exact initials used by the first `Books.getBook` tier.
        let initials: SwordJavaExactStringIdentity

        /// Java-trimmed, exact full name used by the second lookup tier.
        let fullName: SwordJavaExactStringIdentity
    }

    private let modelContainer: ModelContainer
    /// Process-wide identity-publication lease shared by native, SQLite, EPUB, and My Documents.
    private let mutationCoordinator: ModuleStoreMutationCoordinator

    /**
     Creates a management store that publishes identity changes through the global book gate.

     - Parameters:
       - modelContext: Context whose container owns the persisted My Documents graph.
       - moduleStoreRootURL: Canonical SWORD root shared with native, SQLite, and EPUB writers.
     - Side effects: Retains dependencies and resolves the process-wide coordinator; no fetch or
       persistence occurs during initialization.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        modelContext: ModelContext,
        moduleStoreRootURL: URL = URL(
            fileURLWithPath: SwordManager.defaultModulePath(),
            isDirectory: true
        )
    ) {
        self.modelContainer = modelContext.container
        self.mutationCoordinator = ModuleStoreMutationCoordinator.shared(
            forModuleRoot: moduleStoreRootURL
        )
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
       - reservedInitials: Legacy installed identities compared with Java-exact UTF-16 semantics.
       - isInitialsUnavailable: Optional live JSword registry predicate rechecked for newly inserted
         documents immediately before persistence.
     - Side effects: Inserts, updates, and deletes only rows/fields changed from the session baseline,
       saves once, then refreshes the session to include concurrent rows. The coordinator lease is
       held from the fresh persisted-state fetch through validation, save, and rollback.
     - Failure modes: Validation failures leave the context untouched; persistence failures roll the
       context back and preserve the session's dirty baseline.
     - Important: The global module-store coordinator is acquired before any registry callback may
       take the recursive EPUB library lock, preserving the process-wide lock order.
     */
    public func save(
        _ session: inout MyDocumentManagementSession,
        reservedInitials: Set<String> = [],
        isInitialsUnavailable: ((String) -> Bool)? = nil
    ) throws {
        try saveWithExclusiveRegistryAdmission(
            &session,
            reservedInitials: reservedInitials,
            isInitialsUnavailable: { initials in
                isInitialsUnavailable?(initials) ?? false
            }
        )
    }

    /**
     Applies a session delta after one throwing live-registry check under the global lease.

     Production identity publishers use this overload so corrupt or unreadable native/local
     registry state aborts the save instead of being converted into an apparently available token.

     - Parameters:
       - session: Editable session to persist and advance only after successful publication.
       - reservedInitials: Legacy installed identities compared with Java-exact semantics.
       - registryInitialsUnavailable: Fresh complete-registry lookup invoked for every new document
         while the canonical module-store lease is held.
     - Side effects: Performs the same isolated SwiftData delta save as the compatibility overload.
     - Throws: Registry snapshot, validation, journaling, or persistence failures without committing
       any part of the candidate graph.
     */
    public func save(
        _ session: inout MyDocumentManagementSession,
        reservedInitials: Set<String> = [],
        checkingInitialsWith registryInitialsUnavailable: (String) throws -> Bool
    ) throws {
        try saveWithExclusiveRegistryAdmission(
            &session,
            reservedInitials: reservedInitials,
            isInitialsUnavailable: registryInitialsUnavailable
        )
    }

    /** Acquires the canonical lease before invoking any fresh registry or EPUB-lock callback. */
    private func saveWithExclusiveRegistryAdmission(
        _ session: inout MyDocumentManagementSession,
        reservedInitials: Set<String>,
        isInitialsUnavailable: (String) throws -> Bool
    ) throws {
        try mutationCoordinator.withExclusiveTransaction(
            kind: .myDocument,
            prepare: { () },
            commit: { _ in
                try saveUnderExclusiveLease(
                    &session,
                    reservedInitials: reservedInitials,
                    isInitialsUnavailable: isInitialsUnavailable
                )
            }
        )
    }

    /**
     Performs one fresh-state validation and atomic SwiftData save under an existing global lease.

     - Parameters:
       - session: Editable management graph whose baseline-to-draft delta is published.
       - reservedInitials: Legacy native/local identities compared with Java-exact semantics.
       - isInitialsUnavailable: Optional complete-registry lookup evaluated for each inserted row.
     - Side effects: Fetches a fresh isolated context, applies only the session delta, writes the
       remote-sync mutation journal and SwiftData graph once, then advances the saved baseline.
     - Throws: Validation and persistence failures after rolling back the isolated context; the
       caller-owned session remains dirty when publication does not complete.
     - Important: The caller must already own `mutationCoordinator` for this store's SWORD root.
     */
    private func saveUnderExclusiveLease(
        _ session: inout MyDocumentManagementSession,
        reservedInitials: Set<String>,
        isInitialsUnavailable: (String) throws -> Bool
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
            reservedInitials: reservedInitials,
            isInitialsUnavailable: isInitialsUnavailable
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
        reservedInitials: Set<String>,
        isInitialsUnavailable: (String) throws -> Bool
    ) throws {
        var admittedDrafts: [MyDocumentDraft] = []
        let baselineDocumentByID = Dictionary(
            uniqueKeysWithValues: baseline.map { ($0.id, $0) }
        )
        let baselineSuppressionOwners = Self.suppressionOwners(in: baseline)
        let baselineDocumentIDs = Set(baseline.map(\.id))
        let draftDocumentIDs = Set(drafts.map(\.id))
        let deletedDocumentIDs = baselineDocumentIDs.subtracting(draftDocumentIDs)
        let baselinePageIDs = Set(baseline.flatMap(\.pages).map(\.id))
        let draftPageIDs = Set(drafts.flatMap(\.pages).map(\.id))
        let deletedPageIDs = baselinePageIDs.subtracting(draftPageIDs)
        let livePersistedDrafts = MyDocumentManagementSession(
            documents: persistedDocuments.compactMap { persisted -> MyDocumentDraft? in
                guard !deletedDocumentIDs.contains(persisted.id) else { return nil }
                return MyDocumentDraft(
                    id: persisted.id,
                    name: persisted.name,
                    initials: persisted.initials,
                    orderNumber: persisted.orderNumber
                )
            }
        ).documents
        for document in drafts {
            guard !document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MyDocumentManagementError.emptyDocumentName
            }
            if let currentOwner = Self.registrationOwner(
                of: document.initials,
                in: admittedDrafts
            ) {
                let currentFingerprint = Self.registrationFingerprint(for: currentOwner)
                let unchangedSuppressedBaseline = baselineDocumentByID[document.id].map {
                    Self.hasSameRegistrationIdentity($0, document)
                } == true
                    && baselineSuppressionOwners[document.id] == currentFingerprint
                guard unchangedSuppressedBaseline else {
                    throw MyDocumentManagementError.duplicateInitials(document.initials)
                }
                // Authoritative restore may retain Android rows hidden by an earlier owner. An
                // unrelated edit keeps that exact baseline omission; it must not make the row new.
            } else {
                admittedDrafts.append(document)
            }
            if !baselineDocumentIDs.contains(document.id) {
                let isReserved = reservedInitials.contains {
                    SwordJavaStringIdentity.equals($0, document.initials)
                }
                if isReserved {
                    throw MyDocumentManagementError.duplicateInitials(document.initials)
                }
                if try isInitialsUnavailable(document.initials) {
                    throw MyDocumentManagementError.duplicateInitials(document.initials)
                }
            }
            if !baselineDocumentIDs.contains(document.id),
               MyDocumentManagementSession.pendingDocumentsOwnInitials(
                   document.initials,
                   documents: livePersistedDrafts
               ) {
                throw MyDocumentManagementError.duplicateInitials(document.initials)
            }

            var pageKeys = Set<SwordJavaExactStringIdentity>()
            for page in document.pages {
                guard !page.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MyDocumentManagementError.emptyPageTitle
                }
                let exactPageKey = SwordJavaExactStringIdentity(page.pageKey)
                guard pageKeys.insert(exactPageKey).inserted else {
                    throw MyDocumentManagementError.duplicatePageKey(
                        documentInitials: document.initials,
                        pageKey: page.pageKey
                    )
                }
                if persistedPages.contains(where: {
                    $0.document?.id == document.id
                        && SwordJavaStringIdentity.equals($0.pageKey, page.pageKey)
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

    /**
     Replays Android registration and records the exact owner suppressing each retained draft.

     - Parameter documents: Baseline drafts in registration order.
     - Returns: Suppressed document IDs mapped to the admitted owner's exact effective identity.
     - Side effects: Loads the pinned Android case table on first case-insensitive comparison.
     - Failure modes: Traps only when the bundled Android compatibility table is missing/corrupt.
     */
    private static func suppressionOwners(
        in documents: [MyDocumentDraft]
    ) -> [UUID: RegistrationOwnerFingerprint] {
        var admitted: [MyDocumentDraft] = []
        var result: [UUID: RegistrationOwnerFingerprint] = [:]
        for document in documents {
            if let owner = registrationOwner(of: document.initials, in: admitted) {
                result[document.id] = registrationFingerprint(for: owner)
            } else {
                admitted.append(document)
            }
        }
        return result
    }

    /**
     Resolves one candidate against admitted My Documents using JSword lookup tier order.

     - Parameters:
       - candidate: Candidate initials passed to `Books.getBook`.
       - documents: Earlier drafts that survived sequential registration.
     - Returns: Exact initials owner, last exact full-name owner, or first case-insensitive owner.
     - Side effects: Loads the pinned Android case table for the final lookup tier.
     - Failure modes: Traps only when the bundled Android compatibility table is missing/corrupt.
     */
    private static func registrationOwner(
        of candidate: String,
        in documents: [MyDocumentDraft]
    ) -> MyDocumentDraft? {
        if let owner = documents.first(where: {
            SwordJavaStringIdentity.equals($0.initials, candidate)
        }) {
            return owner
        }
        if let owner = documents.last(where: {
            SwordJavaStringIdentity.equals(SwordJavaStringIdentity.trim($0.name), candidate)
        }) {
            return owner
        }
        return documents.first(where: {
            SwordJavaStringIdentity.equalsIgnoreCase($0.initials, candidate)
                || SwordJavaStringIdentity.equalsIgnoreCase(
                    SwordJavaStringIdentity.trim($0.name),
                    candidate
                )
        })
    }

    /** Returns the Java-exact initials/full-name identity that participates in registration. */
    private static func registrationFingerprint(
        for document: MyDocumentDraft
    ) -> RegistrationOwnerFingerprint {
        RegistrationOwnerFingerprint(
            id: document.id,
            initials: SwordJavaExactStringIdentity(document.initials),
            fullName: SwordJavaExactStringIdentity(SwordJavaStringIdentity.trim(document.name))
        )
    }

    /** Whether an edited row preserves the same Java-effective registration identity. */
    private static func hasSameRegistrationIdentity(
        _ lhs: MyDocumentDraft,
        _ rhs: MyDocumentDraft
    ) -> Bool {
        SwordJavaStringIdentity.equals(lhs.initials, rhs.initials)
            && SwordJavaStringIdentity.equals(
                SwordJavaStringIdentity.trim(lhs.name),
                SwordJavaStringIdentity.trim(rhs.name)
            )
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
        if baseline == nil
            || !SwordJavaStringIdentity.equals(baseline?.initials ?? "", draft.initials) {
            document.initials = draft.initials
        }
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
        if baseline == nil
            || !SwordJavaStringIdentity.equals(baseline?.pageKey ?? "", draft.pageKey) {
            page.pageKey = draft.pageKey
        }
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
