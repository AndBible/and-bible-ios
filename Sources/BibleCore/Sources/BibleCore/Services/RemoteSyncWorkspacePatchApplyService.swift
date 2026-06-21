// RemoteSyncWorkspacePatchApplyService.swift — Incremental Android patch replay for workspaces

import CLibSword
import Foundation
import SQLite3
import SwiftData

private let remoteSyncWorkspacePatchSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while replaying Android workspace patch archives against the local SwiftData graph.

 Workspace patches use single-column identifiers for all supported tables, but they still rely on
 Android `LogEntry` metadata for timestamp precedence and sparse row lookup. The error surface
 distinguishes malformed log-entry identifiers from staged patch databases that omit one referenced
 content row.
 */
public enum RemoteSyncWorkspacePatchApplyError: Error, Equatable {
    /// One Android `LogEntry` identifier could not be converted into the expected UUID row key.
    case invalidLogEntryIdentifier(table: String, field: String)

    /// One `UPSERT` log entry referenced a row that was not present in the staged patch database.
    case missingPatchRow(table: String, id: UUID)
}

/**
 Summary of one successful workspace patch replay batch.

 Higher layers need both the patch-level counts and the final workspace restore summary because the
 replay engine stages Android patch rows in memory and then rewrites the whole local workspace graph
 through `RemoteSyncWorkspaceRestoreService`.
 */
public struct RemoteSyncWorkspacePatchApplyReport: Sendable, Equatable {
    /// Number of patch archives applied successfully.
    public let appliedPatchCount: Int

    /// Number of remote `LogEntry` rows that won Android's timestamp comparison and were replayed.
    public let appliedLogEntryCount: Int

    /// Number of remote `LogEntry` rows skipped because a local row was newer or equal.
    public let skippedLogEntryCount: Int

    /// Final workspace restore summary produced by the centralized rewrite path.
    public let restoreReport: RemoteSyncWorkspaceRestoreReport

    /**
     Creates one workspace patch replay summary.

     - Parameters:
       - appliedPatchCount: Number of patch archives applied successfully.
       - appliedLogEntryCount: Number of remote `LogEntry` rows replayed locally.
       - skippedLogEntryCount: Number of remote `LogEntry` rows skipped due to local precedence.
       - restoreReport: Final workspace restore summary produced after replay completed.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        appliedPatchCount: Int,
        appliedLogEntryCount: Int,
        skippedLogEntryCount: Int,
        restoreReport: RemoteSyncWorkspaceRestoreReport
    ) {
        self.appliedPatchCount = appliedPatchCount
        self.appliedLogEntryCount = appliedLogEntryCount
        self.skippedLogEntryCount = skippedLogEntryCount
        self.restoreReport = restoreReport
    }
}

/**
 Replays Android workspace patch archives into the local SwiftData workspace graph.

 Android's workspace sync stream applies incremental changes only for `Workspace`, `Window`, and
 `PageManager` rows. `HistoryItem` rows are present in full backups but are not part of the
 incremental patch contract. This service therefore:

 - projects the current local workspace graph and local-only fidelity rows into a mutable
   Android-shaped working snapshot
 - applies staged Android patch rows in the same table order Android uses in `SyncUtilities`
 - preserves existing history rows across rewrites so workspace patch replay does not silently drop
   local navigation history that lives outside the incremental patch contract
 - rewrites the final working snapshot through `RemoteSyncWorkspaceRestoreService.replaceLocalWorkspaces`
   so destructive local mutation stays centralized in one path

 Data dependencies:
 - `RemoteSyncWorkspaceRestoreService` performs the final SwiftData rewrite and fidelity-store refresh
 - `RemoteSyncWorkspaceSnapshotService` refreshes outbound workspace fingerprint baselines after
   remote replay succeeds
 - `RemoteSyncInitialBackupMetadataRestoreService` reads Android `LogEntry` rows from staged patch files
 - `RemoteSyncLogEntryStore` provides the local Android conflict baseline for timestamp comparison
 - `RemoteSyncPatchStatusStore` records successfully applied patch archives per source device
 - `RemoteSyncWorkspaceFidelityStore` supplies preserved Android-only workspace fidelity payloads and
   history-item identifier aliases while the current local graph is projected into working rows

 Side effects:
 - reads the current local workspace-category SwiftData graph and local-only fidelity stores
 - creates and removes temporary decompressed SQLite files beneath the configured temporary directory
 - rewrites the local workspace-category SwiftData graph after the full batch succeeds
 - replaces local Android `LogEntry` metadata for `.workspaces`
 - appends applied-patch bookkeeping rows to `RemoteSyncPatchStatusStore`
 - refreshes the outbound workspace fingerprint baseline after accepted replay

 Failure modes:
 - throws `RemoteSyncArchiveStagingError.decompressionFailed` when a staged gzip archive cannot be extracted
 - rethrows `RemoteSyncInitialBackupMetadataRestoreError` when staged `LogEntry` rows are malformed
 - throws `RemoteSyncWorkspacePatchApplyError.invalidLogEntryIdentifier` when a patch log row does not use the expected UUID row key
 - throws `RemoteSyncWorkspacePatchApplyError.missingPatchRow` when an `UPSERT` row has no matching content row in the patch database
 - rethrows `RemoteSyncWorkspaceRestoreError` when one patch row cannot be decoded or the final normalized snapshot is not representable by the centralized restore path
 - rethrows SwiftData fetch and save failures from the supplied `ModelContext`

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement of the supplied `ModelContext`
   and `SettingsStore`
 */
public final class RemoteSyncWorkspacePatchApplyService {
    private struct WorkingWorkspace {
        var id: UUID
        var name: String
        var contentsText: String?
        var orderNumber: Int
        var textDisplaySettings: TextDisplaySettings?
        var workspaceSettings: WorkspaceSettings
        var speakSettingsJSON: String?
        var unPinnedWeight: Float?
        var maximizedWindowID: UUID?
        var primaryTargetLinksWindowID: UUID?
        var workspaceColor: Int?
    }

    private struct WorkingWindow {
        var id: UUID
        var workspaceID: UUID
        var isSynchronized: Bool
        var isPinMode: Bool
        var isLinksWindow: Bool
        var orderNumber: Int
        var targetLinksWindowID: UUID?
        var syncGroup: Int
        var layoutState: String
        var layoutWeight: Float
    }

    private struct WorkingPageManager {
        var windowID: UUID
        var bibleDocument: String?
        var bibleVersification: String?
        var bibleBook: Int?
        var bibleChapterNo: Int?
        var bibleVerseNo: Int?
        var commentaryDocument: String?
        var commentaryAnchorOrdinal: Int?
        var commentarySourceBookAndKey: String?
        var dictionaryDocument: String?
        var dictionaryKey: String?
        var dictionaryAnchorOrdinal: Int?
        var generalBookDocument: String?
        var generalBookKey: String?
        var generalBookAnchorOrdinal: Int?
        var mapDocument: String?
        var mapKey: String?
        var mapAnchorOrdinal: Int?
        var currentCategoryName: String
        var textDisplaySettings: TextDisplaySettings?
        var jsState: String?

        /**
         Converts one mutable working page-manager row into the restore snapshot shape.

         - Returns: Immutable page-manager payload suitable for `RemoteSyncAndroidWorkspaceWindow`.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        func materializedValue() -> RemoteSyncAndroidWorkspacePageManager {
            RemoteSyncAndroidWorkspacePageManager(
                windowID: windowID,
                bibleDocument: bibleDocument,
                bibleVersification: bibleVersification,
                bibleBook: bibleBook,
                bibleChapterNo: bibleChapterNo,
                bibleVerseNo: bibleVerseNo,
                commentaryDocument: commentaryDocument,
                commentaryAnchorOrdinal: commentaryAnchorOrdinal,
                commentarySourceBookAndKey: commentarySourceBookAndKey,
                dictionaryDocument: dictionaryDocument,
                dictionaryKey: dictionaryKey,
                dictionaryAnchorOrdinal: dictionaryAnchorOrdinal,
                generalBookDocument: generalBookDocument,
                generalBookKey: generalBookKey,
                generalBookAnchorOrdinal: generalBookAnchorOrdinal,
                mapDocument: mapDocument,
                mapKey: mapKey,
                mapAnchorOrdinal: mapAnchorOrdinal,
                currentCategoryName: currentCategoryName,
                textDisplaySettings: textDisplaySettings,
                jsState: jsState
            )
        }
    }

    private struct WorkingHistoryItem {
        var remoteID: Int64
        var windowID: UUID
        var createdAt: Date
        var document: String
        var key: String
        var anchorOrdinal: Int?

        /**
         Converts one mutable working history row into the restore snapshot shape.

         - Returns: Immutable history payload suitable for `RemoteSyncAndroidWorkspaceWindow`.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        func materializedValue() -> RemoteSyncAndroidWorkspaceHistoryItem {
            RemoteSyncAndroidWorkspaceHistoryItem(
                remoteID: remoteID,
                windowID: windowID,
                createdAt: createdAt,
                document: document,
                key: key,
                anchorOrdinal: anchorOrdinal
            )
        }
    }

    private struct WorkingSnapshot {
        var workspacesByID: [UUID: WorkingWorkspace]
        var windowsByID: [UUID: WorkingWindow]
        var pageManagersByWindowID: [UUID: WorkingPageManager]
        var historyItemsByWindowID: [UUID: [WorkingHistoryItem]]

        /**
         Materializes the mutable working rows into the immutable snapshot shape expected by the centralized restore service.

         Windows whose patch stream currently leaves `PageManager` absent are normalized with a
         synthesized default page manager so iOS can preserve the window shell until a later patch
         repopulates the full page state.

         - Returns: Deterministically sorted workspace snapshot ready for `replaceLocalWorkspaces`.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        func materializedSnapshot() -> RemoteSyncAndroidWorkspaceSnapshot {
            let windowsByWorkspaceID = Dictionary(grouping: windowsByID.values, by: \.workspaceID)
            let workspaces = workspacesByID.values
                .sorted(by: Self.workspaceSort)
                .map { workspace in
                    let windows = windowsByWorkspaceID[workspace.id, default: []]
                        .sorted(by: Self.windowSort)
                        .map { window in
                            let pageManager = pageManagersByWindowID[window.id]
                                ?? Self.synthesizedPageManager(for: window.id)
                            let historyItems = historyItemsByWindowID[window.id, default: []]
                                .sorted(by: Self.historySort)
                                .map { $0.materializedValue() }
                            return RemoteSyncAndroidWorkspaceWindow(
                                id: window.id,
                                workspaceID: window.workspaceID,
                                isSynchronized: window.isSynchronized,
                                isPinMode: window.isPinMode,
                                isLinksWindow: window.isLinksWindow,
                                orderNumber: window.orderNumber,
                                targetLinksWindowID: window.targetLinksWindowID,
                                syncGroup: window.syncGroup,
                                layoutState: window.layoutState,
                                layoutWeight: window.layoutWeight,
                                pageManager: pageManager.materializedValue(),
                                historyItems: historyItems
                            )
                        }
                    return RemoteSyncAndroidWorkspace(
                        id: workspace.id,
                        name: workspace.name,
                        contentsText: workspace.contentsText,
                        orderNumber: workspace.orderNumber,
                        textDisplaySettings: workspace.textDisplaySettings,
                        workspaceSettings: workspace.workspaceSettings,
                        speakSettingsJSON: workspace.speakSettingsJSON,
                        unPinnedWeight: workspace.unPinnedWeight,
                        maximizedWindowID: workspace.maximizedWindowID,
                        primaryTargetLinksWindowID: workspace.primaryTargetLinksWindowID,
                        workspaceColor: workspace.workspaceColor,
                        windows: windows
                    )
                }
            return RemoteSyncAndroidWorkspaceSnapshot(workspaces: workspaces)
        }

        /**
         Sorts workspaces into Android display order with UUID tie-breaking.

         - Parameters:
           - lhs: Left-hand workspace value.
           - rhs: Right-hand workspace value.
         - Returns: `true` when `lhs` should appear before `rhs`.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        private static func workspaceSort(_ lhs: WorkingWorkspace, _ rhs: WorkingWorkspace) -> Bool {
            if lhs.orderNumber == rhs.orderNumber {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.orderNumber < rhs.orderNumber
        }

        /**
         Sorts windows into Android display order with UUID tie-breaking.

         - Parameters:
           - lhs: Left-hand window value.
           - rhs: Right-hand window value.
         - Returns: `true` when `lhs` should appear before `rhs`.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        private static func windowSort(_ lhs: WorkingWindow, _ rhs: WorkingWindow) -> Bool {
            if lhs.orderNumber == rhs.orderNumber {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.orderNumber < rhs.orderNumber
        }

        /**
         Sorts history rows by timestamp and then Android history identifier.

         - Parameters:
           - lhs: Left-hand history row.
           - rhs: Right-hand history row.
         - Returns: `true` when `lhs` should appear before `rhs`.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        private static func historySort(_ lhs: WorkingHistoryItem, _ rhs: WorkingHistoryItem) -> Bool {
            if lhs.createdAt == rhs.createdAt {
                return lhs.remoteID < rhs.remoteID
            }
            return lhs.createdAt < rhs.createdAt
        }

        /**
         Creates a minimal synthesized page manager for one window shell.

         - Parameter windowID: Identifier of the window that currently lacks a page manager row.
         - Returns: Default page-manager payload preserving the window shell until a later patch fills it.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        private static func synthesizedPageManager(for windowID: UUID) -> WorkingPageManager {
            WorkingPageManager(
                windowID: windowID,
                bibleDocument: nil,
                bibleVersification: nil,
                bibleBook: nil,
                bibleChapterNo: nil,
                bibleVerseNo: nil,
                commentaryDocument: nil,
                commentaryAnchorOrdinal: nil,
                commentarySourceBookAndKey: nil,
                dictionaryDocument: nil,
                dictionaryKey: nil,
                dictionaryAnchorOrdinal: nil,
                generalBookDocument: nil,
                generalBookKey: nil,
                generalBookAnchorOrdinal: nil,
                mapDocument: nil,
                mapKey: nil,
                mapAnchorOrdinal: nil,
                currentCategoryName: "BIBLE",
                textDisplaySettings: nil,
                jsState: nil
            )
        }
    }

    private struct AndroidRecentLabelPayload: Decodable {
        let labelId: String
        let lastAccess: Int64
    }

    private static let supportedTableNames: Set<String> = ["Workspace", "Window", "PageManager"]

    private let metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService
    private let restoreService: RemoteSyncWorkspaceRestoreService
    private let snapshotService: RemoteSyncWorkspaceSnapshotService
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let decoder = JSONDecoder()

    /**
     Creates a workspace patch replay service.

     - Parameters:
       - metadataRestoreService: Reader used for staged Android `LogEntry` rows.
       - restoreService: Centralized workspace restore path used for the final SwiftData rewrite.
       - snapshotService: Snapshot service used to refresh outbound workspace fingerprint baselines
         after accepted replay.
       - fileManager: File manager used for temporary-file cleanup.
       - temporaryDirectory: Scratch directory for temporary decompressed patch databases. Defaults
         to the process temporary directory.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService(),
        restoreService: RemoteSyncWorkspaceRestoreService = RemoteSyncWorkspaceRestoreService(),
        snapshotService: RemoteSyncWorkspaceSnapshotService = RemoteSyncWorkspaceSnapshotService(),
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
     Applies one ordered batch of staged Android workspace patch archives.

     The caller is expected to pass archives in discovery order, matching Android's per-device
     patch-number progression.

     - Parameters:
       - stagedArchives: Previously downloaded staged patch archives in application order.
       - modelContext: SwiftData context whose workspace graph should be rewritten on success.
       - settingsStore: Local-only settings store backing preserved Android fidelity metadata.
     - Returns: Summary describing how many patch archives and `LogEntry` rows were replayed.
     - Side effects:
       - creates and removes temporary decompressed SQLite files
       - rewrites the local workspace graph after the full batch succeeds
       - replaces local Android `LogEntry` rows for `.workspaces`
       - appends applied-patch rows to `RemoteSyncPatchStatusStore`
       - refreshes the outbound workspace fingerprint baseline after accepted replay
     - Failure modes:
       - rethrows patch-archive decompression failures
       - rethrows malformed staged `LogEntry` metadata failures
       - throws `RemoteSyncWorkspacePatchApplyError` for invalid identifiers or missing patch rows
       - rethrows `RemoteSyncWorkspaceRestoreError` when one patch row cannot be decoded safely
       - rethrows SwiftData fetch and save failures from `modelContext`
     */
    public func applyPatchArchives(
        _ stagedArchives: [RemoteSyncStagedPatchArchive],
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncWorkspacePatchApplyReport {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

        var snapshot = try currentSnapshot(from: modelContext, settingsStore: settingsStore)
        var logEntriesByKey = Dictionary(
            uniqueKeysWithValues: logEntryStore.entries(for: .workspaces).map {
                (logEntryStore.key(for: .workspaces, entry: $0), $0)
            }
        )

        var appliedPatchStatuses: [RemoteSyncPatchStatus] = []
        var appliedLogEntryCount = 0
        var skippedLogEntryCount = 0

        for stagedArchive in stagedArchives {
            try {
                let patchDatabaseURL = temporaryDatabaseURL(prefix: "remote-sync-workspaces-patch-", suffix: ".sqlite3")
                defer { try? fileManager.removeItem(at: patchDatabaseURL) }

                let archiveData = try Data(contentsOf: stagedArchive.archiveFileURL)
                let databaseData = try Self.gunzip(archiveData)
                try databaseData.write(to: patchDatabaseURL, options: .atomic)

                let metadataSnapshot = try metadataRestoreService.readSnapshot(from: patchDatabaseURL)
                let patchLogEntries = metadataSnapshot.logEntries.filter { Self.supportedTableNames.contains($0.tableName) }
                let filteredLogEntries = patchLogEntries.filter { entry in
                    let key = logEntryStore.key(for: .workspaces, entry: entry)
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
                    try applyWorkspaceOperations(
                        logEntries: filteredLogEntries.filter { $0.tableName == "Workspace" },
                        database: database,
                        snapshot: &snapshot,
                        logEntriesByKey: &logEntriesByKey,
                        logEntryStore: logEntryStore
                    )
                    try applyWindowOperations(
                        logEntries: filteredLogEntries.filter { $0.tableName == "Window" },
                        database: database,
                        snapshot: &snapshot,
                        logEntriesByKey: &logEntriesByKey,
                        logEntryStore: logEntryStore
                    )
                    try applyPageManagerOperations(
                        logEntries: filteredLogEntries.filter { $0.tableName == "PageManager" },
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

        let restoreReport = try restoreService.replaceLocalWorkspaces(
            from: snapshot.materializedSnapshot(),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        logEntryStore.replaceEntries(
            logEntriesByKey.values.sorted(by: Self.logEntrySort),
            for: .workspaces
        )
        patchStatusStore.addStatuses(appliedPatchStatuses, for: .workspaces)
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        return RemoteSyncWorkspacePatchApplyReport(
            appliedPatchCount: appliedPatchStatuses.count,
            appliedLogEntryCount: appliedLogEntryCount,
            skippedLogEntryCount: skippedLogEntryCount,
            restoreReport: restoreReport
        )
    }

    /**
     Loads the current local workspace graph into mutable Android-shaped working rows.

     History rows are preserved even though Android does not mutate them via workspace patch files.
     Existing Android-to-iOS history aliases are reversed when available; otherwise synthetic
     negative identifiers are assigned so the centralized restore path can rebuild the rows without
     colliding with Android's positive auto-generated history IDs.

     - Parameters:
       - modelContext: SwiftData context that owns the local workspace graph.
       - settingsStore: Local-only settings store backing workspace fidelity and history aliases.
     - Returns: Mutable working snapshot representing the current local workspace category.
     - Side effects:
       - reads workspace-category SwiftData rows from `modelContext`
       - reads preserved Android workspace fidelity rows from local settings
     - Failure modes:
       - rethrows SwiftData fetch failures from `modelContext.fetch`
     */
    private func currentSnapshot(
        from modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> WorkingSnapshot {
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        let workspaceFidelityByID = Dictionary(
            uniqueKeysWithValues: fidelityStore.allWorkspaceEntries().map { ($0.workspaceID, $0) }
        )
        let pageManagerFidelityByWindowID = Dictionary(
            uniqueKeysWithValues: fidelityStore.allPageManagerEntries().map { ($0.windowID, $0) }
        )
        let reverseHistoryAliases = Dictionary(
            uniqueKeysWithValues: fidelityStore.allHistoryItemAliases().map { ($0.localHistoryItemID, $0.remoteHistoryItemID) }
        )

        let workspaces = try modelContext.fetch(FetchDescriptor<Workspace>())
            .sorted { lhs, rhs in
                if lhs.orderNumber == rhs.orderNumber {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.orderNumber < rhs.orderNumber
            }

        var nextSyntheticHistoryID: Int64 = -1
        var workspacesByID: [UUID: WorkingWorkspace] = [:]
        var windowsByID: [UUID: WorkingWindow] = [:]
        var pageManagersByWindowID: [UUID: WorkingPageManager] = [:]
        var historyItemsByWindowID: [UUID: [WorkingHistoryItem]] = [:]

        for workspace in workspaces {
            let workspaceFidelity = workspaceFidelityByID[workspace.id]
            workspacesByID[workspace.id] = WorkingWorkspace(
                id: workspace.id,
                name: workspace.name,
                contentsText: workspace.contentsText,
                orderNumber: workspace.orderNumber,
                textDisplaySettings: workspace.textDisplaySettings,
                workspaceSettings: workspace.workspaceSettings ?? WorkspaceSettings(),
                speakSettingsJSON: workspaceFidelity?.speakSettingsJSON,
                unPinnedWeight: workspace.unPinnedWeight,
                maximizedWindowID: workspace.maximizedWindowId,
                primaryTargetLinksWindowID: workspace.primaryTargetLinksWindowId,
                workspaceColor: workspace.workspaceColor
            )

            let windows = (workspace.windows ?? []).sorted { lhs, rhs in
                if lhs.orderNumber == rhs.orderNumber {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.orderNumber < rhs.orderNumber
            }

            for window in windows {
                windowsByID[window.id] = WorkingWindow(
                    id: window.id,
                    workspaceID: workspace.id,
                    isSynchronized: window.isSynchronized,
                    isPinMode: window.isPinMode,
                    isLinksWindow: window.isLinksWindow,
                    orderNumber: window.orderNumber,
                    targetLinksWindowID: window.targetLinksWindowId,
                    syncGroup: window.syncGroup,
                    layoutState: window.layoutState,
                    layoutWeight: window.layoutWeight
                )

                let pageManager = window.pageManager
                let pageManagerFidelity = pageManagerFidelityByWindowID[window.id]
                pageManagersByWindowID[window.id] = WorkingPageManager(
                    windowID: window.id,
                    bibleDocument: pageManager?.bibleDocument,
                    bibleVersification: pageManager?.bibleVersification,
                    bibleBook: pageManager?.bibleBibleBook,
                    bibleChapterNo: pageManager?.bibleChapterNo,
                    bibleVerseNo: pageManager?.bibleVerseNo,
                    commentaryDocument: pageManager?.commentaryDocument,
                    commentaryAnchorOrdinal: pageManager?.commentaryAnchorOrdinal,
                    commentarySourceBookAndKey: pageManagerFidelity?.commentarySourceBookAndKey,
                    dictionaryDocument: pageManager?.dictionaryDocument,
                    dictionaryKey: pageManager?.dictionaryKey,
                    dictionaryAnchorOrdinal: pageManagerFidelity?.dictionaryAnchorOrdinal,
                    generalBookDocument: pageManager?.generalBookDocument,
                    generalBookKey: pageManager?.generalBookKey,
                    generalBookAnchorOrdinal: pageManagerFidelity?.generalBookAnchorOrdinal,
                    mapDocument: pageManager?.mapDocument,
                    mapKey: pageManager?.mapKey,
                    mapAnchorOrdinal: pageManagerFidelity?.mapAnchorOrdinal,
                    currentCategoryName: pageManagerFidelity?.rawCurrentCategoryName
                        ?? Self.remoteCurrentCategoryName(from: pageManager?.currentCategoryName ?? "bible"),
                    textDisplaySettings: pageManager?.textDisplaySettings,
                    jsState: pageManager?.jsState
                )

                let historyItems = (window.historyItems ?? []).sorted { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.createdAt < rhs.createdAt
                }
                historyItemsByWindowID[window.id] = historyItems.map { historyItem in
                    let remoteID: Int64
                    if let aliasedID = reverseHistoryAliases[historyItem.id] {
                        remoteID = aliasedID
                    } else {
                        remoteID = nextSyntheticHistoryID
                        nextSyntheticHistoryID -= 1
                    }
                    return WorkingHistoryItem(
                        remoteID: remoteID,
                        windowID: window.id,
                        createdAt: historyItem.createdAt,
                        document: historyItem.document,
                        key: historyItem.key,
                        anchorOrdinal: historyItem.anchorOrdinal
                    )
                }
            }
        }

        return WorkingSnapshot(
            workspacesByID: workspacesByID,
            windowsByID: windowsByID,
            pageManagersByWindowID: pageManagersByWindowID,
            historyItemsByWindowID: historyItemsByWindowID
        )
    }

    /**
     Applies `Workspace` table operations in Android table order.

     - Parameters:
       - logEntries: Newer patch log entries for the `Workspace` table.
       - database: Open staged patch database handle.
       - snapshot: Mutable working workspace snapshot.
       - logEntriesByKey: Mutable in-memory Android `LogEntry` map keyed by local settings keys.
       - logEntryStore: Store used to derive Android-compatible key strings.
     - Side effects:
       - mutates the working workspace map in memory
       - mutates the in-memory Android `LogEntry` map
       - prunes child windows, page managers, and history rows for deleted workspaces
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchApplyError.invalidLogEntryIdentifier` when a log row does not identify a UUID workspace row
       - throws `RemoteSyncWorkspacePatchApplyError.missingPatchRow` when an `UPSERT` row is absent from the patch database
       - rethrows SQLite read failures when one row cannot be decoded from the staged database
     */
    private func applyWorkspaceOperations(
        logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        for logEntry in logEntries {
            let workspaceID = try uuid(from: logEntry.entityID1, tableName: "Workspace", field: "entityId1")
            switch logEntry.type {
            case .delete:
                snapshot.workspacesByID.removeValue(forKey: workspaceID)
            case .upsert:
                guard let workspace = try fetchWorkspace(id: workspaceID, from: database) else {
                    throw RemoteSyncWorkspacePatchApplyError.missingPatchRow(table: "Workspace", id: workspaceID)
                }
                snapshot.workspacesByID[workspaceID] = workspace
            }
            logEntriesByKey[logEntryStore.key(for: .workspaces, entry: logEntry)] = logEntry
        }

        pruneMissingWorkspaceChildren(in: &snapshot)
    }

    /**
     Applies `Window` table operations in Android table order.

     - Parameters:
       - logEntries: Newer patch log entries for the `Window` table.
       - database: Open staged patch database handle.
       - snapshot: Mutable working workspace snapshot.
       - logEntriesByKey: Mutable in-memory Android `LogEntry` map keyed by local settings keys.
       - logEntryStore: Store used to derive Android-compatible key strings.
     - Side effects:
       - mutates the working window map in memory
       - mutates the in-memory Android `LogEntry` map
       - prunes page-manager and history rows for deleted or orphaned windows
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchApplyError.invalidLogEntryIdentifier` when a log row does not identify a UUID window row
       - throws `RemoteSyncWorkspacePatchApplyError.missingPatchRow` when an `UPSERT` row is absent from the patch database
       - rethrows SQLite read failures when one row cannot be decoded from the staged database
     */
    private func applyWindowOperations(
        logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        for logEntry in logEntries {
            let windowID = try uuid(from: logEntry.entityID1, tableName: "Window", field: "entityId1")
            switch logEntry.type {
            case .delete:
                snapshot.windowsByID.removeValue(forKey: windowID)
            case .upsert:
                guard let window = try fetchWindow(id: windowID, from: database) else {
                    throw RemoteSyncWorkspacePatchApplyError.missingPatchRow(table: "Window", id: windowID)
                }
                snapshot.windowsByID[windowID] = window
            }
            logEntriesByKey[logEntryStore.key(for: .workspaces, entry: logEntry)] = logEntry
        }

        pruneMissingWorkspaceChildren(in: &snapshot)
        pruneMissingWindowChildren(in: &snapshot)
    }

    /**
     Applies `PageManager` table operations in Android table order.

     - Parameters:
       - logEntries: Newer patch log entries for the `PageManager` table.
       - database: Open staged patch database handle.
       - snapshot: Mutable working workspace snapshot.
       - logEntriesByKey: Mutable in-memory Android `LogEntry` map keyed by local settings keys.
       - logEntryStore: Store used to derive Android-compatible key strings.
     - Side effects:
       - mutates the working page-manager map in memory
       - mutates the in-memory Android `LogEntry` map
       - prunes page-manager rows whose owning windows no longer exist
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchApplyError.invalidLogEntryIdentifier` when a log row does not identify a UUID window row
       - throws `RemoteSyncWorkspacePatchApplyError.missingPatchRow` when an `UPSERT` row is absent from the patch database
       - rethrows SQLite read failures when one row cannot be decoded from the staged database
     */
    private func applyPageManagerOperations(
        logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        snapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        for logEntry in logEntries {
            let windowID = try uuid(from: logEntry.entityID1, tableName: "PageManager", field: "entityId1")
            switch logEntry.type {
            case .delete:
                snapshot.pageManagersByWindowID.removeValue(forKey: windowID)
            case .upsert:
                guard let pageManager = try fetchPageManager(windowID: windowID, from: database) else {
                    throw RemoteSyncWorkspacePatchApplyError.missingPatchRow(table: "PageManager", id: windowID)
                }
                snapshot.pageManagersByWindowID[windowID] = pageManager
            }
            logEntriesByKey[logEntryStore.key(for: .workspaces, entry: logEntry)] = logEntry
        }

        pruneMissingWindowChildren(in: &snapshot)
    }

    /**
     Removes child rows whose owning workspace was deleted or became orphaned.

     - Parameter snapshot: Mutable working snapshot to normalize.
     - Side effects:
       - removes windows whose `workspaceID` is no longer present
       - removes page-manager and history rows owned by the removed windows
     - Failure modes: This helper cannot fail.
     */
    private func pruneMissingWorkspaceChildren(in snapshot: inout WorkingSnapshot) {
        let validWorkspaceIDs = Set(snapshot.workspacesByID.keys)
        let invalidWindowIDs = snapshot.windowsByID.values
            .filter { !validWorkspaceIDs.contains($0.workspaceID) }
            .map(\.id)
        for windowID in invalidWindowIDs {
            snapshot.windowsByID.removeValue(forKey: windowID)
            snapshot.pageManagersByWindowID.removeValue(forKey: windowID)
            snapshot.historyItemsByWindowID.removeValue(forKey: windowID)
        }
    }

    /**
     Removes page-manager and history rows whose owning window was deleted or became orphaned.

     - Parameter snapshot: Mutable working snapshot to normalize.
     - Side effects:
       - removes page-manager rows whose `windowID` is no longer present
       - removes history rows whose owning window is no longer present
     - Failure modes: This helper cannot fail.
     */
    private func pruneMissingWindowChildren(in snapshot: inout WorkingSnapshot) {
        let validWindowIDs = Set(snapshot.windowsByID.keys)
        snapshot.pageManagersByWindowID = snapshot.pageManagersByWindowID.filter { validWindowIDs.contains($0.key) }
        snapshot.historyItemsByWindowID = snapshot.historyItemsByWindowID.filter { validWindowIDs.contains($0.key) }
    }

    /**
     Reads one `Workspace` row from the staged patch database.

     - Parameters:
       - id: Workspace identifier referenced by Android `LogEntry.entityId1`.
       - database: Open staged patch database handle.
     - Returns: Decoded workspace row, or `nil` when the row is absent.
     - Side effects:
       - prepares and steps a SQLite query against the `Workspace` table
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase` when SQLite cannot prepare the query
       - rethrows workspace-column, identifier, and JSON-decoding failures from the shared decode helpers
     */
    private func fetchWorkspace(id: UUID, from database: OpaquePointer) throws -> WorkingWorkspace? {
        let sql = "SELECT * FROM Workspace WHERE id = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let columns = columnIndexMap(for: statement)
        let decodedSettings = try decodeWorkspaceSettings(
            table: "Workspace",
            statement: statement,
            columns: columns
        )
        return WorkingWorkspace(
            id: try requiredUUIDBlobColumn("id", table: "Workspace", statement: statement, columns: columns),
            name: try requiredTextColumn("name", table: "Workspace", statement: statement, columns: columns),
            contentsText: try optionalTextColumn("contentsText", table: "Workspace", statement: statement, columns: columns),
            orderNumber: try requiredIntColumn("orderNumber", table: "Workspace", statement: statement, columns: columns),
            textDisplaySettings: try decodeTextDisplaySettings(
                table: "Workspace",
                statement: statement,
                columns: columns,
                prefix: "text_display_settings_"
            ),
            workspaceSettings: decodedSettings.settings,
            speakSettingsJSON: decodedSettings.speakSettingsJSON,
            unPinnedWeight: try optionalFloatColumn("unPinnedWeight", table: "Workspace", statement: statement, columns: columns),
            maximizedWindowID: try optionalUUIDBlobColumn("maximizedWindowId", table: "Workspace", statement: statement, columns: columns),
            primaryTargetLinksWindowID: try optionalUUIDBlobColumn("primaryTargetLinksWindowId", table: "Workspace", statement: statement, columns: columns),
            workspaceColor: decodedSettings.workspaceColor
        )
    }

    /**
     Reads one `Window` row from the staged patch database.

     - Parameters:
       - id: Window identifier referenced by Android `LogEntry.entityId1`.
       - database: Open staged patch database handle.
     - Returns: Decoded window row, or `nil` when the row is absent.
     - Side effects:
       - prepares and steps a SQLite query against the `Window` table
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase` when SQLite cannot prepare the query
       - rethrows window-column and identifier-decoding failures from the shared decode helpers
     */
    private func fetchWindow(id: UUID, from database: OpaquePointer) throws -> WorkingWindow? {
        let sql = "SELECT * FROM \"Window\" WHERE id = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let columns = columnIndexMap(for: statement)
        return WorkingWindow(
            id: try requiredUUIDBlobColumn("id", table: "Window", statement: statement, columns: columns),
            workspaceID: try requiredUUIDBlobColumn("workspaceId", table: "Window", statement: statement, columns: columns),
            isSynchronized: try requiredBoolColumn("isSynchronized", table: "Window", statement: statement, columns: columns),
            isPinMode: try requiredBoolColumn("isPinMode", table: "Window", statement: statement, columns: columns),
            isLinksWindow: try boolColumn("isLinksWindow", table: "Window", statement: statement, columns: columns, default: false),
            orderNumber: try requiredIntColumn("orderNumber", table: "Window", statement: statement, columns: columns),
            targetLinksWindowID: try optionalUUIDBlobColumn("targetLinksWindowId", table: "Window", statement: statement, columns: columns),
            syncGroup: try intOrDefaultColumn("syncGroup", table: "Window", statement: statement, columns: columns, default: 0),
            layoutState: try requiredTextColumn("window_layout_state", table: "Window", statement: statement, columns: columns),
            layoutWeight: try floatOrDefaultColumn("window_layout_weight", table: "Window", statement: statement, columns: columns, default: 1.0)
        )
    }

    /**
     Reads one `PageManager` row from the staged patch database.

     - Parameters:
       - windowID: Window identifier referenced by Android `LogEntry.entityId1`.
       - database: Open staged patch database handle.
     - Returns: Decoded page-manager row, or `nil` when the row is absent.
     - Side effects:
       - prepares and steps a SQLite query against the `PageManager` table
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase` when SQLite cannot prepare the query
       - rethrows page-manager column, identifier, and JSON-decoding failures from the shared decode helpers
     */
    private func fetchPageManager(windowID: UUID, from database: OpaquePointer) throws -> WorkingPageManager? {
        let sql = "SELECT * FROM PageManager WHERE windowId = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(windowID, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let columns = columnIndexMap(for: statement)
        return WorkingPageManager(
            windowID: try requiredUUIDBlobColumn("windowId", table: "PageManager", statement: statement, columns: columns),
            bibleDocument: try optionalTextColumn("bible_document", table: "PageManager", statement: statement, columns: columns),
            bibleVersification: try optionalTextColumn("bible_verse_versification", table: "PageManager", statement: statement, columns: columns),
            bibleBook: try optionalIntColumn("bible_verse_bibleBook", table: "PageManager", statement: statement, columns: columns),
            bibleChapterNo: try optionalIntColumn("bible_verse_chapterNo", table: "PageManager", statement: statement, columns: columns),
            bibleVerseNo: try optionalIntColumn("bible_verse_verseNo", table: "PageManager", statement: statement, columns: columns),
            commentaryDocument: try optionalTextColumn("commentary_document", table: "PageManager", statement: statement, columns: columns),
            commentaryAnchorOrdinal: try optionalIntColumn("commentary_anchorOrdinal", table: "PageManager", statement: statement, columns: columns),
            commentarySourceBookAndKey: try optionalTextColumn("commentary_sourceBookAndKey", table: "PageManager", statement: statement, columns: columns),
            dictionaryDocument: try optionalTextColumn("dictionary_document", table: "PageManager", statement: statement, columns: columns),
            dictionaryKey: try optionalTextColumn("dictionary_key", table: "PageManager", statement: statement, columns: columns),
            dictionaryAnchorOrdinal: try optionalIntColumn("dictionary_anchorOrdinal", table: "PageManager", statement: statement, columns: columns),
            generalBookDocument: try optionalTextColumn("general_book_document", table: "PageManager", statement: statement, columns: columns),
            generalBookKey: try optionalTextColumn("general_book_key", table: "PageManager", statement: statement, columns: columns),
            generalBookAnchorOrdinal: try optionalIntColumn("general_book_anchorOrdinal", table: "PageManager", statement: statement, columns: columns),
            mapDocument: try optionalTextColumn("map_document", table: "PageManager", statement: statement, columns: columns),
            mapKey: try optionalTextColumn("map_key", table: "PageManager", statement: statement, columns: columns),
            mapAnchorOrdinal: try optionalIntColumn("map_anchorOrdinal", table: "PageManager", statement: statement, columns: columns),
            currentCategoryName: try requiredTextColumn("currentCategoryName", table: "PageManager", statement: statement, columns: columns),
            textDisplaySettings: try decodeTextDisplaySettings(
                table: "PageManager",
                statement: statement,
                columns: columns,
                prefix: "text_display_settings_"
            ),
            jsState: try optionalTextColumn("jsState", table: "PageManager", statement: statement, columns: columns)
        )
    }

    /**
     Decodes Android workspace-scoped settings and extracts the unsupported speech-settings payload.

     - Parameters:
       - table: Table name used for error reporting.
       - statement: SQLite statement currently positioned on a `Workspace` row.
       - columns: Precomputed column-name map for the statement.
     - Returns: Decoded iOS `WorkspaceSettings`, raw Android `speakSettings` JSON, and workspace color.
     - Side effects: none.
     - Failure modes:
       - rethrows `RemoteSyncWorkspaceRestoreError.malformedSerializedValue` when one serialized JSON payload cannot be decoded safely
       - rethrows `RemoteSyncWorkspaceRestoreError.invalidIdentifierBlob` when one UUID-like BLOB column cannot be converted into `UUID`
     */
    private func decodeWorkspaceSettings(
        table: String,
        statement: OpaquePointer,
        columns: [String: Int32]
    ) throws -> (settings: WorkspaceSettings, speakSettingsJSON: String?, workspaceColor: Int?) {
        var settings = WorkspaceSettings()
        settings.enableTiltToScroll = try boolColumn(
            "workspace_settings_enableTiltToScroll",
            table: table,
            statement: statement,
            columns: columns,
            default: false
        )
        settings.enableReverseSplitMode = try boolColumn(
            "workspace_settings_enableReverseSplitMode",
            table: table,
            statement: statement,
            columns: columns,
            default: false
        )
        settings.autoPin = try boolColumn(
            "workspace_settings_autoPin",
            table: table,
            statement: statement,
            columns: columns,
            default: true
        )
        if let recentLabelsJSON = try optionalTextColumn(
            "workspace_settings_recentLabels",
            table: table,
            statement: statement,
            columns: columns
        ) {
            settings.recentLabels = try decodeRecentLabels(
                recentLabelsJSON,
                table: table,
                column: "workspace_settings_recentLabels"
            )
        }
        if let autoAssignLabelsJSON = try optionalTextColumn(
            "workspace_settings_autoAssignLabels",
            table: table,
            statement: statement,
            columns: columns
        ) {
            settings.autoAssignLabels = try decodeUUIDSet(
                autoAssignLabelsJSON,
                table: table,
                column: "workspace_settings_autoAssignLabels"
            )
        }
        settings.autoAssignPrimaryLabel = try optionalUUIDBlobColumn(
            "workspace_settings_autoAssignPrimaryLabel",
            table: table,
            statement: statement,
            columns: columns
        )
        if let studyPadCursorsJSON = try optionalTextColumn(
            "workspace_settings_studyPadCursors",
            table: table,
            statement: statement,
            columns: columns
        ) {
            settings.studyPadCursors = try decodeUUIDIntDictionary(
                studyPadCursorsJSON,
                table: table,
                column: "workspace_settings_studyPadCursors"
            )
        }
        if let hideCompareDocumentsJSON = try optionalTextColumn(
            "workspace_settings_hideCompareDocuments",
            table: table,
            statement: statement,
            columns: columns
        ) {
            settings.hideCompareDocuments = try decodeStringSet(
                hideCompareDocumentsJSON,
                table: table,
                column: "workspace_settings_hideCompareDocuments"
            )
        }
        settings.limitAmbiguousModalSize = try boolColumn(
            "workspace_settings_limitAmbiguousModalSize",
            table: table,
            statement: statement,
            columns: columns,
            default: false
        )

        let speakSettingsJSON = try optionalTextColumn(
            "workspace_settings_speakSettings",
            table: table,
            statement: statement,
            columns: columns
        )
        let workspaceColor = try optionalIntColumn(
            "workspace_settings_workspaceColor",
            table: table,
            statement: statement,
            columns: columns
        )

        settings.normalizeAutoAssignPrimaryLabel()
        return (settings, speakSettingsJSON, workspaceColor)
    }

    /**
     Decodes one Android text-display settings block from a `Workspace` or `PageManager` row.

     - Parameters:
       - table: Table name used for error reporting.
       - statement: SQLite statement currently positioned on the row being decoded.
       - columns: Precomputed column-name map for the statement.
       - prefix: Column-name prefix used by the embedded Android settings block.
     - Returns: Decoded `TextDisplaySettings`, or `nil` when every embedded column is null.
     - Side effects: none.
     - Failure modes:
       - rethrows `RemoteSyncWorkspaceRestoreError.malformedSerializedValue` when `bookmarksHideLabels` JSON cannot be decoded safely
     */
    private func decodeTextDisplaySettings(
        table: String,
        statement: OpaquePointer,
        columns: [String: Int32],
        prefix: String
    ) throws -> TextDisplaySettings? {
        var settings = TextDisplaySettings()
        var hasValue = false

        func assignInt(_ column: String, _ keyPath: WritableKeyPath<TextDisplaySettings, Int?>) throws {
            if let value = try optionalIntColumn(column, table: table, statement: statement, columns: columns) {
                settings[keyPath: keyPath] = value
                hasValue = true
            }
        }

        func assignString(_ column: String, _ keyPath: WritableKeyPath<TextDisplaySettings, String?>) throws {
            if let value = try optionalTextColumn(column, table: table, statement: statement, columns: columns) {
                settings[keyPath: keyPath] = value
                hasValue = true
            }
        }

        func assignBool(_ column: String, _ keyPath: WritableKeyPath<TextDisplaySettings, Bool?>) throws {
            if let value = try optionalBoolColumn(column, table: table, statement: statement, columns: columns) {
                settings[keyPath: keyPath] = value
                hasValue = true
            }
        }

        try assignInt("\(prefix)strongsMode", \.strongsMode)
        try assignBool("\(prefix)showMorphology", \.showMorphology)
        try assignBool("\(prefix)showFootNotes", \.showFootNotes)
        try assignBool("\(prefix)showFootNotesInline", \.showFootNotesInline)
        try assignBool("\(prefix)expandXrefs", \.expandXrefs)
        try assignBool("\(prefix)showXrefs", \.showXrefs)
        try assignBool("\(prefix)showRedLetters", \.showRedLetters)
        try assignBool("\(prefix)showSectionTitles", \.showSectionTitles)
        try assignBool("\(prefix)showVerseNumbers", \.showVerseNumbers)
        try assignBool("\(prefix)showVersePerLine", \.showVersePerLine)
        try assignBool("\(prefix)showBookmarks", \.showBookmarks)
        try assignBool("\(prefix)showMyNotes", \.showMyNotes)
        try assignBool("\(prefix)justifyText", \.justifyText)
        try assignBool("\(prefix)hyphenation", \.hyphenation)
        try assignInt("\(prefix)topMargin", \.topMargin)
        try assignInt("\(prefix)fontSize", \.fontSize)
        try assignString("\(prefix)fontFamily", \.fontFamily)
        try assignInt("\(prefix)lineSpacing", \.lineSpacing)
        try assignBool("\(prefix)showPageNumber", \.showPageNumber)
        try assignInt("\(prefix)margin_size_marginLeft", \.marginLeft)
        try assignInt("\(prefix)margin_size_marginRight", \.marginRight)
        try assignInt("\(prefix)margin_size_maxWidth", \.maxWidth)
        try assignInt("\(prefix)colors_dayTextColor", \.dayTextColor)
        try assignInt("\(prefix)colors_dayBackground", \.dayBackground)
        try assignInt("\(prefix)colors_dayNoise", \.dayNoise)
        try assignInt("\(prefix)colors_nightTextColor", \.nightTextColor)
        try assignInt("\(prefix)colors_nightBackground", \.nightBackground)
        try assignInt("\(prefix)colors_nightNoise", \.nightNoise)

        if let bookmarksHideLabelsJSON = try optionalTextColumn(
            "\(prefix)bookmarksHideLabels",
            table: table,
            statement: statement,
            columns: columns
        ) {
            settings.bookmarksHideLabels = try decodeUUIDArray(
                bookmarksHideLabelsJSON,
                table: table,
                column: "\(prefix)bookmarksHideLabels"
            )
            hasValue = true
        }

        return hasValue ? settings : nil
    }

    /**
     Decodes Android `recentLabels` JSON into iOS `RecentLabel` values.

     - Parameters:
       - jsonString: Raw Android JSON payload.
       - table: Table name used for error reporting.
       - column: Column name used for error reporting.
     - Returns: Decoded recent-label list preserving Android ordering.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.malformedSerializedValue` when the JSON payload or one UUID string is invalid
     */
    private func decodeRecentLabels(_ jsonString: String, table: String, column: String) throws -> [RecentLabel] {
        let payloads: [AndroidRecentLabelPayload] = try decodeJSON([AndroidRecentLabelPayload].self, from: jsonString, table: table, column: column)
        return try payloads.map { payload in
            guard let labelID = UUID(uuidString: payload.labelId) else {
                throw RemoteSyncWorkspaceRestoreError.malformedSerializedValue(table: table, column: column)
            }
            return RecentLabel(
                labelId: labelID,
                lastAccess: Date(timeIntervalSince1970: Double(payload.lastAccess) / 1000.0)
            )
        }
    }

    /**
     Decodes Android JSON arrays of UUID strings into an ordered UUID array.

     - Parameters:
       - jsonString: Raw Android JSON payload.
       - table: Table name used for error reporting.
       - column: Column name used for error reporting.
     - Returns: Ordered UUID array.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.malformedSerializedValue` when the JSON payload or one UUID string is invalid
     */
    private func decodeUUIDArray(_ jsonString: String, table: String, column: String) throws -> [UUID] {
        let rawValues: [String] = try decodeJSON([String].self, from: jsonString, table: table, column: column)
        return try rawValues.map { rawValue in
            guard let uuid = UUID(uuidString: rawValue) else {
                throw RemoteSyncWorkspaceRestoreError.malformedSerializedValue(table: table, column: column)
            }
            return uuid
        }
    }

    /**
     Decodes Android JSON arrays of UUID strings into an unordered UUID set.

     - Parameters:
       - jsonString: Raw Android JSON payload.
       - table: Table name used for error reporting.
       - column: Column name used for error reporting.
     - Returns: UUID set containing every decoded entry.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.malformedSerializedValue` when the JSON payload or one UUID string is invalid
     */
    private func decodeUUIDSet(_ jsonString: String, table: String, column: String) throws -> Set<UUID> {
        Set(try decodeUUIDArray(jsonString, table: table, column: column))
    }

    /**
     Decodes Android JSON arrays of strings into an unordered string set.

     - Parameters:
       - jsonString: Raw Android JSON payload.
       - table: Table name used for error reporting.
       - column: Column name used for error reporting.
     - Returns: String set containing every decoded entry.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.malformedSerializedValue` when the JSON payload is invalid
     */
    private func decodeStringSet(_ jsonString: String, table: String, column: String) throws -> Set<String> {
        Set(try decodeJSON([String].self, from: jsonString, table: table, column: column))
    }

    /**
     Decodes Android JSON objects keyed by UUID strings into an iOS UUID-to-int dictionary.

     - Parameters:
       - jsonString: Raw Android JSON payload.
       - table: Table name used for error reporting.
       - column: Column name used for error reporting.
     - Returns: Dictionary keyed by decoded UUID values.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.malformedSerializedValue` when the JSON payload or one UUID key is invalid
     */
    private func decodeUUIDIntDictionary(_ jsonString: String, table: String, column: String) throws -> [UUID: Int] {
        let rawDictionary: [String: Int] = try decodeJSON([String: Int].self, from: jsonString, table: table, column: column)
        var result: [UUID: Int] = [:]
        for (rawKey, value) in rawDictionary {
            guard let uuid = UUID(uuidString: rawKey) else {
                throw RemoteSyncWorkspaceRestoreError.malformedSerializedValue(table: table, column: column)
            }
            result[uuid] = value
        }
        return result
    }

    /**
     Decodes one JSON payload and normalizes decode failures into restore-domain errors.

     - Parameters:
       - type: Decodable type expected from the payload.
       - jsonString: Raw JSON payload.
       - table: Table name used for error reporting.
       - column: Column name used for error reporting.
     - Returns: Decoded payload of the requested type.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.malformedSerializedValue` when the payload cannot be decoded into `T`
     */
    private func decodeJSON<T: Decodable>(_ type: T.Type, from jsonString: String, table: String, column: String) throws -> T {
        guard let data = jsonString.data(using: .utf8) else {
            throw RemoteSyncWorkspaceRestoreError.malformedSerializedValue(table: table, column: column)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw RemoteSyncWorkspaceRestoreError.malformedSerializedValue(table: table, column: column)
        }
    }

    /**
     Builds a lookup from SQLite result-column names to column indices.

     - Parameter statement: Prepared SQLite statement whose result columns should be indexed.
     - Returns: Dictionary from column name to zero-based result index.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func columnIndexMap(for statement: OpaquePointer) -> [String: Int32] {
        var columns: [String: Int32] = [:]
        let count = sqlite3_column_count(statement)
        for index in 0..<count {
            guard let cString = sqlite3_column_name(statement, index) else {
                continue
            }
            columns[String(cString: cString)] = index
        }
        return columns
    }

    /**
     Resolves one SQLite result-column index by name.

     - Parameters:
       - name: Column name expected in the result set.
       - table: Table name used for error reporting.
       - columns: Precomputed column-name map.
     - Returns: Matching SQLite result-column index.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidColumnValue` when the expected column is absent from the prepared result set
     */
    private func columnIndex(_ name: String, table: String, columns: [String: Int32]) throws -> Int32 {
        guard let index = columns[name] else {
            throw RemoteSyncWorkspaceRestoreError.invalidColumnValue(table: table, column: name)
        }
        return index
    }

    /**
     Reads one required text column from the current SQLite row.

     - Parameters:
       - name: Required column name.
       - table: Table name used for error reporting.
       - statement: SQLite statement positioned on the current row.
       - columns: Precomputed column-name map.
     - Returns: Decoded UTF-8 string value.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidColumnValue` when the column is null or not readable as text
     */
    private func requiredTextColumn(
        _ name: String,
        table: String,
        statement: OpaquePointer,
        columns: [String: Int32]
    ) throws -> String {
        let index = try columnIndex(name, table: table, columns: columns)
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, index) else {
            throw RemoteSyncWorkspaceRestoreError.invalidColumnValue(table: table, column: name)
        }
        return String(cString: cString)
    }

    /**
     Reads one optional text column from the current SQLite row.

     - Parameters:
       - name: Column name.
       - table: Table name used for error reporting.
       - statement: SQLite statement positioned on the current row.
       - columns: Precomputed column-name map.
     - Returns: Decoded UTF-8 string, or `nil` when the SQLite value is null.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidColumnValue` when the expected column is absent from the result set
     */
    private func optionalTextColumn(
        _ name: String,
        table: String,
        statement: OpaquePointer,
        columns: [String: Int32]
    ) throws -> String? {
        let index = try columnIndex(name, table: table, columns: columns)
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }

    /**
     Reads one required integer column from the current SQLite row.

     - Parameters:
       - name: Required column name.
       - table: Table name used for error reporting.
       - statement: SQLite statement positioned on the current row.
       - columns: Precomputed column-name map.
     - Returns: Integer value decoded from the current row.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidColumnValue` when the column is null
     */
    private func requiredIntColumn(
        _ name: String,
        table: String,
        statement: OpaquePointer,
        columns: [String: Int32]
    ) throws -> Int {
        let index = try columnIndex(name, table: table, columns: columns)
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            throw RemoteSyncWorkspaceRestoreError.invalidColumnValue(table: table, column: name)
        }
        return Int(sqlite3_column_int(statement, index))
    }

    /**
     Reads one optional integer column from the current SQLite row.

     - Parameters:
       - name: Column name.
       - table: Table name used for error reporting.
       - statement: SQLite statement positioned on the current row.
       - columns: Precomputed column-name map.
     - Returns: Integer value, or `nil` when the SQLite value is null.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidColumnValue` when the expected column is absent from the result set
     */
    private func optionalIntColumn(
        _ name: String,
        table: String,
        statement: OpaquePointer,
        columns: [String: Int32]
    ) throws -> Int? {
        let index = try columnIndex(name, table: table, columns: columns)
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int(statement, index))
    }

    /**
     Reads one integer column, falling back to the supplied default when SQLite stores null.

     - Parameters:
       - name: Column name.
       - table: Table name used for error reporting.
       - statement: SQLite statement positioned on the current row.
       - columns: Precomputed column-name map.
       - defaultValue: Fallback used when the SQLite value is null.
     - Returns: Integer column value or the provided default.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidColumnValue` when the expected column is absent from the result set
     */
    private func intOrDefaultColumn(
        _ name: String,
        table: String,
        statement: OpaquePointer,
        columns: [String: Int32],
        default defaultValue: Int
    ) throws -> Int {
        try optionalIntColumn(name, table: table, statement: statement, columns: columns) ?? defaultValue
    }

    /**
     Reads one optional boolean column from the current SQLite row.

     - Parameters:
       - name: Column name.
       - table: Table name used for error reporting.
       - statement: SQLite statement positioned on the current row.
       - columns: Precomputed column-name map.
     - Returns: Boolean value, or `nil` when the SQLite value is null.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidColumnValue` when the expected column is absent from the result set
     */
    private func optionalBoolColumn(
        _ name: String,
        table: String,
        statement: OpaquePointer,
        columns: [String: Int32]
    ) throws -> Bool? {
        let index = try columnIndex(name, table: table, columns: columns)
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_int(statement, index) != 0
    }

    /**
     Reads one required boolean column from the current SQLite row.

     - Parameters:
       - name: Required column name.
       - table: Table name used for error reporting.
       - statement: SQLite statement positioned on the current row.
       - columns: Precomputed column-name map.
     - Returns: Boolean value decoded from the current row.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidColumnValue` when the column is null
     */
    private func requiredBoolColumn(
        _ name: String,
        table: String,
        statement: OpaquePointer,
        columns: [String: Int32]
    ) throws -> Bool {
        let index = try columnIndex(name, table: table, columns: columns)
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            throw RemoteSyncWorkspaceRestoreError.invalidColumnValue(table: table, column: name)
        }
        return sqlite3_column_int(statement, index) != 0
    }

    /**
     Reads one boolean column, falling back to the supplied default when SQLite stores null.

     - Parameters:
       - name: Column name.
       - table: Table name used for error reporting.
       - statement: SQLite statement positioned on the current row.
       - columns: Precomputed column-name map.
       - defaultValue: Fallback used when the SQLite value is null.
     - Returns: Boolean column value or the provided default.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidColumnValue` when the expected column is absent from the result set
     */
    private func boolColumn(
        _ name: String,
        table: String,
        statement: OpaquePointer,
        columns: [String: Int32],
        default defaultValue: Bool
    ) throws -> Bool {
        try optionalBoolColumn(name, table: table, statement: statement, columns: columns) ?? defaultValue
    }

    /**
     Reads one optional floating-point column from the current SQLite row.

     - Parameters:
       - name: Column name.
       - table: Table name used for error reporting.
       - statement: SQLite statement positioned on the current row.
       - columns: Precomputed column-name map.
     - Returns: Floating-point value, or `nil` when the SQLite value is null.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidColumnValue` when the expected column is absent from the result set
     */
    private func optionalFloatColumn(
        _ name: String,
        table: String,
        statement: OpaquePointer,
        columns: [String: Int32]
    ) throws -> Float? {
        let index = try columnIndex(name, table: table, columns: columns)
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Float(sqlite3_column_double(statement, index))
    }

    /**
     Reads one floating-point column, falling back to the supplied default when SQLite stores null.

     - Parameters:
       - name: Column name.
       - table: Table name used for error reporting.
       - statement: SQLite statement positioned on the current row.
       - columns: Precomputed column-name map.
       - defaultValue: Fallback used when the SQLite value is null.
     - Returns: Floating-point column value or the provided default.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidColumnValue` when the expected column is absent from the result set
     */
    private func floatOrDefaultColumn(
        _ name: String,
        table: String,
        statement: OpaquePointer,
        columns: [String: Int32],
        default defaultValue: Float
    ) throws -> Float {
        try optionalFloatColumn(name, table: table, statement: statement, columns: columns) ?? defaultValue
    }

    /**
     Reads one required UUID-like BLOB column from the current SQLite row.

     - Parameters:
       - name: Required column name.
       - table: Table name used for error reporting.
       - statement: SQLite statement positioned on the current row.
       - columns: Precomputed column-name map.
     - Returns: UUID converted from Android's 16-byte blob format.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidIdentifierBlob` when the column is null, not 16 bytes, or not convertible into `UUID`
     */
    private func requiredUUIDBlobColumn(
        _ name: String,
        table: String,
        statement: OpaquePointer,
        columns: [String: Int32]
    ) throws -> UUID {
        let index = try columnIndex(name, table: table, columns: columns)
        guard let value = try uuidFromBlob(
            statement: statement,
            columnIndex: index,
            table: table,
            column: name,
            allowNull: false
        ) else {
            throw RemoteSyncWorkspaceRestoreError.invalidIdentifierBlob(table: table, column: name)
        }
        return value
    }

    /**
     Reads one optional UUID-like BLOB column from the current SQLite row.

     - Parameters:
       - name: Column name.
       - table: Table name used for error reporting.
       - statement: SQLite statement positioned on the current row.
       - columns: Precomputed column-name map.
     - Returns: UUID converted from Android's 16-byte blob format, or `nil` when the SQLite value is null.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidIdentifierBlob` when a non-null blob is not 16 bytes or not convertible into `UUID`
     */
    private func optionalUUIDBlobColumn(
        _ name: String,
        table: String,
        statement: OpaquePointer,
        columns: [String: Int32]
    ) throws -> UUID? {
        let index = try columnIndex(name, table: table, columns: columns)
        return try uuidFromBlob(statement: statement, columnIndex: index, table: table, column: name, allowNull: true)
    }

    /**
     Converts one Android 16-byte identifier blob into a Swift `UUID`.

     Android `IdType` stores identifiers as 16 raw bytes representing the UUID bit layout. This
     helper reconstructs the `UUID` without assuming textual formatting inside SQLite.

     - Parameters:
       - statement: SQLite statement positioned on the current row.
       - columnIndex: Result-column index that holds the blob.
       - table: Table name used for error reporting.
       - column: Column name used for error reporting.
       - allowNull: Whether SQLite null should be returned as `nil` instead of throwing.
     - Returns: Converted UUID, or `nil` when `allowNull` is true and the SQLite value is null.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidIdentifierBlob` when the blob is absent unexpectedly, not 16 bytes, or not convertible into `UUID`
     */
    private func uuidFromBlob(
        statement: OpaquePointer,
        columnIndex: Int32,
        table: String,
        column: String,
        allowNull: Bool
    ) throws -> UUID? {
        if sqlite3_column_type(statement, columnIndex) == SQLITE_NULL {
            if allowNull {
                return nil
            }
            throw RemoteSyncWorkspaceRestoreError.invalidIdentifierBlob(table: table, column: column)
        }

        let length = sqlite3_column_bytes(statement, columnIndex)
        guard length == 16, let rawBytes = sqlite3_column_blob(statement, columnIndex) else {
            throw RemoteSyncWorkspaceRestoreError.invalidIdentifierBlob(table: table, column: column)
        }

        let data = Data(bytes: rawBytes, count: Int(length))
        guard data.count == 16 else {
            throw RemoteSyncWorkspaceRestoreError.invalidIdentifierBlob(table: table, column: column)
        }

        let uuid = data.withUnsafeBytes { bytes -> UUID? in
            guard bytes.count == 16 else { return nil }
            let tuple = (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
            return UUID(uuid: tuple)
        }

        guard let uuid else {
            throw RemoteSyncWorkspaceRestoreError.invalidIdentifierBlob(table: table, column: column)
        }
        return uuid
    }

    /**
     Converts one preserved Android `LogEntry` identifier component into a UUID.

     Workspace patch tables all use one UUID-like primary-key column, so patch replay only needs the
     first identifier component for row lookup. The second component is still preserved verbatim in
     `RemoteSyncLogEntryStore` for Android parity, but it is not interpreted here.

     - Parameters:
       - value: Typed SQLite value preserved from Android `LogEntry.entityId1`.
       - tableName: Android table name used for diagnostics.
       - field: Log-entry field name used for diagnostics.
     - Returns: UUID extracted from the staged log-entry identifier.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchApplyError.invalidLogEntryIdentifier` when the payload is not a UUID-shaped blob or text value
     */
    private func uuid(from value: RemoteSyncSQLiteValue, tableName: String, field: String) throws -> UUID {
        switch value.kind {
        case .blob:
            guard let data = value.blobData,
                  let uuid = try? uuidFromData(data, table: tableName, name: field) else {
                throw RemoteSyncWorkspacePatchApplyError.invalidLogEntryIdentifier(table: tableName, field: field)
            }
            return uuid
        case .text:
            guard let textValue = value.textValue,
                  let uuid = UUID(uuidString: textValue) else {
                throw RemoteSyncWorkspacePatchApplyError.invalidLogEntryIdentifier(table: tableName, field: field)
            }
            return uuid
        default:
            throw RemoteSyncWorkspacePatchApplyError.invalidLogEntryIdentifier(table: tableName, field: field)
        }
    }

    /**
     Normalizes one local page-manager category key back into Android's raw enum-style string.

     - Parameter localValue: Lower-case iOS page-manager key.
     - Returns: Android raw category name suitable for `RemoteSyncAndroidWorkspacePageManager`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func remoteCurrentCategoryName(from localValue: String) -> String {
        switch localValue.lowercased() {
        case "bible":
            return "BIBLE"
        case "commentary":
            return "COMMENTARY"
        case "dictionary":
            return "DICTIONARY"
        case "general_book":
            return "GENERAL_BOOK"
        case "map":
            return "MAPS"
        default:
            return localValue.uppercased()
        }
    }

    /**
     Opens one staged SQLite database, passes the handle to the supplied closure, and closes it afterward.

     - Parameters:
       - databaseURL: Local SQLite database URL.
       - work: Closure that needs one open SQLite handle.
     - Returns: Value produced by `work`.
     - Side effects:
       - opens the staged database in read-only mode for the duration of `work`
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase` when the file cannot be opened as SQLite
       - rethrows any error produced by `work`
     */
    private func withSQLiteDatabase<T>(at databaseURL: URL, work: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }
        return try work(database)
    }

    /**
     Builds one temporary database URL beneath the configured scratch directory.

     - Parameters:
       - prefix: Filename prefix describing the temporary file purpose.
       - suffix: Filename suffix including the file extension.
     - Returns: Unique temporary-file URL beneath the configured scratch directory.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func temporaryDatabaseURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    /**
     Sorts preserved Android `LogEntry` rows deterministically before writing them back to settings.

     - Parameters:
       - lhs: Left-hand log-entry value.
       - rhs: Right-hand log-entry value.
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
        let lhsID1 = sqliteValueSortKey(lhs.entityID1)
        let rhsID1 = sqliteValueSortKey(rhs.entityID1)
        if lhsID1 != rhsID1 {
            return lhsID1 < rhsID1
        }
        let lhsID2 = sqliteValueSortKey(lhs.entityID2)
        let rhsID2 = sqliteValueSortKey(rhs.entityID2)
        if lhsID2 != rhsID2 {
            return lhsID2 < rhsID2
        }
        if lhs.type.rawValue != rhs.type.rawValue {
            return lhs.type.rawValue < rhs.type.rawValue
        }
        return lhs.sourceDevice < rhs.sourceDevice
    }

    /**
     Converts one typed SQLite scalar into a deterministic string sort key.

     - Parameter value: Typed SQLite value used inside one preserved Android `LogEntry` row.
     - Returns: Stable lexical key suitable for deterministic sorting.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func sqliteValueSortKey(_ value: RemoteSyncSQLiteValue) -> String {
        switch value.kind {
        case .null:
            return "0:"
        case .integer:
            return "1:\(value.integerValue ?? 0)"
        case .real:
            return "2:\(value.realValue ?? 0)"
        case .text:
            let textValue = value.textValue ?? ""
            return "3:\(textValue)"
        case .blob:
            let blobValue = value.blobBase64Value ?? ""
            return "4:\(blobValue)"
        }
    }

    /**
     Decompresses one gzipped Android patch archive into raw SQLite bytes.

     - Parameter data: Gzipped patch archive payload.
     - Returns: Decompressed SQLite file bytes.
     - Side effects:
       - allocates and frees temporary native buffers through `CLibSword`
     - Failure modes:
       - throws `RemoteSyncArchiveStagingError.decompressionFailed` when the payload is not valid gzip data
     */
    private static func gunzip(_ data: Data) throws -> Data {
        let result = try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw RemoteSyncArchiveStagingError.decompressionFailed
            }

            var outputLength: UInt = 0
            guard let outputPointer = gunzip_data(
                baseAddress,
                UInt(data.count),
                &outputLength
            ) else {
                throw RemoteSyncArchiveStagingError.decompressionFailed
            }

            defer { gunzip_free(outputPointer) }
            return Data(bytes: outputPointer, count: Int(outputLength))
        }
        guard !result.isEmpty else {
            throw RemoteSyncArchiveStagingError.decompressionFailed
        }
        return result
    }

    /**
     Converts one raw Android identifier blob into a Swift `UUID`.

     - Parameters:
       - data: Raw 16-byte Android identifier blob.
       - table: Table name used for diagnostics.
       - name: Column or field name used for diagnostics.
     - Returns: Decoded UUID value.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidIdentifierBlob` when the payload does not produce a valid UUID string
     */
    private func uuidFromData(_ data: Data, table: String, name: String) throws -> UUID {
        guard data.count == 16 else {
            throw RemoteSyncWorkspaceRestoreError.invalidIdentifierBlob(table: table, column: name)
        }
        let uuid = data.withUnsafeBytes { bytes -> UUID? in
            guard bytes.count == 16 else { return nil }
            let tuple = (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
            return UUID(uuid: tuple)
        }
        guard let uuid else {
            throw RemoteSyncWorkspaceRestoreError.invalidIdentifierBlob(table: table, column: name)
        }
        return uuid
    }

    /**
     Binds one UUID as Android's raw 16-byte blob format.

     - Parameters:
       - uuid: UUID value that should be encoded as 16 raw bytes.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind index.
     - Side effects:
       - mutates the bind state of the supplied SQLite statement
     - Failure modes: This helper cannot fail.
     */
    private func bindUUIDBlob(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
        var uuidValue = uuid.uuid
        _ = withUnsafeBytes(of: &uuidValue) { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, 16, remoteSyncWorkspacePatchSQLiteTransient)
        }
    }
}
