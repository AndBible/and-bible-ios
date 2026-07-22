import Foundation
import XCTest
@testable import BibleCore

/**
 Protects Android-parity display names loaded from the pinned JSword `BibleNames` resources.

 The tests use immutable bundled resources only and create no files or shared locale state. A
 failure means reader payloads can fall back to backend-specific SWORD names or lose books outside
 KJVA even though Android can name the same `BibleBook`.
 */
final class JSwordBibleNamesTests: XCTestCase {
    /**
     Verifies preferred names cover both the reported KJV regression and non-KJVA source books.

     Android's `VerseRange.name` asks `BibleNames` for every `BibleBook`, not only the books in its
     KJVA versification. English is passed explicitly so the test is independent of host locale.
     */
    func testLocalizedLongNamesCoverKJVAAndExtendedCanonBooks() {
        let english = Locale(identifier: "en")

        XCTAssertEqual(
            JSwordBibleNames.localizedLongName(osisId: "2Cor", locale: english),
            "2 Corinthians"
        )
        XCTAssertEqual(
            JSwordBibleNames.localizedLongName(osisId: "3Macc", locale: english),
            "3 Maccabees"
        )
        XCTAssertEqual(
            JSwordBibleNames.localizedLongName(osisId: "Ps151", locale: english),
            "Psalm 151"
        )
    }
}
