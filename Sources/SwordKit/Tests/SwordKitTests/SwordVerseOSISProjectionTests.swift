import XCTest
@testable import SwordKit

/** Android-parity coverage for reconstructing chapter OSIS from individual SWORD verse entries. */
final class SwordVerseOSISProjectionTests: XCTestCase {
    /**
     Verifies paragraph and pre-verse milestones become siblings before the synthetic verse.

     The fixture models the ESV Genesis 1:6 entry that previously placed a block-level paragraph
     marker inside an inline verse span. That malformed nesting caused WebKit to fully justify the
     short final line of Genesis 1:5. Inline Strong's markup must remain in the verse body.
     */
    func testLeadingParagraphMilestonesAreProjectedBeforeVerseBody() {
        let projection = SwordVerseOSISProjection.project(
            """
            <div type="x-milestone" subType="x-preverse" sID="pv3"/>
            <div sID="gen4" type="paragraph"/>
            <div type="x-milestone" subType="x-preverse" eID="pv3"/>
            <w lemma="strong:H0559">And God said</w>, Let there be light.
            """
        )

        XCTAssertTrue(projection.preVerseXML.contains("sID=\"pv3\""))
        XCTAssertTrue(projection.preVerseXML.contains("sID=\"gen4\""))
        XCTAssertTrue(projection.preVerseXML.contains("eID=\"pv3\""))
        XCTAssertFalse(projection.preVerseXML.contains("And God said"))
        XCTAssertTrue(projection.verseBodyXML.contains("<w lemma=\"strong:H0559\">And God said</w>"))
        XCTAssertTrue(projection.verseBodyXML.contains("Let there be light."))
        XCTAssertFalse(projection.verseBodyXML.contains("type=\"paragraph\""))
    }

    /**
     Verifies ESV Psalm stanza preambles remain at chapter level in Android's exact node order.

     The paired `lg` start sits between pre-verse start and end milestones in installed ESV2011
     content. Leaving it inside the synthetic inline verse creates another block boundary and fully
     justifies the preceding short line. Failure means poetic passages retain that reader regression.
     */
    func testLeadingPsalmLineGroupMilestonesAreProjectedBeforeVerseBody() throws {
        let projection = SwordVerseOSISProjection.project(
            """
            <div type="x-milestone" subType="x-preverse" sID="pv-psalm"/>
            <lg sID="lg-psalm"/>
            <div type="x-milestone" subType="x-preverse" eID="pv-psalm"/>
            <l sID="line-1"/>Blessed is the man
            """
        )

        let preVerse = projection.preVerseXML
        let preVerseStart = try XCTUnwrap(preVerse.range(of: "sID=\"pv-psalm\""))
        let lineGroupStart = try XCTUnwrap(preVerse.range(of: "sID=\"lg-psalm\""))
        let preVerseEnd = try XCTUnwrap(preVerse.range(of: "eID=\"pv-psalm\""))
        XCTAssertLessThan(preVerseStart.lowerBound, lineGroupStart.lowerBound)
        XCTAssertLessThan(lineGroupStart.lowerBound, preVerseEnd.lowerBound)
        XCTAssertFalse(projection.preVerseXML.contains("Blessed is the man"))
        XCTAssertTrue(projection.verseBodyXML.contains("<l sID=\"line-1\"/>"))
        XCTAssertTrue(projection.verseBodyXML.contains("Blessed is the man"))
    }

    /**
     Verifies trailing paragraph ends stay inside the verse, matching Android's chapter OSIS.

     Only leading chapter structure is lifted. A paragraph `eID` after verse text closes the
     paragraph at the correct lexical position and must not be reordered past the verse wrapper.
     */
    func testTrailingParagraphEndRemainsInVerseBody() {
        let projection = SwordVerseOSISProjection.project(
            "The first day.<div eID=\"gen3\" type=\"paragraph\"/>"
        )

        XCTAssertEqual(projection.preVerseXML, "")
        XCTAssertTrue(projection.verseBodyXML.hasPrefix("The first day."))
        XCTAssertTrue(projection.verseBodyXML.contains("eID=\"gen3\""))
    }

    /**
     Pins JSword's last-qualified-preverse boundary instead of broad title/milestone lifting.

     - Setup: Projects an ordinary title, body before a late x-preverse div, and trailing prose.
     - Expected result: Ordinary title remains body content; the late marker makes every preceding
       node chapter-level, and only the suffix after the last marker remains the verse body.
     - Failure meaning: iOS can omit ordinary title text or wrap a different node range than Android.
     - Side effects: Parses bounded in-memory fragments.
     */
    func testLastExactPreVerseBoundaryMatchesSwordBook() {
        let ordinaryTitle = SwordVerseOSISProjection.project("<title>Heading</title>Body")
        XCTAssertEqual(ordinaryTitle.preVerseXML, "")
        XCTAssertEqual(ordinaryTitle.verseBodyXML, "<title>Heading</title>Body")

        let lateBoundary = SwordVerseOSISProjection.project(
            "Before<div subType=\"x-preverse\" type=\"x-milestone\"/>After"
        )
        XCTAssertTrue(lateBoundary.preVerseXML.hasPrefix("Before<div"))
        XCTAssertEqual(lateBoundary.verseBodyXML, "After")
    }

    /**
     Verifies pinned Psalm-title repair becomes canonical preverse source before both consumers.

     - Setup: Supplies a type=psalm title without canonical or subtype attributes.
     - Expected result: Shared source gains canonical=true and x-preverse; the title is retained at
       chapter level and prose alone remains the synthetic verse body.
     - Failure meaning: Psalm superscriptions can disappear from canonical Search or leak preview.
     - Side effects: Mutates one bounded parsed tree before deterministic serialization.
     */
    func testPsalmTitleRepairMatchesSwordBook() {
        let projection = SwordVerseOSISProjection.project(
            "<title type=\"psalm\">Superscription</title>Verse"
        )

        XCTAssertTrue(projection.sourceXML.contains("canonical=\"true\""))
        XCTAssertTrue(projection.sourceXML.contains("subType=\"x-preverse\""))
        XCTAssertTrue(projection.preVerseXML.contains("Superscription"))
        XCTAssertEqual(projection.verseBodyXML, "Verse")
    }

    /**
     Verifies an existing direct verse is never synthetically wrapped a second time.

     - Setup: Supplies a sibling title and direct verse while requesting an emitted ordinal.
     - Expected result: Full source remains one already-wrapped body and the existing verse receives
       the ordinal JSword adds; no preverse split is applied.
     - Failure meaning: Native modules with verse markup can produce nested verse elements.
     - Side effects: Mutates one bounded parsed verse attribute.
     */
    func testExistingVerseSkipsSyntheticWrapperAndReceivesOrdinal() {
        let projection = SwordVerseOSISProjection.project(
            "<title>Outside</title><verse osisID=\"Gen.1.1\">Body</verse>",
            verseOrdinal: 4
        )

        XCTAssertTrue(projection.isAlreadyWrapped)
        XCTAssertEqual(projection.preVerseXML, "")
        XCTAssertTrue(projection.verseBodyXML.contains("<verse osisID=\"Gen.1.1\" verseOrdinal=\"4\">"))
        XCTAssertTrue(projection.verseBodyXML.contains("<title>Outside</title>"))
    }

    /**
     Verifies malformed source takes the lossless compatibility path.

     A malformed entry cannot be structurally partitioned, so the exact original fragment must
     remain in the verse body and no preamble may be invented.
     */
    func testMalformedFragmentRemainsInVerseBody() {
        let malformed = "<w>Unclosed"
        let projection = SwordVerseOSISProjection.project(malformed)

        XCTAssertEqual(projection.preVerseXML, "")
        XCTAssertEqual(projection.verseBodyXML, malformed)
    }

    /**
     Verifies all outer source whitespace survives the shared fragment boundary.

     - Setup: Projects a verse body surrounded by NBSP while ordinary ASCII whitespace surrounds it.
     - Expected result: ASCII formatting and both NBSP remain in the serialized verse body; each
       downstream canonical/preview domain applies its own distinct whitespace rules.
     - Failure meaning: Foundation whitespace classification can erase source content before reader
       rendering or canonical Search traversal observes it.
     - Side effects: Parses one bounded in-memory fragment.
     */
    func testOuterWhitespaceAndNBSPRemainLossless() {
        let projection = SwordVerseOSISProjection.project(
            " \n\u{00A0}edge\u{00A0}\n "
        )

        XCTAssertEqual(projection.preVerseXML, "")
        XCTAssertEqual(projection.verseBodyXML, " \n\u{00A0}edge\u{00A0}\n ")
    }
}
