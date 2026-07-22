import XCTest
import BibleCore
import BibleView
@testable import BibleUI

/**
 Protects the BibleUI boundaries used by Android-style sync-group selection.

 These tests keep zero-based storage separate from one-based labels and prove a real pane controller
 supplies a source-local ordinal that round-trips through the existing synchronized-reference path.
 No WebView, persistence, or network state is created.
 */
final class WindowSyncGroupParityTests: XCTestCase {
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
        let reference = try XCTUnwrap(controller.synchronizedVerseReference(ordinal: position.ordinal))

        XCTAssertEqual(position.key, "Gen.2.3")
        XCTAssertEqual(
            position.ordinal,
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 2, verse: 3)
        )
        XCTAssertEqual(reference.osisBookId, "Gen")
        XCTAssertEqual(reference.chapter, 2)
        XCTAssertEqual(reference.verse, 3)
    }
}
