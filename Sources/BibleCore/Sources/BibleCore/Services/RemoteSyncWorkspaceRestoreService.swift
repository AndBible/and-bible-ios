// RemoteSyncWorkspaceRestoreService.swift — Workspace-category initial-backup restore from Android sync databases

import Foundation
import SQLite3
import SwiftData

/// SQLite transient destructor used when binding Swift-owned strings in metadata queries.
private let remoteSyncWorkspaceSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while reading or restoring Android workspace sync databases.
 */
public enum RemoteSyncWorkspaceRestoreError: Error, Equatable {
    /// The staged file could not be opened as a readable SQLite database.
    case invalidSQLiteDatabase

    /// The staged database does not contain one of the required Android workspace tables.
    case missingTable(String)

    /// One Android UUID-like blob could not be converted into an iOS `UUID`.
    case invalidIdentifierBlob(table: String, column: String)

    /// One required staged column was missing or contained an unusable value.
    case invalidColumnValue(table: String, column: String)

    /// One serialized Android JSON payload could not be decoded safely.
    case malformedSerializedValue(table: String, column: String)

    /// One or more staged rows referenced missing parent or sibling records.
    case orphanReferences([String])
}

/**
 One Android `HistoryItem` row from a staged workspace sync backup.

 Android history rows use auto-generated integer identifiers. iOS does not preserve those IDs in its
 SwiftData model, so restore later emits alias rows through `RemoteSyncWorkspaceFidelityStore`.
 */
public struct RemoteSyncAndroidWorkspaceHistoryItem: Sendable, Equatable {
    /// Android `HistoryItem.id` primary-key value.
    public let remoteID: Int64

    /// Identifier of the owning Android window row.
    public let windowID: UUID

    /// Timestamp captured when Android inserted the history row.
    public let createdAt: Date

    /// Module initials stored in the history row.
    public let document: String

    /// Persisted key or reference stored in the history row.
    public let key: String

    /// Optional Android anchor ordinal for precise reopen behavior.
    public let anchorOrdinal: Int?

    /**
     Creates one staged Android workspace history item.

     - Parameters:
       - remoteID: Android `HistoryItem.id` primary-key value.
       - windowID: Identifier of the owning Android window row.
       - createdAt: Timestamp captured when Android inserted the history row.
       - document: Module initials stored in the history row.
       - key: Persisted key or reference stored in the history row.
       - anchorOrdinal: Optional Android anchor ordinal for precise reopen behavior.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        remoteID: Int64,
        windowID: UUID,
        createdAt: Date,
        document: String,
        key: String,
        anchorOrdinal: Int?
    ) {
        self.remoteID = remoteID
        self.windowID = windowID
        self.createdAt = createdAt
        self.document = document
        self.key = key
        self.anchorOrdinal = anchorOrdinal
    }
}

/**
 One Android `PageManager` row from a staged workspace sync backup.

 The payload preserves Android's raw active category name and Android-only per-category metadata so
 the restore layer can normalize what iOS needs while still preserving the original values locally.
 */
public struct RemoteSyncAndroidWorkspacePageManager: Sendable, Equatable {
    /// Identifier shared with the owning Android window row.
    public let windowID: UUID

    /// Android Bible module initials.
    public let bibleDocument: String?

    /// Android Bible versification name.
    public let bibleVersification: String?

    /// Android persisted Bible book index.
    public let bibleBook: Int?

    /// Android persisted Bible chapter number.
    public let bibleChapterNo: Int?

    /// Android persisted Bible verse number.
    public let bibleVerseNo: Int?

    /// Android commentary module initials.
    public let commentaryDocument: String?

    /// Android commentary anchor ordinal.
    public let commentaryAnchorOrdinal: Int?

    /// Android commentary source-book-and-key payload.
    public let commentarySourceBookAndKey: String?

    /// Android dictionary module initials.
    public let dictionaryDocument: String?

    /// Android dictionary key/headword.
    public let dictionaryKey: String?

    /// Android dictionary anchor ordinal.
    public let dictionaryAnchorOrdinal: Int?

    /// Android general-book module initials.
    public let generalBookDocument: String?

    /// Android general-book key.
    public let generalBookKey: String?

    /// Android general-book anchor ordinal.
    public let generalBookAnchorOrdinal: Int?

    /// Android map module initials.
    public let mapDocument: String?

    /// Android map key.
    public let mapKey: String?

    /// Android map anchor ordinal.
    public let mapAnchorOrdinal: Int?

    /// Raw Android `currentCategoryName` string.
    public let currentCategoryName: String

    /// Optional Android per-window text display overrides.
    public let textDisplaySettings: TextDisplaySettings?

    /// Raw Android serialized JS state blob.
    public let jsState: String?

    /**
     Creates one staged Android workspace page-manager row.

     - Parameters:
       - windowID: Identifier shared with the owning Android window row.
       - bibleDocument: Android Bible module initials.
       - bibleVersification: Android Bible versification name.
       - bibleBook: Android persisted Bible book index.
       - bibleChapterNo: Android persisted Bible chapter number.
       - bibleVerseNo: Android persisted Bible verse number.
       - commentaryDocument: Android commentary module initials.
       - commentaryAnchorOrdinal: Android commentary anchor ordinal.
       - commentarySourceBookAndKey: Android commentary source-book-and-key payload.
       - dictionaryDocument: Android dictionary module initials.
       - dictionaryKey: Android dictionary key/headword.
       - dictionaryAnchorOrdinal: Android dictionary anchor ordinal.
       - generalBookDocument: Android general-book module initials.
       - generalBookKey: Android general-book key.
       - generalBookAnchorOrdinal: Android general-book anchor ordinal.
       - mapDocument: Android map module initials.
       - mapKey: Android map key.
       - mapAnchorOrdinal: Android map anchor ordinal.
       - currentCategoryName: Raw Android `currentCategoryName` string.
       - textDisplaySettings: Optional Android per-window text display overrides.
       - jsState: Raw Android serialized JS state blob.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        windowID: UUID,
        bibleDocument: String?,
        bibleVersification: String?,
        bibleBook: Int?,
        bibleChapterNo: Int?,
        bibleVerseNo: Int?,
        commentaryDocument: String?,
        commentaryAnchorOrdinal: Int?,
        commentarySourceBookAndKey: String?,
        dictionaryDocument: String?,
        dictionaryKey: String?,
        dictionaryAnchorOrdinal: Int?,
        generalBookDocument: String?,
        generalBookKey: String?,
        generalBookAnchorOrdinal: Int?,
        mapDocument: String?,
        mapKey: String?,
        mapAnchorOrdinal: Int?,
        currentCategoryName: String,
        textDisplaySettings: TextDisplaySettings?,
        jsState: String?
    ) {
        self.windowID = windowID
        self.bibleDocument = bibleDocument
        self.bibleVersification = bibleVersification
        self.bibleBook = bibleBook
        self.bibleChapterNo = bibleChapterNo
        self.bibleVerseNo = bibleVerseNo
        self.commentaryDocument = commentaryDocument
        self.commentaryAnchorOrdinal = commentaryAnchorOrdinal
        self.commentarySourceBookAndKey = commentarySourceBookAndKey
        self.dictionaryDocument = dictionaryDocument
        self.dictionaryKey = dictionaryKey
        self.dictionaryAnchorOrdinal = dictionaryAnchorOrdinal
        self.generalBookDocument = generalBookDocument
        self.generalBookKey = generalBookKey
        self.generalBookAnchorOrdinal = generalBookAnchorOrdinal
        self.mapDocument = mapDocument
        self.mapKey = mapKey
        self.mapAnchorOrdinal = mapAnchorOrdinal
        self.currentCategoryName = currentCategoryName
        self.textDisplaySettings = textDisplaySettings
        self.jsState = jsState
    }
}

/**
 One Android `Window` row plus its page-manager and history children.
 */
public struct RemoteSyncAndroidWorkspaceWindow: Sendable, Equatable {
    /// Android window identifier converted into iOS UUID form.
    public let id: UUID

    /// Identifier of the owning Android workspace row.
    public let workspaceID: UUID

    /// Whether Android marked the window as synchronized.
    public let isSynchronized: Bool

    /// Whether Android marked the window as pinned.
    public let isPinMode: Bool

    /// Whether Android marked the window as a links window.
    public let isLinksWindow: Bool

    /// Display order within the owning workspace.
    public let orderNumber: Int

    /// Optional sibling links-target window identifier.
    public let targetLinksWindowID: UUID?

    /// Android sync-group number.
    public let syncGroup: Int

    /// Android window-layout state string.
    public let layoutState: String

    /// Android window-layout weight.
    public let layoutWeight: Float

    /// Android page-manager row linked 1:1 to this window.
    public let pageManager: RemoteSyncAndroidWorkspacePageManager

    /// Android history rows linked to this window.
    public let historyItems: [RemoteSyncAndroidWorkspaceHistoryItem]

    /**
     Creates one staged Android workspace window.

     - Parameters:
       - id: Android window identifier converted into iOS UUID form.
       - workspaceID: Identifier of the owning Android workspace row.
       - isSynchronized: Whether Android marked the window as synchronized.
       - isPinMode: Whether Android marked the window as pinned.
       - isLinksWindow: Whether Android marked the window as a links window.
       - orderNumber: Display order within the owning workspace.
       - targetLinksWindowID: Optional sibling links-target window identifier.
       - syncGroup: Android sync-group number.
       - layoutState: Android window-layout state string.
       - layoutWeight: Android window-layout weight.
       - pageManager: Android page-manager row linked 1:1 to this window.
       - historyItems: Android history rows linked to this window.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        id: UUID,
        workspaceID: UUID,
        isSynchronized: Bool,
        isPinMode: Bool,
        isLinksWindow: Bool,
        orderNumber: Int,
        targetLinksWindowID: UUID?,
        syncGroup: Int,
        layoutState: String,
        layoutWeight: Float,
        pageManager: RemoteSyncAndroidWorkspacePageManager,
        historyItems: [RemoteSyncAndroidWorkspaceHistoryItem]
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.isSynchronized = isSynchronized
        self.isPinMode = isPinMode
        self.isLinksWindow = isLinksWindow
        self.orderNumber = orderNumber
        self.targetLinksWindowID = targetLinksWindowID
        self.syncGroup = syncGroup
        self.layoutState = layoutState
        self.layoutWeight = layoutWeight
        self.pageManager = pageManager
        self.historyItems = historyItems
    }
}

/**
 One Android `Workspace` row plus its child window graph.
 */
public struct RemoteSyncAndroidWorkspace: Sendable {
    /// Android workspace identifier converted into iOS UUID form.
    public let id: UUID

    /// Android workspace name.
    public let name: String

    /// Optional Android contents summary text.
    public let contentsText: String?

    /// Android display order among workspaces.
    public let orderNumber: Int

    /// Optional Android workspace-level text display overrides.
    public let textDisplaySettings: TextDisplaySettings?

    /// Android workspace-scoped behavior settings projected into iOS form.
    public let workspaceSettings: WorkspaceSettings

    /// Raw Android `WorkspaceSettings.speakSettings` JSON payload when present.
    public let speakSettingsJSON: String?

    /// Optional Android unpinned layout weight.
    public let unPinnedWeight: Float?

    /// Optional Android maximized-window identifier.
    public let maximizedWindowID: UUID?

    /// Optional Android primary links-target window identifier.
    public let primaryTargetLinksWindowID: UUID?

    /// Optional Android workspace color.
    public let workspaceColor: Int?

    /// Android child windows sorted into display order.
    public let windows: [RemoteSyncAndroidWorkspaceWindow]

    /**
     Creates one staged Android workspace.

     - Parameters:
       - id: Android workspace identifier converted into iOS UUID form.
       - name: Android workspace name.
       - contentsText: Optional Android contents summary text.
       - orderNumber: Android display order among workspaces.
       - textDisplaySettings: Optional Android workspace-level text display overrides.
       - workspaceSettings: Android workspace-scoped behavior settings projected into iOS form.
       - speakSettingsJSON: Raw Android `WorkspaceSettings.speakSettings` JSON payload.
       - unPinnedWeight: Optional Android unpinned layout weight.
       - maximizedWindowID: Optional Android maximized-window identifier.
       - primaryTargetLinksWindowID: Optional Android primary links-target window identifier.
       - workspaceColor: Optional Android workspace color.
       - windows: Android child windows sorted into display order.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        id: UUID,
        name: String,
        contentsText: String?,
        orderNumber: Int,
        textDisplaySettings: TextDisplaySettings?,
        workspaceSettings: WorkspaceSettings,
        speakSettingsJSON: String?,
        unPinnedWeight: Float?,
        maximizedWindowID: UUID?,
        primaryTargetLinksWindowID: UUID?,
        workspaceColor: Int?,
        windows: [RemoteSyncAndroidWorkspaceWindow]
    ) {
        self.id = id
        self.name = name
        self.contentsText = contentsText
        self.orderNumber = orderNumber
        self.textDisplaySettings = textDisplaySettings
        self.workspaceSettings = workspaceSettings
        self.speakSettingsJSON = speakSettingsJSON
        self.unPinnedWeight = unPinnedWeight
        self.maximizedWindowID = maximizedWindowID
        self.primaryTargetLinksWindowID = primaryTargetLinksWindowID
        self.workspaceColor = workspaceColor
        self.windows = windows
    }
}

/**
 Read-only snapshot of one staged Android workspace sync database.

 The snapshot preserves Android workspace rows, windows, page managers, and history rows as typed
 value objects while keeping Android-only fields available for later fidelity storage.
 */
public struct RemoteSyncAndroidWorkspaceSnapshot: Sendable {
    /// Staged Android workspaces sorted by display order.
    public let workspaces: [RemoteSyncAndroidWorkspace]

    /**
     Creates a staged Android workspace snapshot.

     - Parameter workspaces: Staged Android workspaces sorted by display order.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(workspaces: [RemoteSyncAndroidWorkspace]) {
        self.workspaces = workspaces
    }
}

/**
 Summary of one successful Android workspace restore.
 */
public struct RemoteSyncWorkspaceRestoreReport: Sendable, Equatable {
    /// Number of workspace rows restored into SwiftData.
    public let restoredWorkspaceCount: Int

    /// Number of window/page-manager pairs restored into SwiftData.
    public let restoredWindowCount: Int

    /// Number of history rows restored into SwiftData.
    public let restoredHistoryItemCount: Int

    /// Number of raw Android workspace fidelity payloads preserved locally.
    public let preservedWorkspaceFidelityCount: Int

    /// Number of Android page-manager fidelity payloads preserved locally.
    public let preservedPageManagerFidelityCount: Int

    /// Number of Android-to-iOS history-item identifier aliases preserved locally.
    public let preservedHistoryItemAliasCount: Int

    /**
     Creates one workspace restore summary.

     - Parameters:
       - restoredWorkspaceCount: Number of workspace rows restored into SwiftData.
       - restoredWindowCount: Number of window/page-manager pairs restored into SwiftData.
       - restoredHistoryItemCount: Number of history rows restored into SwiftData.
       - preservedWorkspaceFidelityCount: Number of raw Android workspace fidelity payloads preserved locally.
       - preservedPageManagerFidelityCount: Number of Android page-manager fidelity payloads preserved locally.
       - preservedHistoryItemAliasCount: Number of Android-to-iOS history-item identifier aliases preserved locally.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        restoredWorkspaceCount: Int,
        restoredWindowCount: Int,
        restoredHistoryItemCount: Int,
        preservedWorkspaceFidelityCount: Int,
        preservedPageManagerFidelityCount: Int,
        preservedHistoryItemAliasCount: Int
    ) {
        self.restoredWorkspaceCount = restoredWorkspaceCount
        self.restoredWindowCount = restoredWindowCount
        self.restoredHistoryItemCount = restoredHistoryItemCount
        self.preservedWorkspaceFidelityCount = preservedWorkspaceFidelityCount
        self.preservedPageManagerFidelityCount = preservedPageManagerFidelityCount
        self.preservedHistoryItemAliasCount = preservedHistoryItemAliasCount
    }
}

/**
 Reads staged Android workspace databases and restores them into iOS SwiftData.

 Android persists workspace layout as a graph of `Workspace`, `Window`, `PageManager`, and
 `HistoryItem` tables. iOS stores the same high-level concepts, but the schemas are not identical:
 - Android uses enum-like `currentCategoryName` strings while iOS persists lower-case page-manager
   keys
 - Android stores additional page-manager anchor/source fields that iOS does not model directly
 - Android uses integer primary keys for `HistoryItem`, while iOS uses UUIDs
 - Android stores raw workspace `speakSettings` JSON that iOS does not model yet

 This restore service replaces the entire local workspace graph from one staged Android backup and
 preserves the non-isomorphic Android fields locally through `RemoteSyncWorkspaceFidelityStore`.

 Data dependencies:
 - staged SQLite backups are read directly from Android's workspace-category tables
 - `SettingsStore` is used indirectly through `RemoteSyncWorkspaceFidelityStore`

 Side effects:
 - `replaceLocalWorkspaces(from:modelContext:settingsStore:)` deletes and recreates the local
   workspace/window/page-manager/history graph
 - successful restores clear and repopulate Android-only workspace fidelity rows in local settings
 - successful restores repair `SettingsStore.activeWorkspaceId` to point at a restored workspace
   when possible

 Failure modes:
 - staged snapshot parsing fails explicitly when required tables are missing, required columns are
   unusable, serialized JSON payloads are malformed, or foreign-key-like references are broken
 - restore rethrows `ModelContext.save()` failures after mutating the in-memory SwiftData graph
 - local-only fidelity storage inherits `SettingsStore`'s soft-fail semantics

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement of the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncWorkspaceRestoreService {
    private struct RawWorkspaceRow {
        let id: UUID
        let name: String
        let contentsText: String?
        let orderNumber: Int
        let textDisplaySettings: TextDisplaySettings?
        let workspaceSettings: WorkspaceSettings
        let speakSettingsJSON: String?
        let unPinnedWeight: Float?
        let maximizedWindowID: UUID?
        let primaryTargetLinksWindowID: UUID?
        let workspaceColor: Int?
    }

    private struct RawWindowRow {
        let id: UUID
        let workspaceID: UUID
        let isSynchronized: Bool
        let isPinMode: Bool
        let isLinksWindow: Bool
        let orderNumber: Int
        let targetLinksWindowID: UUID?
        let syncGroup: Int
        let layoutState: String
        let layoutWeight: Float
    }

    private struct RawPageManagerRow {
        let windowID: UUID
        let bibleDocument: String?
        let bibleVersification: String?
        let bibleBook: Int?
        let bibleChapterNo: Int?
        let bibleVerseNo: Int?
        let commentaryDocument: String?
        let commentaryAnchorOrdinal: Int?
        let commentarySourceBookAndKey: String?
        let dictionaryDocument: String?
        let dictionaryKey: String?
        let dictionaryAnchorOrdinal: Int?
        let generalBookDocument: String?
        let generalBookKey: String?
        let generalBookAnchorOrdinal: Int?
        let mapDocument: String?
        let mapKey: String?
        let mapAnchorOrdinal: Int?
        let currentCategoryName: String
        let textDisplaySettings: TextDisplaySettings?
        let jsState: String?
    }

    private struct AndroidRecentLabelPayload: Decodable {
        let labelId: String
        let lastAccess: Int64
    }

    private let decoder = JSONDecoder()

    /**
     Creates a workspace restore service.

     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init() {}

    /**
     Reads one staged Android workspace SQLite database into a typed snapshot.

     - Parameter databaseURL: Local URL of the extracted Android `workspaces.sqlite3` backup.
     - Returns: Typed snapshot of staged workspaces, windows, page managers, and history rows.
     - Side effects:
       - opens the staged SQLite database in read-only mode
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase` when the file cannot be opened as SQLite
       - throws `RemoteSyncWorkspaceRestoreError.missingTable` when required Android tables are absent
       - throws `RemoteSyncWorkspaceRestoreError.invalidIdentifierBlob` when Android UUID-like BLOB columns cannot be converted into `UUID`
       - throws `RemoteSyncWorkspaceRestoreError.invalidColumnValue` when required staged values are missing or unusable
       - throws `RemoteSyncWorkspaceRestoreError.malformedSerializedValue` when one serialized Android JSON payload cannot be decoded safely
       - throws `RemoteSyncWorkspaceRestoreError.orphanReferences` when staged rows reference missing parent or sibling records
     */
    public func readSnapshot(from databaseURL: URL) throws -> RemoteSyncAndroidWorkspaceSnapshot {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(db) }

        for tableName in ["Workspace", "Window", "PageManager", "HistoryItem"] {
            try requireTable(named: tableName, in: db)
        }

        let workspaces = try fetchWorkspaces(from: db)
        let windows = try fetchWindows(from: db)
        let pageManagers = try fetchPageManagers(from: db)
        let historyItems = try fetchHistoryItems(from: db)

        return try buildSnapshot(
            workspaces: workspaces,
            windows: windows,
            pageManagers: pageManagers,
            historyItems: historyItems
        )
    }

    /**
     Replaces local iOS workspaces with the supplied staged Android snapshot.

     The restore is category-wide and all-or-nothing at the persistence level. Existing local
     workspaces are deleted first, then the restored workspace/window/page-manager/history graph is
     inserted and saved, and only after that succeeds are Android-only fidelity rows repopulated in
     local settings.

     - Parameters:
       - snapshot: Staged Android snapshot previously read from `readSnapshot(from:)`.
       - modelContext: SwiftData context whose workspace graph should be replaced.
       - settingsStore: Local-only settings store used for fidelity preservation and active-workspace repair.
     - Returns: Summary of restored rows and preserved Android-only fidelity payloads.
     - Side effects:
       - deletes existing local `Workspace` graphs
       - inserts replacement `Workspace`, `Window`, `PageManager`, and `HistoryItem` rows
       - clears and repopulates Android-only fidelity rows in local settings
       - rewrites `SettingsStore.activeWorkspaceId`
       - saves `modelContext`
     - Failure modes:
       - rethrows SwiftData save errors from `modelContext.save()`
     */
    public func replaceLocalWorkspaces(
        from snapshot: RemoteSyncAndroidWorkspaceSnapshot,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncWorkspaceRestoreReport {
        let previousActiveWorkspaceID = settingsStore.activeWorkspaceId
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)

        let existingWorkspaces = (try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? []
        for workspace in existingWorkspaces {
            modelContext.delete(workspace)
        }
        try modelContext.save()

        var restoredWorkspaceCount = 0
        var restoredWindowCount = 0
        var restoredHistoryItemCount = 0
        var preservedWorkspaceFidelityCount = 0
        var preservedPageManagerFidelityCount = 0
        var historyAliases: [RemoteSyncWorkspaceFidelityStore.HistoryItemAlias] = []
        var restoredWorkspaceIDs: [UUID] = []

        for workspaceSnapshot in snapshot.workspaces {
            let workspace = Workspace(
                id: workspaceSnapshot.id,
                name: workspaceSnapshot.name,
                orderNumber: workspaceSnapshot.orderNumber
            )
            workspace.contentsText = workspaceSnapshot.contentsText
            workspace.textDisplaySettings = workspaceSnapshot.textDisplaySettings
            workspace.workspaceSettings = workspaceSnapshot.workspaceSettings
            workspace.unPinnedWeight = workspaceSnapshot.unPinnedWeight
            workspace.maximizedWindowId = workspaceSnapshot.maximizedWindowID
            workspace.primaryTargetLinksWindowId = workspaceSnapshot.primaryTargetLinksWindowID
            workspace.workspaceColor = workspaceSnapshot.workspaceColor
            modelContext.insert(workspace)

            restoredWorkspaceCount += 1
            restoredWorkspaceIDs.append(workspace.id)

            for windowSnapshot in workspaceSnapshot.windows {
                let window = Window(
                    id: windowSnapshot.id,
                    isSynchronized: windowSnapshot.isSynchronized,
                    isPinMode: windowSnapshot.isPinMode,
                    isLinksWindow: windowSnapshot.isLinksWindow,
                    orderNumber: windowSnapshot.orderNumber,
                    syncGroup: windowSnapshot.syncGroup,
                    layoutWeight: windowSnapshot.layoutWeight,
                    layoutState: windowSnapshot.layoutState
                )
                window.workspace = workspace
                window.targetLinksWindowId = windowSnapshot.targetLinksWindowID
                modelContext.insert(window)
                restoredWindowCount += 1

                let pageManager = PageManager(
                    id: windowSnapshot.pageManager.windowID,
                    currentCategoryName: Self.normalizedCurrentCategoryName(
                        from: windowSnapshot.pageManager.currentCategoryName
                    )
                )
                pageManager.window = window
                pageManager.bibleDocument = windowSnapshot.pageManager.bibleDocument
                pageManager.bibleVersification = windowSnapshot.pageManager.bibleVersification
                pageManager.bibleBibleBook = windowSnapshot.pageManager.bibleBook
                pageManager.bibleChapterNo = windowSnapshot.pageManager.bibleChapterNo
                pageManager.bibleVerseNo = windowSnapshot.pageManager.bibleVerseNo
                pageManager.commentaryDocument = windowSnapshot.pageManager.commentaryDocument
                pageManager.commentaryAnchorOrdinal = windowSnapshot.pageManager.commentaryAnchorOrdinal
                pageManager.dictionaryDocument = windowSnapshot.pageManager.dictionaryDocument
                pageManager.dictionaryKey = windowSnapshot.pageManager.dictionaryKey
                pageManager.generalBookDocument = windowSnapshot.pageManager.generalBookDocument
                pageManager.generalBookKey = windowSnapshot.pageManager.generalBookKey
                pageManager.mapDocument = windowSnapshot.pageManager.mapDocument
                pageManager.mapKey = windowSnapshot.pageManager.mapKey
                pageManager.textDisplaySettings = windowSnapshot.pageManager.textDisplaySettings
                pageManager.jsState = windowSnapshot.pageManager.jsState
                modelContext.insert(pageManager)

                for historySnapshot in windowSnapshot.historyItems {
                    let historyItem = HistoryItem(
                        id: UUID(),
                        createdAt: historySnapshot.createdAt,
                        document: historySnapshot.document,
                        key: historySnapshot.key
                    )
                    historyItem.window = window
                    historyItem.anchorOrdinal = historySnapshot.anchorOrdinal
                    modelContext.insert(historyItem)
                    restoredHistoryItemCount += 1
                    historyAliases.append(
                        .init(
                            remoteHistoryItemID: historySnapshot.remoteID,
                            localHistoryItemID: historyItem.id
                        )
                    )
                }
            }
        }

        try modelContext.save()

        fidelityStore.clearAll()

        for workspaceSnapshot in snapshot.workspaces {
            if let speakSettingsJSON = workspaceSnapshot.speakSettingsJSON, !speakSettingsJSON.isEmpty {
                fidelityStore.setSpeakSettingsJSON(speakSettingsJSON, for: workspaceSnapshot.id)
                preservedWorkspaceFidelityCount += 1
            }

            for windowSnapshot in workspaceSnapshot.windows {
                fidelityStore.setPageManagerEntry(
                    .init(
                        windowID: windowSnapshot.id,
                        rawCurrentCategoryName: windowSnapshot.pageManager.currentCategoryName,
                        commentarySourceBookAndKey: windowSnapshot.pageManager.commentarySourceBookAndKey,
                        dictionaryAnchorOrdinal: windowSnapshot.pageManager.dictionaryAnchorOrdinal,
                        generalBookAnchorOrdinal: windowSnapshot.pageManager.generalBookAnchorOrdinal,
                        mapAnchorOrdinal: windowSnapshot.pageManager.mapAnchorOrdinal
                    )
                )
                preservedPageManagerFidelityCount += 1
            }
        }

        for alias in historyAliases {
            fidelityStore.setHistoryItemAlias(
                remoteHistoryItemID: alias.remoteHistoryItemID,
                localHistoryItemID: alias.localHistoryItemID
            )
        }

        let preferredActiveWorkspaceID: UUID?
        if let previousActiveWorkspaceID, restoredWorkspaceIDs.contains(previousActiveWorkspaceID) {
            preferredActiveWorkspaceID = previousActiveWorkspaceID
        } else {
            preferredActiveWorkspaceID = snapshot.workspaces.first?.id
        }
        settingsStore.activeWorkspaceId = preferredActiveWorkspaceID

        return RemoteSyncWorkspaceRestoreReport(
            restoredWorkspaceCount: restoredWorkspaceCount,
            restoredWindowCount: restoredWindowCount,
            restoredHistoryItemCount: restoredHistoryItemCount,
            preservedWorkspaceFidelityCount: preservedWorkspaceFidelityCount,
            preservedPageManagerFidelityCount: preservedPageManagerFidelityCount,
            preservedHistoryItemAliasCount: historyAliases.count
        )
    }

    /**
     Validates parent/sibling references and assembles the flat staged rows into a hierarchical snapshot.

     - Parameters:
       - workspaces: Flat Android workspace rows.
       - windows: Flat Android window rows.
       - pageManagers: Flat Android page-manager rows.
       - historyItems: Flat Android history rows.
     - Returns: Hierarchical workspace snapshot sorted into deterministic display order.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.orphanReferences` when any row references a missing parent or sibling record
     */
    private func buildSnapshot(
        workspaces: [RawWorkspaceRow],
        windows: [RawWindowRow],
        pageManagers: [RawPageManagerRow],
        historyItems: [RemoteSyncAndroidWorkspaceHistoryItem]
    ) throws -> RemoteSyncAndroidWorkspaceSnapshot {
        let workspacesByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let pageManagersByWindowID = Dictionary(
            uniqueKeysWithValues: pageManagers.map { row in
                (
                    row.windowID,
                    RemoteSyncAndroidWorkspacePageManager(
                        windowID: row.windowID,
                        bibleDocument: row.bibleDocument,
                        bibleVersification: row.bibleVersification,
                        bibleBook: row.bibleBook,
                        bibleChapterNo: row.bibleChapterNo,
                        bibleVerseNo: row.bibleVerseNo,
                        commentaryDocument: row.commentaryDocument,
                        commentaryAnchorOrdinal: row.commentaryAnchorOrdinal,
                        commentarySourceBookAndKey: row.commentarySourceBookAndKey,
                        dictionaryDocument: row.dictionaryDocument,
                        dictionaryKey: row.dictionaryKey,
                        dictionaryAnchorOrdinal: row.dictionaryAnchorOrdinal,
                        generalBookDocument: row.generalBookDocument,
                        generalBookKey: row.generalBookKey,
                        generalBookAnchorOrdinal: row.generalBookAnchorOrdinal,
                        mapDocument: row.mapDocument,
                        mapKey: row.mapKey,
                        mapAnchorOrdinal: row.mapAnchorOrdinal,
                        currentCategoryName: row.currentCategoryName,
                        textDisplaySettings: row.textDisplaySettings,
                        jsState: row.jsState
                    )
                )
            }
        )
        let historyItemsByWindowID = Dictionary(grouping: historyItems, by: \.windowID)

        var orphanReferences: [String] = []

        for window in windows where workspacesByID[window.workspaceID] == nil {
            orphanReferences.append(
                "Window.id=\(window.id.uuidString) missing workspace \(window.workspaceID.uuidString)"
            )
        }

        for pageManager in pageManagers where windowsByID[pageManager.windowID] == nil {
            orphanReferences.append(
                "PageManager.windowId=\(pageManager.windowID.uuidString) missing window"
            )
        }

        for window in windows where pageManagersByWindowID[window.id] == nil {
            orphanReferences.append(
                "Window.id=\(window.id.uuidString) missing PageManager"
            )
        }

        for historyItem in historyItems where windowsByID[historyItem.windowID] == nil {
            orphanReferences.append(
                "HistoryItem.id=\(historyItem.remoteID) missing window \(historyItem.windowID.uuidString)"
            )
        }

        let windowsByWorkspaceID = Dictionary(grouping: windows, by: \.workspaceID)
        for workspace in workspaces {
            let siblingWindowIDs = Set(windowsByWorkspaceID[workspace.id, default: []].map(\.id))

            if let maximizedWindowID = workspace.maximizedWindowID,
               !siblingWindowIDs.contains(maximizedWindowID) {
                orphanReferences.append(
                    "Workspace.maximizedWindowId=\(maximizedWindowID.uuidString) missing window in workspace \(workspace.id.uuidString)"
                )
            }

            if let primaryTargetLinksWindowID = workspace.primaryTargetLinksWindowID,
               !siblingWindowIDs.contains(primaryTargetLinksWindowID) {
                orphanReferences.append(
                    "Workspace.primaryTargetLinksWindowId=\(primaryTargetLinksWindowID.uuidString) missing window in workspace \(workspace.id.uuidString)"
                )
            }
        }

        for window in windows {
            if let targetLinksWindowID = window.targetLinksWindowID {
                let siblingWindowIDs = Set(windowsByWorkspaceID[window.workspaceID, default: []].map(\.id))
                if !siblingWindowIDs.contains(targetLinksWindowID) {
                    orphanReferences.append(
                        "Window.targetLinksWindowId=\(targetLinksWindowID.uuidString) missing sibling window for window \(window.id.uuidString)"
                    )
                }
            }
        }

        if !orphanReferences.isEmpty {
            throw RemoteSyncWorkspaceRestoreError.orphanReferences(orphanReferences.sorted())
        }

        let assembledWorkspaces: [RemoteSyncAndroidWorkspace] = workspaces.map { workspaceRow in
            let assembledWindows = windowsByWorkspaceID[workspaceRow.id, default: []].map { windowRow in
                RemoteSyncAndroidWorkspaceWindow(
                    id: windowRow.id,
                    workspaceID: windowRow.workspaceID,
                    isSynchronized: windowRow.isSynchronized,
                    isPinMode: windowRow.isPinMode,
                    isLinksWindow: windowRow.isLinksWindow,
                    orderNumber: windowRow.orderNumber,
                    targetLinksWindowID: windowRow.targetLinksWindowID,
                    syncGroup: windowRow.syncGroup,
                    layoutState: windowRow.layoutState,
                    layoutWeight: windowRow.layoutWeight,
                    pageManager: pageManagersByWindowID[windowRow.id]!,
                    historyItems: historyItemsByWindowID[windowRow.id, default: []].sorted {
                        if $0.createdAt == $1.createdAt {
                            return $0.remoteID < $1.remoteID
                        }
                        return $0.createdAt < $1.createdAt
                    }
                )
            }
            .sorted { lhs, rhs in
                if lhs.orderNumber == rhs.orderNumber {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.orderNumber < rhs.orderNumber
            }

            return RemoteSyncAndroidWorkspace(
                id: workspaceRow.id,
                name: workspaceRow.name,
                contentsText: workspaceRow.contentsText,
                orderNumber: workspaceRow.orderNumber,
                textDisplaySettings: workspaceRow.textDisplaySettings,
                workspaceSettings: workspaceRow.workspaceSettings,
                speakSettingsJSON: workspaceRow.speakSettingsJSON,
                unPinnedWeight: workspaceRow.unPinnedWeight,
                maximizedWindowID: workspaceRow.maximizedWindowID,
                primaryTargetLinksWindowID: workspaceRow.primaryTargetLinksWindowID,
                workspaceColor: workspaceRow.workspaceColor,
                windows: assembledWindows
            )
        }
        .sorted { lhs, rhs in
            if lhs.orderNumber == rhs.orderNumber {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.orderNumber < rhs.orderNumber
        }

        return RemoteSyncAndroidWorkspaceSnapshot(workspaces: assembledWorkspaces)
    }

    /**
     Verifies that a required Android table exists in the staged database.

     - Parameters:
       - tableName: Required Android table name.
       - db: Open SQLite database handle.
     - Side effects:
       - prepares and steps a SQLite metadata query against `sqlite_master`
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase` when SQLite cannot prepare the metadata query
       - throws `RemoteSyncWorkspaceRestoreError.missingTable` when the required table is absent
     */
    private func requireTable(named tableName: String, in db: OpaquePointer) throws {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase
        }

        sqlite3_bind_text(statement, 1, tableName, -1, remoteSyncWorkspaceSQLiteTransient)
        let result = sqlite3_step(statement)
        if result != SQLITE_ROW {
            throw RemoteSyncWorkspaceRestoreError.missingTable(tableName)
        }
    }

    /**
     Reads staged Android workspace rows from the SQLite backup.

     - Parameter db: Open staged Android workspace database.
     - Returns: Flat staged workspace rows with decoded settings payloads.
     - Side effects:
       - prepares and steps a SQLite query against the `Workspace` table
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase` when SQLite cannot prepare the query
       - rethrows value-decoding errors for required columns, identifier blobs, or serialized JSON payloads
     */
    private func fetchWorkspaces(from db: OpaquePointer) throws -> [RawWorkspaceRow] {
        let sql = "SELECT * FROM Workspace"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        let columns = columnIndexMap(for: statement)
        var rows: [RawWorkspaceRow] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let decodedWorkspaceSettings = try decodeWorkspaceSettings(
                table: "Workspace",
                statement: statement,
                columns: columns
            )
            rows.append(
                RawWorkspaceRow(
                    id: try requiredUUIDBlobColumn(
                        "id",
                        table: "Workspace",
                        statement: statement,
                        columns: columns
                    ),
                    name: try requiredTextColumn(
                        "name",
                        table: "Workspace",
                        statement: statement,
                        columns: columns
                    ),
                    contentsText: try optionalTextColumn(
                        "contentsText",
                        table: "Workspace",
                        statement: statement,
                        columns: columns
                    ),
                    orderNumber: try requiredIntColumn(
                        "orderNumber",
                        table: "Workspace",
                        statement: statement,
                        columns: columns
                    ),
                    textDisplaySettings: try decodeTextDisplaySettings(
                        table: "Workspace",
                        statement: statement,
                        columns: columns,
                        prefix: "text_display_settings_"
                    ),
                    workspaceSettings: decodedWorkspaceSettings.settings,
                    speakSettingsJSON: decodedWorkspaceSettings.speakSettingsJSON,
                    unPinnedWeight: try optionalFloatColumn(
                        "unPinnedWeight",
                        table: "Workspace",
                        statement: statement,
                        columns: columns
                    ),
                    maximizedWindowID: try optionalUUIDBlobColumn(
                        "maximizedWindowId",
                        table: "Workspace",
                        statement: statement,
                        columns: columns
                    ),
                    primaryTargetLinksWindowID: try optionalUUIDBlobColumn(
                        "primaryTargetLinksWindowId",
                        table: "Workspace",
                        statement: statement,
                        columns: columns
                    ),
                    workspaceColor: decodedWorkspaceSettings.workspaceColor
                )
            )
        }

        return rows
    }

    /**
     Reads staged Android window rows from the SQLite backup.

     - Parameter db: Open staged Android workspace database.
     - Returns: Flat staged window rows.
     - Side effects:
       - prepares and steps a SQLite query against the `Window` table
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase` when SQLite cannot prepare the query
       - rethrows value-decoding errors for required columns or identifier blobs
     */
    private func fetchWindows(from db: OpaquePointer) throws -> [RawWindowRow] {
        let sql = "SELECT * FROM \"Window\""
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        let columns = columnIndexMap(for: statement)
        var rows: [RawWindowRow] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                RawWindowRow(
                    id: try requiredUUIDBlobColumn(
                        "id",
                        table: "Window",
                        statement: statement,
                        columns: columns
                    ),
                    workspaceID: try requiredUUIDBlobColumn(
                        "workspaceId",
                        table: "Window",
                        statement: statement,
                        columns: columns
                    ),
                    isSynchronized: try requiredBoolColumn(
                        "isSynchronized",
                        table: "Window",
                        statement: statement,
                        columns: columns
                    ),
                    isPinMode: try requiredBoolColumn(
                        "isPinMode",
                        table: "Window",
                        statement: statement,
                        columns: columns
                    ),
                    isLinksWindow: try boolColumn(
                        "isLinksWindow",
                        table: "Window",
                        statement: statement,
                        columns: columns,
                        default: false
                    ),
                    orderNumber: try requiredIntColumn(
                        "orderNumber",
                        table: "Window",
                        statement: statement,
                        columns: columns
                    ),
                    targetLinksWindowID: try optionalUUIDBlobColumn(
                        "targetLinksWindowId",
                        table: "Window",
                        statement: statement,
                        columns: columns
                    ),
                    syncGroup: try intOrDefaultColumn(
                        "syncGroup",
                        table: "Window",
                        statement: statement,
                        columns: columns,
                        default: 0
                    ),
                    layoutState: try requiredTextColumn(
                        "window_layout_state",
                        table: "Window",
                        statement: statement,
                        columns: columns
                    ),
                    layoutWeight: try floatOrDefaultColumn(
                        "window_layout_weight",
                        table: "Window",
                        statement: statement,
                        columns: columns,
                        default: 1.0
                    )
                )
            )
        }

        return rows
    }

    /**
     Reads staged Android page-manager rows from the SQLite backup.

     - Parameter db: Open staged Android workspace database.
     - Returns: Flat staged page-manager rows.
     - Side effects:
       - prepares and steps a SQLite query against the `PageManager` table
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase` when SQLite cannot prepare the query
       - rethrows value-decoding errors for required columns, identifier blobs, or serialized JSON payloads
     */
    private func fetchPageManagers(from db: OpaquePointer) throws -> [RawPageManagerRow] {
        let sql = "SELECT * FROM PageManager"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        let columns = columnIndexMap(for: statement)
        var rows: [RawPageManagerRow] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                RawPageManagerRow(
                    windowID: try requiredUUIDBlobColumn(
                        "windowId",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    bibleDocument: try optionalTextColumn(
                        "bible_document",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    bibleVersification: try optionalTextColumn(
                        "bible_verse_versification",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    bibleBook: try optionalIntColumn(
                        "bible_verse_bibleBook",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    bibleChapterNo: try optionalIntColumn(
                        "bible_verse_chapterNo",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    bibleVerseNo: try optionalIntColumn(
                        "bible_verse_verseNo",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    commentaryDocument: try optionalTextColumn(
                        "commentary_document",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    commentaryAnchorOrdinal: try optionalIntColumn(
                        "commentary_anchorOrdinal",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    commentarySourceBookAndKey: try optionalTextColumn(
                        "commentary_sourceBookAndKey",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    dictionaryDocument: try optionalTextColumn(
                        "dictionary_document",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    dictionaryKey: try optionalTextColumn(
                        "dictionary_key",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    dictionaryAnchorOrdinal: try optionalIntColumn(
                        "dictionary_anchorOrdinal",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    generalBookDocument: try optionalTextColumn(
                        "general_book_document",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    generalBookKey: try optionalTextColumn(
                        "general_book_key",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    generalBookAnchorOrdinal: try optionalIntColumn(
                        "general_book_anchorOrdinal",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    mapDocument: try optionalTextColumn(
                        "map_document",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    mapKey: try optionalTextColumn(
                        "map_key",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    mapAnchorOrdinal: try optionalIntColumn(
                        "map_anchorOrdinal",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    currentCategoryName: try requiredTextColumn(
                        "currentCategoryName",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    ),
                    textDisplaySettings: try decodeTextDisplaySettings(
                        table: "PageManager",
                        statement: statement,
                        columns: columns,
                        prefix: "text_display_settings_"
                    ),
                    jsState: try optionalTextColumn(
                        "jsState",
                        table: "PageManager",
                        statement: statement,
                        columns: columns
                    )
                )
            )
        }

        return rows
    }

    /**
     Reads staged Android history rows from the SQLite backup.

     - Parameter db: Open staged Android workspace database.
     - Returns: Flat staged history rows.
     - Side effects:
       - prepares and steps a SQLite query against the `HistoryItem` table
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase` when SQLite cannot prepare the query
       - rethrows value-decoding errors for required columns or identifier blobs
     */
    private func fetchHistoryItems(from db: OpaquePointer) throws -> [RemoteSyncAndroidWorkspaceHistoryItem] {
        let sql = "SELECT * FROM HistoryItem"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        let columns = columnIndexMap(for: statement)
        var rows: [RemoteSyncAndroidWorkspaceHistoryItem] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let milliseconds = try requiredInt64Column(
                "createdAt",
                table: "HistoryItem",
                statement: statement,
                columns: columns
            )
            rows.append(
                RemoteSyncAndroidWorkspaceHistoryItem(
                    remoteID: try requiredInt64Column(
                        "id",
                        table: "HistoryItem",
                        statement: statement,
                        columns: columns
                    ),
                    windowID: try requiredUUIDBlobColumn(
                        "windowId",
                        table: "HistoryItem",
                        statement: statement,
                        columns: columns
                    ),
                    createdAt: Date(timeIntervalSince1970: Double(milliseconds) / 1000.0),
                    document: try requiredTextColumn(
                        "document",
                        table: "HistoryItem",
                        statement: statement,
                        columns: columns
                    ),
                    key: try requiredTextColumn(
                        "key",
                        table: "HistoryItem",
                        statement: statement,
                        columns: columns
                    ),
                    anchorOrdinal: try optionalIntColumn(
                        "anchorOrdinal",
                        table: "HistoryItem",
                        statement: statement,
                        columns: columns
                    )
                )
            )
        }

        return rows
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
     Reads one required 64-bit integer column from the current SQLite row.

     - Parameters:
       - name: Required column name.
       - table: Table name used for error reporting.
       - statement: SQLite statement positioned on the current row.
       - columns: Precomputed column-name map.
     - Returns: 64-bit integer value decoded from the current row.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidColumnValue` when the column is null
     */
    private func requiredInt64Column(
        _ name: String,
        table: String,
        statement: OpaquePointer,
        columns: [String: Int32]
    ) throws -> Int64 {
        let index = try columnIndex(name, table: table, columns: columns)
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            throw RemoteSyncWorkspaceRestoreError.invalidColumnValue(table: table, column: name)
        }
        return sqlite3_column_int64(statement, index)
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
     Normalizes Android raw category names into the lower-case page-manager keys iOS persists.

     Android stores values such as `BIBLE`, `GENERAL_BOOK`, and `MAPS`, while iOS expects values
     such as `bible`, `general_book`, and `map`. Unsupported Android categories fall back to
     `bible` and are preserved verbatim in `RemoteSyncWorkspaceFidelityStore`.

     - Parameter rawValue: Raw Android `currentCategoryName` value.
     - Returns: Lower-case iOS page-manager key.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func normalizedCurrentCategoryName(from rawValue: String) -> String {
        switch rawValue.uppercased() {
        case "BIBLE":
            return "bible"
        case "COMMENTARY":
            return "commentary"
        case "DICTIONARY":
            return "dictionary"
        case "GENERAL_BOOK":
            return "general_book"
        case "MAP", "MAPS":
            return "map"
        default:
            return "bible"
        }
    }
}
