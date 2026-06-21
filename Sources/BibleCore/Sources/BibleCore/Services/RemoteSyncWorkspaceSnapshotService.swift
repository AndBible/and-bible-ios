// RemoteSyncWorkspaceSnapshotService.swift — Android-shaped local workspace snapshots for outbound sync

import CryptoKit
import Foundation
import SwiftData

/**
 Current local representation of one Android `Workspace` row.
 */
public struct RemoteSyncCurrentWorkspaceRow: Sendable, Codable {
    /// Android-compatible workspace identifier.
    public let id: UUID

    /// User-visible workspace name.
    public let name: String

    /// Optional contents summary text.
    public let contentsText: String?

    /// Android display order within the workspace list.
    public let orderNumber: Int

    /// Android-compatible text-display settings block embedded in the workspace row.
    public let textDisplaySettings: TextDisplaySettings?

    /// Android-compatible workspace settings block excluding Android-only fidelity fields.
    public let workspaceSettings: WorkspaceSettings

    /// Raw Android `speakSettings` JSON preserved in the fidelity store.
    public let speakSettingsJSON: String?

    /// Android unpinned-window layout weight.
    public let unPinnedWeight: Float?

    /// Android maximized-window identifier.
    public let maximizedWindowID: UUID?

    /// Android primary links-target window identifier.
    public let primaryTargetLinksWindowID: UUID?

    /// Android signed ARGB workspace color.
    public let workspaceColor: Int?

    /**
     Creates one Android-shaped current workspace row.

     - Parameters:
       - id: Android-compatible workspace identifier.
       - name: User-visible workspace name.
       - contentsText: Optional contents summary text.
       - orderNumber: Android display order within the workspace list.
       - textDisplaySettings: Android-compatible text-display settings block embedded in the workspace row.
       - workspaceSettings: Android-compatible workspace settings block excluding Android-only fidelity fields.
       - speakSettingsJSON: Raw Android `speakSettings` JSON preserved in the fidelity store.
       - unPinnedWeight: Android unpinned-window layout weight.
       - maximizedWindowID: Android maximized-window identifier.
       - primaryTargetLinksWindowID: Android primary links-target window identifier.
       - workspaceColor: Android signed ARGB workspace color.
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
        workspaceColor: Int?
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
    }
}

/**
 Current local representation of one Android `Window` row.
 */
public struct RemoteSyncCurrentWorkspaceWindowRow: Sendable, Equatable, Codable {
    /// Android-compatible window identifier.
    public let id: UUID

    /// Owning Android workspace identifier.
    public let workspaceID: UUID

    /// Android synchronized-window flag.
    public let isSynchronized: Bool

    /// Android pin-mode flag.
    public let isPinMode: Bool

    /// Android links-window flag.
    public let isLinksWindow: Bool

    /// Android display order within the workspace.
    public let orderNumber: Int

    /// Android target-links-window identifier.
    public let targetLinksWindowID: UUID?

    /// Android sync-group integer.
    public let syncGroup: Int

    /// Android window layout-state string.
    public let layoutState: String

    /// Android window layout weight.
    public let layoutWeight: Float

    /**
     Creates one Android-shaped current window row.

     - Parameters:
       - id: Android-compatible window identifier.
       - workspaceID: Owning Android workspace identifier.
       - isSynchronized: Android synchronized-window flag.
       - isPinMode: Android pin-mode flag.
       - isLinksWindow: Android links-window flag.
       - orderNumber: Android display order within the workspace.
       - targetLinksWindowID: Android target-links-window identifier.
       - syncGroup: Android sync-group integer.
       - layoutState: Android window layout-state string.
       - layoutWeight: Android window layout weight.
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
        layoutWeight: Float
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
    }
}

/**
 Current local representation of one Android `PageManager` row.
 */
public struct RemoteSyncCurrentWorkspacePageManagerRow: Sendable, Equatable, Codable {
    /// Android-compatible window identifier that owns the page-manager row.
    public let windowID: UUID

    /// Android Bible module initials.
    public let bibleDocument: String?

    /// Android persisted versification.
    public let bibleVersification: String

    /// Android persisted Bible book index.
    public let bibleBook: Int

    /// Android persisted Bible chapter number.
    public let bibleChapterNo: Int

    /// Android persisted Bible verse number.
    public let bibleVerseNo: Int

    /// Android commentary module initials.
    public let commentaryDocument: String?

    /// Android commentary anchor ordinal.
    public let commentaryAnchorOrdinal: Int?

    /// Android commentary source book/key payload preserved through the fidelity store.
    public let commentarySourceBookAndKey: String?

    /// Android dictionary module initials.
    public let dictionaryDocument: String?

    /// Android dictionary key or headword.
    public let dictionaryKey: String?

    /// Android dictionary anchor ordinal preserved through the fidelity store.
    public let dictionaryAnchorOrdinal: Int?

    /// Android general-book module initials.
    public let generalBookDocument: String?

    /// Android general-book key.
    public let generalBookKey: String?

    /// Android general-book anchor ordinal preserved through the fidelity store.
    public let generalBookAnchorOrdinal: Int?

    /// Android map module initials.
    public let mapDocument: String?

    /// Android map key.
    public let mapKey: String?

    /// Android map anchor ordinal preserved through the fidelity store.
    public let mapAnchorOrdinal: Int?

    /// Android raw current-category enum string.
    public let currentCategoryName: String

    /// Android-compatible text-display settings block embedded in the page-manager row.
    public let textDisplaySettings: TextDisplaySettings?

    /// Serialized JavaScript reader state.
    public let jsState: String?

    /**
     Creates one Android-shaped current page-manager row.

     - Parameters:
       - windowID: Android-compatible window identifier that owns the page-manager row.
       - bibleDocument: Android Bible module initials.
       - bibleVersification: Android persisted versification.
       - bibleBook: Android persisted Bible book index.
       - bibleChapterNo: Android persisted Bible chapter number.
       - bibleVerseNo: Android persisted Bible verse number.
       - commentaryDocument: Android commentary module initials.
       - commentaryAnchorOrdinal: Android commentary anchor ordinal.
       - commentarySourceBookAndKey: Android commentary source book/key payload preserved through the fidelity store.
       - dictionaryDocument: Android dictionary module initials.
       - dictionaryKey: Android dictionary key or headword.
       - dictionaryAnchorOrdinal: Android dictionary anchor ordinal preserved through the fidelity store.
       - generalBookDocument: Android general-book module initials.
       - generalBookKey: Android general-book key.
       - generalBookAnchorOrdinal: Android general-book anchor ordinal preserved through the fidelity store.
       - mapDocument: Android map module initials.
       - mapKey: Android map key.
       - mapAnchorOrdinal: Android map anchor ordinal preserved through the fidelity store.
       - currentCategoryName: Android raw current-category enum string.
       - textDisplaySettings: Android-compatible text-display settings block embedded in the page-manager row.
       - jsState: Serialized JavaScript reader state.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        windowID: UUID,
        bibleDocument: String?,
        bibleVersification: String,
        bibleBook: Int,
        bibleChapterNo: Int,
        bibleVerseNo: Int,
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
 Snapshot of the current local workspace state expressed in Android row form.

 The snapshot carries per-table row maps keyed by Android's `(tableName, entityId1, entityId2)`
 composite identifier together with precomputed row fingerprints. Outbound workspace patch creation
 can then diff local state without reprojecting the live SwiftData graph repeatedly.
 */
public struct RemoteSyncWorkspaceCurrentSnapshot: Sendable {
    /// Android-shaped current `Workspace` rows keyed by Android composite key.
    public let workspaceRowsByKey: [String: RemoteSyncCurrentWorkspaceRow]

    /// Android-shaped current `Window` rows keyed by Android composite key.
    public let windowRowsByKey: [String: RemoteSyncCurrentWorkspaceWindowRow]

    /// Android-shaped current `PageManager` rows keyed by Android composite key.
    public let pageManagerRowsByKey: [String: RemoteSyncCurrentWorkspacePageManagerRow]

    /// Stable content fingerprints for every current row keyed by Android composite key.
    public let fingerprintsByKey: [String: String]

    /**
     Creates one current-state workspace snapshot.

     - Parameters:
       - workspaceRowsByKey: Android-shaped current `Workspace` rows keyed by Android composite key.
       - windowRowsByKey: Android-shaped current `Window` rows keyed by Android composite key.
       - pageManagerRowsByKey: Android-shaped current `PageManager` rows keyed by Android composite key.
       - fingerprintsByKey: Stable content fingerprints for every current row keyed by Android composite key.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        workspaceRowsByKey: [String: RemoteSyncCurrentWorkspaceRow],
        windowRowsByKey: [String: RemoteSyncCurrentWorkspaceWindowRow],
        pageManagerRowsByKey: [String: RemoteSyncCurrentWorkspacePageManagerRow],
        fingerprintsByKey: [String: String]
    ) {
        self.workspaceRowsByKey = workspaceRowsByKey
        self.windowRowsByKey = windowRowsByKey
        self.pageManagerRowsByKey = pageManagerRowsByKey
        self.fingerprintsByKey = fingerprintsByKey
    }
}

/**
 Projects current local workspace state into Android-shaped rows and row fingerprints.

 Outbound workspace sync needs the inverse of restore and patch replay:
 - convert local `Workspace`, `Window`, and `PageManager` SwiftData models back into Android row
   shapes
 - preserve Android-only fidelity payloads from `RemoteSyncWorkspaceFidelityStore` so outbound
   rows retain raw category names, speak settings, and unsupported anchor metadata
 - compute stable content fingerprints keyed by Android's composite identifier so later patch
   creation can detect inserts, updates, and deletes without hidden SQLite triggers

 Mapping notes:
 - workspace rows reuse the persisted iOS `WorkspaceSettings` payload for the supported field set
   while reading Android-only `speakSettings` JSON from the fidelity store
 - page-manager rows preserve Android raw category names and anchor-ordinal/source payloads from
   the fidelity store when present, and otherwise normalize iOS category keys back into Android raw
   enum strings
 - missing Bible-position fields are normalized to the Android fixture defaults used by the test
   database builder so outbound page-manager rows always remain representable in patch SQLite

 Data dependencies:
 - `ModelContext` provides live workspace-category SwiftData rows
 - `RemoteSyncWorkspaceFidelityStore` provides preserved Android-only workspace fidelity payloads
 - `RemoteSyncLogEntryStore` provides canonical Android composite-key encoding
 - `RemoteSyncRowFingerprintStore` persists baseline fingerprints after restore, replay, or upload

 Side effects:
 - `snapshotCurrentState` reads workspace-category SwiftData rows and local-only fidelity settings
 - `refreshBaselineFingerprints` rewrites local fingerprint rows for the workspace category

 Failure modes:
 - fetch failures from `ModelContext` are swallowed and treated as an empty local workspace set to
   stay aligned with the repo's existing settings-store behavior

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement rules of the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncWorkspaceSnapshotService {
    private enum Defaults {
        static let bibleVersification = "KJVA"
        static let bibleBook = 0
        static let bibleChapter = 1
        static let bibleVerse = 1
    }

    /**
     Creates a workspace snapshot service.

     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init() {}

    /**
     Projects the current local workspace state into Android-shaped rows and row fingerprints.

     - Parameters:
       - modelContext: SwiftData context that owns the current workspace graph.
       - settingsStore: Local-only settings store that holds preserved Android fidelity payloads.
     - Returns: Android-shaped current rows and their stable fingerprints keyed by Android composite key.
     - Side effects:
       - reads current workspace-category SwiftData rows from `modelContext`
       - reads preserved Android fidelity rows from `SettingsStore`
     - Failure modes:
       - fetch failures from `ModelContext` are swallowed and treated as an empty snapshot
     */
    public func snapshotCurrentState(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) -> RemoteSyncWorkspaceCurrentSnapshot {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        let workspaceFidelityByID = Dictionary(
            uniqueKeysWithValues: fidelityStore.allWorkspaceEntries().map { ($0.workspaceID, $0) }
        )
        let pageManagerFidelityByWindowID = Dictionary(
            uniqueKeysWithValues: fidelityStore.allPageManagerEntries().map { ($0.windowID, $0) }
        )
        let workspaces = ((try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? [])
            .sorted(by: Self.sortWorkspaces)

        var workspaceRowsByKey: [String: RemoteSyncCurrentWorkspaceRow] = [:]
        var windowRowsByKey: [String: RemoteSyncCurrentWorkspaceWindowRow] = [:]
        var pageManagerRowsByKey: [String: RemoteSyncCurrentWorkspacePageManagerRow] = [:]
        var fingerprintsByKey: [String: String] = [:]

        for workspace in workspaces {
            var workspaceSettings = workspace.workspaceSettings ?? WorkspaceSettings()
            workspaceSettings.normalizeAutoAssignPrimaryLabel()
            let workspaceRow = RemoteSyncCurrentWorkspaceRow(
                id: workspace.id,
                name: workspace.name,
                contentsText: workspace.contentsText,
                orderNumber: workspace.orderNumber,
                textDisplaySettings: workspace.textDisplaySettings,
                workspaceSettings: workspaceSettings,
                speakSettingsJSON: workspaceFidelityByID[workspace.id]?.speakSettingsJSON,
                unPinnedWeight: workspace.unPinnedWeight,
                maximizedWindowID: workspace.maximizedWindowId,
                primaryTargetLinksWindowID: workspace.primaryTargetLinksWindowId,
                workspaceColor: workspace.workspaceColor
            )
            let workspaceKey = logEntryStore.key(
                for: .workspaces,
                tableName: "Workspace",
                entityID1: .blob(Self.uuidBlob(workspace.id)),
                entityID2: .text("")
            )
            workspaceRowsByKey[workspaceKey] = workspaceRow
            fingerprintsByKey[workspaceKey] = Self.fingerprintHex(for: workspaceRow)

            let windows = (workspace.windows ?? []).sorted(by: Self.sortWindows)
            for window in windows {
                let windowRow = RemoteSyncCurrentWorkspaceWindowRow(
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
                let windowKey = logEntryStore.key(
                    for: .workspaces,
                    tableName: "Window",
                    entityID1: .blob(Self.uuidBlob(window.id)),
                    entityID2: .text("")
                )
                windowRowsByKey[windowKey] = windowRow
                fingerprintsByKey[windowKey] = Self.fingerprintHex(for: windowRow)

                let pageManager = window.pageManager
                let pageManagerFidelity = pageManagerFidelityByWindowID[window.id]
                let pageManagerRow = RemoteSyncCurrentWorkspacePageManagerRow(
                    windowID: window.id,
                    bibleDocument: pageManager?.bibleDocument,
                    bibleVersification: pageManager?.bibleVersification ?? Defaults.bibleVersification,
                    bibleBook: pageManager?.bibleBibleBook ?? Defaults.bibleBook,
                    bibleChapterNo: pageManager?.bibleChapterNo ?? Defaults.bibleChapter,
                    bibleVerseNo: pageManager?.bibleVerseNo ?? Defaults.bibleVerse,
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
                let pageManagerKey = logEntryStore.key(
                    for: .workspaces,
                    tableName: "PageManager",
                    entityID1: .blob(Self.uuidBlob(window.id)),
                    entityID2: .text("")
                )
                pageManagerRowsByKey[pageManagerKey] = pageManagerRow
                fingerprintsByKey[pageManagerKey] = Self.fingerprintHex(for: pageManagerRow)
            }
        }

        return RemoteSyncWorkspaceCurrentSnapshot(
            workspaceRowsByKey: workspaceRowsByKey,
            windowRowsByKey: windowRowsByKey,
            pageManagerRowsByKey: pageManagerRowsByKey,
            fingerprintsByKey: fingerprintsByKey
        )
    }

    /**
     Replaces the stored fingerprint baseline for workspace rows with the current local snapshot.

     This method is intended to run after remote initial-backup restores or remote patch replay so
     later outbound patch creation compares local edits against the newly accepted remote baseline
     instead of stale pre-restore content hashes.

     - Parameters:
       - modelContext: SwiftData context that owns the current workspace graph.
       - settingsStore: Local-only settings store used by the fingerprint store.
     - Side effects:
       - rewrites fingerprint rows for current `Workspace`, `Window`, and `PageManager` entries
       - removes stale fingerprint rows whose Android keys are no longer present locally
     - Failure modes:
       - fetch failures while reading the current workspace graph are swallowed and treated as an empty snapshot
     */
    public func refreshBaselineFingerprints(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) {
        let snapshot = snapshotCurrentState(modelContext: modelContext, settingsStore: settingsStore)
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)

        for entry in logEntryStore.entries(for: .workspaces) {
            let key = logEntryStore.key(for: .workspaces, entry: entry)
            if snapshot.fingerprintsByKey[key] == nil {
                fingerprintStore.removeFingerprint(
                    for: .workspaces,
                    tableName: entry.tableName,
                    entityID1: entry.entityID1,
                    entityID2: entry.entityID2
                )
            }
        }

        for (key, row) in snapshot.workspaceRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .workspaces,
                tableName: "Workspace",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .text("")
            )
        }

        for (key, row) in snapshot.windowRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .workspaces,
                tableName: "Window",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .text("")
            )
        }

        for (key, row) in snapshot.pageManagerRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .workspaces,
                tableName: "PageManager",
                entityID1: .blob(Self.uuidBlob(row.windowID)),
                entityID2: .text("")
            )
        }
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one Android `Workspace` row.

     - Parameter value: Android-shaped current `Workspace` row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncCurrentWorkspaceRow) -> String {
        let components = [
            value.id.uuidString.lowercased(),
            value.name,
            value.contentsText ?? "",
            String(value.orderNumber),
            canonicalTextDisplaySettings(value.textDisplaySettings),
            canonicalWorkspaceSettings(value.workspaceSettings),
            value.speakSettingsJSON ?? "",
            canonicalOptionalFloat(value.unPinnedWeight),
            value.maximizedWindowID?.uuidString.lowercased() ?? "",
            value.primaryTargetLinksWindowID?.uuidString.lowercased() ?? "",
            canonicalOptionalInt(value.workspaceColor),
        ]
        return fingerprintHex(canonicalValue: components.joined(separator: "|"))
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one Android `Window` row.

     - Parameter value: Android-shaped current `Window` row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncCurrentWorkspaceWindowRow) -> String {
        let components = [
            value.id.uuidString.lowercased(),
            value.workspaceID.uuidString.lowercased(),
            canonicalBool(value.isSynchronized),
            canonicalBool(value.isPinMode),
            canonicalBool(value.isLinksWindow),
            String(value.orderNumber),
            value.targetLinksWindowID?.uuidString.lowercased() ?? "",
            String(value.syncGroup),
            value.layoutState,
            String(value.layoutWeight),
        ]
        return fingerprintHex(canonicalValue: components.joined(separator: "|"))
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one Android `PageManager` row.

     - Parameter value: Android-shaped current `PageManager` row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncCurrentWorkspacePageManagerRow) -> String {
        let bibleComponents = [
            value.windowID.uuidString.lowercased(),
            value.bibleDocument ?? "",
            value.bibleVersification,
            String(value.bibleBook),
            String(value.bibleChapterNo),
            String(value.bibleVerseNo),
        ]
        let commentaryComponents = [
            value.commentaryDocument ?? "",
            canonicalOptionalInt(value.commentaryAnchorOrdinal),
            value.commentarySourceBookAndKey ?? "",
        ]
        let dictionaryComponents = [
            value.dictionaryDocument ?? "",
            value.dictionaryKey ?? "",
            canonicalOptionalInt(value.dictionaryAnchorOrdinal),
        ]
        let generalBookComponents = [
            value.generalBookDocument ?? "",
            value.generalBookKey ?? "",
            canonicalOptionalInt(value.generalBookAnchorOrdinal),
        ]
        let mapAndDisplayComponents = [
            value.mapDocument ?? "",
            value.mapKey ?? "",
            canonicalOptionalInt(value.mapAnchorOrdinal),
            value.currentCategoryName,
            canonicalTextDisplaySettings(value.textDisplaySettings),
            value.jsState ?? "",
        ]
        let components = bibleComponents
            + commentaryComponents
            + dictionaryComponents
            + generalBookComponents
            + mapAndDisplayComponents
        return fingerprintHex(canonicalValue: components.joined(separator: "|"))
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one canonical row string.

     - Parameter canonicalValue: Canonical text representation of one Android row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the supplied string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(canonicalValue: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /**
     Converts one UUID into Android's raw 16-byte SQLite BLOB format.

     - Parameter uuid: UUID to convert.
     - Returns: Raw 16-byte SQLite payload matching Android's identifier storage format.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func uuidBlob(_ uuid: UUID) -> Data {
        var bytes = uuid.uuid
        return withUnsafeBytes(of: &bytes) { Data($0) }
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
    static func sortWorkspaces(_ lhs: Workspace, _ rhs: Workspace) -> Bool {
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
    static func sortWindows(_ lhs: Window, _ rhs: Window) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    /**
     Normalizes one local page-manager category key back into Android's raw enum-style string.

     - Parameter localValue: Lower-case iOS page-manager key.
     - Returns: Android raw category name suitable for outbound workspace rows.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func remoteCurrentCategoryName(from localValue: String) -> String {
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
     Canonicalizes one optional text-display settings block into a stable string.

     - Parameter value: Optional text-display settings block.
     - Returns: Stable string containing every serialized workspace/page-manager text-display field.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func canonicalTextDisplaySettings(_ value: TextDisplaySettings?) -> String {
        let settings = value ?? TextDisplaySettings()
        let components = [
            canonicalOptionalInt(settings.strongsMode),
            canonicalOptionalBool(settings.showMorphology),
            canonicalOptionalBool(settings.showFootNotes),
            canonicalOptionalBool(settings.showFootNotesInline),
            canonicalOptionalBool(settings.expandXrefs),
            canonicalOptionalBool(settings.showXrefs),
            canonicalOptionalBool(settings.showRedLetters),
            canonicalOptionalBool(settings.showSectionTitles),
            canonicalOptionalBool(settings.showVerseNumbers),
            canonicalOptionalBool(settings.showVersePerLine),
            canonicalOptionalBool(settings.showBookmarks),
            canonicalOptionalBool(settings.showMyNotes),
            canonicalOptionalBool(settings.justifyText),
            canonicalOptionalBool(settings.hyphenation),
            canonicalOptionalInt(settings.topMargin),
            canonicalOptionalInt(settings.fontSize),
            settings.fontFamily ?? "",
            canonicalOptionalInt(settings.lineSpacing),
            canonicalUUIDArray(settings.bookmarksHideLabels),
            canonicalOptionalBool(settings.showPageNumber),
            canonicalOptionalInt(settings.marginLeft),
            canonicalOptionalInt(settings.marginRight),
            canonicalOptionalInt(settings.maxWidth),
            canonicalOptionalInt(settings.dayTextColor),
            canonicalOptionalInt(settings.dayBackground),
            canonicalOptionalInt(settings.dayNoise),
            canonicalOptionalInt(settings.nightTextColor),
            canonicalOptionalInt(settings.nightBackground),
            canonicalOptionalInt(settings.nightNoise),
        ]
        return components.joined(separator: "^")
    }

    /**
     Canonicalizes one workspace-settings payload into a stable string.

     - Parameter value: Workspace settings payload.
     - Returns: Stable string containing every serialized workspace-settings field that participates in Android sync.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func canonicalWorkspaceSettings(_ value: WorkspaceSettings) -> String {
        var normalizedValue = value
        normalizedValue.normalizeAutoAssignPrimaryLabel()

        let recentLabels = normalizedValue.recentLabels.map {
            "\($0.labelId.uuidString.lowercased())@\(Int64($0.lastAccess.timeIntervalSince1970 * 1000.0))"
        }.joined(separator: ",")
        let autoAssignLabels = normalizedValue.autoAssignLabels
            .map { $0.uuidString.lowercased() }
            .sorted()
            .joined(separator: ",")
        let studyPadCursors = normalizedValue.studyPadCursors.keys
            .sorted { $0.uuidString < $1.uuidString }
            .map { key in "\(key.uuidString.lowercased())=\(normalizedValue.studyPadCursors[key] ?? 0)" }
            .joined(separator: ",")
        let hiddenCompareDocuments = normalizedValue.hideCompareDocuments.sorted().joined(separator: ",")
        let components = [
            canonicalBool(normalizedValue.enableTiltToScroll),
            canonicalBool(normalizedValue.enableReverseSplitMode),
            canonicalBool(normalizedValue.autoPin),
            recentLabels,
            autoAssignLabels,
            normalizedValue.autoAssignPrimaryLabel?.uuidString.lowercased() ?? "",
            studyPadCursors,
            hiddenCompareDocuments,
            canonicalBool(normalizedValue.limitAmbiguousModalSize),
        ]
        return components.joined(separator: "^")
    }

    /**
     Canonicalizes one optional UUID array into a stable comma-delimited string.

     - Parameter value: Optional UUID array.
     - Returns: Stable string representation preserving array order.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func canonicalUUIDArray(_ value: [UUID]?) -> String {
        guard let value else {
            return ""
        }
        return value.map { $0.uuidString.lowercased() }.joined(separator: ",")
    }

    /**
     Converts one Boolean into the canonical fingerprint string representation.

     - Parameter value: Boolean value to convert.
     - Returns: `1` for `true` and `0` for `false`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func canonicalBool(_ value: Bool) -> String {
        value ? "1" : "0"
    }

    /**
     Converts one optional Boolean into the canonical fingerprint string representation.

     - Parameter value: Optional Boolean value to convert.
     - Returns: Empty string for `nil`, otherwise `1` or `0`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func canonicalOptionalBool(_ value: Bool?) -> String {
        guard let value else {
            return ""
        }
        return canonicalBool(value)
    }

    /**
     Converts one optional integer into the canonical fingerprint string representation.

     - Parameter value: Optional integer value to convert.
     - Returns: Empty string for `nil`, otherwise the decimal string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func canonicalOptionalInt(_ value: Int?) -> String {
        guard let value else {
            return ""
        }
        return String(value)
    }

    /**
     Converts one optional floating-point value into the canonical fingerprint string representation.

     - Parameter value: Optional floating-point value to convert.
     - Returns: Empty string for `nil`, otherwise the decimal string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func canonicalOptionalFloat(_ value: Float?) -> String {
        guard let value else {
            return ""
        }
        return String(value)
    }
}
