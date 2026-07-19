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
     Verifies KJVA references map back into divergent canons — the reverse of `mapVerseToKJVA`.

     Android renders, displays, and navigates a stored KJVA bookmark in the active module's
     versification via `Verse.toV11n(activeV11n)`. The engine must produce the true active-canon
     verse rather than the identically-numbered KJVA verse: KJVA Ps 11:1 is Vulgate Ps 10:1, and the
     Synodal superscription round-trips (KJVA Ps 51:0 -> Synodal Ps 50:1). An empty target defaults
     to KJV; a present-but-unrecognized target returns nil. Values captured from SWORD's tables.
     */
    func testMapsKJVAReferencesBackIntoDivergentCanons() {
        XCTAssertEqual(
            SwordVersification.mapVerseFromKJVA(osisBookId: "Ps", chapter: 11, verse: 1, targetVersification: "Vulg"),
            .init(osisBookId: "Ps", chapter: 10, verse: 1),
            "KJVA Psalm 11:1 is Vulgate Psalm 10:1."
        )
        XCTAssertEqual(
            SwordVersification.mapVerseFromKJVA(osisBookId: "Ps", chapter: 10, verse: 1, targetVersification: "Vulg"),
            .init(osisBookId: "Ps", chapter: 9, verse: 22),
            "KJVA Psalm 10:1 is Vulgate Psalm 9:22."
        )
        XCTAssertEqual(
            SwordVersification.mapVerseFromKJVA(osisBookId: "Ps", chapter: 51, verse: 0, targetVersification: "Synodal"),
            .init(osisBookId: "Ps", chapter: 50, verse: 1),
            "The KJVA Psalm 51 superscription round-trips to Synodal Psalm 50:1."
        )
        // Shared-canon identity, empty -> KJV, and unrecognized -> nil.
        XCTAssertEqual(
            SwordVersification.mapVerseFromKJVA(osisBookId: "Gen", chapter: 1, verse: 1, targetVersification: "KJV"),
            .init(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        XCTAssertEqual(
            SwordVersification.mapVerseFromKJVA(osisBookId: "Gen", chapter: 1, verse: 1, targetVersification: ""),
            .init(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        XCTAssertNil(
            SwordVersification.mapVerseFromKJVA(osisBookId: "Gen", chapter: 1, verse: 1, targetVersification: "NotAVersification")
        )
    }

    /**
     Verifies module-independent ordinal decoding — the iOS analogue of Android's `Verse(v11n, ord)`.

     A restored bookmark's original source ordinal must resolve from versification metadata alone,
     without the producing module installed. SWORD's intro-inclusive `VerseKey` index matches the
     JSword ordinal scheme (index 4 is Genesis 1:1). An empty name defaults to KJV; a present-but-
     unrecognized name and a non-positive ordinal return nil.
     */
    func testDecodesOrdinalsFromVersificationMetadataWithoutAModule() {
        XCTAssertEqual(
            SwordVersification.decodeOrdinal(versification: "KJV", ordinal: 4),
            .init(osisBookId: "Gen", chapter: 1, verse: 1),
            "Intro-inclusive index 4 is Genesis 1:1, matching the JSword ordinal scheme."
        )
        XCTAssertEqual(
            SwordVersification.decodeOrdinal(versification: "", ordinal: 4),
            .init(osisBookId: "Gen", chapter: 1, verse: 1),
            "An empty versification name defaults to KJV."
        )
        XCTAssertNil(SwordVersification.decodeOrdinal(versification: "KJV", ordinal: 0))
        XCTAssertNil(SwordVersification.decodeOrdinal(versification: "NotAVersification", ordinal: 4))
    }

    /**
     Verifies shared canonical references map to KJVA unchanged and defaults/invalid inputs behave.

     KJV and KJVA share Genesis..Malachi and the New Testament numbering, so a KJV reference maps to
     the identical KJVA reference; an empty source versification defaults to KJV; a versification
     name SWORD does not recognize returns nil (matching Android, which rejects an unsupported module
     versification during metadata load, and the flat-API contract); non-positive inputs and empty
     book ids return nil. A failure means the adapter is not wired to SWORD's VersificationMgr or
     mis-handles defaults.
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
        // A versification name SWORD does not recognize returns nil, matching Android's rejection of
        // an unsupported module versification and the flat-API contract; only an empty name defaults
        // to KJV.
        XCTAssertNil(
            SwordVersification.mapVerseToKJVA(osisBookId: "Gen", chapter: 1, verse: 1, sourceVersification: "NotAVersification")
        )
        XCTAssertNil(
            SwordVersification.mapVerseToKJVA(osisBookId: "Gen", chapter: 0, verse: 1, sourceVersification: "KJV")
        )
        XCTAssertNil(
            SwordVersification.mapVerseToKJVA(osisBookId: "", chapter: 1, verse: 1, sourceVersification: "KJV")
        )
    }

    /**
     Verifies divergent-canon Psalm-title verses map to KJVA chapter superscriptions (verse 0).

     The Septuagint/Synodal numbering carries a separate Psalm-title verse that KJVA folds into the
     chapter superscription (verse 0). JSword represents that superscription as a real, positive
     KJVA ordinal, so the engine must return verse 0 rather than nil — otherwise the caller stores a
     raw source ordinal in the KJVA columns (the issue #356 write-side defect). These expectations
     were captured directly from SWORD's mapping tables and match JSword's `Synodal.properties`
     (`Ps.50.1=Ps.51.0`). A failure means verse-0 superscriptions regressed back to nil.
     */
    func testMapsDivergentCanonSuperscriptionsToKJVAVerseZero() {
        XCTAssertEqual(
            SwordVersification.mapVerseToKJVA(osisBookId: "Ps", chapter: 50, verse: 1, sourceVersification: "Synodal"),
            .init(osisBookId: "Ps", chapter: 51, verse: 0),
            "Synodal Psalm 50:1 (title) maps to the KJVA Psalm 51 superscription (verse 0)."
        )
        XCTAssertEqual(
            SwordVersification.mapVerseToKJVA(osisBookId: "Ps", chapter: 50, verse: 2, sourceVersification: "Synodal"),
            .init(osisBookId: "Ps", chapter: 51, verse: 0),
            "Synodal Psalm 50:2 also maps to the KJVA Psalm 51 superscription."
        )
        XCTAssertEqual(
            SwordVersification.mapVerseToKJVA(osisBookId: "Ps", chapter: 3, verse: 1, sourceVersification: "Synodal"),
            .init(osisBookId: "Ps", chapter: 3, verse: 0),
            "Synodal Psalm 3:1 (title) maps to the KJVA Psalm 3 superscription (verse 0)."
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
