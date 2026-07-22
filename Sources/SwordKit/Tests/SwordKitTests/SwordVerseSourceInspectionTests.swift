import XCTest

@testable import SwordKit

/** Verifies the exact cursor identity gate used before a source inspection result is published. */
final class SwordVerseSourceInspectionTests: XCTestCase {
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
