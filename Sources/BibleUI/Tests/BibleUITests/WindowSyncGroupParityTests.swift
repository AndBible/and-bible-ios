import XCTest
import BibleCore
import BibleView
import SwordKit
@testable import BibleUI

/**
 Protects the BibleUI boundaries used by Android-style sync-group selection.

 These tests keep zero-based storage separate from one-based labels and prove real pane controllers
 preserve typed synchronization across versifications. The installer integration uses an isolated
 in-memory workspace, temporary licensed-safe SWORD fixtures, and recording bridges; no network state
 is created.
 */
final class WindowSyncGroupParityTests: BibleUISwordFixtureTestCase {
    /**
     Verifies stored groups `0...5` display as `Group 1...6`.

     A failure reintroduces the tab-menu regression where raw stored values leaked into labels.
     */
    func testStoredSyncGroupsUseOneBasedDisplayTitles() {
        XCTAssertEqual(
            WindowSyncGroupPresentation.storedGroups.map {
                WindowSyncGroupPresentation.title(forStoredGroup: $0)
            },
            ["Group 1", "Group 2", "Group 3", "Group 4", "Group 5", "Group 6"]
        )
    }

    /**
     Verifies a real Bible pane exposes a source-local position that resolves to the same verse.

     The no-SWORD fixture uses the same genuine KJVA ordinal domain as its synthetic reader content.
     The source-reference resolver must recover `Gen.2.3`; target panes then perform their own
     conversion. A failure indicates raw or compatibility ordinals could leak across panes or the
     immediate group callback cannot use the normal feedback-safe path.
     */
    @MainActor
    func testReaderControllerSyncSourceRoundTripsThroughConvertedReference() throws {
        let controller = BibleReaderController(bridge: BibleBridge(), initializesSword: false)
        controller.navigateTo(book: "Genesis", chapter: 2, verse: 3)

        let source = controller as any WindowSynchronizationSource
        XCTAssertTrue(source.canProvideWindowSynchronizationPosition)
        let position = try XCTUnwrap(source.currentWindowSynchronizationPosition())
        XCTAssertEqual(position.sourceVersification, JSwordKJVAVersification.name)
        XCTAssertEqual(position.osisBookId, "Gen")
        XCTAssertEqual(position.chapter, 2)
        XCTAssertEqual(position.verse, 3)
        XCTAssertEqual(position.sourceKey, "Gen.2.3")
        XCTAssertEqual(
            position.sourceOrdinal,
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 2, verse: 3)
        )
    }
    /**
     Verifies the installed callback applies an admitted My Notes KJVA coordinate in target Vulgate.

     The source owns KJVA Psalm 11's introduction while the target's active Vulgate Bible represents
     it as Psalm 10:1. The test captures the immutable source position, changes later source state,
     and invokes the actual installed callback. Only the exact registered target may map the captured
     value; consulting the source controller later would select the replacement Genesis position.
     */
    @MainActor
    func testInstalledSynchronizationMapsCapturedMyNotesKJVAPositionIntoVulgateTarget() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedSyntheticRawTextBibleModule(
            named: "VulgTest",
            description: "Vulgate synchronization target",
            versification: "Vulg",
            entries: [
                ("Ps", 1, 1, #"<verse osisID="Ps.1.1">Vulgate Psalms admission.</verse>"#),
                ("Ps", 10, 1, #"<verse osisID="Ps.10.1">Mapped Vulgate target.</verse>"#),
                ("Ps", 10, 2, #"<verse osisID="Ps.10.2">Distinct starting row.</verse>"#),
            ],
            in: modulePath
        )
        let swordManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let sourceController = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: swordManager
        )
        let (targetBridge, targetScripts) = makeRecordingBridge()
        let targetController = BibleReaderController(
            bridge: targetBridge,
            swordManagerOverride: swordManager
        )
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: container.mainContext)
        let workspace = store.createWorkspace(name: "Typed synchronization installer")
        let sourceWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: store)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        sourceController.activeWindow = sourceWindow
        sourceController.workspaceStore = store
        sourceController.windowManagerRef = windowManager
        targetController.activeWindow = targetWindow
        targetController.workspaceStore = store
        targetController.windowManagerRef = windowManager
        XCTAssertTrue(windowManager.registerController(sourceController, for: sourceWindow))
        XCTAssertTrue(windowManager.registerController(targetController, for: targetWindow))
        XCTAssertEqual(targetController.switchModule(to: "VulgTest"), .switched)
        XCTAssertTrue(targetController.navigateTo(book: "Psalms", chapter: 10, verse: 2))
        targetController.bridgeDidSetClientReady(targetBridge)
        XCTAssertEqual(targetController.currentChapter, 10)
        XCTAssertEqual(targetController.currentVerse, 2)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 2)

        let psalmElevenIntroduction = try XCTUnwrap(
            JSwordKJVAVersification.chapterIntroOrdinal(osisId: "Ps", chapter: 11)
        )
        sourceController.loadMyNotesDocument(
            v11nName: JSwordKJVAVersification.name,
            sourceOrdinal: psalmElevenIntroduction
        )
        let admitted = try XCTUnwrap(sourceController.currentWindowSynchronizationPosition())
        XCTAssertEqual(admitted.sourceVersification, JSwordKJVAVersification.name)
        XCTAssertEqual(admitted.osisBookId, "Ps")
        XCTAssertEqual(admitted.chapter, 11)
        XCTAssertEqual(admitted.verse, 0)

        XCTAssertTrue(sourceController.navigateTo(book: "Genesis", chapter: 1, verse: 1))
        BibleReaderWindowSynchronization.install(on: windowManager)
        let bridgeBoundary = targetScripts().count
        windowManager.onSyncVerseChanged?(
            sourceWindow,
            WindowSynchronizationDelivery(position: admitted, targets: [targetWindow])
        )

        XCTAssertEqual(targetController.activeSourceVersificationName(), "Vulg")
        XCTAssertEqual(targetController.currentBook, "Psalms")
        XCTAssertEqual(targetController.currentChapter, 10)
        XCTAssertEqual(targetController.currentVerse, 1)
        XCTAssertEqual(targetWindow.pageManager?.bibleChapterNo, 10)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 1)
        let deliveryScripts = Array(targetScripts().dropFirst(bridgeBoundary))
        XCTAssertEqual(deliveryScripts.filter { $0.contains("scroll_to_verse") }.count, 1)
        withExtendedLifetime(container) {}
    }

}
