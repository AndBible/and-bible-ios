// RemoteSyncMyDocumentPatchApplyService.swift -- Incremental Android patch replay for My Documents

import CLibSword
import Foundation
import SwiftData

/**
 Errors raised while replaying Android My Documents patch archives against the local SwiftData graph.
 */
public enum RemoteSyncMyDocumentPatchApplyError: Error, Equatable {
    /// One Android `LogEntry` identifier could not be converted into the expected UUID row key.
    case invalidLogEntryIdentifier(table: String, field: String)

    /// One `UPSERT` log entry referenced a row that was not present in the staged patch database.
    case missingPatchRow(table: String, id: UUID)
}

/**
 Summary of one successful My Documents patch replay batch.
 */
public struct RemoteSyncMyDocumentPatchApplyReport: Sendable, Equatable {
    /// Number of patch archives successfully evaluated and recorded in patch status, including all-skipped archives.
    public let appliedPatchCount: Int

    /// Number of remote `LogEntry` rows accepted into local metadata, including rows later pruned by foreign-key cleanup.
    public let appliedLogEntryCount: Int

    /// Number of remote `LogEntry` rows skipped because a local row was newer or equal.
    public let skippedLogEntryCount: Int

    /// Final My Documents restore summary produced by the centralized rewrite path.
    public let restoreReport: RemoteSyncMyDocumentRestoreReport

    /**
     Creates one replay summary after a batch has been evaluated.

     - Parameters:
       - appliedPatchCount: Number of patch archives successfully evaluated and recorded in patch status, including archives whose log entries were all skipped.
       - appliedLogEntryCount: Number of newer remote log entries accepted into local metadata. Rows removed by foreign-key cleanup still count here because Android records their log-entry watermarks.
       - skippedLogEntryCount: Number of remote log entries ignored because local metadata was newer or equal.
       - restoreReport: Final My Documents row counts after replay normalization.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        appliedPatchCount: Int,
        appliedLogEntryCount: Int,
        skippedLogEntryCount: Int,
        restoreReport: RemoteSyncMyDocumentRestoreReport
    ) {
        self.appliedPatchCount = appliedPatchCount
        self.appliedLogEntryCount = appliedLogEntryCount
        self.skippedLogEntryCount = skippedLogEntryCount
        self.restoreReport = restoreReport
    }
}

/**
 Replays Android My Documents patch archives into the local SwiftData My Documents graph.

 Android applies `mydocuments` patches by attaching each sparse SQLite archive, replaying newer
 `LogEntry` rows in Android table order, pruning foreign-key violations per table, and recording
 patch status after successful application. This service mirrors that contract without mutating
 SwiftData until the full batch has been evaluated:

 - current local rows are projected into an Android-shaped mutable working snapshot
 - each archive contributes only log entries whose `lastUpdated` value is newer than local metadata
 - accepted `UPSERT` and `DELETE` rows mutate the working snapshot in Android's table order
 - orphan pages, page content, and AI cache rows are pruned before the final snapshot is written
 - the final snapshot is committed through `RemoteSyncMyDocumentRestoreService`

 Data dependencies:
 - `RemoteSyncInitialBackupMetadataRestoreService` reads staged Android `LogEntry` rows
 - `RemoteSyncMyDocumentRestoreService` decodes sparse patch tables and performs the final rewrite
 - `RemoteSyncMyDocumentSnapshotService` projects the current local graph and refreshes fingerprints
 - `RemoteSyncLogEntryStore` and `RemoteSyncPatchStatusStore` preserve Android sync metadata

 Side effects:
 - reads staged gzip patch archives from disk and writes temporary extracted SQLite files
 - reads the current local My Documents graph from SwiftData
 - rewrites local My Documents SwiftData rows when at least one remote log entry is accepted
 - replaces category-scoped local `LogEntry` metadata and appends applied patch statuses
 - refreshes My Documents fingerprint baselines after replay evaluation

 Failure modes:
 - throws `RemoteSyncArchiveStagingError.decompressionFailed` when a staged gzip archive is invalid
 - rethrows metadata or snapshot decode errors from staged SQLite readers
 - throws `RemoteSyncMyDocumentPatchApplyError.invalidLogEntryIdentifier` for malformed row keys
 - throws `RemoteSyncMyDocumentPatchApplyError.missingPatchRow` for an accepted upsert without data
 - rethrows SwiftData restore failures from `RemoteSyncMyDocumentRestoreService`

 Concurrency:
 - this type is not `Sendable`; callers must use it on the execution context that owns the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncMyDocumentPatchApplyService {
    /**
     Mutable Android-shaped row set used to evaluate a full patch batch before touching SwiftData.

     The dictionaries are keyed by Android primary identifiers rather than SwiftData object identity
     so sparse content/cache updates can be applied without requiring full parent rows in the same
     patch archive.
     */
    private struct WorkingSnapshot {
        var documentsByID: [UUID: RemoteSyncAndroidMyDocument]
        var pagesByID: [UUID: RemoteSyncAndroidMyDocumentPage]
        var pageContentsByPageID: [UUID: RemoteSyncAndroidMyDocumentPageContent]
        var aiPageCacheEntriesByPageID: [UUID: RemoteSyncAndroidAiPageCacheEntry]

        /**
         Removes one document and every child row currently present in the working snapshot.

         - Parameter id: Android `MyDocument.id` value to remove.
         - Side effects: mutates all working row dictionaries that contain descendants.
         - Failure modes: This helper cannot fail.
         */
        mutating func removeDocument(id: UUID) {
            documentsByID.removeValue(forKey: id)
            let removedPageIDs = pagesByID.values
                .filter { $0.documentId == id }
                .map(\.id)
            for pageID in removedPageIDs {
                removePage(id: pageID)
            }
        }

        /**
         Removes one page and detached child rows keyed by that page identifier.

         - Parameter id: Android `MyDocumentPage.id` value to remove.
         - Side effects: mutates page, page-content, and AI-cache working dictionaries.
         - Failure modes: This helper cannot fail.
         */
        mutating func removePage(id: UUID) {
            pagesByID.removeValue(forKey: id)
            pageContentsByPageID.removeValue(forKey: id)
            aiPageCacheEntriesByPageID.removeValue(forKey: id)
        }

        /**
         Drops rows that would violate Android My Documents foreign-key relationships.

         Android runs `pragma_foreign_key_check` after each table is replayed. This in-memory
         equivalent removes pages whose parent document is absent, then removes detached
         page-content and AI-cache rows whose page is absent.

         - Side effects: mutates working dictionaries by deleting invalid child rows.
         - Failure modes: This helper cannot fail.
         */
        mutating func pruneForeignKeyViolations() {
            let validDocumentIDs = Set(documentsByID.keys)
            let invalidPageIDs = pagesByID.values
                .filter { !validDocumentIDs.contains($0.documentId) }
                .map(\.id)
            for pageID in invalidPageIDs {
                removePage(id: pageID)
            }

            let validPageIDs = Set(pagesByID.keys)
            let invalidPageContentIDs = pageContentsByPageID.keys.filter { !validPageIDs.contains($0) }
            for pageID in invalidPageContentIDs {
                pageContentsByPageID.removeValue(forKey: pageID)
            }
            let invalidAiCacheIDs = aiPageCacheEntriesByPageID.keys.filter { !validPageIDs.contains($0) }
            for pageID in invalidAiCacheIDs {
                aiPageCacheEntriesByPageID.removeValue(forKey: pageID)
            }
        }

        /**
         Converts the mutable working row dictionaries into a deterministic restore snapshot.

         - Returns: Android-shaped snapshot suitable for `RemoteSyncMyDocumentRestoreService`.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        func materializedSnapshot() -> RemoteSyncAndroidMyDocumentSnapshot {
            RemoteSyncAndroidMyDocumentSnapshot(
                documents: documentsByID.values.sorted(by: Self.documentSort),
                pages: pagesByID.values.sorted(by: Self.pageSort),
                pageContents: pageContentsByPageID.values.sorted { $0.pageId.uuidString < $1.pageId.uuidString },
                aiPageCacheEntries: aiPageCacheEntriesByPageID.values.sorted { $0.pageId.uuidString < $1.pageId.uuidString }
            )
        }

        private static func documentSort(
            _ lhs: RemoteSyncAndroidMyDocument,
            _ rhs: RemoteSyncAndroidMyDocument
        ) -> Bool {
            if lhs.orderNumber == rhs.orderNumber {
                if lhs.name == rhs.name {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.name < rhs.name
            }
            return lhs.orderNumber < rhs.orderNumber
        }

        private static func pageSort(
            _ lhs: RemoteSyncAndroidMyDocumentPage,
            _ rhs: RemoteSyncAndroidMyDocumentPage
        ) -> Bool {
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
    }

    private static let supportedTableNames: Set<String> = [
        "MyDocument",
        "MyDocumentPage",
        "MyDocumentPageContent",
        "AiPageCacheEntry",
    ]

    private let metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService
    private let restoreService: RemoteSyncMyDocumentRestoreService
    private let snapshotService: RemoteSyncMyDocumentSnapshotService
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    /**
     Creates a My Documents patch replay service with injectable readers and scratch storage.

     - Parameters:
       - metadataRestoreService: Reader for Android `LogEntry` and `SyncStatus` tables in staged patches.
       - restoreService: Reader and final SwiftData writer for Android-shaped My Documents rows.
       - snapshotService: Projector for current local rows and outbound fingerprint refresh.
       - fileManager: File manager used for temporary extracted SQLite files.
       - temporaryDirectory: Scratch directory override. Defaults to the process temporary directory.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService(),
        restoreService: RemoteSyncMyDocumentRestoreService = RemoteSyncMyDocumentRestoreService(),
        snapshotService: RemoteSyncMyDocumentSnapshotService = RemoteSyncMyDocumentSnapshotService(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) {
        self.metadataRestoreService = metadataRestoreService
        self.restoreService = restoreService
        self.snapshotService = snapshotService
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
    }

    /**
     Applies one ordered batch of staged Android My Documents patch archives.

     - Parameters:
       - stagedArchives: Already downloaded gzip patch archives sorted in application order.
       - modelContext: SwiftData context that owns the local My Documents graph.
       - settingsStore: Local settings store backing Android sync metadata and fingerprints.
     - Returns: Patch replay counts and the final normalized My Documents row counts.
     - Side effects:
       - reads and extracts staged patch archives into temporary SQLite files
       - may rewrite the local My Documents graph through the centralized restore service when
         at least one log entry is accepted
       - updates local `LogEntry`, patch-status, and fingerprint stores for `.myDocuments`
     - Failure modes:
       - throws archive decompression, staged metadata decode, row identifier, missing-row, and
         SwiftData restore errors from the lower-level helpers
     */
    public func applyPatchArchives(
        _ stagedArchives: [RemoteSyncStagedPatchArchive],
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncMyDocumentPatchApplyReport {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

        var snapshot = try currentSnapshot(from: modelContext, settingsStore: settingsStore)
        var logEntriesByKey = Dictionary(
            logEntryStore.entries(for: .myDocuments).map {
                (logEntryStore.key(for: .myDocuments, entry: $0), $0)
            },
            uniquingKeysWith: { _, replacement in replacement }
        )

        var appliedPatchStatuses: [RemoteSyncPatchStatus] = []
        var appliedLogEntryCount = 0
        var skippedLogEntryCount = 0

        for stagedArchive in stagedArchives {
            try {
                let patchDatabaseURL = temporaryDatabaseURL(prefix: "remote-sync-mydocuments-patch-", suffix: ".sqlite3")
                defer { try? fileManager.removeItem(at: patchDatabaseURL) }

                let archiveData = try Data(contentsOf: stagedArchive.archiveFileURL)
                let databaseData = try Self.gunzip(archiveData)
                try databaseData.write(to: patchDatabaseURL, options: .atomic)

                let metadataSnapshot = try metadataRestoreService.readSnapshot(from: patchDatabaseURL)
                let patchSnapshot = try restoreService.readSnapshot(from: patchDatabaseURL)
                let patchLogEntries = metadataSnapshot.logEntries.filter { Self.supportedTableNames.contains($0.tableName) }
                let filteredLogEntries = patchLogEntries.filter { entry in
                    let key = logEntryStore.key(for: .myDocuments, entry: entry)
                    guard let localEntry = logEntriesByKey[key] else {
                        return true
                    }
                    return entry.lastUpdated > localEntry.lastUpdated
                }

                skippedLogEntryCount += patchLogEntries.count - filteredLogEntries.count
                try applyDocumentOperations(
                    logEntries: filteredLogEntries.filter { $0.tableName == "MyDocument" },
                    patchSnapshot: patchSnapshot,
                    snapshot: &snapshot,
                    logEntriesByKey: &logEntriesByKey,
                    logEntryStore: logEntryStore
                )
                try applyPageOperations(
                    logEntries: filteredLogEntries.filter { $0.tableName == "MyDocumentPage" },
                    patchSnapshot: patchSnapshot,
                    snapshot: &snapshot,
                    logEntriesByKey: &logEntriesByKey,
                    logEntryStore: logEntryStore
                )
                try applyPageContentOperations(
                    logEntries: filteredLogEntries.filter { $0.tableName == "MyDocumentPageContent" },
                    patchSnapshot: patchSnapshot,
                    snapshot: &snapshot,
                    logEntriesByKey: &logEntriesByKey,
                    logEntryStore: logEntryStore
                )
                try applyAiPageCacheOperations(
                    logEntries: filteredLogEntries.filter { $0.tableName == "AiPageCacheEntry" },
                    patchSnapshot: patchSnapshot,
                    snapshot: &snapshot,
                    logEntriesByKey: &logEntriesByKey,
                    logEntryStore: logEntryStore
                )

                appliedLogEntryCount += filteredLogEntries.count
                appliedPatchStatuses.append(
                    RemoteSyncPatchStatus(
                        sourceDevice: stagedArchive.patch.sourceDevice,
                        patchNumber: stagedArchive.patch.patchNumber,
                        sizeBytes: stagedArchive.patch.file.size,
                        appliedDate: stagedArchive.patch.file.timestamp
                    )
                )
            }()
        }

        let materializedSnapshot = snapshot.materializedSnapshot()
        let restoreReport: RemoteSyncMyDocumentRestoreReport
        if appliedLogEntryCount > 0 {
            restoreReport = try restoreService.replaceLocalMyDocuments(
                from: materializedSnapshot,
                modelContext: modelContext
            )
        } else {
            restoreReport = Self.restoreReport(from: materializedSnapshot)
        }
        logEntryStore.replaceEntries(
            logEntriesByKey.values.sorted(by: Self.logEntrySort),
            for: .myDocuments
        )
        patchStatusStore.addStatuses(appliedPatchStatuses, for: .myDocuments)
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        return RemoteSyncMyDocumentPatchApplyReport(
            appliedPatchCount: appliedPatchStatuses.count,
            appliedLogEntryCount: appliedLogEntryCount,
            skippedLogEntryCount: skippedLogEntryCount,
            restoreReport: restoreReport
        )
    }

    /**
     Projects the current SwiftData graph into the mutable working representation used by replay.

     - Parameters:
       - modelContext: SwiftData context to read.
       - settingsStore: Settings store needed by the snapshot service for Android sync keys.
     - Returns: Working snapshot seeded with the current local My Documents rows.
     - Side effects: reads SwiftData through `RemoteSyncMyDocumentSnapshotService`.
     - Failure modes: Rethrows SwiftData fetch failures so replay never treats an unreadable local graph as empty.
     */
    private func currentSnapshot(
        from modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> WorkingSnapshot {
        let currentSnapshot = try snapshotService.snapshotCurrentStateThrowing(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        return WorkingSnapshot(
            documentsByID: Dictionary(
                currentSnapshot.documentRowsByKey.values.map { ($0.id, $0) },
                uniquingKeysWith: { _, replacement in replacement }
            ),
            pagesByID: Dictionary(
                currentSnapshot.pageRowsByKey.values.map { ($0.id, $0) },
                uniquingKeysWith: { _, replacement in replacement }
            ),
            pageContentsByPageID: Dictionary(
                currentSnapshot.pageContentRowsByKey.values.map { ($0.pageId, $0) },
                uniquingKeysWith: { _, replacement in replacement }
            ),
            aiPageCacheEntriesByPageID: Dictionary(
                currentSnapshot.aiPageCacheEntryRowsByKey.values.map { ($0.pageId, $0) },
                uniquingKeysWith: { _, replacement in replacement }
            )
        )
    }

    /**
     Applies accepted `MyDocument` operations from one patch archive.

     - Parameters:
       - logEntries: Newer Android log entries for the `MyDocument` table.
       - patchSnapshot: Sparse patch data decoded from the staged SQLite database.
       - snapshot: Mutable working snapshot to update.
       - logEntriesByKey: Local metadata map updated for every accepted operation.
       - logEntryStore: Store used to compute Android-compatible log keys.
     - Side effects: mutates `snapshot` and `logEntriesByKey`.
     - Failure modes: Throws when an accepted upsert log row has no corresponding document row.
     */
    private func applyDocumentOperations(
        logEntries: [RemoteSyncLogEntry],
        patchSnapshot: RemoteSyncAndroidMyDocumentSnapshot,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let patchRows = Dictionary(
            patchSnapshot.documents.map { ($0.id, $0) },
            uniquingKeysWith: { _, replacement in replacement }
        )
        try applySingleIDOperations(
            logEntries: logEntries,
            tableName: "MyDocument",
            patchRows: patchRows,
            upsert: { row in
                snapshot.documentsByID[row.id] = row
            },
            delete: { id in
                snapshot.removeDocument(id: id)
            },
            afterMutation: {
                snapshot.pruneForeignKeyViolations()
            },
            logEntriesByKey: &logEntriesByKey,
            logEntryStore: logEntryStore
        )
    }

    /**
     Applies accepted `MyDocumentPage` operations from one patch archive.

     - Parameters:
       - logEntries: Newer Android log entries for the `MyDocumentPage` table.
       - patchSnapshot: Sparse patch data decoded from the staged SQLite database.
       - snapshot: Mutable working snapshot to update.
       - logEntriesByKey: Local metadata map updated for every accepted operation.
       - logEntryStore: Store used to compute Android-compatible log keys.
     - Side effects: mutates `snapshot` and `logEntriesByKey`.
     - Failure modes: Throws when an accepted upsert log row has no corresponding page row.
     */
    private func applyPageOperations(
        logEntries: [RemoteSyncLogEntry],
        patchSnapshot: RemoteSyncAndroidMyDocumentSnapshot,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let patchRows = Dictionary(
            patchSnapshot.pages.map { ($0.id, $0) },
            uniquingKeysWith: { _, replacement in replacement }
        )
        try applySingleIDOperations(
            logEntries: logEntries,
            tableName: "MyDocumentPage",
            patchRows: patchRows,
            upsert: { row in
                snapshot.pagesByID[row.id] = row
            },
            delete: { id in
                snapshot.removePage(id: id)
            },
            afterMutation: {
                snapshot.pruneForeignKeyViolations()
            },
            logEntriesByKey: &logEntriesByKey,
            logEntryStore: logEntryStore
        )
    }

    /**
     Applies accepted `MyDocumentPageContent` operations from one patch archive.

     - Parameters:
       - logEntries: Newer Android log entries for the `MyDocumentPageContent` table.
       - patchSnapshot: Sparse patch data decoded from the staged SQLite database.
       - snapshot: Mutable working snapshot to update.
       - logEntriesByKey: Local metadata map updated for every accepted operation.
       - logEntryStore: Store used to compute Android-compatible log keys.
     - Side effects: mutates `snapshot` and `logEntriesByKey`.
     - Failure modes: Throws when an accepted upsert log row has no corresponding content row.
     */
    private func applyPageContentOperations(
        logEntries: [RemoteSyncLogEntry],
        patchSnapshot: RemoteSyncAndroidMyDocumentSnapshot,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let patchRows = Dictionary(
            patchSnapshot.pageContents.map { ($0.pageId, $0) },
            uniquingKeysWith: { _, replacement in replacement }
        )
        try applySingleIDOperations(
            logEntries: logEntries,
            tableName: "MyDocumentPageContent",
            patchRows: patchRows,
            upsert: { row in
                snapshot.pageContentsByPageID[row.pageId] = row
            },
            delete: { id in
                snapshot.pageContentsByPageID.removeValue(forKey: id)
            },
            afterMutation: {
                snapshot.pruneForeignKeyViolations()
            },
            logEntriesByKey: &logEntriesByKey,
            logEntryStore: logEntryStore
        )
    }

    /**
     Applies accepted `AiPageCacheEntry` operations from one patch archive.

     - Parameters:
       - logEntries: Newer Android log entries for the `AiPageCacheEntry` table.
       - patchSnapshot: Sparse patch data decoded from the staged SQLite database.
       - snapshot: Mutable working snapshot to update.
       - logEntriesByKey: Local metadata map updated for every accepted operation.
       - logEntryStore: Store used to compute Android-compatible log keys.
     - Side effects: mutates `snapshot` and `logEntriesByKey`.
     - Failure modes: Throws when an accepted upsert log row has no corresponding AI-cache row.
     */
    private func applyAiPageCacheOperations(
        logEntries: [RemoteSyncLogEntry],
        patchSnapshot: RemoteSyncAndroidMyDocumentSnapshot,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let patchRows = Dictionary(
            patchSnapshot.aiPageCacheEntries.map { ($0.pageId, $0) },
            uniquingKeysWith: { _, replacement in replacement }
        )
        try applySingleIDOperations(
            logEntries: logEntries,
            tableName: "AiPageCacheEntry",
            patchRows: patchRows,
            upsert: { row in
                snapshot.aiPageCacheEntriesByPageID[row.pageId] = row
            },
            delete: { id in
                snapshot.aiPageCacheEntriesByPageID.removeValue(forKey: id)
            },
            afterMutation: {
                snapshot.pruneForeignKeyViolations()
            },
            logEntriesByKey: &logEntriesByKey,
            logEntryStore: logEntryStore
        )
    }

    /**
     Applies single-UUID `UPSERT` and `DELETE` log rows for one Android My Documents table.

     Android's table replay first upserts newer rows, processes deletes, and normalizes foreign-key
     violations for that table. This helper preserves the same final table state and records
     accepted log entries in the local metadata map.

     - Parameters:
       - logEntries: Newer log entries for one table.
       - tableName: Android table name used in errors and log keys.
       - patchRows: Sparse patch rows keyed by the same UUID stored in `entityId1`.
       - upsert: Closure that inserts or replaces one working row.
       - delete: Closure that removes one working row.
       - afterMutation: Closure that normalizes foreign-key state after the table has been replayed.
       - logEntriesByKey: Local metadata map updated for accepted log entries.
       - logEntryStore: Store used to compute Android-compatible log keys.
     - Side effects: mutates caller-owned working rows through the supplied closures.
     - Failure modes:
       - throws `RemoteSyncMyDocumentPatchApplyError.invalidLogEntryIdentifier` for malformed keys
       - throws `RemoteSyncMyDocumentPatchApplyError.missingPatchRow` for accepted upserts without data
     */
    private func applySingleIDOperations<Row>(
        logEntries: [RemoteSyncLogEntry],
        tableName: String,
        patchRows: [UUID: Row],
        upsert: (Row) -> Void,
        delete: (UUID) -> Void,
        afterMutation: () -> Void,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let upserts = logEntries.filter { $0.type == .upsert }.sorted(by: Self.logEntrySort)
        let deletes = logEntries.filter { $0.type == .delete }.sorted(by: Self.logEntrySort)
        var didMutate = false

        for entry in upserts {
            let rowID = try uuid(from: entry.entityID1, tableName: tableName, field: "entityId1")
            guard let row = patchRows[rowID] else {
                throw RemoteSyncMyDocumentPatchApplyError.missingPatchRow(table: tableName, id: rowID)
            }
            upsert(row)
            didMutate = true
            logEntriesByKey[logEntryStore.key(for: .myDocuments, entry: entry)] = entry
        }

        for entry in deletes {
            let rowID = try uuid(from: entry.entityID1, tableName: tableName, field: "entityId1")
            delete(rowID)
            didMutate = true
            logEntriesByKey[logEntryStore.key(for: .myDocuments, entry: entry)] = entry
        }

        if didMutate {
            afterMutation()
        }
    }

    /**
     Converts an Android `LogEntry` identifier value into the UUID used by My Documents tables.

     - Parameters:
       - value: SQLite value from `LogEntry.entityId1`.
       - tableName: Android table name used for diagnostics.
       - field: Android field name used for diagnostics.
     - Returns: UUID decoded from a 16-byte blob or UUID string.
     - Side effects: none.
     - Failure modes: Throws `RemoteSyncMyDocumentPatchApplyError.invalidLogEntryIdentifier` when
       the value cannot be decoded as a UUID.
     */
    private func uuid(from value: RemoteSyncSQLiteValue, tableName: String, field: String) throws -> UUID {
        switch value.kind {
        case .blob:
            guard let data = value.blobData,
                  let uuid = uuid(from: data) else {
                throw RemoteSyncMyDocumentPatchApplyError.invalidLogEntryIdentifier(table: tableName, field: field)
            }
            return uuid
        case .text:
            guard let textValue = value.textValue,
                  let uuid = UUID(uuidString: textValue) else {
                throw RemoteSyncMyDocumentPatchApplyError.invalidLogEntryIdentifier(table: tableName, field: field)
            }
            return uuid
        default:
            throw RemoteSyncMyDocumentPatchApplyError.invalidLogEntryIdentifier(table: tableName, field: field)
        }
    }

    /**
     Converts Android's raw 16-byte UUID blob into Swift's UUID value.

     - Parameter data: SQLite blob payload expected to contain exactly 16 UUID bytes.
     - Returns: Decoded UUID, or `nil` when the blob has an invalid length.
     - Side effects: none.
     - Failure modes: This helper cannot throw.
     */
    private func uuid(from data: Data) -> UUID? {
        guard data.count == 16 else {
            return nil
        }
        return data.withUnsafeBytes { bytes -> UUID? in
            guard bytes.count == 16 else { return nil }
            let tuple = (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
            return UUID(uuid: tuple)
        }
    }

    /**
     Builds a unique temporary SQLite filename beneath the configured scratch directory.

     - Parameters:
       - prefix: Filename prefix used to identify the staging purpose.
       - suffix: Filename suffix, including extension.
     - Returns: Nonexistent candidate URL for temporary replay work.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func temporaryDatabaseURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    /**
     Extracts one gzip payload using the shared CLibSword compression bridge.

     - Parameter data: Gzip-compressed patch archive bytes.
     - Returns: Decompressed SQLite database bytes.
     - Side effects: allocates and frees native memory through the compression bridge.
     - Failure modes: Throws `RemoteSyncArchiveStagingError.decompressionFailed` for invalid gzip data.
     */
    private static func gunzip(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = ptr.baseAddress else {
                throw RemoteSyncArchiveStagingError.decompressionFailed
            }

            var outputLength: UInt = 0
            guard let output = gunzip_data(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(data.count),
                &outputLength
            ) else {
                throw RemoteSyncArchiveStagingError.decompressionFailed
            }

            defer { gunzip_free(output) }
            return Data(bytes: output, count: Int(outputLength))
        }
    }

    /**
     Builds a restore-count report from an already-normalized in-memory snapshot.

     This is used for all-skipped patch batches so the service can record patch status without
     destructively rewriting SwiftData for a no-op replay.

     - Parameter snapshot: Materialized working snapshot after replay evaluation.
     - Returns: Row counts matching the restore report shape.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func restoreReport(
        from snapshot: RemoteSyncAndroidMyDocumentSnapshot
    ) -> RemoteSyncMyDocumentRestoreReport {
        RemoteSyncMyDocumentRestoreReport(
            restoredDocumentCount: snapshot.documents.count,
            restoredPageCount: snapshot.pages.count,
            restoredContentCount: snapshot.pageContents.count,
            restoredAIPageCacheEntryCount: snapshot.aiPageCacheEntries.count
        )
    }

    /**
     Provides deterministic ordering for Android log-entry metadata persistence.

     - Parameters:
       - lhs: First log entry.
       - rhs: Second log entry.
     - Returns: `true` when `lhs` should be stored before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
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

    /**
     Converts one SQLite value into a stable string for tie-breaking log-entry sort order.

     - Parameter value: SQLite value to canonicalize.
     - Returns: Sortable representation including the SQLite storage kind.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
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
}
