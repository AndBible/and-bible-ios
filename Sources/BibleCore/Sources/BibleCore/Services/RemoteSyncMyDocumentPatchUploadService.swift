// RemoteSyncMyDocumentPatchUploadService.swift -- Android-shaped outbound My Documents patch creation and upload

import Foundation
import SQLite3
import SwiftData

private let remoteSyncMyDocumentPatchUploadSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while exporting and uploading an outbound Android My Documents patch.
 */
public enum RemoteSyncMyDocumentPatchUploadError: Error, Equatable {
    /// The category is not ready for upload because no remote device folder identifier is known locally.
    case missingDeviceFolderID

    /// The generated temporary SQLite patch database could not be opened for writing.
    case invalidSQLiteDatabase
}

/**
 Summary of one successful outbound My Documents patch upload.
 */
public struct RemoteSyncMyDocumentPatchUploadReport: Sendable, Equatable {
    /// Remote file metadata returned by the backend after upload succeeded.
    public let uploadedFile: RemoteSyncFile

    /// Monotonic patch number assigned within the current device folder.
    public let patchNumber: Int64

    /// Number of `MyDocument` rows written into the patch database.
    public let upsertedDocumentCount: Int

    /// Number of `MyDocumentPage` rows written into the patch database.
    public let upsertedPageCount: Int

    /// Number of `MyDocumentPageContent` rows written into the patch database.
    public let upsertedPageContentCount: Int

    /// Number of `AiPageCacheEntry` rows written into the patch database.
    public let upsertedAiPageCacheEntryCount: Int

    /// Number of `DELETE` log entries emitted for rows removed locally.
    public let deletedRowCount: Int

    /// Total number of Android `LogEntry` rows written into the patch database.
    public let logEntryCount: Int

    /// Millisecond timestamp recorded as `lastUpdated` for the emitted Android log entries.
    public let lastUpdated: Int64

    /**
     Creates one outbound My Documents patch-upload summary.
     */
    public init(
        uploadedFile: RemoteSyncFile,
        patchNumber: Int64,
        upsertedDocumentCount: Int,
        upsertedPageCount: Int,
        upsertedPageContentCount: Int,
        upsertedAiPageCacheEntryCount: Int,
        deletedRowCount: Int,
        logEntryCount: Int,
        lastUpdated: Int64
    ) {
        self.uploadedFile = uploadedFile
        self.patchNumber = patchNumber
        self.upsertedDocumentCount = upsertedDocumentCount
        self.upsertedPageCount = upsertedPageCount
        self.upsertedPageContentCount = upsertedPageContentCount
        self.upsertedAiPageCacheEntryCount = upsertedAiPageCacheEntryCount
        self.deletedRowCount = deletedRowCount
        self.logEntryCount = logEntryCount
        self.lastUpdated = lastUpdated
    }
}

/**
 Creates Android-shaped sparse My Documents patch databases and uploads them to the active backend.
 */
public final class RemoteSyncMyDocumentPatchUploadService {
    private struct ChangeSet {
        let documentRowsByKey: [String: RemoteSyncAndroidMyDocument]
        let pageRowsByKey: [String: RemoteSyncAndroidMyDocumentPage]
        let pageContentRowsByKey: [String: RemoteSyncAndroidMyDocumentPageContent]
        let aiPageCacheEntryRowsByKey: [String: RemoteSyncAndroidAiPageCacheEntry]
        let logEntries: [RemoteSyncLogEntry]
        let updatedEntriesByKey: [String: RemoteSyncLogEntry]

        var deletedRowCount: Int {
            logEntries.filter { $0.type == .delete }.count
        }
    }

    private static let supportedTableNames: Set<String> = [
        "MyDocument",
        "MyDocumentPage",
        "MyDocumentPageContent",
        "AiPageCacheEntry",
    ]

    private let adapter: any RemoteSyncAdapting
    private let snapshotService: RemoteSyncMyDocumentSnapshotService
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let nowProvider: () -> Int64

    /**
     Creates a My Documents patch upload service for one remote backend.
     */
    public init(
        adapter: any RemoteSyncAdapting,
        snapshotService: RemoteSyncMyDocumentSnapshotService = RemoteSyncMyDocumentSnapshotService(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        nowProvider: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000.0)
        }
    ) {
        self.adapter = adapter
        self.snapshotService = snapshotService
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.nowProvider = nowProvider
    }

    /**
     Builds and uploads the next sparse My Documents patch when local state differs from the baseline.
     */
    public func uploadPendingPatch(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion
    ) async throws -> RemoteSyncMyDocumentPatchUploadReport? {
        guard let deviceFolderID = bootstrapState.deviceFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceFolderID.isEmpty else {
            throw RemoteSyncMyDocumentPatchUploadError.missingDeviceFolderID
        }

        let sourceDevice = Self.sourceDeviceName(from: deviceFolderID)
        let timestamp = nowProvider()
        let snapshot = snapshotService.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let existingEntriesByKey = Dictionary(
            uniqueKeysWithValues: logEntryStore.entries(for: .myDocuments).map {
                (logEntryStore.key(for: .myDocuments, entry: $0), $0)
            }
        )

        let hadMissingFingerprintBaseline = existingEntriesByKey.contains { key, entry in
            guard Self.supportedTableNames.contains(entry.tableName),
                  entry.type != .delete,
                  currentRowExists(forKey: key, in: snapshot) else {
                return false
            }
            return fingerprintStore.fingerprint(
                for: .myDocuments,
                tableName: entry.tableName,
                entityID1: entry.entityID1,
                entityID2: entry.entityID2
            ) == nil
        }

        let changeSet = buildChangeSet(
            snapshot: snapshot,
            existingEntriesByKey: existingEntriesByKey,
            fingerprintStore: fingerprintStore,
            timestamp: timestamp,
            sourceDevice: sourceDevice
        )

        if changeSet.logEntries.isEmpty {
            if hadMissingFingerprintBaseline {
                snapshotService.refreshBaselineFingerprints(
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            }
            return nil
        }

        let patchNumber = (patchStatusStore.lastPatchNumber(
            for: .myDocuments,
            sourceDevice: sourceDevice
        ) ?? 0) + 1
        let patchFileName = "\(patchNumber).\(schemaVersion).sqlite3.gz"

        let databaseURL = temporaryURL(prefix: "remote-sync-mydocuments-upload-", suffix: ".sqlite3")
        let archiveURL = temporaryURL(prefix: "remote-sync-mydocuments-upload-", suffix: ".sqlite3.gz")
        defer {
            try? fileManager.removeItem(at: databaseURL)
            try? fileManager.removeItem(at: archiveURL)
        }

        try writePatchDatabase(
            at: databaseURL,
            schemaVersion: schemaVersion,
            changeSet: changeSet
        )
        let archiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: databaseURL))
        try archiveData.write(to: archiveURL, options: .atomic)

        let uploadedFile = try await adapter.upload(
            name: patchFileName,
            fileURL: archiveURL,
            parentID: deviceFolderID,
            contentType: NextCloudSyncAdapter.gzipMimeType
        )

        logEntryStore.replaceEntries(
            changeSet.updatedEntriesByKey.values.sorted(by: Self.logEntrySort),
            for: .myDocuments
        )
        patchStatusStore.addStatus(
            RemoteSyncPatchStatus(
                sourceDevice: sourceDevice,
                patchNumber: patchNumber,
                sizeBytes: uploadedFile.size,
                appliedDate: timestamp
            ),
            for: .myDocuments
        )
        var progressState = stateStore.progressState(for: .myDocuments)
        progressState.lastPatchWritten = timestamp
        stateStore.setProgressState(progressState, for: .myDocuments)
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        return RemoteSyncMyDocumentPatchUploadReport(
            uploadedFile: uploadedFile,
            patchNumber: patchNumber,
            upsertedDocumentCount: changeSet.documentRowsByKey.count,
            upsertedPageCount: changeSet.pageRowsByKey.count,
            upsertedPageContentCount: changeSet.pageContentRowsByKey.count,
            upsertedAiPageCacheEntryCount: changeSet.aiPageCacheEntryRowsByKey.count,
            deletedRowCount: changeSet.deletedRowCount,
            logEntryCount: changeSet.logEntries.count,
            lastUpdated: timestamp
        )
    }

    private func buildChangeSet(
        snapshot: RemoteSyncMyDocumentCurrentSnapshot,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore,
        timestamp: Int64,
        sourceDevice: String
    ) -> ChangeSet {
        var documentRowsByKey: [String: RemoteSyncAndroidMyDocument] = [:]
        var pageRowsByKey: [String: RemoteSyncAndroidMyDocumentPage] = [:]
        var pageContentRowsByKey: [String: RemoteSyncAndroidMyDocumentPageContent] = [:]
        var aiPageCacheEntryRowsByKey: [String: RemoteSyncAndroidAiPageCacheEntry] = [:]
        var logEntries: [RemoteSyncLogEntry] = []
        var updatedEntriesByKey = existingEntriesByKey

        for (key, row) in snapshot.documentRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "MyDocument",
                entityID1: .blob(RemoteSyncMyDocumentSnapshotService.uuidBlob(row.id)),
                entityID2: RemoteSyncMyDocumentSnapshotService.emptySecondaryEntityID,
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            documentRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.pageRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "MyDocumentPage",
                entityID1: .blob(RemoteSyncMyDocumentSnapshotService.uuidBlob(row.id)),
                entityID2: RemoteSyncMyDocumentSnapshotService.emptySecondaryEntityID,
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            pageRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.pageContentRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "MyDocumentPageContent",
                entityID1: .blob(RemoteSyncMyDocumentSnapshotService.uuidBlob(row.pageId)),
                entityID2: RemoteSyncMyDocumentSnapshotService.emptySecondaryEntityID,
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            pageContentRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.aiPageCacheEntryRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "AiPageCacheEntry",
                entityID1: .blob(RemoteSyncMyDocumentSnapshotService.uuidBlob(row.pageId)),
                entityID2: RemoteSyncMyDocumentSnapshotService.emptySecondaryEntityID,
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            aiPageCacheEntryRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, entry) in existingEntriesByKey.sorted(by: { $0.key < $1.key }) {
            guard Self.supportedTableNames.contains(entry.tableName), entry.type != .delete else {
                continue
            }
            guard !currentRowExists(forKey: key, in: snapshot) else {
                continue
            }
            let deleteEntry = RemoteSyncLogEntry(
                tableName: entry.tableName,
                entityID1: entry.entityID1,
                entityID2: entry.entityID2,
                type: .delete,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            logEntries.append(deleteEntry)
            updatedEntriesByKey[key] = deleteEntry
        }

        return ChangeSet(
            documentRowsByKey: documentRowsByKey,
            pageRowsByKey: pageRowsByKey,
            pageContentRowsByKey: pageContentRowsByKey,
            aiPageCacheEntryRowsByKey: aiPageCacheEntryRowsByKey,
            logEntries: logEntries.sorted(by: Self.logEntrySort),
            updatedEntriesByKey: updatedEntriesByKey
        )
    }

    private func shouldUploadCurrentRow(
        key: String,
        currentFingerprint: String?,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore
    ) -> Bool {
        guard let currentFingerprint else {
            return false
        }

        guard let existingEntry = existingEntriesByKey[key] else {
            if let existingFingerprint = fingerprintStore.fingerprint(
                forLogKey: key,
                category: .myDocuments
            ) {
                return existingFingerprint != currentFingerprint
            }
            return true
        }

        guard Self.supportedTableNames.contains(existingEntry.tableName) else {
            return false
        }

        if existingEntry.type == .delete {
            return true
        }

        let existingFingerprint = fingerprintStore.fingerprint(
            for: .myDocuments,
            tableName: existingEntry.tableName,
            entityID1: existingEntry.entityID1,
            entityID2: existingEntry.entityID2
        )
        guard let existingFingerprint else {
            return true
        }
        return existingFingerprint != currentFingerprint
    }

    private func currentRowExists(forKey key: String, in snapshot: RemoteSyncMyDocumentCurrentSnapshot) -> Bool {
        snapshot.documentRowsByKey[key] != nil
            || snapshot.pageRowsByKey[key] != nil
            || snapshot.pageContentRowsByKey[key] != nil
            || snapshot.aiPageCacheEntryRowsByKey[key] != nil
    }

    private func writePatchDatabase(
        at url: URL,
        schemaVersion: Int,
        changeSet: ChangeSet
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        try execute(
            """
            PRAGMA user_version = \(schemaVersion);
            CREATE TABLE MyDocument (
                id BLOB NOT NULL PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT DEFAULT NULL,
                initials TEXT NOT NULL,
                orderNumber INTEGER NOT NULL,
                createdAt INTEGER NOT NULL,
                updatedAt INTEGER NOT NULL,
                sourcePromptId BLOB DEFAULT NULL
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
                sourcePromptId BLOB DEFAULT NULL,
                languageCode TEXT DEFAULT NULL,
                FOREIGN KEY(documentId) REFERENCES MyDocument(id) ON DELETE CASCADE
            );
            CREATE TABLE MyDocumentPageContent (
                pageId BLOB NOT NULL PRIMARY KEY,
                content TEXT NOT NULL,
                FOREIGN KEY(pageId) REFERENCES MyDocumentPage(id) ON DELETE CASCADE
            );
            CREATE TABLE AiPageCacheEntry (
                pageId BLOB NOT NULL PRIMARY KEY,
                sourcePromptId BLOB NOT NULL,
                sourceContext TEXT DEFAULT NULL,
                kjvOrdinalStart INTEGER DEFAULT NULL,
                kjvOrdinalEnd INTEGER DEFAULT NULL,
                contextHash TEXT DEFAULT NULL,
                usedWriteTools INTEGER NOT NULL,
                sourceModelName TEXT DEFAULT NULL,
                sourceBookInitials TEXT DEFAULT NULL,
                sourceBookKey TEXT DEFAULT NULL,
                FOREIGN KEY(pageId) REFERENCES MyDocumentPage(id) ON DELETE CASCADE
            );
            CREATE TABLE LogEntry (
                tableName TEXT NOT NULL,
                entityId1 BLOB NOT NULL,
                entityId2 BLOB NOT NULL,
                type TEXT NOT NULL,
                lastUpdated INTEGER NOT NULL,
                sourceDevice TEXT NOT NULL,
                PRIMARY KEY(tableName, entityId1, entityId2)
            );
            CREATE TABLE SyncConfiguration (
                keyName TEXT NOT NULL,
                stringValue TEXT,
                longValue INTEGER,
                booleanValue INTEGER,
                PRIMARY KEY(keyName)
            );
            CREATE TABLE SyncStatus (
                sourceDevice TEXT NOT NULL,
                patchNumber INTEGER NOT NULL,
                sizeBytes INTEGER NOT NULL,
                appliedDate INTEGER NOT NULL,
                PRIMARY KEY(sourceDevice, patchNumber)
            );
            CREATE TABLE room_master_table (
                id INTEGER PRIMARY KEY,
                identity_hash TEXT
            );
            INSERT OR REPLACE INTO room_master_table (id, identity_hash)
                VALUES(42, '3f0946602099d896c8d47129233c1794');
            CREATE UNIQUE INDEX index_MyDocument_initials ON MyDocument (initials);
            CREATE INDEX index_MyDocumentPage_documentId ON MyDocumentPage (documentId);
            CREATE UNIQUE INDEX index_MyDocumentPage_documentId_pageKey ON MyDocumentPage (documentId, pageKey);
            CREATE INDEX index_AiPageCacheEntry_sourcePromptId_contextHash ON AiPageCacheEntry (sourcePromptId, contextHash);
            CREATE INDEX index_AiPageCacheEntry_sourcePromptId_kjvOrdinalStart_kjvOrdinalEnd ON AiPageCacheEntry (sourcePromptId, kjvOrdinalStart, kjvOrdinalEnd);
            CREATE INDEX index_AiPageCacheEntry_kjvOrdinalStart_kjvOrdinalEnd ON AiPageCacheEntry (kjvOrdinalStart, kjvOrdinalEnd);
            CREATE INDEX index_AiPageCacheEntry_sourceBookInitials_sourceBookKey ON AiPageCacheEntry (sourceBookInitials, sourceBookKey);
            CREATE INDEX index_LogEntry_lastUpdated ON LogEntry (lastUpdated);
            CREATE INDEX index_LogEntry_sourceDevice ON LogEntry (sourceDevice);
            CREATE VIEW MyDocumentPageWithContent AS
                SELECT p.*, c.content
                FROM MyDocumentPage p
                LEFT OUTER JOIN MyDocumentPageContent c ON p.id = c.pageId;
            CREATE VIEW AiCachedPageWithContent AS
                SELECT c.pageId, c.sourcePromptId, c.sourceContext, c.kjvOrdinalStart,
                       c.kjvOrdinalEnd, c.contextHash, c.usedWriteTools, c.sourceModelName,
                       c.sourceBookInitials, c.sourceBookKey,
                       p.title, p.pageKey, p.contentType, p.documentId,
                       p.orderNumber, p.createdAt, p.updatedAt, p.languageCode, cnt.content
                FROM AiPageCacheEntry c
                INNER JOIN MyDocumentPage p ON c.pageId = p.id
                LEFT OUTER JOIN MyDocumentPageContent cnt ON p.id = cnt.pageId;
            """,
            in: database
        )

        try execute("BEGIN IMMEDIATE TRANSACTION;", in: database)
        do {
            for row in changeSet.documentRowsByKey.values.sorted(by: Self.myDocumentSort) {
                try insertMyDocumentRow(row, in: database)
            }
            for row in changeSet.pageRowsByKey.values.sorted(by: Self.myDocumentPageSort) {
                try insertMyDocumentPageRow(row, in: database)
            }
            for row in changeSet.pageContentRowsByKey.values.sorted(by: Self.myDocumentPageContentSort) {
                try insertMyDocumentPageContentRow(row, in: database)
            }
            for row in changeSet.aiPageCacheEntryRowsByKey.values.sorted(by: Self.aiPageCacheEntrySort) {
                try insertAiPageCacheEntryRow(row, in: database)
            }
            for entry in changeSet.logEntries {
                try insertLogEntry(entry, in: database)
            }
            try execute("COMMIT;", in: database)
        } catch {
            try? execute("ROLLBACK;", in: database)
            throw error
        }
    }

    private func insertMyDocumentRow(_ row: RemoteSyncAndroidMyDocument, in database: OpaquePointer) throws {
        let sql = "INSERT INTO MyDocument (id, name, description, initials, orderNumber, createdAt, updatedAt, sourcePromptId) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.id, to: statement, index: 1)
        Self.bindText(row.name, to: statement, index: 2)
        Self.bindOptionalText(row.documentDescription, to: statement, index: 3)
        Self.bindText(row.initials, to: statement, index: 4)
        sqlite3_bind_int(statement, 5, Int32(row.orderNumber))
        sqlite3_bind_int64(statement, 6, Int64(row.createdAt.timeIntervalSince1970 * 1000.0))
        sqlite3_bind_int64(statement, 7, Int64(row.updatedAt.timeIntervalSince1970 * 1000.0))
        Self.bindOptionalUUIDBlob(row.sourcePromptId, to: statement, index: 8)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
    }

    private func insertMyDocumentPageRow(_ row: RemoteSyncAndroidMyDocumentPage, in database: OpaquePointer) throws {
        let sql = "INSERT INTO MyDocumentPage (id, documentId, title, pageKey, contentType, orderNumber, createdAt, updatedAt, sourcePromptId, languageCode) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.id, to: statement, index: 1)
        Self.bindUUIDBlob(row.documentId, to: statement, index: 2)
        Self.bindText(row.title, to: statement, index: 3)
        Self.bindText(row.pageKey, to: statement, index: 4)
        Self.bindText(row.contentType.rawValue, to: statement, index: 5)
        sqlite3_bind_int(statement, 6, Int32(row.orderNumber))
        sqlite3_bind_int64(statement, 7, Int64(row.createdAt.timeIntervalSince1970 * 1000.0))
        sqlite3_bind_int64(statement, 8, Int64(row.updatedAt.timeIntervalSince1970 * 1000.0))
        Self.bindOptionalUUIDBlob(row.sourcePromptId, to: statement, index: 9)
        Self.bindOptionalText(row.languageCode, to: statement, index: 10)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
    }

    private func insertMyDocumentPageContentRow(
        _ row: RemoteSyncAndroidMyDocumentPageContent,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO MyDocumentPageContent (pageId, content) VALUES (?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.pageId, to: statement, index: 1)
        Self.bindText(row.content, to: statement, index: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
    }

    private func insertAiPageCacheEntryRow(
        _ row: RemoteSyncAndroidAiPageCacheEntry,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO AiPageCacheEntry (pageId, sourcePromptId, sourceContext, kjvOrdinalStart, kjvOrdinalEnd, contextHash, usedWriteTools, sourceModelName, sourceBookInitials, sourceBookKey) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.pageId, to: statement, index: 1)
        Self.bindUUIDBlob(row.sourcePromptId, to: statement, index: 2)
        Self.bindOptionalText(row.sourceContext, to: statement, index: 3)
        Self.bindOptionalInt(row.kjvOrdinalStart, to: statement, index: 4)
        Self.bindOptionalInt(row.kjvOrdinalEnd, to: statement, index: 5)
        Self.bindOptionalText(row.contextHash, to: statement, index: 6)
        Self.bindBool(row.usedWriteTools, to: statement, index: 7)
        Self.bindOptionalText(row.sourceModelName, to: statement, index: 8)
        Self.bindOptionalText(row.sourceBookInitials, to: statement, index: 9)
        Self.bindOptionalText(row.sourceBookKey, to: statement, index: 10)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
    }

    private func insertLogEntry(_ entry: RemoteSyncLogEntry, in database: OpaquePointer) throws {
        let sql = "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindText(entry.tableName, to: statement, index: 1)
        Self.bindSQLiteValue(entry.entityID1, to: statement, index: 2)
        Self.bindSQLiteValue(entry.entityID2, to: statement, index: 3)
        Self.bindText(entry.type.rawValue, to: statement, index: 4)
        sqlite3_bind_int64(statement, 5, entry.lastUpdated)
        Self.bindText(entry.sourceDevice, to: statement, index: 6)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
    }

    private func temporaryURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    private static func sourceDeviceName(from deviceFolderID: String) -> String {
        let trimmed = deviceFolderID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? deviceFolderID
    }

    private static func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, remoteSyncMyDocumentPatchUploadSQLiteTransient)
    }

    private static func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindText(value, to: statement, index: index)
    }

    private static func bindBool(_ value: Bool, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_int(statement, index, value ? 1 : 0)
    }

    private static func bindOptionalInt(_ value: Int?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private static func bindUUIDBlob(_ value: UUID, to statement: OpaquePointer?, index: Int32) {
        let blob = RemoteSyncMyDocumentSnapshotService.uuidBlob(value)
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(blob.count),
                remoteSyncMyDocumentPatchUploadSQLiteTransient
            )
        }
    }

    private static func bindOptionalUUIDBlob(_ value: UUID?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindUUIDBlob(value, to: statement, index: index)
    }

    private static func bindSQLiteValue(
        _ value: RemoteSyncSQLiteValue,
        to statement: OpaquePointer?,
        index: Int32
    ) {
        switch value.kind {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer:
            sqlite3_bind_int64(statement, index, value.integerValue ?? 0)
        case .real:
            sqlite3_bind_double(statement, index, value.realValue ?? 0)
        case .text:
            sqlite3_bind_text(statement, index, value.textValue ?? "", -1, remoteSyncMyDocumentPatchUploadSQLiteTransient)
        case .blob:
            let data = value.blobData ?? Data()
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement,
                    index,
                    bytes.baseAddress,
                    Int32(data.count),
                    remoteSyncMyDocumentPatchUploadSQLiteTransient
                )
            }
        }
    }

    private static func logEntrySort(_ lhs: RemoteSyncLogEntry, _ rhs: RemoteSyncLogEntry) -> Bool {
        if lhs.lastUpdated != rhs.lastUpdated {
            return lhs.lastUpdated < rhs.lastUpdated
        }
        if lhs.tableName != rhs.tableName {
            return lhs.tableName < rhs.tableName
        }
        if lhs.type != rhs.type {
            return lhs.type.rawValue < rhs.type.rawValue
        }
        if lhs.sourceDevice != rhs.sourceDevice {
            return lhs.sourceDevice < rhs.sourceDevice
        }
        if lhs.entityID1 != rhs.entityID1 {
            return sortKey(for: lhs.entityID1) < sortKey(for: rhs.entityID1)
        }
        return sortKey(for: lhs.entityID2) < sortKey(for: rhs.entityID2)
    }

    private static func sortKey(for value: RemoteSyncSQLiteValue) -> String {
        switch value.kind {
        case .null:
            return "null"
        case .integer:
            return "integer:\(value.integerValue ?? 0)"
        case .real:
            return "real:\(value.realValue?.bitPattern ?? 0)"
        case .text:
            return "text:\(value.textValue ?? "")"
        case .blob:
            return "blob:\(value.blobBase64Value ?? "")"
        }
    }

    private static func myDocumentSort(_ lhs: RemoteSyncAndroidMyDocument, _ rhs: RemoteSyncAndroidMyDocument) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            if lhs.name == rhs.name {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.name < rhs.name
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    private static func myDocumentPageSort(_ lhs: RemoteSyncAndroidMyDocumentPage, _ rhs: RemoteSyncAndroidMyDocumentPage) -> Bool {
        if lhs.documentId == rhs.documentId {
            if lhs.orderNumber == rhs.orderNumber {
                if lhs.title == rhs.title {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.title < rhs.title
            }
            return lhs.orderNumber < rhs.orderNumber
        }
        return lhs.documentId.uuidString < rhs.documentId.uuidString
    }

    private static func myDocumentPageContentSort(
        _ lhs: RemoteSyncAndroidMyDocumentPageContent,
        _ rhs: RemoteSyncAndroidMyDocumentPageContent
    ) -> Bool {
        lhs.pageId.uuidString < rhs.pageId.uuidString
    }

    private static func aiPageCacheEntrySort(
        _ lhs: RemoteSyncAndroidAiPageCacheEntry,
        _ rhs: RemoteSyncAndroidAiPageCacheEntry
    ) -> Bool {
        lhs.pageId.uuidString < rhs.pageId.uuidString
    }
}
