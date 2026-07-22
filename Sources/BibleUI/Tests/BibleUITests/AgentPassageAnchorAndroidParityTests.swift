import SwordKit
import XCTest
@testable import BibleUI

/**
 Protects Android's stable non-Bible passage-anchor contract for agent commentary and general-book
 reads. Fixtures are canonical source fragments processed entirely in memory, so assertions cover
 the same BVA projection used by reader follow-up navigation without requiring installed modules.
 */
final class AgentPassageAnchorAndroidParityTests: XCTestCase {
    /**
     Verifies commentary text matches Android's exact marker placement and semantic formatting.

     The fixture mirrors `GetCommentariesTool` and `OsisToPlainTextTest` at Android commit
     `0f3b85823`: commentary verse wrappers are removed, title/body text receives local BVA
     ordinals, and those ordinals are exposed as `[§N]`. Failure means a marker can no longer be
     converted into a valid `linkUrl#oN` follow-up navigation target. No persistent state is used.
     */
    func testCommentaryTextMarkersMatchAndroidAndProcessedXMLOrdinals() throws {
        let content = try BibleUIAgentAnchoredDocumentContent(
            sourceXML: """
            <verse osisID="Matt.5.3">
              <title>Commentary Title</title>
              <p>Text here.</p>
            </verse>
            """,
            category: .commentary,
            moduleInitials: "MHC"
        )

        XCTAssertEqual(
            content.value(for: .text),
            "## [§0] Commentary Title\n\n[§1] Text here."
        )
        XCTAssertEqual(content.contentOrdinalRange, 0...1)
        XCTAssertTrue(content.hasRenderableContent)
        XCTAssertTrue(content.value(for: .xml).contains("ordinal=\"0\""))
        XCTAssertTrue(content.value(for: .xml).contains("ordinal=\"1\""))
        XCTAssertEqual(
            "\(BibleUIAgentJSON.swordURL(initials: "MHC", key: "Matt.5.3"))#o1",
            "sword://MHC/Matt.5.3#o1"
        )
    }

    /**
     Verifies multi-root general-book content receives deterministic entry-local ordinals.

     Android wraps all top-level nodes in one fragment before assigning anchors. Reprocessing the
     same source must produce identical text/XML, while a different entry restarts at ordinal zero
     because its own `linkUrl` is the navigation base. Failure indicates unstable citations or
     ordinal leakage across tool calls. No persistent state is used.
     */
    func testGeneralBookMultiRootAnchorsAreDeterministicAndRestartForEachEntry() throws {
        let source = """
        <title>Entry heading</title>
        <p>First block.</p>
        <p>Second block.</p>
        """
        let first = try BibleUIAgentAnchoredDocumentContent(
            sourceXML: source,
            category: .generalBook,
            moduleInitials: "Westminster"
        )
        let repeated = try BibleUIAgentAnchoredDocumentContent(
            sourceXML: source,
            category: .generalBook,
            moduleInitials: "Westminster"
        )
        let nextEntry = try BibleUIAgentAnchoredDocumentContent(
            sourceXML: "<p>Independent entry.</p>",
            category: .generalBook,
            moduleInitials: "Westminster"
        )

        XCTAssertEqual(first, repeated)
        XCTAssertEqual(
            first.value(for: .text),
            "## [§0] Entry heading\n\n[§1] First block.\n\n[§2] Second block."
        )
        XCTAssertEqual(first.contentOrdinalRange, 0...2)
        XCTAssertEqual(nextEntry.value(for: .text), "[§0] Independent entry.")
        XCTAssertEqual(nextEntry.contentOrdinalRange, 0...0)
    }

    /**
     Verifies an empty exact entry remains a valid result without a fabricated passage marker.

     Android represents an anchorless fragment with the sentinel local range `0...0`, but its text
     is empty and its XML has no BVA node. Failure means empty general-book content could crash,
     expose a non-navigable `[§0]`, or be confused with a missing key. No persistent state is used.
     */
    func testEmptyGeneralBookContentRemainsSafeAndAnchorless() throws {
        let content = try BibleUIAgentAnchoredDocumentContent(
            sourceXML: "",
            category: .generalBook,
            moduleInitials: "EmptyBook"
        )

        XCTAssertEqual(content.value(for: .text), "")
        XCTAssertEqual(content.contentOrdinalRange, 0...0)
        XCTAssertFalse(content.hasRenderableContent)
        XCTAssertFalse(content.value(for: .xml).contains("<BVA"))
    }
}
