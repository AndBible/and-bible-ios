// MyDocumentStore.swift -- Local My Documents persistence operations

import Foundation
import SwiftData

/**
 Raw page content payload returned to the WebView bridge.

 The encoded key names match Android's `PageRawContent` serializer output.
 */
public struct MyDocumentRawContentPayload: Codable, Equatable, Sendable {
    public let pageId: String
    public let contentType: String
    public let content: String
    public let title: String
    public let sourcePromptId: String?

    public init(
        pageId: String,
        contentType: String,
        content: String,
        title: String,
        sourcePromptId: String?
    ) {
        self.pageId = pageId
        self.contentType = contentType
        self.content = content
        self.title = title
        self.sourcePromptId = sourcePromptId
    }
}

/**
 Native context for source-prompt-backed My Documents page actions.

 iOS does not yet own the shared AI regeneration dialog, so the reader bridge
 passes this validated context to its native callback instead of regenerating
 directly in the persistence layer.
 */
public struct MyDocumentAIPageActionContext: Equatable, Sendable {
    public let pageId: UUID
    public let documentId: UUID
    public let bookInitials: String
    public let documentName: String
    public let pageKey: String
    public let pageTitle: String
    public let sourcePromptId: UUID
    public let sourceContext: String?
    public let kjvOrdinalStart: Int?
    public let kjvOrdinalEnd: Int?
    public let contextHash: String?
    public let usedWriteTools: Bool
    public let sourceModelName: String?
    public let sourceBookInitials: String?
    public let sourceBookKey: String?
}

/**
 Result of attempting to delete one source-prompt-backed My Documents page.
 */
public enum MyDocumentAIPageDeletionResult: Equatable, Sendable {
    case deleted(MyDocumentAIPageActionContext)
    case notAIPage
    case pageNotFound
    case saveFailed
}

/**
 Fail-closed errors from exact My Documents identity lookups.

 Compatibility readers may continue using the optional first-match APIs below. Bookmark navigation
 uses these typed failures so duplicate Android identities cannot be mistaken for one authoritative
 document or page.
 */
public enum MyDocumentExactLookupError: Error, Equatable, LocalizedError, Sendable {
    /// The supplied document initials are empty after whitespace normalization.
    case invalidDocumentInitials

    /// No document owns the exact supplied initials.
    case documentNotFound(initials: String)

    /// More than one document owns the exact supplied initials.
    case duplicateDocuments(initials: String)

    /// The document query could not be completed by SwiftData.
    case documentReadFailed(initials: String)

    /// No page owns the exact parent-scoped key.
    case pageNotFound(bookInitials: String, pageKey: String)

    /// More than one page owns the exact parent-scoped key.
    case duplicatePages(bookInitials: String, pageKey: String)

    /// The page query could not be completed by SwiftData.
    case pageReadFailed(bookInitials: String, pageKey: String)

    /**
     Returns a localized user-facing explanation without exposing persistence internals.

     - Returns: Existing Android-localized module/content messages where they describe the failure,
       otherwise the shared generic error text.
     - Side effects: Reads localized string resources only.
     - Failure modes: None; every current case has a fallback value.
     */
    public var errorDescription: String? {
        switch self {
        case .documentNotFound:
            return String(localized: "error_module_not_found", defaultValue: "Module not found")
        case .pageNotFound:
            return String(localized: "error_no_content", defaultValue: "No content for selected verse")
        case .invalidDocumentInitials,
             .duplicateDocuments,
             .documentReadFailed,
             .duplicatePages,
             .pageReadFailed:
            return String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }
}

/**
 Low-level persistence API for My Documents pages and raw content.

 This store deliberately resolves pages by Android-compatible `(initials,
 pageKey)` pairs because those values are what the WebView bridge receives.

 - Important: This store inherits the thread/actor confinement of the supplied
   `ModelContext`.
 */
public final class MyDocumentStore {
    /// SwiftData context supplied by the owning UI/app actor.
    private let modelContext: ModelContext

    /// Synchronous save operation used by editable page writes.
    private let savePageContentChanges: () throws -> Void

    /// App-owned channel that propagates committed AI marker changes to every open reader pane.
    private let aiDocMarkerEventCenter: MyDocumentAIDocMarkerEventCenter

    /**
     Creates a My Documents store for the supplied SwiftData context.

     - Parameters:
       - modelContext: SwiftData context whose lifetime and actor confinement remain caller-owned.
       - aiDocMarkerEventCenter: Typed app event channel shared by open reader controllers.
     - Side effects: Stores dependencies only; no fetch, save, or event publication occurs.
     - Failure modes: None during initialization.
     */
    public init(
        modelContext: ModelContext,
        aiDocMarkerEventCenter: MyDocumentAIDocMarkerEventCenter = .shared
    ) {
        self.modelContext = modelContext
        self.aiDocMarkerEventCenter = aiDocMarkerEventCenter
        self.savePageContentChanges = {
            try RemoteSyncMutationJournalService.savePendingGraphChanges(
                for: .myDocuments,
                modelContext: modelContext
            )
        }
    }

    /**
     Creates a store with an injectable page-content save boundary for deterministic failure tests.

     - Parameters:
       - modelContext: SwiftData context containing the My Documents graph.
       - savePageContentChanges: Synchronous operation that persists pending page-content changes;
         production callers use `ModelContext.save()` through the public initializer.
       - aiDocMarkerEventCenter: Typed app event channel shared by open reader controllers.
     - Side effects: Stores references only; no fetch or save occurs during initialization.
     - Failure modes: Errors thrown by `savePageContentChanges` are handled by
       `savePageContent(bookInitials:pageId:content:title:)`.
     - Important: The closure must obey the supplied context's actor/thread confinement.
     */
    init(
        modelContext: ModelContext,
        savePageContentChanges: @escaping () throws -> Void,
        aiDocMarkerEventCenter: MyDocumentAIDocMarkerEventCenter = .shared
    ) {
        self.modelContext = modelContext
        self.savePageContentChanges = savePageContentChanges
        self.aiDocMarkerEventCenter = aiDocMarkerEventCenter
    }

    /**
     Fetches one document by its stable bridge initials.
     */
    public func document(initials: String) -> MyDocument? {
        var descriptor = FetchDescriptor<MyDocument>(
            predicate: #Predicate { $0.initials == initials },
            sortBy: [
                SortDescriptor(\.createdAt),
                SortDescriptor(\.updatedAt),
                SortDescriptor(\.name),
            ]
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /**
     Lists My Documents in Android registration order for global book identity resolution.

     - Returns: Persisted documents ordered by `orderNumber` with deterministic metadata tie-breakers.
     - Side effects: Reads document rows from the supplied SwiftData context without saving.
     - Throws: Re-throws SwiftData metadata fetch failures so callers fail the combined local
       registry closed instead of substituting an EPUB or another document.
     - Important: This method does not access page content. Registration consumers must resolve an
       owner before calling `page(bookInitials:pageKey:)` or another content API.
     */
    public func documentsInRegistrationOrder() throws -> [MyDocument] {
        let descriptor = FetchDescriptor<MyDocument>(
            sortBy: [
                SortDescriptor(\.orderNumber),
                SortDescriptor(\.createdAt),
                SortDescriptor(\.name),
                SortDescriptor(\.initials),
            ]
        )
        return try modelContext.fetch(descriptor)
    }

    /**
     Resolves exactly one document by its byte-exact Android bridge initials.

     Unlike `document(initials:)`, this lookup does not sort and select one row when persisted
     identity is ambiguous. Fetching at most two rows is sufficient to distinguish a unique match
     from every duplicate state without loading an unbounded corrupted result set.

     - Parameter initials: Non-empty document initials; matching is case-sensitive and untrimmed.
     - Returns: The only document with the supplied initials.
     - Side effects: Reads the supplied SwiftData context without saving or mutating models.
     - Throws: `MyDocumentExactLookupError` for invalid input, no match, duplicate matches, or a
       SwiftData read failure.
     - Important: The call inherits the supplied context's actor/thread confinement.
     */
    public func exactDocument(initials: String) throws -> MyDocument {
        guard !initials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MyDocumentExactLookupError.invalidDocumentInitials
        }
        var descriptor = FetchDescriptor<MyDocument>(
            predicate: #Predicate { $0.initials == initials }
        )
        descriptor.fetchLimit = 2

        let matches: [MyDocument]
        do {
            matches = try modelContext.fetch(descriptor)
        } catch {
            throw MyDocumentExactLookupError.documentReadFailed(initials: initials)
        }
        guard let match = matches.first else {
            throw MyDocumentExactLookupError.documentNotFound(initials: initials)
        }
        guard matches.count == 1 else {
            throw MyDocumentExactLookupError.duplicateDocuments(initials: initials)
        }
        return match
    }

    /**
     Resolves one page by the Android-compatible document initials and page key.
     */
    public func page(bookInitials: String, pageKey: String) -> MyDocumentPage? {
        var descriptor = FetchDescriptor<MyDocumentPage>(
            predicate: #Predicate {
                $0.pageKey == pageKey && $0.document?.initials == bookInitials
            },
            sortBy: [
                SortDescriptor(\.orderNumber),
                SortDescriptor(\.createdAt),
                SortDescriptor(\.updatedAt),
                SortDescriptor(\.title),
            ]
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /**
     Resolves exactly one page under exactly one My Documents identity.

     Document uniqueness is validated before page lookup, then the page query is scoped by the
     resolved document UUID and byte-exact page key. This prevents a duplicate document identity or
     duplicate sibling key from being hidden by the compatibility API's `fetchLimit = 1` behavior.

     - Parameters:
       - bookInitials: Non-empty exact parent document initials.
       - pageKey: Exact parent-scoped persisted page key; empty keys are looked up literally.
     - Returns: The only matching page.
     - Side effects: Reads the supplied SwiftData context without saving or mutating models.
     - Throws: `MyDocumentExactLookupError` for invalid/missing/duplicate document identity,
       missing/duplicate page identity, or a SwiftData read failure.
     - Important: The call inherits the supplied context's actor/thread confinement.
     */
    public func exactPage(bookInitials: String, pageKey: String) throws -> MyDocumentPage {
        let document = try exactDocument(initials: bookInitials)
        let documentID = document.id
        var descriptor = FetchDescriptor<MyDocumentPage>(
            predicate: #Predicate {
                $0.pageKey == pageKey && $0.document?.id == documentID
            }
        )
        descriptor.fetchLimit = 2

        let matches: [MyDocumentPage]
        do {
            matches = try modelContext.fetch(descriptor)
        } catch {
            throw MyDocumentExactLookupError.pageReadFailed(
                bookInitials: bookInitials,
                pageKey: pageKey
            )
        }
        guard let match = matches.first else {
            throw MyDocumentExactLookupError.pageNotFound(
                bookInitials: bookInitials,
                pageKey: pageKey
            )
        }
        guard matches.count == 1 else {
            throw MyDocumentExactLookupError.duplicatePages(
                bookInitials: bookInitials,
                pageKey: pageKey
            )
        }
        return match
    }

    /**
     Resolves one page by its stable page identifier and parent document initials.
     */
    public func page(bookInitials: String, pageId: UUID) -> MyDocumentPage? {
        var descriptor = FetchDescriptor<MyDocumentPage>(
            predicate: #Predicate {
                $0.id == pageId && $0.document?.initials == bookInitials
            }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /**
     Resolves one page by its stable page identifier without requiring the
     parent document initials.
     */
    public func page(pageId: UUID) -> MyDocumentPage? {
        var descriptor = FetchDescriptor<MyDocumentPage>(
            predicate: #Predicate { $0.id == pageId }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /**
     Builds the raw-content bridge payload for one page.
     */
    public func rawContentPayload(bookInitials: String, pageKey: String) -> MyDocumentRawContentPayload? {
        guard let page = page(bookInitials: bookInitials, pageKey: pageKey) else {
            return nil
        }

        return MyDocumentRawContentPayload(
            pageId: page.id.uuidString,
            contentType: page.contentType.rawValue,
            content: page.pageContent?.content ?? "",
            title: page.title,
            sourcePromptId: page.sourcePromptId?.uuidString
        )
    }

    /**
     Returns only the stored raw content for copy/share workflows.
     */
    public func rawContent(bookInitials: String, pageKey: String) -> String? {
        rawContentPayload(bookInitials: bookInitials, pageKey: pageKey)?.content
    }

    /**
     Projects Android's prompt/model footer and source-page AI marker metadata for one page.

     - Parameters:
       - page: Resolved page being rendered.
       - bookInitials: Parent document initials used by Android's source-page marker query.
       - pageKey: Parent-scoped key used by Android's source-page marker query.
       - unknownPromptName: Localized fallback used when a prompt ID no longer resolves.
       - promptName: Optional prompt catalog lookup. iOS currently supplies no prompt catalog and
         therefore uses Android's localized unknown-prompt fallback.
     - Returns: Deterministically ordered metadata matching `CurrentPageBase` and
       `AiDocMarkerInfo`.
     - Side effects: Reads SwiftData only.
     - Failure modes: Marker fetch failures degrade to an empty marker list; page metadata remains.
     */
    public func readerMetadata(
        for page: MyDocumentPage,
        bookInitials: String,
        pageKey: String,
        unknownPromptName: String,
        promptName: ((UUID) -> String?)? = nil
    ) -> MyDocumentReaderMetadata {
        let sourcePromptId = page.sourcePromptId
        let cacheEntry = sourcePromptId == nil
            ? nil
            : page.aiPageCacheEntries?.sorted {
                $0.id.uuidString < $1.id.uuidString
            }.first
        let resolvedPromptName = sourcePromptId.map {
            promptName?($0) ?? unknownPromptName
        }

        return MyDocumentReaderMetadata(
            sourcePromptId: sourcePromptId,
            sourcePromptName: resolvedPromptName,
            sourceModelName: cacheEntry?.sourceModelName,
            aiDocMarkers: aiDocMarkers(bookInitials: bookInitials, pageKey: pageKey)
        )
    }

    /**
     Projects generated-page markers attached to one exact Android document identity.

     - Parameters:
       - bookInitials: Source document initials stored by `AiPageCacheEntry`.
       - pageKey: Exact source key stored by `AiPageCacheEntry`.
     - Returns: Deterministically ordered markers whose generated page and document still exist.
     - Side effects: Reads SwiftData only.
     - Failure modes: Fetch failures and dangling generated-page relationships return an empty or
       filtered marker list; no nearest-key or module-only fallback is attempted.
     */
    public func aiDocMarkers(bookInitials: String, pageKey: String) -> [MyDocumentAIDocMarker] {
        let sourceInitials = bookInitials
        let sourceKey = pageKey
        let descriptor = FetchDescriptor<AiPageCacheEntry>(
            predicate: #Predicate {
                $0.sourceBookInitials == sourceInitials && $0.sourceBookKey == sourceKey
            }
        )
        let entries: [AiPageCacheEntry] = (try? modelContext.fetch(descriptor)) ?? []
        return projectedAIDocMarkers(entries)
    }

    /**
     Projects generated-page markers whose authoritative KJVA source range overlaps a Bible range.

     - Parameter range: Inclusive KJVA range for the rendered Bible document.
     - Returns: Deterministically ordered generated-page markers with overlapping stored ranges.
     - Side effects: Reads SwiftData only.
     - Failure modes: Fetch failures, nil source ranges, and dangling page/document relationships are
       omitted; source initials and keys do not constrain Bible marker visibility.
     */
    public func aiDocMarkers(kjvaRange range: ClosedRange<Int>) -> [MyDocumentAIDocMarker] {
        let descriptor = FetchDescriptor<AiPageCacheEntry>()
        let entries: [AiPageCacheEntry] = (try? modelContext.fetch(descriptor)) ?? []
        return projectedAIDocMarkers(entries.filter { entry in
            guard let start = entry.kjvOrdinalStart,
                  let end = entry.kjvOrdinalEnd else {
                return false
            }
            return start <= range.upperBound && end >= range.lowerBound
        })
    }

    /**
     Converts cache rows into the shared marker DTO while filtering dangling relationships.

     - Parameter entries: Cache rows already selected by exact-page or KJVA-range semantics.
     - Returns: Marker DTOs ordered by localized page title and stable page UUID.
     - Side effects: Reads row relationships already loaded by SwiftData.
     - Failure modes: Rows without a generated page or parent document are omitted.
     */
    private func projectedAIDocMarkers(
        _ entries: [AiPageCacheEntry]
    ) -> [MyDocumentAIDocMarker] {
        entries.compactMap { entry -> MyDocumentAIDocMarker? in
            guard let markerPage = entry.page,
                  let markerDocument = markerPage.document else {
                return nil
            }
            return MyDocumentAIDocMarker(
                pageId: markerPage.id,
                documentId: markerDocument.id,
                documentInitials: markerDocument.initials,
                pageTitle: markerPage.title,
                pageKey: markerPage.pageKey,
                kjvOrdinalStart: entry.kjvOrdinalStart,
                kjvOrdinalEnd: entry.kjvOrdinalEnd,
                sourcePromptId: entry.sourcePromptId,
                sourceBookInitials: entry.sourceBookInitials,
                sourceBookKey: entry.sourceBookKey
            )
        }.sorted { lhs, rhs in
            if lhs.pageTitle != rhs.pageTitle {
                return lhs.pageTitle.localizedCaseInsensitiveCompare(rhs.pageTitle) == .orderedAscending
            }
            return lhs.pageId.uuidString < rhs.pageId.uuidString
        }
    }

    /**
     Builds the native action context for an AI-generated My Documents page.

     A page must carry source prompt metadata either directly or through its AI
     cache row. User-authored pages intentionally return `nil`.
     */
    public func aiPageActionContext(pageId: UUID) -> MyDocumentAIPageActionContext? {
        guard let page = page(pageId: pageId) else {
            return nil
        }

        return aiPageActionContext(page: page)
    }

    private func aiPageActionContext(page: MyDocumentPage) -> MyDocumentAIPageActionContext? {
        guard let document = page.document else {
            return nil
        }

        let cacheEntry = page.aiPageCacheEntries?.first
        guard let sourcePromptId = page.sourcePromptId ?? cacheEntry?.sourcePromptId else {
            return nil
        }

        return MyDocumentAIPageActionContext(
            pageId: page.id,
            documentId: document.id,
            bookInitials: document.initials,
            documentName: document.name,
            pageKey: page.pageKey,
            pageTitle: page.title,
            sourcePromptId: sourcePromptId,
            sourceContext: cacheEntry?.sourceContext,
            kjvOrdinalStart: cacheEntry?.kjvOrdinalStart,
            kjvOrdinalEnd: cacheEntry?.kjvOrdinalEnd,
            contextHash: cacheEntry?.contextHash,
            usedWriteTools: cacheEntry?.usedWriteTools ?? false,
            sourceModelName: cacheEntry?.sourceModelName,
            sourceBookInitials: cacheEntry?.sourceBookInitials,
            sourceBookKey: cacheEntry?.sourceBookKey
        )
    }

    /**
     Deletes one AI-generated My Documents page and its cascaded content/cache.

     User-authored pages are refused so the Android action-menu gate stays
     sourcePromptId-driven on iOS too.
     */
    @discardableResult
    public func deleteAIPage(pageId: UUID) -> MyDocumentAIPageDeletionResult {
        guard let page = page(pageId: pageId) else {
            return .pageNotFound
        }

        guard let context = aiPageActionContext(page: page) else {
            return .notAIPage
        }

        let now = Date()
        if let document = page.document {
            document.updatedAt = now
        }

        modelContext.delete(page)

        do {
            try RemoteSyncMutationJournalService.savePendingGraphChanges(
                for: .myDocuments,
                modelContext: modelContext
            )
            aiDocMarkerEventCenter.post(
                MyDocumentAIDocMarkersChangedEvent(deletedPageIDs: [context.pageId])
            )
            return .deleted(context)
        } catch {
            modelContext.rollback()
            return .saveFailed
        }
    }

    /**
     Persists raw editable content for one My Documents page.

     - Parameters:
       - bookInitials: Parent document initials supplied by the bridge.
       - pageId: Stable page UUID supplied by the editor payload.
       - content: Replacement raw page body.
       - title: Optional replacement page title; `nil` preserves the current title.
     - Returns: `true` when a matching page was found and saved.
     - Side effects: Mutates the matching page, its parent document timestamp, and its content row,
       then saves the supplied `ModelContext` synchronously.
     - Failure modes: Returns `false` when the page cannot be resolved or persistence fails. A save
       failure restores only the page graph fields changed by this call and removes any content row
       this call inserted, leaving unrelated pending context changes intact.
     - Important: The operation inherits the supplied context's actor/thread confinement.
     */
    @discardableResult
    public func savePageContent(
        bookInitials: String,
        pageId: UUID,
        content: String,
        title: String?
    ) -> Bool {
        guard let page = page(bookInitials: bookInitials, pageId: pageId) else {
            return false
        }

        let originalTitle = page.title
        let originalPageUpdatedAt = page.updatedAt
        let document = page.document
        let originalDocumentUpdatedAt = document?.updatedAt
        let originalPageContent = page.pageContent
        let originalContent = originalPageContent?.content
        var insertedPageContent: MyDocumentPageContent?

        let now = Date()
        if let title {
            page.title = title
        }
        page.updatedAt = now
        document?.updatedAt = now

        if let pageContent = page.pageContent {
            pageContent.content = content
        } else {
            let pageContent = MyDocumentPageContent(pageId: page.id, content: content)
            pageContent.page = page
            page.pageContent = pageContent
            modelContext.insert(pageContent)
            insertedPageContent = pageContent
        }

        do {
            try savePageContentChanges()
            postAIDocMarkerUpserts(for: [page])
            return true
        } catch {
            page.title = originalTitle
            page.updatedAt = originalPageUpdatedAt
            if let document, let originalDocumentUpdatedAt {
                document.updatedAt = originalDocumentUpdatedAt
            }

            if let originalPageContent, let originalContent {
                originalPageContent.content = originalContent
            } else if let insertedPageContent {
                page.pageContent = nil
                insertedPageContent.page = nil
                modelContext.delete(insertedPageContent)
            }
            return false
        }
    }

    /**
     Inserts a My Documents graph and saves immediately.

     - Parameter document: Detached graph whose exact initials must be absent from My Documents.
     - Returns: `true` after the graph and sync journal save, otherwise `false` after rollback.
     - Side effects: Inserts the graph, records pending remote-sync mutations, updates AI markers,
       and saves through the journal service.
     - Failure modes: Duplicate My Documents initials or any persistence error returns `false`.
     - Important: This compatibility API has no production caller and does not participate in the
       complete native/SQLite/EPUB/MyDocument admission lease. New application publishers must use
       `MyDocumentLibraryStore` or another globally coordinated strict publication boundary.
     */
    @discardableResult
    public func insert(_ document: MyDocument) -> Bool {
        guard !hasDocument(initials: document.initials, excluding: document.id) else {
            return false
        }
        modelContext.insert(document)
        do {
            try RemoteSyncMutationJournalService.savePendingGraphChanges(
                for: .myDocuments,
                modelContext: modelContext
            )
            postAIDocMarkerUpserts(for: document.pages ?? [])
            return true
        } catch {
            modelContext.rollback()
            return false
        }
    }

    /**
     Saves pending My Documents changes with their remote-sync mutation journal.

     - Side Effects: Commits the graph and Android-compatible `LogEntry` rows atomically, then
       publishes the complete current AI marker set so open readers replace changed marker values.
     - Failure: Journal or persistence errors are swallowed and publish no event, preserving this
       store's eager-save API without exposing uncommitted marker state.
     */
    public func save() {
        do {
            try RemoteSyncMutationJournalService.savePendingGraphChanges(
                for: .myDocuments,
                modelContext: modelContext
            )
            let entries = (try? modelContext.fetch(FetchDescriptor<AiPageCacheEntry>())) ?? []
            aiDocMarkerEventCenter.post(
                MyDocumentAIDocMarkersChangedEvent(markers: projectedAIDocMarkers(entries))
            )
        } catch {
            return
        }
    }

    /**
     Publishes marker upserts for generated pages affected by one successful save.

     - Parameter pages: Saved pages whose AI cache relationships may project marker values.
     - Side effects: Reads loaded SwiftData relationships and synchronously posts one typed event.
     - Failure modes: Pages without complete AI cache/document relationships produce no marker and
       therefore no event.
     */
    private func postAIDocMarkerUpserts(for pages: [MyDocumentPage]) {
        let entries = pages.flatMap { $0.aiPageCacheEntries ?? [] }
        aiDocMarkerEventCenter.post(
            MyDocumentAIDocMarkersChangedEvent(markers: projectedAIDocMarkers(entries))
        )
    }

    /**
     Checks whether another persisted My Documents row already owns the supplied bridge initials.

     `MyDocument.initials` must stay unique for Android-compatible bridge resolution and remote
     backup export, but CloudKit-backed SwiftData stores cannot use a store-level unique
     constraint. This helper preserves the uniqueness contract at the app layer before new local
     rows are inserted.
     */
    private func hasDocument(initials: String, excluding documentID: UUID) -> Bool {
        var descriptor = FetchDescriptor<MyDocument>(
            predicate: #Predicate {
                $0.initials == initials && $0.id != documentID
            }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }
}
