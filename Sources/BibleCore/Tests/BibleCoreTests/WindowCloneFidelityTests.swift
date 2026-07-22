// WindowCloneFidelityTests.swift -- Complete Android-compatible pane clone coverage

import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/**
 Protects the complete persisted reader-state boundary used when duplicating panes.

 Android clones every category page in `CurrentPageManager.entity`, its display and JavaScript
 state, and the source window's synchronization properties while assigning fresh row identities.
 These tests exercise the same behavior without constructing a reader controller or loading SWORD.
 */
final class WindowCloneFidelityTests: XCTestCase {
    /**
     Verifies every non-Bible category survives pane duplication without category normalization.

     Each case seeds every parallel page slot, then selects commentary, dictionary, an ordinary
     general book, My Documents, modern or legacy EPUB, maps, daily devotion, or Android My Note.
     The clone must equal the complete source snapshot and retain the exact selected category. The
     in-memory container is discarded after the test.
     */
    func testPaneDuplicationPreservesEveryNonBibleCategoryAndParallelPageState() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let store = WorkspaceStore(modelContext: context)
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Category clones")
        let source = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let sourcePageManager = try XCTUnwrap(source.pageManager)
        manager.setActiveWorkspace(workspace)

        for (index, fixture) in categoryFixtures().enumerated() {
            seedCompleteReaderState(on: sourcePageManager, index: index)
            fixture.configure(sourcePageManager)
            store.persistChanges()
            let expected = ReaderState(sourcePageManager)

            let clone = try XCTUnwrap(manager.addWindow(from: source), fixture.name)
            let clonePageManager = try XCTUnwrap(clone.pageManager, fixture.name)

            XCTAssertEqual(ReaderState(clonePageManager), expected, fixture.name)
            XCTAssertEqual(clonePageManager.currentCategoryName, fixture.categoryName, fixture.name)
            XCTAssertNotEqual(clonePageManager.currentCategoryName, "bible", fixture.name)
        }
    }

    /**
     Verifies cloned pane rows and mutable state are independently owned.

     The source includes raw pane synchronization/link state, a link target, history, all page
     fields, collection-valued display overrides, JavaScript state, and Android-only sidecar data.
     Duplication must retain the Android-copied values while clearing the link target and history.
     Mutating the clone afterward must leave both source rows and source sidecar unchanged. A source
     without a page manager must fail without inserting a default Bible pane.
     */
    func testPaneDuplicationCreatesIndependentRowsAndNeverFallsBackForMissingPageState() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let store = WorkspaceStore(modelContext: context)
        let settingsStore = SettingsStore(modelContext: context)
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Independent clone")
        let source = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let sourcePageManager = try XCTUnwrap(source.pageManager)
        manager.setActiveWorkspace(workspace)

        source.isSynchronized = false
        source.isPinMode = true
        source.syncGroup = 6
        source.layoutWeight = 1.75
        source.targetLinksWindowId = UUID()
        seedCompleteReaderState(on: sourcePageManager, index: 40)
        sourcePageManager.currentCategoryName = DocumentCategory.generalBook.pageManagerKey
        sourcePageManager.generalBookDocument = "Multi"
        sourcePageManager.generalBookKey = "KJV:Gen.1.1||BDB:H7225"
        store.addHistoryItem(to: source, document: "Multi", key: "KJV:Gen.1.1")
        let sourceFidelity = FidelityState(
            rawCurrentCategoryName: "GENERAL_BOOK",
            commentarySourceBookAndKey: "KJV:John.3.16",
            dictionaryAnchorOrdinal: 120,
            generalBookAnchorOrdinal: 220,
            mapAnchorOrdinal: 320
        )
        fidelityStore.setPageManagerEntry(sourceFidelity.entry(windowID: source.id))
        store.persistChanges()
        let originalReaderState = ReaderState(sourcePageManager)

        let clone = try XCTUnwrap(manager.addWindow(from: source))
        let clonePageManager = try XCTUnwrap(clone.pageManager)

        XCTAssertNotEqual(clone.id, source.id)
        XCTAssertEqual(clonePageManager.id, clone.id)
        XCTAssertNotEqual(clonePageManager.id, sourcePageManager.id)
        XCTAssertEqual(clone.workspace?.id, workspace.id)
        XCTAssertEqual(clonePageManager.window?.id, clone.id)
        XCTAssertFalse(clone.isSynchronized)
        XCTAssertTrue(clone.isPinMode)
        XCTAssertEqual(clone.syncGroup, 6)
        XCTAssertEqual(clone.layoutWeight, 1.75, accuracy: 0.001)
        XCTAssertNil(clone.targetLinksWindowId)
        XCTAssertTrue(clone.historyItems?.isEmpty ?? true)
        XCTAssertEqual(ReaderState(clonePageManager), originalReaderState)
        XCTAssertEqual(
            fidelityStore.pageManagerEntry(for: clone.id).map(FidelityState.init),
            sourceFidelity
        )

        clone.isSynchronized = true
        clone.syncGroup = 2
        clone.layoutWeight = 0.5
        clonePageManager.currentCategoryName = DocumentCategory.dictionary.pageManagerKey
        clonePageManager.generalBookKey = "changed-clone-key"
        clonePageManager.jsState = "{\"clone\":true}"
        var cloneDisplaySettings = try XCTUnwrap(clonePageManager.textDisplaySettings)
        cloneDisplaySettings.fontSize = 99
        cloneDisplaySettings.bookmarksHideLabels = [UUID()]
        clonePageManager.textDisplaySettings = cloneDisplaySettings
        fidelityStore.setPageManagerEntry(FidelityState(
            rawCurrentCategoryName: "DICTIONARY",
            commentarySourceBookAndKey: nil,
            dictionaryAnchorOrdinal: 999,
            generalBookAnchorOrdinal: nil,
            mapAnchorOrdinal: nil
        ).entry(windowID: clone.id))
        store.persistChanges()

        XCTAssertEqual(ReaderState(sourcePageManager), originalReaderState)
        XCTAssertFalse(source.isSynchronized)
        XCTAssertEqual(source.syncGroup, 6)
        XCTAssertEqual(source.layoutWeight, 1.75, accuracy: 0.001)
        XCTAssertEqual(
            fidelityStore.pageManagerEntry(for: source.id).map(FidelityState.init),
            sourceFidelity
        )

        let countBeforeRejectedClone = manager.allWindows.count
        XCTAssertNil(manager.addWindow(from: Window()))
        XCTAssertEqual(manager.allWindows.count, countBeforeRejectedClone)
    }

    /**
     Verifies links panes follow Android's two distinct clone operations.

     A normal duplicate of a links source remains a links pane, but Change to normal creates a
     complete normal clone and closes the source. Both results must clear inherited target-link
     routing and preserve the source page snapshot. The in-memory graph is discarded afterward.
     */
    func testLinksPaneDuplicationPreservesRoleWhileConversionCreatesNormalPane() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let store = WorkspaceStore(modelContext: context)
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Links clone roles")
        let source = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let sourcePageManager = try XCTUnwrap(source.pageManager)
        source.isLinksWindow = true
        source.isSynchronized = false
        source.targetLinksWindowId = UUID()
        seedCompleteReaderState(on: sourcePageManager, index: 50)
        sourcePageManager.currentCategoryName = DocumentCategory.map.pageManagerKey
        sourcePageManager.mapDocument = "BibleAtlas"
        sourcePageManager.mapKey = "jerusalem"
        store.persistChanges()
        manager.setActiveWorkspace(workspace)
        let expected = ReaderState(sourcePageManager)

        let duplicatedLinksPane = try XCTUnwrap(manager.addWindow(from: source))

        XCTAssertTrue(duplicatedLinksPane.isLinksWindow)
        XCTAssertFalse(duplicatedLinksPane.isSynchronized)
        XCTAssertNil(duplicatedLinksPane.targetLinksWindowId)
        XCTAssertEqual(duplicatedLinksPane.pageManager.map(ReaderState.init), expected)
        XCTAssertEqual(manager.activeWindow?.id, duplicatedLinksPane.id)

        let normalPane = try XCTUnwrap(manager.changeLinksWindowToNormal(source))

        XCTAssertFalse(normalPane.isLinksWindow)
        XCTAssertFalse(normalPane.isSynchronized)
        XCTAssertNil(normalPane.targetLinksWindowId)
        XCTAssertEqual(normalPane.pageManager.map(ReaderState.init), expected)
        XCTAssertFalse(manager.allWindows.contains(where: { $0.id == source.id }))
    }

    /**
     Verifies duplicated category state and Android-only fidelity survive a process-style reopen.

     The first phase duplicates every non-Bible fixture into a two-store file-backed SwiftData
     container. The second phase creates a new container over the same URLs and verifies each clone's
     complete page snapshot and sidecar payload. Temporary stores are deleted after both phases.
     */
    func testEveryNonBiblePaneCloneSurvivesPersistentStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowCloneFidelity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var workspaceID = UUID()
        var expectations: [PersistedCloneExpectation] = []

        try autoreleasepool {
            let container = try makePersistentContainer(in: directory)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let store = WorkspaceStore(modelContext: context)
            let fidelityStore = RemoteSyncWorkspaceFidelityStore(
                settingsStore: SettingsStore(modelContext: context)
            )
            let manager = WindowManager(workspaceStore: store)
            let workspace = store.createWorkspace(name: "Relaunch clones")
            workspaceID = workspace.id
            let source = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
            let sourcePageManager = try XCTUnwrap(source.pageManager)
            manager.setActiveWorkspace(workspace)

            for (index, fixture) in categoryFixtures().enumerated() {
                seedCompleteReaderState(on: sourcePageManager, index: 100 + index)
                fixture.configure(sourcePageManager)
                let sourceFidelity = FidelityState(
                    rawCurrentCategoryName: fixture.androidCategoryName,
                    commentarySourceBookAndKey: "KJV:Mark.\(index + 1).1",
                    dictionaryAnchorOrdinal: 1_000 + index,
                    generalBookAnchorOrdinal: 2_000 + index,
                    mapAnchorOrdinal: 3_000 + index
                )
                fidelityStore.setPageManagerEntry(sourceFidelity.entry(windowID: source.id))
                store.persistChanges()

                let clone = try XCTUnwrap(manager.addWindow(from: source), fixture.name)
                let clonePageManager = try XCTUnwrap(clone.pageManager, fixture.name)
                expectations.append(PersistedCloneExpectation(
                    fixtureName: fixture.name,
                    windowID: clone.id,
                    readerState: ReaderState(clonePageManager),
                    fidelityState: sourceFidelity
                ))
            }
            try context.save()
        }

        try autoreleasepool {
            let container = try makePersistentContainer(in: directory)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let store = WorkspaceStore(modelContext: context)
            let fidelityStore = RemoteSyncWorkspaceFidelityStore(
                settingsStore: SettingsStore(modelContext: context)
            )
            let reloadedWindows = store.windows(workspaceId: workspaceID)

            for expectation in expectations {
                let window = try XCTUnwrap(
                    reloadedWindows.first(where: { $0.id == expectation.windowID }),
                    expectation.fixtureName
                )
                let pageManager = try XCTUnwrap(window.pageManager, expectation.fixtureName)
                XCTAssertEqual(
                    ReaderState(pageManager),
                    expectation.readerState,
                    expectation.fixtureName
                )
                XCTAssertEqual(
                    fidelityStore.pageManagerEntry(for: window.id).map(FidelityState.init),
                    expectation.fidelityState,
                    expectation.fixtureName
                )
            }
        }
    }

    /**
     Verifies full-workspace cloning uses the same complete page and fidelity copy boundary.

     The source contains a Memorize special-document identity and Android commentary source key.
     The workspace clone must assign independent window/page-manager rows while preserving every
     reader field and sidecar value. The in-memory container is discarded afterward.
     */
    func testWorkspaceClonePreservesSpecialReaderAndAndroidFidelityState() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let store = WorkspaceStore(modelContext: context)
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(
            settingsStore: SettingsStore(modelContext: context)
        )
        let sourceWorkspace = store.createWorkspace(name: "Memorize source")
        let sourceWindow = try XCTUnwrap(store.windows(workspaceId: sourceWorkspace.id).first)
        let sourcePageManager = try XCTUnwrap(sourceWindow.pageManager)
        seedCompleteReaderState(on: sourcePageManager, index: 200)
        sourcePageManager.currentCategoryName = DocumentCategory.commentary.pageManagerKey
        sourcePageManager.commentaryDocument = "Memorize"
        sourcePageManager.commentaryAnchorOrdinal = 44_100
        let sourceFidelity = FidelityState(
            rawCurrentCategoryName: "COMMENTARY",
            commentarySourceBookAndKey: "KJV:Ps.119.11",
            dictionaryAnchorOrdinal: 400,
            generalBookAnchorOrdinal: 500,
            mapAnchorOrdinal: 600
        )
        fidelityStore.setPageManagerEntry(sourceFidelity.entry(windowID: sourceWindow.id))
        store.persistChanges()
        let expectedReaderState = ReaderState(sourcePageManager)

        let clonedWorkspace = store.cloneWorkspace(sourceWorkspace, newName: "Memorize clone")
        let clonedWindow = try XCTUnwrap(store.windows(workspaceId: clonedWorkspace.id).first)
        let clonedPageManager = try XCTUnwrap(clonedWindow.pageManager)

        XCTAssertNotEqual(clonedWindow.id, sourceWindow.id)
        XCTAssertNotEqual(clonedPageManager.id, sourcePageManager.id)
        XCTAssertEqual(ReaderState(clonedPageManager), expectedReaderState)
        XCTAssertEqual(
            fidelityStore.pageManagerEntry(for: clonedWindow.id).map(FidelityState.init),
            sourceFidelity
        )
    }

    /** Defines one category-specific identity layered over a complete parallel page snapshot. */
    private struct CategoryFixture {
        /// Failure label used by category-loop assertions.
        let name: String

        /// Exact iOS or restored Android category string expected after cloning.
        let categoryName: String

        /// Raw Android category retained in the local fidelity sidecar.
        let androidCategoryName: String

        /// Mutation that selects and identifies this category on the source page manager.
        let configure: (PageManager) -> Void
    }

    /** Captures all mutable `PageManager` fields except row ownership and identity. */
    private struct ReaderState: Equatable {
        let bibleDocument: String?
        let bibleVersification: String?
        let bibleBibleBook: Int?
        let bibleChapterNo: Int?
        let bibleVerseNo: Int?
        let commentaryDocument: String?
        let commentaryAnchorOrdinal: Int?
        let dictionaryDocument: String?
        let dictionaryKey: String?
        let generalBookDocument: String?
        let generalBookKey: String?
        let mapDocument: String?
        let mapKey: String?
        let epubIdentifier: String?
        let epubHref: String?
        let currentCategoryName: String
        let textDisplaySettings: TextDisplaySettings?
        let jsState: String?

        /** Creates a value snapshot without retaining a SwiftData model reference. */
        init(_ pageManager: PageManager) {
            bibleDocument = pageManager.bibleDocument
            bibleVersification = pageManager.bibleVersification
            bibleBibleBook = pageManager.bibleBibleBook
            bibleChapterNo = pageManager.bibleChapterNo
            bibleVerseNo = pageManager.bibleVerseNo
            commentaryDocument = pageManager.commentaryDocument
            commentaryAnchorOrdinal = pageManager.commentaryAnchorOrdinal
            dictionaryDocument = pageManager.dictionaryDocument
            dictionaryKey = pageManager.dictionaryKey
            generalBookDocument = pageManager.generalBookDocument
            generalBookKey = pageManager.generalBookKey
            mapDocument = pageManager.mapDocument
            mapKey = pageManager.mapKey
            epubIdentifier = pageManager.epubIdentifier
            epubHref = pageManager.epubHref
            currentCategoryName = pageManager.currentCategoryName
            textDisplaySettings = pageManager.textDisplaySettings
            jsState = pageManager.jsState
        }
    }

    /** Captures Android-only page fields independently of their owning window identifier. */
    private struct FidelityState: Equatable {
        let rawCurrentCategoryName: String
        let commentarySourceBookAndKey: String?
        let dictionaryAnchorOrdinal: Int?
        let generalBookAnchorOrdinal: Int?
        let mapAnchorOrdinal: Int?

        /** Creates a value snapshot from a persisted fidelity entry. */
        init(_ entry: RemoteSyncWorkspaceFidelityStore.PageManagerEntry) {
            rawCurrentCategoryName = entry.rawCurrentCategoryName
            commentarySourceBookAndKey = entry.commentarySourceBookAndKey
            dictionaryAnchorOrdinal = entry.dictionaryAnchorOrdinal
            generalBookAnchorOrdinal = entry.generalBookAnchorOrdinal
            mapAnchorOrdinal = entry.mapAnchorOrdinal
        }

        /** Creates a fixture value from its complete Android-only field set. */
        init(
            rawCurrentCategoryName: String,
            commentarySourceBookAndKey: String?,
            dictionaryAnchorOrdinal: Int?,
            generalBookAnchorOrdinal: Int?,
            mapAnchorOrdinal: Int?
        ) {
            self.rawCurrentCategoryName = rawCurrentCategoryName
            self.commentarySourceBookAndKey = commentarySourceBookAndKey
            self.dictionaryAnchorOrdinal = dictionaryAnchorOrdinal
            self.generalBookAnchorOrdinal = generalBookAnchorOrdinal
            self.mapAnchorOrdinal = mapAnchorOrdinal
        }

        /** Reattaches this value snapshot to a newly owned window identifier. */
        func entry(windowID: UUID) -> RemoteSyncWorkspaceFidelityStore.PageManagerEntry {
            .init(
                windowID: windowID,
                rawCurrentCategoryName: rawCurrentCategoryName,
                commentarySourceBookAndKey: commentarySourceBookAndKey,
                dictionaryAnchorOrdinal: dictionaryAnchorOrdinal,
                generalBookAnchorOrdinal: generalBookAnchorOrdinal,
                mapAnchorOrdinal: mapAnchorOrdinal
            )
        }
    }

    /** Stores one expected file-backed clone without retaining SwiftData objects across reopen. */
    private struct PersistedCloneExpectation {
        let fixtureName: String
        let windowID: UUID
        let readerState: ReaderState
        let fidelityState: FidelityState
    }

    /**
     Returns every non-Bible category and special identity supported by persisted reader state.

     The modern EPUB case carries Android-style general-book initials and a numeric key, plus an
     opaque JavaScript-state value containing a generation-bearing resource URL. This verifies that
     cloning does not rewrite opaque state; live `EpubReader` generation selection belongs to the
     reader-controller boundary. The legacy EPUB case protects the old identifier/href migration
     fields until a reader next opens that pane.
     */
    private func categoryFixtures() -> [CategoryFixture] {
        [
            CategoryFixture(
                name: "commentary",
                categoryName: DocumentCategory.commentary.pageManagerKey,
                androidCategoryName: "COMMENTARY"
            ) {
                $0.currentCategoryName = DocumentCategory.commentary.pageManagerKey
                $0.commentaryDocument = "MHC"
                $0.commentaryAnchorOrdinal = 31_001
            },
            CategoryFixture(
                name: "dictionary",
                categoryName: DocumentCategory.dictionary.pageManagerKey,
                androidCategoryName: "DICTIONARY"
            ) {
                $0.currentCategoryName = DocumentCategory.dictionary.pageManagerKey
                $0.dictionaryDocument = "BDB"
                $0.dictionaryKey = "H7225"
            },
            CategoryFixture(
                name: "general book",
                categoryName: DocumentCategory.generalBook.pageManagerKey,
                androidCategoryName: "GENERAL_BOOK"
            ) {
                $0.currentCategoryName = DocumentCategory.generalBook.pageManagerKey
                $0.generalBookDocument = "Josephus"
                $0.generalBookKey = "War.1.2"
            },
            CategoryFixture(
                name: "My Documents",
                categoryName: DocumentCategory.generalBook.pageManagerKey,
                androidCategoryName: "GENERAL_BOOK"
            ) {
                $0.currentCategoryName = DocumentCategory.generalBook.pageManagerKey
                $0.generalBookDocument = "ResearchNotes"
                $0.generalBookKey = "page/faith-and-works"
            },
            CategoryFixture(
                name: "modern EPUB",
                categoryName: DocumentCategory.generalBook.pageManagerKey,
                androidCategoryName: "GENERAL_BOOK"
            ) {
                $0.currentCategoryName = DocumentCategory.generalBook.pageManagerKey
                $0.generalBookDocument = "StudyHandbook"
                $0.generalBookKey = "17"
                $0.epubIdentifier = nil
                $0.epubHref = nil
                $0.jsState = "{\"resource\":\"andbible-resource://epub/StudyHandbook/generation-42/OEBPS/ch17.xhtml\"}"
            },
            CategoryFixture(
                name: "legacy EPUB",
                categoryName: DocumentCategory.epub.pageManagerKey,
                androidCategoryName: "EPUB"
            ) {
                $0.currentCategoryName = DocumentCategory.epub.pageManagerKey
                $0.generalBookDocument = nil
                $0.generalBookKey = nil
                $0.epubIdentifier = "library-book-42"
                $0.epubHref = "OEBPS/chapter-02.xhtml#parable"
            },
            CategoryFixture(
                name: "maps",
                categoryName: DocumentCategory.map.pageManagerKey,
                androidCategoryName: "MAPS"
            ) {
                $0.currentCategoryName = DocumentCategory.map.pageManagerKey
                $0.mapDocument = "BibleAtlas"
                $0.mapKey = "jerusalem/temple-mount"
            },
            CategoryFixture(
                name: "daily devotion",
                categoryName: DocumentCategory.dailyDevotion.pageManagerKey,
                androidCategoryName: "DAILY_DEVOTION"
            ) {
                $0.currentCategoryName = DocumentCategory.dailyDevotion.pageManagerKey
                $0.generalBookDocument = "DailyLight"
                $0.generalBookKey = "2026-07-20-evening"
            },
            CategoryFixture(
                name: "Android My Note",
                categoryName: "MYNOTE",
                androidCategoryName: "MYNOTE"
            ) {
                $0.currentCategoryName = "MYNOTE"
                $0.bibleDocument = "KJV"
                $0.bibleVersification = "KJVA"
                $0.bibleBibleBook = 42
                $0.bibleChapterNo = 3
                $0.bibleVerseNo = 16
            },
        ]
    }

    /** Seeds every persisted page slot plus display and JavaScript state with distinct values. */
    private func seedCompleteReaderState(on pageManager: PageManager, index: Int) {
        pageManager.bibleDocument = "Bible-\(index)"
        pageManager.bibleVersification = "KJVA"
        pageManager.bibleBibleBook = index % 66
        pageManager.bibleChapterNo = index + 1
        pageManager.bibleVerseNo = index + 2
        pageManager.commentaryDocument = "Commentary-\(index)"
        pageManager.commentaryAnchorOrdinal = 10_000 + index
        pageManager.dictionaryDocument = "Dictionary-\(index)"
        pageManager.dictionaryKey = "dictionary-key-\(index)"
        pageManager.generalBookDocument = "GeneralBook-\(index)"
        pageManager.generalBookKey = "general-key-\(index)"
        pageManager.mapDocument = "Map-\(index)"
        pageManager.mapKey = "map-key-\(index)"
        pageManager.epubIdentifier = "legacy-epub-\(index)"
        pageManager.epubHref = "OPS/chapter-\(index).xhtml#section"
        var displaySettings = TextDisplaySettings()
        displaySettings.fontSize = 18 + index
        displaySettings.fontFamily = "serif-\(index)"
        displaySettings.showFootNotes = index.isMultiple(of: 2)
        displaySettings.bookmarksHideLabels = [UUID()]
        pageManager.textDisplaySettings = displaySettings
        pageManager.jsState = "{\"expanded\":[\"section-\(index)\"],\"scroll\":\(index)}"
    }

    /** Creates an isolated in-memory graph and local-settings store for one test. */
    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            Setting.self,
            Workspace.self,
            Window.self,
            PageManager.self,
            HistoryItem.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /** Creates separate file-backed workspace and local-settings stores for reopen coverage. */
    private func makePersistentContainer(in directory: URL) throws -> ModelContainer {
        let graphModels: [any PersistentModel.Type] = [
            Workspace.self,
            Window.self,
            PageManager.self,
            HistoryItem.self,
        ]
        let localModels: [any PersistentModel.Type] = [Setting.self]
        let schema = Schema(graphModels + localModels)
        let graphConfiguration = ModelConfiguration(
            "WindowCloneGraph",
            schema: Schema(graphModels),
            url: directory.appendingPathComponent("WindowCloneGraph.store"),
            cloudKitDatabase: .none
        )
        let localConfiguration = ModelConfiguration(
            "WindowCloneSettings",
            schema: Schema(localModels),
            url: directory.appendingPathComponent("WindowCloneSettings.store"),
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            configurations: [graphConfiguration, localConfiguration]
        )
    }
}
