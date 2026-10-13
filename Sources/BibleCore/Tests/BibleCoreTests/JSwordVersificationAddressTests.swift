import XCTest
@testable import BibleCore

/**
 Contract tests for public source-versification coordinate validation.

 The cases use exact dimensions from the pinned Android JSword canon fixture. They exercise only
 immutable package resources and process-local lazy caches.
 */
final class JSwordVersificationAddressTests: XCTestCase {
    /// Accepts verse zero as an explicit introduction coordinate, including chapter zero.
    func testAcceptsExplicitIntroductionCoordinates() {
        XCTAssertTrue(
            JSwordVersificationAddress.isValid(
                osisBookID: "Gen",
                chapter: 0,
                verse: 0,
                versification: "KJV"
            )
        )
        XCTAssertTrue(
            JSwordVersificationAddress.isValid(
                osisBookID: "Gen",
                chapter: 1,
                verse: 0,
                versification: "KJV"
            )
        )
    }

    /// Validates a Vulgate-only Esther chapter without requiring a KJVA mapping.
    func testAcceptsCoordinateUniqueToSourceVersification() {
        XCTAssertTrue(
            JSwordVersificationAddress.isValid(
                osisBookID: "Esth",
                chapter: 16,
                verse: 24,
                versification: "Vulg"
            )
        )
        XCTAssertFalse(
            JSwordVersificationAddress.isValid(
                osisBookID: "Esth",
                chapter: 16,
                verse: 24,
                versification: "KJVA"
            )
        )
    }

    /// Rejects chapters and verses outside the exact source-versification dimensions.
    func testRejectsOutOfRangeCoordinates() {
        XCTAssertFalse(
            JSwordVersificationAddress.isValid(
                osisBookID: "Esth",
                chapter: 119,
                verse: 1,
                versification: "KJVA"
            )
        )
        XCTAssertFalse(
            JSwordVersificationAddress.isValid(
                osisBookID: "Gen",
                chapter: 1,
                verse: 32,
                versification: "KJV"
            )
        )
        XCTAssertFalse(
            JSwordVersificationAddress.isValid(
                osisBookID: "Gen",
                chapter: -1,
                verse: 0,
                versification: "KJV"
            )
        )
        XCTAssertFalse(
            JSwordVersificationAddress.isValid(
                osisBookID: "Gen",
                chapter: 1,
                verse: -1,
                versification: "KJV"
            )
        )
    }

    /// Unknown source identities fail closed instead of falling back to a different canon.
    func testRejectsUnknownVersificationAndBook() {
        XCTAssertFalse(
            JSwordVersificationAddress.isValid(
                osisBookID: "Gen",
                chapter: 1,
                verse: 1,
                versification: "Unknown"
            )
        )
        XCTAssertFalse(
            JSwordVersificationAddress.isValid(
                osisBookID: "Unknown",
                chapter: 1,
                verse: 1,
                versification: "KJV"
            )
        )
    }
}
