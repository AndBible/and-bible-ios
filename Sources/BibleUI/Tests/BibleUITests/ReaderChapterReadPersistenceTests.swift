import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 Exercises chapter-read persistence through the production reader, bridge, SWORD projection, and
 file-backed settings store.

 These tests deliberately use ordinals emitted in reader document JSON. That is the identity Vue
 sends back for current and infinite-scroll chapters, including chapter introductions that precede
 verse one. A passing test therefore proves the user workflow rather than a hand-selected ordinal
 that bypasses document preparation.
 */
final class ReaderChapterReadPersistenceTests: BibleUISwordFixtureTestCase {
    /**
     Verifies repeated manual reads survive a file-backed store reopen and hydrate a fresh document.

     The first controller loads Genesis 1, derives the bridge start ordinal from the emitted document,
     and records two manual taps. A new container and controller then open the same SQLite store and
     rebuild Genesis 1. The durable history and emitted `chapterReadCount` must both equal two.

     - Side effects: Creates a process-lifetime SwiftData store and temporary SWORD fixture, writes
       two reading-progress rows, and runs two asynchronous reader preparation operations.
     - Failure modes: Throws fixture, SwiftData, bridge-payload, or preparation errors; XCTest records
       incorrect counts. The temporary persistent directory remains for the test process because
       SwiftData provides no synchronous container-close boundary.
     */
    @MainActor
    func testRepeatedManualReadsSurviveStoreReopenAndHydrateDocumentCount() async throws {
        let directory = try makePersistentStoreDirectory(label: "chapter-read-reopen")
        let storeURL = directory.appendingPathComponent("ReaderProgress.store")
        let modulePath = try makeTemporarySwordFixturePath()

        do {
            let container = try makePersistentSettingsContainer(at: storeURL)
            let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
            let (bridge, scripts) = makeRecordingBridge()
            let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
            controller.settingsStore = SettingsStore(modelContext: ModelContext(container))

            let document = try await loadCurrentDocument(controller: controller, scripts: scripts)
            let startOrdinal = try documentStartOrdinal(document)
            let chapter = try XCTUnwrap(document["chapterNumber"] as? Int)
            let initials = try XCTUnwrap(document["bookInitials"] as? String)

            for _ in 0..<2 {
                XCTAssertEqual(
                    bridge.dispatchMessage(
                        method: "recordChapterRead",
                        args: [initials, startOrdinal, chapter, "MANUAL"]
                    ),
                    .handled
                )
            }
            XCTAssertEqual(
                controller.readingProgressStore?.snapshot().history.count,
                2,
                "Both manual taps must become separate Android-compatible history rows"
            )
        }

        let reopenedContainer = try makePersistentSettingsContainer(at: storeURL)
        let reopenedManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (reopenedBridge, reopenedScripts) = makeRecordingBridge()
        let reopenedController = BibleReaderController(
            bridge: reopenedBridge,
            swordManagerOverride: reopenedManager
        )
        reopenedController.settingsStore = SettingsStore(
            modelContext: ModelContext(reopenedContainer)
        )

        let reopenedDocument = try await loadCurrentDocument(
            controller: reopenedController,
            scripts: reopenedScripts
        )
        XCTAssertEqual(reopenedController.readingProgressStore?.snapshot().history.count, 2)
        XCTAssertEqual(reopenedDocument["chapterReadCount"] as? Int, 2)
    }

    /**
     Verifies bridge validation accepts emitted introduction and adjacent-document ordinals.

     Genesis 1 uses the exact start ordinal from the replacement document, which can be a chapter or
     book introduction before verse one. Genesis 2 comes from the real infinite-scroll response while
     native navigation remains on Genesis 1. Both valid documents must record reads, while replaying
     the Genesis 2 ordinal with a mismatched chapter must leave history unchanged.

     - Side effects: Creates an in-memory settings store, prepares current and adjacent SWORD
       documents, and records two valid manual read rows through `BibleBridge`.
     - Failure modes: Throws fixture, payload, or asynchronous preparation errors; XCTest records
       rejection of valid document identities or acceptance of the mismatched chapter.
     */
    @MainActor
    func testEmittedIntroductionAndAdjacentChapterOrdinalsAreAcceptedButMismatchIsRejected() async throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()

        let current = try await loadCurrentDocument(controller: controller, scripts: scripts)
        let initials = try XCTUnwrap(current["bookInitials"] as? String)
        let currentStart = try documentStartOrdinal(current)
        let currentChapter = try XCTUnwrap(current["chapterNumber"] as? Int)
        let module = try XCTUnwrap(manager.module(named: initials))
        let verseOne = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        XCTAssertLessThan(
            currentStart,
            verseOne,
            "The fixture must exercise the introduction-inclusive ordinal emitted before verse one"
        )
        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "recordChapterRead",
                args: [initials, currentStart, currentChapter, "MANUAL"]
            ),
            .handled
        )
        XCTAssertEqual(controller.readingProgressStore?.snapshot().history.count, 1)

        let responseBoundary = scripts().count
        controller.bridge(bridge, requestMoreToEnd: 4321)
        let optionalResponse = try await awaitBridgeScript(
            from: scripts,
            after: responseBoundary,
            description: "adjacent Bible chapter response"
        ) { $0.hasPrefix("bibleView.response(4321,") }
        let response = try XCTUnwrap(optionalResponse)
        let adjacent = try bridgeResponseObject(response)
        let adjacentStart = try documentStartOrdinal(adjacent)
        let adjacentChapter = try XCTUnwrap(adjacent["chapterNumber"] as? Int)

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "recordChapterRead",
                args: [initials, adjacentStart, adjacentChapter, "AUTO_SCROLL"]
            ),
            .handled
        )
        XCTAssertEqual(controller.readingProgressStore?.snapshot().history.count, 2)
        XCTAssertTrue(
            controller.readingProgressStore?.snapshot().history.contains {
                $0.chapter == adjacentChapter && $0.source == .autoScroll
            } == true,
            "The streamed chapter must retain the source supplied by automatic tracking"
        )

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "recordChapterRead",
                args: [initials, adjacentStart, adjacentChapter + 1, "MANUAL"]
            ),
            .handled
        )
        XCTAssertEqual(
            controller.readingProgressStore?.snapshot().history.count,
            2,
            "A chapter number that disagrees with the emitted ordinal must fail closed"
        )
    }

    /**
     Verifies every chapter-history action accepts a streamed first chapter from the next book.

     The controller navigates to Genesis 50, then Vue's append request produces Exodus 1 while
     native current-book state remains Genesis. The test uses the appended document's exact ordinal
     for record, open-history, and unmark. This protects the shared resolver from consulting only the
     controller's current book or rejecting the book-introduction ordinal emitted for chapter one.

     - Side effects: Prepares Genesis 50 and streamed Exodus 1 documents, appends and removes one
       in-memory history row, and invokes the native history presentation callback once.
     - Failure modes: Throws fixture, bridge-payload, or preparation errors; XCTest records a
       rejected adjacent-book identity, missing history presentation, or failed removal.
     */
    @MainActor
    func testAdjacentNextBookDocumentSupportsRecordHistoryAndUnmark() async throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()

        let initialBoundary = scripts().count
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: initialBoundary)
        let replacementBoundary = scripts().count
        controller.navigateTo(book: "Genesis", chapter: 50)
        let replacementEmissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: replacementBoundary
        )
        let genesis50 = try XCTUnwrap(
            bridgeEmissionPayload(
                from: replacementEmissions,
                event: "add_documents",
                selection: .last
            ) as? [String: Any]
        )
        XCTAssertEqual(genesis50["chapterNumber"] as? Int, 50)

        let responseBoundary = scripts().count
        controller.bridge(bridge, requestMoreToEnd: 4322)
        let optionalResponse = try await awaitBridgeScript(
            from: scripts,
            after: responseBoundary,
            description: "first chapter of the adjacent Bible book"
        ) { $0.hasPrefix("bibleView.response(4322,") }
        let response = try XCTUnwrap(optionalResponse)
        let exodus = try bridgeResponseObject(response)
        let initials = try XCTUnwrap(exodus["bookInitials"] as? String)
        let startOrdinal = try documentStartOrdinal(exodus)
        let chapter = try XCTUnwrap(exodus["chapterNumber"] as? Int)
        XCTAssertEqual(exodus["bibleBookName"] as? String, "Exodus")
        XCTAssertEqual(chapter, 1)

        let module = try XCTUnwrap(manager.module(named: initials))
        let exodusVerseOne = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Exod", chapter: 1, verse: 1)
        )
        XCTAssertLessThan(
            startOrdinal,
            exodusVerseOne,
            "A streamed first chapter must retain its emitted book-introduction start"
        )

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "recordChapterRead",
                args: [initials, startOrdinal, chapter, "MANUAL"]
            ),
            .handled
        )
        XCTAssertEqual(controller.readingProgressStore?.snapshot().history.count, 1)

        var presentedTarget: ChapterReadHistoryTarget?
        controller.onShowChapterReadHistory = { presentedTarget = $0 }
        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "openChapterReadHistory",
                args: [initials, startOrdinal, chapter]
            ),
            .handled
        )
        XCTAssertEqual(presentedTarget?.bookName, "Exodus")
        XCTAssertEqual(presentedTarget?.chapter, 1)

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "unmarkChapterRead",
                args: [initials, startOrdinal, chapter]
            ),
            .handled
        )
        XCTAssertTrue(controller.readingProgressStore?.snapshot().history.isEmpty == true)
    }

    /**
     Verifies a real SQLite Bible document persists progress while foreign identities fail closed.

     The test installs the checked-in MyBible fixture, switches the production reader to that
     SQLite source, and records the exact chapter identity emitted to Vue. A freshly opened
     file-backed settings container must contain that row. Calls naming an unknown module or using
     an Exodus ordinal outside the owned Genesis document must not append another row.

     - Side effects: Copies one SQLite fixture, creates a disk-backed SwiftData store, prepares a
       SQLite reader document, and writes one reading-progress row through the production bridge.
     - Failure modes: Throws fixture, SwiftData, reader-preparation, or payload errors; XCTest records
       rejected valid SQLite progress, lost durability, or mutation by an unauthorized identity.
     */
    @MainActor
    func testSQLiteChapterReadPersistsWhileUnknownModuleAndUnownedOrdinalAreRejected() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installMyBibleFixture(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let directory = try makePersistentStoreDirectory(label: "sqlite-chapter-read")
        let storeURL = directory.appendingPathComponent("SQLiteReaderProgress.store")
        let container = try makePersistentSettingsContainer(at: storeURL)
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = SettingsStore(modelContext: ModelContext(container))
        let window = Window()
        let pageManager = PageManager(id: window.id)
        retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
        controller.bridgeDidSetClientReady(bridge)

        let boundary = scripts().count
        XCTAssertEqual(controller.switchBibleDocument(to: "MyBible-bible"), .switched)
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(
                from: emissions,
                event: "add_documents",
                selection: .last
            ) as? [String: Any]
        )
        let initials = try XCTUnwrap(document["bookInitials"] as? String)
        let startOrdinal = try documentStartOrdinal(document)
        let chapter = try XCTUnwrap(document["chapterNumber"] as? Int)
        XCTAssertEqual(initials, "MyBible-bible")

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "recordChapterRead",
                args: [initials, startOrdinal, chapter, "MANUAL"]
            ),
            .handled
        )
        XCTAssertEqual(controller.readingProgressStore?.snapshot().history.count, 1)

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "recordChapterRead",
                args: ["UnknownSQLiteModule", startOrdinal, chapter, "MANUAL"]
            ),
            .handled
        )
        let unownedOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(
                osisId: "Exod",
                chapter: 1,
                verse: 1
            )
        )
        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "recordChapterRead",
                args: [initials, unownedOrdinal, chapter, "MANUAL"]
            ),
            .handled
        )
        XCTAssertEqual(
            controller.readingProgressStore?.snapshot().history.count,
            1,
            "Unknown sources and ordinals outside the rendered document must not mutate progress"
        )

        let reopenedContainer = try makePersistentSettingsContainer(at: storeURL)
        let reopened = ReadingProgressStore(
            settingsStore: SettingsStore(modelContext: ModelContext(reopenedContainer))
        )
        XCTAssertEqual(reopened.snapshot().history.count, 1)
        XCTAssertEqual(reopened.snapshot().history.first?.bookInitials, "MyBible-bible")
    }

    /**
     Loads the controller's current chapter and returns the exact document object emitted to Vue.

     - Parameters:
       - controller: Production reader controller configured with a recording bridge.
       - scripts: Recorder closure paired with the controller bridge.
     - Returns: Parsed `add_documents` object after asynchronous preparation publishes.
     - Side effects: Starts one reader document preparation and waits for its bridge publication.
     - Failure modes: Throws cancellation, timeout, extraction, or JSON-shape errors.
     */
    @MainActor
    private func loadCurrentDocument(
        controller: BibleReaderController,
        scripts: @escaping () -> [String]
    ) async throws -> [String: Any] {
        let boundary = scripts().count
        controller.loadCurrentContent()
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        return try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
    }

    /**
     Extracts Vue's bridge start ordinal from a prepared Bible document.

     - Parameter document: Parsed reader document containing a two-element `ordinalRange`.
     - Returns: The first source ordinal exactly as emitted to Vue.
     - Side effects: none.
     - Failure modes: Throws an XCTest unwrap error when the document omits a valid integer range.
     */
    private func documentStartOrdinal(_ document: [String: Any]) throws -> Int {
        let range = try XCTUnwrap(document["ordinalRange"] as? [Int])
        return try XCTUnwrap(range.first)
    }

    /**
     Creates a disk-backed container containing the production `Setting` model.

     - Parameter storeURL: Stable SQLite URL reused by the reopen phase.
     - Returns: A new SwiftData container connected to that URL.
     - Side effects: Creates or opens the SQLite store and its sidecar files.
     - Failure modes: Rethrows schema or persistent-store initialization failures.
     */
    private func makePersistentSettingsContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema([Setting.self])
        let configuration = ModelConfiguration(
            "ReaderChapterReadPersistence",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /**
     Creates a unique process-lifetime directory for a SwiftData regression store.

     - Parameter label: Stable diagnostic prefix for the fixture family.
     - Returns: Newly created unique directory beneath the process temporary directory.
     - Side effects: Creates the directory on disk.
     - Failure modes: Rethrows filesystem directory-creation errors.
     */
    private func makePersistentStoreDirectory(label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("andbible-reader-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /**
     Installs the checked-in MyBible Bible fixture into Android's discovery directory.

     - Parameter modulePath: Temporary module root returned by the SWORD fixture base class.
     - Side effects: Creates `mybible` and copies one immutable SQLite database into it.
     - Failure modes: Throws repository-location, directory-creation, or file-copy errors.
     */
    private func installMyBibleFixture(in modulePath: String) throws {
        let repositoryRoot = try BibleUITestSourceLocator.repositoryRoot(
            containing: "Sources/BibleCore/Tests/Fixtures/SQLiteDocumentReaders"
        )
        let source = repositoryRoot
            .appendingPathComponent("Sources/BibleCore/Tests/Fixtures/SQLiteDocumentReaders")
            .appendingPathComponent("mybible-bible.SQLite3")
        let destination = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mybible", isDirectory: true)
            .appendingPathComponent("bible.SQLite3")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /**
     Decodes the object argument from an exact `bibleView.response` script.

     - Parameter script: JavaScript response emitted by the production bridge.
     - Returns: Parsed adjacent reader document.
     - Side effects: none.
     - Failure modes: Throws an XCTest unwrap or JSON decoding error for malformed responses.
     */
    private func bridgeResponseObject(_ script: String) throws -> [String: Any] {
        let comma = try XCTUnwrap(script.firstIndex(of: ","))
        XCTAssertTrue(script.hasSuffix(");"))
        let jsonStart = script.index(after: comma)
        let jsonEnd = script.index(script.endIndex, offsetBy: -2)
        let json = script[jsonStart..<jsonEnd].trimmingCharacters(in: .whitespaces)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
    }
}
