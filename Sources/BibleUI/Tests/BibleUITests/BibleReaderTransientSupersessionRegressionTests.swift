import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/** Regression coverage for cancellation and replay ownership of pre-ready transient documents. */
@MainActor
final class BibleReaderTransientSupersessionRegressionTests: BibleUISwordFixtureTestCase {
    private var retainedPaneOwners: [(WindowManager, ModelContainer?)] = []
    /** A superseded pre-ready Multi cannot replay after its cancelled waiter has settled. */
    func testPreReadyMultiSupersededByMyNotesCannotReplayAfterClientReady() async throws {
        let manager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let myNotesOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Matt", chapter: 1, verse: 1)
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        try attachWindow(to: controller)
        let boundary = scripts().count

        let superseded = Task { @MainActor in
            await controller.loadRestoredAndroidMultiDocumentAwaitingSelection(
                pageKey: "KJV:Gen.1.1"
            )
        }
        try await awaitReaderCondition("pre-ready Multi selected intent committed") {
            controller.currentGeneralBookKey == "KJV:Gen.1.1"
        }
        XCTAssertTrue(addDocumentEmissions(in: scripts(), after: boundary).isEmpty)

        let replacement = Task { @MainActor in
            await controller.loadMyNotesDocumentAwaitingSelection(
                jumpToOrdinal: myNotesOrdinal
            )
        }
        try await awaitReaderCondition("replacement My Notes target retained") {
            controller.showingMyNotes
        }
        let supersededDisposition = await superseded.value
        XCTAssertEqual(supersededDisposition, .cancelled)
        XCTAssertTrue(addDocumentEmissions(in: scripts(), after: boundary).isEmpty)

        controller.bridgeDidSetClientReady(bridge)

        let replacementDisposition = await replacement.value
        XCTAssertEqual(replacementDisposition, .accepted)
        let emitted = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        let replacements = addDocumentEmissions(in: emitted, after: 0)
        XCTAssertEqual(replacements.count, 1)
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: replacements, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "notes")
        XCTAssertTrue(controller.showingMyNotes)
        XCTAssertEqual(controller.committedRenderState.identity?.moduleName, "My Notes")
        XCTAssertEqual(controller.committedRenderState.identity?.book, "My Notes")
        XCTAssertNotEqual(controller.committedRenderState.identity?.moduleName, "Multi")
    }

    /** Filters only document-replacement emissions; labels and setup/config traffic are permitted. */
    private func addDocumentEmissions(in scripts: [String], after boundary: Int) -> [String] {
        Array(scripts.dropFirst(boundary)).filter { $0.contains("emit('add_documents'") }
    }

    private func attachWindow(to controller: BibleReaderController) throws {
        let owner = try registerMyNotesPaneOwner(controller)
        retainedPaneOwners.append((owner.manager, owner.container))
    }
}
