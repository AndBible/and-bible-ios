import XCTest
@testable import BibleCore
import SwiftData
import SQLite3

/// SQLite transient destructor used when binding Swift-owned text/blob buffers in test fixtures.
private let workspaceSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Regression coverage for Android workspace initial-backup restore.

 The suite exercises three boundaries:
 - snapshot parsing from Android-shaped SQLite databases
 - destructive replacement of the local SwiftData workspace graph
 - preservation of Android-only fidelity payloads that do not map directly onto iOS models

 Test dependencies:
 - in-memory SwiftData containers are created per test
 - temporary SQLite fixture databases are created under `FileManager.default.temporaryDirectory`

 Side effects:
 - tests create and delete temporary SQLite files
 - restore tests mutate in-memory SwiftData graphs and local-only `SettingsStore` rows

 Failure modes:
 - helper fixture builders fail the test immediately when they cannot create valid Android-shaped
   SQLite databases
 */
final class WorkspaceSyncRestoreTests: XCTestCase {
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
        XCTAssertEqual(workspace.workspaceSettings.autoAssignPrimaryLabel, primaryLabelID)
        XCTAssertEqual(workspace.workspaceSettings.studyPadCursors, [cursorLabelID: 5])
        XCTAssertEqual(workspace.workspaceSettings.hideCompareDocuments, ["ESV", "NET"])
        XCTAssertTrue(workspace.workspaceSettings.enableTiltToScroll)
        XCTAssertTrue(workspace.workspaceSettings.enableReverseSplitMode)
        XCTAssertFalse(workspace.workspaceSettings.autoPin)
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
        let report = try service.replaceLocalWorkspaces(
            from: snapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

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
        XCTAssertEqual(workspaces[0].workspaceSettings?.autoAssignPrimaryLabel, primaryLabelID)
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
        XCTAssertEqual(pageManagers.first(where: { $0.id == secondWindowID })?.currentCategoryName, "bible")
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
            schemaVersion: 8
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

        let schemaStatements = [
            #"""
                CREATE TABLE "Workspace" (
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
                    workspace_settings_speakSettings TEXT DEFAULT NULL,
                    workspace_settings_recentLabels TEXT DEFAULT NULL,
                    workspace_settings_autoAssignLabels TEXT DEFAULT NULL,
                    workspace_settings_autoAssignPrimaryLabel BLOB DEFAULT NULL,
                    workspace_settings_studyPadCursors TEXT DEFAULT NULL,
                    workspace_settings_hideCompareDocuments TEXT DEFAULT NULL,
                    workspace_settings_limitAmbiguousModalSize INTEGER DEFAULT 0,
                    workspace_settings_workspaceColor INTEGER DEFAULT NULL
                )
            """#,
            #"""
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
                    window_layout_weight REAL NOT NULL,
                    FOREIGN KEY(workspaceId) REFERENCES "Workspace"(id) ON DELETE CASCADE
                )
            """#,
            #"""
                CREATE TABLE "HistoryItem" (
                    windowId BLOB NOT NULL,
                    createdAt INTEGER NOT NULL,
                    document TEXT NOT NULL,
                    key TEXT NOT NULL,
                    anchorOrdinal INTEGER DEFAULT NULL,
                    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                    FOREIGN KEY(windowId) REFERENCES "Window"(id) ON DELETE CASCADE
                )
            """#,
            #"""
                CREATE TABLE "PageManager" (
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
                    text_display_settings_colors_nightNoise INTEGER DEFAULT NULL,
                    FOREIGN KEY(windowId) REFERENCES "Window"(id) ON DELETE CASCADE
                )
            """#,
        ]
        var allSchemaStatements = schemaStatements
        if !logEntries.isEmpty {
            allSchemaStatements.append(
                #"""
                    CREATE TABLE "LogEntry" (
                        tableName TEXT NOT NULL,
                        entityId1 BLOB NOT NULL,
                        entityId2 BLOB NOT NULL DEFAULT '',
                        type TEXT NOT NULL,
                        lastUpdated INTEGER NOT NULL,
                        sourceDevice TEXT NOT NULL,
                        PRIMARY KEY(tableName, entityId1, entityId2)
                    )
                """#
            )
            allSchemaStatements.append(
                #"CREATE INDEX "index_LogEntry_tableName_entityId1" ON "LogEntry" (tableName, entityId1)"#
            )
            allSchemaStatements.append(
                #"CREATE INDEX "index_LogEntry_lastUpdated" ON "LogEntry" (lastUpdated)"#
            )
        }
        if !syncStatuses.isEmpty {
            allSchemaStatements.append(
                #"""
                    CREATE TABLE "SyncStatus" (
                        sourceDevice TEXT NOT NULL,
                        patchNumber INTEGER NOT NULL,
                        sizeBytes INTEGER NOT NULL,
                        appliedDate INTEGER NOT NULL,
                        PRIMARY KEY(sourceDevice, patchNumber)
                    )
                """#
            )
        }

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
                    "INSERT INTO \"Workspace\" (name, contentsText, id, orderNumber, unPinnedWeight, maximizedWindowId, primaryTargetLinksWindowId, text_display_settings_strongsMode, text_display_settings_showMorphology, text_display_settings_showFootNotes, text_display_settings_showFootNotesInline, text_display_settings_expandXrefs, text_display_settings_showXrefs, text_display_settings_showRedLetters, text_display_settings_showSectionTitles, text_display_settings_showVerseNumbers, text_display_settings_showVersePerLine, text_display_settings_showBookmarks, text_display_settings_showMyNotes, text_display_settings_justifyText, text_display_settings_hyphenation, text_display_settings_topMargin, text_display_settings_fontSize, text_display_settings_fontFamily, text_display_settings_lineSpacing, text_display_settings_bookmarksHideLabels, text_display_settings_showPageNumber, text_display_settings_margin_size_marginLeft, text_display_settings_margin_size_marginRight, text_display_settings_margin_size_maxWidth, text_display_settings_colors_dayTextColor, text_display_settings_colors_dayBackground, text_display_settings_colors_dayNoise, text_display_settings_colors_nightTextColor, text_display_settings_colors_nightBackground, text_display_settings_colors_nightNoise, workspace_settings_enableTiltToScroll, workspace_settings_enableReverseSplitMode, workspace_settings_autoPin, workspace_settings_speakSettings, workspace_settings_recentLabels, workspace_settings_autoAssignLabels, workspace_settings_autoAssignPrimaryLabel, workspace_settings_studyPadCursors, workspace_settings_hideCompareDocuments, workspace_settings_limitAmbiguousModalSize, workspace_settings_workspaceColor) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
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
