import XCTest
@testable import BibleUI
@testable import SwordKit

/** Contract tests for Android-compatible commentary conversion plus exact addressability. */
final class CommentaryVersificationFallbackTests: XCTestCase {
    /**
     Verifies Android's public fallback reaches the exact destination lookup once.

     Synodal Daniel 3:34 has no authoritative KJVA mapping. Android retains the coordinate for
     ephemeral commentary lookup, so an exact KJVA owner can accept it without any neighboring-key
     search.

     - Side effects: Reads pinned versification data and records one in-memory lookup.
     - Failure modes: Fails if commentary becomes stricter than Android, skips exact addressability,
       or changes the fallback coordinate.
     */
    func testPublicFallbackSucceedsOnlyThroughExactDestinationLookup() throws {
        let source = SwordVersification.Reference(
            osisBookId: "Dan",
            chapter: 3,
            verse: 34
        )
        var lookedUp: [SwordVersification.Reference] = []

        let result: String? = BibleReaderCommentaryVersificationRouter.resolve(
            reference: source,
            from: "Synodal",
            to: "KJVA"
        ) { candidate in
            lookedUp.append(candidate)
            return candidate == source ? "Dan.3.34" : nil
        }

        XCTAssertEqual(result, "Dan.3.34")
        XCTAssertEqual(lookedUp, [source])
    }

    /**
     Verifies an unaddressable public fallback is rejected without a nearby substitute.

     - Side effects: Reads pinned versification data and records one in-memory lookup.
     - Failure modes: Fails if a fallback bypasses destination ownership or triggers multiple
       candidate probes.
     */
    func testPublicFallbackFailsClosedWhenDestinationRejectsExactCoordinate() {
        let source = SwordVersification.Reference(
            osisBookId: "Dan",
            chapter: 3,
            verse: 34
        )
        var lookupCount = 0

        let result: SwordVersification.Reference? =
            BibleReaderCommentaryVersificationRouter.resolve(
                reference: source,
                from: "Synodal",
                to: "KJVA"
            ) { _ in
                lookupCount += 1
                return nil
            }

        XCTAssertNil(result)
        XCTAssertEqual(lookupCount, 1)
    }

    /**
     Verifies authoritative cross-versification mappings also require exact destination ownership.

     Vulgate Psalm 10:1 maps to the KJVA Psalm 11 superscription. This protects next/previous
     commentary navigation from relabeling the source coordinate or bypassing active-Bible lookup.

     - Side effects: Reads pinned versification data and records one in-memory lookup.
     - Failure modes: Fails if the mapped coordinate changes or exact addressability is skipped.
     */
    func testMappedCommentaryNavigationRetainsConvertedCoordinate() {
        let expected = SwordVersification.Reference(
            osisBookId: "Ps",
            chapter: 11,
            verse: 0
        )
        var lookedUp: SwordVersification.Reference?

        let result: SwordVersification.Reference? =
            BibleReaderCommentaryVersificationRouter.resolve(
                reference: .init(osisBookId: "Ps", chapter: 10, verse: 1),
                from: "Vulg",
                to: "KJVA"
            ) { candidate in
                lookedUp = candidate
                return candidate
            }

        XCTAssertEqual(lookedUp, expected)
        XCTAssertEqual(result, expected)
    }
}
