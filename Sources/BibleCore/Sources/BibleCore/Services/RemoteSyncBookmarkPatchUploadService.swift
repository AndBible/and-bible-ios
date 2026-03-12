// RemoteSyncBookmarkPatchUploadService.swift — Android-shaped outbound bookmark patch creation and upload

import Foundation
import SQLite3
import SwiftData

private let remoteSyncBookmarkPatchUploadSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while exporting and uploading an outbound Android bookmark patch.
 */
public enum RemoteSyncBookmarkPatchUploadError: Error, Equatable {
    /// The category is not ready for upload because no remote device folder identifier is known locally.
    case missingDeviceFolderID

    /// The generated temporary SQLite patch database could not be opened for writing.
    case invalidSQLiteDatabase
}

/**
 Summary of one successful outbound bookmark patch upload.

 Android bookmark sync spans nine content tables plus `LogEntry`. This report keeps enough detail to
 confirm that an outbound upload actually serialized the expected mix of bookmark-category rows.
 */
public struct RemoteSyncBookmarkPatchUploadReport: Sendable, Equatable {
    /// Remote file metadata returned by the backend after upload succeeded.
    public let uploadedFile: RemoteSyncFile

    /// Monotonic patch number assigned within the current device folder.
    public let patchNumber: Int64

    /// Number of `Label` rows written into the patch database.
    public let upsertedLabelCount: Int

    /// Number of `BibleBookmark` rows written into the patch database.
    public let upsertedBibleBookmarkCount: Int

    /// Number of `GenericBookmark` rows written into the patch database.
    public let upsertedGenericBookmarkCount: Int

    /// Number of `StudyPadTextEntry` rows written into the patch database.
    public let upsertedStudyPadEntryCount: Int

    /// Number of auxiliary note, link, and StudyPad-text rows written into the patch database.
    public let upsertedAuxiliaryRowCount: Int

    /// Number of `DELETE` log entries emitted for rows removed locally.
    public let deletedRowCount: Int

    /// Total number of Android `LogEntry` rows written into the patch database.
    public let logEntryCount: Int

    /// Millisecond timestamp recorded as `lastUpdated` for the emitted Android log entries.
    public let lastUpdated: Int64

    /**
     Creates one outbound bookmark patch-upload summary.

     - Parameters:
       - uploadedFile: Remote file metadata returned by the backend after upload succeeded.
       - patchNumber: Monotonic patch number assigned within the current device folder.
       - upsertedLabelCount: Number of `Label` rows written into the patch database.
       - upsertedBibleBookmarkCount: Number of `BibleBookmark` rows written into the patch database.
       - upsertedGenericBookmarkCount: Number of `GenericBookmark` rows written into the patch database.
       - upsertedStudyPadEntryCount: Number of `StudyPadTextEntry` rows written into the patch database.
       - upsertedAuxiliaryRowCount: Number of auxiliary note, link, and StudyPad-text rows written into the patch database.
       - deletedRowCount: Number of `DELETE` log entries emitted for rows removed locally.
       - logEntryCount: Total number of Android `LogEntry` rows written into the patch database.
       - lastUpdated: Millisecond timestamp recorded as `lastUpdated` for the emitted Android log entries.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        uploadedFile: RemoteSyncFile,
        patchNumber: Int64,
        upsertedLabelCount: Int,
        upsertedBibleBookmarkCount: Int,
        upsertedGenericBookmarkCount: Int,
        upsertedStudyPadEntryCount: Int,
        upsertedAuxiliaryRowCount: Int,
        deletedRowCount: Int,
        logEntryCount: Int,
        lastUpdated: Int64
    ) {
        self.uploadedFile = uploadedFile
        self.patchNumber = patchNumber
        self.upsertedLabelCount = upsertedLabelCount
        self.upsertedBibleBookmarkCount = upsertedBibleBookmarkCount
        self.upsertedGenericBookmarkCount = upsertedGenericBookmarkCount
        self.upsertedStudyPadEntryCount = upsertedStudyPadEntryCount
        self.upsertedAuxiliaryRowCount = upsertedAuxiliaryRowCount
        self.deletedRowCount = deletedRowCount
        self.logEntryCount = logEntryCount
        self.lastUpdated = lastUpdated
    }
}

/**
 Creates Android-shaped sparse bookmark patch databases and uploads them to the active backend.

 The service mirrors the outbound half of Android's bookmark sync contract:
 - project current local SwiftData bookmark state into Android `Label`, bookmark, note, link, and
   StudyPad rows
 - compare those rows against the preserved Android `LogEntry` baseline and local row fingerprints
 - emit sparse `UPSERT` and `DELETE` `LogEntry` rows for only the changed Android keys
 - write an Android-compatible SQLite patch database and gzip archive
 - upload `<patchNumber>.<schemaVersion>.sqlite3.gz` into the device folder
 - advance local `LogEntry`, `lastPatchWritten`, playback-fidelity state, and fingerprint baselines
   only after upload succeeds

 Data dependencies:
 - `RemoteSyncAdapting` performs the remote file upload
 - `RemoteSyncBookmarkSnapshotService` projects live SwiftData and local-only bookmark fidelity data
   into Android-shaped rows
 - `RemoteSyncLogEntryStore` provides the Android conflict baseline and is updated after success
 - `RemoteSyncBookmarkPlaybackSettingsStore` preserves accepted raw Android playback JSON for
   uploaded bookmark rows
 - `RemoteSyncPatchStatusStore` tracks the highest uploaded patch number for the local device folder
 - `RemoteSyncStateStore` persists Android-aligned `lastPatchWritten` bookkeeping
 - `RemoteSyncArchiveStagingService` provides gzip compression for the generated SQLite patch file

 Side effects:
 - reads live bookmark-category state from SwiftData and local-only fidelity settings
 - creates and removes temporary SQLite and gzip files beneath the configured temporary directory
 - uploads a gzip patch archive into the ready device folder
 - rewrites preserved bookmark playback JSON for uploaded or deleted bookmark rows
 - rewrites local Android `LogEntry` and fingerprint baselines for `.bookmarks` after success
 - appends one local patch status row and updates `lastPatchWritten`

 Failure modes:
 - throws `RemoteSyncBookmarkPatchUploadError.missingDeviceFolderID` when the category is not bootstrapped for outbound upload
 - throws `RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase` when the temporary SQLite patch file cannot be created
 - rethrows local filesystem write failures while building the temporary SQLite or gzip files
 - rethrows backend transport or local-file read failures from `RemoteSyncAdapting.upload`
 - rethrows gzip-compression failures from `RemoteSyncArchiveStagingService.gzip(_:)`

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement rules of the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncBookmarkPatchUploadService {
    private struct ChangeSet {
        let labelRowsByKey: [String: RemoteSyncAndroidLabel]
        let bibleBookmarkRowsByKey: [String: RemoteSyncAndroidBibleBookmark]
        let bibleNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow]
        let bibleLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow]
        let genericBookmarkRowsByKey: [String: RemoteSyncAndroidGenericBookmark]
        let genericNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow]
        let genericLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow]
        let studyPadEntryRowsByKey: [String: RemoteSyncAndroidStudyPadEntry]
        let studyPadTextRowsByKey: [String: RemoteSyncCurrentStudyPadTextRow]
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

        /**
         Returns the total number of auxiliary upsert rows in the change set.

         - Returns: Number of note, link, and StudyPad-text upserts.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        var auxiliaryUpsertCount: Int {
            bibleNoteRowsByKey.count
                + bibleLinkRowsByKey.count
                + genericNoteRowsByKey.count
                + genericLinkRowsByKey.count
                + studyPadTextRowsByKey.count
        }
    }

    private let adapter: any RemoteSyncAdapting
    private let snapshotService: RemoteSyncBookmarkSnapshotService
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let nowProvider: () -> Int64

    /**
     Creates a bookmark patch upload service for one remote backend.

     - Parameters:
       - adapter: Remote backend adapter used for the final archive upload.
       - snapshotService: Snapshot service used to project current local bookmark state into Android rows.
       - fileManager: File manager used for temporary-file cleanup.
       - temporaryDirectory: Scratch directory for temporary SQLite and gzip files. Defaults to the process temporary directory.
       - nowProvider: Millisecond clock used for Android `LogEntry.lastUpdated` and local `lastPatchWritten`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        adapter: any RemoteSyncAdapting,
        snapshotService: RemoteSyncBookmarkSnapshotService = RemoteSyncBookmarkSnapshotService(),
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
     Builds and uploads the next sparse bookmark patch when local state differs from the baseline.

     The service is intentionally conservative about missing fingerprint baselines. When it finds a
     preserved Android `LogEntry` row with no matching local fingerprint, it assumes the row came
     from a pre-fingerprint restore or replay and refreshes the baseline without uploading a patch.
     That avoids fabricating large false-positive patches the first time outbound diffing is enabled
     on an existing install.

     - Parameters:
       - bootstrapState: Ready bootstrap state for the bookmark category.
       - modelContext: SwiftData context that owns the live bookmark graph.
       - settingsStore: Local-only settings store backing preserved Android sync metadata.
       - schemaVersion: Schema version to encode into the generated patch filename and SQLite user version.
     - Returns: Upload summary when a sparse patch was emitted, or `nil` when no local changes need upload.
     - Side effects:
       - may refresh the fingerprint baseline without uploading when the service encounters historical rows with no stored fingerprints
       - creates and removes temporary SQLite and gzip files
       - uploads a gzip patch archive when local changes exist
       - rewrites local `LogEntry`, patch-status, playback-fidelity, progress, and fingerprint state after successful upload
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchUploadError.missingDeviceFolderID` when `bootstrapState.deviceFolderID` is missing or empty
       - throws `RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase` when the temporary SQLite patch file cannot be opened
       - rethrows filesystem, compression, and backend upload failures
     */
    public func uploadPendingPatch(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = 1
    ) async throws -> RemoteSyncBookmarkPatchUploadReport? {
        guard let deviceFolderID = bootstrapState.deviceFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceFolderID.isEmpty else {
            throw RemoteSyncBookmarkPatchUploadError.missingDeviceFolderID
        }

        let sourceDevice = Self.sourceDeviceName(from: deviceFolderID)
        let timestamp = nowProvider()
        let snapshot = snapshotService.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let playbackSettingsStore = RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)

        let existingEntriesByKey = Dictionary(
            uniqueKeysWithValues: logEntryStore.entries(for: .bookmarks).map {
                (logEntryStore.key(for: .bookmarks, entry: $0), $0)
            }
        )
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let hadMissingFingerprintBaseline = existingEntriesByKey.keys.contains { snapshot.fingerprintsByKey[$0] != nil }
            && existingEntriesByKey.contains { key, entry in
                if entry.type == .delete || snapshot.fingerprintsByKey[key] == nil {
                    return false
                }
                return fingerprintStore.fingerprint(
                    for: .bookmarks,
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
            for: .bookmarks,
            sourceDevice: sourceDevice
        ) ?? 0) + 1
        let patchFileName = "\(patchNumber).\(schemaVersion).sqlite3.gz"

        let databaseURL = temporaryURL(prefix: "remote-sync-bookmarks-upload-", suffix: ".sqlite3")
        let archiveURL = temporaryURL(prefix: "remote-sync-bookmarks-upload-", suffix: ".sqlite3.gz")
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

        persistAcceptedPlaybackSettings(
            bibleRows: changeSet.bibleBookmarkRowsByKey.values,
            genericRows: changeSet.genericBookmarkRowsByKey.values,
            playbackSettingsStore: playbackSettingsStore
        )
        removeDeletedPlaybackSettings(changeSet.logEntries, from: playbackSettingsStore)
        logEntryStore.replaceEntries(
            changeSet.updatedEntriesByKey.values.sorted(by: Self.logEntrySort),
            for: .bookmarks
        )
        patchStatusStore.addStatus(
            RemoteSyncPatchStatus(
                sourceDevice: sourceDevice,
                patchNumber: patchNumber,
                sizeBytes: uploadedFile.size,
                appliedDate: timestamp
            ),
            for: .bookmarks
        )
        var progressState = stateStore.progressState(for: .bookmarks)
        progressState.lastPatchWritten = timestamp
        stateStore.setProgressState(progressState, for: .bookmarks)
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        return RemoteSyncBookmarkPatchUploadReport(
            uploadedFile: uploadedFile,
            patchNumber: patchNumber,
            upsertedLabelCount: changeSet.labelRowsByKey.count,
            upsertedBibleBookmarkCount: changeSet.bibleBookmarkRowsByKey.count,
            upsertedGenericBookmarkCount: changeSet.genericBookmarkRowsByKey.count,
            upsertedStudyPadEntryCount: changeSet.studyPadEntryRowsByKey.count,
            upsertedAuxiliaryRowCount: changeSet.auxiliaryUpsertCount,
            deletedRowCount: changeSet.deletedRowCount,
            logEntryCount: changeSet.logEntries.count,
            lastUpdated: timestamp
        )
    }

    /**
     Computes the sparse Android row diff for the current bookmark snapshot.

     - Parameters:
       - snapshot: Current local bookmark state projected into Android-shaped rows.
       - existingEntriesByKey: Existing Android `LogEntry` baseline keyed by Android composite key.
       - fingerprintStore: Local fingerprint store used to compare current rows against the last uploaded baseline.
       - timestamp: Millisecond timestamp to assign to any emitted outbound `LogEntry` rows.
       - sourceDevice: Local source-device folder name that should own the outbound patch rows.
     - Returns: Sparse change set containing upserted rows, delete entries, and the updated local metadata baseline.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func buildChangeSet(
        snapshot: RemoteSyncBookmarkCurrentSnapshot,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore,
        timestamp: Int64,
        sourceDevice: String
    ) -> ChangeSet {
        var labelRowsByKey: [String: RemoteSyncAndroidLabel] = [:]
        var bibleBookmarkRowsByKey: [String: RemoteSyncAndroidBibleBookmark] = [:]
        var bibleNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow] = [:]
        var bibleLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow] = [:]
        var genericBookmarkRowsByKey: [String: RemoteSyncAndroidGenericBookmark] = [:]
        var genericNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow] = [:]
        var genericLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow] = [:]
        var studyPadEntryRowsByKey: [String: RemoteSyncAndroidStudyPadEntry] = [:]
        var studyPadTextRowsByKey: [String: RemoteSyncCurrentStudyPadTextRow] = [:]
        var logEntries: [RemoteSyncLogEntry] = []
        var updatedEntriesByKey = existingEntriesByKey

        for (key, row) in snapshot.labelRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "Label",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.id)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            labelRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.bibleBookmarkRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "BibleBookmark",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.id)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            bibleBookmarkRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.bibleNoteRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "BibleBookmarkNotes",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.bookmarkID)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            bibleNoteRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.bibleLinkRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "BibleBookmarkToLabel",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.bookmarkID)),
                entityID2: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.labelID)),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            bibleLinkRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.genericBookmarkRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "GenericBookmark",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.id)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            genericBookmarkRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.genericNoteRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "GenericBookmarkNotes",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.bookmarkID)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            genericNoteRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.genericLinkRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "GenericBookmarkToLabel",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.bookmarkID)),
                entityID2: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.labelID)),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            genericLinkRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.studyPadEntryRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "StudyPadTextEntry",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.id)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            studyPadEntryRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.studyPadTextRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: "StudyPadTextEntryText",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.entryID)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            studyPadTextRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, entry) in existingEntriesByKey.sorted(by: { $0.key < $1.key }) {
            guard entry.type != .delete else {
                continue
            }
            guard snapshot.fingerprintsByKey[key] == nil else {
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
            labelRowsByKey: labelRowsByKey,
            bibleBookmarkRowsByKey: bibleBookmarkRowsByKey,
            bibleNoteRowsByKey: bibleNoteRowsByKey,
            bibleLinkRowsByKey: bibleLinkRowsByKey,
            genericBookmarkRowsByKey: genericBookmarkRowsByKey,
            genericNoteRowsByKey: genericNoteRowsByKey,
            genericLinkRowsByKey: genericLinkRowsByKey,
            studyPadEntryRowsByKey: studyPadEntryRowsByKey,
            studyPadTextRowsByKey: studyPadTextRowsByKey,
            logEntries: logEntries.sorted(by: Self.logEntrySort),
            updatedEntriesByKey: updatedEntriesByKey
        )
    }

    /**
     Persists the accepted bookmark playback payloads emitted by a successful upload.

     - Parameters:
       - bibleRows: Uploaded Android-shaped Bible bookmark rows.
       - genericRows: Uploaded Android-shaped generic bookmark rows.
       - playbackSettingsStore: Local-only playback-settings store to update.
     - Side effects:
       - writes or removes preserved raw Android playback JSON for uploaded bookmark rows
     - Failure modes:
       - underlying playback-store persistence failures are swallowed by `SettingsStore`
     */
    private func persistAcceptedPlaybackSettings(
        bibleRows: some Sequence<RemoteSyncAndroidBibleBookmark>,
        genericRows: some Sequence<RemoteSyncAndroidGenericBookmark>,
        playbackSettingsStore: RemoteSyncBookmarkPlaybackSettingsStore
    ) {
        for row in bibleRows {
            if let playbackSettingsJSON = row.playbackSettingsJSON, !playbackSettingsJSON.isEmpty {
                playbackSettingsStore.setPlaybackSettingsJSON(
                    playbackSettingsJSON,
                    for: row.id,
                    kind: .bible
                )
            } else {
                playbackSettingsStore.removePlaybackSettings(for: row.id, kind: .bible)
            }
        }

        for row in genericRows {
            if let playbackSettingsJSON = row.playbackSettingsJSON, !playbackSettingsJSON.isEmpty {
                playbackSettingsStore.setPlaybackSettingsJSON(
                    playbackSettingsJSON,
                    for: row.id,
                    kind: .generic
                )
            } else {
                playbackSettingsStore.removePlaybackSettings(for: row.id, kind: .generic)
            }
        }
    }

    /**
     Removes preserved bookmark playback payloads for rows deleted by the current upload.

     - Parameters:
       - logEntries: Log entries emitted by the current upload.
       - playbackSettingsStore: Local-only playback-settings store to update.
     - Side effects:
       - deletes preserved raw Android playback JSON when the upload emitted matching bookmark deletes
     - Failure modes:
       - malformed or non-UUID `entityId1` values are ignored
       - underlying playback-store persistence failures are swallowed by `SettingsStore`
     */
    private func removeDeletedPlaybackSettings(
        _ logEntries: some Sequence<RemoteSyncLogEntry>,
        from playbackSettingsStore: RemoteSyncBookmarkPlaybackSettingsStore
    ) {
        for entry in logEntries where entry.type == .delete {
            switch entry.tableName {
            case "BibleBookmark":
                guard let bookmarkID = Self.uuid(from: entry.entityID1) else {
                    continue
                }
                playbackSettingsStore.removePlaybackSettings(for: bookmarkID, kind: .bible)
            case "GenericBookmark":
                guard let bookmarkID = Self.uuid(from: entry.entityID1) else {
                    continue
                }
                playbackSettingsStore.removePlaybackSettings(for: bookmarkID, kind: .generic)
            default:
                continue
            }
        }
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
                category: .bookmarks
            ) {
                return existingFingerprint != currentFingerprint
            }
            return true
        }

        if existingEntry.type == .delete {
            return true
        }

        let existingFingerprint = fingerprintStore.fingerprint(
            for: .bookmarks,
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
     Writes one sparse Android bookmark patch database to the supplied SQLite URL.

     - Parameters:
       - url: Temporary SQLite file URL to create.
       - schemaVersion: SQLite user version that should be written to the patch database.
       - changeSet: Sparse current-row diff that should be serialized.
     - Side effects:
       - creates and writes a temporary SQLite database file
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase` when the file cannot be opened for writing
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
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        try execute(
            """
            PRAGMA user_version = \(schemaVersion);
            CREATE TABLE Label (
                id BLOB NOT NULL PRIMARY KEY,
                name TEXT NOT NULL,
                color INTEGER NOT NULL DEFAULT 0,
                markerStyle INTEGER NOT NULL DEFAULT 0,
                markerStyleWholeVerse INTEGER NOT NULL DEFAULT 0,
                underlineStyle INTEGER NOT NULL DEFAULT 0,
                underlineStyleWholeVerse INTEGER NOT NULL DEFAULT 0,
                hideStyle INTEGER NOT NULL DEFAULT 0,
                hideStyleWholeVerse INTEGER NOT NULL DEFAULT 0,
                favourite INTEGER NOT NULL DEFAULT 0,
                type TEXT DEFAULT NULL,
                customIcon TEXT DEFAULT NULL
            );
            CREATE TABLE BibleBookmark (
                kjvOrdinalStart INTEGER NOT NULL,
                kjvOrdinalEnd INTEGER NOT NULL,
                ordinalStart INTEGER NOT NULL,
                ordinalEnd INTEGER NOT NULL,
                v11n TEXT NOT NULL,
                playbackSettings TEXT DEFAULT NULL,
                id BLOB NOT NULL PRIMARY KEY,
                createdAt INTEGER NOT NULL,
                book TEXT DEFAULT NULL,
                startOffset INTEGER DEFAULT NULL,
                endOffset INTEGER DEFAULT NULL,
                primaryLabelId BLOB DEFAULT NULL,
                lastUpdatedOn INTEGER NOT NULL DEFAULT 0,
                wholeVerse INTEGER NOT NULL DEFAULT 0,
                type TEXT DEFAULT NULL,
                customIcon TEXT DEFAULT NULL,
                editAction_mode TEXT DEFAULT NULL,
                editAction_content TEXT DEFAULT NULL
            );
            CREATE TABLE BibleBookmarkNotes (
                bookmarkId BLOB NOT NULL PRIMARY KEY,
                notes TEXT NOT NULL
            );
            CREATE TABLE BibleBookmarkToLabel (
                bookmarkId BLOB NOT NULL,
                labelId BLOB NOT NULL,
                orderNumber INTEGER NOT NULL DEFAULT -1,
                indentLevel INTEGER NOT NULL DEFAULT 0,
                expandContent INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (bookmarkId, labelId)
            );
            CREATE TABLE GenericBookmark (
                id BLOB NOT NULL PRIMARY KEY,
                `key` TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                bookInitials TEXT NOT NULL DEFAULT '',
                ordinalStart INTEGER NOT NULL,
                ordinalEnd INTEGER NOT NULL,
                startOffset INTEGER DEFAULT NULL,
                endOffset INTEGER DEFAULT NULL,
                primaryLabelId BLOB DEFAULT NULL,
                lastUpdatedOn INTEGER NOT NULL DEFAULT 0,
                wholeVerse INTEGER NOT NULL DEFAULT 0,
                playbackSettings TEXT DEFAULT NULL,
                customIcon TEXT DEFAULT NULL,
                editAction_mode TEXT DEFAULT NULL,
                editAction_content TEXT DEFAULT NULL
            );
            CREATE TABLE GenericBookmarkNotes (
                bookmarkId BLOB NOT NULL PRIMARY KEY,
                notes TEXT NOT NULL
            );
            CREATE TABLE GenericBookmarkToLabel (
                bookmarkId BLOB NOT NULL,
                labelId BLOB NOT NULL,
                orderNumber INTEGER NOT NULL DEFAULT -1,
                indentLevel INTEGER NOT NULL DEFAULT 0,
                expandContent INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (bookmarkId, labelId)
            );
            CREATE TABLE StudyPadTextEntry (
                id BLOB NOT NULL PRIMARY KEY,
                labelId BLOB NOT NULL,
                orderNumber INTEGER NOT NULL,
                indentLevel INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE StudyPadTextEntryText (
                studyPadTextEntryId BLOB NOT NULL PRIMARY KEY,
                text TEXT NOT NULL
            );
            CREATE TABLE LogEntry (
                tableName TEXT NOT NULL,
                entityId1 BLOB NOT NULL,
                entityId2 BLOB,
                type TEXT NOT NULL,
                lastUpdated INTEGER NOT NULL,
                sourceDevice TEXT NOT NULL,
                PRIMARY KEY (tableName, entityId1, entityId2)
            );
            """,
            in: database
        )

        for row in changeSet.labelRowsByKey.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try insertLabelRow(row, in: database)
        }
        for row in changeSet.bibleBookmarkRowsByKey.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try insertBibleBookmarkRow(row, in: database)
        }
        for row in changeSet.bibleNoteRowsByKey.values.sorted(by: { $0.bookmarkID.uuidString < $1.bookmarkID.uuidString }) {
            try insertBookmarkNoteRow(row, tableName: "BibleBookmarkNotes", in: database)
        }
        for row in changeSet.bibleLinkRowsByKey.values.sorted(by: Self.labelLinkSort) {
            try insertBookmarkLabelLinkRow(row, tableName: "BibleBookmarkToLabel", in: database)
        }
        for row in changeSet.genericBookmarkRowsByKey.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try insertGenericBookmarkRow(row, in: database)
        }
        for row in changeSet.genericNoteRowsByKey.values.sorted(by: { $0.bookmarkID.uuidString < $1.bookmarkID.uuidString }) {
            try insertBookmarkNoteRow(row, tableName: "GenericBookmarkNotes", in: database)
        }
        for row in changeSet.genericLinkRowsByKey.values.sorted(by: Self.labelLinkSort) {
            try insertBookmarkLabelLinkRow(row, tableName: "GenericBookmarkToLabel", in: database)
        }
        for row in changeSet.studyPadEntryRowsByKey.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try insertStudyPadEntryRow(row, in: database)
        }
        for row in changeSet.studyPadTextRowsByKey.values.sorted(by: { $0.entryID.uuidString < $1.entryID.uuidString }) {
            try insertStudyPadTextRow(row, in: database)
        }
        for entry in changeSet.logEntries {
            try insertLogEntry(entry, in: database)
        }
    }

    /**
     Inserts one Android `Label` row into the open patch database.

     - Parameters:
       - row: Android-shaped label row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `Label` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertLabelRow(_ row: RemoteSyncAndroidLabel, in database: OpaquePointer) throws {
        let sql = "INSERT INTO Label (id, name, color, markerStyle, markerStyleWholeVerse, underlineStyle, underlineStyleWholeVerse, hideStyle, hideStyleWholeVerse, favourite, type, customIcon) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.id, to: statement, index: 1)
        sqlite3_bind_text(statement, 2, row.name, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        sqlite3_bind_int(statement, 3, Int32(row.color))
        sqlite3_bind_int(statement, 4, row.markerStyle ? 1 : 0)
        sqlite3_bind_int(statement, 5, row.markerStyleWholeVerse ? 1 : 0)
        sqlite3_bind_int(statement, 6, row.underlineStyle ? 1 : 0)
        sqlite3_bind_int(statement, 7, row.underlineStyleWholeVerse ? 1 : 0)
        sqlite3_bind_int(statement, 8, row.hideStyle ? 1 : 0)
        sqlite3_bind_int(statement, 9, row.hideStyleWholeVerse ? 1 : 0)
        sqlite3_bind_int(statement, 10, row.favourite ? 1 : 0)
        Self.bindOptionalText(row.type, to: statement, index: 11)
        Self.bindOptionalText(row.customIcon, to: statement, index: 12)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `BibleBookmark` row into the open patch database.

     - Parameters:
       - row: Android-shaped Bible bookmark row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `BibleBookmark` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertBibleBookmarkRow(_ row: RemoteSyncAndroidBibleBookmark, in database: OpaquePointer) throws {
        let sql = "INSERT INTO BibleBookmark (kjvOrdinalStart, kjvOrdinalEnd, ordinalStart, ordinalEnd, v11n, playbackSettings, id, createdAt, book, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse, type, customIcon, editAction_mode, editAction_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(row.kjvOrdinalStart))
        sqlite3_bind_int(statement, 2, Int32(row.kjvOrdinalEnd))
        sqlite3_bind_int(statement, 3, Int32(row.ordinalStart))
        sqlite3_bind_int(statement, 4, Int32(row.ordinalEnd))
        sqlite3_bind_text(statement, 5, row.v11n, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        Self.bindOptionalText(row.playbackSettingsJSON, to: statement, index: 6)
        Self.bindUUIDBlob(row.id, to: statement, index: 7)
        sqlite3_bind_int64(statement, 8, Int64(row.createdAt.timeIntervalSince1970 * 1000.0))
        Self.bindOptionalText(row.book, to: statement, index: 9)
        Self.bindOptionalInt(row.startOffset, to: statement, index: 10)
        Self.bindOptionalInt(row.endOffset, to: statement, index: 11)
        Self.bindOptionalUUIDBlob(row.primaryLabelID, to: statement, index: 12)
        sqlite3_bind_int64(statement, 13, Int64(row.lastUpdatedOn.timeIntervalSince1970 * 1000.0))
        sqlite3_bind_int(statement, 14, row.wholeVerse ? 1 : 0)
        Self.bindOptionalText(row.type, to: statement, index: 15)
        Self.bindOptionalText(row.customIcon, to: statement, index: 16)
        Self.bindOptionalText(row.editAction?.mode?.rawValue, to: statement, index: 17)
        Self.bindOptionalText(row.editAction?.content, to: statement, index: 18)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one detached bookmark-note row into the open patch database.

     - Parameters:
       - row: Android-shaped bookmark-note row to insert.
       - tableName: Either `BibleBookmarkNotes` or `GenericBookmarkNotes`.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the supplied note table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertBookmarkNoteRow(
        _ row: RemoteSyncCurrentBookmarkNoteRow,
        tableName: String,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO \(tableName) (bookmarkId, notes) VALUES (?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.bookmarkID, to: statement, index: 1)
        sqlite3_bind_text(statement, 2, row.notes, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one bookmark-to-label junction row into the open patch database.

     - Parameters:
       - row: Android-shaped bookmark-to-label row to insert.
       - tableName: Either `BibleBookmarkToLabel` or `GenericBookmarkToLabel`.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the supplied junction table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertBookmarkLabelLinkRow(
        _ row: RemoteSyncCurrentBookmarkLabelLinkRow,
        tableName: String,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO \(tableName) (bookmarkId, labelId, orderNumber, indentLevel, expandContent) VALUES (?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.bookmarkID, to: statement, index: 1)
        Self.bindUUIDBlob(row.labelID, to: statement, index: 2)
        sqlite3_bind_int(statement, 3, Int32(row.orderNumber))
        sqlite3_bind_int(statement, 4, Int32(row.indentLevel))
        sqlite3_bind_int(statement, 5, row.expandContent ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `GenericBookmark` row into the open patch database.

     - Parameters:
       - row: Android-shaped generic bookmark row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `GenericBookmark` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertGenericBookmarkRow(_ row: RemoteSyncAndroidGenericBookmark, in database: OpaquePointer) throws {
        let sql = "INSERT INTO GenericBookmark (id, `key`, createdAt, bookInitials, ordinalStart, ordinalEnd, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse, playbackSettings, customIcon, editAction_mode, editAction_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.id, to: statement, index: 1)
        sqlite3_bind_text(statement, 2, row.key, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        sqlite3_bind_int64(statement, 3, Int64(row.createdAt.timeIntervalSince1970 * 1000.0))
        sqlite3_bind_text(statement, 4, row.bookInitials, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        sqlite3_bind_int(statement, 5, Int32(row.ordinalStart))
        sqlite3_bind_int(statement, 6, Int32(row.ordinalEnd))
        Self.bindOptionalInt(row.startOffset, to: statement, index: 7)
        Self.bindOptionalInt(row.endOffset, to: statement, index: 8)
        Self.bindOptionalUUIDBlob(row.primaryLabelID, to: statement, index: 9)
        sqlite3_bind_int64(statement, 10, Int64(row.lastUpdatedOn.timeIntervalSince1970 * 1000.0))
        sqlite3_bind_int(statement, 11, row.wholeVerse ? 1 : 0)
        Self.bindOptionalText(row.playbackSettingsJSON, to: statement, index: 12)
        Self.bindOptionalText(row.customIcon, to: statement, index: 13)
        Self.bindOptionalText(row.editAction?.mode?.rawValue, to: statement, index: 14)
        Self.bindOptionalText(row.editAction?.content, to: statement, index: 15)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `StudyPadTextEntry` row into the open patch database.

     - Parameters:
       - row: Android-shaped StudyPad entry row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `StudyPadTextEntry` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertStudyPadEntryRow(_ row: RemoteSyncAndroidStudyPadEntry, in database: OpaquePointer) throws {
        let sql = "INSERT INTO StudyPadTextEntry (id, labelId, orderNumber, indentLevel) VALUES (?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.id, to: statement, index: 1)
        Self.bindUUIDBlob(row.labelID, to: statement, index: 2)
        sqlite3_bind_int(statement, 3, Int32(row.orderNumber))
        sqlite3_bind_int(statement, 4, Int32(row.indentLevel))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `StudyPadTextEntryText` row into the open patch database.

     - Parameters:
       - row: Android-shaped StudyPad text row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `StudyPadTextEntryText` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertStudyPadTextRow(_ row: RemoteSyncCurrentStudyPadTextRow, in database: OpaquePointer) throws {
        let sql = "INSERT INTO StudyPadTextEntryText (studyPadTextEntryId, text) VALUES (?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.entryID, to: statement, index: 1)
        sqlite3_bind_text(statement, 2, row.text, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `LogEntry` row into the open patch database.

     - Parameters:
       - entry: Android log entry to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `LogEntry` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertLogEntry(_ entry: RemoteSyncLogEntry, in database: OpaquePointer) throws {
        let sql = "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, entry.tableName, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        Self.bindSQLiteValue(entry.entityID1, to: statement, index: 2)
        Self.bindSQLiteValue(entry.entityID2, to: statement, index: 3)
        sqlite3_bind_text(statement, 4, entry.type.rawValue, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        sqlite3_bind_int64(statement, 5, entry.lastUpdated)
        sqlite3_bind_text(statement, 6, entry.sourceDevice, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Executes one schema or pragma SQL batch against the open patch database.

     - Parameters:
       - sql: SQL batch to execute.
       - database: Open SQLite database handle.
     - Side effects: mutates the open SQLite database schema or metadata.
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase` when SQLite rejects the statement batch
     */
    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
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
     Binds one required UUID into a prepared SQLite statement parameter as Android's raw 16-byte blob.

     - Parameters:
       - uuid: UUID to bind.
       - statement: Prepared SQLite statement receiving the value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindUUIDBlob(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
        let data = RemoteSyncBookmarkSnapshotService.uuidBlob(uuid)
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(data.count),
                remoteSyncBookmarkPatchUploadSQLiteTransient
            )
        }
    }

    /**
     Binds one optional UUID into a prepared SQLite statement parameter.

     - Parameters:
       - uuid: Optional UUID to bind.
       - statement: Prepared SQLite statement receiving the value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalUUIDBlob(_ uuid: UUID?, to statement: OpaquePointer?, index: Int32) {
        guard let uuid else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindUUIDBlob(uuid, to: statement, index: index)
    }

    /**
     Binds one optional text value into a prepared SQLite statement parameter.

     - Parameters:
       - value: Optional text payload to bind.
       - statement: Prepared SQLite statement receiving the value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
    }

    /**
     Binds one optional integer value into a prepared SQLite statement parameter.

     - Parameters:
       - value: Optional integer payload to bind.
       - statement: Prepared SQLite statement receiving the value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalInt(_ value: Int?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int(statement, index, Int32(value))
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
            sqlite3_bind_text(
                statement,
                index,
                value.textValue ?? "",
                -1,
                remoteSyncBookmarkPatchUploadSQLiteTransient
            )
        case .blob:
            let data = value.blobData ?? Data()
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement,
                    index,
                    bytes.baseAddress,
                    Int32(data.count),
                    remoteSyncBookmarkPatchUploadSQLiteTransient
                )
            }
        }
    }

    /**
     Decodes one UUID from a typed SQLite scalar when the payload is a 16-byte BLOB.

     - Parameter value: Typed SQLite scalar value to decode.
     - Returns: UUID represented by the blob, or `nil` when the value is not a 16-byte blob.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func uuid(from value: RemoteSyncSQLiteValue) -> UUID? {
        guard value.kind == .blob,
              let data = value.blobData,
              data.count == 16 else {
            return nil
        }
        let bytes = Array(data)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /**
     Sorts bookmark-to-label rows into a deterministic order for patch serialization.

     - Parameters:
       - lhs: First bookmark-to-label row to compare.
       - rhs: Second bookmark-to-label row to compare.
     - Returns: `true` when `lhs` should appear before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func labelLinkSort(
        _ lhs: RemoteSyncCurrentBookmarkLabelLinkRow,
        _ rhs: RemoteSyncCurrentBookmarkLabelLinkRow
    ) -> Bool {
        if lhs.bookmarkID == rhs.bookmarkID {
            if lhs.orderNumber == rhs.orderNumber {
                return lhs.labelID.uuidString < rhs.labelID.uuidString
            }
            return lhs.orderNumber < rhs.orderNumber
        }
        return lhs.bookmarkID.uuidString < rhs.bookmarkID.uuidString
    }

    /**
     Sorts Android log entries into a deterministic patch-write order.

     - Parameters:
       - lhs: First log entry to compare.
       - rhs: Second log entry to compare.
     - Returns: `true` when `lhs` should appear before `rhs`.
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
