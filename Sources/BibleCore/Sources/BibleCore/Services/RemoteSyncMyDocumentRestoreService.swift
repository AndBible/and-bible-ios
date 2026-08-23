// RemoteSyncMyDocumentRestoreService.swift -- My Documents initial-backup restore from Android sync databases

import Foundation
import SQLite3
import SwordKit
import SwiftData

private let remoteSyncMyDocumentSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while reading or restoring Android My Documents sync databases.
 */
public enum RemoteSyncMyDocumentRestoreError: Error, Equatable {
    /// The staged file could not be opened as a readable SQLite database.
    case invalidSQLiteDatabase

    /// The staged database requires a newer Android schema than iOS currently supports.
    case unsupportedSchemaVersion(Int)

    /// The staged database does not contain one of the required Android My Documents tables.
    case missingTable(String)

    /// One Android UUID-like blob could not be converted into an iOS `UUID`.
    case invalidIdentifierBlob(table: String, column: String)

    /// One staged Android backup would create duplicate bridge initials.
    case duplicateInitials([String])

    /// One required staged column was missing or contained an unusable value.
    case invalidColumnValue(table: String, column: String)

    /// One or more staged rows referenced missing parent records.
    case orphanReferences([String])
}

/**
 One Android `MyDocument` row from a staged sync backup.
 */
public struct RemoteSyncAndroidMyDocument: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let documentDescription: String?
    public let initials: String
    public let orderNumber: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let sourcePromptId: UUID?

    public init(
        id: UUID,
        name: String,
        documentDescription: String?,
        initials: String,
        orderNumber: Int,
        createdAt: Date,
        updatedAt: Date,
        sourcePromptId: UUID?
    ) {
        self.id = id
        self.name = name
        self.documentDescription = documentDescription
        self.initials = initials
        self.orderNumber = orderNumber
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourcePromptId = sourcePromptId
    }
}

/**
 One Android `MyDocumentPage` row from a staged sync backup.
 */
public struct RemoteSyncAndroidMyDocumentPage: Sendable, Equatable {
    public let id: UUID
    public let documentId: UUID
    public let title: String
    public let pageKey: String
    public let contentType: MyDocumentContentType
    public let orderNumber: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let sourcePromptId: UUID?
    public let languageCode: String?

    public init(
        id: UUID,
        documentId: UUID,
        title: String,
        pageKey: String,
        contentType: MyDocumentContentType,
        orderNumber: Int,
        createdAt: Date,
        updatedAt: Date,
        sourcePromptId: UUID?,
        languageCode: String?
    ) {
        self.id = id
        self.documentId = documentId
        self.title = title
        self.pageKey = pageKey
        self.contentType = contentType
        self.orderNumber = orderNumber
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourcePromptId = sourcePromptId
        self.languageCode = languageCode
    }
}

/**
 One Android `MyDocumentPageContent` row from a staged sync backup.
 */
public struct RemoteSyncAndroidMyDocumentPageContent: Sendable, Equatable {
    public let pageId: UUID
    public let content: String

    public init(pageId: UUID, content: String) {
        self.pageId = pageId
        self.content = content
    }
}

/**
 One Android `AiPageCacheEntry` row from a staged sync backup.
 */
public struct RemoteSyncAndroidAiPageCacheEntry: Sendable, Equatable {
    public let pageId: UUID
    public let sourcePromptId: UUID
    public let sourceContext: String?
    public let kjvOrdinalStart: Int?
    public let kjvOrdinalEnd: Int?
    public let contextHash: String?
    public let usedWriteTools: Bool
    public let sourceModelName: String?
    public let sourceBookInitials: String?
    public let sourceBookKey: String?

    public init(
        pageId: UUID,
        sourcePromptId: UUID,
        sourceContext: String?,
        kjvOrdinalStart: Int?,
        kjvOrdinalEnd: Int?,
        contextHash: String?,
        usedWriteTools: Bool,
        sourceModelName: String?,
        sourceBookInitials: String?,
        sourceBookKey: String?
    ) {
        self.pageId = pageId
        self.sourcePromptId = sourcePromptId
        self.sourceContext = sourceContext
        self.kjvOrdinalStart = kjvOrdinalStart
        self.kjvOrdinalEnd = kjvOrdinalEnd
        self.contextHash = contextHash
        self.usedWriteTools = usedWriteTools
        self.sourceModelName = sourceModelName
        self.sourceBookInitials = sourceBookInitials
        self.sourceBookKey = sourceBookKey
    }
}

/**
 Read-only snapshot of one staged Android My Documents sync database.
 */
public struct RemoteSyncAndroidMyDocumentSnapshot: Sendable, Equatable {
    public let documents: [RemoteSyncAndroidMyDocument]
    public let pages: [RemoteSyncAndroidMyDocumentPage]
    public let pageContents: [RemoteSyncAndroidMyDocumentPageContent]
    public let aiPageCacheEntries: [RemoteSyncAndroidAiPageCacheEntry]
    public let orphanReferences: [String]

    public init(
        documents: [RemoteSyncAndroidMyDocument],
        pages: [RemoteSyncAndroidMyDocumentPage],
        pageContents: [RemoteSyncAndroidMyDocumentPageContent],
        aiPageCacheEntries: [RemoteSyncAndroidAiPageCacheEntry],
        orphanReferences: [String] = []
    ) {
        self.documents = documents
        self.pages = pages
        self.pageContents = pageContents
        self.aiPageCacheEntries = aiPageCacheEntries
        self.orphanReferences = orphanReferences
    }
}

/**
 Summary of one successful Android My Documents restore.
 */
public struct RemoteSyncMyDocumentRestoreReport: Sendable, Equatable {
    public let restoredDocumentCount: Int
    public let restoredPageCount: Int
    public let restoredContentCount: Int
    public let restoredAIPageCacheEntryCount: Int

    public init(
        restoredDocumentCount: Int,
        restoredPageCount: Int,
        restoredContentCount: Int,
        restoredAIPageCacheEntryCount: Int
    ) {
        self.restoredDocumentCount = restoredDocumentCount
        self.restoredPageCount = restoredPageCount
        self.restoredContentCount = restoredContentCount
        self.restoredAIPageCacheEntryCount = restoredAIPageCacheEntryCount
    }
}

/**
 Reads staged Android My Documents databases and restores them into iOS SwiftData.

 This is an authoritative synced-graph replacement, not a new local document registration. Android
 retains restored My Documents rows even when an earlier native, SQLite, or EPUB registration owns
 the same lookup identity. iOS therefore preserves those rows as sync data and lets the combined
 reader resolver replay native, SQLite, EPUB, then My Documents admission to choose the visible
 owner. Restore intentionally does not reject the remote graph against the live module registry.

 Side effects:
 - reads staged SQLite databases without mutating them
 - replaces the complete local My Documents graph in one caller-owned or direct SwiftData commit

 Failure modes:
 - malformed schemas, invalid graphs, fetch failures, and persistence failures abort or roll back the
   replacement; registry collisions are retained and resolved later by Android registration order
 */
public final class RemoteSyncMyDocumentRestoreService {
    public static let supportedAndroidSchemaVersion = 4

    public init() {}

    /**
     Reads one staged Android `mydocuments.sqlite3` database into a typed snapshot.
     */
    public func readSnapshot(from databaseURL: URL) throws -> RemoteSyncAndroidMyDocumentSnapshot {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(db) }

        let userVersion = try databaseUserVersion(db)
        if userVersion > Self.supportedAndroidSchemaVersion {
            throw RemoteSyncMyDocumentRestoreError.unsupportedSchemaVersion(userVersion)
        }

        try requireTable(named: "MyDocument", in: db)
        try requireTable(named: "MyDocumentPage", in: db)
        try requireTable(named: "MyDocumentPageContent", in: db)
        try requireTable(named: "AiPageCacheEntry", in: db)

        let documents = try fetchDocuments(from: db)
        let pages = try fetchPages(from: db)
        let pageContents = try fetchPageContents(from: db)
        let aiPageCacheEntries = try fetchAIPageCacheEntries(from: db)
        let orphanReferences = Self.orphanReferences(
            documents: documents,
            pages: pages,
            pageContents: pageContents,
            aiPageCacheEntries: aiPageCacheEntries
        )

        return RemoteSyncAndroidMyDocumentSnapshot(
            documents: documents.sorted { $0.orderNumber == $1.orderNumber ? $0.name < $1.name : $0.orderNumber < $1.orderNumber },
            pages: pages.sorted { $0.orderNumber == $1.orderNumber ? $0.title < $1.title : $0.orderNumber < $1.orderNumber },
            pageContents: pageContents.sorted { $0.pageId.uuidString < $1.pageId.uuidString },
            aiPageCacheEntries: aiPageCacheEntries.sorted { $0.pageId.uuidString < $1.pageId.uuidString },
            orphanReferences: orphanReferences
        )
    }

    /**
     Replaces local iOS My Documents with the supplied staged Android snapshot.

     - Parameters:
       - snapshot: Validated or untrusted Android-shaped My Documents graph.
       - modelContext: Context whose complete My Documents graph is replaced.
     - Returns: Counts of the rows durably restored.
     - Side Effects: Deletes and recreates My Documents models, then saves the context once.
     - Throws: Rethrows validation, fetch, and save errors; save failure rolls all staged models back.
     */
    public func replaceLocalMyDocuments(
        from snapshot: RemoteSyncAndroidMyDocumentSnapshot,
        modelContext: ModelContext
    ) throws -> RemoteSyncMyDocumentRestoreReport {
        let report = try stageLocalMyDocuments(from: snapshot, modelContext: modelContext)
        do {
            try modelContext.save()
            return report
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /**
     Replaces My Documents inside a settings-backed sync transaction.

     Initial restore and patch replay use this overload so document models, Android `LogEntry`
     metadata, patch status, and fingerprint baselines can share one outer transaction. Nested calls
     join an existing batch rather than saving early.

     - Parameters:
       - snapshot: Android-shaped My Documents graph to publish.
       - modelContext: Exact clean context shared by models and `settingsStore`.
       - settingsStore: Settings store bound to `modelContext`.
     - Returns: Counts of rows restored after the outer transaction commits.
     - Side Effects: Stages the complete My Documents replacement without an intermediate save.
     - Throws: Rethrows validation, context-contract, fetch, cancellation, and commit errors; the
       complete shared context rolls back on failure.
     */
    func replaceLocalMyDocuments(
        from snapshot: RemoteSyncAndroidMyDocumentSnapshot,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncMyDocumentRestoreReport {
        try settingsStore.performAtomicBatch(in: modelContext) {
            try stageLocalMyDocuments(from: snapshot, modelContext: modelContext)
        }
    }

    /**
     Validates and stages one complete My Documents graph replacement without committing it.

     - Parameters:
       - snapshot: Android-shaped graph whose references and initials must be valid.
       - modelContext: Context receiving all delete and insert mutations.
     - Returns: Counts describing the staged replacement.
     - Side Effects: Deletes existing My Documents models and inserts snapshot models in memory.
     - Throws: Throws explicit orphan/duplicate validation errors and rethrows strict fetch errors.
     - Important: The caller owns the commit or rollback boundary.
     */
    private func stageLocalMyDocuments(
        from snapshot: RemoteSyncAndroidMyDocumentSnapshot,
        modelContext: ModelContext
    ) throws -> RemoteSyncMyDocumentRestoreReport {
        if !snapshot.orphanReferences.isEmpty {
            throw RemoteSyncMyDocumentRestoreError.orphanReferences(snapshot.orphanReferences)
        }
        let duplicateInitials = Self.duplicateInitials(in: snapshot.documents)
        if !duplicateInitials.isEmpty {
            throw RemoteSyncMyDocumentRestoreError.duplicateInitials(duplicateInitials)
        }

        let existingCacheEntries = try modelContext.fetch(FetchDescriptor<AiPageCacheEntry>())
        let existingContents = try modelContext.fetch(FetchDescriptor<MyDocumentPageContent>())
        let existingPages = try modelContext.fetch(FetchDescriptor<MyDocumentPage>())
        let existingDocuments = try modelContext.fetch(FetchDescriptor<MyDocument>())

        for cacheEntry in existingCacheEntries {
            modelContext.delete(cacheEntry)
        }
        for content in existingContents {
            modelContext.delete(content)
        }
        for page in existingPages {
            modelContext.delete(page)
        }
        for document in existingDocuments {
            modelContext.delete(document)
        }

        var documentsByID: [UUID: MyDocument] = [:]
        var pagesByID: [UUID: MyDocumentPage] = [:]

        for stagedDocument in snapshot.documents {
            let document = MyDocument(
                id: stagedDocument.id,
                name: stagedDocument.name,
                documentDescription: stagedDocument.documentDescription,
                initials: stagedDocument.initials,
                orderNumber: stagedDocument.orderNumber,
                createdAt: stagedDocument.createdAt,
                updatedAt: stagedDocument.updatedAt,
                sourcePromptId: stagedDocument.sourcePromptId
            )
            document.pages = []
            documentsByID[stagedDocument.id] = document
            modelContext.insert(document)
        }

        for stagedPage in snapshot.pages {
            let page = MyDocumentPage(
                id: stagedPage.id,
                title: stagedPage.title,
                pageKey: stagedPage.pageKey,
                contentType: stagedPage.contentType,
                orderNumber: stagedPage.orderNumber,
                createdAt: stagedPage.createdAt,
                updatedAt: stagedPage.updatedAt,
                sourcePromptId: stagedPage.sourcePromptId,
                languageCode: stagedPage.languageCode
            )
            page.aiPageCacheEntries = []
            if let document = documentsByID[stagedPage.documentId] {
                page.document = document
                document.pages?.append(page)
            }
            pagesByID[stagedPage.id] = page
            modelContext.insert(page)
        }

        for stagedContent in snapshot.pageContents {
            let content = MyDocumentPageContent(
                pageId: stagedContent.pageId,
                content: stagedContent.content
            )
            if let page = pagesByID[stagedContent.pageId] {
                content.page = page
                page.pageContent = content
            }
            modelContext.insert(content)
        }

        for stagedCacheEntry in snapshot.aiPageCacheEntries {
            let cacheEntry = AiPageCacheEntry(
                pageId: stagedCacheEntry.pageId,
                sourcePromptId: stagedCacheEntry.sourcePromptId,
                sourceContext: stagedCacheEntry.sourceContext,
                kjvOrdinalStart: stagedCacheEntry.kjvOrdinalStart,
                kjvOrdinalEnd: stagedCacheEntry.kjvOrdinalEnd,
                contextHash: stagedCacheEntry.contextHash,
                usedWriteTools: stagedCacheEntry.usedWriteTools,
                sourceModelName: stagedCacheEntry.sourceModelName,
                sourceBookInitials: stagedCacheEntry.sourceBookInitials,
                sourceBookKey: stagedCacheEntry.sourceBookKey
            )
            if let page = pagesByID[stagedCacheEntry.pageId] {
                cacheEntry.page = page
                page.aiPageCacheEntries?.append(cacheEntry)
            }
            modelContext.insert(cacheEntry)
        }

        return RemoteSyncMyDocumentRestoreReport(
            restoredDocumentCount: snapshot.documents.count,
            restoredPageCount: snapshot.pages.count,
            restoredContentCount: snapshot.pageContents.count,
            restoredAIPageCacheEntryCount: snapshot.aiPageCacheEntries.count
        )
    }

    /**
     Returns staged My Documents initials that would violate Android bridge uniqueness.

     Android exposes each My Document as a generated general-book module and keeps `initials`
     unique by SQLite BINARY/Java `String.equals` identity. iOS must preserve that exact UTF-16
     contract at import time because CloudKit-backed SwiftData stores cannot use a native unique
     constraint on the synced model attribute and Swift `String` equality normalizes canonical
     equivalents.

     - Parameter documents: Android-shaped My Documents rows decoded from restore or patch data.
     - Returns: Sorted duplicate initials values; empty when the staged rows are unique.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func duplicateInitials(in documents: [RemoteSyncAndroidMyDocument]) -> [String] {
        var seen: Set<SwordJavaExactStringIdentity> = []
        var duplicates: [SwordJavaExactStringIdentity: String] = [:]
        for document in documents {
            let identity = SwordJavaExactStringIdentity(document.initials)
            if !seen.insert(identity).inserted {
                duplicates[identity] = document.initials
            }
        }
        return duplicates.values.sorted {
            SwordJavaExactStringIdentity($0).utf16CodeUnits.lexicographicallyPrecedes(
                SwordJavaExactStringIdentity($1).utf16CodeUnits
            )
        }
    }

    private static func orphanReferences(
        documents: [RemoteSyncAndroidMyDocument],
        pages: [RemoteSyncAndroidMyDocumentPage],
        pageContents: [RemoteSyncAndroidMyDocumentPageContent],
        aiPageCacheEntries: [RemoteSyncAndroidAiPageCacheEntry]
    ) -> [String] {
        let documentIDs = Set(documents.map(\.id))
        let pageIDs = Set(pages.map(\.id))
        var references: [String] = []

        for page in pages where !documentIDs.contains(page.documentId) {
            references.append("MyDocumentPage.id=\(page.id.uuidString) missing MyDocument")
        }
        for content in pageContents where !pageIDs.contains(content.pageId) {
            references.append("MyDocumentPageContent.pageId=\(content.pageId.uuidString) missing MyDocumentPage")
        }
        for cacheEntry in aiPageCacheEntries where !pageIDs.contains(cacheEntry.pageId) {
            references.append("AiPageCacheEntry.pageId=\(cacheEntry.pageId.uuidString) missing MyDocumentPage")
        }
        return references.sorted()
    }

    private func databaseUserVersion(_ db: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              let statement,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func requireTable(named tableName: String, in db: OpaquePointer) throws {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
        }

        sqlite3_bind_text(statement, 1, tableName, -1, remoteSyncMyDocumentSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw RemoteSyncMyDocumentRestoreError.missingTable(tableName)
        }
    }

    private func fetchDocuments(from db: OpaquePointer) throws -> [RemoteSyncAndroidMyDocument] {
        let table = "MyDocument"
        let sql = """
        SELECT id, name, description, initials, orderNumber, createdAt, updatedAt, sourcePromptId
        FROM MyDocument
        ORDER BY orderNumber, name
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
        }

        var rows: [RemoteSyncAndroidMyDocument] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                RemoteSyncAndroidMyDocument(
                    id: try uuidFromBlob(statement: statement, column: 0, table: table, name: "id"),
                    name: try requiredTextColumn(statement: statement, index: 1, table: table, name: "name"),
                    documentDescription: optionalTextColumn(statement: statement, index: 2),
                    initials: try requiredTextColumn(statement: statement, index: 3, table: table, name: "initials"),
                    orderNumber: try requiredIntColumn(statement: statement, index: 4, table: table, name: "orderNumber"),
                    createdAt: try requiredDateColumn(statement: statement, index: 5, table: table, name: "createdAt"),
                    updatedAt: try requiredDateColumn(statement: statement, index: 6, table: table, name: "updatedAt"),
                    sourcePromptId: try optionalUUIDFromBlob(statement: statement, column: 7, table: table, name: "sourcePromptId")
                )
            )
        }
        return rows
    }

    private func fetchPages(from db: OpaquePointer) throws -> [RemoteSyncAndroidMyDocumentPage] {
        let table = "MyDocumentPage"
        let sql = """
        SELECT id, documentId, title, pageKey, contentType, orderNumber, createdAt, updatedAt, sourcePromptId, languageCode
        FROM MyDocumentPage
        ORDER BY documentId, orderNumber, title
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
        }

        var rows: [RemoteSyncAndroidMyDocumentPage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rawContentType = try requiredTextColumn(statement: statement, index: 4, table: table, name: "contentType")
            guard let contentType = MyDocumentContentType(rawValue: rawContentType) else {
                throw RemoteSyncMyDocumentRestoreError.invalidColumnValue(table: table, column: "contentType")
            }
            rows.append(
                RemoteSyncAndroidMyDocumentPage(
                    id: try uuidFromBlob(statement: statement, column: 0, table: table, name: "id"),
                    documentId: try uuidFromBlob(statement: statement, column: 1, table: table, name: "documentId"),
                    title: try requiredTextColumn(statement: statement, index: 2, table: table, name: "title"),
                    pageKey: try requiredTextColumn(statement: statement, index: 3, table: table, name: "pageKey"),
                    contentType: contentType,
                    orderNumber: try requiredIntColumn(statement: statement, index: 5, table: table, name: "orderNumber"),
                    createdAt: try requiredDateColumn(statement: statement, index: 6, table: table, name: "createdAt"),
                    updatedAt: try requiredDateColumn(statement: statement, index: 7, table: table, name: "updatedAt"),
                    sourcePromptId: try optionalUUIDFromBlob(statement: statement, column: 8, table: table, name: "sourcePromptId"),
                    languageCode: optionalTextColumn(statement: statement, index: 9)
                )
            )
        }
        return rows
    }

    private func fetchPageContents(from db: OpaquePointer) throws -> [RemoteSyncAndroidMyDocumentPageContent] {
        let table = "MyDocumentPageContent"
        let sql = """
        SELECT pageId, content
        FROM MyDocumentPageContent
        ORDER BY pageId
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
        }

        var rows: [RemoteSyncAndroidMyDocumentPageContent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                RemoteSyncAndroidMyDocumentPageContent(
                    pageId: try uuidFromBlob(statement: statement, column: 0, table: table, name: "pageId"),
                    content: try requiredTextColumn(statement: statement, index: 1, table: table, name: "content")
                )
            )
        }
        return rows
    }

    private func fetchAIPageCacheEntries(from db: OpaquePointer) throws -> [RemoteSyncAndroidAiPageCacheEntry] {
        let table = "AiPageCacheEntry"
        let sql = """
        SELECT pageId, sourcePromptId, sourceContext, kjvOrdinalStart, kjvOrdinalEnd, contextHash,
               usedWriteTools, sourceModelName, sourceBookInitials, sourceBookKey
        FROM AiPageCacheEntry
        ORDER BY pageId
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
        }

        var rows: [RemoteSyncAndroidAiPageCacheEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                RemoteSyncAndroidAiPageCacheEntry(
                    pageId: try uuidFromBlob(statement: statement, column: 0, table: table, name: "pageId"),
                    sourcePromptId: try uuidFromBlob(statement: statement, column: 1, table: table, name: "sourcePromptId"),
                    sourceContext: optionalTextColumn(statement: statement, index: 2),
                    kjvOrdinalStart: optionalIntColumn(statement: statement, index: 3),
                    kjvOrdinalEnd: optionalIntColumn(statement: statement, index: 4),
                    contextHash: optionalTextColumn(statement: statement, index: 5),
                    usedWriteTools: try requiredBoolColumn(statement: statement, index: 6, table: table, name: "usedWriteTools"),
                    sourceModelName: optionalTextColumn(statement: statement, index: 7),
                    sourceBookInitials: optionalTextColumn(statement: statement, index: 8),
                    sourceBookKey: optionalTextColumn(statement: statement, index: 9)
                )
            )
        }
        return rows
    }

    private func uuidFromBlob(statement: OpaquePointer?, column: Int32, table: String, name: String) throws -> UUID {
        guard
            let bytes = sqlite3_column_blob(statement, column),
            sqlite3_column_bytes(statement, column) == 16
        else {
            throw RemoteSyncMyDocumentRestoreError.invalidIdentifierBlob(table: table, column: name)
        }

        let data = Data(bytes: bytes, count: 16)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let part1 = String(hex[hex.startIndex..<hex.index(hex.startIndex, offsetBy: 8)])
        let part2Start = hex.index(hex.startIndex, offsetBy: 8)
        let part2End = hex.index(part2Start, offsetBy: 4)
        let part2 = String(hex[part2Start..<part2End])
        let part3End = hex.index(part2End, offsetBy: 4)
        let part3 = String(hex[part2End..<part3End])
        let part4End = hex.index(part3End, offsetBy: 4)
        let part4 = String(hex[part3End..<part4End])
        let part5 = String(hex[part4End..<hex.endIndex])
        let uuidString = "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)"

        guard let uuid = UUID(uuidString: uuidString) else {
            throw RemoteSyncMyDocumentRestoreError.invalidIdentifierBlob(table: table, column: name)
        }
        return uuid
    }

    private func optionalUUIDFromBlob(statement: OpaquePointer?, column: Int32, table: String, name: String) throws -> UUID? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL {
            return nil
        }
        return try uuidFromBlob(statement: statement, column: column, table: table, name: name)
    }

    private func requiredTextColumn(
        statement: OpaquePointer?,
        index: Int32,
        table: String,
        name: String
    ) throws -> String {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, index) else {
            throw RemoteSyncMyDocumentRestoreError.invalidColumnValue(table: table, column: name)
        }
        return String(cString: raw)
    }

    private func optionalTextColumn(statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: raw)
    }

    private func optionalIntColumn(statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int(statement, index))
    }

    private func requiredIntColumn(
        statement: OpaquePointer?,
        index: Int32,
        table: String,
        name: String
    ) throws -> Int {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            throw RemoteSyncMyDocumentRestoreError.invalidColumnValue(table: table, column: name)
        }
        return Int(sqlite3_column_int(statement, index))
    }

    private func requiredInt64Column(
        statement: OpaquePointer?,
        index: Int32,
        table: String,
        name: String
    ) throws -> Int64 {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            throw RemoteSyncMyDocumentRestoreError.invalidColumnValue(table: table, column: name)
        }
        return sqlite3_column_int64(statement, index)
    }

    private func requiredBoolColumn(
        statement: OpaquePointer?,
        index: Int32,
        table: String,
        name: String
    ) throws -> Bool {
        try requiredIntColumn(statement: statement, index: index, table: table, name: name) != 0
    }

    private func requiredDateColumn(
        statement: OpaquePointer?,
        index: Int32,
        table: String,
        name: String
    ) throws -> Date {
        let milliseconds = try requiredInt64Column(statement: statement, index: index, table: table, name: name)
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000.0)
    }
}
