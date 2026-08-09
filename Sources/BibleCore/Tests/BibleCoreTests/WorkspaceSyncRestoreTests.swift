import CLibSword
import XCTest
@testable import BibleCore
import SwiftData
import SQLite3

/// SQLite transient destructor used when binding Swift-owned text/blob buffers in test fixtures.
private let workspaceSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Regression coverage for Android workspace restore and patch replay.

 The suite exercises four boundaries:
 - snapshot parsing from Android-shaped SQLite databases
 - destructive replacement of the local SwiftData workspace graph
 - preservation of Android-only fidelity payloads that do not map directly onto iOS models
 - incremental patch replay against the preserved Android `LogEntry` baseline

 Test dependencies:
 - isolated in-memory SwiftData containers are created for ordinary behavior tests
 - file-backed graph/settings stores are used for durable rollback assertions
 - temporary SQLite fixture databases are created under `FileManager.default.temporaryDirectory`

 Side effects:
 - tests create and delete temporary SQLite/SwiftData files
 - restore tests mutate isolated SwiftData graphs and local-only `SettingsStore` rows

 Failure modes:
 - helper fixture builders fail the test immediately when they cannot create valid Android-shaped
   SQLite databases
 */
final class WorkspaceSyncRestoreTests: XCTestCase {
    /**
     Persistent-store side that should reject the workspace restore's sole final save.

     Running the rollback contract against both cases pins cross-store atomicity independently of
     SwiftData's internal persistent-store commit order.
     */
    private enum RejectedWorkspaceRestoreStore: CaseIterable {
        /// Cloud-shaped store containing the workspace relationship graph.
        case graph

        /// Local store containing fidelity aliases and active-workspace settings.
        case settings

        /// Human-readable store name included in XCTest activity diagnostics.
        var displayName: String {
            switch self {
            case .graph:
                return "workspace graph store"
            case .settings:
                return "local settings store"
            }
        }

        /// Stable fixture-directory component used to isolate each commit-order direction.
        var fixtureDirectoryName: String {
            switch self {
            case .graph:
                return "graph-rejected"
            case .settings:
                return "settings-rejected"
            }
        }
    }

    /**
     Verifies that preserved Android `LogEntry` rows can be queried and cleared per category.
     */
    func testRemoteSyncLogEntryStorePersistsAndClearsEntries() throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let store = RemoteSyncLogEntryStore(settingsStore: settingsStore)

        let workspaceEntry = RemoteSyncLogEntry(
            tableName: "Workspace",
            entityID1: .blob(uuidBlob(UUID(uuidString: "c0500000-0000-0000-0000-000000000001")!)),
            entityID2: .text(""),
            type: .upsert,
            lastUpdated: 1_735_689_600_000,
            sourceDevice: "pixel"
        )
        let bookmarkEntry = RemoteSyncLogEntry(
            tableName: "Label",
            entityID1: .blob(uuidBlob(UUID(uuidString: "c0500000-0000-0000-0000-000000000002")!)),
            entityID2: .text(""),
            type: .delete,
            lastUpdated: 1_735_689_700_000,
            sourceDevice: "tablet"
        )

        store.addEntry(workspaceEntry, for: .workspaces)
        store.addEntry(bookmarkEntry, for: .bookmarks)

        XCTAssertEqual(
            store.entry(
                for: .workspaces,
                tableName: "Workspace",
                entityID1: workspaceEntry.entityID1,
                entityID2: workspaceEntry.entityID2
            ),
            workspaceEntry
        )
        XCTAssertEqual(store.entries(for: .workspaces), [workspaceEntry])
        XCTAssertEqual(store.entries(for: .bookmarks), [bookmarkEntry])

        store.clearCategory(.workspaces)

        XCTAssertTrue(store.entries(for: .workspaces).isEmpty)
        XCTAssertEqual(store.entries(for: .bookmarks), [bookmarkEntry])
    }

    func testRemoteSyncWorkspaceFidelityStorePersistsAndClearsEntries() throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let store = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)

        let workspaceID = UUID(uuidString: "c1000000-0000-0000-0000-000000000001")!
        let windowID = UUID(uuidString: "c1000000-0000-0000-0000-000000000002")!
        let localHistoryItemID = UUID(uuidString: "c1000000-0000-0000-0000-000000000003")!

        store.setSpeakSettingsJSON(#"{"sleepTimer":10}"#, for: workspaceID)
        store.setPageManagerEntry(
            .init(
                windowID: windowID,
                rawCurrentCategoryName: "MYNOTE",
                commentarySourceBookAndKey: "GEN.1.1",
                dictionaryAnchorOrdinal: 12,
                generalBookAnchorOrdinal: 34,
                mapAnchorOrdinal: 56
            )
        )
        store.setHistoryItemAlias(remoteHistoryItemID: 77, localHistoryItemID: localHistoryItemID)

        XCTAssertEqual(store.speakSettingsJSON(for: workspaceID), #"{"sleepTimer":10}"#)
        XCTAssertEqual(
            store.pageManagerEntry(for: windowID),
            .init(
                windowID: windowID,
                rawCurrentCategoryName: "MYNOTE",
                commentarySourceBookAndKey: "GEN.1.1",
                dictionaryAnchorOrdinal: 12,
                generalBookAnchorOrdinal: 34,
                mapAnchorOrdinal: 56
            )
        )
        XCTAssertEqual(store.localHistoryItemID(for: 77), localHistoryItemID)
        XCTAssertEqual(
            store.allWorkspaceEntries(),
            [
                .init(workspaceID: workspaceID, speakSettingsJSON: #"{"sleepTimer":10}"#)
            ]
        )
        XCTAssertEqual(
            store.allPageManagerEntries(),
            [
                .init(
                    windowID: windowID,
                    rawCurrentCategoryName: "MYNOTE",
                    commentarySourceBookAndKey: "GEN.1.1",
                    dictionaryAnchorOrdinal: 12,
                    generalBookAnchorOrdinal: 34,
                    mapAnchorOrdinal: 56
                )
            ]
        )
        XCTAssertEqual(
            store.allHistoryItemAliases(),
            [
                .init(remoteHistoryItemID: 77, localHistoryItemID: localHistoryItemID)
            ]
        )

        store.clearAll()
        XCTAssertTrue(store.allWorkspaceEntries().isEmpty)
        XCTAssertTrue(store.allPageManagerEntries().isEmpty)
        XCTAssertTrue(store.allHistoryItemAliases().isEmpty)
        XCTAssertNil(store.speakSettingsJSON(for: workspaceID))
        XCTAssertNil(store.pageManagerEntry(for: windowID))
        XCTAssertNil(store.localHistoryItemID(for: 77))
    }

    func testRemoteSyncWorkspaceRestoreReadsAndroidSnapshot() throws {
        let service = RemoteSyncWorkspaceRestoreService()
        let workspaceID = UUID(uuidString: "c2000000-0000-0000-0000-000000000001")!
        let windowID = UUID(uuidString: "c2000000-0000-0000-0000-000000000002")!
        let hiddenLabelID = UUID(uuidString: "c2000000-0000-0000-0000-000000000003")!
        let recentLabelID = UUID(uuidString: "c2000000-0000-0000-0000-000000000004")!
        let autoAssignLabelID = UUID(uuidString: "c2000000-0000-0000-0000-000000000005")!
        let cursorLabelID = UUID(uuidString: "c2000000-0000-0000-0000-000000000006")!
        let primaryLabelID = UUID(uuidString: "c2000000-0000-0000-0000-000000000007")!

        let databaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(
                    id: workspaceID,
                    name: "Travel",
                    contentsText: "Genesis study",
                    orderNumber: 2,
                    textDisplaySettings: .init(
                        strongsMode: 1,
                        showFootNotesInline: true,
                        fontSize: 24,
                        fontFamily: "serif",
                        lineSpacing: 18,
                        bookmarksHideLabelsJSON: #"["\#(hiddenLabelID.uuidString)"]"#,
                        marginLeft: 7,
                        marginRight: 8,
                        maxWidth: 640,
                        dayBackground: Int(Int32(bitPattern: 0xFFF5F0E6)),
                        nightBackground: Int(Int32(bitPattern: 0xFF111111))
                    ),
                    workspaceSettings: .init(
                        enableTiltToScroll: true,
                        enableReverseSplitMode: true,
                        autoPin: false,
                        restoreButtonsVisible: false,
                        speakSettingsJSON: #"{"sleepTimer":15,"queue":true}"#,
                        recentLabelsJSON: #"[{"labelId":"\#(recentLabelID.uuidString)","lastAccess":1735689600000}]"#,
                        autoAssignLabelsJSON: #"["\#(autoAssignLabelID.uuidString)"]"#,
                        autoAssignPrimaryLabelID: primaryLabelID,
                        studyPadCursorsJSON: #"{"\#(cursorLabelID.uuidString)":5}"#,
                        hideCompareDocumentsJSON: #"["ESV","NET"]"#,
                        limitAmbiguousModalSize: true,
                        workspaceColor: Int(Int32(bitPattern: 0xFF444444))
                    ),
                    unPinnedWeight: 1.25,
                    maximizedWindowID: windowID,
                    primaryTargetLinksWindowID: windowID
                )
            ],
            windows: [
                .init(
                    id: windowID,
                    workspaceID: workspaceID,
                    isSynchronized: true,
                    isPinMode: false,
                    isLinksWindow: true,
                    orderNumber: 0,
                    syncGroup: 3,
                    layoutState: "split",
                    layoutWeight: 1.5
                )
            ],
            pageManagers: [
                .init(
                    windowID: windowID,
                    bibleDocument: "KJV",
                    bibleVersification: "KJVA",
                    bibleBook: 0,
                    bibleChapterNo: 1,
                    bibleVerseNo: 1,
                    commentaryDocument: "MHC",
                    commentaryAnchorOrdinal: 12,
                    commentarySourceBookAndKey: "GEN.1.1",
                    dictionaryDocument: "StrongsHebrew",
                    dictionaryKey: "H02022",
                    dictionaryAnchorOrdinal: 21,
                    generalBookDocument: "Josephus",
                    generalBookKey: "Ant.1.1",
                    generalBookAnchorOrdinal: 31,
                    mapDocument: "Maps",
                    mapKey: "Jerusalem",
                    mapAnchorOrdinal: 41,
                    currentCategoryName: "MYNOTE",
                    textDisplaySettings: .init(
                        showVersePerLine: true,
                        showBookmarks: false,
                        topMargin: 4,
                        bookmarksHideLabelsJSON: #"["\#(hiddenLabelID.uuidString)"]"#,
                        dayTextColor: Int(Int32(bitPattern: 0xFF000000)),
                        nightTextColor: Int(Int32(bitPattern: 0xFFFFFFFF))
                    ),
                    jsState: #"{"scroll":120}"#
                )
            ],
            historyItems: [
                .init(
                    remoteID: 77,
                    windowID: windowID,
                    createdAt: Date(timeIntervalSince1970: 1_735_689_600),
                    document: "KJV",
                    key: "Gen.1.1",
                    anchorOrdinal: 101
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let snapshot = try service.readSnapshot(from: databaseURL)

        XCTAssertEqual(snapshot.workspaces.count, 1)
        let workspace = try XCTUnwrap(snapshot.workspaces.first)
        XCTAssertEqual(workspace.id, workspaceID)
        XCTAssertEqual(workspace.name, "Travel")
        XCTAssertEqual(workspace.contentsText, "Genesis study")
        XCTAssertEqual(workspace.orderNumber, 2)
        XCTAssertEqual(workspace.unPinnedWeight, 1.25)
        XCTAssertEqual(workspace.maximizedWindowID, windowID)
        XCTAssertEqual(workspace.primaryTargetLinksWindowID, windowID)
        XCTAssertEqual(workspace.workspaceColor, Int(Int32(bitPattern: 0xFF444444)))
        XCTAssertEqual(workspace.speakSettingsJSON, #"{"sleepTimer":15,"queue":true}"#)
        XCTAssertEqual(workspace.textDisplaySettings?.fontFamily, "serif")
        XCTAssertEqual(workspace.textDisplaySettings?.fontSize, 24)
        XCTAssertEqual(workspace.textDisplaySettings?.bookmarksHideLabels, [hiddenLabelID])
        XCTAssertEqual(workspace.workspaceSettings.recentLabels.count, 1)
        XCTAssertEqual(workspace.workspaceSettings.recentLabels.first?.labelId, recentLabelID)
        XCTAssertEqual(
            workspace.workspaceSettings.recentLabels.first?.lastAccess,
            Date(timeIntervalSince1970: 1_735_689_600)
        )
        XCTAssertEqual(workspace.workspaceSettings.autoAssignLabels, [autoAssignLabelID])
        XCTAssertEqual(workspace.workspaceSettings.autoAssignPrimaryLabel, autoAssignLabelID)
        XCTAssertEqual(workspace.workspaceSettings.studyPadCursors, [cursorLabelID: 5])
        XCTAssertEqual(workspace.workspaceSettings.hideCompareDocuments, ["ESV", "NET"])
        XCTAssertTrue(workspace.workspaceSettings.enableTiltToScroll)
        XCTAssertTrue(workspace.workspaceSettings.enableReverseSplitMode)
        XCTAssertFalse(workspace.workspaceSettings.autoPin)
        XCTAssertFalse(workspace.workspaceSettings.restoreButtonsVisible)
        XCTAssertTrue(workspace.workspaceSettings.limitAmbiguousModalSize)

        XCTAssertEqual(workspace.windows.count, 1)
        let window = try XCTUnwrap(workspace.windows.first)
        XCTAssertEqual(window.id, windowID)
        XCTAssertEqual(window.syncGroup, 3)
        XCTAssertEqual(window.layoutState, "split")
        XCTAssertEqual(window.layoutWeight, 1.5)
        XCTAssertTrue(window.isLinksWindow)
        XCTAssertEqual(window.pageManager.currentCategoryName, "MYNOTE")
        XCTAssertEqual(window.pageManager.commentarySourceBookAndKey, "GEN.1.1")
        XCTAssertEqual(window.pageManager.dictionaryAnchorOrdinal, 21)
        XCTAssertEqual(window.pageManager.generalBookAnchorOrdinal, 31)
        XCTAssertEqual(window.pageManager.mapAnchorOrdinal, 41)
        XCTAssertEqual(window.pageManager.textDisplaySettings?.showVersePerLine, true)
        XCTAssertEqual(window.pageManager.textDisplaySettings?.bookmarksHideLabels, [hiddenLabelID])
        XCTAssertEqual(window.pageManager.jsState, #"{"scroll":120}"#)
        XCTAssertEqual(window.historyItems, [
            .init(
                remoteID: 77,
                windowID: windowID,
                createdAt: Date(timeIntervalSince1970: 1_735_689_600),
                document: "KJV",
                key: "Gen.1.1",
                anchorOrdinal: 101
            )
        ])
    }

    /**
     Verifies restore clears an incoming auto-assign primary label when Android data has no auto-assigned labels.
     */
    func testRemoteSyncWorkspaceRestoreClearsAutoAssignPrimaryLabelWhenNoAutoAssignLabelsRemain() throws {
        let service = RemoteSyncWorkspaceRestoreService()
        let workspaceID = UUID(uuidString: "c2200000-0000-0000-0000-000000000001")!
        let orphanPrimaryLabelID = UUID(uuidString: "c2200000-0000-0000-0000-000000000002")!
        let databaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(
                    id: workspaceID,
                    name: "No Auto Labels",
                    orderNumber: 0,
                    workspaceSettings: .init(autoAssignPrimaryLabelID: orphanPrimaryLabelID)
                )
            ],
            windows: [],
            pageManagers: [],
            historyItems: []
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let snapshot = try service.readSnapshot(from: databaseURL)

        let workspace = try XCTUnwrap(snapshot.workspaces.first)
        XCTAssertTrue(workspace.workspaceSettings.autoAssignLabels.isEmpty)
        XCTAssertNil(workspace.workspaceSettings.autoAssignPrimaryLabel)
    }

    /**
     Verifies restore preserves an incoming auto-assign primary label when it is still auto-assigned.
     */
    func testRemoteSyncWorkspaceRestorePreservesAssignedAutoAssignPrimaryLabel() throws {
        let service = RemoteSyncWorkspaceRestoreService()
        let workspaceID = UUID(uuidString: "c2200000-0000-0000-0000-000000000003")!
        let firstAssignedLabelID = UUID(uuidString: "c2200000-0000-0000-0000-000000000004")!
        let primaryLabelID = UUID(uuidString: "c2200000-0000-0000-0000-000000000005")!
        let databaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(
                    id: workspaceID,
                    name: "Valid Auto Labels",
                    orderNumber: 0,
                    workspaceSettings: .init(
                        autoAssignLabelsJSON: #"["\#(firstAssignedLabelID.uuidString)","\#(primaryLabelID.uuidString)"]"#,
                        autoAssignPrimaryLabelID: primaryLabelID
                    )
                )
            ],
            windows: [],
            pageManagers: [],
            historyItems: []
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let snapshot = try service.readSnapshot(from: databaseURL)

        let workspace = try XCTUnwrap(snapshot.workspaces.first)
        XCTAssertEqual(workspace.workspaceSettings.autoAssignLabels, [firstAssignedLabelID, primaryLabelID])
        XCTAssertEqual(workspace.workspaceSettings.autoAssignPrimaryLabel, primaryLabelID)
    }

    /**
     Verifies outbound workspace snapshots repair stale local auto-assign primary-label state before fingerprinting.
     */
    func testRemoteSyncWorkspaceSnapshotNormalizesInvalidAutoAssignPrimaryLabelBeforeFingerprinting() throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let service = RemoteSyncWorkspaceSnapshotService()
        let workspaceID = UUID(uuidString: "c2200000-0000-0000-0000-000000000006")!
        let assignedLabelID = UUID(uuidString: "c2200000-0000-0000-0000-000000000007")!
        let orphanPrimaryLabelID = UUID(uuidString: "c2200000-0000-0000-0000-000000000008")!
        let workspace = Workspace(id: workspaceID, name: "Local Stale Settings", orderNumber: 0)
        var workspaceSettings = WorkspaceSettings(autoAssignLabels: [assignedLabelID])
        workspaceSettings.autoAssignPrimaryLabel = orphanPrimaryLabelID
        workspace.workspaceSettings = workspaceSettings
        modelContext.insert(workspace)
        try modelContext.save()

        let snapshot = service.snapshotCurrentState(modelContext: modelContext, settingsStore: settingsStore)

        let workspaceRow = try XCTUnwrap(snapshot.workspaceRowsByKey.values.first)
        XCTAssertEqual(workspaceRow.workspaceSettings.autoAssignLabels, [assignedLabelID])
        XCTAssertEqual(workspaceRow.workspaceSettings.autoAssignPrimaryLabel, assignedLabelID)
        let canonicalComponents = RemoteSyncWorkspaceSnapshotService.canonicalWorkspaceSettings(workspaceRow.workspaceSettings)
            .split(separator: "^", omittingEmptySubsequences: false)
        XCTAssertEqual(canonicalComponents[6], Substring(assignedLabelID.uuidString.lowercased()))
        XCTAssertFalse(canonicalComponents.contains(Substring(orphanPrimaryLabelID.uuidString.lowercased())))
    }

    /**
     Verifies a successful Android workspace restore publishes the complete graph and fidelity state
     through exactly one durable model-context save.

     The fixture includes two windows, page managers, history aliases, raw Android fidelity fields,
     and active-workspace metadata. A `ModelContext.didSave` expectation rejects the former sequence
     of graph deletion, graph insertion, and per-setting commits, while post-save values prove the one
     accepted save contains every required relationship and metadata value.

     - Side effects: Mutates an isolated in-memory SwiftData container and installs a scoped save
       notification observer that is removed when the test returns.
     - Failure meaning: A failure indicates workspace restore can expose an incomplete graph or
       metadata generation instead of Android's category-wide replacement behavior.
     */
    func testRemoteSyncWorkspaceRestoreReplacesLocalWorkspacesAndPreservesAndroidFidelity() throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let service = RemoteSyncWorkspaceRestoreService()

        let legacyWorkspace = Workspace(
            id: UUID(uuidString: "c3000000-0000-0000-0000-000000000001")!,
            name: "Legacy",
            orderNumber: 0
        )
        modelContext.insert(legacyWorkspace)
        try modelContext.save()

        let restoredWorkspaceID = UUID(uuidString: "c3000000-0000-0000-0000-000000000010")!
        let firstWindowID = UUID(uuidString: "c3000000-0000-0000-0000-000000000011")!
        let secondWindowID = UUID(uuidString: "c3000000-0000-0000-0000-000000000012")!
        let hiddenLabelID = UUID(uuidString: "c3000000-0000-0000-0000-000000000013")!
        let recentLabelID = UUID(uuidString: "c3000000-0000-0000-0000-000000000014")!
        let autoAssignLabelID = UUID(uuidString: "c3000000-0000-0000-0000-000000000015")!
        let cursorLabelID = UUID(uuidString: "c3000000-0000-0000-0000-000000000016")!
        let primaryLabelID = UUID(uuidString: "c3000000-0000-0000-0000-000000000017")!

        settingsStore.activeWorkspaceId = restoredWorkspaceID

        let databaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(
                    id: restoredWorkspaceID,
                    name: "Restored Workspace",
                    contentsText: "Parallel study",
                    orderNumber: 1,
                    textDisplaySettings: .init(
                        strongsMode: 2,
                        showBookmarks: true,
                        showMyNotes: true,
                        fontSize: 22,
                        bookmarksHideLabelsJSON: #"["\#(hiddenLabelID.uuidString)"]"#,
                        dayBackground: Int(Int32(bitPattern: 0xFFF8F1E7))
                    ),
                    workspaceSettings: .init(
                        enableTiltToScroll: true,
                        enableReverseSplitMode: false,
                        autoPin: false,
                        speakSettingsJSON: #"{"playbackSettings":{"speed":115},"sleepTimer":20}"#,
                        recentLabelsJSON: #"[{"labelId":"\#(recentLabelID.uuidString)","lastAccess":1735689600000}]"#,
                        autoAssignLabelsJSON: #"["\#(autoAssignLabelID.uuidString)"]"#,
                        autoAssignPrimaryLabelID: primaryLabelID,
                        studyPadCursorsJSON: #"{"\#(cursorLabelID.uuidString)":9}"#,
                        hideCompareDocumentsJSON: #"["ESV"]"#,
                        limitAmbiguousModalSize: true,
                        workspaceColor: Int(Int32(bitPattern: 0xFF335577))
                    ),
                    unPinnedWeight: 0.75,
                    maximizedWindowID: firstWindowID,
                    primaryTargetLinksWindowID: secondWindowID
                )
            ],
            windows: [
                .init(
                    id: firstWindowID,
                    workspaceID: restoredWorkspaceID,
                    isSynchronized: true,
                    isPinMode: false,
                    isLinksWindow: false,
                    orderNumber: 0,
                    targetLinksWindowID: secondWindowID,
                    syncGroup: 1,
                    layoutState: "split",
                    layoutWeight: 1.0
                ),
                .init(
                    id: secondWindowID,
                    workspaceID: restoredWorkspaceID,
                    isSynchronized: false,
                    isPinMode: true,
                    isLinksWindow: true,
                    orderNumber: 1,
                    syncGroup: 2,
                    layoutState: "minimized",
                    layoutWeight: 0.4
                )
            ],
            pageManagers: [
                .init(
                    windowID: firstWindowID,
                    bibleDocument: "KJV",
                    bibleVersification: "KJVA",
                    bibleBook: 0,
                    bibleChapterNo: 2,
                    bibleVerseNo: 3,
                    commentaryDocument: "MHC",
                    commentaryAnchorOrdinal: 11,
                    commentarySourceBookAndKey: "EXOD.2.3",
                    dictionaryDocument: "StrongsHebrew",
                    dictionaryKey: "H02022",
                    dictionaryAnchorOrdinal: 21,
                    generalBookDocument: "Josephus",
                    generalBookKey: "Ant.1.1",
                    generalBookAnchorOrdinal: 31,
                    mapDocument: "Maps",
                    mapKey: "Jerusalem",
                    mapAnchorOrdinal: 41,
                    currentCategoryName: "GENERAL_BOOK",
                    textDisplaySettings: .init(showFootNotes: false, showVersePerLine: true),
                    jsState: #"{"scroll":50}"#
                ),
                .init(
                    windowID: secondWindowID,
                    bibleDocument: "ESV",
                    bibleVersification: "KJVA",
                    bibleBook: 1,
                    bibleChapterNo: 4,
                    bibleVerseNo: 5,
                    commentaryDocument: "TSK",
                    commentaryAnchorOrdinal: 22,
                    commentarySourceBookAndKey: "MATT.5.3",
                    dictionaryDocument: "Easton",
                    dictionaryKey: "Grace",
                    dictionaryAnchorOrdinal: 24,
                    generalBookDocument: "Calvin",
                    generalBookKey: "Commentary.1",
                    generalBookAnchorOrdinal: 34,
                    mapDocument: "Maps",
                    mapKey: "Galilee",
                    mapAnchorOrdinal: 44,
                    currentCategoryName: "MYNOTE",
                    textDisplaySettings: .init(showBookmarks: false, topMargin: 3),
                    jsState: #"{"scroll":75}"#
                )
            ],
            historyItems: [
                .init(
                    remoteID: 101,
                    windowID: firstWindowID,
                    createdAt: Date(timeIntervalSince1970: 1_735_689_600),
                    document: "KJV",
                    key: "Exod.2.3",
                    anchorOrdinal: 201
                ),
                .init(
                    remoteID: 102,
                    windowID: secondWindowID,
                    createdAt: Date(timeIntervalSince1970: 1_735_689_700),
                    document: "ESV",
                    key: "Matt.5.3",
                    anchorOrdinal: 202
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let snapshot = try service.readSnapshot(from: databaseURL)
        let saveExpectation = expectation(description: "Workspace restore performs one durable save")
        saveExpectation.expectedFulfillmentCount = 1
        saveExpectation.assertForOverFulfill = true
        let saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: modelContext,
            queue: nil
        ) { _ in
            saveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(saveObserver) }

        let report = try service.replaceLocalWorkspaces(
            from: snapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        wait(for: [saveExpectation], timeout: 1)

        XCTAssertEqual(
            report,
            RemoteSyncWorkspaceRestoreReport(
                restoredWorkspaceCount: 1,
                restoredWindowCount: 2,
                restoredHistoryItemCount: 2,
                preservedWorkspaceFidelityCount: 1,
                preservedPageManagerFidelityCount: 2,
                preservedHistoryItemAliasCount: 2
            )
        )

        let workspaces = try modelContext.fetch(FetchDescriptor<Workspace>())
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces[0].id, restoredWorkspaceID)
        XCTAssertEqual(workspaces[0].name, "Restored Workspace")
        XCTAssertEqual(workspaces[0].contentsText, "Parallel study")
        XCTAssertEqual(workspaces[0].unPinnedWeight, 0.75)
        XCTAssertEqual(workspaces[0].maximizedWindowId, firstWindowID)
        XCTAssertEqual(workspaces[0].primaryTargetLinksWindowId, secondWindowID)
        XCTAssertEqual(workspaces[0].workspaceColor, Int(Int32(bitPattern: 0xFF335577)))
        XCTAssertEqual(workspaces[0].workspaceSettings?.recentLabels.count, 1)
        XCTAssertEqual(workspaces[0].workspaceSettings?.recentLabels.first?.labelId, recentLabelID)
        XCTAssertEqual(
            workspaces[0].workspaceSettings?.recentLabels.first?.lastAccess,
            Date(timeIntervalSince1970: 1_735_689_600)
        )
        XCTAssertEqual(workspaces[0].workspaceSettings?.autoAssignLabels, [autoAssignLabelID])
        XCTAssertEqual(workspaces[0].workspaceSettings?.autoAssignPrimaryLabel, autoAssignLabelID)
        XCTAssertEqual(workspaces[0].workspaceSettings?.studyPadCursors, [cursorLabelID: 9])
        XCTAssertEqual(workspaces[0].workspaceSettings?.hideCompareDocuments, ["ESV"])
        XCTAssertEqual(workspaces[0].textDisplaySettings?.bookmarksHideLabels, [hiddenLabelID])

        let windows = try modelContext.fetch(FetchDescriptor<Window>()).sorted { $0.orderNumber < $1.orderNumber }
        XCTAssertEqual(windows.map(\.id), [firstWindowID, secondWindowID])
        XCTAssertEqual(windows[0].targetLinksWindowId, secondWindowID)
        XCTAssertEqual(windows[1].layoutState, "minimized")

        let pageManagers = try modelContext.fetch(FetchDescriptor<PageManager>()).sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(pageManagers.count, 2)
        XCTAssertEqual(pageManagers.first(where: { $0.id == firstWindowID })?.currentCategoryName, "general_book")
        // Android MYNOTE windows restore into iOS's `mynote` page-manager key so the reader
        // reopens the My Notes page instead of collapsing the window to the Bible text.
        XCTAssertEqual(pageManagers.first(where: { $0.id == secondWindowID })?.currentCategoryName, "mynote")
        XCTAssertEqual(pageManagers.first(where: { $0.id == firstWindowID })?.generalBookDocument, "Josephus")
        XCTAssertEqual(pageManagers.first(where: { $0.id == secondWindowID })?.commentaryDocument, "TSK")

        let historyItems = try modelContext.fetch(FetchDescriptor<HistoryItem>()).sorted { $0.createdAt < $1.createdAt }
        XCTAssertEqual(historyItems.count, 2)
        XCTAssertEqual(historyItems.map(\.document), ["KJV", "ESV"])
        XCTAssertEqual(historyItems.map(\.key), ["Exod.2.3", "Matt.5.3"])

        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        XCTAssertEqual(
            fidelityStore.allWorkspaceEntries(),
            [
                .init(
                    workspaceID: restoredWorkspaceID,
                    speakSettingsJSON: #"{"playbackSettings":{"speed":115},"sleepTimer":20}"#
                )
            ]
        )
        XCTAssertEqual(
            fidelityStore.allPageManagerEntries(),
            [
                .init(
                    windowID: firstWindowID,
                    rawCurrentCategoryName: "GENERAL_BOOK",
                    commentarySourceBookAndKey: "EXOD.2.3",
                    dictionaryAnchorOrdinal: 21,
                    generalBookAnchorOrdinal: 31,
                    mapAnchorOrdinal: 41
                ),
                .init(
                    windowID: secondWindowID,
                    rawCurrentCategoryName: "MYNOTE",
                    commentarySourceBookAndKey: "MATT.5.3",
                    dictionaryAnchorOrdinal: 24,
                    generalBookAnchorOrdinal: 34,
                    mapAnchorOrdinal: 44
                )
            ]
        )
        let historyAliases = fidelityStore.allHistoryItemAliases()
        XCTAssertEqual(historyAliases.map(\.remoteHistoryItemID), [101, 102])
        XCTAssertEqual(Set(historyAliases.map(\.localHistoryItemID)), Set(historyItems.map(\.id)))
        XCTAssertEqual(settingsStore.activeWorkspaceId, restoredWorkspaceID)
    }

    /**
     Verifies a failed final workspace publish preserves the complete previously durable generation.

     The test seeds a file-backed workspace/window/page-manager/history graph plus fidelity and active
     workspace settings, then independently rejects writes in the graph store and the local settings
     store. Each restore can read and stage its replacement, but its sole final save must fail.
     Reopening both stores after each direction must reveal only the old graph and old metadata,
     matching Android's graph-level database replacement guarantee.

     - Side effects: Creates two temporary SwiftData SQLite stores, reopens each target configuration
       read-only in turn, observes each attempted final save, and deletes the fixture afterward.
     - Determinism: SwiftData's `allowsSave: false` configuration rejects the selected persistent
       store without locks or schema mutation, while `willSave` proves final persistence was attempted.
     - Failure meaning: A failure indicates restore can durably publish a partial replacement or lose
       the user's prior workspace generation when persistence fails.
     */
    func testRemoteSyncWorkspaceRestorePreservesOldGenerationWhenFinalSaveFails() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceAtomicRestore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let seedDirectory = temporaryDirectory.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.createDirectory(at: seedDirectory, withIntermediateDirectories: true)

        let oldWorkspaceID = UUID(uuidString: "c3100000-0000-0000-0000-000000000001")!
        let oldWindowID = UUID(uuidString: "c3100000-0000-0000-0000-000000000002")!
        let oldHistoryID = UUID(uuidString: "c3100000-0000-0000-0000-000000000003")!
        try autoreleasepool {
            let persistentStore = try makePersistentWorkspaceRestoreModelContainer(in: seedDirectory)
            let modelContext = ModelContext(persistentStore.container)
            modelContext.autosaveEnabled = false
            let settingsStore = SettingsStore(modelContext: modelContext)
            let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)

            let oldWorkspace = Workspace(id: oldWorkspaceID, name: "Durable Workspace", orderNumber: 0)
            oldWorkspace.contentsText = "Keep this graph"
            oldWorkspace.workspaceSettings = WorkspaceSettings(enableTiltToScroll: true)
            let oldWindow = Window(
                id: oldWindowID,
                isSynchronized: true,
                isPinMode: true,
                isLinksWindow: false,
                orderNumber: 0,
                syncGroup: 7,
                layoutWeight: 1,
                layoutState: "split"
            )
            oldWindow.workspace = oldWorkspace
            let oldPageManager = PageManager(id: oldWindowID, currentCategoryName: "commentary")
            oldPageManager.window = oldWindow
            oldPageManager.commentaryDocument = "MHC"
            oldPageManager.commentaryAnchorOrdinal = 123
            let oldHistory = HistoryItem(
                id: oldHistoryID,
                createdAt: Date(timeIntervalSince1970: 1_735_689_600),
                document: "KJV",
                key: "Gen.1.1"
            )
            oldHistory.window = oldWindow
            oldHistory.anchorOrdinal = 4
            modelContext.insert(oldWorkspace)
            modelContext.insert(oldWindow)
            modelContext.insert(oldPageManager)
            modelContext.insert(oldHistory)
            try modelContext.save()

            settingsStore.activeWorkspaceId = oldWorkspaceID
            fidelityStore.setSpeakSettingsJSON(#"{"sleepTimer":15}"#, for: oldWorkspaceID)
            fidelityStore.setPageManagerEntry(
                .init(
                    windowID: oldWindowID,
                    rawCurrentCategoryName: "COMMENTARY",
                    commentarySourceBookAndKey: "GEN.1.1",
                    dictionaryAnchorOrdinal: 11,
                    generalBookAnchorOrdinal: 12,
                    mapAnchorOrdinal: 13
                )
            )
            fidelityStore.setHistoryItemAlias(remoteHistoryItemID: 41, localHistoryItemID: oldHistoryID)
            XCTAssertFalse(modelContext.hasChanges)
        }

        let replacementWorkspaceID = UUID(uuidString: "c3100000-0000-0000-0000-000000000010")!
        let replacementWindowID = UUID(uuidString: "c3100000-0000-0000-0000-000000000011")!
        let replacementPageManager = RemoteSyncAndroidWorkspacePageManager(
            windowID: replacementWindowID,
            bibleDocument: "ESV",
            bibleVersification: "KJVA",
            bibleBook: 0,
            bibleChapterNo: 2,
            bibleVerseNo: 3,
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
            jsState: #"{"scroll":75}"#
        )
        let replacementHistory = RemoteSyncAndroidWorkspaceHistoryItem(
            remoteID: 99,
            windowID: replacementWindowID,
            createdAt: Date(timeIntervalSince1970: 1_735_689_700),
            document: "ESV",
            key: "Exod.2.3",
            anchorOrdinal: 205
        )
        let replacementSnapshot = RemoteSyncAndroidWorkspaceSnapshot(
            workspaces: [
                RemoteSyncAndroidWorkspace(
                    id: replacementWorkspaceID,
                    name: "Replacement Workspace",
                    contentsText: "Must not publish partially",
                    orderNumber: 0,
                    textDisplaySettings: nil,
                    workspaceSettings: WorkspaceSettings(autoPin: true),
                    speakSettingsJSON: #"{"sleepTimer":30}"#,
                    unPinnedWeight: 0.5,
                    maximizedWindowID: replacementWindowID,
                    primaryTargetLinksWindowID: nil,
                    workspaceColor: Workspace.defaultWorkspaceColor,
                    windows: [
                        RemoteSyncAndroidWorkspaceWindow(
                            id: replacementWindowID,
                            workspaceID: replacementWorkspaceID,
                            isSynchronized: false,
                            isPinMode: false,
                            isLinksWindow: false,
                            orderNumber: 0,
                            targetLinksWindowID: nil,
                            syncGroup: 2,
                            layoutState: "maximized",
                            layoutWeight: 0.5,
                            pageManager: replacementPageManager,
                            historyItems: [replacementHistory]
                        )
                    ]
                )
            ]
        )

        for rejectedStore in RejectedWorkspaceRestoreStore.allCases {
            try XCTContext.runActivity(named: "Reject \(rejectedStore.displayName) writes") { _ in
                let caseDirectory = temporaryDirectory.appendingPathComponent(
                    rejectedStore.fixtureDirectoryName,
                    isDirectory: true
                )
                try FileManager.default.copyItem(at: seedDirectory, to: caseDirectory)
                try assertWorkspaceRestoreRollback(
                    whenRejecting: rejectedStore,
                    temporaryDirectory: caseDirectory,
                    replacementSnapshot: replacementSnapshot,
                    oldWorkspaceID: oldWorkspaceID,
                    oldWindowID: oldWindowID,
                    oldHistoryID: oldHistoryID,
                    replacementWorkspaceID: replacementWorkspaceID,
                    replacementWindowID: replacementWindowID
                )
            }
        }
    }

    /**
     Verifies patch replay publishes graph, conflict metadata, status, and fingerprints atomically.

     The test seeds a complete old workspace graph and old replay bookkeeping, then reopens each
     physical store read-only while applying a newer Android workspace patch. Reopening both stores
     writable after each rejected save must reveal the old graph and old metadata only.

     - Side effects: Creates two temporary SwiftData stores and one staged gzip patch archive, attempts
       replay once per rejected store, then reopens both stores for durable assertions.
     - Failure modes: Rethrows fixture setup or fetch failures. Assertions fail when patch replay does
       not reach one final save, leaves pending context changes, or publishes any mixed generation.
     */
    func testRemoteSyncWorkspacePatchPublishPreservesOldGenerationWhenEitherStoreRejectsSave() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceAtomicPatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let seedDirectory = temporaryDirectory.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.createDirectory(at: seedDirectory, withIntermediateDirectories: true)

        let workspaceID = UUID(uuidString: "c3200000-0000-0000-0000-000000000001")!
        let windowID = UUID(uuidString: "c3200000-0000-0000-0000-000000000002")!
        let historyID = UUID(uuidString: "c3200000-0000-0000-0000-000000000003")!
        let oldLogEntry = RemoteSyncLogEntry(
            tableName: "Workspace",
            entityID1: .blob(uuidBlob(workspaceID)),
            entityID2: .text(""),
            type: .upsert,
            lastUpdated: 100,
            sourceDevice: "ios-local"
        )
        let oldPatchStatus = RemoteSyncPatchStatus(
            sourceDevice: "pixel",
            patchNumber: 1,
            sizeBytes: 512,
            appliedDate: 90
        )

        try autoreleasepool {
            let persistentStore = try makePersistentWorkspaceRestoreModelContainer(in: seedDirectory)
            let modelContext = ModelContext(persistentStore.container)
            modelContext.autosaveEnabled = false
            let settingsStore = SettingsStore(modelContext: modelContext)

            let workspace = Workspace(id: workspaceID, name: "Durable Patch Workspace", orderNumber: 0)
            workspace.contentsText = "Keep patch generation"
            let window = Window(
                id: windowID,
                isSynchronized: true,
                isPinMode: false,
                isLinksWindow: false,
                orderNumber: 0,
                syncGroup: 3,
                layoutWeight: 1,
                layoutState: "split"
            )
            window.workspace = workspace
            let pageManager = PageManager(id: windowID, currentCategoryName: "bible")
            pageManager.window = window
            pageManager.bibleDocument = "KJV"
            pageManager.bibleVersification = "KJVA"
            pageManager.bibleChapterNo = 1
            pageManager.bibleVerseNo = 1
            let history = HistoryItem(
                id: historyID,
                createdAt: Date(timeIntervalSince1970: 1_735_689_600),
                document: "KJV",
                key: "Gen.1.1"
            )
            history.window = window
            history.anchorOrdinal = 4
            modelContext.insert(workspace)
            modelContext.insert(window)
            modelContext.insert(pageManager)
            modelContext.insert(history)
            try modelContext.save()

            settingsStore.activeWorkspaceId = workspaceID
            RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
                .setSpeakSettingsJSON(#"{"sleepTimer":15}"#, for: workspaceID)
            RemoteSyncLogEntryStore(settingsStore: settingsStore)
                .replaceEntries([oldLogEntry], for: .workspaces)
            RemoteSyncPatchStatusStore(settingsStore: settingsStore)
                .addStatus(oldPatchStatus, for: .workspaces)
            RemoteSyncRowFingerprintStore(settingsStore: settingsStore).setFingerprint(
                "durable-workspace-fingerprint",
                for: .workspaces,
                tableName: "Workspace",
                entityID1: .blob(uuidBlob(workspaceID)),
                entityID2: .text("")
            )
            XCTAssertFalse(modelContext.hasChanges)
        }

        let patchDatabaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(
                    id: workspaceID,
                    name: "Rejected Remote Workspace",
                    contentsText: "Must not publish",
                    orderNumber: 2,
                    workspaceSettings: .init(speakSettingsJSON: #"{"sleepTimer":30}"#)
                )
            ],
            windows: [],
            pageManagers: [],
            historyItems: [],
            logEntries: [
                .init(
                    tableName: "Workspace",
                    entityID1: .blob(uuidBlob(workspaceID)),
                    entityID2: .text(""),
                    type: "UPSERT",
                    lastUpdated: 200,
                    sourceDevice: "pixel"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }
        let stagedArchive = try makeWorkspacePatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "pixel",
            patchNumber: 2,
            fileTimestamp: 210
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        for rejectedStore in RejectedWorkspaceRestoreStore.allCases {
            try XCTContext.runActivity(named: "Reject patch publish to \(rejectedStore.displayName)") { _ in
                let caseDirectory = temporaryDirectory.appendingPathComponent(
                    rejectedStore.fixtureDirectoryName,
                    isDirectory: true
                )
                try FileManager.default.copyItem(at: seedDirectory, to: caseDirectory)
                try assertWorkspacePatchPublishRollback(
                    whenRejecting: rejectedStore,
                    temporaryDirectory: caseDirectory,
                    stagedArchive: stagedArchive,
                    workspaceID: workspaceID,
                    windowID: windowID,
                    historyID: historyID,
                    oldLogEntry: oldLogEntry,
                    oldPatchStatus: oldPatchStatus
                )
            }
        }
    }

    /**
     Verifies that Android `LogEntry` and `SyncStatus` rows are read faithfully and replace only the targeted category metadata.
     */
    func testRemoteSyncInitialBackupMetadataRestoreReadsAndReplacesAndroidMetadata() throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let service = RemoteSyncInitialBackupMetadataRestoreService()

        let workspaceID = UUID(uuidString: "c4500000-0000-0000-0000-000000000001")!
        let windowID = UUID(uuidString: "c4500000-0000-0000-0000-000000000002")!
        let logEntries: [AndroidLogEntryRow] = [
            .init(
                tableName: "Workspace",
                entityID1: .blob(uuidBlob(workspaceID)),
                entityID2: .text(""),
                type: "UPSERT",
                lastUpdated: 1_735_689_600_000,
                sourceDevice: "pixel"
            ),
            .init(
                tableName: "Window",
                entityID1: .blob(uuidBlob(windowID)),
                entityID2: .integer(7),
                type: "DELETE",
                lastUpdated: 1_735_689_700_000,
                sourceDevice: "pixel"
            ),
        ]
        let syncStatuses: [AndroidSyncStatusRow] = [
            .init(sourceDevice: "pixel", patchNumber: 3, sizeBytes: 2_048, appliedDate: 1_735_689_800_000),
            .init(sourceDevice: "tablet", patchNumber: 1, sizeBytes: 4_096, appliedDate: 1_735_689_900_000),
        ]

        let databaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [],
            windows: [],
            pageManagers: [],
            historyItems: [],
            logEntries: logEntries,
            syncStatuses: syncStatuses
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let snapshot = try service.readSnapshot(from: databaseURL)

        XCTAssertEqual(
            snapshot.logEntries,
            [
                .init(
                    tableName: "Workspace",
                    entityID1: .blob(uuidBlob(workspaceID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 1_735_689_600_000,
                    sourceDevice: "pixel"
                ),
                .init(
                    tableName: "Window",
                    entityID1: .blob(uuidBlob(windowID)),
                    entityID2: .integer(7),
                    type: .delete,
                    lastUpdated: 1_735_689_700_000,
                    sourceDevice: "pixel"
                ),
            ]
        )
        XCTAssertEqual(
            snapshot.patchStatuses,
            [
                .init(sourceDevice: "pixel", patchNumber: 3, sizeBytes: 2_048, appliedDate: 1_735_689_800_000),
                .init(sourceDevice: "tablet", patchNumber: 1, sizeBytes: 4_096, appliedDate: 1_735_689_900_000),
            ]
        )

        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        logEntryStore.addEntry(
            .init(
                tableName: "Workspace",
                entityID1: .blob(uuidBlob(UUID(uuidString: "c4500000-0000-0000-0000-000000000010")!)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 10,
                sourceDevice: "old-phone"
            ),
            for: .workspaces
        )
        logEntryStore.addEntry(
            .init(
                tableName: "Label",
                entityID1: .blob(uuidBlob(UUID(uuidString: "c4500000-0000-0000-0000-000000000011")!)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 11,
                sourceDevice: "bookmark-device"
            ),
            for: .bookmarks
        )
        patchStatusStore.addStatus(
            .init(sourceDevice: "old-phone", patchNumber: 1, sizeBytes: 111, appliedDate: 222),
            for: .workspaces
        )
        patchStatusStore.addStatus(
            .init(sourceDevice: "bookmark-device", patchNumber: 9, sizeBytes: 333, appliedDate: 444),
            for: .bookmarks
        )

        let report = service.replaceLocalMetadata(
            from: snapshot,
            category: .workspaces,
            settingsStore: settingsStore
        )

        XCTAssertEqual(
            report,
            .init(importedLogEntryCount: 2, importedPatchStatusCount: 2)
        )
        XCTAssertEqual(logEntryStore.entries(for: .workspaces), snapshot.logEntries)
        XCTAssertEqual(patchStatusStore.statuses(for: .workspaces), snapshot.patchStatuses)
        XCTAssertEqual(logEntryStore.entries(for: .bookmarks).count, 1)
        XCTAssertEqual(patchStatusStore.statuses(for: .bookmarks), [
            .init(sourceDevice: "bookmark-device", patchNumber: 9, sizeBytes: 333, appliedDate: 444)
        ])
    }

    func testRemoteSyncWorkspaceRestoreRejectsOrphanReferencesWithoutMutation() throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let service = RemoteSyncWorkspaceRestoreService()

        let legacyWorkspace = Workspace(
            id: UUID(uuidString: "c4000000-0000-0000-0000-000000000001")!,
            name: "Legacy",
            orderNumber: 0
        )
        modelContext.insert(legacyWorkspace)
        try modelContext.save()

        let workspaceID = UUID(uuidString: "c4000000-0000-0000-0000-000000000010")!
        let windowID = UUID(uuidString: "c4000000-0000-0000-0000-000000000011")!
        let databaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(id: workspaceID, name: "Broken", orderNumber: 0)
            ],
            windows: [
                .init(
                    id: windowID,
                    workspaceID: workspaceID,
                    isSynchronized: true,
                    isPinMode: false,
                    isLinksWindow: false,
                    orderNumber: 0,
                    syncGroup: 0,
                    layoutState: "split",
                    layoutWeight: 1.0
                )
            ],
            pageManagers: [],
            historyItems: []
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        XCTAssertThrowsError(try service.readSnapshot(from: databaseURL)) { error in
            XCTAssertEqual(
                error as? RemoteSyncWorkspaceRestoreError,
                .orphanReferences([
                    "Window.id=\(windowID.uuidString) missing PageManager"
                ])
            )
        }

        let workspaces = try modelContext.fetch(FetchDescriptor<Workspace>())
        XCTAssertEqual(workspaces.map(\.name), ["Legacy"])
    }

    /**
     Verifies a v24-declared initial workspace backup is migrated, decoded, and published with its
     Android metadata. Failure indicates the archive generation is no longer forwarded to the
     shared workspace schema validator. The temporary SQLite fixture is removed on exit.
     */
    func testRemoteSyncInitialBackupRestoreDispatchesWorkspaceBackups() throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let service = RemoteSyncInitialBackupRestoreService()
        let workspaceID = UUID(uuidString: "c5000000-0000-0000-0000-000000000001")!
        let windowID = UUID(uuidString: "c5000000-0000-0000-0000-000000000002")!
        let stagedLogEntry = AndroidLogEntryRow(
            tableName: "Workspace",
            entityID1: .blob(uuidBlob(workspaceID)),
            entityID2: .text(""),
            type: "UPSERT",
            lastUpdated: 1_735_689_600_000,
            sourceDevice: "pixel"
        )
        let stagedPatchStatus = AndroidSyncStatusRow(
            sourceDevice: "pixel",
            patchNumber: 4,
            sizeBytes: 8_192,
            appliedDate: 1_735_689_650_000
        )

        let databaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(
                    id: workspaceID,
                    name: "Dispatch",
                    orderNumber: 0,
                    workspaceSettings: .init(speakSettingsJSON: #"{"sleepTimer":5}"#)
                )
            ],
            windows: [
                .init(
                    id: windowID,
                    workspaceID: workspaceID,
                    isSynchronized: true,
                    isPinMode: false,
                    isLinksWindow: false,
                    orderNumber: 0,
                    syncGroup: 0,
                    layoutState: "split",
                    layoutWeight: 1.0
                )
            ],
            pageManagers: [
                .init(
                    windowID: windowID,
                    bibleDocument: "KJV",
                    currentCategoryName: "BIBLE"
                )
            ],
            historyItems: [
                .init(
                    remoteID: 501,
                    windowID: windowID,
                    createdAt: Date(timeIntervalSince1970: 1_735_689_600),
                    document: "KJV",
                    key: "Gen.1.1",
                    anchorOrdinal: 301
                )
            ],
            logEntries: [stagedLogEntry],
            syncStatuses: [stagedPatchStatus]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let stagedBackup = RemoteSyncStagedInitialBackup(
            remoteFile: RemoteSyncFile(
                id: "/org.andbible.ios-sync-workspaces/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 4096,
                timestamp: 1_735_689_600_000,
                parentID: "/org.andbible.ios-sync-workspaces",
                mimeType: "application/gzip"
            ),
            databaseFileURL: databaseURL,
            schemaVersion: RemoteSyncCategory.workspaces.currentSchemaVersion
        )

        let report = try service.restoreInitialBackup(
            stagedBackup,
            category: .workspaces,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(
            report,
            .workspaces(
                .init(
                    restoredWorkspaceCount: 1,
                    restoredWindowCount: 1,
                    restoredHistoryItemCount: 1,
                    preservedWorkspaceFidelityCount: 1,
                    preservedPageManagerFidelityCount: 1,
                    preservedHistoryItemAliasCount: 1
                )
            )
        )

        let workspaces = try modelContext.fetch(FetchDescriptor<Workspace>())
        XCTAssertEqual(workspaces.map(\.id), [workspaceID])

        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        XCTAssertEqual(fidelityStore.speakSettingsJSON(for: workspaceID), #"{"sleepTimer":5}"#)
        XCTAssertEqual(fidelityStore.pageManagerEntry(for: windowID)?.rawCurrentCategoryName, "BIBLE")
        XCTAssertEqual(fidelityStore.localHistoryItemID(for: 501) != nil, true)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        XCTAssertEqual(
            logEntryStore.entries(for: .workspaces),
            [
                .init(
                    tableName: "Workspace",
                    entityID1: .blob(uuidBlob(workspaceID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 1_735_689_600_000,
                    sourceDevice: "pixel"
                )
            ]
        )
        XCTAssertEqual(
            patchStatusStore.statuses(for: .workspaces),
            [
                .init(
                    sourceDevice: "pixel",
                    patchNumber: 4,
                    sizeBytes: 8_192,
                    appliedDate: 1_735_689_650_000
                )
            ]
        )
        XCTAssertEqual(settingsStore.activeWorkspaceId, workspaceID)
    }

    /**
     Verifies newer Android workspace patches publish graph and replay bookkeeping with one save.

     The replay updates workspace/window/page-manager rows, preserves local history, replaces conflict
     log entries, records patch status, and refreshes fingerprints. One `didSave` notification pins the
     outer atomic boundary across the nested centralized workspace restore and all metadata writes.

     - Side effects: Builds temporary Android SQLite fixtures and mutates an isolated in-memory store.
     - Failure modes: Rethrows fixture, archive, restore, or fetch errors. Assertions describe replay
       fidelity, bookkeeping drift, or more than one durable publish.
     */
    func testRemoteSyncWorkspacePatchApplyReplaysNewerRowsAndPreservesHistoryAndFidelity() throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreService = RemoteSyncWorkspaceRestoreService()
        let patchService = RemoteSyncWorkspacePatchApplyService()
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

        let workspaceID = UUID(uuidString: "c6000000-0000-0000-0000-000000000001")!
        let firstWindowID = UUID(uuidString: "c6000000-0000-0000-0000-000000000002")!
        let secondWindowID = UUID(uuidString: "c6000000-0000-0000-0000-000000000003")!
        let hiddenLabelID = UUID(uuidString: "c6000000-0000-0000-0000-000000000004")!

        let initialDatabaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(
                    id: workspaceID,
                    name: "Initial Workspace",
                    contentsText: "Initial content",
                    orderNumber: 0,
                    textDisplaySettings: .init(fontSize: 18),
                    workspaceSettings: .init(
                        enableTiltToScroll: true,
                        enableReverseSplitMode: false,
                        autoPin: false,
                        speakSettingsJSON: #"{"sleepTimer":5}"#
                    ),
                    maximizedWindowID: firstWindowID,
                    primaryTargetLinksWindowID: firstWindowID
                )
            ],
            windows: [
                .init(
                    id: firstWindowID,
                    workspaceID: workspaceID,
                    isSynchronized: true,
                    isPinMode: false,
                    isLinksWindow: false,
                    orderNumber: 0,
                    syncGroup: 1,
                    layoutState: "split",
                    layoutWeight: 1.0
                )
            ],
            pageManagers: [
                .init(
                    windowID: firstWindowID,
                    bibleDocument: "KJV",
                    bibleVersification: "KJVA",
                    bibleBook: 0,
                    bibleChapterNo: 1,
                    bibleVerseNo: 1,
                    commentaryDocument: "MHC",
                    commentaryAnchorOrdinal: 11,
                    commentarySourceBookAndKey: "GEN.1.1",
                    dictionaryDocument: "StrongsHebrew",
                    dictionaryKey: "H02022",
                    dictionaryAnchorOrdinal: 21,
                    generalBookDocument: "Josephus",
                    generalBookKey: "Ant.1.1",
                    generalBookAnchorOrdinal: 31,
                    mapDocument: "Maps",
                    mapKey: "Jerusalem",
                    mapAnchorOrdinal: 41,
                    currentCategoryName: "BIBLE",
                    textDisplaySettings: .init(
                        showBookmarks: true,
                        bookmarksHideLabelsJSON: #"["\#(hiddenLabelID.uuidString)"]"#
                    ),
                    jsState: #"{"scroll":25}"#
                )
            ],
            historyItems: [
                .init(
                    remoteID: 501,
                    windowID: firstWindowID,
                    createdAt: Date(timeIntervalSince1970: 1_735_800_000),
                    document: "KJV",
                    key: "Gen.1.1",
                    anchorOrdinal: 100
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalWorkspaces(
            from: initialSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        settingsStore.activeWorkspaceId = workspaceID
        logEntryStore.replaceEntries([
            .init(
                tableName: "Workspace",
                entityID1: .blob(uuidBlob(workspaceID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "ios-local"
            ),
            .init(
                tableName: "Window",
                entityID1: .blob(uuidBlob(firstWindowID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_100,
                sourceDevice: "ios-local"
            ),
            .init(
                tableName: "PageManager",
                entityID1: .blob(uuidBlob(firstWindowID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_200,
                sourceDevice: "ios-local"
            ),
        ], for: .workspaces)

        let patchDatabaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(
                    id: workspaceID,
                    name: "Patched Workspace",
                    contentsText: "Updated content",
                    orderNumber: 2,
                    textDisplaySettings: .init(fontSize: 22),
                    workspaceSettings: .init(
                        enableTiltToScroll: false,
                        enableReverseSplitMode: true,
                        autoPin: true,
                        speakSettingsJSON: #"{"sleepTimer":30,"queue":true}"#
                    ),
                    maximizedWindowID: secondWindowID,
                    primaryTargetLinksWindowID: secondWindowID
                )
            ],
            windows: [
                .init(
                    id: firstWindowID,
                    workspaceID: workspaceID,
                    isSynchronized: false,
                    isPinMode: true,
                    isLinksWindow: false,
                    orderNumber: 1,
                    targetLinksWindowID: secondWindowID,
                    syncGroup: 3,
                    layoutState: "minimized",
                    layoutWeight: 0.8
                ),
                .init(
                    id: secondWindowID,
                    workspaceID: workspaceID,
                    isSynchronized: true,
                    isPinMode: false,
                    isLinksWindow: true,
                    orderNumber: 0,
                    syncGroup: 4,
                    layoutState: "split",
                    layoutWeight: 1.2
                )
            ],
            pageManagers: [
                .init(
                    windowID: firstWindowID,
                    bibleDocument: "ESV",
                    bibleVersification: "KJVA",
                    bibleBook: 1,
                    bibleChapterNo: 2,
                    bibleVerseNo: 3,
                    commentaryDocument: "TSK",
                    commentaryAnchorOrdinal: 12,
                    commentarySourceBookAndKey: "EXOD.2.3",
                    dictionaryDocument: "StrongsGreek",
                    dictionaryKey: "G01234",
                    dictionaryAnchorOrdinal: 22,
                    generalBookDocument: "Josephus",
                    generalBookKey: "Ant.2.1",
                    generalBookAnchorOrdinal: 32,
                    mapDocument: "Maps",
                    mapKey: "Egypt",
                    mapAnchorOrdinal: 42,
                    currentCategoryName: "GENERAL_BOOK",
                    textDisplaySettings: .init(showVersePerLine: true),
                    jsState: #"{"scroll":125}"#
                ),
                .init(
                    windowID: secondWindowID,
                    bibleDocument: "NET",
                    bibleVersification: "KJVA",
                    bibleBook: 39,
                    bibleChapterNo: 5,
                    bibleVerseNo: 3,
                    commentaryDocument: "MHC",
                    commentaryAnchorOrdinal: 13,
                    commentarySourceBookAndKey: "MATT.5.3",
                    dictionaryDocument: "Easton",
                    dictionaryKey: "Grace",
                    dictionaryAnchorOrdinal: 23,
                    generalBookDocument: "Calvin",
                    generalBookKey: "Commentary.1",
                    generalBookAnchorOrdinal: 33,
                    mapDocument: "Maps",
                    mapKey: "Galilee",
                    mapAnchorOrdinal: 43,
                    currentCategoryName: "MYNOTE",
                    textDisplaySettings: .init(showBookmarks: false),
                    jsState: #"{"scroll":225}"#
                )
            ],
            historyItems: [],
            logEntries: [
                .init(tableName: "Workspace", entityID1: .blob(uuidBlob(workspaceID)), entityID2: .text(""), type: "UPSERT", lastUpdated: 2_000, sourceDevice: "pixel"),
                .init(tableName: "Window", entityID1: .blob(uuidBlob(firstWindowID)), entityID2: .text(""), type: "UPSERT", lastUpdated: 2_100, sourceDevice: "pixel"),
                .init(tableName: "Window", entityID1: .blob(uuidBlob(secondWindowID)), entityID2: .text(""), type: "UPSERT", lastUpdated: 2_200, sourceDevice: "pixel"),
                .init(tableName: "PageManager", entityID1: .blob(uuidBlob(firstWindowID)), entityID2: .text(""), type: "UPSERT", lastUpdated: 2_300, sourceDevice: "pixel"),
                .init(tableName: "PageManager", entityID1: .blob(uuidBlob(secondWindowID)), entityID2: .text(""), type: "UPSERT", lastUpdated: 2_400, sourceDevice: "pixel"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeWorkspacePatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "pixel",
            patchNumber: 7,
            fileTimestamp: 3_000
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let saveExpectation = expectation(description: "Workspace patch publishes graph and bookkeeping once")
        saveExpectation.expectedFulfillmentCount = 1
        saveExpectation.assertForOverFulfill = true
        let saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: modelContext,
            queue: nil
        ) { _ in
            saveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(saveObserver) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        wait(for: [saveExpectation], timeout: 1)

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 5)
        XCTAssertEqual(report.skippedLogEntryCount, 0)
        XCTAssertEqual(
            report.restoreReport,
            .init(
                restoredWorkspaceCount: 1,
                restoredWindowCount: 2,
                restoredHistoryItemCount: 1,
                preservedWorkspaceFidelityCount: 1,
                preservedPageManagerFidelityCount: 2,
                preservedHistoryItemAliasCount: 1
            )
        )

        let workspaces = try modelContext.fetch(FetchDescriptor<Workspace>())
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces[0].name, "Patched Workspace")
        XCTAssertEqual(workspaces[0].contentsText, "Updated content")
        XCTAssertEqual(workspaces[0].orderNumber, 2)
        XCTAssertEqual(workspaces[0].maximizedWindowId, secondWindowID)
        XCTAssertEqual(workspaces[0].primaryTargetLinksWindowId, secondWindowID)
        XCTAssertTrue(workspaces[0].workspaceSettings?.enableReverseSplitMode ?? false)
        XCTAssertEqual(settingsStore.activeWorkspaceId, workspaceID)

        let windows = try modelContext.fetch(FetchDescriptor<Window>()).sorted { lhs, rhs in
            if lhs.orderNumber == rhs.orderNumber {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.orderNumber < rhs.orderNumber
        }
        XCTAssertEqual(windows.map(\.id), [secondWindowID, firstWindowID])
        XCTAssertEqual(windows.first(where: { $0.id == firstWindowID })?.targetLinksWindowId, secondWindowID)
        XCTAssertEqual(windows.first(where: { $0.id == firstWindowID })?.layoutState, "minimized")

        let pageManagers = try modelContext.fetch(FetchDescriptor<PageManager>())
        XCTAssertEqual(pageManagers.count, 2)
        XCTAssertEqual(pageManagers.first(where: { $0.id == firstWindowID })?.currentCategoryName, "general_book")
        // Android MYNOTE windows restore into iOS's `mynote` page-manager key so the reader
        // reopens the My Notes page instead of collapsing the window to the Bible text.
        XCTAssertEqual(pageManagers.first(where: { $0.id == secondWindowID })?.currentCategoryName, "mynote")
        XCTAssertEqual(pageManagers.first(where: { $0.id == secondWindowID })?.dictionaryDocument, "Easton")

        let historyItems = try modelContext.fetch(FetchDescriptor<HistoryItem>())
        XCTAssertEqual(historyItems.count, 1)
        XCTAssertEqual(historyItems.first?.document, "KJV")
        XCTAssertEqual(historyItems.first?.key, "Gen.1.1")

        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        XCTAssertEqual(
            fidelityStore.speakSettingsJSON(for: workspaceID),
            #"{"sleepTimer":30,"queue":true}"#
        )
        XCTAssertEqual(
            fidelityStore.allPageManagerEntries(),
            [
                .init(
                    windowID: firstWindowID,
                    rawCurrentCategoryName: "GENERAL_BOOK",
                    commentarySourceBookAndKey: "EXOD.2.3",
                    dictionaryAnchorOrdinal: 22,
                    generalBookAnchorOrdinal: 32,
                    mapAnchorOrdinal: 42
                ),
                .init(
                    windowID: secondWindowID,
                    rawCurrentCategoryName: "MYNOTE",
                    commentarySourceBookAndKey: "MATT.5.3",
                    dictionaryAnchorOrdinal: 23,
                    generalBookAnchorOrdinal: 33,
                    mapAnchorOrdinal: 43
                )
            ]
        )
        XCTAssertNotNil(fidelityStore.localHistoryItemID(for: 501))
        XCTAssertEqual(
            patchStatusStore.status(for: .workspaces, sourceDevice: "pixel", patchNumber: 7),
            .init(sourceDevice: "pixel", patchNumber: 7, sizeBytes: Int64((try Data(contentsOf: stagedArchive.archiveFileURL)).count), appliedDate: 3_000)
        )
        XCTAssertEqual(
            logEntryStore.entry(
                for: .workspaces,
                tableName: "PageManager",
                entityID1: .blob(uuidBlob(secondWindowID)),
                entityID2: .text("")
            )?.lastUpdated,
            2_400
        )
        let currentSnapshot = RemoteSyncWorkspaceSnapshotService().snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        for (logKey, expectedFingerprint) in currentSnapshot.fingerprintsByKey {
            XCTAssertEqual(
                fingerprintStore.fingerprint(forLogKey: logKey, category: .workspaces),
                expectedFingerprint
            )
        }
    }

    /**
     Verifies that deleting one Android window removes its page manager and history rows even when the patch carries no separate child-table deletions.
     */
    func testRemoteSyncWorkspacePatchApplyDeletesWindowsAndRetainsRemainingHistory() throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreService = RemoteSyncWorkspaceRestoreService()
        let patchService = RemoteSyncWorkspacePatchApplyService()

        let workspaceID = UUID(uuidString: "c6100000-0000-0000-0000-000000000001")!
        let firstWindowID = UUID(uuidString: "c6100000-0000-0000-0000-000000000002")!
        let secondWindowID = UUID(uuidString: "c6100000-0000-0000-0000-000000000003")!

        let initialDatabaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(id: workspaceID, name: "Workspace", orderNumber: 0)
            ],
            windows: [
                .init(id: firstWindowID, workspaceID: workspaceID, isSynchronized: true, isPinMode: false, isLinksWindow: false, orderNumber: 0, syncGroup: 0, layoutState: "split", layoutWeight: 1.0),
                .init(id: secondWindowID, workspaceID: workspaceID, isSynchronized: true, isPinMode: false, isLinksWindow: false, orderNumber: 1, syncGroup: 0, layoutState: "split", layoutWeight: 1.0),
            ],
            pageManagers: [
                .init(windowID: firstWindowID, bibleDocument: "KJV", bibleVersification: "KJVA", bibleBook: 0, bibleChapterNo: 1, bibleVerseNo: 1, currentCategoryName: "BIBLE"),
                .init(windowID: secondWindowID, bibleDocument: "ESV", bibleVersification: "KJVA", bibleBook: 1, bibleChapterNo: 2, bibleVerseNo: 3, currentCategoryName: "BIBLE"),
            ],
            historyItems: [
                .init(remoteID: 701, windowID: firstWindowID, createdAt: Date(timeIntervalSince1970: 1_735_810_000), document: "KJV", key: "Gen.1.1", anchorOrdinal: 10),
                .init(remoteID: 702, windowID: secondWindowID, createdAt: Date(timeIntervalSince1970: 1_735_810_100), document: "ESV", key: "Exod.2.3", anchorOrdinal: 20),
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalWorkspaces(
            from: initialSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let patchDatabaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [],
            windows: [],
            pageManagers: [],
            historyItems: [],
            logEntries: [
                .init(tableName: "Window", entityID1: .blob(uuidBlob(secondWindowID)), entityID2: .text(""), type: "DELETE", lastUpdated: 2_000, sourceDevice: "pixel")
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeWorkspacePatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "pixel",
            patchNumber: 8,
            fileTimestamp: 2_500
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 1)
        XCTAssertEqual(report.skippedLogEntryCount, 0)
        XCTAssertEqual(report.restoreReport.restoredWindowCount, 1)
        XCTAssertEqual(report.restoreReport.restoredHistoryItemCount, 1)

        let windows = try modelContext.fetch(FetchDescriptor<Window>())
        XCTAssertEqual(windows.map(\.id), [firstWindowID])
        let pageManagers = try modelContext.fetch(FetchDescriptor<PageManager>())
        XCTAssertEqual(pageManagers.map(\.id), [firstWindowID])
        let historyItems = try modelContext.fetch(FetchDescriptor<HistoryItem>())
        XCTAssertEqual(historyItems.count, 1)
        XCTAssertEqual(historyItems.first?.document, "KJV")
    }

    /**
     Verifies that older Android workspace rows do not mutate local state while their validated patch
     is recorded as consumed for deterministic discovery deduplication.
     */
    func testRemoteSyncWorkspacePatchApplySkipsOlderRows() throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreService = RemoteSyncWorkspaceRestoreService()
        let patchService = RemoteSyncWorkspacePatchApplyService()
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

        let workspaceID = UUID(uuidString: "c6200000-0000-0000-0000-000000000001")!

        let initialDatabaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(id: workspaceID, name: "Local", orderNumber: 0)
            ],
            windows: [],
            pageManagers: [],
            historyItems: []
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalWorkspaces(
            from: initialSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        logEntryStore.replaceEntries([
            .init(
                tableName: "Workspace",
                entityID1: .blob(uuidBlob(workspaceID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 5_000,
                sourceDevice: "ios-local"
            )
        ], for: .workspaces)

        let patchDatabaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(id: workspaceID, name: "Remote Older", orderNumber: 1)
            ],
            windows: [],
            pageManagers: [],
            historyItems: [],
            logEntries: [
                .init(tableName: "Workspace", entityID1: .blob(uuidBlob(workspaceID)), entityID2: .text(""), type: "UPSERT", lastUpdated: 4_000, sourceDevice: "pixel")
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeWorkspacePatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "pixel",
            patchNumber: 9,
            fileTimestamp: 4_500
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 0)
        XCTAssertEqual(report.skippedLogEntryCount, 1)

        let workspaces = try modelContext.fetch(FetchDescriptor<Workspace>())
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces[0].name, "Local")
        XCTAssertEqual(
            patchStatusStore.status(for: .workspaces, sourceDevice: "pixel", patchNumber: 9),
            RemoteSyncPatchStatus(
                sourceDevice: "pixel",
                patchNumber: 9,
                sizeBytes: stagedArchive.patch.file.size,
                appliedDate: 4_500
            )
        )
        XCTAssertEqual(
            logEntryStore.entry(
                for: .workspaces,
                tableName: "Workspace",
                entityID1: .blob(uuidBlob(workspaceID)),
                entityID2: .text("")
            )?.lastUpdated,
            5_000
        )
    }

    /**
     Verifies that deleting one Android workspace prunes its descendant windows, page managers, and history rows even when the patch batch carries no child-table rows.
     */
    func testRemoteSyncWorkspacePatchApplyPrunesChildrenAfterWorkspaceDeletionWithoutChildRows() throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreService = RemoteSyncWorkspaceRestoreService()
        let patchService = RemoteSyncWorkspacePatchApplyService()

        let workspaceID = UUID(uuidString: "c6300000-0000-0000-0000-000000000001")!
        let windowID = UUID(uuidString: "c6300000-0000-0000-0000-000000000002")!

        let initialDatabaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(id: workspaceID, name: "Delete Me", orderNumber: 0)
            ],
            windows: [
                .init(id: windowID, workspaceID: workspaceID, isSynchronized: true, isPinMode: false, isLinksWindow: false, orderNumber: 0, syncGroup: 0, layoutState: "split", layoutWeight: 1.0)
            ],
            pageManagers: [
                .init(windowID: windowID, bibleDocument: "KJV", bibleVersification: "KJVA", bibleBook: 0, bibleChapterNo: 1, bibleVerseNo: 1, currentCategoryName: "BIBLE")
            ],
            historyItems: [
                .init(remoteID: 801, windowID: windowID, createdAt: Date(timeIntervalSince1970: 1_735_820_000), document: "KJV", key: "Gen.1.1", anchorOrdinal: 10)
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalWorkspaces(
            from: initialSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        settingsStore.activeWorkspaceId = workspaceID

        let patchDatabaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [],
            windows: [],
            pageManagers: [],
            historyItems: [],
            logEntries: [
                .init(tableName: "Workspace", entityID1: .blob(uuidBlob(workspaceID)), entityID2: .text(""), type: "DELETE", lastUpdated: 2_000, sourceDevice: "pixel")
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeWorkspacePatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "pixel",
            patchNumber: 10,
            fileTimestamp: 2_500
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 1)
        XCTAssertEqual(report.skippedLogEntryCount, 0)
        XCTAssertEqual(
            report.restoreReport,
            .init(
                restoredWorkspaceCount: 0,
                restoredWindowCount: 0,
                restoredHistoryItemCount: 0,
                preservedWorkspaceFidelityCount: 0,
                preservedPageManagerFidelityCount: 0,
                preservedHistoryItemAliasCount: 0
            )
        )
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<Workspace>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<Window>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<PageManager>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<HistoryItem>()).isEmpty)
        XCTAssertNil(settingsStore.activeWorkspaceId)
    }

    /**
     Verifies that initial-backup upload writes a full Android workspace database, preserves
     history aliases, and records the accepted patch-zero baseline locally.
     */
    func testRemoteSyncInitialBackupUploadWritesWorkspaceDatabaseAndResetsBaseline() async throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        let metadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService()
        let restoreDispatcher = RemoteSyncInitialBackupRestoreService()
        let restoreService = RemoteSyncWorkspaceRestoreService()

        let workspaceID = UUID(uuidString: "c6300000-0000-0000-0000-000000000001")!
        let windowID = UUID(uuidString: "c6300000-0000-0000-0000-000000000002")!
        let initialDatabaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(id: workspaceID, name: "Travel", orderNumber: 0)
            ],
            windows: [
                .init(
                    id: windowID,
                    workspaceID: workspaceID,
                    isSynchronized: true,
                    isPinMode: false,
                    isLinksWindow: false,
                    orderNumber: 0,
                    syncGroup: 0,
                    layoutState: "split",
                    layoutWeight: 1.0
                )
            ],
            pageManagers: [
                .init(
                    windowID: windowID,
                    bibleDocument: "KJV",
                    bibleVersification: "KJVA",
                    bibleBook: 0,
                    bibleChapterNo: 1,
                    bibleVerseNo: 1,
                    currentCategoryName: "BIBLE",
                    jsState: #"{"scrollY":0}"#
                )
            ],
            historyItems: [
                .init(
                    remoteID: 77,
                    windowID: windowID,
                    createdAt: Date(timeIntervalSince1970: 1_735_689_600),
                    document: "KJV",
                    key: "Gen.1.1",
                    anchorOrdinal: 101
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let stagedBackup = RemoteSyncStagedInitialBackup(
            remoteFile: RemoteSyncFile(
                id: "/org.andbible.ios-sync-workspaces/seed/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 1,
                timestamp: 1_500,
                parentID: "/org.andbible.ios-sync-workspaces/seed",
                mimeType: "application/gzip"
            ),
            databaseFileURL: initialDatabaseURL,
            schemaVersion: 24
        )
        _ = try restoreDispatcher.restoreInitialBackup(
            stagedBackup,
            category: .workspaces,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let hiddenLabelID = UUID(uuidString: "c6300000-0000-0000-0000-000000000003")!
        settingsStore.setString("remote_sync_device_identifier", value: "ios-device")
        let workspaceDisplaySettings = completeTextDisplaySettings(
            seed: 10,
            hiddenLabelID: hiddenLabelID
        )
        let pageDisplaySettings = completeTextDisplaySettings(
            seed: 30,
            hiddenLabelID: hiddenLabelID
        )
        let globalDisplaySettings = completeTextDisplaySettings(
            seed: 50,
            hiddenLabelID: hiddenLabelID
        )
        let roomFidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        try roomFidelityStore.setGlobalTextDisplayEntry(
            id: RemoteSyncCurrentGlobalTextDisplaySettingsRow.androidSingletonID,
            fidelity: .init(
                autoTrackReading: true,
                scrollHelperLines: true,
                scrollHelperLineStyle: 5,
                showPageButtons: false
            )
        )
        let localWorkspace = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<Workspace>()).first)
        localWorkspace.textDisplaySettings = workspaceDisplaySettings
        let localPageManager = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<PageManager>()).first)
        localPageManager.textDisplaySettings = pageDisplaySettings
        try roomFidelityStore.setTextDisplayFidelity(
            .init(
                autoTrackReading: false,
                scrollHelperLines: true,
                scrollHelperLineStyle: 6,
                showPageButtons: true
            ),
            forWorkspaceID: workspaceID
        )
        try roomFidelityStore.setTextDisplayFidelity(
            .init(
                autoTrackReading: true,
                scrollHelperLines: false,
                scrollHelperLineStyle: 7,
                showPageButtons: true
            ),
            forPageManagerWindowID: windowID
        )
        try roomFidelityStore.setLabelOverride(
            .init(workspaceID: workspaceID, labelID: hiddenLabelID, overrideMode: 2)
        )
        let globalDisplayData = try JSONEncoder().encode(globalDisplaySettings)
        settingsStore.setString(
            SettingsStore.globalTextDisplaySettingsKey,
            value: String(decoding: globalDisplayData, as: UTF8.self)
        )

        let syncFolderID = "/org.andbible.ios-sync-workspaces"
        let adapter = WorkspaceMockRemoteSyncAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(syncFolderID)/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 0,
                timestamp: 2_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let service = RemoteSyncInitialBackupUploadService(
            adapter: adapter,
            deviceIdentifier: "ios-device",
            nowProvider: { 1_900 }
        )

        let report = try await service.uploadInitialBackup(
            for: .workspaces,
            bootstrapState: RemoteSyncBootstrapState(syncFolderID: syncFolderID),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.category, .workspaces)
        XCTAssertEqual(
            patchStatusStore.statuses(for: .workspaces),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 0,
                    sizeBytes: report.uploadedFile.size,
                    appliedDate: 2_000
                )
            ]
        )
        let initialWriteTimestamp = try XCTUnwrap(
            stateStore.progressState(for: .workspaces).lastPatchWritten
        )
        XCTAssertGreaterThan(initialWriteTimestamp, 1_900)
        XCTAssertNil(stateStore.progressState(for: .workspaces).lastSynchronized)
        XCTAssertEqual(fidelityStore.allHistoryItemAliases().map(\.remoteHistoryItemID), [77])

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .listFiles(
                parentIDs: [syncFolderID],
                name: "initial.sqlite3.gz",
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .upload(
                name: "initial.sqlite3.gz",
                parentID: syncFolderID,
                contentType: NextCloudSyncAdapter.gzipMimeType
            )
        ])

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedArchive = try XCTUnwrap(uploadedFiles.first)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploaded-workspace-initial-\(UUID().uuidString).sqlite3.gz")
        let databaseURL = archiveURL.deletingPathExtension()
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: databaseURL)
        }
        try uploadedArchive.data.write(to: archiveURL, options: .atomic)
        let initialDatabaseData = try workspaceGunzipTestData(uploadedArchive.data)
        try initialDatabaseData.write(to: databaseURL, options: .atomic)

        let metadataSnapshot = try metadataRestoreService.readSnapshot(from: databaseURL)
        XCTAssertTrue(metadataSnapshot.logEntries.isEmpty)
        XCTAssertTrue(metadataSnapshot.patchStatuses.isEmpty)

        let snapshot = try restoreService.readSnapshot(from: databaseURL)
        XCTAssertEqual(snapshot.workspaces.count, 1)
        XCTAssertEqual(snapshot.workspaces[0].name, "Travel")
        XCTAssertEqual(snapshot.workspaces[0].textDisplaySettings, workspaceDisplaySettings)
        XCTAssertEqual(
            snapshot.workspaces[0].textDisplayFidelity,
            .init(
                autoTrackReading: false,
                scrollHelperLines: true,
                scrollHelperLineStyle: 6,
                showPageButtons: true
            )
        )
        XCTAssertEqual(snapshot.workspaces[0].windows.count, 1)
        XCTAssertEqual(snapshot.workspaces[0].windows[0].pageManager.currentCategoryName, "BIBLE")
        XCTAssertEqual(
            snapshot.workspaces[0].windows[0].pageManager.textDisplaySettings,
            pageDisplaySettings
        )
        XCTAssertEqual(
            snapshot.workspaces[0].windows[0].pageManager.textDisplayFidelity,
            .init(
                autoTrackReading: true,
                scrollHelperLines: false,
                scrollHelperLineStyle: 7,
                showPageButtons: true
            )
        )
        XCTAssertEqual(snapshot.workspaces[0].windows[0].historyItems.count, 1)
        XCTAssertEqual(snapshot.workspaces[0].windows[0].historyItems[0].remoteID, 77)
        XCTAssertEqual(
            snapshot.labelOverrides,
            [.init(workspaceID: workspaceID, labelID: hiddenLabelID, overrideMode: 2)]
        )
        XCTAssertEqual(snapshot.globalTextDisplaySettings?.textDisplaySettings, globalDisplaySettings)
        XCTAssertEqual(
            snapshot.globalTextDisplaySettings?.fidelity,
            .init(
                autoTrackReading: true,
                scrollHelperLines: true,
                scrollHelperLineStyle: 5,
                showPageButtons: false
            )
        )
    }

    /**
     Verifies that outbound upload writes an Android-shaped sparse workspace patch, uploads it, and advances local sync bookkeeping.
     */
    func testRemoteSyncWorkspacePatchUploadWritesAndUploadsSparsePatch() async throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreService = RemoteSyncWorkspaceRestoreService()
        let metadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService()
        let snapshotService = RemoteSyncWorkspaceSnapshotService()
        let patchApplyService = RemoteSyncWorkspacePatchApplyService()
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)

        let workspaceID = UUID(uuidString: "c6400000-0000-0000-0000-000000000001")!
        let windowID = UUID(uuidString: "c6400000-0000-0000-0000-000000000002")!
        let initialLogEntries: [RemoteSyncLogEntry] = [
            .init(
                tableName: "Workspace",
                entityID1: .blob(uuidBlob(workspaceID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            .init(
                tableName: "Window",
                entityID1: .blob(uuidBlob(windowID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            .init(
                tableName: "PageManager",
                entityID1: .blob(uuidBlob(windowID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
        ]

        let initialDatabaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(id: workspaceID, name: "Travel", orderNumber: 0)
            ],
            windows: [
                .init(
                    id: windowID,
                    workspaceID: workspaceID,
                    isSynchronized: true,
                    isPinMode: false,
                    isLinksWindow: false,
                    orderNumber: 0,
                    syncGroup: 0,
                    layoutState: "split",
                    layoutWeight: 1.0
                )
            ],
            pageManagers: [
                .init(
                    windowID: windowID,
                    bibleDocument: "KJV",
                    bibleVersification: "KJVA",
                    bibleBook: 0,
                    bibleChapterNo: 1,
                    bibleVerseNo: 1,
                    currentCategoryName: "BIBLE",
                    jsState: #"{"scrollY":0}"#
                )
            ],
            historyItems: []
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalWorkspaces(
            from: initialSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        logEntryStore.replaceEntries(initialLogEntries, for: .workspaces)
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let hiddenLabelID = UUID(uuidString: "c6400000-0000-0000-0000-000000000003")!
        settingsStore.setString("remote_sync_device_identifier", value: "ios-device")
        let workspaceDisplaySettings = completeTextDisplaySettings(
            seed: 20,
            hiddenLabelID: hiddenLabelID
        )
        let pageDisplaySettings = completeTextDisplaySettings(
            seed: 40,
            hiddenLabelID: hiddenLabelID
        )
        let globalDisplaySettings = completeTextDisplaySettings(
            seed: 60,
            hiddenLabelID: hiddenLabelID
        )
        let workspaceDisplayFidelity = RemoteSyncWorkspaceTextDisplaySettingsFidelity(
            autoTrackReading: true,
            scrollHelperLines: false,
            scrollHelperLineStyle: 2,
            showPageButtons: true
        )
        let pageDisplayFidelity = RemoteSyncWorkspaceTextDisplaySettingsFidelity(
            autoTrackReading: false,
            scrollHelperLines: true,
            scrollHelperLineStyle: 3,
            showPageButtons: false
        )
        let globalDisplayFidelity = RemoteSyncWorkspaceTextDisplaySettingsFidelity(
            autoTrackReading: true,
            scrollHelperLines: true,
            scrollHelperLineStyle: 4,
            showPageButtons: true
        )
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        try fidelityStore.setGlobalTextDisplayEntry(
            id: RemoteSyncCurrentGlobalTextDisplaySettingsRow.androidSingletonID,
            fidelity: globalDisplayFidelity
        )

        let workspace = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<Workspace>()).first)
        workspace.name = "Travel Updated"
        workspace.textDisplaySettings = workspaceDisplaySettings
        let pageManager = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<PageManager>()).first)
        pageManager.jsState = #"{"scrollY":240}"#
        pageManager.textDisplaySettings = pageDisplaySettings
        try fidelityStore.setTextDisplayFidelity(
            workspaceDisplayFidelity,
            forWorkspaceID: workspaceID
        )
        try fidelityStore.setTextDisplayFidelity(
            pageDisplayFidelity,
            forPageManagerWindowID: windowID
        )
        try fidelityStore.setLabelOverride(
            RemoteSyncCurrentWorkspaceLabelOverrideRow(
                workspaceID: workspaceID,
                labelID: hiddenLabelID,
                overrideMode: 3
            )
        )
        let globalDisplayData = try JSONEncoder().encode(globalDisplaySettings)
        let mutationJournal = RemoteSyncMutationJournalService(nowProvider: { 2_000 })
        try settingsStore.performJournaledSave {
            settingsStore.setString(
                SettingsStore.globalTextDisplaySettingsKey,
                value: String(decoding: globalDisplayData, as: UTF8.self)
            )
            try mutationJournal.recordLocalChanges(
                for: .workspaces,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        }

        let currentSnapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(currentSnapshot.labelOverrideRowsByKey.count, 1)
        XCTAssertEqual(currentSnapshot.globalTextDisplayRowsByKey.count, 1)
        XCTAssertEqual(
            Set(try mutationJournal.pendingMutations(for: .workspaces, settingsStore: settingsStore)
                .values.map(\.entry.tableName)),
            ["Workspace", "PageManager", "WorkspaceLabelOverride", "GlobalTextDisplaySettings"]
        )

        let adapter = WorkspaceMockRemoteSyncAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-workspaces/ios-device/1.24.sqlite3.gz",
                name: "1.24.sqlite3.gz",
                size: 0,
                timestamp: 2_000,
                parentID: "/org.andbible.ios-sync-workspaces/ios-device",
                mimeType: "application/gzip"
            )
        )
        let service = RemoteSyncWorkspacePatchUploadService(
            adapter: adapter,
            nowProvider: { 2_000 }
        )

        let report = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-workspaces/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let unwrappedReport = try XCTUnwrap(report)
        XCTAssertEqual(unwrappedReport.patchNumber, 1)
        XCTAssertEqual(unwrappedReport.upsertedWorkspaceCount, 1)
        XCTAssertEqual(unwrappedReport.upsertedWindowCount, 0)
        XCTAssertEqual(unwrappedReport.upsertedPageManagerCount, 1)
        XCTAssertEqual(unwrappedReport.upsertedLabelOverrideCount, 1)
        XCTAssertEqual(unwrappedReport.upsertedGlobalTextDisplaySettingsCount, 1)
        XCTAssertEqual(unwrappedReport.deletedRowCount, 0)
        XCTAssertEqual(unwrappedReport.logEntryCount, 4)
        XCTAssertGreaterThan(unwrappedReport.lastUpdated, 2_000)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-workspaces/ios-device"],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-workspaces/ios-device"],
                name: "1.24.sqlite3.gz",
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .upload(
                name: "1.24.sqlite3.gz",
                parentID: "/org.andbible.ios-sync-workspaces/ios-device",
                contentType: NextCloudSyncAdapter.gzipMimeType
            )
        ])

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedArchive = try XCTUnwrap(uploadedFiles.first)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploaded-workspace-patch-\(UUID().uuidString).sqlite3.gz")
        let databaseURL = archiveURL.deletingPathExtension()
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: databaseURL)
        }
        try uploadedArchive.data.write(to: archiveURL, options: .atomic)
        let patchDatabaseData = try workspaceGunzipTestData(uploadedArchive.data)
        try patchDatabaseData.write(to: databaseURL, options: .atomic)

        let metadataSnapshot = try metadataRestoreService.readSnapshot(from: databaseURL)
        XCTAssertEqual(metadataSnapshot.logEntries.count, 4)
        XCTAssertEqual(
            Set(metadataSnapshot.logEntries.map(\.tableName)),
            ["Workspace", "PageManager", "WorkspaceLabelOverride", "GlobalTextDisplaySettings"]
        )
        XCTAssertEqual(Set(metadataSnapshot.logEntries.map(\.sourceDevice)), ["ios-device"])

        let secondContainer = try makeWorkspaceRestoreModelContainer()
        let secondModelContext = ModelContext(secondContainer)
        let secondSettingsStore = SettingsStore(modelContext: secondModelContext)
        _ = try restoreService.replaceLocalWorkspaces(
            from: initialSnapshot,
            modelContext: secondModelContext,
            settingsStore: secondSettingsStore
        )
        let secondLogEntryStore = RemoteSyncLogEntryStore(settingsStore: secondSettingsStore)
        secondLogEntryStore.replaceEntries(initialLogEntries, for: .workspaces)

        let stagedArchive = RemoteSyncStagedPatchArchive(
            patch: RemoteSyncDiscoveredPatch(
                sourceDevice: "ios-device",
                patchNumber: 1,
                schemaVersion: 24,
                file: RemoteSyncFile(
                    id: "/org.andbible.ios-sync-workspaces/ios-device/1.24.sqlite3.gz",
                    name: "1.24.sqlite3.gz",
                    size: Int64(uploadedArchive.data.count),
                    timestamp: 2_000,
                    parentID: "/org.andbible.ios-sync-workspaces/ios-device",
                    mimeType: NextCloudSyncAdapter.gzipMimeType
                )
            ),
            archiveFileURL: archiveURL
        )

        let replayReport = try patchApplyService.applyPatchArchives(
            [stagedArchive],
            modelContext: secondModelContext,
            settingsStore: secondSettingsStore
        )
        XCTAssertEqual(replayReport.appliedPatchCount, 1)
        XCTAssertEqual(replayReport.appliedLogEntryCount, 4)
        XCTAssertEqual(replayReport.skippedLogEntryCount, 0)

        let replayedWorkspace = try XCTUnwrap(try secondModelContext.fetch(FetchDescriptor<Workspace>()).first)
        XCTAssertEqual(replayedWorkspace.name, "Travel Updated")
        XCTAssertEqual(replayedWorkspace.textDisplaySettings, workspaceDisplaySettings)
        let replayedPageManager = try XCTUnwrap(try secondModelContext.fetch(FetchDescriptor<PageManager>()).first)
        XCTAssertEqual(replayedPageManager.jsState, #"{"scrollY":240}"#)
        XCTAssertEqual(replayedPageManager.textDisplaySettings, pageDisplaySettings)
        let replayedFidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: secondSettingsStore)
        XCTAssertEqual(
            replayedFidelityStore.textDisplayFidelity(forWorkspaceID: workspaceID),
            workspaceDisplayFidelity
        )
        XCTAssertEqual(
            replayedFidelityStore.textDisplayFidelity(forPageManagerWindowID: windowID),
            pageDisplayFidelity
        )
        XCTAssertEqual(
            replayedFidelityStore.allLabelOverrides(),
            [
                RemoteSyncCurrentWorkspaceLabelOverrideRow(
                    workspaceID: workspaceID,
                    labelID: hiddenLabelID,
                    overrideMode: 3
                )
            ]
        )
        XCTAssertEqual(secondSettingsStore.storedGlobalTextDisplaySettings(), globalDisplaySettings)
        XCTAssertEqual(
            replayedFidelityStore.globalTextDisplayEntry()?.fidelity,
            globalDisplayFidelity
        )

        XCTAssertEqual(
            patchStatusStore.statuses(for: .workspaces),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 1,
                    sizeBytes: unwrappedReport.uploadedFile.size,
                    appliedDate: 2_000
                )
            ]
        )
        XCTAssertEqual(
            stateStore.progressState(for: .workspaces).lastPatchWritten,
            unwrappedReport.lastUpdated
        )
        XCTAssertEqual(logEntryStore.entries(for: .workspaces).count, 5)

        let secondReport = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-workspaces/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertNil(secondReport)
        let uploadedFilesAfterSecondPass = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(uploadedFilesAfterSecondPass.count, 1)
    }

    /**
     Verifies that workspace initial restore refreshes the outbound fingerprint baseline so later local deletes emit delete patches.
     */
    func testRemoteSyncWorkspacePatchUploadDetectsDeleteAfterInitialRestoreRefresh() async throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let metadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService()
        let restoreDispatcher = RemoteSyncInitialBackupRestoreService()

        let workspaceID = UUID(uuidString: "c6500000-0000-0000-0000-000000000001")!
        let databaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(id: workspaceID, name: "Restore Me", orderNumber: 0)
            ],
            windows: [],
            pageManagers: [],
            historyItems: [],
            logEntries: []
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let stagedBackup = RemoteSyncStagedInitialBackup(
            remoteFile: RemoteSyncFile(
                id: "/org.andbible.ios-sync-workspaces/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 1,
                timestamp: 1_500,
                parentID: "/org.andbible.ios-sync-workspaces",
                mimeType: "application/gzip"
            ),
            databaseFileURL: databaseURL,
            schemaVersion: 24
        )

        _ = try restoreDispatcher.restoreInitialBackup(
            stagedBackup,
            category: .workspaces,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let restoredWorkspace = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<Workspace>()).first)
        XCTAssertTrue(
            RemoteSyncLogEntryStore(settingsStore: settingsStore)
                .entries(for: .workspaces).isEmpty
        )
        let acceptedBaseline = try XCTUnwrap(
            RemoteSyncWorkspaceSnapshotService().storedAcceptedBaseline(
                settingsStore: settingsStore
            )
        )
        XCTAssertEqual(acceptedBaseline.generation.rowsByKey.count, 1)
        settingsStore.setString("remote_sync_device_identifier", value: "ios-device")
        modelContext.delete(restoredWorkspace)
        try RemoteSyncMutationJournalService.savePendingGraphChanges(
            for: .workspaces,
            modelContext: modelContext
        )
        let pendingDeletion = try XCTUnwrap(
            RemoteSyncMutationJournalService()
                .pendingMutations(for: .workspaces, settingsStore: settingsStore)
                .values.first
        )
        XCTAssertEqual(pendingDeletion.entry.tableName, "Workspace")
        XCTAssertEqual(pendingDeletion.entry.type, .delete)
        XCTAssertNil(pendingDeletion.stateFingerprint)

        let adapter = WorkspaceMockRemoteSyncAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-workspaces/ios-device/1.24.sqlite3.gz",
                name: "1.24.sqlite3.gz",
                size: 0,
                timestamp: 2_000,
                parentID: "/org.andbible.ios-sync-workspaces/ios-device",
                mimeType: "application/gzip"
            )
        )
        let service = RemoteSyncWorkspacePatchUploadService(
            adapter: adapter,
            nowProvider: { 2_000 }
        )

        let report = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-workspaces/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let unwrappedReport = try XCTUnwrap(report)
        XCTAssertEqual(unwrappedReport.upsertedWorkspaceCount, 0)
        XCTAssertEqual(unwrappedReport.upsertedWindowCount, 0)
        XCTAssertEqual(unwrappedReport.upsertedPageManagerCount, 0)
        XCTAssertEqual(unwrappedReport.deletedRowCount, 1)
        XCTAssertEqual(unwrappedReport.logEntryCount, 1)

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedArchive = try XCTUnwrap(uploadedFiles.first)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploaded-workspace-delete-\(UUID().uuidString).sqlite3.gz")
        let patchDatabaseURL = archiveURL.deletingPathExtension()
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: patchDatabaseURL)
        }
        try uploadedArchive.data.write(to: archiveURL, options: .atomic)
        let patchDatabaseData = try workspaceGunzipTestData(uploadedArchive.data)
        try patchDatabaseData.write(to: patchDatabaseURL, options: .atomic)

        let metadataSnapshot = try metadataRestoreService.readSnapshot(from: patchDatabaseURL)
        XCTAssertEqual(metadataSnapshot.logEntries.count, 1)
        XCTAssertEqual(metadataSnapshot.logEntries[0].tableName, "Workspace")
        XCTAssertEqual(metadataSnapshot.logEntries[0].type, .delete)
        XCTAssertEqual(metadataSnapshot.logEntries[0].entityID1, .blob(uuidBlob(workspaceID)))
        XCTAssertEqual(metadataSnapshot.logEntries[0].entityID2, .text(""))
    }

    /**
     Verifies that a ready workspace category uploads one sparse local patch before discovering that
     no newer remote patches exist.
     */
    func testRemoteSyncSynchronizationServiceUploadsLocalWorkspaceChangesWhenNoRemotePatchesExist() async throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let snapshotService = RemoteSyncWorkspaceSnapshotService()
        let restoreService = RemoteSyncWorkspaceRestoreService()

        let syncFolderID = "/org.andbible.ios-sync-workspaces"
        let deviceFolderID = "/org.andbible.ios-sync-workspaces/ios-device"
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: deviceFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .workspaces
        )

        let workspaceID = UUID(uuidString: "c6600000-0000-0000-0000-000000000001")!
        let windowID = UUID(uuidString: "c6600000-0000-0000-0000-000000000002")!
        let initialDatabaseURL = try makeAndroidWorkspacesDatabase(
            workspaces: [
                .init(id: workspaceID, name: "Travel", orderNumber: 0)
            ],
            windows: [
                .init(
                    id: windowID,
                    workspaceID: workspaceID,
                    isSynchronized: true,
                    isPinMode: false,
                    isLinksWindow: false,
                    orderNumber: 0,
                    syncGroup: 0,
                    layoutState: "split",
                    layoutWeight: 1.0
                )
            ],
            pageManagers: [
                .init(
                    windowID: windowID,
                    bibleDocument: "KJV",
                    bibleVersification: "KJVA",
                    bibleBook: 0,
                    bibleChapterNo: 1,
                    bibleVerseNo: 1,
                    currentCategoryName: "BIBLE",
                    jsState: #"{"scrollY":0}"#
                )
            ],
            historyItems: []
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalWorkspaces(
            from: initialSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        logEntryStore.replaceEntries([
            .init(
                tableName: "Workspace",
                entityID1: .blob(uuidBlob(workspaceID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            .init(
                tableName: "Window",
                entityID1: .blob(uuidBlob(windowID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            .init(
                tableName: "PageManager",
                entityID1: .blob(uuidBlob(windowID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
        ], for: .workspaces)
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let workspace = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<Workspace>()).first)
        workspace.name = "Travel Renamed"
        let pageManager = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<PageManager>()).first)
        pageManager.jsState = #"{"scrollY":128}"#
        try modelContext.save()

        let adapter = WorkspaceMockRemoteSyncAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: "device-known-ios-device-secret"
        )
        await adapter.enqueueListFilesResult([])
        await adapter.enqueueListFilesResult([])
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(deviceFolderID)/1.24.sqlite3.gz",
                name: "1.24.sqlite3.gz",
                size: 0,
                timestamp: 4_000_000,
                parentID: deviceFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 4_000_000 }
        )

        let outcome = try await service.synchronize(
            .workspaces,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        guard case .synchronized(let report) = outcome else {
            return XCTFail("Expected synchronized outcome")
        }

        XCTAssertEqual(report.category, .workspaces)
        XCTAssertNil(report.initialRestoreReport)
        XCTAssertNil(report.patchReplayReport)
        XCTAssertEqual(report.discoveredPatchCount, 0)
        XCTAssertEqual(report.lastSynchronized, 4_000_000)

        guard case .workspaces(let uploadReport)? = report.patchUploadReport else {
            return XCTFail("Expected workspace patch upload report")
        }

        XCTAssertEqual(uploadReport.patchNumber, 1)
        XCTAssertEqual(uploadReport.upsertedWorkspaceCount, 1)
        XCTAssertEqual(uploadReport.upsertedWindowCount, 0)
        XCTAssertEqual(uploadReport.upsertedPageManagerCount, 1)
        XCTAssertEqual(uploadReport.deletedRowCount, 0)
        XCTAssertEqual(uploadReport.logEntryCount, 2)
        XCTAssertGreaterThan(uploadReport.lastUpdated, 4_000_000)
        XCTAssertEqual(report.lastPatchWritten, uploadReport.lastUpdated)
        XCTAssertEqual(uploadReport.uploadedFile.name, "1.24.sqlite3.gz")
        XCTAssertEqual(uploadReport.uploadedFile.parentID, deviceFolderID)

        XCTAssertEqual(
            patchStatusStore.statuses(for: .workspaces),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 1,
                    sizeBytes: uploadReport.uploadedFile.size,
                    appliedDate: 4_000_000
                )
            ]
        )
        XCTAssertEqual(
            stateStore.progressState(for: .workspaces).lastPatchWritten,
            uploadReport.lastUpdated
        )
        XCTAssertEqual(stateStore.progressState(for: .workspaces).lastSynchronized, 4_000_000)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .isSyncFolderKnown(
                syncFolderID: syncFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            .listFiles(
                parentIDs: [deviceFolderID],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: [deviceFolderID],
                name: "1.24.sqlite3.gz",
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .upload(
                name: "1.24.sqlite3.gz",
                parentID: deviceFolderID,
                contentType: NextCloudSyncAdapter.gzipMimeType
            ),
            .listFiles(
                parentIDs: [syncFolderID],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
        ])
    }

    /**
     Verifies a workspace edit made while remote publication is suspended remains pending.

     Acceptance publishes the immutable uploaded fingerprint rather than re-reading the live graph.
     A second patch containing the newer workspace name proves the concurrent edit was retained.
     */
    func testWorkspaceUploadKeepsInFlightEditDirtyForNextPatch() async throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let snapshotService = RemoteSyncWorkspaceSnapshotService()
        let workspace = Workspace(name: "Accepted", orderNumber: 0)
        modelContext.insert(workspace)
        try modelContext.save()
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        workspace.name = "Uploaded generation"
        try modelContext.save()
        let uploadedSnapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let workspaceKey = try XCTUnwrap(uploadedSnapshot.workspaceRowsByKey.first?.key)
        let adapter = RemoteSyncDurableOutboxTestAdapter(
            uploadMetadata: [
                .init(timestamp: 28_000),
                .init(timestamp: 29_000),
            ]
        )
        await adapter.suspendNextUpload()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-inflight-edit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RemoteSyncWorkspacePatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: directory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 27_000 }
        )

        let uploadTask = Task {
            try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/workspaces/ios-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        }
        await adapter.waitUntilUploadStarts()
        workspace.name = "Newer local generation"
        try modelContext.save()
        await adapter.resumeUpload()

        let firstResult = try await uploadTask.value
        XCTAssertEqual(try XCTUnwrap(firstResult).patchNumber, 1)
        XCTAssertEqual(
            RemoteSyncRowFingerprintStore(settingsStore: settingsStore).fingerprint(
                forLogKey: workspaceKey,
                category: .workspaces
            ),
            uploadedSnapshot.fingerprintsByKey[workspaceKey]
        )
        let currentSnapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertNotEqual(
            currentSnapshot.fingerprintsByKey[workspaceKey],
            uploadedSnapshot.fingerprintsByKey[workspaceKey]
        )

        let secondResult = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/workspaces/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(try XCTUnwrap(secondResult).patchNumber, 2)
        let uploads = await adapter.uploads()
        XCTAssertEqual(
            uploads.map(\.name),
            ["1.24.sqlite3.gz", "2.24.sqlite3.gz"]
        )
    }

    /**
     Verifies remote success followed by local failure resumes the exact durable workspace generation.

     A new service instance reconciles existing bytes and accepts without another create. Sync status
     uses server size/time, while `lastPatchWritten` preserves the original generation watermark.
     */
    func testWorkspaceUploadAcceptanceFailureResumesExactOutboxGeneration() async throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let snapshotService = RemoteSyncWorkspaceSnapshotService()
        let workspace = Workspace(name: "Accepted", orderNumber: 0)
        modelContext.insert(workspace)
        try modelContext.save()
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let acceptedSnapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let workspaceKey = try XCTUnwrap(acceptedSnapshot.workspaceRowsByKey.first?.key)
        workspace.name = "Pending upload"
        try modelContext.save()

        let adapter = RemoteSyncDurableOutboxTestAdapter(
            uploadMetadata: [.init(timestamp: 32_000, size: 76_543)]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-acceptance-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outboxDirectory = directory.appendingPathComponent("outbox", isDirectory: true)
        let failingService = RemoteSyncWorkspacePatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: outboxDirectory,
            nowProvider: { 30_000 },
            finalAcceptanceCheckpoint: {
                throw NSError(domain: "WorkspaceUploadAcceptance", code: 81)
            }
        )

        do {
            _ = try await failingService.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/workspaces/ios-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected workspace acceptance failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, "WorkspaceUploadAcceptance")
        }

        XCTAssertNotNil(settingsStore.getString(RemoteSyncWorkspacePatchUploadService.pendingUploadKey))
        XCTAssertEqual(
            RemoteSyncRowFingerprintStore(settingsStore: settingsStore).fingerprint(
                forLogKey: workspaceKey,
                category: .workspaces
            ),
            acceptedSnapshot.fingerprintsByKey[workspaceKey]
        )
        XCTAssertTrue(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .workspaces).isEmpty
        )
        XCTAssertNil(
            RemoteSyncStateStore(settingsStore: settingsStore)
                .progressState(for: .workspaces).lastPatchWritten
        )

        let retryService = RemoteSyncWorkspacePatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: outboxDirectory,
            nowProvider: { 99_000 }
        )
        let retryResult = try await retryService.resumePendingUploadIfPresent(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/workspaces/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let retryReport = try XCTUnwrap(retryResult)
        XCTAssertEqual(retryReport.patchNumber, 1)
        let retryUploads = await adapter.uploads()
        XCTAssertEqual(retryUploads.count, 1)
        XCTAssertNil(settingsStore.getString(RemoteSyncWorkspacePatchUploadService.pendingUploadKey))
        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .workspaces),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 1,
                    sizeBytes: 76_543,
                    appliedDate: 32_000
                )
            ]
        )
        XCTAssertEqual(
            RemoteSyncStateStore(settingsStore: settingsStore)
                .progressState(for: .workspaces).lastPatchWritten,
            retryReport.lastUpdated
        )
        XCTAssertGreaterThan(retryReport.lastUpdated, 30_000)
    }

    /**
     Verifies cancellation after a workspace archive becomes durable retains retryable outbox state.

     Cancellation after conditional create must leave acceptance metadata untouched. Resume-only then
     reconciles the same bytes and accepts patch one without creating a replacement generation.
     */
    func testWorkspaceUploadCancellationRetainsDurableGenerationForResume() async throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let snapshotService = RemoteSyncWorkspaceSnapshotService()
        let workspace = Workspace(name: "Accepted", orderNumber: 0)
        modelContext.insert(workspace)
        try modelContext.save()
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        workspace.name = "Pending"
        try modelContext.save()

        let adapter = RemoteSyncDurableOutboxTestAdapter(
            uploadMetadata: [.init(timestamp: 35_000)]
        )
        await adapter.suspendNextUpload()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-cancel-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RemoteSyncWorkspacePatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: directory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 34_000 }
        )
        let uploadTask = Task {
            try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/workspaces/ios-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        }
        await adapter.waitUntilUploadStarts()
        uploadTask.cancel()
        await adapter.resumeUpload()

        do {
            _ = try await uploadTask.value
            XCTFail("Expected workspace upload cancellation")
        } catch is CancellationError {
            // Expected: pending metadata remains durable for the next lifecycle pass.
        }
        XCTAssertNotNil(settingsStore.getString(RemoteSyncWorkspacePatchUploadService.pendingUploadKey))
        XCTAssertTrue(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .workspaces).isEmpty
        )
        let resumed = try await service.resumePendingUploadIfPresent(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/workspaces/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(try XCTUnwrap(resumed).patchNumber, 1)
        let resumedUploads = await adapter.uploads()
        XCTAssertEqual(resumedUploads.count, 1)
    }

    /**
     Verifies absent local status allocates after remote workspace history and corruption fails closed.

     Remote patch seven must yield patch eight. Malformed accepted metadata on the next pass must abort
     before another create rather than resetting the local sequence to zero.
     */
    func testWorkspaceUploadUsesRemoteNumberingAndRejectsCorruptLocalStatus() async throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let snapshotService = RemoteSyncWorkspaceSnapshotService()
        let workspace = Workspace(name: "Accepted", orderNumber: 0)
        modelContext.insert(workspace)
        try modelContext.save()
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        workspace.name = "Dirty"
        try modelContext.save()

        let deviceFolderID = "/workspaces/ios-device"
        let adapter = RemoteSyncDurableOutboxTestAdapter(
            uploadMetadata: [.init(timestamp: 38_000)]
        )
        await adapter.seedRemoteFile(
            name: "7.1.sqlite3.gz",
            parentID: deviceFolderID,
            data: Data("accepted workspace history".utf8),
            timestamp: 37_000
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-remote-numbering-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RemoteSyncWorkspacePatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: directory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 37_500 }
        )

        let firstResult = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: deviceFolderID),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(try XCTUnwrap(firstResult).patchNumber, 8)
        let numberedUploads = await adapter.uploads()
        XCTAssertEqual(numberedUploads.map(\.name), ["8.24.sqlite3.gz"])

        workspace.name = "Dirty again"
        try modelContext.save()
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let corruptKey = patchStatusStore.key(
            for: .workspaces,
            sourceDevice: "ios-device",
            patchNumber: 9
        )
        settingsStore.setString(corruptKey, value: "{not-json")
        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: deviceFolderID),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected corrupt workspace patch status to fail closed")
        } catch let error as RemoteSyncPatchStatusStoreError {
            XCTAssertEqual(error, .invalidStoredStatus(corruptKey))
        }
        let uploadsAfterCorruption = await adapter.uploads()
        XCTAssertEqual(uploadsAfterCorruption.count, 1)
    }

    /**
     Verifies a workspace outbox cannot cross destinations without explicit lifecycle cleanup.

     A failed old-folder acceptance must block a new destination. Explicit discard retains the old
     baseline, allowing the current workspace graph to rebuild as patch one in the replacement folder.
     */
    func testWorkspaceDestinationReplacementRequiresExplicitPendingCleanup() async throws {
        let container = try makeWorkspaceRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let snapshotService = RemoteSyncWorkspaceSnapshotService()
        let workspace = Workspace(name: "Accepted", orderNumber: 0)
        modelContext.insert(workspace)
        try modelContext.save()
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        workspace.name = "Dirty"
        try modelContext.save()

        let adapter = RemoteSyncDurableOutboxTestAdapter(
            uploadMetadata: [
                .init(timestamp: 41_000),
                .init(timestamp: 42_000),
            ]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-destination-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outboxDirectory = directory.appendingPathComponent("outbox", isDirectory: true)
        let failingService = RemoteSyncWorkspacePatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: outboxDirectory,
            nowProvider: { 40_000 },
            finalAcceptanceCheckpoint: {
                throw NSError(domain: "WorkspaceDestination", code: 91)
            }
        )
        do {
            _ = try await failingService.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/workspaces/old-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected workspace acceptance failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, "WorkspaceDestination")
        }

        let replacementService = RemoteSyncWorkspacePatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: outboxDirectory,
            nowProvider: { 40_500 }
        )
        do {
            _ = try await replacementService.resumePendingUploadIfPresent(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/workspaces/new-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected mismatched workspace outbox to fail closed")
        } catch let error as RemoteSyncWorkspacePatchUploadError {
            XCTAssertEqual(
                error,
                .pendingUploadDestinationMismatch(
                    stored: "/workspaces/old-device",
                    requested: "/workspaces/new-device"
                )
            )
        }

        try replacementService.discardPendingUploadForDestinationReplacement(
            settingsStore: settingsStore
        )
        let replacementResult = try await replacementService.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/workspaces/new-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(try XCTUnwrap(replacementResult).patchNumber, 1)
        let destinationUploads = await adapter.uploads()
        XCTAssertEqual(
            destinationUploads.map(\.parentID),
            ["/workspaces/old-device", "/workspaces/new-device"]
        )
    }

    /**
     Minimal Android `TextDisplaySettings` fixture projected onto SQLite columns.
     */
    private struct AndroidTextDisplayFixture {
        var strongsMode: Int? = nil
        var showMorphology: Bool? = nil
        var showFootNotes: Bool? = nil
        var showFootNotesInline: Bool? = nil
        var expandXrefs: Bool? = nil
        var showXrefs: Bool? = nil
        var showRedLetters: Bool? = nil
        var showSectionTitles: Bool? = nil
        var showVerseNumbers: Bool? = nil
        var showVersePerLine: Bool? = nil
        var showBookmarks: Bool? = nil
        var showMyNotes: Bool? = nil
        var justifyText: Bool? = nil
        var hyphenation: Bool? = nil
        var topMargin: Int? = nil
        var fontSize: Int? = nil
        var fontFamily: String? = nil
        var lineSpacing: Int? = nil
        var bookmarksHideLabelsJSON: String? = nil
        var showPageNumber: Bool? = nil
        var marginLeft: Int? = nil
        var marginRight: Int? = nil
        var maxWidth: Int? = nil
        var dayTextColor: Int? = nil
        var dayBackground: Int? = nil
        var dayNoise: Int? = nil
        var nightTextColor: Int? = nil
        var nightBackground: Int? = nil
        var nightNoise: Int? = nil
    }

    /**
     Minimal Android `WorkspaceSettings` fixture projected onto SQLite columns.
     */
    private struct AndroidWorkspaceSettingsFixture {
        var enableTiltToScroll: Bool = false
        var enableReverseSplitMode: Bool = false
        var autoPin: Bool = true
        var restoreButtonsVisible: Bool = true
        var speakSettingsJSON: String? = nil
        var recentLabelsJSON: String? = nil
        var autoAssignLabelsJSON: String? = nil
        var autoAssignPrimaryLabelID: UUID? = nil
        var studyPadCursorsJSON: String? = nil
        var hideCompareDocumentsJSON: String? = nil
        var limitAmbiguousModalSize: Bool = false
        var workspaceColor: Int? = nil
    }

    /**
     One Android `Workspace` fixture row used to build temporary SQLite backups.
     */
    private struct AndroidWorkspaceRow {
        let id: UUID
        let name: String
        let contentsText: String?
        let orderNumber: Int
        let textDisplaySettings: AndroidTextDisplayFixture?
        let workspaceSettings: AndroidWorkspaceSettingsFixture
        let unPinnedWeight: Double?
        let maximizedWindowID: UUID?
        let primaryTargetLinksWindowID: UUID?

        init(
            id: UUID,
            name: String,
            contentsText: String? = nil,
            orderNumber: Int,
            textDisplaySettings: AndroidTextDisplayFixture? = nil,
            workspaceSettings: AndroidWorkspaceSettingsFixture = .init(),
            unPinnedWeight: Double? = nil,
            maximizedWindowID: UUID? = nil,
            primaryTargetLinksWindowID: UUID? = nil
        ) {
            self.id = id
            self.name = name
            self.contentsText = contentsText
            self.orderNumber = orderNumber
            self.textDisplaySettings = textDisplaySettings
            self.workspaceSettings = workspaceSettings
            self.unPinnedWeight = unPinnedWeight
            self.maximizedWindowID = maximizedWindowID
            self.primaryTargetLinksWindowID = primaryTargetLinksWindowID
        }
    }

    /**
     One Android `Window` fixture row used to build temporary SQLite backups.
     */
    private struct AndroidWorkspaceWindowRow {
        let id: UUID
        let workspaceID: UUID
        let isSynchronized: Bool
        let isPinMode: Bool
        let isLinksWindow: Bool
        let orderNumber: Int
        let targetLinksWindowID: UUID?
        let syncGroup: Int
        let layoutState: String
        let layoutWeight: Double

        init(
            id: UUID,
            workspaceID: UUID,
            isSynchronized: Bool,
            isPinMode: Bool,
            isLinksWindow: Bool,
            orderNumber: Int,
            targetLinksWindowID: UUID? = nil,
            syncGroup: Int,
            layoutState: String,
            layoutWeight: Double
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
     One Android `PageManager` fixture row used to build temporary SQLite backups.
     */
    private struct AndroidWorkspacePageManagerRow {
        let windowID: UUID
        let bibleDocument: String?
        let bibleVersification: String
        let bibleBook: Int
        let bibleChapterNo: Int
        let bibleVerseNo: Int
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
        let textDisplaySettings: AndroidTextDisplayFixture?
        let jsState: String?

        init(
            windowID: UUID,
            bibleDocument: String? = nil,
            bibleVersification: String = "KJVA",
            bibleBook: Int = 0,
            bibleChapterNo: Int = 1,
            bibleVerseNo: Int = 1,
            commentaryDocument: String? = nil,
            commentaryAnchorOrdinal: Int? = nil,
            commentarySourceBookAndKey: String? = nil,
            dictionaryDocument: String? = nil,
            dictionaryKey: String? = nil,
            dictionaryAnchorOrdinal: Int? = nil,
            generalBookDocument: String? = nil,
            generalBookKey: String? = nil,
            generalBookAnchorOrdinal: Int? = nil,
            mapDocument: String? = nil,
            mapKey: String? = nil,
            mapAnchorOrdinal: Int? = nil,
            currentCategoryName: String,
            textDisplaySettings: AndroidTextDisplayFixture? = nil,
            jsState: String? = nil
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
     One Android `HistoryItem` fixture row used to build temporary SQLite backups.
     */
    private struct AndroidWorkspaceHistoryItemRow {
        let remoteID: Int64
        let windowID: UUID
        let createdAt: Date
        let document: String
        let key: String
        let anchorOrdinal: Int?
    }

    /**
     One typed SQLite scalar fixture used when building Android sync-metadata rows.
     */
    private enum AndroidSQLiteFixtureValue: Equatable {
        /// SQLite `NULL` fixture payload.
        case null

        /// SQLite signed integer fixture payload.
        case integer(Int64)

        /// SQLite floating-point fixture payload.
        case real(Double)

        /// SQLite UTF-8 text fixture payload.
        case text(String)

        /// SQLite raw blob fixture payload.
        case blob(Data)
    }

    /**
     One Android `LogEntry` fixture row used to build temporary SQLite backups.
     */
    private struct AndroidLogEntryRow {
        let tableName: String
        let entityID1: AndroidSQLiteFixtureValue
        let entityID2: AndroidSQLiteFixtureValue
        let type: String
        let lastUpdated: Int64
        let sourceDevice: String
    }

    /**
     One Android `SyncStatus` fixture row used to build temporary SQLite backups.
     */
    private struct AndroidSyncStatusRow {
        let sourceDevice: String
        let patchNumber: Int64
        let sizeBytes: Int64
        let appliedDate: Int64
    }

    /**
     Runs one rejected-store direction of the workspace patch publication rollback contract.

     - Parameters:
       - rejectedStore: Graph or settings configuration that must reject the final transaction save.
       - temporaryDirectory: Directory containing the previously seeded graph and settings stores.
       - stagedArchive: Newer Android workspace patch whose effects must not become durable.
       - workspaceID: Existing workspace identifier modified by the patch.
       - windowID: Existing window/page-manager identifier that must remain related to the workspace.
       - historyID: Existing local history identifier that must survive unchanged.
       - oldLogEntry: Durable conflict baseline that must remain after rejected replay.
       - oldPatchStatus: Durable applied-patch status that must remain after rejected replay.
     - Side effects: Opens the target store read-only, attempts replay, observes the sole save, then
       reopens both stores writable for graph and bookkeeping assertions.
     - Failure modes: Rethrows container or fetch failures. XCTest assertions describe any partial
       graph, fidelity, conflict-log, patch-status, or fingerprint publication.
     */
    private func assertWorkspacePatchPublishRollback(
        whenRejecting rejectedStore: RejectedWorkspaceRestoreStore,
        temporaryDirectory: URL,
        stagedArchive: RemoteSyncStagedPatchArchive,
        workspaceID: UUID,
        windowID: UUID,
        historyID: UUID,
        oldLogEntry: RemoteSyncLogEntry,
        oldPatchStatus: RemoteSyncPatchStatus
    ) throws {
        try autoreleasepool {
            let rejectingStore = try makePersistentWorkspaceRestoreModelContainer(
                in: temporaryDirectory,
                graphAllowsSave: rejectedStore != .graph,
                settingsAllowsSave: rejectedStore != .settings
            )
            let modelContext = ModelContext(rejectingStore.container)
            modelContext.autosaveEnabled = false
            let settingsStore = SettingsStore(modelContext: modelContext)

            let finalSaveExpectation = expectation(
                description: "Workspace patch reaches final save with rejected \(rejectedStore.displayName)"
            )
            finalSaveExpectation.expectedFulfillmentCount = 1
            finalSaveExpectation.assertForOverFulfill = true
            let saveObserver = NotificationCenter.default.addObserver(
                forName: ModelContext.willSave,
                object: modelContext,
                queue: nil
            ) { _ in
                finalSaveExpectation.fulfill()
            }
            defer { NotificationCenter.default.removeObserver(saveObserver) }

            XCTAssertThrowsError(
                try RemoteSyncWorkspacePatchApplyService().applyPatchArchives(
                    [stagedArchive],
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            ) { error in
                let cocoaError = error as NSError
                XCTAssertEqual(cocoaError.domain, NSCocoaErrorDomain)
                XCTAssertEqual(cocoaError.code, NSFileWriteNoPermissionError)
            }
            wait(for: [finalSaveExpectation], timeout: 1)
            XCTAssertFalse(modelContext.hasChanges)
        }

        let reopenedStore = try makePersistentWorkspaceRestoreModelContainer(in: temporaryDirectory)
        let reopenedContext = ModelContext(reopenedStore.container)
        reopenedContext.autosaveEnabled = false
        let reopenedSettings = SettingsStore(modelContext: reopenedContext)

        let workspaces = try reopenedContext.fetch(FetchDescriptor<Workspace>())
        XCTAssertEqual(workspaces.map(\.id), [workspaceID])
        XCTAssertEqual(workspaces.first?.name, "Durable Patch Workspace")
        XCTAssertEqual(workspaces.first?.contentsText, "Keep patch generation")
        XCTAssertEqual(workspaces.first?.orderNumber, 0)

        let windows = try reopenedContext.fetch(FetchDescriptor<Window>())
        XCTAssertEqual(windows.map(\.id), [windowID])
        XCTAssertEqual(windows.first?.workspace?.id, workspaceID)
        XCTAssertEqual(windows.first?.syncGroup, 3)

        let pageManagers = try reopenedContext.fetch(FetchDescriptor<PageManager>())
        XCTAssertEqual(pageManagers.map(\.id), [windowID])
        XCTAssertEqual(pageManagers.first?.window?.id, windowID)
        XCTAssertEqual(pageManagers.first?.bibleDocument, "KJV")

        let historyItems = try reopenedContext.fetch(FetchDescriptor<HistoryItem>())
        XCTAssertEqual(historyItems.map(\.id), [historyID])
        XCTAssertEqual(historyItems.first?.window?.id, windowID)
        XCTAssertEqual(historyItems.first?.key, "Gen.1.1")

        XCTAssertEqual(reopenedSettings.activeWorkspaceId, workspaceID)
        XCTAssertEqual(
            RemoteSyncWorkspaceFidelityStore(settingsStore: reopenedSettings)
                .speakSettingsJSON(for: workspaceID),
            #"{"sleepTimer":15}"#
        )
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: reopenedSettings)
        XCTAssertEqual(
            logEntryStore.entry(
                for: .workspaces,
                tableName: "Workspace",
                entityID1: .blob(uuidBlob(workspaceID)),
                entityID2: .text("")
            ),
            oldLogEntry
        )
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: reopenedSettings)
        XCTAssertEqual(
            patchStatusStore.status(for: .workspaces, sourceDevice: "pixel", patchNumber: 1),
            oldPatchStatus
        )
        XCTAssertNil(
            patchStatusStore.status(for: .workspaces, sourceDevice: "pixel", patchNumber: 2)
        )
        XCTAssertEqual(
            RemoteSyncRowFingerprintStore(settingsStore: reopenedSettings).fingerprint(
                for: .workspaces,
                tableName: "Workspace",
                entityID1: .blob(uuidBlob(workspaceID)),
                entityID2: .text("")
            ),
            "durable-workspace-fingerprint"
        )
    }

    /**
     Runs one direction of the cross-store workspace rollback contract and verifies durable old state.

     - Parameters:
       - rejectedStore: Persistent store whose entity writes must reject the final save.
       - temporaryDirectory: Directory used to reopen the same stores after the failed save.
       - replacementSnapshot: Complete new Android workspace generation to stage.
       - oldWorkspaceID: Durable workspace identifier that must survive.
       - oldWindowID: Durable window/page-manager identifier that must survive.
       - oldHistoryID: Durable local history identifier that must survive.
       - replacementWorkspaceID: New workspace identifier that must not become durable.
       - replacementWindowID: New window/page-manager identifier that must not become durable.
     - Side effects: Opens the selected configuration read-only, attempts one restore, observes its
       final save, then reopens both configurations writable for durable assertions.
     - Failure modes: Rethrows fixture setup, SwiftData reopen, or fetch failures. XCTest assertions
       fail when restore does not throw, does not roll back its context, or persists any mixed generation.
     */
    private func assertWorkspaceRestoreRollback(
        whenRejecting rejectedStore: RejectedWorkspaceRestoreStore,
        temporaryDirectory: URL,
        replacementSnapshot: RemoteSyncAndroidWorkspaceSnapshot,
        oldWorkspaceID: UUID,
        oldWindowID: UUID,
        oldHistoryID: UUID,
        replacementWorkspaceID: UUID,
        replacementWindowID: UUID
    ) throws {
        try autoreleasepool {
            let rejectingStore = try makePersistentWorkspaceRestoreModelContainer(
                in: temporaryDirectory,
                graphAllowsSave: rejectedStore != .graph,
                settingsAllowsSave: rejectedStore != .settings
            )
            let modelContext = ModelContext(rejectingStore.container)
            modelContext.autosaveEnabled = false
            let settingsStore = SettingsStore(modelContext: modelContext)

            let finalSaveExpectation = expectation(
                description: "Workspace replacement reaches final save with rejected \(rejectedStore.displayName)"
            )
            finalSaveExpectation.expectedFulfillmentCount = 1
            finalSaveExpectation.assertForOverFulfill = true
            let saveObserver = NotificationCenter.default.addObserver(
                forName: ModelContext.willSave,
                object: modelContext,
                queue: nil
            ) { _ in
                finalSaveExpectation.fulfill()
            }
            defer { NotificationCenter.default.removeObserver(saveObserver) }

            XCTAssertThrowsError(
                try RemoteSyncWorkspaceRestoreService().replaceLocalWorkspaces(
                    from: replacementSnapshot,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            ) { error in
                let cocoaError = error as NSError
                XCTAssertEqual(cocoaError.domain, NSCocoaErrorDomain)
                XCTAssertEqual(cocoaError.code, NSFileWriteNoPermissionError)
            }
            wait(for: [finalSaveExpectation], timeout: 1)
            XCTAssertFalse(modelContext.hasChanges)
        }

        let reopenedStore = try makePersistentWorkspaceRestoreModelContainer(in: temporaryDirectory)
        let reopenedContext = ModelContext(reopenedStore.container)
        reopenedContext.autosaveEnabled = false
        let reopenedSettings = SettingsStore(modelContext: reopenedContext)
        let reopenedFidelity = RemoteSyncWorkspaceFidelityStore(settingsStore: reopenedSettings)

        let reopenedWorkspaces = try reopenedContext.fetch(FetchDescriptor<Workspace>())
        XCTAssertEqual(reopenedWorkspaces.map(\.id), [oldWorkspaceID])
        XCTAssertEqual(reopenedWorkspaces.first?.name, "Durable Workspace")
        XCTAssertEqual(reopenedWorkspaces.first?.contentsText, "Keep this graph")

        let reopenedWindows = try reopenedContext.fetch(FetchDescriptor<Window>())
        XCTAssertEqual(reopenedWindows.map(\.id), [oldWindowID])
        XCTAssertEqual(reopenedWindows.first?.workspace?.id, oldWorkspaceID)
        XCTAssertEqual(reopenedWindows.first?.syncGroup, 7)

        let reopenedPageManagers = try reopenedContext.fetch(FetchDescriptor<PageManager>())
        XCTAssertEqual(reopenedPageManagers.map(\.id), [oldWindowID])
        XCTAssertEqual(reopenedPageManagers.first?.window?.id, oldWindowID)
        XCTAssertEqual(reopenedPageManagers.first?.commentaryDocument, "MHC")
        XCTAssertEqual(reopenedPageManagers.first?.commentaryAnchorOrdinal, 123)

        let reopenedHistoryItems = try reopenedContext.fetch(FetchDescriptor<HistoryItem>())
        XCTAssertEqual(reopenedHistoryItems.map(\.id), [oldHistoryID])
        XCTAssertEqual(reopenedHistoryItems.first?.window?.id, oldWindowID)
        XCTAssertEqual(reopenedHistoryItems.first?.key, "Gen.1.1")
        XCTAssertEqual(reopenedHistoryItems.first?.anchorOrdinal, 4)

        XCTAssertEqual(reopenedSettings.activeWorkspaceId, oldWorkspaceID)
        XCTAssertEqual(reopenedFidelity.speakSettingsJSON(for: oldWorkspaceID), #"{"sleepTimer":15}"#)
        XCTAssertNil(reopenedFidelity.speakSettingsJSON(for: replacementWorkspaceID))
        XCTAssertEqual(
            reopenedFidelity.pageManagerEntry(for: oldWindowID),
            .init(
                windowID: oldWindowID,
                rawCurrentCategoryName: "COMMENTARY",
                commentarySourceBookAndKey: "GEN.1.1",
                dictionaryAnchorOrdinal: 11,
                generalBookAnchorOrdinal: 12,
                mapAnchorOrdinal: 13
            )
        )
        XCTAssertNil(reopenedFidelity.pageManagerEntry(for: replacementWindowID))
        XCTAssertEqual(reopenedFidelity.localHistoryItemID(for: 41), oldHistoryID)
        XCTAssertNil(reopenedFidelity.localHistoryItemID(for: 99))
    }

    /**
     Builds a fully populated native text-display value for Room workspace round-trip tests.

     - Parameters:
       - seed: Distinguishes workspace, page-manager, and global values.
       - hiddenLabelID: Bookmark label carried by Android's JSON-backed hidden-label column.
     - Returns: A value with every native field represented in Android workspace Room populated.
     - Side effects: none.
     - Failure modes: This deterministic fixture builder cannot fail.
     */
    private func completeTextDisplaySettings(
        seed: Int,
        hiddenLabelID: UUID
    ) -> TextDisplaySettings {
        var settings = TextDisplaySettings()
        settings.fontSize = seed + 1
        settings.fontFamily = "font-\(seed)"
        settings.lineSpacing = seed + 2
        settings.marginLeft = seed + 3
        settings.marginRight = seed + 4
        settings.maxWidth = seed + 5
        settings.topMargin = seed + 6
        settings.strongsMode = seed + 7
        settings.showMorphology = true
        settings.showFootNotes = false
        settings.showFootNotesInline = true
        settings.expandXrefs = false
        settings.showXrefs = true
        settings.showRedLetters = false
        settings.showSectionTitles = true
        settings.showVerseNumbers = false
        settings.showVersePerLine = true
        settings.showBookmarks = false
        settings.showMyNotes = true
        settings.justifyText = false
        settings.hyphenation = true
        settings.showPageNumber = false
        settings.infiniteScroll = true
        settings.nonStrongsWordItalic = false
        settings.showMarkAsReadButton = true
        settings.showTitleScrollButton = false
        settings.showMemorizationIndicators = true
        settings.showAiDocMarkers = false
        settings.pageScrollAmount = TextDisplaySettings.pageScrollAmountValues[seed % 6]
        settings.showOrdinals = true
        settings.dayTextColor = seed + 8
        settings.dayBackground = seed + 9
        settings.dayNoise = seed + 10
        settings.nightTextColor = seed + 11
        settings.nightBackground = seed + 12
        settings.nightNoise = seed + 13
        settings.bookmarksHideLabels = [hiddenLabelID]
        return settings
    }

    /**
     Creates an in-memory SwiftData container containing only the models needed for workspace restore tests.

     - Returns: Isolated in-memory model container for workspace restore assertions.
     - Side effects: allocates a new in-memory SwiftData store.
     - Failure modes:
       - rethrows `ModelContainer` creation failures
     */
    private func makeWorkspaceRestoreModelContainer() throws -> ModelContainer {
        let schema = Schema([
            Workspace.self,
            Window.self,
            PageManager.self,
            HistoryItem.self,
            Setting.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /**
     Creates production-shaped file-backed stores for durable workspace restore assertions.

     Workspace graph models and local `Setting` rows use separate configurations, matching the app's
     Cloud/local store boundary while omitting CloudKit itself. Calling this helper again with the
     same directory reopens the same two SQLite stores.

     - Parameters:
       - directoryURL: Existing temporary directory that owns both store files.
       - graphAllowsSave: Whether the workspace graph configuration accepts persistence writes.
       - settingsAllowsSave: Whether the local settings configuration accepts persistence writes.
     - Returns: Loaded model container plus graph/settings store URLs used by failure fixtures.
     - Side effects: Creates or opens `WorkspaceGraph.store` and `WorkspaceSettings.store` beneath
       `directoryURL`.
     - Failure modes: Rethrows SwiftData container/configuration errors.
     */
    private func makePersistentWorkspaceRestoreModelContainer(
        in directoryURL: URL,
        graphAllowsSave: Bool = true,
        settingsAllowsSave: Bool = true
    ) throws -> (container: ModelContainer, graphStoreURL: URL, localStoreURL: URL) {
        let graphModels: [any PersistentModel.Type] = [
            Workspace.self,
            Window.self,
            PageManager.self,
            HistoryItem.self,
        ]
        let localModels: [any PersistentModel.Type] = [Setting.self]
        let schema = Schema(graphModels + localModels)
        let graphStoreURL = directoryURL.appendingPathComponent("WorkspaceGraph.store")
        let localStoreURL = directoryURL.appendingPathComponent("WorkspaceSettings.store")
        let graphConfiguration = ModelConfiguration(
            "WorkspaceRestoreGraph",
            schema: Schema(graphModels),
            url: graphStoreURL,
            allowsSave: graphAllowsSave,
            cloudKitDatabase: .none
        )
        let localConfiguration = ModelConfiguration(
            "WorkspaceRestoreSettings",
            schema: Schema(localModels),
            url: localStoreURL,
            allowsSave: settingsAllowsSave,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [graphConfiguration, localConfiguration]
        )
        return (container, graphStoreURL, localStoreURL)
    }

    /**
     Builds one staged patch-archive fixture for workspace replay tests.

     - Parameters:
       - patchDatabaseURL: Local SQLite database containing Android workspace patch rows.
       - sourceDevice: Android source-device name owning the patch stream.
       - patchNumber: Monotonic patch number within the source-device stream.
       - fileTimestamp: Remote millisecond timestamp that should be recorded on the staged archive.
     - Returns: Staged patch archive pointing at a temporary gzip file.
     - Side effects:
       - reads the supplied SQLite database
       - writes one temporary gzip archive beneath the process temporary directory
     - Failure modes:
       - rethrows filesystem read and write errors
       - rethrows gzip-compression failures from `RemoteSyncArchiveStagingService`
     */
    private func makeWorkspacePatchArchive(
        patchDatabaseURL: URL,
        sourceDevice: String,
        patchNumber: Int64,
        fileTimestamp: Int64
    ) throws -> RemoteSyncStagedPatchArchive {
        let schemaVersion = RemoteSyncAndroidDatabaseContract.schemaVersion(for: .workspaces)
        let archiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: patchDatabaseURL))
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-workspaces-patch-\(UUID().uuidString).sqlite3.gz")
        try archiveData.write(to: archiveURL, options: .atomic)

        return RemoteSyncStagedPatchArchive(
            patch: RemoteSyncDiscoveredPatch(
                sourceDevice: sourceDevice,
                patchNumber: patchNumber,
                schemaVersion: schemaVersion,
                file: RemoteSyncFile(
                    id: "/org.andbible.ios-sync-workspaces/\(sourceDevice)/\(patchNumber).\(schemaVersion).sqlite3.gz",
                    name: "\(patchNumber).\(schemaVersion).sqlite3.gz",
                    size: Int64(archiveData.count),
                    timestamp: fileTimestamp,
                    parentID: "/org.andbible.ios-sync-workspaces/\(sourceDevice)",
                    mimeType: "application/gzip"
                )
            ),
            archiveFileURL: archiveURL
        )
    }

    /**
     Builds one temporary Android-shaped `workspaces.sqlite3` fixture database.

     The helper writes the exact table names and column shapes consumed by
     `RemoteSyncWorkspaceRestoreService`, then verifies that a second read-only SQLite connection can
     still observe the required tables before returning the file URL.

     - Parameters:
     - workspaces: Android workspace rows to insert.
     - windows: Android window rows to insert.
     - pageManagers: Android page-manager rows to insert.
     - historyItems: Android history rows to insert.
      - logEntries: Optional Android `LogEntry` rows to insert when testing sync metadata import.
      - syncStatuses: Optional Android `SyncStatus` rows to insert when testing applied-patch metadata import.
     - Returns: Temporary SQLite file URL containing the requested Android fixture graph.
     - Side effects:
       - creates and writes a temporary SQLite file
       - fails the current test immediately when SQLite cannot prepare or execute required statements
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase` when SQLite cannot open the temporary database
       - may propagate assertion failures when the generated database is structurally invalid
     */
    private func makeAndroidWorkspacesDatabase(
        workspaces: [AndroidWorkspaceRow],
        windows: [AndroidWorkspaceWindowRow],
        pageManagers: [AndroidWorkspacePageManagerRow],
        historyItems: [AndroidWorkspaceHistoryItemRow],
        logEntries: [AndroidLogEntryRow] = [],
        syncStatuses: [AndroidSyncStatusRow] = []
    ) throws -> URL {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-workspaces-\(UUID().uuidString).sqlite3")

        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            XCTFail("Failed to open temporary Android workspace database")
            throw RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase
        }
        defer { XCTAssertEqual(sqlite3_close(db), SQLITE_OK) }

        let allSchemaStatements = [RemoteSyncAndroidDatabaseContract.createSchemaSQL(for: .workspaces)]

        for statement in allSchemaStatements {
            XCTAssertEqual(
                sqlite3_exec(db, statement, nil, nil, nil),
                SQLITE_OK,
                String(cString: sqlite3_errmsg(db))
            )
        }

        for workspace in workspaces {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO \"Workspace\" (name, contentsText, id, orderNumber, unPinnedWeight, maximizedWindowId, primaryTargetLinksWindowId, text_display_settings_strongsMode, text_display_settings_showMorphology, text_display_settings_showFootNotes, text_display_settings_showFootNotesInline, text_display_settings_expandXrefs, text_display_settings_showXrefs, text_display_settings_showRedLetters, text_display_settings_showSectionTitles, text_display_settings_showVerseNumbers, text_display_settings_showVersePerLine, text_display_settings_showBookmarks, text_display_settings_showMyNotes, text_display_settings_justifyText, text_display_settings_hyphenation, text_display_settings_topMargin, text_display_settings_fontSize, text_display_settings_fontFamily, text_display_settings_lineSpacing, text_display_settings_bookmarksHideLabels, text_display_settings_showPageNumber, text_display_settings_margin_size_marginLeft, text_display_settings_margin_size_marginRight, text_display_settings_margin_size_maxWidth, text_display_settings_colors_dayTextColor, text_display_settings_colors_dayBackground, text_display_settings_colors_dayNoise, text_display_settings_colors_nightTextColor, text_display_settings_colors_nightBackground, text_display_settings_colors_nightNoise, workspace_settings_enableTiltToScroll, workspace_settings_enableReverseSplitMode, workspace_settings_autoPin, workspace_settings_restoreButtonsVisible, workspace_settings_speakSettings, workspace_settings_recentLabels, workspace_settings_autoAssignLabels, workspace_settings_autoAssignPrimaryLabel, workspace_settings_studyPadCursors, workspace_settings_hideCompareDocuments, workspace_settings_limitAmbiguousModalSize, workspace_settings_workspaceColor) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            var index: Int32 = 1
            sqlite3_bind_text(statement, index, workspace.name, -1, workspaceSQLiteTransient)
            index += 1
            bindOptionalText(workspace.contentsText, to: statement, index: index)
            index += 1
            bindUUIDBlob(workspace.id, to: statement, index: index)
            index += 1
            sqlite3_bind_int(statement, index, Int32(workspace.orderNumber))
            index += 1
            bindOptionalDouble(workspace.unPinnedWeight, to: statement, index: index)
            index += 1
            bindOptionalUUIDBlob(workspace.maximizedWindowID, to: statement, index: index)
            index += 1
            bindOptionalUUIDBlob(workspace.primaryTargetLinksWindowID, to: statement, index: index)
            index += 1
            bindTextDisplaySettings(workspace.textDisplaySettings, to: statement, index: &index)
            bindWorkspaceSettings(workspace.workspaceSettings, to: statement, index: &index)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for window in windows {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO \"Window\" (workspaceId, isSynchronized, isPinMode, isLinksWindow, id, orderNumber, targetLinksWindowId, syncGroup, window_layout_state, window_layout_weight) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(window.workspaceID, to: statement, index: 1)
            bindBool(window.isSynchronized, to: statement, index: 2)
            bindBool(window.isPinMode, to: statement, index: 3)
            bindBool(window.isLinksWindow, to: statement, index: 4)
            bindUUIDBlob(window.id, to: statement, index: 5)
            sqlite3_bind_int(statement, 6, Int32(window.orderNumber))
            bindOptionalUUIDBlob(window.targetLinksWindowID, to: statement, index: 7)
            sqlite3_bind_int(statement, 8, Int32(window.syncGroup))
            sqlite3_bind_text(statement, 9, window.layoutState, -1, workspaceSQLiteTransient)
            sqlite3_bind_double(statement, 10, window.layoutWeight)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for pageManager in pageManagers {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO \"PageManager\" (windowId, currentCategoryName, jsState, bible_document, bible_verse_versification, bible_verse_bibleBook, bible_verse_chapterNo, bible_verse_verseNo, commentary_document, commentary_anchorOrdinal, commentary_sourceBookAndKey, dictionary_document, dictionary_key, dictionary_anchorOrdinal, general_book_document, general_book_key, general_book_anchorOrdinal, map_document, map_key, map_anchorOrdinal, text_display_settings_strongsMode, text_display_settings_showMorphology, text_display_settings_showFootNotes, text_display_settings_showFootNotesInline, text_display_settings_expandXrefs, text_display_settings_showXrefs, text_display_settings_showRedLetters, text_display_settings_showSectionTitles, text_display_settings_showVerseNumbers, text_display_settings_showVersePerLine, text_display_settings_showBookmarks, text_display_settings_showMyNotes, text_display_settings_justifyText, text_display_settings_hyphenation, text_display_settings_topMargin, text_display_settings_fontSize, text_display_settings_fontFamily, text_display_settings_lineSpacing, text_display_settings_bookmarksHideLabels, text_display_settings_showPageNumber, text_display_settings_margin_size_marginLeft, text_display_settings_margin_size_marginRight, text_display_settings_margin_size_maxWidth, text_display_settings_colors_dayTextColor, text_display_settings_colors_dayBackground, text_display_settings_colors_dayNoise, text_display_settings_colors_nightTextColor, text_display_settings_colors_nightBackground, text_display_settings_colors_nightNoise) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            var index: Int32 = 1
            bindUUIDBlob(pageManager.windowID, to: statement, index: index)
            index += 1
            sqlite3_bind_text(statement, index, pageManager.currentCategoryName, -1, workspaceSQLiteTransient)
            index += 1
            bindOptionalText(pageManager.jsState, to: statement, index: index)
            index += 1
            bindOptionalText(pageManager.bibleDocument, to: statement, index: index)
            index += 1
            sqlite3_bind_text(statement, index, pageManager.bibleVersification, -1, workspaceSQLiteTransient)
            index += 1
            sqlite3_bind_int(statement, index, Int32(pageManager.bibleBook))
            index += 1
            sqlite3_bind_int(statement, index, Int32(pageManager.bibleChapterNo))
            index += 1
            sqlite3_bind_int(statement, index, Int32(pageManager.bibleVerseNo))
            index += 1
            bindOptionalText(pageManager.commentaryDocument, to: statement, index: index)
            index += 1
            bindOptionalInt(pageManager.commentaryAnchorOrdinal, to: statement, index: index)
            index += 1
            bindOptionalText(pageManager.commentarySourceBookAndKey, to: statement, index: index)
            index += 1
            bindOptionalText(pageManager.dictionaryDocument, to: statement, index: index)
            index += 1
            bindOptionalText(pageManager.dictionaryKey, to: statement, index: index)
            index += 1
            bindOptionalInt(pageManager.dictionaryAnchorOrdinal, to: statement, index: index)
            index += 1
            bindOptionalText(pageManager.generalBookDocument, to: statement, index: index)
            index += 1
            bindOptionalText(pageManager.generalBookKey, to: statement, index: index)
            index += 1
            bindOptionalInt(pageManager.generalBookAnchorOrdinal, to: statement, index: index)
            index += 1
            bindOptionalText(pageManager.mapDocument, to: statement, index: index)
            index += 1
            bindOptionalText(pageManager.mapKey, to: statement, index: index)
            index += 1
            bindOptionalInt(pageManager.mapAnchorOrdinal, to: statement, index: index)
            index += 1
            bindTextDisplaySettings(pageManager.textDisplaySettings, to: statement, index: &index)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for historyItem in historyItems {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO \"HistoryItem\" (windowId, createdAt, document, key, anchorOrdinal, id) VALUES (?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(historyItem.windowID, to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, Int64(historyItem.createdAt.timeIntervalSince1970 * 1000))
            sqlite3_bind_text(statement, 3, historyItem.document, -1, workspaceSQLiteTransient)
            sqlite3_bind_text(statement, 4, historyItem.key, -1, workspaceSQLiteTransient)
            bindOptionalInt(historyItem.anchorOrdinal, to: statement, index: 5)
            sqlite3_bind_int64(statement, 6, historyItem.remoteID)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for logEntry in logEntries {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO \"LogEntry\" (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            sqlite3_bind_text(statement, 1, logEntry.tableName, -1, workspaceSQLiteTransient)
            bindSQLiteFixtureValue(logEntry.entityID1, to: statement, index: 2)
            bindSQLiteFixtureValue(logEntry.entityID2, to: statement, index: 3)
            sqlite3_bind_text(statement, 4, logEntry.type, -1, workspaceSQLiteTransient)
            sqlite3_bind_int64(statement, 5, logEntry.lastUpdated)
            sqlite3_bind_text(statement, 6, logEntry.sourceDevice, -1, workspaceSQLiteTransient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for syncStatus in syncStatuses {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO \"SyncStatus\" (sourceDevice, patchNumber, sizeBytes, appliedDate) VALUES (?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            sqlite3_bind_text(statement, 1, syncStatus.sourceDevice, -1, workspaceSQLiteTransient)
            sqlite3_bind_int64(statement, 2, syncStatus.patchNumber)
            sqlite3_bind_int64(statement, 3, syncStatus.sizeBytes)
            sqlite3_bind_int64(statement, 4, syncStatus.appliedDate)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        var expectedTableNames: Set<String> = ["HistoryItem", "PageManager", "Window", "Workspace"]
        if !logEntries.isEmpty {
            expectedTableNames.insert("LogEntry")
        }
        if !syncStatuses.isEmpty {
            expectedTableNames.insert("SyncStatus")
        }
        XCTAssertEqual(Set(try sqliteTableNames(in: db)).intersection(expectedTableNames), expectedTableNames)

        var verificationDB: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(databaseURL.path, &verificationDB, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK
        )
        if let verificationDB {
            defer { XCTAssertEqual(sqlite3_close(verificationDB), SQLITE_OK) }
            XCTAssertEqual(
                Set(try sqliteTableNames(in: verificationDB)).intersection(expectedTableNames),
                expectedTableNames
            )
        }

        return databaseURL
    }

    /**
     Reads the table names currently visible through one open SQLite connection.

     - Parameter db: Open SQLite database handle.
     - Returns: Table names ordered lexicographically by SQLite.
     - Side effects:
       - prepares and steps a `sqlite_master` metadata query
     - Failure modes:
       - throws `RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase` when the metadata query cannot be prepared
       - records an XCTest failure with the SQLite error message before throwing
     */
    private func sqliteTableNames(in db: OpaquePointer) throws -> [String] {
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            XCTFail("Failed to prepare sqlite_master query: \(String(cString: sqlite3_errmsg(db)))")
            throw RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        var tableNames: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                tableNames.append(String(cString: cString))
            }
        }
        return tableNames
    }

    /**
     Binds one optional Android text-display fixture block into the next contiguous SQLite columns.

     - Parameters:
       - settings: Optional Android text-display fixture to encode.
       - statement: Prepared SQLite statement receiving the bound values.
       - index: Inout parameter tracking the next placeholder index; advanced past the full block.
     - Side effects:
       - mutates the SQLite bind state for the supplied statement
       - increments `index` for each bound column
     - Failure modes:
       - SQLite bind failures are surfaced later by the surrounding `sqlite3_step` assertions
     */
    private func bindTextDisplaySettings(_ settings: AndroidTextDisplayFixture?, to statement: OpaquePointer?, index: inout Int32) {
        bindOptionalInt(settings?.strongsMode, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showMorphology, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showFootNotes, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showFootNotesInline, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.expandXrefs, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showXrefs, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showRedLetters, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showSectionTitles, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showVerseNumbers, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showVersePerLine, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showBookmarks, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showMyNotes, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.justifyText, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.hyphenation, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.topMargin, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.fontSize, to: statement, index: index)
        index += 1
        bindOptionalText(settings?.fontFamily, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.lineSpacing, to: statement, index: index)
        index += 1
        bindOptionalText(settings?.bookmarksHideLabelsJSON, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showPageNumber, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.marginLeft, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.marginRight, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.maxWidth, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.dayTextColor, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.dayBackground, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.dayNoise, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.nightTextColor, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.nightBackground, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.nightNoise, to: statement, index: index)
        index += 1
    }

    /**
     Binds one Android workspace-settings fixture block into the next contiguous SQLite columns.

     - Parameters:
       - settings: Android workspace-settings fixture to encode.
       - statement: Prepared SQLite statement receiving the bound values.
       - index: Inout parameter tracking the next placeholder index; advanced past the full block.
     - Side effects:
       - mutates the SQLite bind state for the supplied statement
       - increments `index` for each bound column
     - Failure modes:
       - SQLite bind failures are surfaced later by the surrounding `sqlite3_step` assertions
     */
    private func bindWorkspaceSettings(_ settings: AndroidWorkspaceSettingsFixture, to statement: OpaquePointer?, index: inout Int32) {
        bindBool(settings.enableTiltToScroll, to: statement, index: index)
        index += 1
        bindBool(settings.enableReverseSplitMode, to: statement, index: index)
        index += 1
        bindBool(settings.autoPin, to: statement, index: index)
        index += 1
        bindBool(settings.restoreButtonsVisible, to: statement, index: index)
        index += 1
        bindOptionalText(settings.speakSettingsJSON, to: statement, index: index)
        index += 1
        bindOptionalText(settings.recentLabelsJSON, to: statement, index: index)
        index += 1
        bindOptionalText(settings.autoAssignLabelsJSON, to: statement, index: index)
        index += 1
        bindOptionalUUIDBlob(settings.autoAssignPrimaryLabelID, to: statement, index: index)
        index += 1
        bindOptionalText(settings.studyPadCursorsJSON, to: statement, index: index)
        index += 1
        bindOptionalText(settings.hideCompareDocumentsJSON, to: statement, index: index)
        index += 1
        bindBool(settings.limitAmbiguousModalSize, to: statement, index: index)
        index += 1
        bindOptionalInt(settings.workspaceColor, to: statement, index: index)
        index += 1
    }

    /**
     Binds one UUID as Android's raw 16-byte BLOB format.

     - Parameters:
       - uuid: UUID to encode.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: Placeholder index that should receive the BLOB.
     - Side effects:
       - mutates the SQLite bind state for the supplied statement
     - Failure modes:
       - SQLite bind failures are surfaced later by the surrounding `sqlite3_step` assertions
     */
    private func bindUUIDBlob(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
        bindBlob(uuidBlob(uuid), to: statement, index: index)
    }

    /**
     Binds one raw blob payload into SQLite.

     - Parameters:
       - value: Raw blob payload to encode.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: Placeholder index that should receive the BLOB.
     - Side effects:
       - mutates the SQLite bind state for the supplied statement
     - Failure modes:
       - SQLite bind failures are surfaced later by the surrounding `sqlite3_step` assertions
     */
    private func bindBlob(_ value: Data, to statement: OpaquePointer?, index: Int32) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), workspaceSQLiteTransient)
        }
    }

    /**
     Binds one optional UUID using Android's raw BLOB representation.

     - Parameters:
       - uuid: Optional UUID to encode.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: Placeholder index that should receive the value.
     - Side effects:
       - mutates the SQLite bind state for the supplied statement
     - Failure modes:
       - SQLite bind failures are surfaced later by the surrounding `sqlite3_step` assertions
     */
    private func bindOptionalUUIDBlob(_ uuid: UUID?, to statement: OpaquePointer?, index: Int32) {
        guard let uuid else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindUUIDBlob(uuid, to: statement, index: index)
    }

    /**
     Binds one Boolean using Android's integer-backed SQLite representation.

     - Parameters:
       - value: Boolean value to encode.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: Placeholder index that should receive the value.
     - Side effects:
       - mutates the SQLite bind state for the supplied statement
     - Failure modes:
       - SQLite bind failures are surfaced later by the surrounding `sqlite3_step` assertions
     */
    private func bindBool(_ value: Bool, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_int(statement, index, value ? 1 : 0)
    }

    /**
     Binds one optional Boolean using Android's integer-backed SQLite representation.

     - Parameters:
       - value: Optional Boolean value to encode.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: Placeholder index that should receive the value.
     - Side effects:
       - mutates the SQLite bind state for the supplied statement
     - Failure modes:
       - SQLite bind failures are surfaced later by the surrounding `sqlite3_step` assertions
     */
    private func bindOptionalBool(_ value: Bool?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindBool(value, to: statement, index: index)
    }

    /**
     Binds one optional UTF-8 string into SQLite.

     - Parameters:
       - value: Optional string value to encode.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: Placeholder index that should receive the value.
     - Side effects:
       - mutates the SQLite bind state for the supplied statement
     - Failure modes:
       - SQLite bind failures are surfaced later by the surrounding `sqlite3_step` assertions
     */
    private func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, workspaceSQLiteTransient)
    }

    /**
     Binds one optional integer into SQLite.

     - Parameters:
       - value: Optional integer value to encode.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: Placeholder index that should receive the value.
     - Side effects:
       - mutates the SQLite bind state for the supplied statement
     - Failure modes:
       - SQLite bind failures are surfaced later by the surrounding `sqlite3_step` assertions
     */
    private func bindOptionalInt(_ value: Int?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int(statement, index, Int32(value))
    }

    /**
     Binds one optional floating-point value into SQLite.

     - Parameters:
       - value: Optional floating-point value to encode.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: Placeholder index that should receive the value.
     - Side effects:
       - mutates the SQLite bind state for the supplied statement
     - Failure modes:
       - SQLite bind failures are surfaced later by the surrounding `sqlite3_step` assertions
     */
    private func bindOptionalDouble(_ value: Double?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    /**
     Binds one typed SQLite fixture value while preserving its explicit storage class.

     - Parameters:
       - value: SQLite fixture payload to encode.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: Placeholder index that should receive the value.
     - Side effects:
       - mutates the SQLite bind state for the supplied statement
     - Failure modes:
       - SQLite bind failures are surfaced later by the surrounding `sqlite3_step` assertions
     */
    private func bindSQLiteFixtureValue(_ value: AndroidSQLiteFixtureValue, to statement: OpaquePointer?, index: Int32) {
        switch value {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer(let value):
            sqlite3_bind_int64(statement, index, value)
        case .real(let value):
            sqlite3_bind_double(statement, index, value)
        case .text(let value):
            sqlite3_bind_text(statement, index, value, -1, workspaceSQLiteTransient)
        case .blob(let value):
            bindBlob(value, to: statement, index: index)
        }
    }

    /**
     Converts one UUID into Android's raw 16-byte SQLite BLOB format.

     Android stores workspace identifiers as raw bytes rather than canonical UUID strings. The test
     fixtures therefore mirror that encoding so `RemoteSyncWorkspaceRestoreService` exercises the
     same blob-decoding path used against real Android backups.

     - Parameter uuid: UUID to convert into raw bytes.
     - Returns: Sixteen-byte BLOB payload matching Android's identifier storage format.
     - Side effects: none.
     - Failure modes:
       - this helper traps if the UUID hex string cannot be converted into bytes, which would
         indicate a programming error in the fixture builder
     */
    private func uuidBlob(_ uuid: UUID) -> Data {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "")
        var bytes = Data()
        bytes.reserveCapacity(16)

        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            let byteString = hex[index..<nextIndex]
            bytes.append(UInt8(byteString, radix: 16)!)
            index = nextIndex
        }
        return bytes
    }
}

/**
 Minimal remote-sync adapter double for workspace upload and coordinator tests.

 The mock records every adapter call in order, captures uploaded file payloads for later SQLite
 inspection, and lets each test queue deterministic list/upload responses without touching the
 network.
 */
private actor WorkspaceMockRemoteSyncAdapter: RemoteSyncAdapting, RemoteSyncConditionalFileUploading {
    private var fallbackListFilesResult: [RemoteSyncFile] = []
    private var listFilesResultsQueue: [[RemoteSyncFile]] = []
    private var uploadResults: [RemoteSyncFile] = []
    private var knownResponses: [String: Bool] = [:]
    private var events: [WorkspaceMockRemoteSyncAdapterEvent] = []
    private var uploadedFiles: [WorkspaceMockRemoteSyncUploadedFile] = []

    /**
     Queues one exact `listFiles` response for the next adapter call.
     */
    func enqueueListFilesResult(_ result: [RemoteSyncFile]) {
        listFilesResultsQueue.append(result)
    }

    /**
     Queues one exact `upload` response for the next adapter call.
     */
    func enqueueUploadResult(_ result: RemoteSyncFile) {
        uploadResults.append(result)
    }

    /**
     Stores one bootstrap ownership answer for a sync-folder marker lookup.
     */
    func setKnownResponse(_ value: Bool, forSyncFolderID syncFolderID: String, secretFileName: String) {
        knownResponses["\(syncFolderID)|\(secretFileName)"] = value
    }

    /**
     Returns the recorded adapter events in call order.
     */
    func eventsSnapshot() -> [WorkspaceMockRemoteSyncAdapterEvent] {
        events
    }

    /**
     Returns the uploaded file payloads captured by the mock adapter.
     */
    func uploadedFilesSnapshot() -> [WorkspaceMockRemoteSyncUploadedFile] {
        uploadedFiles
    }

    func listFiles(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        modifiedAtLeast: Date?
    ) async throws -> [RemoteSyncFile] {
        events.append(
            .listFiles(
                parentIDs: parentIDs,
                name: name,
                mimeType: mimeType,
                modifiedAtLeast: modifiedAtLeast
            )
        )
        if !listFilesResultsQueue.isEmpty {
            return listFilesResultsQueue.removeFirst()
        }
        return fallbackListFilesResult
    }

    func createNewFolder(name: String, parentID: String?) async throws -> RemoteSyncFile {
        events.append(.createFolder(name: name, parentID: parentID))
        return RemoteSyncFile(
            id: [parentID, name].compactMap { $0 }.joined(separator: "/"),
            name: name,
            size: 0,
            timestamp: 0,
            parentID: parentID ?? "/",
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
    }

    func download(id: String) async throws -> Data {
        events.append(.download(id: id))
        return Data()
    }

    func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncFile {
        events.append(.upload(name: name, parentID: parentID, contentType: contentType))
        let data = try Data(contentsOf: fileURL)
        uploadedFiles.append(
            WorkspaceMockRemoteSyncUploadedFile(
                name: name,
                parentID: parentID,
                contentType: contentType,
                data: data
            )
        )
        if !uploadResults.isEmpty {
            let result = uploadResults.removeFirst()
            return RemoteSyncFile(
                id: result.id,
                name: result.name,
                size: Int64(data.count),
                timestamp: result.timestamp,
                parentID: result.parentID,
                mimeType: result.mimeType
            )
        }
        return RemoteSyncFile(
            id: [parentID, name].joined(separator: "/"),
            name: name,
            size: Int64(data.count),
            timestamp: 0,
            parentID: parentID,
            mimeType: contentType
        )
    }

    /**
     Records create-only workspace patch bytes through the mock's established upload queue.

     The fake never models a competing writer; exact-name conflict behavior is covered by the shared
     reconciler tests and `RemoteSyncDurableOutboxTestAdapter`.
     */
    func uploadIfAbsent(
        name: String,
        fileURL: URL,
        maximumByteCount: Int,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncConditionalUploadResult {
        _ = try RemoteSyncBoundedFileIO.fingerprintRegularFile(
            at: fileURL,
            maximumByteCount: maximumByteCount
        )
        return .created(try await upload(
            name: name,
            fileURL: fileURL,
            parentID: parentID,
            contentType: contentType
        ))
    }

    func delete(id: String) async throws {
        events.append(.delete(id: id))
    }

    func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool {
        events.append(.isSyncFolderKnown(syncFolderID: syncFolderID, secretFileName: secretFileName))
        return knownResponses["\(syncFolderID)|\(secretFileName)"] ?? false
    }

    func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        events.append(.makeKnown(syncFolderID: syncFolderID, deviceIdentifier: deviceIdentifier))
        return "device-known-\(deviceIdentifier)-secret"
    }
}

/**
 Ordered adapter events captured by `WorkspaceMockRemoteSyncAdapter`.
 */
private enum WorkspaceMockRemoteSyncAdapterEvent: Equatable {
    case listFiles(parentIDs: [String]?, name: String?, mimeType: String?, modifiedAtLeast: Date?)
    case createFolder(name: String, parentID: String?)
    case download(id: String)
    case upload(name: String, parentID: String, contentType: String)
    case delete(id: String)
    case isSyncFolderKnown(syncFolderID: String, secretFileName: String)
    case makeKnown(syncFolderID: String, deviceIdentifier: String)
}

/**
 Captured remote file upload emitted by `WorkspaceMockRemoteSyncAdapter`.
 */
private struct WorkspaceMockRemoteSyncUploadedFile: Equatable {
    let name: String
    let parentID: String
    let contentType: String
    let data: Data
}

/**
 Decompresses one gzip payload created by the workspace upload path.

 The helper uses the same low-level gunzip bridge as the production staging services so the tests
 validate the exact patch bytes uploaded to the mock adapter.
 */
private func workspaceGunzipTestData(_ data: Data) throws -> Data {
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
