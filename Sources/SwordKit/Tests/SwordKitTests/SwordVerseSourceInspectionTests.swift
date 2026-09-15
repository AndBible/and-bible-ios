import XCTest

@testable import SwordKit

/** Verifies the exact cursor identity gate used before a source inspection result is published. */
final class SwordVerseSourceInspectionTests: XCTestCase {
  /**
   Verifies canonical projection distinguishes excluded content from unavailable conversion.

   - Setup: Projects a positive title-only verse with a conflicting stripped fallback, a
     chapter-introduction title, an explicitly canonical title, a non-breaking space, and a missing
     converted source.
   - Expected result: Valid excluded trees never revive stripped headings; both the positive verse
     and unwrapped introduction stay empty because the writer suppresses a separator until content
     is written, canonical=true wins before the title exclusion, NBSP remains content under Java
     whitespace rules, and absent conversion uses the independent fallback.
   - Failure meaning: Memorize text can leak generated chapter headings, discard canonical titles,
     collapse Java-distinct whitespace, or confuse valid empty content with extraction failure.
   - Side effects: Parses bounded copied XML only; no native cursor or module is used.
   */
  func testCanonicalProjectionPreservesValidEmptyOverrideAndFallbackSemantics() {
    let positiveReference = VerseKeyReference(
      osisBookId: "Gen", chapter: 2, verse: 1, ordinal: 41
    )
    let introductionReference = VerseKeyReference(
      osisBookId: "Gen", chapter: 2, verse: 0, ordinal: 40
    )

    XCTAssertEqual(
      SwordBibleCanonicalTextProjection.project([
        .init(
          reference: positiveReference,
          osisFragment: "<title type=\"chapter\">CHAPTER 2.</title>",
          canonicalText: "CHAPTER 2."
        ),
      ]),
      ""
    )
    XCTAssertEqual(
      SwordBibleCanonicalTextProjection.project([
        .init(
          reference: introductionReference,
          osisFragment: "<title type=\"chapter\">CHAPTER 2.</title>",
          canonicalText: "CHAPTER 2."
        ),
      ]),
      ""
    )
    XCTAssertEqual(
      SwordBibleCanonicalTextProjection.project([
        .init(
          reference: introductionReference,
          osisFragment: "<title canonical=\"true\">Superscription</title>",
          canonicalText: "fallback"
        ),
      ]),
      "Superscription"
    )
    XCTAssertEqual(
      SwordBibleCanonicalTextProjection.project([
        .init(
          reference: introductionReference,
          osisFragment: "&#160;",
          canonicalText: "fallback"
        ),
      ]),
      "\u{00A0}"
    )
    XCTAssertEqual(
      SwordBibleCanonicalTextProjection.project([
        .init(
          reference: positiveReference,
          osisFragment: nil,
          canonicalText: "fallback"
        ),
      ]),
      "fallback "
    )
  }

  /**
   Verifies restoration requires both the original key text and VerseKey index.

   - Setup: Captures one cursor identity and evaluates exact, key-only, and index-only restorations.
   - Expected result: Only the exact composite identity succeeds.
   - Failure meaning: `inspectVerseSourceRangeRestoringPrevious` could publish content after SWORD
     restored a neighboring verse or a differently typed key with matching display text.
   - Side effects: None; this tests the value predicate used by the native restoration boundary.
   */
  func testCursorRestorationRejectsKeyOrVerseIndexDrift() {
    let snapshot = SwordModuleCursorSnapshot(keyText: "Genesis 1:5", verseIndex: 11)

    XCTAssertTrue(snapshot.matches(restoredKeyText: "Genesis 1:5", restoredVerseIndex: 11))
    XCTAssertFalse(snapshot.matches(restoredKeyText: "Genesis 1:6", restoredVerseIndex: 11))
    XCTAssertFalse(snapshot.matches(restoredKeyText: "Genesis 1:5", restoredVerseIndex: 12))
    XCTAssertFalse(snapshot.matches(restoredKeyText: "Genesis 1:5", restoredVerseIndex: nil))
  }
}
