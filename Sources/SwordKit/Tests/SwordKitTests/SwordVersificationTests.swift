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
     Verifies SWORD's general mapper converts both directions where compiled tables define it.

     Vulgate and Synodal carry explicit SWORD mappings. LXX has no Psalm-offset resource in either
     JSword or SWORD and therefore stays coordinate-identical for this fixture. Android-only table
     overlays such as SynodalProt are tested at BibleCore's shared mapper boundary.
     */
    func testMapsBetweenNamedVersificationsInBothDirections() {
        XCTAssertEqual(
            SwordVersification.mapVerse(
                osisBookId: "Ps",
                chapter: 11,
                verse: 1,
                sourceVersification: "KJVA",
                targetVersification: "Vulg"
            ),
            .init(osisBookId: "Ps", chapter: 10, verse: 1)
        )
        XCTAssertEqual(
            SwordVersification.mapVerse(
                osisBookId: "Ps",
                chapter: 10,
                verse: 1,
                sourceVersification: "Vulg",
                targetVersification: "KJVA"
            ),
            .init(osisBookId: "Ps", chapter: 11, verse: 1)
        )
        XCTAssertEqual(
            SwordVersification.mapVerse(
                osisBookId: "Ps",
                chapter: 11,
                verse: 1,
                sourceVersification: "KJVA",
                targetVersification: "Synodal"
            ),
            .init(osisBookId: "Ps", chapter: 10, verse: 1)
        )
        XCTAssertEqual(
            SwordVersification.mapVerse(
                osisBookId: "Ps",
                chapter: 11,
                verse: 1,
                sourceVersification: "KJVA",
                targetVersification: "LXX"
            ),
            .init(osisBookId: "Ps", chapter: 11, verse: 1)
        )
    }

    /**
     Verifies canon indexes round-trip real verses and chapter introductions.

     JSword mapping resources contain ranges that include verse 0. These primitives must preserve
     those intro slots exactly while rejecting unknown systems and invalid coordinates. A failure
     would make range expansion shift every mapping after a superscription.
     */
    func testCanonReferenceIndexesRoundTripVerseAndIntroduction() throws {
        let verse = SwordVersification.Reference(osisBookId: "Gen", chapter: 1, verse: 1)
        let verseIndex = try XCTUnwrap(
            SwordVersification.referenceIndex(for: verse, versification: "KJVA")
        )
        XCTAssertEqual(verseIndex, 4)
        XCTAssertEqual(
            SwordVersification.reference(forIndex: verseIndex, versification: "KJVA"),
            verse
        )

        let introduction = SwordVersification.Reference(osisBookId: "Ps", chapter: 51, verse: 0)
        let introductionIndex = try XCTUnwrap(
            SwordVersification.referenceIndex(for: introduction, versification: "KJVA")
        )
        XCTAssertEqual(
            SwordVersification.reference(forIndex: introductionIndex, versification: "KJVA"),
            introduction
        )
        XCTAssertFalse(SwordVersification.supports("NotAVersification"))
        XCTAssertNil(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 1, verse: 99),
                versification: "KJVA"
            )
        )
        XCTAssertNil(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "NotABook", chapter: 1, verse: 1),
                versification: "KJVA"
            ),
            "An unknown OSIS id must fail before native code indexes SWORD's book vector."
        )
    }

    /**
     Verifies convenience APIs retain their public shape without restoring permissive fallbacks.

     The wrappers must delegate to the generalized strict implementation: valid reverse mappings
     and ordinal decoding succeed, while unknown target and source systems fail instead of being
     relabeled as KJV. A failure exposes callers to cross-versification data corruption.
     */
    func testConvenienceWrappersDelegateToStrictVersificationBoundaries() {
        XCTAssertEqual(
            SwordVersification.mapVerseFromKJVA(
                osisBookId: "Ps",
                chapter: 11,
                verse: 1,
                targetVersification: "Vulg"
            ),
            .init(osisBookId: "Ps", chapter: 10, verse: 1)
        )
        XCTAssertNil(
            SwordVersification.mapVerseFromKJVA(
                osisBookId: "Gen",
                chapter: 1,
                verse: 1,
                targetVersification: "NotAVersification"
            )
        )
        XCTAssertEqual(
            SwordVersification.decodeOrdinal(versification: "KJV", ordinal: 4),
            .init(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        XCTAssertNil(
            SwordVersification.decodeOrdinal(versification: "NotAVersification", ordinal: 4)
        )
        XCTAssertTrue(SwordVersification.isVersificationDefined("KJVA"))
        XCTAssertFalse(SwordVersification.isVersificationDefined("NotAVersification"))
    }

    /**
     Verifies invalid targets and coordinates fail without returning source-domain placeholders.

     This is the data-safety boundary for KJVA persistence: an unavailable conversion must be
     explicit so callers cannot stamp a target versification onto unchanged source coordinates.
     The test is deterministic and reads only SWORD's compiled mapping tables.
     */
    func testGeneralMapperRejectsUnknownTargetsAndInvalidCoordinates() {
        XCTAssertNil(
            SwordVersification.mapVerse(
                osisBookId: "Gen",
                chapter: 1,
                verse: 1,
                sourceVersification: "KJV",
                targetVersification: "NotAVersification"
            )
        )
        XCTAssertNil(
            SwordVersification.mapVerse(
                osisBookId: "Gen",
                chapter: 0,
                verse: 1,
                sourceVersification: "KJV",
                targetVersification: "KJVA"
            )
        )
        XCTAssertNil(
            SwordVersification.mapVerse(
                osisBookId: "Gen",
                chapter: 1,
                verse: -1,
                sourceVersification: "KJV",
                targetVersification: "KJVA"
            )
        )
    }

    /**
     Verifies shared canonical references map to KJVA unchanged and invalid inputs fail closed.

     KJV and KJVA share Genesis..Malachi and the New Testament numbering, so a KJV reference maps to
     the identical KJVA reference. An absent source versification defaults to KJV on both platforms;
     an unknown non-empty source, non-positive chapter, or empty book id returns nil. A failure means
     the adapter could relabel unsupported source coordinates into a valid-looking target canon.
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
        XCTAssertNil(
            SwordVersification.mapVerseToKJVA(osisBookId: "Gen", chapter: 1, verse: 1, sourceVersification: "NotAVersification"),
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
     chapter superscription (verse 0). These expectations exercise SWORD's compiled mapping tables;
     BibleCore separately pins Android's JSword resource behavior. A failure means this low-level
     SWORD primitive regressed to dropping chapter superscriptions.
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
     one across a large range because Hebrew/KJVA Psalms 9 and 10 are a single psalm there. These
     expectations pin SWORD's compiled mapper only; BibleCore's `VersificationMapperTests` own exact
     Android/JSword parity. A failure means the native primitive regressed to a name-identity lookup.
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
