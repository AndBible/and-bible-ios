import XCTest
@testable import SwordKit

/**
 Contract tests for SWORD-backed cross-versification mapping into KJVA.

 These exercise the CLibSword adapter's `SWVersification_mapVerseToKJVA` end to end through the
 `SwordVersification` Swift wrapper, so they require the real libsword framework. Mapping uses
 SWORD's compiled versification tables and needs no installed modules.
 */
final class SwordVersificationTests: XCTestCase {
    /**
     Verifies shared canonical references map to KJVA unchanged and defaults/invalid inputs behave.

     KJV and KJVA share Genesis..Malachi and the New Testament numbering, so a KJV reference maps to
     the identical KJVA reference; an empty source versification defaults to KJV; a versification
     name SWORD does not recognize also falls back to KJV (mirroring SWORD's own module loading, so
     the caller never persists a raw source ordinal into the KJVA columns); non-positive inputs and
     empty book ids return nil. A failure means the adapter is not wired to SWORD's VersificationMgr
     or mis-handles defaults.
     */
    func testMapsSharedCanonAndDefaultsAndInvalidInputs() {
        XCTAssertEqual(
            SwordVersification.mapVerseToKJVA(osisBookId: "Gen", chapter: 1, verse: 1, sourceVersification: "KJV"),
            .init(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        XCTAssertEqual(
            SwordVersification.mapVerseToKJVA(osisBookId: "John", chapter: 3, verse: 16, sourceVersification: "KJV"),
            .init(osisBookId: "John", chapter: 3, verse: 16)
        )
        // Empty source versification defaults to KJV.
        XCTAssertEqual(
            SwordVersification.mapVerseToKJVA(osisBookId: "Gen", chapter: 1, verse: 1, sourceVersification: ""),
            .init(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        // A versification name SWORD does not recognize falls back to KJV rather than failing, so
        // shared-canon references still resolve to their identical KJVA reference instead of nil
        // (which would let callers store a raw source ordinal in the KJVA columns).
        XCTAssertEqual(
            SwordVersification.mapVerseToKJVA(osisBookId: "Gen", chapter: 1, verse: 1, sourceVersification: "NotAVersification"),
            .init(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        XCTAssertNil(
            SwordVersification.mapVerseToKJVA(osisBookId: "Gen", chapter: 0, verse: 1, sourceVersification: "KJV")
        )
        XCTAssertNil(
            SwordVersification.mapVerseToKJVA(osisBookId: "", chapter: 1, verse: 1, sourceVersification: "KJV")
        )
    }

    /**
     Verifies genuine non-identity mapping for versification-divergent canons.

     The Vulgate and Russian Synodal versifications number the Psalms per the Septuagint, offset by
     one across a large range because Hebrew/KJVA Psalms 9 and 10 are a single psalm there. SWORD's
     VersificationMgr remaps these verse-by-verse (the exact behavior Android's JSword `toV11n(KJVA)`
     produces), so the engine must translate them onto their true KJVA counterparts rather than
     re-interpreting the same numbers. These expectations were captured directly from SWORD's
     compiled mapping tables. A failure means the mapping regressed to a name-identity lookup — the
     issue #356 defect on the write side.
     */
    func testMapsDivergentCanonPsalmsToKJVA() {
        // Vulgate follows the Septuagint Psalm numbering.
        XCTAssertEqual(
            SwordVersification.mapVerseToKJVA(osisBookId: "Ps", chapter: 10, verse: 1, sourceVersification: "Vulg"),
            .init(osisBookId: "Ps", chapter: 11, verse: 1),
            "Vulgate Psalm 10 maps to KJVA Psalm 11."
        )
        XCTAssertEqual(
            SwordVersification.mapVerseToKJVA(osisBookId: "Ps", chapter: 9, verse: 22, sourceVersification: "Vulg"),
            .init(osisBookId: "Ps", chapter: 10, verse: 1),
            "Vulgate Psalm 9:22 (past the KJVA Psalm 9 boundary) maps into KJVA Psalm 10."
        )
        XCTAssertEqual(
            SwordVersification.mapVerseToKJVA(osisBookId: "Ps", chapter: 147, verse: 1, sourceVersification: "Vulg"),
            .init(osisBookId: "Ps", chapter: 147, verse: 12),
            "Vulgate Psalm 147:1 maps to KJVA Psalm 147:12."
        )
        // Russian Synodal shares the Septuagint Psalm numbering.
        XCTAssertEqual(
            SwordVersification.mapVerseToKJVA(osisBookId: "Ps", chapter: 9, verse: 22, sourceVersification: "Synodal"),
            .init(osisBookId: "Ps", chapter: 10, verse: 1),
            "Synodal Psalm 9:22 maps into KJVA Psalm 10."
        )
        XCTAssertEqual(
            SwordVersification.mapVerseToKJVA(osisBookId: "Ps", chapter: 147, verse: 1, sourceVersification: "Synodal"),
            .init(osisBookId: "Ps", chapter: 147, verse: 12),
            "Synodal Psalm 147:1 maps to KJVA Psalm 147:12."
        )
    }
}
