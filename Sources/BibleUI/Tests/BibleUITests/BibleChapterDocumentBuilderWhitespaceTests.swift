import XCTest

@testable import BibleUI

/** Protects Java-significant source whitespace through final reader chapter XML emission. */
final class BibleChapterDocumentBuilderWhitespaceTests: XCTestCase {
    /**
     Verifies the chapter builder does not pre-trim NBSP before structured verse projection.

     - Setup: Builds one emitted verse from raw OSIS with ordinary outer whitespace surrounding
       leading/trailing NBSP content.
     - Expected result: The lossless shared projector retains ordinary source edges and both NBSP;
       the builder adds only its established inter-verse trailing space.
     - Failure meaning: Reader display and Search canonical text can observe different source bytes
       because the chapter caller reapplied Foundation's broader whitespace rules.
     - Side effects: Parses one bounded in-memory verse fragment.
     */
    func testVerseChunkEmissionPreservesEdgeNBSP() {
        let xml = BibleChapterDocumentBuilder.buildVerseChunkXML(
            osisBookId: "Gen",
            chapter: 1,
            verses: [
                BibleChapterDocumentBuilder.VerseEntry(
                    verse: 1,
                    ordinal: 4,
                    xml: " \n\u{00A0}edge\u{00A0}\n "
                ),
            ]
        )

        XCTAssertEqual(
            xml,
            "<div><verse osisID=\"Gen.1.1\" verseOrdinal=\"4\"> \n\u{00A0}edge\u{00A0}\n  </verse></div>"
        )
    }
}
