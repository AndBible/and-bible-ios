// MyDocumentManagementSession.swift -- Save/cancel reducer for My Documents management

import Foundation

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
       - reservedInitials: Installed module initials that must not collide with generated documents.
       - initials: Explicit Android module identity, or `nil` to generate one from `name`.
       - sourcePromptId: Prompt that owns an AI-created document, or `nil` for user-created content.
     - Returns: Stable ID of the new draft.
     - Side effects: Appends the draft and marks the session dirty.
     - Failure modes: Throws when the trimmed name is empty.
     */
    @discardableResult
    public mutating func createDocument(
        name: String,
        documentDescription: String? = nil,
        reservedInitials: Set<String> = [],
        initials explicitInitials: String? = nil,
        sourcePromptId: UUID? = nil
    ) throws -> UUID {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw MyDocumentManagementError.emptyDocumentName
        }

        let id = UUID()
        let now = Date()
        let unavailableInitials = reservedInitials.union(documents.map(\.initials))
        let initials: String
        if let explicitInitials {
            let normalizedInitials = explicitInitials.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedInitials.isEmpty,
                  !unavailableInitials.contains(normalizedInitials) else {
                throw MyDocumentManagementError.duplicateInitials(normalizedInitials)
            }
            initials = normalizedInitials
        } else {
            initials = Self.generateInitials(for: trimmedName, unavailable: unavailableInitials)
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
     Imports sorted text files as one document using Android filename and content-type rules.
     */
    @discardableResult
    public mutating func importDocument(
        name: String,
        files: [MyDocumentImportFile],
        reservedInitials: Set<String> = []
    ) throws -> UUID {
        let importedPages = try MyDocumentTransferService.importPages(
            from: files,
            stripsDocumentOrderPrefix: true
        )
        let documentID = try createDocument(name: name, reservedInitials: reservedInitials)
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
     */
    public static func generateInitials(for baseName: String, unavailable: Set<String>) -> String {
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
        while unavailable.contains(candidate) {
            candidate = "MyDoc_\(stem)_\(counter)"
            counter += 1
        }
        return candidate
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
