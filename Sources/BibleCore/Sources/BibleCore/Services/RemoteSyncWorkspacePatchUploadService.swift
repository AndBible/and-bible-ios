// RemoteSyncWorkspacePatchUploadService.swift — Android-shaped outbound workspace patch creation and upload

import Foundation
import SQLite3
import SwiftData

private let remoteSyncWorkspacePatchUploadSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while exporting and uploading an outbound Android workspace patch.
 */
public enum RemoteSyncWorkspacePatchUploadError: Error, Equatable {
    /// The category is not ready for upload because no remote device folder identifier is known locally.
    case missingDeviceFolderID

    /// One current local workspace value could not be serialized into Android's JSON-backed SQLite columns.
    case jsonEncodingFailed(field: String)

    /// The generated temporary SQLite patch database could not be opened for writing.
    case invalidSQLiteDatabase
}

/**
 Summary of one successful outbound workspace patch upload.

 Android's workspace patch stream only mutates three content tables: `Workspace`, `Window`, and
 `PageManager`. This report preserves the per-table row counts so higher layers can confirm the
 upload serialized the expected mix of workspace shell, window layout, and page-state mutations.
 */
public struct RemoteSyncWorkspacePatchUploadReport: Sendable, Equatable {
    /// Remote file metadata returned by the backend after upload succeeded.
    public let uploadedFile: RemoteSyncFile

    /// Monotonic patch number assigned within the current device folder.
    public let patchNumber: Int64

    /// Number of `Workspace` rows written into the patch database.
    public let upsertedWorkspaceCount: Int

    /// Number of `Window` rows written into the patch database.
    public let upsertedWindowCount: Int

    /// Number of `PageManager` rows written into the patch database.
    public let upsertedPageManagerCount: Int

    /// Number of `DELETE` log entries emitted for rows removed locally.
    public let deletedRowCount: Int

    /// Total number of Android `LogEntry` rows written into the patch database.
    public let logEntryCount: Int

    /// Millisecond timestamp recorded as `lastUpdated` for the emitted Android log entries.
    public let lastUpdated: Int64

    /**
     Creates one outbound workspace patch-upload summary.

     - Parameters:
       - uploadedFile: Remote file metadata returned by the backend after upload succeeded.
       - patchNumber: Monotonic patch number assigned within the current device folder.
       - upsertedWorkspaceCount: Number of `Workspace` rows written into the patch database.
       - upsertedWindowCount: Number of `Window` rows written into the patch database.
       - upsertedPageManagerCount: Number of `PageManager` rows written into the patch database.
       - deletedRowCount: Number of `DELETE` log entries emitted for rows removed locally.
       - logEntryCount: Total number of Android `LogEntry` rows written into the patch database.
       - lastUpdated: Millisecond timestamp recorded as `lastUpdated` for the emitted Android log entries.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        uploadedFile: RemoteSyncFile,
        patchNumber: Int64,
        upsertedWorkspaceCount: Int,
        upsertedWindowCount: Int,
        upsertedPageManagerCount: Int,
        deletedRowCount: Int,
        logEntryCount: Int,
        lastUpdated: Int64
    ) {
        self.uploadedFile = uploadedFile
        self.patchNumber = patchNumber
        self.upsertedWorkspaceCount = upsertedWorkspaceCount
        self.upsertedWindowCount = upsertedWindowCount
        self.upsertedPageManagerCount = upsertedPageManagerCount
        self.deletedRowCount = deletedRowCount
        self.logEntryCount = logEntryCount
        self.lastUpdated = lastUpdated
    }
}

/**
 Creates Android-shaped sparse workspace patch databases and uploads them to the active backend.

 The service mirrors the outbound half of Android's incremental workspace sync contract:
 - project the current local SwiftData workspace graph into Android `Workspace`, `Window`, and
   `PageManager` rows
 - compare those rows against the preserved Android `LogEntry` baseline and local fingerprint store
 - emit sparse `UPSERT` and `DELETE` `LogEntry` rows only for changed Android row keys
 - write an Android-compatible SQLite patch database and gzip archive
 - upload `<patchNumber>.<schemaVersion>.sqlite3.gz` into the ready device folder
 - advance local `LogEntry`, `lastPatchWritten`, patch-status, and fingerprint baselines only after
   upload succeeds

 Android's workspace incremental contract does not include `HistoryItem` rows. This exporter
 therefore leaves preserved history metadata untouched and only mutates the three supported tables
 when building outbound patches.

 Data dependencies:
 - `RemoteSyncAdapting` performs the remote file upload
 - `RemoteSyncWorkspaceSnapshotService` projects live SwiftData and local-only workspace fidelity
   state into Android-shaped rows
 - `RemoteSyncLogEntryStore` provides the Android conflict baseline and is updated after success
 - `RemoteSyncPatchStatusStore` tracks the highest uploaded patch number for the local device folder
 - `RemoteSyncStateStore` persists Android-aligned `lastPatchWritten` bookkeeping
 - `RemoteSyncArchiveStagingService` provides gzip compression for the generated SQLite patch file

 Side effects:
 - reads live workspace-category state from SwiftData and local-only fidelity settings
 - creates and removes temporary SQLite and gzip files beneath the configured temporary directory
 - uploads a gzip patch archive into the ready device folder
 - rewrites local Android `LogEntry` and fingerprint baselines for `.workspaces` after success
 - appends one local patch status row and updates `lastPatchWritten`

 Failure modes:
 - throws `RemoteSyncWorkspacePatchUploadError.missingDeviceFolderID` when the category is not bootstrapped for outbound upload
 - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when local workspace settings cannot be serialized into Android JSON-backed columns
 - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when the temporary SQLite patch file cannot be created
 - rethrows local filesystem write failures while building the temporary SQLite or gzip files
 - rethrows backend transport or local-file read failures from `RemoteSyncAdapting.upload`
 - rethrows gzip-compression failures from `RemoteSyncArchiveStagingService.gzip(_:)`

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement rules of the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncWorkspacePatchUploadService {
    private struct ChangeSet {
        let workspaceRowsByKey: [String: RemoteSyncCurrentWorkspaceRow]
        let windowRowsByKey: [String: RemoteSyncCurrentWorkspaceWindowRow]
        let pageManagerRowsByKey: [String: RemoteSyncCurrentWorkspacePageManagerRow]
        let logEntries: [RemoteSyncLogEntry]
        let updatedEntriesByKey: [String: RemoteSyncLogEntry]

        /**
         Returns the total number of delete log entries in the change set.

         - Returns: Number of emitted delete operations.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        var deletedRowCount: Int {
            logEntries.filter { $0.type == .delete }.count
        }
    }

    private struct AndroidRecentLabelPayload: Encodable {
        let labelId: String
        let lastAccess: Int64
    }

    private static let supportedTableNames: Set<String> = ["Workspace", "Window", "PageManager"]

    private let adapter: any RemoteSyncAdapting
    private let snapshotService: RemoteSyncWorkspaceSnapshotService
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let nowProvider: () -> Int64
    private let jsonEncoder: JSONEncoder

    /**
     Creates a workspace patch upload service for one remote backend.

     - Parameters:
       - adapter: Remote backend adapter used for the final archive upload.
       - snapshotService: Snapshot service used to project current local workspace state into Android rows.
       - fileManager: File manager used for temporary-file cleanup.
       - temporaryDirectory: Scratch directory for temporary SQLite and gzip files. Defaults to the process temporary directory.
       - nowProvider: Millisecond clock used for Android `LogEntry.lastUpdated` and local `lastPatchWritten`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        adapter: any RemoteSyncAdapting,
        snapshotService: RemoteSyncWorkspaceSnapshotService = RemoteSyncWorkspaceSnapshotService(),
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

        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.sortedKeys]
        self.jsonEncoder = jsonEncoder
    }

    /**
     Builds and uploads the next sparse workspace patch when local state differs from the baseline.

     The service is intentionally conservative about missing fingerprint baselines. When it finds a
     preserved Android `LogEntry` row for one supported workspace table with no matching local
     fingerprint, it assumes the row came from a pre-fingerprint restore or replay and refreshes
     the baseline without uploading a patch. That avoids fabricating large false-positive uploads
     the first time outbound diffing is enabled on an existing install.

     Unsupported workspace metadata tables, such as `HistoryItem`, are preserved in the local
     `LogEntry` store but are excluded from outbound diffing because Android never mutates them via
     incremental workspace patches.

     - Parameters:
       - bootstrapState: Ready bootstrap state for the workspace category.
       - modelContext: SwiftData context that owns the live workspace graph.
       - settingsStore: Local-only settings store backing preserved Android sync metadata.
       - schemaVersion: Schema version to encode into the generated patch filename and SQLite user version.
     - Returns: Upload summary when a sparse patch was emitted, or `nil` when no local changes need upload.
     - Side effects:
       - may refresh the fingerprint baseline without uploading when the service encounters historical rows with no stored fingerprints
       - creates and removes temporary SQLite and gzip files
       - uploads a gzip patch archive when local changes exist
       - rewrites local `LogEntry`, patch-status, progress, and fingerprint state after successful upload
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.missingDeviceFolderID` when `bootstrapState.deviceFolderID` is missing or empty
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when local settings cannot be serialized into Android row payloads
       - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when the temporary SQLite patch file cannot be opened
       - rethrows filesystem, compression, and backend upload failures
     */
    public func uploadPendingPatch(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = 1
    ) async throws -> RemoteSyncWorkspacePatchUploadReport? {
        guard let deviceFolderID = bootstrapState.deviceFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceFolderID.isEmpty else {
            throw RemoteSyncWorkspacePatchUploadError.missingDeviceFolderID
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
            uniqueKeysWithValues: logEntryStore.entries(for: .workspaces).map {
                (logEntryStore.key(for: .workspaces, entry: $0), $0)
            }
        )
        let hadMissingFingerprintBaseline = existingEntriesByKey.contains { key, entry in
            guard Self.supportedTableNames.contains(entry.tableName),
                  entry.type != .delete,
                  currentRowExists(forKey: key, in: snapshot) else {
                return false
            }
            return fingerprintStore.fingerprint(
                for: .workspaces,
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
            for: .workspaces,
            sourceDevice: sourceDevice
        ) ?? 0) + 1
        let patchFileName = "\(patchNumber).\(schemaVersion).sqlite3.gz"

        let databaseURL = temporaryURL(prefix: "remote-sync-workspaces-upload-", suffix: ".sqlite3")
        let archiveURL = temporaryURL(prefix: "remote-sync-workspaces-upload-", suffix: ".sqlite3.gz")
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
            for: .workspaces
        )
        patchStatusStore.addStatus(
            RemoteSyncPatchStatus(
                sourceDevice: sourceDevice,
                patchNumber: patchNumber,
                sizeBytes: uploadedFile.size,
                appliedDate: timestamp
            ),
            for: .workspaces
        )
        var progressState = stateStore.progressState(for: .workspaces)
        progressState.lastPatchWritten = timestamp
        stateStore.setProgressState(progressState, for: .workspaces)
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        return RemoteSyncWorkspacePatchUploadReport(
            uploadedFile: uploadedFile,
            patchNumber: patchNumber,
            upsertedWorkspaceCount: changeSet.workspaceRowsByKey.count,
            upsertedWindowCount: changeSet.windowRowsByKey.count,
            upsertedPageManagerCount: changeSet.pageManagerRowsByKey.count,
            deletedRowCount: changeSet.deletedRowCount,
            logEntryCount: changeSet.logEntries.count,
            lastUpdated: timestamp
        )
    }

    /**
     Computes the sparse Android row diff for the current workspace snapshot.

     - Parameters:
       - snapshot: Current local workspace state projected into Android-shaped rows.
       - existingEntriesByKey: Existing Android `LogEntry` baseline keyed by Android composite key.
       - fingerprintStore: Local fingerprint store used to compare current rows against the last uploaded baseline.
       - timestamp: Millisecond timestamp to assign to any emitted outbound `LogEntry` rows.
       - sourceDevice: Local source-device folder name that should own the outbound patch rows.
     - Returns: Sparse change set containing upserted rows, delete entries, and the updated local metadata baseline.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func buildChangeSet(
        snapshot: RemoteSyncWorkspaceCurrentSnapshot,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore,
        timestamp: Int64,
        sourceDevice: String
    ) -> ChangeSet {
        var workspaceRowsByKey: [String: RemoteSyncCurrentWorkspaceRow] = [:]
        var windowRowsByKey: [String: RemoteSyncCurrentWorkspaceWindowRow] = [:]
        var pageManagerRowsByKey: [String: RemoteSyncCurrentWorkspacePageManagerRow] = [:]
        var logEntries: [RemoteSyncLogEntry] = []
        var updatedEntriesByKey = existingEntriesByKey

        for (key, row) in snapshot.workspaceRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "Workspace",
                entityID1: .blob(RemoteSyncWorkspaceSnapshotService.uuidBlob(row.id)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            workspaceRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.windowRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "Window",
                entityID1: .blob(RemoteSyncWorkspaceSnapshotService.uuidBlob(row.id)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            windowRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.pageManagerRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "PageManager",
                entityID1: .blob(RemoteSyncWorkspaceSnapshotService.uuidBlob(row.windowID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            pageManagerRowsByKey[key] = row
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
            workspaceRowsByKey: workspaceRowsByKey,
            windowRowsByKey: windowRowsByKey,
            pageManagerRowsByKey: pageManagerRowsByKey,
            logEntries: logEntries.sorted(by: Self.logEntrySort),
            updatedEntriesByKey: updatedEntriesByKey
        )
    }

    /**
     Returns whether one current snapshot row should be emitted as an outbound `UPSERT`.

     Missing fingerprints are intentionally treated as unchanged when the row already has a
     preserved non-delete Android `LogEntry` baseline. That conservative branch prevents a one-time
     fingerprint migration from generating false-positive uploads for historical restores.

     - Parameters:
       - key: Android composite key for the row.
       - currentFingerprint: Current stable row fingerprint, if one was computed.
       - existingEntriesByKey: Existing Android `LogEntry` baseline keyed by Android composite key.
       - fingerprintStore: Local fingerprint store used to read the prior baseline for the row.
     - Returns: `true` when the row should be emitted as an outbound upsert.
     - Side effects: reads preserved local fingerprint rows from `SettingsStore`.
     - Failure modes: This helper cannot fail.
     */
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
                category: .workspaces
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
            for: .workspaces,
            tableName: existingEntry.tableName,
            entityID1: existingEntry.entityID1,
            entityID2: existingEntry.entityID2
        )
        guard let existingFingerprint else {
            return false
        }
        return existingFingerprint != currentFingerprint
    }

    /**
     Returns whether the current workspace snapshot still contains one Android composite key.

     - Parameters:
       - key: Android composite key to inspect.
       - snapshot: Current local workspace snapshot.
     - Returns: `true` when the key still resolves to a current `Workspace`, `Window`, or `PageManager` row.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func currentRowExists(forKey key: String, in snapshot: RemoteSyncWorkspaceCurrentSnapshot) -> Bool {
        snapshot.workspaceRowsByKey[key] != nil
            || snapshot.windowRowsByKey[key] != nil
            || snapshot.pageManagerRowsByKey[key] != nil
    }

    /**
     Writes one sparse Android workspace patch database to the supplied SQLite URL.

     - Parameters:
       - url: Temporary SQLite file URL to create.
       - schemaVersion: SQLite user version that should be written to the patch database.
       - changeSet: Sparse current-row diff that should be serialized.
     - Side effects:
       - creates and writes a temporary SQLite database file
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when local settings cannot be serialized into Android JSON columns
       - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when the file cannot be opened for writing
       - rethrows SQLite execution failures from schema creation or row inserts
     */
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
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        try execute(
            """
            PRAGMA user_version = \(schemaVersion);
            CREATE TABLE Workspace (
                name TEXT NOT NULL,
                contentsText TEXT,
                id BLOB NOT NULL PRIMARY KEY,
                orderNumber INTEGER NOT NULL DEFAULT 0,
                unPinnedWeight REAL DEFAULT NULL,
                maximizedWindowId BLOB,
                primaryTargetLinksWindowId BLOB DEFAULT NULL,
                text_display_settings_strongsMode INTEGER DEFAULT NULL,
                text_display_settings_showMorphology INTEGER DEFAULT NULL,
                text_display_settings_showFootNotes INTEGER DEFAULT NULL,
                text_display_settings_showFootNotesInline INTEGER DEFAULT NULL,
                text_display_settings_expandXrefs INTEGER DEFAULT NULL,
                text_display_settings_showXrefs INTEGER DEFAULT NULL,
                text_display_settings_showRedLetters INTEGER DEFAULT NULL,
                text_display_settings_showSectionTitles INTEGER DEFAULT NULL,
                text_display_settings_showVerseNumbers INTEGER DEFAULT NULL,
                text_display_settings_showVersePerLine INTEGER DEFAULT NULL,
                text_display_settings_showBookmarks INTEGER DEFAULT NULL,
                text_display_settings_showMyNotes INTEGER DEFAULT NULL,
                text_display_settings_justifyText INTEGER DEFAULT NULL,
                text_display_settings_hyphenation INTEGER DEFAULT NULL,
                text_display_settings_topMargin INTEGER DEFAULT NULL,
                text_display_settings_fontSize INTEGER DEFAULT NULL,
                text_display_settings_fontFamily TEXT DEFAULT NULL,
                text_display_settings_lineSpacing INTEGER DEFAULT NULL,
                text_display_settings_bookmarksHideLabels TEXT DEFAULT NULL,
                text_display_settings_showPageNumber INTEGER DEFAULT NULL,
                text_display_settings_margin_size_marginLeft INTEGER DEFAULT NULL,
                text_display_settings_margin_size_marginRight INTEGER DEFAULT NULL,
                text_display_settings_margin_size_maxWidth INTEGER DEFAULT NULL,
                text_display_settings_colors_dayTextColor INTEGER DEFAULT NULL,
                text_display_settings_colors_dayBackground INTEGER DEFAULT NULL,
                text_display_settings_colors_dayNoise INTEGER DEFAULT NULL,
                text_display_settings_colors_nightTextColor INTEGER DEFAULT NULL,
                text_display_settings_colors_nightBackground INTEGER DEFAULT NULL,
                text_display_settings_colors_nightNoise INTEGER DEFAULT NULL,
                workspace_settings_enableTiltToScroll INTEGER DEFAULT 0,
                workspace_settings_enableReverseSplitMode INTEGER DEFAULT 0,
                workspace_settings_autoPin INTEGER DEFAULT 1,
                workspace_settings_restoreButtonsVisible INTEGER DEFAULT 1,
                workspace_settings_speakSettings TEXT DEFAULT NULL,
                workspace_settings_recentLabels TEXT DEFAULT NULL,
                workspace_settings_autoAssignLabels TEXT DEFAULT NULL,
                workspace_settings_autoAssignPrimaryLabel BLOB DEFAULT NULL,
                workspace_settings_studyPadCursors TEXT DEFAULT NULL,
                workspace_settings_hideCompareDocuments TEXT DEFAULT NULL,
                workspace_settings_limitAmbiguousModalSize INTEGER DEFAULT 0,
                workspace_settings_workspaceColor INTEGER DEFAULT NULL
            );
            CREATE TABLE "Window" (
                workspaceId BLOB NOT NULL,
                isSynchronized INTEGER NOT NULL,
                isPinMode INTEGER NOT NULL,
                isLinksWindow INTEGER NOT NULL,
                id BLOB NOT NULL PRIMARY KEY,
                orderNumber INTEGER NOT NULL,
                targetLinksWindowId BLOB DEFAULT NULL,
                syncGroup INTEGER NOT NULL DEFAULT 0,
                window_layout_state TEXT NOT NULL,
                window_layout_weight REAL NOT NULL
            );
            CREATE TABLE PageManager (
                windowId BLOB NOT NULL PRIMARY KEY,
                currentCategoryName TEXT NOT NULL,
                jsState TEXT,
                bible_document TEXT,
                bible_verse_versification TEXT NOT NULL,
                bible_verse_bibleBook INTEGER NOT NULL,
                bible_verse_chapterNo INTEGER NOT NULL,
                bible_verse_verseNo INTEGER NOT NULL,
                commentary_document TEXT,
                commentary_anchorOrdinal INTEGER DEFAULT NULL,
                commentary_sourceBookAndKey TEXT DEFAULT NULL,
                dictionary_document TEXT,
                dictionary_key TEXT,
                dictionary_anchorOrdinal INTEGER DEFAULT NULL,
                general_book_document TEXT,
                general_book_key TEXT,
                general_book_anchorOrdinal INTEGER DEFAULT NULL,
                map_document TEXT,
                map_key TEXT,
                map_anchorOrdinal INTEGER DEFAULT NULL,
                text_display_settings_strongsMode INTEGER DEFAULT NULL,
                text_display_settings_showMorphology INTEGER DEFAULT NULL,
                text_display_settings_showFootNotes INTEGER DEFAULT NULL,
                text_display_settings_showFootNotesInline INTEGER DEFAULT NULL,
                text_display_settings_expandXrefs INTEGER DEFAULT NULL,
                text_display_settings_showXrefs INTEGER DEFAULT NULL,
                text_display_settings_showRedLetters INTEGER DEFAULT NULL,
                text_display_settings_showSectionTitles INTEGER DEFAULT NULL,
                text_display_settings_showVerseNumbers INTEGER DEFAULT NULL,
                text_display_settings_showVersePerLine INTEGER DEFAULT NULL,
                text_display_settings_showBookmarks INTEGER DEFAULT NULL,
                text_display_settings_showMyNotes INTEGER DEFAULT NULL,
                text_display_settings_justifyText INTEGER DEFAULT NULL,
                text_display_settings_hyphenation INTEGER DEFAULT NULL,
                text_display_settings_topMargin INTEGER DEFAULT NULL,
                text_display_settings_fontSize INTEGER DEFAULT NULL,
                text_display_settings_fontFamily TEXT DEFAULT NULL,
                text_display_settings_lineSpacing INTEGER DEFAULT NULL,
                text_display_settings_bookmarksHideLabels TEXT DEFAULT NULL,
                text_display_settings_showPageNumber INTEGER DEFAULT NULL,
                text_display_settings_margin_size_marginLeft INTEGER DEFAULT NULL,
                text_display_settings_margin_size_marginRight INTEGER DEFAULT NULL,
                text_display_settings_margin_size_maxWidth INTEGER DEFAULT NULL,
                text_display_settings_colors_dayTextColor INTEGER DEFAULT NULL,
                text_display_settings_colors_dayBackground INTEGER DEFAULT NULL,
                text_display_settings_colors_dayNoise INTEGER DEFAULT NULL,
                text_display_settings_colors_nightTextColor INTEGER DEFAULT NULL,
                text_display_settings_colors_nightBackground INTEGER DEFAULT NULL,
                text_display_settings_colors_nightNoise INTEGER DEFAULT NULL
            );
            CREATE TABLE LogEntry (
                tableName TEXT NOT NULL,
                entityId1 BLOB NOT NULL,
                entityId2 BLOB NOT NULL DEFAULT '',
                type TEXT NOT NULL,
                lastUpdated INTEGER NOT NULL,
                sourceDevice TEXT NOT NULL,
                PRIMARY KEY (tableName, entityId1, entityId2)
            );
            CREATE INDEX index_LogEntry_tableName_entityId1 ON LogEntry (tableName, entityId1);
            CREATE INDEX index_LogEntry_lastUpdated ON LogEntry (lastUpdated);
            """,
            in: database
        )

        for row in changeSet.workspaceRowsByKey.values.sorted(by: Self.workspaceSort) {
            try insertWorkspaceRow(row, in: database)
        }
        for row in changeSet.windowRowsByKey.values.sorted(by: Self.windowSort) {
            try insertWindowRow(row, in: database)
        }
        for row in changeSet.pageManagerRowsByKey.values.sorted(by: Self.pageManagerSort) {
            try insertPageManagerRow(row, in: database)
        }
        for entry in changeSet.logEntries {
            try insertLogEntry(entry, in: database)
        }
    }

    /**
     Inserts one Android `Workspace` row into the open patch database.

     - Parameters:
       - row: Android-shaped workspace row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `Workspace` table.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when one JSON-backed settings payload cannot be serialized
       - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when SQLite cannot prepare or step the insert
     */
    private func insertWorkspaceRow(
        _ row: RemoteSyncCurrentWorkspaceRow,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO Workspace (name, contentsText, id, orderNumber, unPinnedWeight, maximizedWindowId, primaryTargetLinksWindowId, text_display_settings_strongsMode, text_display_settings_showMorphology, text_display_settings_showFootNotes, text_display_settings_showFootNotesInline, text_display_settings_expandXrefs, text_display_settings_showXrefs, text_display_settings_showRedLetters, text_display_settings_showSectionTitles, text_display_settings_showVerseNumbers, text_display_settings_showVersePerLine, text_display_settings_showBookmarks, text_display_settings_showMyNotes, text_display_settings_justifyText, text_display_settings_hyphenation, text_display_settings_topMargin, text_display_settings_fontSize, text_display_settings_fontFamily, text_display_settings_lineSpacing, text_display_settings_bookmarksHideLabels, text_display_settings_showPageNumber, text_display_settings_margin_size_marginLeft, text_display_settings_margin_size_marginRight, text_display_settings_margin_size_maxWidth, text_display_settings_colors_dayTextColor, text_display_settings_colors_dayBackground, text_display_settings_colors_dayNoise, text_display_settings_colors_nightTextColor, text_display_settings_colors_nightBackground, text_display_settings_colors_nightNoise, workspace_settings_enableTiltToScroll, workspace_settings_enableReverseSplitMode, workspace_settings_autoPin, workspace_settings_restoreButtonsVisible, workspace_settings_speakSettings, workspace_settings_recentLabels, workspace_settings_autoAssignLabels, workspace_settings_autoAssignPrimaryLabel, workspace_settings_studyPadCursors, workspace_settings_hideCompareDocuments, workspace_settings_limitAmbiguousModalSize, workspace_settings_workspaceColor) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        Self.bindText(row.name, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.contentsText, to: statement, index: index)
        index += 1
        Self.bindUUIDBlob(row.id, to: statement, index: index)
        index += 1
        sqlite3_bind_int(statement, index, Int32(row.orderNumber))
        index += 1
        Self.bindOptionalFloat(row.unPinnedWeight, to: statement, index: index)
        index += 1
        Self.bindOptionalUUIDBlob(row.maximizedWindowID, to: statement, index: index)
        index += 1
        Self.bindOptionalUUIDBlob(row.primaryTargetLinksWindowID, to: statement, index: index)
        index += 1
        try bindTextDisplaySettings(row.textDisplaySettings, to: statement, index: &index)
        try bindWorkspaceSettings(
            row.workspaceSettings,
            speakSettingsJSON: row.speakSettingsJSON,
            workspaceColor: row.workspaceColor,
            to: statement,
            index: &index
        )

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `Window` row into the open patch database.

     - Parameters:
       - row: Android-shaped window row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `Window` table.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when SQLite cannot prepare or step the insert
     */
    private func insertWindowRow(
        _ row: RemoteSyncCurrentWorkspaceWindowRow,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO \"Window\" (workspaceId, isSynchronized, isPinMode, isLinksWindow, id, orderNumber, targetLinksWindowId, syncGroup, window_layout_state, window_layout_weight) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.workspaceID, to: statement, index: 1)
        Self.bindBool(row.isSynchronized, to: statement, index: 2)
        Self.bindBool(row.isPinMode, to: statement, index: 3)
        Self.bindBool(row.isLinksWindow, to: statement, index: 4)
        Self.bindUUIDBlob(row.id, to: statement, index: 5)
        sqlite3_bind_int(statement, 6, Int32(row.orderNumber))
        Self.bindOptionalUUIDBlob(row.targetLinksWindowID, to: statement, index: 7)
        sqlite3_bind_int(statement, 8, Int32(row.syncGroup))
        Self.bindText(row.layoutState, to: statement, index: 9)
        sqlite3_bind_double(statement, 10, Double(row.layoutWeight))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `PageManager` row into the open patch database.

     - Parameters:
       - row: Android-shaped page-manager row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `PageManager` table.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when one JSON-backed settings payload cannot be serialized
       - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when SQLite cannot prepare or step the insert
     */
    private func insertPageManagerRow(
        _ row: RemoteSyncCurrentWorkspacePageManagerRow,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO PageManager (windowId, currentCategoryName, jsState, bible_document, bible_verse_versification, bible_verse_bibleBook, bible_verse_chapterNo, bible_verse_verseNo, commentary_document, commentary_anchorOrdinal, commentary_sourceBookAndKey, dictionary_document, dictionary_key, dictionary_anchorOrdinal, general_book_document, general_book_key, general_book_anchorOrdinal, map_document, map_key, map_anchorOrdinal, text_display_settings_strongsMode, text_display_settings_showMorphology, text_display_settings_showFootNotes, text_display_settings_showFootNotesInline, text_display_settings_expandXrefs, text_display_settings_showXrefs, text_display_settings_showRedLetters, text_display_settings_showSectionTitles, text_display_settings_showVerseNumbers, text_display_settings_showVersePerLine, text_display_settings_showBookmarks, text_display_settings_showMyNotes, text_display_settings_justifyText, text_display_settings_hyphenation, text_display_settings_topMargin, text_display_settings_fontSize, text_display_settings_fontFamily, text_display_settings_lineSpacing, text_display_settings_bookmarksHideLabels, text_display_settings_showPageNumber, text_display_settings_margin_size_marginLeft, text_display_settings_margin_size_marginRight, text_display_settings_margin_size_maxWidth, text_display_settings_colors_dayTextColor, text_display_settings_colors_dayBackground, text_display_settings_colors_dayNoise, text_display_settings_colors_nightTextColor, text_display_settings_colors_nightBackground, text_display_settings_colors_nightNoise) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        Self.bindUUIDBlob(row.windowID, to: statement, index: index)
        index += 1
        Self.bindText(row.currentCategoryName, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.jsState, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.bibleDocument, to: statement, index: index)
        index += 1
        Self.bindText(row.bibleVersification, to: statement, index: index)
        index += 1
        sqlite3_bind_int(statement, index, Int32(row.bibleBook))
        index += 1
        sqlite3_bind_int(statement, index, Int32(row.bibleChapterNo))
        index += 1
        sqlite3_bind_int(statement, index, Int32(row.bibleVerseNo))
        index += 1
        Self.bindOptionalText(row.commentaryDocument, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(row.commentaryAnchorOrdinal, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.commentarySourceBookAndKey, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.dictionaryDocument, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.dictionaryKey, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(row.dictionaryAnchorOrdinal, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.generalBookDocument, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.generalBookKey, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(row.generalBookAnchorOrdinal, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.mapDocument, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.mapKey, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(row.mapAnchorOrdinal, to: statement, index: index)
        index += 1
        try bindTextDisplaySettings(row.textDisplaySettings, to: statement, index: &index)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `LogEntry` row into the open patch database.

     - Parameters:
       - entry: Android log entry to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `LogEntry` table.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when SQLite cannot prepare or step the insert
     */
    private func insertLogEntry(
        _ entry: RemoteSyncLogEntry,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindText(entry.tableName, to: statement, index: 1)
        Self.bindSQLiteValue(entry.entityID1, to: statement, index: 2)
        Self.bindSQLiteValue(entry.entityID2, to: statement, index: 3)
        Self.bindText(entry.type.rawValue, to: statement, index: 4)
        sqlite3_bind_int64(statement, 5, entry.lastUpdated)
        Self.bindText(entry.sourceDevice, to: statement, index: 6)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Binds one embedded Android text-display settings block into a prepared SQLite statement.

     - Parameters:
       - value: Optional text-display settings override block.
       - statement: Prepared SQLite statement receiving the bound values.
       - index: In-out one-based SQLite parameter index advanced past the bound columns.
     - Side effects: mutates the statement's bound-parameter state.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when `bookmarksHideLabels` cannot be encoded safely
     */
    private func bindTextDisplaySettings(
        _ value: TextDisplaySettings?,
        to statement: OpaquePointer,
        index: inout Int32
    ) throws {
        let settings = value
        Self.bindOptionalInt(settings?.strongsMode, to: statement, index: index)
        index += 1
        Self.bindOptionalBool(settings?.showMorphology, to: statement, index: index)
        index += 1
        Self.bindOptionalBool(settings?.showFootNotes, to: statement, index: index)
        index += 1
        Self.bindOptionalBool(settings?.showFootNotesInline, to: statement, index: index)
        index += 1
        Self.bindOptionalBool(settings?.expandXrefs, to: statement, index: index)
        index += 1
        Self.bindOptionalBool(settings?.showXrefs, to: statement, index: index)
        index += 1
        Self.bindOptionalBool(settings?.showRedLetters, to: statement, index: index)
        index += 1
        Self.bindOptionalBool(settings?.showSectionTitles, to: statement, index: index)
        index += 1
        Self.bindOptionalBool(settings?.showVerseNumbers, to: statement, index: index)
        index += 1
        Self.bindOptionalBool(settings?.showVersePerLine, to: statement, index: index)
        index += 1
        Self.bindOptionalBool(settings?.showBookmarks, to: statement, index: index)
        index += 1
        Self.bindOptionalBool(settings?.showMyNotes, to: statement, index: index)
        index += 1
        Self.bindOptionalBool(settings?.justifyText, to: statement, index: index)
        index += 1
        Self.bindOptionalBool(settings?.hyphenation, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(settings?.topMargin, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(settings?.fontSize, to: statement, index: index)
        index += 1
        Self.bindOptionalText(settings?.fontFamily, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(settings?.lineSpacing, to: statement, index: index)
        index += 1
        if let bookmarksHideLabels = settings?.bookmarksHideLabels {
            let bookmarksHideLabelsJSON = try encodeUUIDArrayJSON(
                bookmarksHideLabels,
                field: "text_display_settings_bookmarksHideLabels"
            )
            Self.bindText(bookmarksHideLabelsJSON, to: statement, index: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
        index += 1
        Self.bindOptionalBool(settings?.showPageNumber, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(settings?.marginLeft, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(settings?.marginRight, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(settings?.maxWidth, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(settings?.dayTextColor, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(settings?.dayBackground, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(settings?.dayNoise, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(settings?.nightTextColor, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(settings?.nightBackground, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(settings?.nightNoise, to: statement, index: index)
        index += 1
    }

    /**
     Binds one embedded Android workspace-settings block into a prepared SQLite statement.

     - Parameters:
       - value: Workspace settings payload supported by both Android and iOS.
       - speakSettingsJSON: Raw Android `speakSettings` JSON preserved in the fidelity store.
       - workspaceColor: Optional raw Android workspace color preserved in the fidelity store.
       - statement: Prepared SQLite statement receiving the bound values.
       - index: In-out one-based SQLite parameter index advanced past the bound columns.
     - Side effects: mutates the statement's bound-parameter state.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when one JSON-backed settings payload cannot be serialized safely
     */
    private func bindWorkspaceSettings(
        _ value: WorkspaceSettings,
        speakSettingsJSON: String?,
        workspaceColor: Int?,
        to statement: OpaquePointer,
        index: inout Int32
    ) throws {
        var normalizedValue = value
        normalizedValue.normalizeAutoAssignPrimaryLabel()

        Self.bindBool(normalizedValue.enableTiltToScroll, to: statement, index: index)
        index += 1
        Self.bindBool(normalizedValue.enableReverseSplitMode, to: statement, index: index)
        index += 1
        Self.bindBool(normalizedValue.autoPin, to: statement, index: index)
        index += 1
        Self.bindBool(normalizedValue.restoreButtonsVisible, to: statement, index: index)
        index += 1
        Self.bindOptionalText(speakSettingsJSON, to: statement, index: index)
        index += 1
        if normalizedValue.recentLabels.isEmpty {
            sqlite3_bind_null(statement, index)
        } else {
            let recentLabelsJSON = try encodeRecentLabelsJSON(normalizedValue.recentLabels)
            Self.bindText(recentLabelsJSON, to: statement, index: index)
        }
        index += 1
        if normalizedValue.autoAssignLabels.isEmpty {
            sqlite3_bind_null(statement, index)
        } else {
            let autoAssignLabelsJSON = try encodeSortedUUIDSetJSON(
                normalizedValue.autoAssignLabels,
                field: "workspace_settings_autoAssignLabels"
            )
            Self.bindText(autoAssignLabelsJSON, to: statement, index: index)
        }
        index += 1
        Self.bindOptionalUUIDBlob(normalizedValue.autoAssignPrimaryLabel, to: statement, index: index)
        index += 1
        if normalizedValue.studyPadCursors.isEmpty {
            sqlite3_bind_null(statement, index)
        } else {
            let studyPadCursorsJSON = try encodeStudyPadCursorsJSON(normalizedValue.studyPadCursors)
            Self.bindText(studyPadCursorsJSON, to: statement, index: index)
        }
        index += 1
        if normalizedValue.hideCompareDocuments.isEmpty {
            sqlite3_bind_null(statement, index)
        } else {
            let hiddenCompareDocumentsJSON = try encodeSortedStringSetJSON(
                normalizedValue.hideCompareDocuments,
                field: "workspace_settings_hideCompareDocuments"
            )
            Self.bindText(hiddenCompareDocumentsJSON, to: statement, index: index)
        }
        index += 1
        Self.bindBool(normalizedValue.limitAmbiguousModalSize, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(workspaceColor, to: statement, index: index)
        index += 1
    }

    /**
     Encodes the workspace `recentLabels` array into Android's JSON payload shape.

     - Parameter value: Recent-label array in current order.
     - Returns: JSON string using Android's `{labelId,lastAccess}` millisecond payload.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when the payload cannot be encoded safely
     */
    private func encodeRecentLabelsJSON(_ value: [RecentLabel]) throws -> String {
        let payload = value.map {
            AndroidRecentLabelPayload(
                labelId: $0.labelId.uuidString.lowercased(),
                lastAccess: Int64($0.lastAccess.timeIntervalSince1970 * 1000.0)
            )
        }
        return try encodeJSONString(payload, field: "workspace_settings_recentLabels")
    }

    /**
     Encodes one UUID set into Android's string-array JSON payload shape.

     - Parameters:
       - value: UUID set to encode.
       - field: Android column name used for error reporting.
     - Returns: JSON string containing sorted lower-case UUID strings.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when the payload cannot be encoded safely
     */
    private func encodeSortedUUIDSetJSON(_ value: Set<UUID>, field: String) throws -> String {
        let payload = value.map { $0.uuidString.lowercased() }.sorted()
        return try encodeJSONString(payload, field: field)
    }

    /**
     Encodes one UUID array into Android's string-array JSON payload shape.

     - Parameters:
       - value: UUID array to encode.
       - field: Android column name used for error reporting.
     - Returns: JSON string preserving the current array order.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when the payload cannot be encoded safely
     */
    private func encodeUUIDArrayJSON(_ value: [UUID], field: String) throws -> String {
        let payload = value.map { $0.uuidString.lowercased() }
        return try encodeJSONString(payload, field: field)
    }

    /**
     Encodes one string set into Android's string-array JSON payload shape.

     - Parameters:
       - value: String set to encode.
       - field: Android column name used for error reporting.
     - Returns: JSON string containing sorted strings.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when the payload cannot be encoded safely
     */
    private func encodeSortedStringSetJSON(_ value: Set<String>, field: String) throws -> String {
        try encodeJSONString(value.sorted(), field: field)
    }

    /**
     Encodes one StudyPad-cursor dictionary into Android's JSON object payload shape.

     - Parameter value: Cursor positions keyed by label identifier.
     - Returns: JSON object string keyed by lower-case UUID strings.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when the payload cannot be encoded safely
     */
    private func encodeStudyPadCursorsJSON(_ value: [UUID: Int]) throws -> String {
        let payload = Dictionary(uniqueKeysWithValues: value.map {
            ($0.key.uuidString.lowercased(), $0.value)
        })
        return try encodeJSONString(payload, field: "workspace_settings_studyPadCursors")
    }

    /**
     Encodes one arbitrary `Encodable` payload into a UTF-8 JSON string.

     - Parameters:
       - value: Encodable payload to serialize.
       - field: Android column name used for error reporting.
     - Returns: UTF-8 JSON string.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when the payload cannot be encoded safely
     */
    private func encodeJSONString<Value: Encodable>(_ value: Value, field: String) throws -> String {
        let data: Data
        do {
            data = try jsonEncoder.encode(value)
        } catch {
            throw RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed(field: field)
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed(field: field)
        }
        return string
    }

    /**
     Executes one schema or pragma SQL batch against the open patch database.

     - Parameters:
       - sql: SQL batch to execute.
       - database: Open SQLite database handle.
     - Side effects: mutates the open SQLite database schema or metadata.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when SQLite rejects the statement batch
     */
    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Creates a new unique temporary URL beneath the configured temporary directory.

     - Parameters:
       - prefix: File-name prefix for the temporary file.
       - suffix: File-name suffix for the temporary file.
     - Returns: Temporary file URL that does not currently exist.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func temporaryURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    /**
     Derives the Android source-device name from the ready device-folder identifier.

     - Parameter deviceFolderID: Remote device-folder identifier stored in the bootstrap state.
     - Returns: Final path component used as the Android source-device name.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func sourceDeviceName(from deviceFolderID: String) -> String {
        let trimmed = deviceFolderID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? deviceFolderID
    }

    /**
     Sorts workspace rows into Android display order with UUID tie-breaking.

     - Parameters:
       - lhs: Left-hand workspace row.
       - rhs: Right-hand workspace row.
     - Returns: `true` when `lhs` should be inserted before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func workspaceSort(_ lhs: RemoteSyncCurrentWorkspaceRow, _ rhs: RemoteSyncCurrentWorkspaceRow) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    /**
     Sorts window rows into Android display order with UUID tie-breaking.

     - Parameters:
       - lhs: Left-hand window row.
       - rhs: Right-hand window row.
     - Returns: `true` when `lhs` should be inserted before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func windowSort(_ lhs: RemoteSyncCurrentWorkspaceWindowRow, _ rhs: RemoteSyncCurrentWorkspaceWindowRow) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    /**
     Sorts page-manager rows by owning window identifier.

     - Parameters:
       - lhs: Left-hand page-manager row.
       - rhs: Right-hand page-manager row.
     - Returns: `true` when `lhs` should be inserted before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func pageManagerSort(_ lhs: RemoteSyncCurrentWorkspacePageManagerRow, _ rhs: RemoteSyncCurrentWorkspacePageManagerRow) -> Bool {
        lhs.windowID.uuidString < rhs.windowID.uuidString
    }

    /**
     Binds one typed SQLite scalar value into a prepared statement parameter.

     - Parameters:
       - value: Typed SQLite value to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindSQLiteValue(
        _ value: RemoteSyncSQLiteValue,
        to statement: OpaquePointer,
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
            bindOptionalText(value.textValue, to: statement, index: index)
        case .blob:
            if let data = value.blobData {
                _ = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        bytes.baseAddress,
                        Int32(data.count),
                        remoteSyncWorkspacePatchUploadSQLiteTransient
                    )
                }
            } else {
                sqlite3_bind_null(statement, index)
            }
        }
    }

    /**
     Binds one required UTF-8 string into a prepared SQLite statement parameter.

     - Parameters:
       - value: Required text value.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindText(_ value: String, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, remoteSyncWorkspacePatchUploadSQLiteTransient)
    }

    /**
     Binds one optional UTF-8 string into a prepared SQLite statement parameter.

     - Parameters:
       - value: Optional text value.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalText(_ value: String?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindText(value, to: statement, index: index)
    }

    /**
     Binds one Boolean into a prepared SQLite statement parameter using Android's integer convention.

     - Parameters:
       - value: Boolean value to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindBool(_ value: Bool, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_int(statement, index, value ? 1 : 0)
    }

    /**
     Binds one optional Boolean into a prepared SQLite statement parameter using Android's integer convention.

     - Parameters:
       - value: Optional Boolean value.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalBool(_ value: Bool?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindBool(value, to: statement, index: index)
    }

    /**
     Binds one optional integer into a prepared SQLite statement parameter.

     - Parameters:
       - value: Optional integer value.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalInt(_ value: Int?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int(statement, index, Int32(value))
    }

    /**
     Binds one optional floating-point value into a prepared SQLite statement parameter.

     - Parameters:
       - value: Optional floating-point value.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalFloat(_ value: Float?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, Double(value))
    }

    /**
     Binds one UUID into Android's raw 16-byte SQLite BLOB format.

     - Parameters:
       - value: UUID value to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindUUIDBlob(_ value: UUID, to statement: OpaquePointer, index: Int32) {
        let data = RemoteSyncWorkspaceSnapshotService.uuidBlob(value)
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(data.count),
                remoteSyncWorkspacePatchUploadSQLiteTransient
            )
        }
    }

    /**
     Binds one optional UUID into Android's raw 16-byte SQLite BLOB format.

     - Parameters:
       - value: Optional UUID value to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalUUIDBlob(_ value: UUID?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindUUIDBlob(value, to: statement, index: index)
    }

    /**
     Sorts local Android log-entry payloads deterministically for stable settings persistence.

     - Parameters:
       - lhs: Left-hand log entry.
       - rhs: Right-hand log entry.
     - Returns: `true` when `lhs` should be ordered before `rhs`.
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
     Builds a deterministic string key used only for local ordering of SQLite value payloads.

     - Parameter value: Typed SQLite scalar value.
     - Returns: Canonical string preserving storage kind and payload.
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
