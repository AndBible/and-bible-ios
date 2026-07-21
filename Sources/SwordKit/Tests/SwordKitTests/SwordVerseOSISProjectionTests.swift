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
     Verifies malformed source takes the lossless compatibility path.

     A malformed entry cannot be structurally partitioned, so the original trimmed fragment must
     remain in the verse body and no preamble may be invented.
     */
    func testMalformedFragmentRemainsInVerseBody() {
        let malformed = "<w>Unclosed"
        let projection = SwordVerseOSISProjection.project(malformed)

        XCTAssertEqual(projection.preVerseXML, "")
        XCTAssertEqual(projection.verseBodyXML, malformed)
    }
}
