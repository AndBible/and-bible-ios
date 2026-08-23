// MyDocumentManagementSession.swift -- Save/cancel reducer for My Documents management

import Foundation
import SwordKit

/**
 Value-based editing session for the complete My Documents library.

 Android exposes document and page management as explicit Save/Cancel activities. Keeping a
 persisted baseline beside the editable values gives iOS the same dirty-state contract without
 mutating SwiftData objects before Save. Cancel restores the baseline, including imported or newly
 created rows, and Save advances it only after the store commits successfully.

 - Side effects: None outside the value itself.
 - Failure modes: Mutations throw for empty names, missing IDs, protected AI Documents deletion,
   or empty imports.
 */
public struct MyDocumentManagementSession: Sendable {
    public static let aiDocumentsInitials = "AIDocuments"

    /// Current editable document graph.
    public private(set) var documents: [MyDocumentDraft]

    /// Last successfully loaded or saved graph.
    private var baseline: [MyDocumentDraft]

    /**
     Snapshot used by the persistence layer to distinguish user deletions from rows added by sync
     or AI work after this session loaded.

     This stays module-internal so UI callers cannot mutate or treat it as a second public model.
     */
    var persistedBaseline: [MyDocumentDraft] {
        baseline
    }

    /**
     Starts a session from persisted document values.

     - Parameter documents: Persisted documents and pages in any fetch order.
     - Side effects: Normalizes deterministic display order in memory.
     - Failure modes: None.
     */
    public init(documents: [MyDocumentDraft]) {
        let normalized = Self.normalizedDocuments(documents)
        self.documents = normalized
        self.baseline = normalized
    }

    /// Whether the editable graph differs from the last persisted baseline.
    public var isDirty: Bool {
        documents != baseline
    }

    /** Discards all pending mutations, including creates and imports. */
    public mutating func discardChanges() {
        documents = baseline
    }

    /** Advances the clean baseline after a successful transactional save. */
    public mutating func acceptSavedChanges() {
        documents = Self.normalizedDocuments(documents)
        baseline = documents
    }

    /**
     Creates one document with Android-compatible identity and optional AI ownership.

     - Parameters:
       - name: User-visible document name.
       - documentDescription: Optional description.
       - reservedInitials: Legacy installed identities compared with Java-exact UTF-16 semantics.
       - isInitialsUnavailable: Optional live JSword-registry predicate applied to every explicit or
         generated candidate after the legacy exact reserved set.
       - initials: Explicit Android module identity, or `nil` to generate one from `name`.
       - sourcePromptId: Prompt that owns an AI-created document, or `nil` for user-created content.
     - Returns: Stable ID of the new draft.
     - Side effects: Appends the draft and marks the session dirty.
     - Failure modes: Throws when the trimmed name is empty or an explicit identity is unavailable.
     */
    @discardableResult
    public mutating func createDocument(
        name: String,
        documentDescription: String? = nil,
        reservedInitials: Set<String> = [],
        isInitialsUnavailable: ((String) -> Bool)? = nil,
        initials explicitInitials: String? = nil,
        sourcePromptId: UUID? = nil
    ) throws -> UUID {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw MyDocumentManagementError.emptyDocumentName
        }

        let id = UUID()
        let now = Date()
        let unavailableInitials = Array(reservedInitials)
        let pendingDocuments = documents
        let isPendingInitialsUnavailable: (String) -> Bool = { candidate in
            Self.pendingDocumentsOwnInitials(candidate, documents: pendingDocuments)
                || isInitialsUnavailable?(candidate) == true
        }
        let initials: String
        if let explicitInitials {
            let normalizedInitials = explicitInitials.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedInitials.isEmpty,
                  !Self.containsJavaExact(unavailableInitials, normalizedInitials),
                  !isPendingInitialsUnavailable(normalizedInitials) else {
                throw MyDocumentManagementError.duplicateInitials(normalizedInitials)
            }
            initials = normalizedInitials
        } else {
            initials = Self.generateInitials(
                for: trimmedName,
                unavailableValues: unavailableInitials,
                isUnavailable: isPendingInitialsUnavailable
            )
        }
        documents.append(MyDocumentDraft(
            id: id,
            name: trimmedName,
            documentDescription: Self.normalizedOptionalText(documentDescription),
            initials: initials,
            orderNumber: documents.count,
            createdAt: now,
            updatedAt: now,
            sourcePromptId: sourcePromptId
        ))
        normalizeDocumentOrder(now: now)
        return id
    }

    /**
     Imports sorted text files as one globally admissible My Documents book.

     - Parameters:
       - name: User-visible document name used to generate the Android initials stem.
       - files: Selected text/Markdown/HTML files projected into ordered pages.
       - reservedInitials: Legacy installed identities compared with Java-exact UTF-16 semantics.
       - isInitialsUnavailable: Optional complete JSword-registry predicate applied to every
         generated candidate before a draft is appended.
     - Returns: Stable ID of the imported document draft.
     - Side effects: Parses supplied file values, appends one document, and assigns imported pages.
     - Failure modes: Propagates empty/unsupported import, identity, and draft invariant failures;
       no document remains appended if page conversion fails before creation.
     */
    @discardableResult
    public mutating func importDocument(
        name: String,
        files: [MyDocumentImportFile],
        reservedInitials: Set<String> = [],
        isInitialsUnavailable: ((String) -> Bool)? = nil
    ) throws -> UUID {
        let importedPages = try MyDocumentTransferService.importPages(
            from: files,
            stripsDocumentOrderPrefix: true
        )
        let documentID = try createDocument(
            name: name,
            reservedInitials: reservedInitials,
            isInitialsUnavailable: isInitialsUnavailable
        )
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else {
            throw MyDocumentManagementError.documentNotFound(documentID)
        }
        documents[index].pages = importedPages
        documents[index].updatedAt = Date()
        return documentID
    }

    /** Renames one document after trimming its user-visible name. */
    public mutating func renameDocument(id: UUID, name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw MyDocumentManagementError.emptyDocumentName
        }
        try mutateDocument(id: id) { document in
            document.name = trimmedName
            document.updatedAt = Date()
        }
    }

    /** Replaces one document description, storing blank input as `nil`. */
    public mutating func setDocumentDescription(id: UUID, description: String?) throws {
        try mutateDocument(id: id) { document in
            document.documentDescription = Self.normalizedOptionalText(description)
            document.updatedAt = Date()
        }
    }

    /**
     Removes one document from the draft.

     Android protects the generated AI Documents collection while it contains pages; iOS preserves
     that exact guard and allows deleting an empty AI Documents row.
     */
    public mutating func deleteDocument(id: UUID) throws {
        guard let index = documents.firstIndex(where: { $0.id == id }) else {
            throw MyDocumentManagementError.documentNotFound(id)
        }
        if documents[index].initials == Self.aiDocumentsInitials,
           !documents[index].pages.isEmpty {
            throw MyDocumentManagementError.cannotDeleteNonemptyAIDocument
        }
        documents.remove(at: index)
        normalizeDocumentOrder(now: Date())
    }

    /** Reorders documents while keeping Android's AI Documents collection first. */
    public mutating func moveDocuments(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let movable = IndexSet(offsets.filter {
            documents.indices.contains($0) && documents[$0].initials != Self.aiDocumentsInitials
        })
        Self.move(&documents, fromOffsets: movable, toOffset: destination)
        if let aiIndex = documents.firstIndex(where: { $0.initials == Self.aiDocumentsInitials }),
           aiIndex != 0 {
            documents.insert(documents.remove(at: aiIndex), at: 0)
        }
        normalizeDocumentOrder(now: Date())
    }

    /** Creates a page at the end of one document with optional initial content and AI ownership. */
    @discardableResult
    public mutating func createPage(
        documentID: UUID,
        title: String,
        contentType: MyDocumentContentType,
        content: String = "",
        sourcePromptId: UUID? = nil
    ) throws -> UUID {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw MyDocumentManagementError.emptyPageTitle
        }
        let pageID = UUID()
        let now = Date()
        try mutateDocument(id: documentID) { document in
            document.pages.append(MyDocumentPageDraft(
                id: pageID,
                title: trimmedTitle,
                contentType: contentType,
                orderNumber: document.pages.count,
                createdAt: now,
                updatedAt: now,
                sourcePromptId: sourcePromptId,
                languageCode: Locale.current.language.languageCode?.identifier,
                content: content
            ))
            Self.normalizePageOrder(in: &document, now: now)
            document.updatedAt = now
        }
        return pageID
    }

    /** Imports one text file as a page using Android's extension and title rules. */
    @discardableResult
    public mutating func importPage(documentID: UUID, file: MyDocumentImportFile) throws -> UUID {
        let pages = try MyDocumentTransferService.importPages(
            from: [file],
            stripsDocumentOrderPrefix: false
        )
        guard var page = pages.first else {
            throw MyDocumentManagementError.emptyImport
        }
        let now = Date()
        try mutateDocument(id: documentID) { document in
            page.orderNumber = document.pages.count
            document.pages.append(page)
            Self.normalizePageOrder(in: &document, now: now)
            document.updatedAt = now
        }
        return page.id
    }

    /** Updates a page title, content type, and raw body as one editor mutation. */
    public mutating func updatePage(
        documentID: UUID,
        pageID: UUID,
        title: String,
        contentType: MyDocumentContentType,
        content: String
    ) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw MyDocumentManagementError.emptyPageTitle
        }
        let now = Date()
        try mutateDocument(id: documentID) { document in
            guard let pageIndex = document.pages.firstIndex(where: { $0.id == pageID }) else {
                throw MyDocumentManagementError.pageNotFound(pageID)
            }
            document.pages[pageIndex].title = trimmedTitle
            document.pages[pageIndex].contentType = contentType
            document.pages[pageIndex].content = content
            document.pages[pageIndex].updatedAt = now
            document.updatedAt = now
        }
    }

    /** Removes one page and compacts sibling order numbers. */
    public mutating func deletePage(documentID: UUID, pageID: UUID) throws {
        let now = Date()
        try mutateDocument(id: documentID) { document in
            guard let pageIndex = document.pages.firstIndex(where: { $0.id == pageID }) else {
                throw MyDocumentManagementError.pageNotFound(pageID)
            }
            document.pages.remove(at: pageIndex)
            Self.normalizePageOrder(in: &document, now: now)
            document.updatedAt = now
        }
    }

    /** Reorders pages inside one document and persists contiguous Android order numbers. */
    public mutating func movePages(
        documentID: UUID,
        fromOffsets offsets: IndexSet,
        toOffset destination: Int
    ) throws {
        let now = Date()
        try mutateDocument(id: documentID) { document in
            Self.move(&document.pages, fromOffsets: offsets, toOffset: destination)
            Self.normalizePageOrder(in: &document, now: now)
            document.updatedAt = now
        }
    }

    /** Returns one current draft without exposing mutable storage internals. */
    public func document(id: UUID) -> MyDocumentDraft? {
        documents.first { $0.id == id }
    }

    /**
     Generates initials with Android's `MyDocumentBookManager.generateInitials` algorithm.

     - Parameters:
       - baseName: Document name whose first ten ASCII alphanumeric scalars form the initials stem.
       - unavailable: Existing My Documents/legacy-reserved initials compared as Java UTF-16.
       - isUnavailable: Optional complete JSword `Books.getBook` predicate evaluated for every
         base/suffixed candidate.
     - Returns: First candidate absent from both availability authorities.
     - Side effects: Repeatedly evaluates `isUnavailable` until a candidate is admitted.
     - Failure modes: None for finite registries; an adversarial predicate that rejects every
       generated suffix does not terminate, matching the caller's responsibility.
     */
    public static func generateInitials(
        for baseName: String,
        unavailable: Set<String>,
        isUnavailable: ((String) -> Bool)? = nil
    ) -> String {
        generateInitials(
            for: baseName,
            unavailableValues: Array(unavailable),
            isUnavailable: isUnavailable
        )
    }

    /**
     Generates initials against exact Java-string values without Swift canonical folding.

     - Parameters:
       - baseName: Document name used to derive the ASCII initials stem.
       - unavailableValues: Existing identities whose UTF-16 sequences are already registered.
       - isUnavailable: Optional live global-registry predicate for each candidate.
     - Returns: First Android-generated candidate absent from both availability authorities.
     - Side effects: Repeatedly evaluates `isUnavailable` until a candidate is admitted.
     - Failure modes: A predicate that rejects every suffix does not terminate.
     */
    private static func generateInitials(
        for baseName: String,
        unavailableValues: [String],
        isUnavailable: ((String) -> Bool)?
    ) -> String {
        let sanitized = String(baseName.unicodeScalars
            .filter { scalar in
                (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 65 && scalar.value <= 90)
                    || (scalar.value >= 97 && scalar.value <= 122)
            }
            .prefix(10)
            .map(Character.init))
        let stem = sanitized.isEmpty ? "MyDoc" : sanitized
        var candidate = "MyDoc_\(stem)"
        var counter = 1
        while containsJavaExact(unavailableValues, candidate)
            || isUnavailable?(candidate) == true {
            candidate = "MyDoc_\(stem)_\(counter)"
            counter += 1
        }
        return candidate
    }

    /**
     Tests exact identity membership with Java `String.equals` semantics.

     - Parameters:
       - values: Registered or reserved identity strings.
       - candidate: Candidate identity being admitted.
     - Returns: True only when one value has the same UTF-16 code units as the candidate.
     - Side effects: None.
     - Failure modes: None; Swift strings expose valid UTF-16 views.
     */
    private static func containsJavaExact(_ values: [String], _ candidate: String) -> Bool {
        values.contains { SwordJavaStringIdentity.equals($0, candidate) }
    }

    /**
     Replays Android's sequential My Documents registration and resolves a candidate initials token.

     Each pending document is admitted only when `Books.getBook(document.initials)` would not find
     an earlier admitted document by exact initials/full name or Android case-insensitive
     initials/full name. Replaying is necessary because iOS keeps new documents as drafts until
     Save, while Android inserts and registers each document immediately.

     - Parameters:
       - candidate: Candidate initials passed to Android's global `Books.getBook` preflight.
       - documents: Existing drafts in registration order.
     - Returns: True when an earlier Android-admitted draft owns the candidate token.
     - Side effects: Loads the pinned Android case table on first case-insensitive comparison.
     - Failure modes: Traps only when the bundled Android compatibility table is missing/corrupt.
     */
    static func pendingDocumentsOwnInitials(
        _ candidate: String,
        documents: [MyDocumentDraft]
    ) -> Bool {
        var admitted: [MyDocumentDraft] = []
        for document in documents {
            guard !pendingDocumentsOwnInitials(document.initials, admittedDocuments: admitted) else {
                continue
            }
            admitted.append(document)
        }
        return pendingDocumentsOwnInitials(candidate, admittedDocuments: admitted)
    }

    /**
     Resolves one initials token against already-admitted My Documents metadata.

     - Parameters:
       - candidate: Exact initials token supplied to JSword.
       - admittedDocuments: Earlier documents that survived sequential registration preflight.
     - Returns: True for Android `Books.getBook` exact/case-insensitive initials or full-name tiers.
     - Side effects: Loads the pinned Android case table on first case-insensitive comparison.
     - Failure modes: Traps only when the bundled Android compatibility table is missing/corrupt.
     */
    private static func pendingDocumentsOwnInitials(
        _ candidate: String,
        admittedDocuments: [MyDocumentDraft]
    ) -> Bool {
        let identities = admittedDocuments.map {
            (initials: $0.initials, fullName: SwordJavaStringIdentity.trim($0.name))
        }
        return identities.contains {
            SwordJavaStringIdentity.equals($0.initials, candidate)
        } || identities.contains {
            SwordJavaStringIdentity.equals($0.fullName, candidate)
        } || identities.contains {
            SwordJavaStringIdentity.equalsIgnoreCase($0.initials, candidate)
        } || identities.contains {
            SwordJavaStringIdentity.equalsIgnoreCase($0.fullName, candidate)
        }
    }

    private mutating func mutateDocument(
        id: UUID,
        mutation: (inout MyDocumentDraft) throws -> Void
    ) throws {
        guard let index = documents.firstIndex(where: { $0.id == id }) else {
            throw MyDocumentManagementError.documentNotFound(id)
        }
        try mutation(&documents[index])
    }

    private mutating func normalizeDocumentOrder(now: Date) {
        for index in documents.indices where documents[index].orderNumber != index {
            documents[index].orderNumber = index
            documents[index].updatedAt = now
        }
    }

    private static func normalizePageOrder(in document: inout MyDocumentDraft, now: Date) {
        for index in document.pages.indices where document.pages[index].orderNumber != index {
            document.pages[index].orderNumber = index
            document.pages[index].updatedAt = now
        }
    }

    private static func normalizedDocuments(_ source: [MyDocumentDraft]) -> [MyDocumentDraft] {
        var documents = source.sorted { lhs, rhs in
            let lhsIsAI = lhs.initials == aiDocumentsInitials
            let rhsIsAI = rhs.initials == aiDocumentsInitials
            if lhsIsAI != rhsIsAI { return lhsIsAI }
            if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
            if lhs.name != rhs.name { return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
            return lhs.initials < rhs.initials
        }
        for documentIndex in documents.indices {
            documents[documentIndex].orderNumber = documentIndex
            documents[documentIndex].pages.sort { lhs, rhs in
                if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
                if lhs.title != rhs.title { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
                return lhs.pageKey < rhs.pageKey
            }
            for pageIndex in documents[documentIndex].pages.indices {
                documents[documentIndex].pages[pageIndex].orderNumber = pageIndex
            }
        }
        return documents
    }

    private static func normalizedOptionalText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func move<Element>(
        _ values: inout [Element],
        fromOffsets offsets: IndexSet,
        toOffset destination: Int
    ) {
        let validOffsets = offsets.filter(values.indices.contains).sorted()
        guard !validOffsets.isEmpty else { return }
        let moving = validOffsets.map { values[$0] }
        for index in validOffsets.reversed() {
            values.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertionIndex = min(max(0, destination - removedBeforeDestination), values.count)
        values.insert(contentsOf: moving, at: insertionIndex)
    }
}
