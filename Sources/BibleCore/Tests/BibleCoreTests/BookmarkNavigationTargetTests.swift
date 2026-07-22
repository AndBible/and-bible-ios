import XCTest
@testable import BibleCore

/** Exact persisted bookmark target validation tests independent of reader-side planning. */
final class BookmarkNavigationTargetTests: XCTestCase {
    /**
     Verifies Android's first local BVA anchor remains a valid explicit generic bookmark position.

     The fixture supplies a start ordinal of zero with no end, matching a single-anchor selection.
     Failure means persisted selections at the beginning of SWORD, EPUB, or My Documents fragments
     become unnavigable even though zero is addressable in the fragment-local ordinal domain.
     */
    func testGenericBookmarkAcceptsExplicitZeroStartAsSingleAnchorRange() throws {
        let bookmark = GenericBookmark(
            key: "entry",
            bookInitials: "Dictionary",
            ordinalStart: 0,
            ordinalEnd: nil
        )

        guard case .generic(let target) = try BookmarkNavigationTargetResolver.resolve(bookmark) else {
            return XCTFail("Expected a generic navigation target")
        }
        XCTAssertEqual(target.ordinalRange, 0...0)
    }

    /**
     Verifies a generic range beginning at BVA zero remains ordered and unchanged.

     Failure means the resolver applies Bible's positive-ordinal rule to a generic fragment-local
     range or shifts the persisted selection before the reader can validate fragment containment.
     */
    func testGenericBookmarkAcceptsOrderedRangeBeginningAtZero() throws {
        let bookmark = GenericBookmark(
            key: "entry",
            bookInitials: "Dictionary",
            ordinalStart: 0,
            ordinalEnd: 2
        )

        guard case .generic(let target) = try BookmarkNavigationTargetResolver.resolve(bookmark) else {
            return XCTFail("Expected a generic navigation target")
        }
        XCTAssertEqual(target.ordinalRange, 0...2)
    }

    /**
     Verifies negative, reversed, and end-only generic coordinates still fail closed.

     Each malformed row is resolved independently and must retain its exact persisted endpoints in
     the typed failure. A regression would let the zero fix admit negative or incomplete ranges.
     */
    func testGenericBookmarkRejectsNegativeReversedAndEndOnlyRanges() {
        let cases: [(Int?, Int?)] = [(-1, -1), (2, 1), (nil, 0)]

        for (start, end) in cases {
            let bookmark = GenericBookmark(
                key: "entry",
                bookInitials: "Dictionary",
                ordinalStart: start,
                ordinalEnd: end
            )
            XCTAssertThrowsError(try BookmarkNavigationTargetResolver.resolve(bookmark)) { error in
                XCTAssertEqual(
                    error as? BookmarkNavigationTargetError,
                    .invalidGenericOrdinals(start: start, end: end)
                )
            }
        }
    }
}
