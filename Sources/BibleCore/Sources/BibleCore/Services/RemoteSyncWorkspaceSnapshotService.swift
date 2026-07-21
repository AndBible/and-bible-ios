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

    /// Android-only Room text-display fields not represented by the native reader model.
    public let textDisplayFidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity

    /// Android-compatible workspace settings block excluding Android-only fidelity fields.
    public let workspaceSettings: WorkspaceSettings

    /// Complete Android `speakSettings` JSON synthesized from native state or preserved as fallback.
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
       - speakSettingsJSON: Complete Android `speakSettings` JSON synthesized from native state or preserved as fallback.
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
        textDisplayFidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity = .init(),
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
        self.textDisplayFidelity = textDisplayFidelity
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

    /// Android-only Room text-display fields not represented by the native reader model.
    public let textDisplayFidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity

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
        textDisplayFidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity = .init(),
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
        self.textDisplayFidelity = textDisplayFidelity
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

    /// Android-shaped `WorkspaceLabelOverride` rows keyed by composite workspace/label identity.
    public let labelOverrideRowsByKey: [String: RemoteSyncCurrentWorkspaceLabelOverrideRow]

    /// Android-shaped global text-display singleton rows keyed by Android identity.
    public let globalTextDisplayRowsByKey: [String: RemoteSyncCurrentGlobalTextDisplaySettingsRow]

    /// Stable content fingerprints for every current row keyed by Android composite key.
    public let fingerprintsByKey: [String: String]

    /// Quarantined row keys omitted from export whose accepted baseline must remain intact.
    public let suppressedKeys: Set<String>

    /**
     Creates one current-state workspace snapshot.

     - Parameters:
       - workspaceRowsByKey: Android-shaped current `Workspace` rows keyed by Android composite key.
       - windowRowsByKey: Android-shaped current `Window` rows keyed by Android composite key.
       - pageManagerRowsByKey: Android-shaped current `PageManager` rows keyed by Android composite key.
       - fingerprintsByKey: Stable content fingerprints for every current row keyed by Android composite key.
       - suppressedKeys: Quarantined keys omitted from export and protected from inferred deletes.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        workspaceRowsByKey: [String: RemoteSyncCurrentWorkspaceRow],
        windowRowsByKey: [String: RemoteSyncCurrentWorkspaceWindowRow],
        pageManagerRowsByKey: [String: RemoteSyncCurrentWorkspacePageManagerRow],
        labelOverrideRowsByKey: [String: RemoteSyncCurrentWorkspaceLabelOverrideRow] = [:],
        globalTextDisplayRowsByKey: [String: RemoteSyncCurrentGlobalTextDisplaySettingsRow] = [:],
        fingerprintsByKey: [String: String],
        suppressedKeys: Set<String> = []
    ) {
        self.workspaceRowsByKey = workspaceRowsByKey
        self.windowRowsByKey = windowRowsByKey
        self.pageManagerRowsByKey = pageManagerRowsByKey
        self.labelOverrideRowsByKey = labelOverrideRowsByKey
        self.globalTextDisplayRowsByKey = globalTextDisplayRowsByKey
        self.fingerprintsByKey = fingerprintsByKey
        self.suppressedKeys = suppressedKeys
    }
}

/**
 Identifies one workspace-category row in an accepted restore, replay, or upload generation.

 The durable identity manifest allows a later local deletion to emit an Android `DELETE` even when
 the initial database did not carry a corresponding `LogEntry` row.
 */
struct RemoteSyncWorkspaceAcceptedRowIdentity: Codable, Sendable, Equatable {
    /// Android table that owns the accepted row.
    let tableName: String

    /// First Android composite-key component.
    let entityID1: RemoteSyncSQLiteValue

    /// Second Android composite-key component.
    let entityID2: RemoteSyncSQLiteValue
}

/**
 Immutable workspace baseline accepted after restore, replay, or outbound upload.
 */
struct RemoteSyncWorkspaceAcceptedGeneration: Codable, Sendable, Equatable {
    /// Exact row fingerprints carried by the accepted generation.
    let fingerprintsByKey: [String: String]

    /// Exact accepted row identities keyed by Android's canonical composite key.
    let rowsByKey: [String: RemoteSyncWorkspaceAcceptedRowIdentity]

    /// Quarantined keys whose prior accepted identity and fingerprint remain preserved.
    let suppressedKeys: Set<String>
}

/** Durable revisioned workspace baseline used for compare-and-swap publication. */
struct RemoteSyncWorkspaceAcceptedBaseline: Codable, Sendable, Equatable {
    /// Monotonic local revision incremented by every inbound or outbound baseline acceptance.
    let revision: Int64

    /// Complete accepted generation associated with `revision`.
    let generation: RemoteSyncWorkspaceAcceptedGeneration
}

/**
 Errors raised while reading or publishing the durable workspace accepted-row manifest.
 */
enum RemoteSyncWorkspaceSnapshotError: Error, Equatable {
    /// The stored accepted baseline could not be decoded safely.
    case invalidAcceptedBaseline

    /// A projected fingerprint had no matching typed row identity.
    case incompleteAcceptedGeneration(String)

    /// One exportable typed row did not have a stable content fingerprint.
    case missingProjectedFingerprint(String)

    /// Preserved workspace fidelity metadata could not be projected completely.
    case invalidStoredFidelityMetadata

    /// Another accepted generation advanced while an outbound archive was in flight.
    case staleAcceptedBaseline(expected: Int64, actual: Int64)
}

/**
 Projects current local workspace state into Android-shaped rows and row fingerprints.

 Outbound workspace sync needs the inverse of restore and patch replay:
 - convert local `Workspace`, `Window`, and `PageManager` SwiftData models back into Android row
   shapes
 - synthesize complete Android speak settings from native workspace state while preserving fidelity
   payloads for raw category names, unsupported anchor metadata, and encoding fallback
 - compute stable content fingerprints keyed by Android's composite identifier so later patch
   creation can detect inserts, updates, and deletes without hidden SQLite triggers

 Mapping notes:
 - workspace rows encode native `WorkspaceSettings.speakSettings` into Android JSON first and use
   the preserved fidelity payload only if that encoding is unavailable
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
 - strict projection and refresh variants provide the same behavior while participating in an
   explicit atomic restore or replay batch

 Failure modes:
 - legacy projection/refresh methods swallow graph fetch failures as an empty workspace set
 - strict projection/refresh methods rethrow graph fetch failures; otherwise-soft settings failures
   invalidate their containing `SettingsStore` atomic batch

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

    /// Local-only setting containing the revisioned accepted workspace generation.
    static let acceptedBaselineKey = "remote_sync.workspaces.accepted_baseline"

    /// Settings prefixes used by fidelity metadata consumed during workspace projection.
    private static let workspaceFidelityPrefix = "remote_sync.workspaces.fidelity.workspace"
    private static let pageManagerFidelityPrefix = "remote_sync.workspaces.fidelity.page_manager"

    /// Fetches the complete local workspace graph for strict projection.
    private let workspaceFetcher: (ModelContext) throws -> [Workspace]

    /**
     Creates a workspace snapshot service.

     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init() {
        workspaceFetcher = { modelContext in
            try modelContext.fetch(FetchDescriptor<Workspace>())
        }
    }

    /**
     Creates a workspace snapshot service with an explicit graph-fetch behavior.

     This initializer supports deterministic failure-path tests without weakening production's
     strict SwiftData projection.

     - Parameter workspaceFetcher: Throwing operation that returns every current workspace root.
     - Side effects: none until projection is requested.
     - Failure modes: The initializer cannot fail; fetch failures are surfaced by strict projection.
     */
    init(workspaceFetcher: @escaping (ModelContext) throws -> [Workspace]) {
        self.workspaceFetcher = workspaceFetcher
    }

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
        (try? snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )) ?? RemoteSyncWorkspaceCurrentSnapshot(
            workspaceRowsByKey: [:],
            windowRowsByKey: [:],
            pageManagerRowsByKey: [:],
            fingerprintsByKey: [:]
        )
    }

    /**
     Projects the current workspace graph without swallowing SwiftData fetch failures.

     Atomic restore and patch-replay paths use this variant so a failed graph read invalidates the
     containing transaction instead of replacing baseline metadata with an empty snapshot. Settings
     reads retain their normal API shape; when called inside `SettingsStore.performAtomicBatch`, any
     otherwise-soft settings fetch failure is recorded and aborts that outer batch.

     - Parameters:
       - modelContext: SwiftData context that owns the current workspace graph.
       - settingsStore: Local-only settings store that holds preserved Android fidelity payloads.
     - Returns: Android-shaped current rows and stable fingerprints keyed by Android composite key.
     - Side effects: Reads workspace graph and fidelity rows from the supplied shared context.
     - Failure modes: Rethrows workspace fetch failures from `modelContext`.
     */
    func snapshotCurrentStateStrict(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncWorkspaceCurrentSnapshot {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        let rawWorkspaceFidelity = settingsStore.entries(withPrefix: "\(Self.workspaceFidelityPrefix).")
        let rawPageManagerFidelity = settingsStore.entries(withPrefix: "\(Self.pageManagerFidelityPrefix).")
        let rawWorkspaceTextDisplayFidelity = settingsStore.entries(
            withPrefix: "\(RemoteSyncWorkspaceFidelityStore.workspaceTextDisplayFidelityPrefix)."
        )
        let rawPageManagerTextDisplayFidelity = settingsStore.entries(
            withPrefix: "\(RemoteSyncWorkspaceFidelityStore.pageManagerTextDisplayFidelityPrefix)."
        )
        let rawLabelOverrides = settingsStore.entries(
            withPrefix: "\(RemoteSyncWorkspaceFidelityStore.labelOverrideFidelityPrefix)."
        )
        let rawGlobalTextDisplayFidelity = settingsStore.entries(
            withPrefix: RemoteSyncWorkspaceFidelityStore.globalTextDisplayFidelityKey
        ).filter { $0.key == RemoteSyncWorkspaceFidelityStore.globalTextDisplayFidelityKey }
        let workspaceFidelity = fidelityStore.allWorkspaceEntries()
        let pageManagerFidelity = fidelityStore.allPageManagerEntries()
        let workspaceTextDisplayFidelity = fidelityStore.allWorkspaceTextDisplayFidelityEntries()
        let pageManagerTextDisplayFidelity = fidelityStore.allPageManagerTextDisplayFidelityEntries()
        let labelOverrides = fidelityStore.allLabelOverrides()
        let globalTextDisplayFidelity = fidelityStore.globalTextDisplayEntry()
        guard workspaceFidelity.count == rawWorkspaceFidelity.count,
              pageManagerFidelity.count == rawPageManagerFidelity.count,
              workspaceTextDisplayFidelity.count == rawWorkspaceTextDisplayFidelity.count,
              pageManagerTextDisplayFidelity.count == rawPageManagerTextDisplayFidelity.count,
              labelOverrides.count == rawLabelOverrides.count,
              (globalTextDisplayFidelity == nil ? 0 : 1) == rawGlobalTextDisplayFidelity.count else {
            throw RemoteSyncWorkspaceSnapshotError.invalidStoredFidelityMetadata
        }
        let workspaceFidelityByID = Dictionary(
            uniqueKeysWithValues: workspaceFidelity.map { ($0.workspaceID, $0) }
        )
        let pageManagerFidelityByWindowID = Dictionary(
            uniqueKeysWithValues: pageManagerFidelity.map { ($0.windowID, $0) }
        )
        let workspaceTextDisplayFidelityByID = Dictionary(
            uniqueKeysWithValues: workspaceTextDisplayFidelity.map { ($0.ownerID, $0.fidelity) }
        )
        let pageManagerTextDisplayFidelityByWindowID = Dictionary(
            uniqueKeysWithValues: pageManagerTextDisplayFidelity.map { ($0.ownerID, $0.fidelity) }
        )
        let workspaces = try workspaceFetcher(modelContext)
            .sorted(by: Self.sortWorkspaces)
        let workspaceIDs = Set(workspaces.map(\.id))

        var workspaceRowsByKey: [String: RemoteSyncCurrentWorkspaceRow] = [:]
        var windowRowsByKey: [String: RemoteSyncCurrentWorkspaceWindowRow] = [:]
        var pageManagerRowsByKey: [String: RemoteSyncCurrentWorkspacePageManagerRow] = [:]
        var labelOverrideRowsByKey: [String: RemoteSyncCurrentWorkspaceLabelOverrideRow] = [:]
        var globalTextDisplayRowsByKey: [String: RemoteSyncCurrentGlobalTextDisplaySettingsRow] = [:]
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
                textDisplayFidelity: workspaceTextDisplayFidelityByID[workspace.id] ?? .init(),
                workspaceSettings: workspaceSettings,
                speakSettingsJSON: (try? workspaceSettings.speakSettings.androidJSON())
                    ?? workspaceFidelityByID[workspace.id]?.speakSettingsJSON,
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
                    textDisplayFidelity: pageManagerTextDisplayFidelityByWindowID[window.id] ?? .init(),
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

        for row in labelOverrides where workspaceIDs.contains(row.workspaceID) {
            let key = logEntryStore.key(
                for: .workspaces,
                tableName: "WorkspaceLabelOverride",
                entityID1: .blob(Self.uuidBlob(row.workspaceID)),
                entityID2: .blob(Self.uuidBlob(row.labelID))
            )
            labelOverrideRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)
        }

        let storedGlobalSettings: TextDisplaySettings?
        if let rawGlobalSettings = settingsStore.getString(SettingsStore.globalTextDisplaySettingsKey) {
            guard let data = rawGlobalSettings.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(TextDisplaySettings.self, from: data) else {
                throw RemoteSyncWorkspaceSnapshotError.invalidStoredFidelityMetadata
            }
            storedGlobalSettings = decoded
        } else {
            storedGlobalSettings = nil
        }
        if storedGlobalSettings != nil || globalTextDisplayFidelity != nil {
            let row = RemoteSyncCurrentGlobalTextDisplaySettingsRow(
                id: globalTextDisplayFidelity?.id
                    ?? RemoteSyncCurrentGlobalTextDisplaySettingsRow.androidSingletonID,
                textDisplaySettings: storedGlobalSettings,
                fidelity: globalTextDisplayFidelity?.fidelity ?? .init()
            )
            let key = logEntryStore.key(
                for: .workspaces,
                tableName: "GlobalTextDisplaySettings",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .text("")
            )
            globalTextDisplayRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)
        }

        return RemoteSyncWorkspaceCurrentSnapshot(
            workspaceRowsByKey: workspaceRowsByKey,
            windowRowsByKey: windowRowsByKey,
            pageManagerRowsByKey: pageManagerRowsByKey,
            labelOverrideRowsByKey: labelOverrideRowsByKey,
            globalTextDisplayRowsByKey: globalTextDisplayRowsByKey,
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
        try? refreshBaselineFingerprintsStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
    }

    /**
     Replaces workspace baseline fingerprints after a strict current-graph projection.

     This opt-in variant is for atomic restore and patch replay. It prevents a failed SwiftData fetch
     from being interpreted as an empty graph while the surrounding transaction publishes replay
     bookkeeping.

     - Parameters:
       - modelContext: SwiftData context that owns the current workspace graph.
       - settingsStore: Local-only settings store used by the fingerprint store.
     - Side effects: Rewrites current workspace fingerprint rows and removes stale rows.
     - Failure modes: Rethrows graph fetch failures from `snapshotCurrentStateStrict`; settings fetch
       failures invalidate an active `SettingsStore` atomic batch.
     */
    func refreshBaselineFingerprintsStrict(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws {
        let snapshot = try snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let previousBaseline = try storedAcceptedBaseline(settingsStore: settingsStore)
        try validateExportableFingerprints(in: snapshot)
        try acceptBaselineFingerprints(
            acceptedGeneration(from: snapshot, preserving: previousBaseline?.generation),
            settingsStore: settingsStore
        )
    }

    /**
     Builds the immutable accepted baseline represented by one projected workspace snapshot.

     - Parameter snapshot: Complete workspace projection whose rows and fingerprints belong to the
       same generation.
     - Returns: Exact fingerprints and accepted row identities suitable for durable outbox storage.
     - Side effects: none.
     - Failure modes: This helper cannot fail because every projected row has a typed identity.
     */
    func acceptedGeneration(
        from snapshot: RemoteSyncWorkspaceCurrentSnapshot,
        preserving previousGeneration: RemoteSyncWorkspaceAcceptedGeneration? = nil
    ) -> RemoteSyncWorkspaceAcceptedGeneration {
        var rowsByKey: [String: RemoteSyncWorkspaceAcceptedRowIdentity] = [:]
        for (key, row) in snapshot.workspaceRowsByKey where !snapshot.suppressedKeys.contains(key) {
            rowsByKey[key] = RemoteSyncWorkspaceAcceptedRowIdentity(
                tableName: "Workspace",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .text("")
            )
        }
        for (key, row) in snapshot.windowRowsByKey where !snapshot.suppressedKeys.contains(key) {
            rowsByKey[key] = RemoteSyncWorkspaceAcceptedRowIdentity(
                tableName: "Window",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .text("")
            )
        }
        for (key, row) in snapshot.pageManagerRowsByKey where !snapshot.suppressedKeys.contains(key) {
            rowsByKey[key] = RemoteSyncWorkspaceAcceptedRowIdentity(
                tableName: "PageManager",
                entityID1: .blob(Self.uuidBlob(row.windowID)),
                entityID2: .text("")
            )
        }
        for (key, row) in snapshot.labelOverrideRowsByKey where !snapshot.suppressedKeys.contains(key) {
            rowsByKey[key] = RemoteSyncWorkspaceAcceptedRowIdentity(
                tableName: "WorkspaceLabelOverride",
                entityID1: .blob(Self.uuidBlob(row.workspaceID)),
                entityID2: .blob(Self.uuidBlob(row.labelID))
            )
        }
        for (key, row) in snapshot.globalTextDisplayRowsByKey where !snapshot.suppressedKeys.contains(key) {
            rowsByKey[key] = RemoteSyncWorkspaceAcceptedRowIdentity(
                tableName: "GlobalTextDisplaySettings",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .text("")
            )
        }
        var fingerprintsByKey = snapshot.fingerprintsByKey.filter {
            !snapshot.suppressedKeys.contains($0.key)
        }
        for key in snapshot.suppressedKeys {
            if let priorFingerprint = previousGeneration?.fingerprintsByKey[key] {
                fingerprintsByKey[key] = priorFingerprint
            }
            if let priorIdentity = previousGeneration?.rowsByKey[key] {
                rowsByKey[key] = priorIdentity
            }
        }
        return RemoteSyncWorkspaceAcceptedGeneration(
            fingerprintsByKey: fingerprintsByKey,
            rowsByKey: rowsByKey,
            suppressedKeys: snapshot.suppressedKeys
        )
    }

    /**
     Validates that every exportable projected row has one stable fingerprint and no orphan hash.

     - Parameter snapshot: Strict current workspace projection to validate.
     - Side effects: none.
     - Throws: `missingProjectedFingerprint` or `incompleteAcceptedGeneration` when row and
       fingerprint key sets differ outside explicitly suppressed quarantine keys.
     */
    func validateExportableFingerprints(
        in snapshot: RemoteSyncWorkspaceCurrentSnapshot
    ) throws {
        let rowKeys = Set(snapshot.workspaceRowsByKey.keys)
            .union(snapshot.windowRowsByKey.keys)
            .union(snapshot.pageManagerRowsByKey.keys)
            .union(snapshot.labelOverrideRowsByKey.keys)
            .union(snapshot.globalTextDisplayRowsByKey.keys)
            .subtracting(snapshot.suppressedKeys)
        let fingerprintKeys = Set(snapshot.fingerprintsByKey.keys)
            .subtracting(snapshot.suppressedKeys)
        if let missingKey = rowKeys.subtracting(fingerprintKeys).sorted().first {
            throw RemoteSyncWorkspaceSnapshotError.missingProjectedFingerprint(missingKey)
        }
        if let orphanKey = fingerprintKeys.subtracting(rowKeys).sorted().first {
            throw RemoteSyncWorkspaceSnapshotError.incompleteAcceptedGeneration(orphanKey)
        }
    }

    /**
     Reads the complete revisioned accepted baseline when one has been published.

     - Parameter settingsStore: Local-only settings store containing synchronization metadata.
     - Returns: Accepted baseline, or `nil` before initial baseline publication.
     - Side effects: Reads one settings row.
     - Throws: `invalidAcceptedBaseline` for malformed persisted data; strict settings failures
       invalidate an enclosing atomic batch.
     */
    func storedAcceptedBaseline(
        settingsStore: SettingsStore
    ) throws -> RemoteSyncWorkspaceAcceptedBaseline? {
        guard let rawValue = settingsStore.getString(Self.acceptedBaselineKey) else {
            return nil
        }
        guard let data = rawValue.data(using: .utf8),
              let baseline = try? JSONDecoder().decode(
                  RemoteSyncWorkspaceAcceptedBaseline.self,
                  from: data
              ), baseline.revision >= 0 else {
            throw RemoteSyncWorkspaceSnapshotError.invalidAcceptedBaseline
        }
        return baseline
    }

    /**
     Reads the durable accepted-row manifest used for deletion detection.

     - Parameter settingsStore: Local-only settings store containing the manifest.
     - Returns: Accepted identities keyed by Android composite key, or `nil` when no manifest has
       ever been published for workspaces.
     - Side effects: Reads one local setting row.
     - Throws: `RemoteSyncWorkspaceSnapshotError.invalidAcceptedBaseline` when stored JSON is
       malformed; callers fail closed rather than forgetting accepted rows.
     */
    func acceptedRowsByKey(
        settingsStore: SettingsStore
    ) throws -> [String: RemoteSyncWorkspaceAcceptedRowIdentity]? {
        try storedAcceptedBaseline(settingsStore: settingsStore)?.generation.rowsByKey
    }

    /**
     Atomically stages workspace fingerprints and identities from one immutable generation.

     - Parameters:
       - generation: Immutable fingerprints and row identities that were restored, replayed, or uploaded.
       - settingsStore: Local-only settings store receiving the accepted baseline.
     - Side effects: Replaces all workspace fingerprint settings and the accepted-row manifest.
     - Throws:
       - `RemoteSyncWorkspaceSnapshotError.incompleteAcceptedGeneration` when a fingerprint lacks a
         matching identity
       - rethrows JSON encoding failures
       - settings persistence failures invalidate the enclosing atomic batch
     */
    @discardableResult
    func acceptBaselineFingerprints(
        _ generation: RemoteSyncWorkspaceAcceptedGeneration,
        settingsStore: SettingsStore,
        expectedRevision: Int64? = nil
    ) throws -> Int64 {
        let currentBaseline = try storedAcceptedBaseline(settingsStore: settingsStore)
        let currentRevision = currentBaseline?.revision ?? 0
        if let expectedRevision, expectedRevision != currentRevision {
            throw RemoteSyncWorkspaceSnapshotError.staleAcceptedBaseline(
                expected: expectedRevision,
                actual: currentRevision
            )
        }

        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let fingerprintPrefix = fingerprintStore.prefix(for: .workspaces)
        let logPrefix = logEntryStore.prefix(for: .workspaces)
        for entry in settingsStore.entries(withPrefix: fingerprintPrefix) {
            let suffix = String(entry.key.dropFirst(fingerprintPrefix.count))
            let logKey = "\(logPrefix)\(suffix)"
            if !generation.suppressedKeys.contains(logKey) {
                settingsStore.remove(entry.key)
            }
        }
        for (key, fingerprint) in generation.fingerprintsByKey.sorted(by: { $0.key < $1.key }) {
            guard let row = generation.rowsByKey[key] else {
                throw RemoteSyncWorkspaceSnapshotError.incompleteAcceptedGeneration(key)
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .workspaces,
                tableName: row.tableName,
                entityID1: row.entityID1,
                entityID2: row.entityID2
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let nextRevision = currentRevision + 1
        let manifestData = try encoder.encode(
            RemoteSyncWorkspaceAcceptedBaseline(
                revision: nextRevision,
                generation: generation
            )
        )
        settingsStore.setString(
            Self.acceptedBaselineKey,
            value: String(decoding: manifestData, as: UTF8.self)
        )
        return nextRevision
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
            canonicalTextDisplaySettings(
                value.textDisplaySettings,
                fidelity: value.textDisplayFidelity
            ),
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
            canonicalTextDisplaySettings(
                value.textDisplaySettings,
                fidelity: value.textDisplayFidelity
            ),
            value.jsState ?? "",
        ]
        let components = bibleComponents
            + commentaryComponents
            + dictionaryComponents
            + generalBookComponents
            + mapAndDisplayComponents
        return fingerprintHex(canonicalValue: components.joined(separator: "|"))
    }

    /** Computes one stable fingerprint for a workspace-label override row. */
    static func fingerprintHex(for value: RemoteSyncCurrentWorkspaceLabelOverrideRow) -> String {
        fingerprintHex(
            canonicalValue: [
                value.workspaceID.uuidString.lowercased(),
                value.labelID.uuidString.lowercased(),
                canonicalOptionalInt(value.overrideMode),
            ].joined(separator: "|")
        )
    }

    /** Computes one stable fingerprint for the global text-display singleton row. */
    static func fingerprintHex(for value: RemoteSyncCurrentGlobalTextDisplaySettingsRow) -> String {
        fingerprintHex(
            canonicalValue: [
                value.id.uuidString.lowercased(),
                canonicalTextDisplaySettings(
                    value.textDisplaySettings,
                    fidelity: value.fidelity
                ),
            ].joined(separator: "|")
        )
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
    static func canonicalTextDisplaySettings(
        _ value: TextDisplaySettings?,
        fidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity = .init()
    ) -> String {
        RemoteSyncWorkspaceTextDisplaySettingsWire(
            settings: value,
            fidelity: fidelity
        ).canonicalString()
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
            canonicalBool(normalizedValue.restoreButtonsVisible),
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
