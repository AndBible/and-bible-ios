// RemoteSyncMyDocumentRestoreTests.swift -- Android My Documents initial-backup restore tests

import XCTest
import SQLite3
import SwiftData
@testable import BibleCore

private let myDocumentRestoreSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class RemoteSyncMyDocumentRestoreTests: XCTestCase {
    func testRemoteSyncMyDocumentRestoreReplacesLocalGraphAndPreservesAIContext() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let store = MyDocumentStore(modelContext: modelContext)
        modelContext.insert(MyDocument(name: "Legacy", initials: "LEGACY"))
        try modelContext.save()

        let documentID = UUID(uuidString: "a1000000-0000-0000-0000-000000000001")!
        let pageID = UUID(uuidString: "a1000000-0000-0000-0000-000000000011")!
        let promptID = UUID(uuidString: "a1000000-0000-0000-0000-000000000021")!
        let createdAt = Date(timeIntervalSince1970: 1_735_689_600)
        let updatedAt = Date(timeIntervalSince1970: 1_735_689_660)
        let databaseURL = try makeAndroidMyDocumentsDatabase(
            documents: [
                .init(
                    id: documentID,
                    name: "Android Document",
                    documentDescription: "Imported",
                    initials: "MYDOC",
                    orderNumber: 2,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    sourcePromptId: nil
                )
            ],
            pages: [
                .init(
                    id: pageID,
                    documentId: documentID,
                    title: "Intro",
                    pageKey: "intro",
                    contentType: .markdown,
                    orderNumber: 1,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    sourcePromptId: promptID,
                    languageCode: "en"
                )
            ],
            pageContents: [
                .init(pageId: pageID, content: "Restored **markdown**")
            ],
            aiPageCacheEntries: [
                .init(
                    pageId: pageID,
                    sourcePromptId: promptID,
                    sourceContext: #"{"osisRef":"Gen.1"}"#,
                    kjvOrdinalStart: 1,
                    kjvOrdinalEnd: 31,
                    contextHash: "ctx-hash",
                    usedWriteTools: true,
                    sourceModelName: "gpt-test",
                    sourceBookInitials: "KJV",
                    sourceBookKey: "Gen.1"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = RemoteSyncMyDocumentRestoreService()
        let snapshot = try service.readSnapshot(from: databaseURL)
        let report = try service.replaceLocalMyDocuments(from: snapshot, modelContext: modelContext)

        XCTAssertEqual(
            report,
            .init(
                restoredDocumentCount: 1,
                restoredPageCount: 1,
                restoredContentCount: 1,
                restoredAIPageCacheEntryCount: 1
            )
        )
        XCTAssertNil(store.document(initials: "LEGACY"))

        let payload = try XCTUnwrap(store.rawContentPayload(bookInitials: "MYDOC", pageKey: "intro"))
        XCTAssertEqual(payload.pageId, pageID.uuidString)
        XCTAssertEqual(payload.contentType, "MARKDOWN")
        XCTAssertEqual(payload.content, "Restored **markdown**")
        XCTAssertEqual(payload.title, "Intro")
        XCTAssertEqual(payload.sourcePromptId, promptID.uuidString)

        let actionContext = try XCTUnwrap(store.aiPageActionContext(pageId: pageID))
        XCTAssertEqual(actionContext.documentId, documentID)
        XCTAssertEqual(actionContext.sourcePromptId, promptID)
        XCTAssertEqual(actionContext.sourceContext, #"{"osisRef":"Gen.1"}"#)
        XCTAssertEqual(actionContext.kjvOrdinalStart, 1)
        XCTAssertEqual(actionContext.kjvOrdinalEnd, 31)
        XCTAssertEqual(actionContext.contextHash, "ctx-hash")
        XCTAssertTrue(actionContext.usedWriteTools)
        XCTAssertEqual(actionContext.sourceModelName, "gpt-test")
        XCTAssertEqual(actionContext.sourceBookInitials, "KJV")
        XCTAssertEqual(actionContext.sourceBookKey, "Gen.1")

        let documents = try modelContext.fetch(FetchDescriptor<MyDocument>())
        XCTAssertEqual(documents.map(\.id), [documentID])
        XCTAssertEqual(documents[0].createdAt, createdAt)
        XCTAssertEqual(documents[0].updatedAt, updatedAt)
    }

    func testRemoteSyncMyDocumentRestoreRejectsOrphansWithoutMutation() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let existingDocument = MyDocument(name: "Existing", initials: "EXISTING")
        modelContext.insert(existingDocument)
        try modelContext.save()

        let orphanPageID = UUID(uuidString: "b1000000-0000-0000-0000-000000000011")!
        let missingDocumentID = UUID(uuidString: "b1000000-0000-0000-0000-000000000099")!
        let databaseURL = try makeAndroidMyDocumentsDatabase(
            documents: [],
            pages: [
                .init(
                    id: orphanPageID,
                    documentId: missingDocumentID,
                    title: "Orphan",
                    pageKey: "orphan",
                    contentType: .markdown
                )
            ],
            pageContents: [],
            aiPageCacheEntries: []
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = RemoteSyncMyDocumentRestoreService()
        let snapshot = try service.readSnapshot(from: databaseURL)
        XCTAssertThrowsError(
            try service.replaceLocalMyDocuments(from: snapshot, modelContext: modelContext)
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncMyDocumentRestoreError,
                .orphanReferences([
                    "MyDocumentPage.id=\(orphanPageID.uuidString) missing MyDocument"
                ])
            )
        }

        let documents = try modelContext.fetch(FetchDescriptor<MyDocument>())
        XCTAssertEqual(documents.map(\.initials), ["EXISTING"])
    }

    func testRemoteSyncMyDocumentRestoreRejectsMalformedContentType() throws {
        let documentID = UUID(uuidString: "d1000000-0000-0000-0000-000000000001")!
        let pageID = UUID(uuidString: "d1000000-0000-0000-0000-000000000011")!
        let databaseURL = try makeAndroidMyDocumentsDatabase(
            documents: [
                .init(id: documentID, name: "Malformed", initials: "BAD")
            ],
            pages: [
                .init(
                    id: pageID,
                    documentId: documentID,
                    title: "Malformed Page",
                    pageKey: "bad",
                    contentTypeRawValue: "PDF"
                )
            ],
            pageContents: [],
            aiPageCacheEntries: []
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = RemoteSyncMyDocumentRestoreService()
        XCTAssertThrowsError(try service.readSnapshot(from: databaseURL)) { error in
            XCTAssertEqual(
                error as? RemoteSyncMyDocumentRestoreError,
                .invalidColumnValue(table: "MyDocumentPage", column: "contentType")
            )
        }
    }

    func testRemoteSyncInitialBackupRestoreDispatchesMyDocumentBackups() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let dispatcher = RemoteSyncInitialBackupRestoreService()
        let documentID = UUID(uuidString: "c1000000-0000-0000-0000-000000000001")!
        let pageID = UUID(uuidString: "c1000000-0000-0000-0000-000000000011")!
        let promptID = UUID(uuidString: "c1000000-0000-0000-0000-000000000021")!
        let logEntry = RemoteSyncLogEntry(
            tableName: "MyDocument",
            entityID1: .blob(uuidBlob(documentID)),
            entityID2: .text(""),
            type: .upsert,
            lastUpdated: 1_735_689_600_000,
            sourceDevice: "pixel"
        )
        let patchStatus = RemoteSyncPatchStatus(
            sourceDevice: "pixel",
            patchNumber: 3,
            sizeBytes: 2_048,
            appliedDate: 1_735_689_650_000
        )
        let databaseURL = try makeAndroidMyDocumentsDatabase(
            documents: [
                .init(id: documentID, name: "Dispatch", initials: "DISP")
            ],
            pages: [
                .init(
                    id: pageID,
                    documentId: documentID,
                    title: "Dispatch Page",
                    pageKey: "dispatch",
                    contentType: .html,
                    sourcePromptId: promptID
                )
            ],
            pageContents: [
                .init(pageId: pageID, content: "<p>Dispatch</p>")
            ],
            aiPageCacheEntries: [
                .init(pageId: pageID, sourcePromptId: promptID)
            ],
            logEntries: [logEntry],
            syncStatuses: [patchStatus]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let report = try dispatcher.restoreInitialBackup(
            RemoteSyncStagedInitialBackup(
                remoteFile: RemoteSyncFile(
                    id: "/org.andbible.ios-sync-mydocuments/initial.sqlite3.gz",
                    name: "initial.sqlite3.gz",
                    size: 4_096,
                    timestamp: 1_735_689_600_000,
                    parentID: "/org.andbible.ios-sync-mydocuments",
                    mimeType: "application/gzip"
                ),
                databaseFileURL: databaseURL,
                schemaVersion: 4
            ),
            category: .myDocuments,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(
            report,
            .myDocuments(
                .init(
                    restoredDocumentCount: 1,
                    restoredPageCount: 1,
                    restoredContentCount: 1,
                    restoredAIPageCacheEntryCount: 1
                )
            )
        )

        let store = MyDocumentStore(modelContext: modelContext)
        XCTAssertEqual(
            store.rawContentPayload(bookInitials: "DISP", pageKey: "dispatch")?.content,
            "<p>Dispatch</p>"
        )
        XCTAssertEqual(
            RemoteSyncLogEntryStore(settingsStore: settingsStore).entries(for: .myDocuments),
            [logEntry]
        )
        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .myDocuments),
            [patchStatus]
        )
    }

    private func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([
            MyDocument.self,
            MyDocumentPage.self,
            MyDocumentPageContent.self,
            AiPageCacheEntry.self,
            Setting.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeAndroidMyDocumentsDatabase(
        documents: [AndroidMyDocumentRow],
        pages: [AndroidMyDocumentPageRow],
        pageContents: [AndroidMyDocumentPageContentRow],
        aiPageCacheEntries: [AndroidAiPageCacheEntryRow],
        logEntries: [RemoteSyncLogEntry] = [],
        syncStatuses: [RemoteSyncPatchStatus] = [],
        schemaVersion: Int = RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion
    ) throws -> URL {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-mydocuments-\(UUID().uuidString).sqlite3")

        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            XCTFail("Failed to open temporary Android My Documents database")
            throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
        }
        defer { XCTAssertEqual(sqlite3_close(db), SQLITE_OK) }

        let schemaSQL = """
        PRAGMA user_version = \(schemaVersion);
        CREATE TABLE MyDocument (
            id BLOB NOT NULL PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT,
            initials TEXT NOT NULL,
            orderNumber INTEGER NOT NULL,
            createdAt INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL,
            sourcePromptId BLOB
        );
        CREATE TABLE MyDocumentPage (
            id BLOB NOT NULL PRIMARY KEY,
            documentId BLOB NOT NULL,
            title TEXT NOT NULL,
            pageKey TEXT NOT NULL,
            contentType TEXT NOT NULL,
            orderNumber INTEGER NOT NULL,
            createdAt INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL,
            sourcePromptId BLOB,
            languageCode TEXT
        );
        CREATE TABLE MyDocumentPageContent (
            pageId BLOB NOT NULL PRIMARY KEY,
            content TEXT NOT NULL
        );
        CREATE TABLE AiPageCacheEntry (
            pageId BLOB NOT NULL PRIMARY KEY,
            sourcePromptId BLOB NOT NULL,
            sourceContext TEXT,
            kjvOrdinalStart INTEGER,
            kjvOrdinalEnd INTEGER,
            contextHash TEXT,
            usedWriteTools INTEGER NOT NULL,
            sourceModelName TEXT,
            sourceBookInitials TEXT,
            sourceBookKey TEXT
        );
        CREATE TABLE LogEntry (
            tableName TEXT NOT NULL,
            entityId1 BLOB NOT NULL,
            entityId2 BLOB NOT NULL DEFAULT '',
            type TEXT NOT NULL,
            lastUpdated INTEGER NOT NULL,
            sourceDevice TEXT NOT NULL
        );
        CREATE TABLE SyncStatus (
            sourceDevice TEXT NOT NULL,
            patchNumber INTEGER NOT NULL,
            sizeBytes INTEGER NOT NULL,
            appliedDate INTEGER NOT NULL,
            PRIMARY KEY(sourceDevice, patchNumber)
        );
        """
        XCTAssertEqual(sqlite3_exec(db, schemaSQL, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))

        for document in documents {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO MyDocument (id, name, description, initials, orderNumber, createdAt, updatedAt, sourcePromptId) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(document.id, to: statement, index: 1)
            sqlite3_bind_text(statement, 2, document.name, -1, myDocumentRestoreSQLiteTransient)
            bindOptionalText(document.documentDescription, to: statement, index: 3)
            sqlite3_bind_text(statement, 4, document.initials, -1, myDocumentRestoreSQLiteTransient)
            sqlite3_bind_int(statement, 5, Int32(document.orderNumber))
            bindDate(document.createdAt, to: statement, index: 6)
            bindDate(document.updatedAt, to: statement, index: 7)
            bindOptionalUUIDBlob(document.sourcePromptId, to: statement, index: 8)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for page in pages {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO MyDocumentPage (id, documentId, title, pageKey, contentType, orderNumber, createdAt, updatedAt, sourcePromptId, languageCode) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(page.id, to: statement, index: 1)
            bindUUIDBlob(page.documentId, to: statement, index: 2)
            sqlite3_bind_text(statement, 3, page.title, -1, myDocumentRestoreSQLiteTransient)
            sqlite3_bind_text(statement, 4, page.pageKey, -1, myDocumentRestoreSQLiteTransient)
            sqlite3_bind_text(statement, 5, page.contentTypeRawValue ?? page.contentType.rawValue, -1, myDocumentRestoreSQLiteTransient)
            sqlite3_bind_int(statement, 6, Int32(page.orderNumber))
            bindDate(page.createdAt, to: statement, index: 7)
            bindDate(page.updatedAt, to: statement, index: 8)
            bindOptionalUUIDBlob(page.sourcePromptId, to: statement, index: 9)
            bindOptionalText(page.languageCode, to: statement, index: 10)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for content in pageContents {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO MyDocumentPageContent (pageId, content) VALUES (?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(content.pageId, to: statement, index: 1)
            sqlite3_bind_text(statement, 2, content.content, -1, myDocumentRestoreSQLiteTransient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for cacheEntry in aiPageCacheEntries {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO AiPageCacheEntry (pageId, sourcePromptId, sourceContext, kjvOrdinalStart, kjvOrdinalEnd, contextHash, usedWriteTools, sourceModelName, sourceBookInitials, sourceBookKey) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(cacheEntry.pageId, to: statement, index: 1)
            bindUUIDBlob(cacheEntry.sourcePromptId, to: statement, index: 2)
            bindOptionalText(cacheEntry.sourceContext, to: statement, index: 3)
            bindOptionalInt(cacheEntry.kjvOrdinalStart, to: statement, index: 4)
            bindOptionalInt(cacheEntry.kjvOrdinalEnd, to: statement, index: 5)
            bindOptionalText(cacheEntry.contextHash, to: statement, index: 6)
            sqlite3_bind_int(statement, 7, cacheEntry.usedWriteTools ? 1 : 0)
            bindOptionalText(cacheEntry.sourceModelName, to: statement, index: 8)
            bindOptionalText(cacheEntry.sourceBookInitials, to: statement, index: 9)
            bindOptionalText(cacheEntry.sourceBookKey, to: statement, index: 10)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for logEntry in logEntries {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            sqlite3_bind_text(statement, 1, logEntry.tableName, -1, myDocumentRestoreSQLiteTransient)
            bindSQLiteValue(logEntry.entityID1, to: statement, index: 2)
            bindSQLiteValue(logEntry.entityID2, to: statement, index: 3)
            sqlite3_bind_text(statement, 4, logEntry.type.rawValue, -1, myDocumentRestoreSQLiteTransient)
            sqlite3_bind_int64(statement, 5, logEntry.lastUpdated)
            sqlite3_bind_text(statement, 6, logEntry.sourceDevice, -1, myDocumentRestoreSQLiteTransient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for syncStatus in syncStatuses {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO SyncStatus (sourceDevice, patchNumber, sizeBytes, appliedDate) VALUES (?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            sqlite3_bind_text(statement, 1, syncStatus.sourceDevice, -1, myDocumentRestoreSQLiteTransient)
            sqlite3_bind_int64(statement, 2, syncStatus.patchNumber)
            sqlite3_bind_int64(statement, 3, syncStatus.sizeBytes)
            sqlite3_bind_int64(statement, 4, syncStatus.appliedDate)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        return databaseURL
    }

    private struct AndroidMyDocumentRow {
        let id: UUID
        let name: String
        var documentDescription: String? = nil
        let initials: String
        var orderNumber: Int = 0
        var createdAt: Date = Date(timeIntervalSince1970: 1_735_689_600)
        var updatedAt: Date = Date(timeIntervalSince1970: 1_735_689_600)
        var sourcePromptId: UUID? = nil
    }

    private struct AndroidMyDocumentPageRow {
        let id: UUID
        let documentId: UUID
        let title: String
        let pageKey: String
        var contentType: MyDocumentContentType = .markdown
        var contentTypeRawValue: String? = nil
        var orderNumber: Int = 0
        var createdAt: Date = Date(timeIntervalSince1970: 1_735_689_600)
        var updatedAt: Date = Date(timeIntervalSince1970: 1_735_689_600)
        var sourcePromptId: UUID? = nil
        var languageCode: String? = nil
    }

    private struct AndroidMyDocumentPageContentRow {
        let pageId: UUID
        let content: String
    }

    private struct AndroidAiPageCacheEntryRow {
        let pageId: UUID
        let sourcePromptId: UUID
        var sourceContext: String? = nil
        var kjvOrdinalStart: Int? = nil
        var kjvOrdinalEnd: Int? = nil
        var contextHash: String? = nil
        var usedWriteTools: Bool = false
        var sourceModelName: String? = nil
        var sourceBookInitials: String? = nil
        var sourceBookKey: String? = nil
    }

    private func bindUUIDBlob(_ value: UUID, to statement: OpaquePointer?, index: Int32) {
        let blob = uuidBlob(value)
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(blob.count), myDocumentRestoreSQLiteTransient)
        }
    }

    private func bindOptionalUUIDBlob(_ value: UUID?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindUUIDBlob(value, to: statement, index: index)
    }

    private func bindSQLiteValue(_ value: RemoteSyncSQLiteValue, to statement: OpaquePointer?, index: Int32) {
        switch value.kind {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer:
            sqlite3_bind_int64(statement, index, value.integerValue ?? 0)
        case .real:
            sqlite3_bind_double(statement, index, value.realValue ?? 0)
        case .text:
            sqlite3_bind_text(statement, index, value.textValue ?? "", -1, myDocumentRestoreSQLiteTransient)
        case .blob:
            let data = value.blobData ?? Data()
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), myDocumentRestoreSQLiteTransient)
            }
        }
    }

    private func bindDate(_ value: Date, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_int64(statement, index, Int64(value.timeIntervalSince1970 * 1000.0))
    }

    private func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, myDocumentRestoreSQLiteTransient)
    }

    private func bindOptionalInt(_ value: Int?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int(statement, index, Int32(value))
    }

    private func uuidBlob(_ value: UUID) -> Data {
        var uuid = value.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }
}
