// RemoteSyncBookmarkPatchApplyService.swift — Incremental Android patch replay for bookmarks

import CLibSword
import Foundation
import SQLite3
import SwiftData

private let remoteSyncBookmarkPatchSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while replaying Android bookmark patch archives against the local SwiftData graph.

 Bookmark patches use a broader table set than reading plans and include both single-column and
 composite primary keys. The error surface distinguishes malformed patch metadata from patch
 databases that omit a referenced content row so sync diagnostics can explain which contract was
 violated.
 */
public enum RemoteSyncBookmarkPatchApplyError: Error, Equatable {
    /// One Android `LogEntry` identifier could not be converted into the expected UUID row key.
    case invalidLogEntryIdentifier(table: String, field: String)

    /// One `UPSERT` log entry referenced a row that was not present in the staged patch database.
    case missingPatchRow(table: String, entityID1: UUID, entityID2: UUID?)
}

/**
 Summary of one successful bookmark patch replay batch.

 Higher layers need both the patch-level counts and the final bookmark restore summary because the
 replay engine stages Android patch rows in memory and then rewrites the whole local bookmark graph
 through `RemoteSyncBookmarkRestoreService`.
 */
public struct RemoteSyncBookmarkPatchApplyReport: Sendable, Equatable {
    /// Number of patch archives applied successfully.
    public let appliedPatchCount: Int

    /// Number of remote `LogEntry` rows that won Android's timestamp comparison and were replayed.
    public let appliedLogEntryCount: Int

    /// Number of remote `LogEntry` rows skipped because a local row was newer or equal.
    public let skippedLogEntryCount: Int

    /// Final bookmark restore summary produced by the centralized rewrite path.
    public let restoreReport: RemoteSyncBookmarkRestoreReport

    /**
     Creates one bookmark patch replay summary.

     - Parameters:
       - appliedPatchCount: Number of patch archives applied successfully.
       - appliedLogEntryCount: Number of remote `LogEntry` rows replayed locally.
       - skippedLogEntryCount: Number of remote `LogEntry` rows skipped due to local precedence.
       - restoreReport: Final bookmark restore summary produced after replay completed.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        appliedPatchCount: Int,
        appliedLogEntryCount: Int,
        skippedLogEntryCount: Int,
        restoreReport: RemoteSyncBookmarkRestoreReport
    ) {
        self.appliedPatchCount = appliedPatchCount
        self.appliedLogEntryCount = appliedLogEntryCount
        self.skippedLogEntryCount = skippedLogEntryCount
        self.restoreReport = restoreReport
    }
}

/**
 Replays Android bookmark patch archives into the local SwiftData bookmark graph.

 Android treats the bookmark sync database as one category spanning labels, Bible bookmarks,
 generic bookmarks, detached notes, bookmark-to-label junction rows, and StudyPad rows. Patch
 replay therefore cannot update a single SwiftData entity in isolation. Instead this service:

 - projects the current local SwiftData graph and local-only fidelity stores into a remote-ID
   working snapshot
 - applies Android patch rows in the same per-table order used by `SyncUtilities.readPatchData`
 - runs the Android-style foreign-key cleanup step for every table, even when the patch contains no
   rows for that table, so parent deletions in earlier tables are reflected in later child tables
 - hands the final working snapshot to `RemoteSyncBookmarkRestoreService.replaceLocalBookmarks`
   so the destructive local rewrite stays centralized in one code path

 iOS stores reserved system labels under deterministic UUIDs, while Android patch rows reference the
 original remote UUIDs. The working snapshot therefore stays in remote-ID space until the final
 restore handoff, using `RemoteSyncBookmarkLabelAliasStore` to translate current local system-label
 rows back to their Android identifiers.

 Data dependencies:
 - `RemoteSyncBookmarkRestoreService` performs the final SwiftData rewrite and fidelity-store refresh
 - `RemoteSyncInitialBackupMetadataRestoreService` reads Android `LogEntry` rows from staged patch files
 - `RemoteSyncLogEntryStore` provides the local Android conflict baseline for timestamp comparison
 - `RemoteSyncPatchStatusStore` records successfully applied patch archives per source device
 - `RemoteSyncBookmarkSnapshotService` refreshes outbound bookmark fingerprint baselines after replay
 - `RemoteSyncBookmarkPlaybackSettingsStore` supplies preserved raw Android playback JSON while the
   current local graph is projected into remote-ID working rows
 - `RemoteSyncBookmarkLabelAliasStore` supplies Android-to-iOS reserved-label aliases for the same
   remote-ID projection

 Side effects:
 - reads the current local bookmark-category SwiftData graph and local-only fidelity stores
 - creates and removes temporary decompressed SQLite files beneath the configured temporary directory
 - rewrites the local bookmark-category SwiftData graph after the full batch succeeds
 - replaces local Android `LogEntry` metadata for `.bookmarks`
 - refreshes outbound bookmark fingerprint baselines after successful replay
 - appends applied-patch bookkeeping rows to `RemoteSyncPatchStatusStore`

 Failure modes:
 - throws `RemoteSyncArchiveStagingError.decompressionFailed` when a staged gzip archive cannot be extracted
 - rethrows `RemoteSyncInitialBackupMetadataRestoreError` when staged `LogEntry` rows are malformed
 - throws `RemoteSyncBookmarkPatchApplyError.invalidLogEntryIdentifier` when a patch log row does not use the expected UUID keys
 - throws `RemoteSyncBookmarkPatchApplyError.missingPatchRow` when an `UPSERT` row has no matching content row in the patch database
 - rethrows `RemoteSyncBookmarkRestoreError` when the final normalized snapshot is not representable by the centralized restore path
 - rethrows SwiftData fetch and save failures from the supplied `ModelContext`

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement of the supplied `ModelContext`
   and `SettingsStore`
 */
public final class RemoteSyncBookmarkPatchApplyService {
    private struct WorkingLabel {
        var id: UUID
        var name: String
        var color: Int
        var markerStyle: Bool
        var markerStyleWholeVerse: Bool
        var underlineStyle: Bool
        var underlineStyleWholeVerse: Bool
        var hideStyle: Bool
        var hideStyleWholeVerse: Bool
        var favourite: Bool
        var type: String?
        var customIcon: String?
    }

    private struct WorkingBibleBookmark {
        var id: UUID
        var kjvOrdinalStart: Int
        var kjvOrdinalEnd: Int
        var ordinalStart: Int
        var ordinalEnd: Int
        var v11n: String
        var playbackSettingsJSON: String?
        var createdAt: Date
        var book: String?
        var startOffset: Int?
        var endOffset: Int?
        var primaryLabelID: UUID?
        var notes: String?
        var lastUpdatedOn: Date
        var wholeVerse: Bool
        var type: String?
        var customIcon: String?
        var editAction: EditAction?
        var labelLinks: [RemoteSyncAndroidBookmarkLabelLink]
    }

    private struct WorkingGenericBookmark {
        var id: UUID
        var key: String
        var createdAt: Date
        var bookInitials: String
        var ordinalStart: Int
        var ordinalEnd: Int
        var startOffset: Int?
        var endOffset: Int?
        var primaryLabelID: UUID?
        var notes: String?
        var lastUpdatedOn: Date
        var wholeVerse: Bool
        var playbackSettingsJSON: String?
        var customIcon: String?
        var editAction: EditAction?
        var labelLinks: [RemoteSyncAndroidBookmarkLabelLink]
    }

    private struct WorkingStudyPadEntry {
        var id: UUID
        var labelID: UUID
        var orderNumber: Int
        var indentLevel: Int
        var text: String?
    }

    private struct WorkingSnapshot {
        var labelsByID: [UUID: WorkingLabel]
        var bibleBookmarksByID: [UUID: WorkingBibleBookmark]
        var genericBookmarksByID: [UUID: WorkingGenericBookmark]
        var studyPadEntriesByID: [UUID: WorkingStudyPadEntry]

        /**
         Materializes the mutable remote-ID working rows into the immutable snapshot shape expected by the centralized restore service.

         - Returns: Deterministically sorted bookmark snapshot ready for `replaceLocalBookmarks`.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         - Note: StudyPad entries without a preserved text row normalize to an empty string here because the iOS restore path stores StudyPad content inline on the value type instead of as a separate optional child row.
         */
        func materializedSnapshot() -> RemoteSyncAndroidBookmarkSnapshot {
            RemoteSyncAndroidBookmarkSnapshot(
                labels: labelsByID.values
                    .map {
                        RemoteSyncAndroidLabel(
                            id: $0.id,
                            name: $0.name,
                            color: $0.color,
                            markerStyle: $0.markerStyle,
                            markerStyleWholeVerse: $0.markerStyleWholeVerse,
                            underlineStyle: $0.underlineStyle,
                            underlineStyleWholeVerse: $0.underlineStyleWholeVerse,
                            hideStyle: $0.hideStyle,
                            hideStyleWholeVerse: $0.hideStyleWholeVerse,
                            favourite: $0.favourite,
                            type: $0.type,
                            customIcon: $0.customIcon
                        )
                    }
                    .sorted(by: Self.labelSort),
                bibleBookmarks: bibleBookmarksByID.values
                    .map {
                        RemoteSyncAndroidBibleBookmark(
                            id: $0.id,
                            kjvOrdinalStart: $0.kjvOrdinalStart,
                            kjvOrdinalEnd: $0.kjvOrdinalEnd,
                            ordinalStart: $0.ordinalStart,
                            ordinalEnd: $0.ordinalEnd,
                            v11n: $0.v11n,
                            playbackSettingsJSON: $0.playbackSettingsJSON,
                            createdAt: $0.createdAt,
                            book: $0.book,
                            startOffset: $0.startOffset,
                            endOffset: $0.endOffset,
                            primaryLabelID: $0.primaryLabelID,
                            notes: $0.notes,
                            lastUpdatedOn: $0.lastUpdatedOn,
                            wholeVerse: $0.wholeVerse,
                            type: $0.type,
                            customIcon: $0.customIcon,
                            editAction: $0.editAction,
                            labelLinks: $0.labelLinks.sorted(by: Self.labelLinkSort)
                        )
                    }
                    .sorted { $0.id.uuidString < $1.id.uuidString },
                genericBookmarks: genericBookmarksByID.values
                    .map {
                        RemoteSyncAndroidGenericBookmark(
                            id: $0.id,
                            key: $0.key,
                            createdAt: $0.createdAt,
                            bookInitials: $0.bookInitials,
                            ordinalStart: $0.ordinalStart,
                            ordinalEnd: $0.ordinalEnd,
                            startOffset: $0.startOffset,
                            endOffset: $0.endOffset,
                            primaryLabelID: $0.primaryLabelID,
                            notes: $0.notes,
                            lastUpdatedOn: $0.lastUpdatedOn,
                            wholeVerse: $0.wholeVerse,
                            playbackSettingsJSON: $0.playbackSettingsJSON,
                            customIcon: $0.customIcon,
                            editAction: $0.editAction,
                            labelLinks: $0.labelLinks.sorted(by: Self.labelLinkSort)
                        )
                    }
                    .sorted { $0.id.uuidString < $1.id.uuidString },
                studyPadEntries: studyPadEntriesByID.values
                    .map {
                        RemoteSyncAndroidStudyPadEntry(
                            id: $0.id,
                            labelID: $0.labelID,
                            orderNumber: $0.orderNumber,
                            indentLevel: $0.indentLevel,
                            text: $0.text ?? ""
                        )
                    }
                    .sorted(by: Self.studyPadSort)
            )
        }

        private static func labelSort(_ lhs: RemoteSyncAndroidLabel, _ rhs: RemoteSyncAndroidLabel) -> Bool {
            if lhs.name == rhs.name {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.name < rhs.name
        }

        private static func labelLinkSort(_ lhs: RemoteSyncAndroidBookmarkLabelLink, _ rhs: RemoteSyncAndroidBookmarkLabelLink) -> Bool {
            if lhs.orderNumber == rhs.orderNumber {
                return lhs.labelID.uuidString < rhs.labelID.uuidString
            }
            return lhs.orderNumber < rhs.orderNumber
        }

        private static func studyPadSort(_ lhs: RemoteSyncAndroidStudyPadEntry, _ rhs: RemoteSyncAndroidStudyPadEntry) -> Bool {
            if lhs.orderNumber == rhs.orderNumber {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.orderNumber < rhs.orderNumber
        }
    }

    private let restoreService: RemoteSyncBookmarkRestoreService
    private let metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService
    private let snapshotService: RemoteSyncBookmarkSnapshotService
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    /**
     Creates a bookmark patch replay service.

     - Parameters:
       - restoreService: Centralized bookmark restore service used for the final SwiftData rewrite.
       - metadataRestoreService: Reader used for staged Android `LogEntry` rows.
       - snapshotService: Snapshot service used to refresh outbound fingerprint baselines after replay.
       - fileManager: File manager used for temporary-file cleanup.
       - temporaryDirectory: Scratch directory for temporary decompressed patch databases. Defaults to the process temporary directory.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        restoreService: RemoteSyncBookmarkRestoreService = RemoteSyncBookmarkRestoreService(),
        metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService(),
        snapshotService: RemoteSyncBookmarkSnapshotService = RemoteSyncBookmarkSnapshotService(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) {
        self.restoreService = restoreService
        self.metadataRestoreService = metadataRestoreService
        self.snapshotService = snapshotService
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
    }

    /**
     Applies one ordered batch of staged Android bookmark patch archives.

     The caller is expected to pass archives in discovery order, matching Android's per-device
     patch-number progression.

     - Parameters:
       - stagedArchives: Previously downloaded staged patch archives in application order.
       - modelContext: SwiftData context whose bookmark graph should be rewritten on success.
       - settingsStore: Local-only settings store backing preserved Android fidelity metadata.
     - Returns: Summary describing how many patch archives and `LogEntry` rows were replayed.
     - Side effects:
       - reads the current local bookmark graph and local-only fidelity stores
       - creates and removes temporary decompressed SQLite files
       - rewrites local bookmark-category SwiftData rows after the full batch succeeds
       - replaces local Android `LogEntry` metadata for `.bookmarks`
       - refreshes outbound bookmark fingerprint baselines after the final replay state is accepted
       - appends applied-patch rows to `RemoteSyncPatchStatusStore`
     - Failure modes:
       - rethrows patch-archive decompression failures
       - rethrows malformed staged `LogEntry` metadata failures
       - throws `RemoteSyncBookmarkPatchApplyError` for invalid identifiers or missing patch rows
       - rethrows bookmark-restore errors when the final working snapshot cannot be normalized back into iOS
       - rethrows SwiftData fetch and save failures from the supplied `ModelContext`
     */
    public func applyPatchArchives(
        _ stagedArchives: [RemoteSyncStagedPatchArchive],
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncBookmarkPatchApplyReport {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

        var snapshot = try currentSnapshot(from: modelContext, settingsStore: settingsStore)
        var logEntriesByKey = Dictionary(
            uniqueKeysWithValues: logEntryStore.entries(for: .bookmarks).map {
                (logEntryStore.key(for: .bookmarks, entry: $0), $0)
            }
        )

        var appliedPatchStatuses: [RemoteSyncPatchStatus] = []
        var appliedLogEntryCount = 0
        var skippedLogEntryCount = 0

        for stagedArchive in stagedArchives {
            try {
                let patchDatabaseURL = temporaryDatabaseURL(prefix: "remote-sync-bookmarks-patch-", suffix: ".sqlite3")
                defer { try? fileManager.removeItem(at: patchDatabaseURL) }

                let archiveData = try Data(contentsOf: stagedArchive.archiveFileURL)
                let databaseData = try Self.gunzip(archiveData)
                try databaseData.write(to: patchDatabaseURL, options: .atomic)

                let metadataSnapshot = try metadataRestoreService.readSnapshot(from: patchDatabaseURL)
                let patchLogEntries = metadataSnapshot.logEntries.filter { Self.supportedTableNames.contains($0.tableName) }
                let filteredLogEntries = patchLogEntries.filter { entry in
                    let key = logEntryStore.key(for: .bookmarks, entry: entry)
                    guard let localEntry = logEntriesByKey[key] else {
                        return true
                    }
                    return entry.lastUpdated > localEntry.lastUpdated
                }

                skippedLogEntryCount += patchLogEntries.count - filteredLogEntries.count
                if filteredLogEntries.isEmpty {
                    return
                }

                try withSQLiteDatabase(at: patchDatabaseURL) { database in
                    try applyLabelOperations(
                        logEntries: filteredLogEntries.filter { $0.tableName == "Label" },
                        database: database,
                        snapshot: &snapshot,
                        logEntriesByKey: &logEntriesByKey,
                        logEntryStore: logEntryStore
                    )
                    try applyBibleBookmarkOperations(
                        logEntries: filteredLogEntries.filter { $0.tableName == "BibleBookmark" },
                        database: database,
                        snapshot: &snapshot,
                        logEntriesByKey: &logEntriesByKey,
                        logEntryStore: logEntryStore
                    )
                    try applyBibleBookmarkNotesOperations(
                        logEntries: filteredLogEntries.filter { $0.tableName == "BibleBookmarkNotes" },
                        database: database,
                        snapshot: &snapshot,
                        logEntriesByKey: &logEntriesByKey,
                        logEntryStore: logEntryStore
                    )
                    try applyBibleBookmarkLabelOperations(
                        logEntries: filteredLogEntries.filter { $0.tableName == "BibleBookmarkToLabel" },
                        database: database,
                        snapshot: &snapshot,
                        logEntriesByKey: &logEntriesByKey,
                        logEntryStore: logEntryStore
                    )
                    try applyGenericBookmarkOperations(
                        logEntries: filteredLogEntries.filter { $0.tableName == "GenericBookmark" },
                        database: database,
                        snapshot: &snapshot,
                        logEntriesByKey: &logEntriesByKey,
                        logEntryStore: logEntryStore
                    )
                    try applyGenericBookmarkNotesOperations(
                        logEntries: filteredLogEntries.filter { $0.tableName == "GenericBookmarkNotes" },
                        database: database,
                        snapshot: &snapshot,
                        logEntriesByKey: &logEntriesByKey,
                        logEntryStore: logEntryStore
                    )
                    try applyGenericBookmarkLabelOperations(
                        logEntries: filteredLogEntries.filter { $0.tableName == "GenericBookmarkToLabel" },
                        database: database,
                        snapshot: &snapshot,
                        logEntriesByKey: &logEntriesByKey,
                        logEntryStore: logEntryStore
                    )
                    try applyStudyPadEntryOperations(
                        logEntries: filteredLogEntries.filter { $0.tableName == "StudyPadTextEntry" },
                        database: database,
                        snapshot: &snapshot,
                        logEntriesByKey: &logEntriesByKey,
                        logEntryStore: logEntryStore
                    )
                    try applyStudyPadTextOperations(
                        logEntries: filteredLogEntries.filter { $0.tableName == "StudyPadTextEntryText" },
                        database: database,
                        snapshot: &snapshot,
                        logEntriesByKey: &logEntriesByKey,
                        logEntryStore: logEntryStore
                    )
                }

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

        let restoreReport = try restoreService.replaceLocalBookmarks(
            from: snapshot.materializedSnapshot(),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        logEntryStore.replaceEntries(
            logEntriesByKey.values.sorted(by: Self.logEntrySort),
            for: .bookmarks
        )
        patchStatusStore.addStatuses(appliedPatchStatuses, for: .bookmarks)
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        return RemoteSyncBookmarkPatchApplyReport(
            appliedPatchCount: appliedPatchStatuses.count,
            appliedLogEntryCount: appliedLogEntryCount,
            skippedLogEntryCount: skippedLogEntryCount,
            restoreReport: restoreReport
        )
    }

    /**
     Loads the current local bookmark graph into mutable remote-ID working rows.

     The working snapshot must stay in Android's identifier space so patch `LogEntry` rows can be
     matched without translating every incoming UUID. Reserved system labels therefore use the
     reverse alias map when one has been preserved locally.

     - Parameters:
       - modelContext: SwiftData context that owns the local bookmark graph.
       - settingsStore: Local-only settings store backing playback JSON and system-label aliases.
     - Returns: Mutable remote-ID working snapshot representing the current local bookmark category.
     - Side effects:
       - reads bookmark-category SwiftData rows from `modelContext`
       - reads preserved Android playback JSON and label-alias rows from local settings
     - Failure modes:
       - rethrows SwiftData fetch failures from `modelContext.fetch`
     */
    private func currentSnapshot(
        from modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> WorkingSnapshot {
        let labelAliasStore = RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore)
        let playbackSettingsStore = RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore)
        let reverseAliases = Dictionary(
            uniqueKeysWithValues: labelAliasStore.allAliases().map { ($0.localLabelID, $0.remoteLabelID) }
        )

        let labels = try modelContext.fetch(FetchDescriptor<Label>())
        let bibleBookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        let bibleNotes = try modelContext.fetch(FetchDescriptor<BibleBookmarkNotes>())
        let bibleLinks = try modelContext.fetch(FetchDescriptor<BibleBookmarkToLabel>())
        let genericBookmarks = try modelContext.fetch(FetchDescriptor<GenericBookmark>())
        let genericNotes = try modelContext.fetch(FetchDescriptor<GenericBookmarkNotes>())
        let genericLinks = try modelContext.fetch(FetchDescriptor<GenericBookmarkToLabel>())
        let studyPadEntries = try modelContext.fetch(FetchDescriptor<StudyPadTextEntry>())
        let studyPadTexts = try modelContext.fetch(FetchDescriptor<StudyPadTextEntryText>())

        let bibleNotesByBookmarkID = Dictionary(uniqueKeysWithValues: bibleNotes.map { ($0.bookmarkId, $0.notes) })
        let genericNotesByBookmarkID = Dictionary(uniqueKeysWithValues: genericNotes.map { ($0.bookmarkId, $0.notes) })
        let studyPadTextsByEntryID = Dictionary(uniqueKeysWithValues: studyPadTexts.map { ($0.studyPadTextEntryId, $0.text) })

        let bibleLinksByBookmarkID = Dictionary(grouping: bibleLinks.compactMap { link -> (UUID, RemoteSyncAndroidBookmarkLabelLink)? in
            guard let bookmarkID = link.bookmark?.id,
                  let localLabelID = link.label?.id else {
                return nil
            }
            let remoteLabelID = reverseAliases[localLabelID] ?? localLabelID
            return (
                bookmarkID,
                RemoteSyncAndroidBookmarkLabelLink(
                    labelID: remoteLabelID,
                    orderNumber: link.orderNumber,
                    indentLevel: link.indentLevel,
                    expandContent: link.expandContent
                )
            )
        }, by: { $0.0 })
        let genericLinksByBookmarkID = Dictionary(grouping: genericLinks.compactMap { link -> (UUID, RemoteSyncAndroidBookmarkLabelLink)? in
            guard let bookmarkID = link.bookmark?.id,
                  let localLabelID = link.label?.id else {
                return nil
            }
            let remoteLabelID = reverseAliases[localLabelID] ?? localLabelID
            return (
                bookmarkID,
                RemoteSyncAndroidBookmarkLabelLink(
                    labelID: remoteLabelID,
                    orderNumber: link.orderNumber,
                    indentLevel: link.indentLevel,
                    expandContent: link.expandContent
                )
            )
        }, by: { $0.0 })

        let labelsByID = Dictionary(uniqueKeysWithValues: labels.map { label in
            let remoteID = reverseAliases[label.id] ?? label.id
            return (
                remoteID,
                WorkingLabel(
                    id: remoteID,
                    name: label.name,
                    color: label.color,
                    markerStyle: label.markerStyle,
                    markerStyleWholeVerse: label.markerStyleWholeVerse,
                    underlineStyle: label.underlineStyle,
                    underlineStyleWholeVerse: label.underlineStyleWholeVerse,
                    hideStyle: label.hideStyle,
                    hideStyleWholeVerse: label.hideStyleWholeVerse,
                    favourite: label.favourite,
                    type: label.type,
                    customIcon: label.customIcon
                )
            )
        })

        let bibleBookmarksByID = Dictionary(uniqueKeysWithValues: bibleBookmarks.map { bookmark in
            let playbackJSON = playbackSettingsStore.playbackSettingsJSON(for: bookmark.id, kind: .bible)
                ?? synthesizedPlaybackSettingsJSON(from: bookmark.playbackSettings)
            let labelLinks = (bibleLinksByBookmarkID[bookmark.id] ?? [])
                .map { $0.1 }
                .sorted(by: sortLabelLinks)
            return (
                bookmark.id,
                WorkingBibleBookmark(
                    id: bookmark.id,
                    kjvOrdinalStart: bookmark.kjvOrdinalStart,
                    kjvOrdinalEnd: bookmark.kjvOrdinalEnd,
                    ordinalStart: bookmark.ordinalStart,
                    ordinalEnd: bookmark.ordinalEnd,
                    v11n: bookmark.v11n,
                    playbackSettingsJSON: playbackJSON,
                    createdAt: bookmark.createdAt,
                    book: bookmark.book,
                    startOffset: bookmark.startOffset,
                    endOffset: bookmark.endOffset,
                    primaryLabelID: bookmark.primaryLabelId.map { reverseAliases[$0] ?? $0 },
                    notes: bibleNotesByBookmarkID[bookmark.id],
                    lastUpdatedOn: bookmark.lastUpdatedOn,
                    wholeVerse: bookmark.wholeVerse,
                    type: bookmark.type,
                    customIcon: bookmark.customIcon,
                    editAction: bookmark.editAction,
                    labelLinks: labelLinks
                )
            )
        })

        let genericBookmarksByID = Dictionary(uniqueKeysWithValues: genericBookmarks.map { bookmark in
            let playbackJSON = playbackSettingsStore.playbackSettingsJSON(for: bookmark.id, kind: .generic)
                ?? synthesizedPlaybackSettingsJSON(from: bookmark.playbackSettings)
            let labelLinks = (genericLinksByBookmarkID[bookmark.id] ?? [])
                .map { $0.1 }
                .sorted(by: sortLabelLinks)
            return (
                bookmark.id,
                WorkingGenericBookmark(
                    id: bookmark.id,
                    key: bookmark.key,
                    createdAt: bookmark.createdAt,
                    bookInitials: bookmark.bookInitials,
                    ordinalStart: bookmark.ordinalStart,
                    ordinalEnd: bookmark.ordinalEnd,
                    startOffset: bookmark.startOffset,
                    endOffset: bookmark.endOffset,
                    primaryLabelID: bookmark.primaryLabelId.map { reverseAliases[$0] ?? $0 },
                    notes: genericNotesByBookmarkID[bookmark.id],
                    lastUpdatedOn: bookmark.lastUpdatedOn,
                    wholeVerse: bookmark.wholeVerse,
                    playbackSettingsJSON: playbackJSON,
                    customIcon: bookmark.customIcon,
                    editAction: bookmark.editAction,
                    labelLinks: labelLinks
                )
            )
        })

        let studyPadEntriesByID = Dictionary(uniqueKeysWithValues: studyPadEntries.compactMap { entry -> (UUID, WorkingStudyPadEntry)? in
            guard let localLabelID = entry.label?.id else {
                return nil
            }
            let remoteLabelID = reverseAliases[localLabelID] ?? localLabelID
            return (
                entry.id,
                WorkingStudyPadEntry(
                    id: entry.id,
                    labelID: remoteLabelID,
                    orderNumber: entry.orderNumber,
                    indentLevel: entry.indentLevel,
                    text: studyPadTextsByEntryID[entry.id]
                )
            )
        })

        return WorkingSnapshot(
            labelsByID: labelsByID,
            bibleBookmarksByID: bibleBookmarksByID,
            genericBookmarksByID: genericBookmarksByID,
            studyPadEntriesByID: studyPadEntriesByID
        )
    }

    /**
     Applies `Label` table operations in Android table order.

     - Parameters:
       - logEntries: Newer patch log entries for the `Label` table.
       - database: Open staged patch database handle.
       - snapshot: Mutable working bookmark snapshot.
       - logEntriesByKey: Mutable in-memory Android `LogEntry` map keyed by local settings keys.
       - logEntryStore: Store used to derive Android-compatible key strings.
     - Side effects:
       - mutates the working label map in memory
       - mutates the in-memory Android `LogEntry` map
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchApplyError.invalidLogEntryIdentifier` when a log row does not identify a UUID label row
       - throws `RemoteSyncBookmarkPatchApplyError.missingPatchRow` when an `UPSERT` row is absent from the patch database
       - rethrows SQLite read failures when one row cannot be read from the staged database
     */
    private func applyLabelOperations(
        logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let upserts = logEntries.filter { $0.type == .upsert }.sorted(by: Self.logEntrySort)
        let deletes = logEntries.filter { $0.type == .delete }.sorted(by: Self.logEntrySort)

        for entry in upserts {
            let labelID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            guard let label = try fetchLabel(id: labelID, from: database) else {
                throw RemoteSyncBookmarkPatchApplyError.missingPatchRow(table: entry.tableName, entityID1: labelID, entityID2: nil)
            }
            snapshot.labelsByID[label.id] = label
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }

        for entry in deletes {
            let labelID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            snapshot.labelsByID.removeValue(forKey: labelID)
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }
    }

    /**
     Applies `BibleBookmark` table operations in Android table order, including the unconditional post-upsert foreign-key cleanup step.

     - Parameters:
       - logEntries: Newer patch log entries for the `BibleBookmark` table.
       - database: Open staged patch database handle.
       - snapshot: Mutable working bookmark snapshot.
       - logEntriesByKey: Mutable in-memory Android `LogEntry` map keyed by local settings keys.
       - logEntryStore: Store used to derive Android-compatible key strings.
     - Side effects:
       - mutates the working Bible-bookmark map in memory
       - mutates the in-memory Android `LogEntry` map
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchApplyError.invalidLogEntryIdentifier` when a log row does not identify a UUID bookmark row
       - throws `RemoteSyncBookmarkPatchApplyError.missingPatchRow` when an `UPSERT` row is absent from the patch database
       - rethrows SQLite read failures when one row cannot be read from the staged database
     */
    private func applyBibleBookmarkOperations(
        logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let upserts = logEntries.filter { $0.type == .upsert }.sorted(by: Self.logEntrySort)
        let deletes = logEntries.filter { $0.type == .delete }.sorted(by: Self.logEntrySort)

        for entry in upserts {
            let bookmarkID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            let existing = snapshot.bibleBookmarksByID[bookmarkID]
            guard let bookmark = try fetchBibleBookmark(id: bookmarkID, preserving: existing, from: database) else {
                throw RemoteSyncBookmarkPatchApplyError.missingPatchRow(table: entry.tableName, entityID1: bookmarkID, entityID2: nil)
            }
            snapshot.bibleBookmarksByID[bookmark.id] = bookmark
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }

        pruneInvalidBibleBookmarks(in: &snapshot)

        for entry in deletes {
            let bookmarkID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            snapshot.bibleBookmarksByID.removeValue(forKey: bookmarkID)
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }
    }

    /**
     Applies `BibleBookmarkNotes` table operations in Android table order.

     - Parameters:
       - logEntries: Newer patch log entries for the `BibleBookmarkNotes` table.
       - database: Open staged patch database handle.
       - snapshot: Mutable working bookmark snapshot.
       - logEntriesByKey: Mutable in-memory Android `LogEntry` map keyed by local settings keys.
       - logEntryStore: Store used to derive Android-compatible key strings.
     - Side effects:
       - mutates note payloads inside the working Bible-bookmark map
       - mutates the in-memory Android `LogEntry` map
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchApplyError.invalidLogEntryIdentifier` when a log row does not identify a UUID bookmark row
       - throws `RemoteSyncBookmarkPatchApplyError.missingPatchRow` when an `UPSERT` row is absent from the patch database
       - rethrows SQLite read failures when one row cannot be read from the staged database
       - Note: Upserts targeting a bookmark that is no longer present are ignored after recording the newer `LogEntry`, matching Android's later foreign-key cleanup outcome.
     */
    private func applyBibleBookmarkNotesOperations(
        logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let upserts = logEntries.filter { $0.type == .upsert }.sorted(by: Self.logEntrySort)
        let deletes = logEntries.filter { $0.type == .delete }.sorted(by: Self.logEntrySort)

        for entry in upserts {
            let bookmarkID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            guard let notes = try fetchBookmarkNotes(bookmarkID: bookmarkID, tableName: "BibleBookmarkNotes", from: database) else {
                throw RemoteSyncBookmarkPatchApplyError.missingPatchRow(table: entry.tableName, entityID1: bookmarkID, entityID2: nil)
            }
            if var bookmark = snapshot.bibleBookmarksByID[bookmarkID] {
                bookmark.notes = notes
                snapshot.bibleBookmarksByID[bookmarkID] = bookmark
            }
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }

        for entry in deletes {
            let bookmarkID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            if var bookmark = snapshot.bibleBookmarksByID[bookmarkID] {
                bookmark.notes = nil
                snapshot.bibleBookmarksByID[bookmarkID] = bookmark
            }
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }
    }

    /**
     Applies `BibleBookmarkToLabel` table operations in Android table order, including unconditional link cleanup after upserts.

     - Parameters:
       - logEntries: Newer patch log entries for the `BibleBookmarkToLabel` table.
       - database: Open staged patch database handle.
       - snapshot: Mutable working bookmark snapshot.
       - logEntriesByKey: Mutable in-memory Android `LogEntry` map keyed by local settings keys.
       - logEntryStore: Store used to derive Android-compatible key strings.
     - Side effects:
       - mutates label-link arrays inside the working Bible-bookmark map
       - mutates the in-memory Android `LogEntry` map
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchApplyError.invalidLogEntryIdentifier` when a log row does not identify the composite bookmark/label key
       - throws `RemoteSyncBookmarkPatchApplyError.missingPatchRow` when an `UPSERT` row is absent from the patch database
       - rethrows SQLite read failures when one row cannot be read from the staged database
     */
    private func applyBibleBookmarkLabelOperations(
        logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let upserts = logEntries.filter { $0.type == .upsert }.sorted(by: Self.logEntrySort)
        let deletes = logEntries.filter { $0.type == .delete }.sorted(by: Self.logEntrySort)

        for entry in upserts {
            let bookmarkID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            let labelID = try uuid(from: entry.entityID2, tableName: entry.tableName, field: "entityId2")
            guard let link = try fetchBookmarkLabelLink(bookmarkID: bookmarkID, labelID: labelID, tableName: "BibleBookmarkToLabel", from: database) else {
                throw RemoteSyncBookmarkPatchApplyError.missingPatchRow(table: entry.tableName, entityID1: bookmarkID, entityID2: labelID)
            }
            if var bookmark = snapshot.bibleBookmarksByID[bookmarkID] {
                upsert(link: link, into: &bookmark.labelLinks)
                snapshot.bibleBookmarksByID[bookmarkID] = bookmark
            }
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }

        pruneInvalidBibleBookmarkLinks(in: &snapshot)

        for entry in deletes {
            let bookmarkID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            let labelID = try uuid(from: entry.entityID2, tableName: entry.tableName, field: "entityId2")
            if var bookmark = snapshot.bibleBookmarksByID[bookmarkID] {
                bookmark.labelLinks.removeAll { $0.labelID == labelID }
                snapshot.bibleBookmarksByID[bookmarkID] = bookmark
            }
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }
    }

    /**
     Applies `GenericBookmark` table operations in Android table order, including unconditional post-upsert foreign-key cleanup.

     - Parameters:
       - logEntries: Newer patch log entries for the `GenericBookmark` table.
       - database: Open staged patch database handle.
       - snapshot: Mutable working bookmark snapshot.
       - logEntriesByKey: Mutable in-memory Android `LogEntry` map keyed by local settings keys.
       - logEntryStore: Store used to derive Android-compatible key strings.
     - Side effects:
       - mutates the working generic-bookmark map in memory
       - mutates the in-memory Android `LogEntry` map
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchApplyError.invalidLogEntryIdentifier` when a log row does not identify a UUID bookmark row
       - throws `RemoteSyncBookmarkPatchApplyError.missingPatchRow` when an `UPSERT` row is absent from the patch database
       - rethrows SQLite read failures when one row cannot be read from the staged database
     */
    private func applyGenericBookmarkOperations(
        logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let upserts = logEntries.filter { $0.type == .upsert }.sorted(by: Self.logEntrySort)
        let deletes = logEntries.filter { $0.type == .delete }.sorted(by: Self.logEntrySort)

        for entry in upserts {
            let bookmarkID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            let existing = snapshot.genericBookmarksByID[bookmarkID]
            guard let bookmark = try fetchGenericBookmark(id: bookmarkID, preserving: existing, from: database) else {
                throw RemoteSyncBookmarkPatchApplyError.missingPatchRow(table: entry.tableName, entityID1: bookmarkID, entityID2: nil)
            }
            snapshot.genericBookmarksByID[bookmark.id] = bookmark
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }

        pruneInvalidGenericBookmarks(in: &snapshot)

        for entry in deletes {
            let bookmarkID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            snapshot.genericBookmarksByID.removeValue(forKey: bookmarkID)
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }
    }

    /**
     Applies `GenericBookmarkNotes` table operations in Android table order.

     - Parameters:
       - logEntries: Newer patch log entries for the `GenericBookmarkNotes` table.
       - database: Open staged patch database handle.
       - snapshot: Mutable working bookmark snapshot.
       - logEntriesByKey: Mutable in-memory Android `LogEntry` map keyed by local settings keys.
       - logEntryStore: Store used to derive Android-compatible key strings.
     - Side effects:
       - mutates note payloads inside the working generic-bookmark map
       - mutates the in-memory Android `LogEntry` map
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchApplyError.invalidLogEntryIdentifier` when a log row does not identify a UUID bookmark row
       - throws `RemoteSyncBookmarkPatchApplyError.missingPatchRow` when an `UPSERT` row is absent from the patch database
       - rethrows SQLite read failures when one row cannot be read from the staged database
     */
    private func applyGenericBookmarkNotesOperations(
        logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let upserts = logEntries.filter { $0.type == .upsert }.sorted(by: Self.logEntrySort)
        let deletes = logEntries.filter { $0.type == .delete }.sorted(by: Self.logEntrySort)

        for entry in upserts {
            let bookmarkID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            guard let notes = try fetchBookmarkNotes(bookmarkID: bookmarkID, tableName: "GenericBookmarkNotes", from: database) else {
                throw RemoteSyncBookmarkPatchApplyError.missingPatchRow(table: entry.tableName, entityID1: bookmarkID, entityID2: nil)
            }
            if var bookmark = snapshot.genericBookmarksByID[bookmarkID] {
                bookmark.notes = notes
                snapshot.genericBookmarksByID[bookmarkID] = bookmark
            }
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }

        for entry in deletes {
            let bookmarkID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            if var bookmark = snapshot.genericBookmarksByID[bookmarkID] {
                bookmark.notes = nil
                snapshot.genericBookmarksByID[bookmarkID] = bookmark
            }
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }
    }

    /**
     Applies `GenericBookmarkToLabel` table operations in Android table order, including unconditional link cleanup after upserts.

     - Parameters:
       - logEntries: Newer patch log entries for the `GenericBookmarkToLabel` table.
       - database: Open staged patch database handle.
       - snapshot: Mutable working bookmark snapshot.
       - logEntriesByKey: Mutable in-memory Android `LogEntry` map keyed by local settings keys.
       - logEntryStore: Store used to derive Android-compatible key strings.
     - Side effects:
       - mutates label-link arrays inside the working generic-bookmark map
       - mutates the in-memory Android `LogEntry` map
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchApplyError.invalidLogEntryIdentifier` when a log row does not identify the composite bookmark/label key
       - throws `RemoteSyncBookmarkPatchApplyError.missingPatchRow` when an `UPSERT` row is absent from the patch database
       - rethrows SQLite read failures when one row cannot be read from the staged database
     */
    private func applyGenericBookmarkLabelOperations(
        logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let upserts = logEntries.filter { $0.type == .upsert }.sorted(by: Self.logEntrySort)
        let deletes = logEntries.filter { $0.type == .delete }.sorted(by: Self.logEntrySort)

        for entry in upserts {
            let bookmarkID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            let labelID = try uuid(from: entry.entityID2, tableName: entry.tableName, field: "entityId2")
            guard let link = try fetchBookmarkLabelLink(bookmarkID: bookmarkID, labelID: labelID, tableName: "GenericBookmarkToLabel", from: database) else {
                throw RemoteSyncBookmarkPatchApplyError.missingPatchRow(table: entry.tableName, entityID1: bookmarkID, entityID2: labelID)
            }
            if var bookmark = snapshot.genericBookmarksByID[bookmarkID] {
                upsert(link: link, into: &bookmark.labelLinks)
                snapshot.genericBookmarksByID[bookmarkID] = bookmark
            }
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }

        pruneInvalidGenericBookmarkLinks(in: &snapshot)

        for entry in deletes {
            let bookmarkID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            let labelID = try uuid(from: entry.entityID2, tableName: entry.tableName, field: "entityId2")
            if var bookmark = snapshot.genericBookmarksByID[bookmarkID] {
                bookmark.labelLinks.removeAll { $0.labelID == labelID }
                snapshot.genericBookmarksByID[bookmarkID] = bookmark
            }
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }
    }

    /**
     Applies `StudyPadTextEntry` table operations in Android table order, including unconditional post-upsert foreign-key cleanup.

     - Parameters:
       - logEntries: Newer patch log entries for the `StudyPadTextEntry` table.
       - database: Open staged patch database handle.
       - snapshot: Mutable working bookmark snapshot.
       - logEntriesByKey: Mutable in-memory Android `LogEntry` map keyed by local settings keys.
       - logEntryStore: Store used to derive Android-compatible key strings.
     - Side effects:
       - mutates the working StudyPad-entry map in memory
       - mutates the in-memory Android `LogEntry` map
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchApplyError.invalidLogEntryIdentifier` when a log row does not identify a UUID StudyPad row
       - throws `RemoteSyncBookmarkPatchApplyError.missingPatchRow` when an `UPSERT` row is absent from the patch database
       - rethrows SQLite read failures when one row cannot be read from the staged database
     */
    private func applyStudyPadEntryOperations(
        logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let upserts = logEntries.filter { $0.type == .upsert }.sorted(by: Self.logEntrySort)
        let deletes = logEntries.filter { $0.type == .delete }.sorted(by: Self.logEntrySort)

        for entry in upserts {
            let entryID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            let existingText = snapshot.studyPadEntriesByID[entryID]?.text
            guard let studyPadEntry = try fetchStudyPadEntry(id: entryID, preservingText: existingText, from: database) else {
                throw RemoteSyncBookmarkPatchApplyError.missingPatchRow(table: entry.tableName, entityID1: entryID, entityID2: nil)
            }
            snapshot.studyPadEntriesByID[entryID] = studyPadEntry
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }

        pruneInvalidStudyPadEntries(in: &snapshot)

        for entry in deletes {
            let entryID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            snapshot.studyPadEntriesByID.removeValue(forKey: entryID)
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }
    }

    /**
     Applies `StudyPadTextEntryText` table operations in Android table order.

     - Parameters:
       - logEntries: Newer patch log entries for the `StudyPadTextEntryText` table.
       - database: Open staged patch database handle.
       - snapshot: Mutable working bookmark snapshot.
       - logEntriesByKey: Mutable in-memory Android `LogEntry` map keyed by local settings keys.
       - logEntryStore: Store used to derive Android-compatible key strings.
     - Side effects:
       - mutates text payloads inside the working StudyPad-entry map
       - mutates the in-memory Android `LogEntry` map
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchApplyError.invalidLogEntryIdentifier` when a log row does not identify a UUID StudyPad row
       - throws `RemoteSyncBookmarkPatchApplyError.missingPatchRow` when an `UPSERT` row is absent from the patch database
       - rethrows SQLite read failures when one row cannot be read from the staged database
       - Note: Deleting a StudyPad text row clears the working text payload instead of deleting the parent entry because iOS rebuilds StudyPad state from the parent row plus inline text value, not a separate optional child-row representation.
     */
    private func applyStudyPadTextOperations(
        logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let upserts = logEntries.filter { $0.type == .upsert }.sorted(by: Self.logEntrySort)
        let deletes = logEntries.filter { $0.type == .delete }.sorted(by: Self.logEntrySort)

        for entry in upserts {
            let entryID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            guard let text = try fetchStudyPadText(entryID: entryID, from: database) else {
                throw RemoteSyncBookmarkPatchApplyError.missingPatchRow(table: entry.tableName, entityID1: entryID, entityID2: nil)
            }
            if var studyPadEntry = snapshot.studyPadEntriesByID[entryID] {
                studyPadEntry.text = text
                snapshot.studyPadEntriesByID[entryID] = studyPadEntry
            }
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }

        for entry in deletes {
            let entryID = try uuid(from: entry.entityID1, tableName: entry.tableName, field: "entityId1")
            if var studyPadEntry = snapshot.studyPadEntriesByID[entryID] {
                studyPadEntry.text = nil
                snapshot.studyPadEntriesByID[entryID] = studyPadEntry
            }
            logEntriesByKey[logEntryStore.key(for: .bookmarks, entry: entry)] = entry
        }
    }

    /**
     Removes Bible bookmarks whose primary label no longer exists after the current table phase.

     Android runs `pragma_foreign_key_check('BibleBookmark')` after every `BibleBookmark` upsert pass,
     even when the current patch archive had no rows for that table. This helper mirrors the final
     post-check state by dropping any bookmark whose `primaryLabelId` now references a deleted label.

     - Parameter snapshot: Mutable working bookmark snapshot.
     - Side effects:
       - removes invalid Bible-bookmark rows from the in-memory snapshot
     - Failure modes: This helper cannot fail.
     */
    private func pruneInvalidBibleBookmarks(in snapshot: inout WorkingSnapshot) {
        let labelIDs = Set(snapshot.labelsByID.keys)
        snapshot.bibleBookmarksByID = snapshot.bibleBookmarksByID.filter { _, bookmark in
            guard let primaryLabelID = bookmark.primaryLabelID else {
                return true
            }
            return labelIDs.contains(primaryLabelID)
        }
    }

    /**
     Removes Bible bookmark-to-label links whose label target no longer exists.

     - Parameter snapshot: Mutable working bookmark snapshot.
     - Side effects:
       - mutates each working Bible bookmark's label-link array in place
     - Failure modes: This helper cannot fail.
     */
    private func pruneInvalidBibleBookmarkLinks(in snapshot: inout WorkingSnapshot) {
        let labelIDs = Set(snapshot.labelsByID.keys)
        for bookmarkID in snapshot.bibleBookmarksByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var bookmark = snapshot.bibleBookmarksByID[bookmarkID] else { continue }
            bookmark.labelLinks.removeAll { !labelIDs.contains($0.labelID) }
            bookmark.labelLinks.sort(by: sortLabelLinks)
            snapshot.bibleBookmarksByID[bookmarkID] = bookmark
        }
    }

    /**
     Removes generic bookmarks whose primary label no longer exists after the current table phase.

     - Parameter snapshot: Mutable working bookmark snapshot.
     - Side effects:
       - removes invalid generic-bookmark rows from the in-memory snapshot
     - Failure modes: This helper cannot fail.
     */
    private func pruneInvalidGenericBookmarks(in snapshot: inout WorkingSnapshot) {
        let labelIDs = Set(snapshot.labelsByID.keys)
        snapshot.genericBookmarksByID = snapshot.genericBookmarksByID.filter { _, bookmark in
            guard let primaryLabelID = bookmark.primaryLabelID else {
                return true
            }
            return labelIDs.contains(primaryLabelID)
        }
    }

    /**
     Removes generic bookmark-to-label links whose label target no longer exists.

     - Parameter snapshot: Mutable working bookmark snapshot.
     - Side effects:
       - mutates each working generic bookmark's label-link array in place
     - Failure modes: This helper cannot fail.
     */
    private func pruneInvalidGenericBookmarkLinks(in snapshot: inout WorkingSnapshot) {
        let labelIDs = Set(snapshot.labelsByID.keys)
        for bookmarkID in snapshot.genericBookmarksByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var bookmark = snapshot.genericBookmarksByID[bookmarkID] else { continue }
            bookmark.labelLinks.removeAll { !labelIDs.contains($0.labelID) }
            bookmark.labelLinks.sort(by: sortLabelLinks)
            snapshot.genericBookmarksByID[bookmarkID] = bookmark
        }
    }

    /**
     Removes StudyPad entries whose owning label no longer exists.

     - Parameter snapshot: Mutable working bookmark snapshot.
     - Side effects:
       - removes invalid StudyPad-entry rows from the in-memory snapshot
     - Failure modes: This helper cannot fail.
     */
    private func pruneInvalidStudyPadEntries(in snapshot: inout WorkingSnapshot) {
        let labelIDs = Set(snapshot.labelsByID.keys)
        snapshot.studyPadEntriesByID = snapshot.studyPadEntriesByID.filter { _, entry in
            labelIDs.contains(entry.labelID)
        }
    }

    /**
     Inserts or replaces one label-link row inside a bookmark's ordered link array.

     - Parameters:
       - link: Incoming remote label-link payload.
       - links: Mutable ordered label-link array to update.
     - Side effects:
       - mutates the supplied label-link array
     - Failure modes: This helper cannot fail.
     */
    private func upsert(link: RemoteSyncAndroidBookmarkLabelLink, into links: inout [RemoteSyncAndroidBookmarkLabelLink]) {
        links.removeAll { $0.labelID == link.labelID }
        links.append(link)
        links.sort(by: sortLabelLinks)
    }

    /**
     Reads one `Label` row from a staged patch database by UUID.

     - Parameters:
       - id: Android `Label.id` value to fetch.
       - database: Open staged patch database handle.
     - Returns: Working label row when present in the staged patch database; otherwise `nil`.
     - Side effects:
       - prepares and steps one SQLite select statement
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when the row identifier is malformed
     */
    private func fetchLabel(id: UUID, from database: OpaquePointer) throws -> WorkingLabel? {
        let sql = """
        SELECT id, name, color, markerStyle, markerStyleWholeVerse, underlineStyle,
               underlineStyleWholeVerse, hideStyle, hideStyleWholeVerse, favourite, type, customIcon
        FROM Label
        WHERE id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }
        bindUUIDBlob(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return WorkingLabel(
            id: try uuidFromBlob(statement: statement, column: 0, table: "Label", name: "id"),
            name: stringColumn(statement: statement, index: 1),
            color: Int(sqlite3_column_int(statement, 2)),
            markerStyle: boolColumn(statement: statement, index: 3),
            markerStyleWholeVerse: boolColumn(statement: statement, index: 4),
            underlineStyle: boolColumn(statement: statement, index: 5),
            underlineStyleWholeVerse: boolColumn(statement: statement, index: 6),
            hideStyle: boolColumn(statement: statement, index: 7),
            hideStyleWholeVerse: boolColumn(statement: statement, index: 8),
            favourite: boolColumn(statement: statement, index: 9),
            type: optionalStringColumn(statement: statement, index: 10),
            customIcon: optionalStringColumn(statement: statement, index: 11)
        )
    }

    /**
     Reads one `BibleBookmark` row from a staged patch database and merges it with preserved notes and label links.

     - Parameters:
       - id: Android `BibleBookmark.id` value to fetch.
       - preserving: Existing working bookmark used to preserve detached note and label-link rows when the patch only changed the parent bookmark table.
       - database: Open staged patch database handle.
     - Returns: Working Bible bookmark when present in the staged patch database; otherwise `nil`.
     - Side effects:
       - prepares and steps one SQLite select statement
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when the row or label identifier is malformed
     */
    private func fetchBibleBookmark(
        id: UUID,
        preserving existing: WorkingBibleBookmark?,
        from database: OpaquePointer
    ) throws -> WorkingBibleBookmark? {
        let sql = """
        SELECT id, kjvOrdinalStart, kjvOrdinalEnd, ordinalStart, ordinalEnd, v11n, playbackSettings,
               createdAt, book, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse,
               type, customIcon, editAction_mode, editAction_content
        FROM BibleBookmark
        WHERE id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }
        bindUUIDBlob(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return WorkingBibleBookmark(
            id: try uuidFromBlob(statement: statement, column: 0, table: "BibleBookmark", name: "id"),
            kjvOrdinalStart: Int(sqlite3_column_int(statement, 1)),
            kjvOrdinalEnd: Int(sqlite3_column_int(statement, 2)),
            ordinalStart: Int(sqlite3_column_int(statement, 3)),
            ordinalEnd: Int(sqlite3_column_int(statement, 4)),
            v11n: stringColumn(statement: statement, index: 5),
            playbackSettingsJSON: optionalStringColumn(statement: statement, index: 6),
            createdAt: dateFromMillisecondsColumn(statement: statement, index: 7),
            book: optionalStringColumn(statement: statement, index: 8),
            startOffset: optionalIntColumn(statement: statement, index: 9),
            endOffset: optionalIntColumn(statement: statement, index: 10),
            primaryLabelID: try optionalUUIDFromBlob(statement: statement, column: 11, table: "BibleBookmark", name: "primaryLabelId"),
            notes: existing?.notes,
            lastUpdatedOn: dateFromMillisecondsColumn(statement: statement, index: 12),
            wholeVerse: boolColumn(statement: statement, index: 13),
            type: optionalStringColumn(statement: statement, index: 14),
            customIcon: optionalStringColumn(statement: statement, index: 15),
            editAction: editAction(
                mode: optionalStringColumn(statement: statement, index: 16),
                content: optionalStringColumn(statement: statement, index: 17)
            ),
            labelLinks: existing?.labelLinks ?? []
        )
    }

    /**
     Reads one detached bookmark-note row from a staged patch database.

     - Parameters:
       - bookmarkID: Android bookmark identifier used as the note-table primary key.
       - tableName: Either `BibleBookmarkNotes` or `GenericBookmarkNotes`.
       - database: Open staged patch database handle.
     - Returns: Note text when present in the staged patch database; otherwise `nil`.
     - Side effects:
       - prepares and steps one SQLite select statement
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
     */
    private func fetchBookmarkNotes(
        bookmarkID: UUID,
        tableName: String,
        from database: OpaquePointer
    ) throws -> String? {
        let sql = "SELECT notes FROM \(tableName) WHERE bookmarkId = ? LIMIT 1"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }
        bindUUIDBlob(bookmarkID, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return stringColumn(statement: statement, index: 0)
    }

    /**
     Reads one bookmark-to-label junction row from a staged patch database.

     - Parameters:
       - bookmarkID: Android bookmark identifier.
       - labelID: Android label identifier.
       - tableName: Either `BibleBookmarkToLabel` or `GenericBookmarkToLabel`.
       - database: Open staged patch database handle.
     - Returns: Label-link payload when present in the staged patch database; otherwise `nil`.
     - Side effects:
       - prepares and steps one SQLite select statement
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
     */
    private func fetchBookmarkLabelLink(
        bookmarkID: UUID,
        labelID: UUID,
        tableName: String,
        from database: OpaquePointer
    ) throws -> RemoteSyncAndroidBookmarkLabelLink? {
        let sql = "SELECT labelId, orderNumber, indentLevel, expandContent FROM \(tableName) WHERE bookmarkId = ? AND labelId = ? LIMIT 1"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }
        bindUUIDBlob(bookmarkID, to: statement, index: 1)
        bindUUIDBlob(labelID, to: statement, index: 2)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return RemoteSyncAndroidBookmarkLabelLink(
            labelID: try uuidFromBlob(statement: statement, column: 0, table: tableName, name: "labelId"),
            orderNumber: Int(sqlite3_column_int(statement, 1)),
            indentLevel: Int(sqlite3_column_int(statement, 2)),
            expandContent: boolColumn(statement: statement, index: 3)
        )
    }

    /**
     Reads one `GenericBookmark` row from a staged patch database and merges it with preserved notes and label links.

     - Parameters:
       - id: Android `GenericBookmark.id` value to fetch.
       - preserving: Existing working bookmark used to preserve detached note and label-link rows when the patch only changed the parent bookmark table.
       - database: Open staged patch database handle.
     - Returns: Working generic bookmark when present in the staged patch database; otherwise `nil`.
     - Side effects:
       - prepares and steps one SQLite select statement
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when the row or label identifier is malformed
     */
    private func fetchGenericBookmark(
        id: UUID,
        preserving existing: WorkingGenericBookmark?,
        from database: OpaquePointer
    ) throws -> WorkingGenericBookmark? {
        let sql = """
        SELECT id, `key`, createdAt, bookInitials, ordinalStart, ordinalEnd, startOffset, endOffset,
               primaryLabelId, lastUpdatedOn, wholeVerse, playbackSettings, customIcon,
               editAction_mode, editAction_content
        FROM GenericBookmark
        WHERE id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }
        bindUUIDBlob(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return WorkingGenericBookmark(
            id: try uuidFromBlob(statement: statement, column: 0, table: "GenericBookmark", name: "id"),
            key: stringColumn(statement: statement, index: 1),
            createdAt: dateFromMillisecondsColumn(statement: statement, index: 2),
            bookInitials: stringColumn(statement: statement, index: 3),
            ordinalStart: Int(sqlite3_column_int(statement, 4)),
            ordinalEnd: Int(sqlite3_column_int(statement, 5)),
            startOffset: optionalIntColumn(statement: statement, index: 6),
            endOffset: optionalIntColumn(statement: statement, index: 7),
            primaryLabelID: try optionalUUIDFromBlob(statement: statement, column: 8, table: "GenericBookmark", name: "primaryLabelId"),
            notes: existing?.notes,
            lastUpdatedOn: dateFromMillisecondsColumn(statement: statement, index: 9),
            wholeVerse: boolColumn(statement: statement, index: 10),
            playbackSettingsJSON: optionalStringColumn(statement: statement, index: 11),
            customIcon: optionalStringColumn(statement: statement, index: 12),
            editAction: editAction(
                mode: optionalStringColumn(statement: statement, index: 13),
                content: optionalStringColumn(statement: statement, index: 14)
            ),
            labelLinks: existing?.labelLinks ?? []
        )
    }

    /**
     Reads one `StudyPadTextEntry` row from a staged patch database and merges it with the preserved text payload.

     - Parameters:
       - id: Android `StudyPadTextEntry.id` value to fetch.
       - preservingText: Existing working text payload for the entry, when present.
       - database: Open staged patch database handle.
     - Returns: Working StudyPad entry when present in the staged patch database; otherwise `nil`.
     - Side effects:
       - prepares and steps one SQLite select statement
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when the row or label identifier is malformed
     */
    private func fetchStudyPadEntry(
        id: UUID,
        preservingText: String?,
        from database: OpaquePointer
    ) throws -> WorkingStudyPadEntry? {
        let sql = "SELECT id, labelId, orderNumber, indentLevel FROM StudyPadTextEntry WHERE id = ? LIMIT 1"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }
        bindUUIDBlob(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return WorkingStudyPadEntry(
            id: try uuidFromBlob(statement: statement, column: 0, table: "StudyPadTextEntry", name: "id"),
            labelID: try uuidFromBlob(statement: statement, column: 1, table: "StudyPadTextEntry", name: "labelId"),
            orderNumber: Int(sqlite3_column_int(statement, 2)),
            indentLevel: Int(sqlite3_column_int(statement, 3)),
            text: preservingText
        )
    }

    /**
     Reads one `StudyPadTextEntryText` row from a staged patch database.

     - Parameters:
       - entryID: Android StudyPad-entry identifier used as the text-table primary key.
       - database: Open staged patch database handle.
     - Returns: Text payload when present in the staged patch database; otherwise `nil`.
     - Side effects:
       - prepares and steps one SQLite select statement
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
     */
    private func fetchStudyPadText(entryID: UUID, from database: OpaquePointer) throws -> String? {
        let sql = "SELECT text FROM StudyPadTextEntryText WHERE studyPadTextEntryId = ? LIMIT 1"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }
        bindUUIDBlob(entryID, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return stringColumn(statement: statement, index: 0)
    }

    /**
     Converts one preserved Android `LogEntry` identifier component into a UUID.

     Bookmark patches use UUID primary keys for every content table, with the two link tables using
     two UUID components. The local log-entry store preserves Android's typed SQLite values, so the
     replay engine validates that each required component is still a UUID-shaped blob or text value.

     - Parameters:
       - value: Typed SQLite value preserved from Android `LogEntry.entityId1` or `entityId2`.
       - tableName: Android table name used for error reporting.
       - field: Android log-entry field name used for error reporting.
     - Returns: UUID row identifier.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchApplyError.invalidLogEntryIdentifier` when the payload is not a UUID-shaped blob or text value
     */
    private func uuid(from value: RemoteSyncSQLiteValue, tableName: String, field: String) throws -> UUID {
        switch value.kind {
        case .blob:
            guard let data = value.blobData, data.count == 16 else {
                throw RemoteSyncBookmarkPatchApplyError.invalidLogEntryIdentifier(table: tableName, field: field)
            }
            return try uuidFromData(data, table: tableName, name: field)
        case .text:
            guard let textValue = value.textValue, let uuid = UUID(uuidString: textValue) else {
                throw RemoteSyncBookmarkPatchApplyError.invalidLogEntryIdentifier(table: tableName, field: field)
            }
            return uuid
        default:
            throw RemoteSyncBookmarkPatchApplyError.invalidLogEntryIdentifier(table: tableName, field: field)
        }
    }

    /**
     Executes a read-only SQLite block against one staged patch database.

     - Parameters:
       - databaseURL: Local URL of the decompressed staged patch database.
       - body: Closure that receives the open SQLite database handle.
     - Returns: Result produced by `body`.
     - Side effects:
       - opens the staged database in read-only mode for the duration of `body`
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the staged database cannot be opened
       - rethrows any error produced by `body`
     */
    private func withSQLiteDatabase<T>(at databaseURL: URL, body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    /**
     Creates a unique temporary database URL in the configured scratch directory.

     - Parameters:
       - prefix: Leading file-name prefix for easier debugging.
       - suffix: Trailing file-name suffix including the extension.
     - Returns: Unique temporary-file URL that does not yet exist.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func temporaryDatabaseURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    /**
     Recreates a minimal Android playback-settings JSON payload from the subset currently modeled on iOS.

     - Parameter playbackSettings: Current iOS bookmark playback settings.
     - Returns: Raw JSON payload containing `bookId`, or `nil` when the current bookmark has no playback metadata.
     - Side effects: none.
     - Failure modes:
       - encoding failures return `nil`
     */
    private func synthesizedPlaybackSettingsJSON(from playbackSettings: PlaybackSettings?) -> String? {
        guard let bookID = playbackSettings?.bookId, !bookID.isEmpty else {
            return nil
        }

        struct PlaybackProjection: Encodable {
            let bookId: String
        }

        guard let data = try? JSONEncoder().encode(PlaybackProjection(bookId: bookID)),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /**
     Reconstructs an optional bookmark edit-action descriptor from Android's flattened columns.

     - Parameters:
       - mode: Optional Android raw `EditActionMode` string.
       - content: Optional Android edit-action content payload.
     - Returns: Restored `EditAction`, or `nil` when both embedded columns were null.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func editAction(mode: String?, content: String?) -> EditAction? {
        guard mode != nil || content != nil else {
            return nil
        }
        return EditAction(mode: mode.flatMap(EditActionMode.init(rawValue:)), content: content)
    }

    /**
     Sorts bookmark-to-label links deterministically for snapshot stability.

     - Parameters:
       - lhs: Left-hand label link.
       - rhs: Right-hand label link.
     - Returns: `true` when `lhs` should sort before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func sortLabelLinks(_ lhs: RemoteSyncAndroidBookmarkLabelLink, _ rhs: RemoteSyncAndroidBookmarkLabelLink) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            return lhs.labelID.uuidString < rhs.labelID.uuidString
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    /**
     Sorts Android log entries into the deterministic order used for local replay bookkeeping.

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
            return sqliteValueSortKey(lhs.entityID1) < sqliteValueSortKey(rhs.entityID1)
        }
        return sqliteValueSortKey(lhs.entityID2) < sqliteValueSortKey(rhs.entityID2)
    }

    /**
     Builds a deterministic text representation of one typed SQLite value for stable local sorting.

     - Parameter value: Typed SQLite identifier component.
     - Returns: Canonical string representation of the value's storage kind and payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func sqliteValueSortKey(_ value: RemoteSyncSQLiteValue) -> String {
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

    /**
     Decompresses staged patch payloads using the same C helpers as archive staging.

     - Parameter data: Raw gzip-compressed patch bytes.
     - Returns: Decompressed SQLite database bytes.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncArchiveStagingError.decompressionFailed` when the payload is not valid gzip data
     */
    private static func gunzip(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = pointer.baseAddress else {
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
     Converts one required Android identifier BLOB into a Foundation `UUID`.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - column: Zero-based column index containing the UUID BLOB.
       - table: Android table name used for error reporting.
       - name: Android column name used for error reporting.
     - Returns: Converted UUID value.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when the column is absent, malformed, or not exactly 16 bytes long
     */
    private func uuidFromBlob(statement: OpaquePointer?, column: Int32, table: String, name: String) throws -> UUID {
        guard
            let bytes = sqlite3_column_blob(statement, column),
            sqlite3_column_bytes(statement, column) == 16
        else {
            throw RemoteSyncBookmarkRestoreError.invalidIdentifierBlob(table: table, column: name)
        }
        return try uuidFromData(Data(bytes: bytes, count: 16), table: table, name: name)
    }

    /**
     Converts one optional Android identifier BLOB into a Foundation `UUID`.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - column: Zero-based column index containing the optional BLOB.
       - table: Android table name used for error reporting.
       - name: Android column name used for error reporting.
     - Returns: Converted `UUID`, or `nil` when the SQLite column is `NULL`.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when a non-null BLOB is not a valid 16-byte Android identifier
     */
    private func optionalUUIDFromBlob(statement: OpaquePointer?, column: Int32, table: String, name: String) throws -> UUID? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return try uuidFromBlob(statement: statement, column: column, table: table, name: name)
    }

    /**
     Converts one 16-byte Android UUID payload into a Foundation `UUID`.

     - Parameters:
       - data: Raw 16-byte Android UUID payload.
       - table: Android table name used for error reporting.
       - name: Android column or field name used for error reporting.
     - Returns: Converted UUID value.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when the payload does not produce a valid UUID string
     */
    private func uuidFromData(_ data: Data, table: String, name: String) throws -> UUID {
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

        guard let uuid = UUID(uuidString: "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)") else {
            throw RemoteSyncBookmarkRestoreError.invalidIdentifierBlob(table: table, column: name)
        }
        return uuid
    }

    /**
     Binds one UUID as Android-style raw BLOB data to an SQLite statement.

     - Parameters:
       - uuid: UUID value to bind.
       - statement: SQLite statement receiving the bound parameter.
       - index: One-based parameter index.
     - Side effects:
       - mutates the bound SQLite statement parameter state
     - Failure modes: This helper cannot fail.
     */
    private func bindUUIDBlob(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "")
        var bytes = Data()
        bytes.reserveCapacity(16)

        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            bytes.append(UInt8(hex[cursor..<next], radix: 16) ?? 0)
            cursor = next
        }

        _ = bytes.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(statement, index, rawBuffer.baseAddress, Int32(bytes.count), remoteSyncBookmarkPatchSQLiteTransient)
        }
    }

    /**
     Reads one required SQLite text column as a Swift `String`.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - index: Zero-based text column index.
     - Returns: Decoded UTF-8 string, or an empty string when SQLite returned `NULL`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func stringColumn(statement: OpaquePointer?, index: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: raw)
    }

    /**
     Reads one optional SQLite text column as a Swift `String`.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - index: Zero-based text column index.
     - Returns: Decoded UTF-8 string, or `nil` when SQLite returned `NULL`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func optionalStringColumn(statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: raw)
    }

    /**
     Reads one optional SQLite integer column as a Swift `Int`.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - index: Zero-based integer column index.
     - Returns: Integer value, or `nil` when SQLite returned `NULL`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func optionalIntColumn(statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int(statement, index))
    }

    /**
     Reads one SQLite integer column as a `Bool` using Android's `0`/`1` convention.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - index: Zero-based integer column index.
     - Returns: `true` when the integer value is non-zero; otherwise `false`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func boolColumn(statement: OpaquePointer?, index: Int32) -> Bool {
        sqlite3_column_int(statement, index) != 0
    }

    /**
     Reads one SQLite millisecond-since-epoch column as a Foundation `Date`.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - index: Zero-based integer column index.
     - Returns: Foundation `Date` converted from Unix milliseconds.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func dateFromMillisecondsColumn(statement: OpaquePointer?, index: Int32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, index)) / 1000.0)
    }

    private static let supportedTableNames = Set([
        "Label",
        "BibleBookmark",
        "BibleBookmarkNotes",
        "BibleBookmarkToLabel",
        "GenericBookmark",
        "GenericBookmarkNotes",
        "GenericBookmarkToLabel",
        "StudyPadTextEntry",
        "StudyPadTextEntryText",
    ])
}
