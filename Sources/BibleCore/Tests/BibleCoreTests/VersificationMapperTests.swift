import XCTest
import SwordKit
@testable import BibleCore

/**
 Contract tests for the shared Android-compatible versification conversion boundary.

 Fixtures exercise Android's pinned JSword mapping resources together with iOS's source-derived
 JSword KJVA ordinal table. Tests perform no persistence or network work and are deterministic
 across module installations.
 */
final class VersificationMapperTests: XCTestCase {
    /**
     Verifies divergent source coordinates become the exact JSword KJVA storage ordinal.

     Synodal Psalm 50:1 maps to the KJVA Psalm 51 superscription, while Vulgate Psalm 10:1 maps to
     the KJVA Psalm 11 superscription. A failure means the shared boundary reverted to coordinate
     identity or lost Android's chapter-introduction ordinal semantics.
     */
    func testProjectsDivergentReferencesIntoKJVAOrdinals() throws {
        let synodalTitle = VerseKeyReference(
            osisBookId: "Ps",
            chapter: 50,
            verse: 1,
            ordinal: 1
        )
        XCTAssertEqual(
            VersificationMapper.kjvaOrdinal(
                for: synodalTitle,
                sourceVersification: "Synodal"
            ),
            JSwordKJVAVersification.chapterIntroOrdinal(osisId: "Ps", chapter: 51)
        )

        let vulgateVerse = VerseKeyReference(
            osisBookId: "Ps",
            chapter: 10,
            verse: 1,
            ordinal: 1
        )
        XCTAssertEqual(
            VersificationMapper.kjvaOrdinal(
                for: vulgateVerse,
                sourceVersification: "Vulg"
            ),
            JSwordKJVAVersification.chapterIntroOrdinal(osisId: "Ps", chapter: 11)
        )
    }

    /**
     Verifies KJVA-backed data converts into a divergent rendered versification.

     Android converts memorization, progress, and bookmark KJVA ordinals into the active module's
     versification before emitting reader payloads. A failure means iOS would send KJVA coordinates
     to a Vulgate document or relabel them without conversion.
     */
    func testConvertsKJVAOrdinalToTargetReference() throws {
        let kjvaOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Ps", chapter: 11, verse: 1)
        )
        XCTAssertEqual(
            VersificationMapper.reference(
                forKJVAOrdinal: kjvaOrdinal,
                targetVersification: "Vulg"
            ),
            .init(osisBookId: "Ps", chapter: 10, verse: 2)
        )
    }

    /**
     Verifies KJVA chapter-introduction ordinals round-trip through divergent versifications.

     Android memorization events enumerate every ordinal in a stored KJVA range and construct a
     `Verse(KJVA, ordinal)` before converting it to the visible document. Vulgate Psalm 10:1 maps
     to the KJVA Psalm 11 superscription, so the reverse path must preserve verse `0` rather than
     dropping the event as a non-verse gap.

     Failure means:
     - a valid Android memorization target can persist but never highlight in the source module
     - chapter-title bookmark projections can lose their active-module ordinal
     */
    func testConvertsKJVAChapterIntroductionToDivergentTarget() throws {
        let psalmElevenIntroduction = try XCTUnwrap(
            JSwordKJVAVersification.chapterIntroOrdinal(osisId: "Ps", chapter: 11)
        )
        XCTAssertEqual(
            JSwordKJVAVersification.referenceIncludingIntroductions(
                ordinal: psalmElevenIntroduction
            ),
            .init(
                osisId: "Ps",
                chapter: 11,
                verse: 0,
                ordinal: psalmElevenIntroduction
            )
        )
        XCTAssertEqual(
            VersificationMapper.reference(
                forKJVAOrdinal: psalmElevenIntroduction,
                targetVersification: "Vulg"
            ),
            .init(osisBookId: "Ps", chapter: 10, verse: 1)
        )
    }

    /**
     Verifies Android's SynodalProt resource closes libsword's missing-table gap in both directions.

     The Android fixture defines SynodalProt Psalm 13:2 as KJVA Psalm 14:2. libsword ships the
     SynodalProt canon dimensions without this mapping table, so this test proves the shared mapper
     is using JSword's resource rather than silently accepting SWORD coordinate identity.
     */
    func testUsesJSwordSynodalProtMappingInBothDirections() {
        XCTAssertEqual(
            VersificationMapper.convert(
                osisBookId: "Ps",
                chapter: 13,
                verse: 2,
                from: "SynodalProt",
                to: "KJVA"
            )?.reference,
            .init(osisBookId: "Ps", chapter: 14, verse: 2)
        )
        XCTAssertEqual(
            VersificationMapper.convert(
                osisBookId: "Ps",
                chapter: 14,
                verse: 2,
                from: "KJVA",
                to: "SynodalProt"
            )?.reference,
            .init(osisBookId: "Ps", chapter: 13, verse: 2)
        )
    }

    /**
     Verifies verse-part qualifiers survive the KJVA intermediate between divergent canons.

     Synodal and Vulgate both split the KJVA Psalm 51 superscription into two source verses. Without
     JSword's `!a`/`!b` qualifier contract, Synodal Psalm 50:2 would collapse onto Vulgate Psalm
     50:1. The test pins Android's exact second-part mapping.
     */
    func testPreservesQualifiedVersePartsAcrossNonKJVCanons() {
        XCTAssertEqual(
            VersificationMapper.convert(
                osisBookId: "Ps",
                chapter: 50,
                verse: 2,
                from: "Synodal",
                to: "Vulg"
            )?.reference,
            .init(osisBookId: "Ps", chapter: 50, verse: 2)
        )
    }

    /**
     Verifies named sections absent from KJVA still bridge two non-KJVA systems.

     Android's pinned Catholic resources assign the same `BelThenKingSaid` section name to Daniel
     14:43. The section has no concrete KJVA verse, but JSword carries the named key through the
     intermediate so Catholic and Catholic2 can convert it in both directions.
     */
    func testCarriesNamedAbsentSectionsAcrossNonKJVCanons() {
        XCTAssertEqual(
            VersificationMapper.convert(
                osisBookId: "Dan",
                chapter: 14,
                verse: 43,
                from: "Catholic",
                to: "Catholic2"
            )?.reference,
            .init(osisBookId: "Dan", chapter: 14, verse: 43)
        )
        XCTAssertEqual(
            VersificationMapper.convert(
                osisBookId: "Dan",
                chapter: 14,
                verse: 43,
                from: "Catholic2",
                to: "Catholic"
            )?.reference,
            .init(osisBookId: "Dan", chapter: 14, verse: 43)
        )
    }

    /**
     Verifies JSword preserves a one-to-many intermediate range until target unmapping.

     Vulgate Psalm 12:1 maps to the whole KJVA Psalm 13:0-1 range. JSword coordinate-casts that
     range into Synodal and chooses Psalm 13:0 as the first result; flattening the intermediate and
     applying Synodal's per-verse mappings would incorrectly return Psalm 12:1.
     */
    func testPreservesOneToManyIntermediateRangeShape() {
        XCTAssertEqual(
            VersificationMapper.convert(
                osisBookId: "Ps",
                chapter: 12,
                verse: 1,
                from: "Vulg",
                to: "Synodal"
            )?.reference,
            .init(osisBookId: "Ps", chapter: 13, verse: 0)
        )
    }

    /**
     Verifies qualifiers attached to a multi-verse resource range do not survive expansion.

     JSword documents range parts as unsupported and expands `getWhole()`. With the pinned MT and
     Synodal resources, 1 Kings 18:34 must therefore resolve to Synodal 1 Kings 18:33 rather than
     taking a qualified exact lookup that returns verse 34.
     */
    func testStripsQualifiersFromExpandedMappingRanges() {
        XCTAssertEqual(
            VersificationMapper.convert(
                osisBookId: "1Kgs",
                chapter: 18,
                verse: 34,
                from: "MT",
                to: "Synodal"
            )?.reference,
            .init(osisBookId: "1Kgs", chapter: 18, verse: 33)
        )
    }

    /**
     Verifies Android's public fallback is visible without becoming persistence-authoritative.

     Synodal Daniel 3:34 belongs to a named section with no KJVA equivalent, so JSword's strict
     converter is empty and its public converter retains the same coordinate. JSword also permits
     direct construction of coordinates absent from a source canon and preserves them as fallback.
     Unknown systems and unknown OSIS book identifiers still fail.
     */
    func testClassifiesPublicFallbackAndRejectsItForStrictPersistence() throws {
        let fallback = try XCTUnwrap(
            VersificationMapper.convert(
                osisBookId: "Dan",
                chapter: 3,
                verse: 34,
                from: "Synodal",
                to: "KJVA"
            )
        )
        XCTAssertEqual(fallback.reference, .init(osisBookId: "Dan", chapter: 3, verse: 34))
        XCTAssertEqual(fallback.fidelity, .fallback)
        XCTAssertFalse(fallback.isAuthoritative)
        XCTAssertNil(
            VersificationMapper.convertStrictly(
                osisBookId: "Dan",
                chapter: 3,
                verse: 34,
                from: "Synodal",
                to: "KJVA"
            )
        )
        XCTAssertNil(
            VersificationMapper.convert(
                osisBookId: "Gen",
                chapter: 1,
                verse: 1,
                from: "UnknownVersification",
                to: "KJVA"
            )
        )
        let rawVerseFallback = try XCTUnwrap(
            VersificationMapper.convert(
                osisBookId: "Jude",
                chapter: 1,
                verse: 26,
                from: "NRSV",
                to: "KJVA"
            )
        )
        XCTAssertEqual(rawVerseFallback.reference, .init(osisBookId: "Jude", chapter: 1, verse: 26))
        XCTAssertEqual(rawVerseFallback.fidelity, .fallback)
        XCTAssertFalse(rawVerseFallback.isAuthoritative)
        XCTAssertNil(
            VersificationMapper.convertStrictly(
                osisBookId: "Jude",
                chapter: 1,
                verse: 26,
                from: "NRSV",
                to: "KJVA"
            )
        )
        let rawChapterFallback = try XCTUnwrap(
            VersificationMapper.convert(
                osisBookId: "Jude",
                chapter: 2,
                verse: 1,
                from: "NRSV",
                to: "KJVA"
            )
        )
        XCTAssertEqual(rawChapterFallback.reference, .init(osisBookId: "Jude", chapter: 2, verse: 1))
        XCTAssertEqual(rawChapterFallback.fidelity, .fallback)
        XCTAssertFalse(rawChapterFallback.isAuthoritative)
        XCTAssertNil(
            VersificationMapper.convert(
                osisBookId: "NotABook",
                chapter: 1,
                verse: 1,
                from: "NRSV",
                to: "KJVA"
            )
        )
    }

    /**
     Verifies the selected cross-canon matrix against Android's pinned JSword converter.

     The expected references and strict/fallback classifications were generated by constructing
     `Verse` values with JSword revision `0da7412d7716731f402c9002a0b92e4c00ef30eb`, then calling
     `VersificationConverter.isConvertibleTo` and `convert`. These cases cover explicit maps,
     coordinate identity, named sections, additions, and Android's public fallback.

     Failure means the Swift parser, canon fixture, intermediate mapping shape, or fallback policy
     has diverged from the Android dependency that owns the persisted-reference contract.
     */
    func testMatchesPinnedAndroidJSwordOracleMatrix() {
        typealias Fixture = (
            source: String,
            reference: SwordVersification.Reference,
            target: String,
            expected: SwordVersification.Reference,
            fidelity: VersificationMapper.Fidelity
        )
        let fixtures: [Fixture] = [
            ("Vulg", .init(osisBookId: "Ps", chapter: 10, verse: 1), "KJVA", .init(osisBookId: "Ps", chapter: 11, verse: 0), .mapped),
            ("Vulg", .init(osisBookId: "Ps", chapter: 12, verse: 1), "Synodal", .init(osisBookId: "Ps", chapter: 13, verse: 0), .mapped),
            ("MT", .init(osisBookId: "1Kgs", chapter: 18, verse: 34), "Synodal", .init(osisBookId: "1Kgs", chapter: 18, verse: 33), .mapped),
            ("Synodal", .init(osisBookId: "Dan", chapter: 3, verse: 34), "KJVA", .init(osisBookId: "Dan", chapter: 3, verse: 34), .fallback),
            ("Catholic", .init(osisBookId: "Dan", chapter: 14, verse: 42), "KJVA", .init(osisBookId: "Bel", chapter: 1, verse: 42), .mapped),
            ("Catholic", .init(osisBookId: "Dan", chapter: 14, verse: 43), "KJVA", .init(osisBookId: "Dan", chapter: 14, verse: 43), .fallback),
            ("Catholic2", .init(osisBookId: "Esth", chapter: 15, verse: 1), "KJVA", .init(osisBookId: "Esth", chapter: 15, verse: 1), .fallback),
            ("Catholic2", .init(osisBookId: "Esth", chapter: 15, verse: 4), "KJVA", .init(osisBookId: "AddEsth", chapter: 15, verse: 1), .mapped),
            ("Catholic2", .init(osisBookId: "Tob", chapter: 7, verse: 10), "KJVA", .init(osisBookId: "Tob", chapter: 7, verse: 9), .mapped),
            ("NRSV", .init(osisBookId: "Jude", chapter: 1, verse: 25), "KJVA", .init(osisBookId: "Jude", chapter: 1, verse: 25), .identity),
            ("NRSV", .init(osisBookId: "Jude", chapter: 1, verse: 26), "KJVA", .init(osisBookId: "Jude", chapter: 1, verse: 26), .fallback),
            ("KJVA", .init(osisBookId: "AddEsth", chapter: 15, verse: 1), "Catholic2", .init(osisBookId: "Esth", chapter: 15, verse: 4), .mapped),
            ("Catholic", .init(osisBookId: "Dan", chapter: 14, verse: 43), "Catholic2", .init(osisBookId: "Dan", chapter: 14, verse: 43), .mapped),
            ("Catholic2", .init(osisBookId: "Dan", chapter: 14, verse: 43), "Catholic", .init(osisBookId: "Dan", chapter: 14, verse: 43), .mapped),
            ("Catholic", .init(osisBookId: "Gen", chapter: 32, verse: 1), "KJVA", .init(osisBookId: "Gen", chapter: 31, verse: 55), .mapped),
            ("Segond", .init(osisBookId: "Exod", chapter: 7, verse: 26), "KJVA", .init(osisBookId: "Exod", chapter: 8, verse: 1), .mapped),
        ]

        for fixture in fixtures {
            let conversion = VersificationMapper.convert(
                osisBookId: fixture.reference.osisBookId,
                chapter: fixture.reference.chapter,
                verse: fixture.reference.verse,
                from: fixture.source,
                to: fixture.target
            )
            XCTAssertEqual(conversion?.reference, fixture.expected, "\(fixture.source) -> \(fixture.target)")
            XCTAssertEqual(conversion?.fidelity, fixture.fidelity, "\(fixture.source) -> \(fixture.target)")
        }
    }

    /**
     Verifies every JSword mapping resource bundled by Android parses and overrides identity.

     The matrix selects one explicit non-identity rule from each resource. This catches resource
     packaging omissions, parser drift, and canon-dimension mismatches that narrower Psalm tests
     would miss. The fixtures are copied directly from Android's pinned JSword revision.
     */
    func testLoadsEveryBundledAndroidMappingResource() {
        let genesisShiftSystems = ["Catholic", "Catholic2", "German", "Leningrad", "Luther", "MT"]
        for versification in genesisShiftSystems {
            XCTAssertEqual(
                VersificationMapper.convert(
                    osisBookId: "Gen",
                    chapter: 32,
                    verse: 1,
                    from: versification,
                    to: "KJVA"
                )?.reference,
                .init(osisBookId: "Gen", chapter: 31, verse: 55),
                versification
            )
        }

        for versification in ["NRSV", "NRSVA"] {
            XCTAssertEqual(
                VersificationMapper.convert(
                    osisBookId: "3John",
                    chapter: 1,
                    verse: 15,
                    from: versification,
                    to: "KJVA"
                )?.reference,
                .init(osisBookId: "3John", chapter: 1, verse: 14),
                versification
            )
        }

        XCTAssertEqual(
            VersificationMapper.convert(
                osisBookId: "Exod",
                chapter: 7,
                verse: 26,
                from: "Segond",
                to: "KJVA"
            )?.reference,
            .init(osisBookId: "Exod", chapter: 8, verse: 1)
        )
        XCTAssertEqual(
            VersificationMapper.convert(
                osisBookId: "Num",
                chapter: 13,
                verse: 1,
                from: "Synodal",
                to: "KJVA"
            )?.reference,
            .init(osisBookId: "Num", chapter: 12, verse: 16)
        )
        XCTAssertEqual(
            VersificationMapper.convert(
                osisBookId: "Num",
                chapter: 13,
                verse: 1,
                from: "SynodalProt",
                to: "KJVA"
            )?.reference,
            .init(osisBookId: "Num", chapter: 12, verse: 16)
        )
        XCTAssertEqual(
            VersificationMapper.convert(
                osisBookId: "Ps",
                chapter: 3,
                verse: 1,
                from: "Vulg",
                to: "KJVA"
            )?.reference,
            .init(osisBookId: "Ps", chapter: 3, verse: 0)
        )

        XCTAssertEqual(
            VersificationMapper.convert(
                osisBookId: "Gen",
                chapter: 32,
                verse: 1,
                from: "Catholic",
                to: "KJVA"
            )?.fidelity,
            .mapped
        )
        XCTAssertEqual(
            VersificationMapper.convert(
                osisBookId: "Exod",
                chapter: 7,
                verse: 26,
                from: "Segond",
                to: "KJVA"
            )?.fidelity,
            .mapped
        )
    }

    /**
     Verifies range conversion is all-or-nothing and never substitutes source ordinals.

     The valid range maps both endpoints through JSword's Vulgate table, including its verse-zero
     first endpoint. An invalid endpoint makes the whole range fail, protecting bookmark
     persistence from a mixed-domain or partially converted result.
     */
    func testKJVARangeProjectionRejectsPartialConversion() throws {
        let start = VerseKeyReference(osisBookId: "Ps", chapter: 10, verse: 1, ordinal: 500)
        let end = VerseKeyReference(osisBookId: "Ps", chapter: 10, verse: 2, ordinal: 501)
        let projected = try XCTUnwrap(
            VersificationMapper.kjvaOrdinalRange(
                start: start,
                end: end,
                sourceVersification: "Vulg"
            )
        )
        XCTAssertEqual(
            projected.lowerBound,
            JSwordKJVAVersification.chapterIntroOrdinal(osisId: "Ps", chapter: 11)
        )
        XCTAssertEqual(
            projected.upperBound,
            JSwordKJVAVersification.verseOrdinal(osisId: "Ps", chapter: 11, verse: 1)
        )

        let invalid = VerseKeyReference(osisBookId: "", chapter: 10, verse: 2, ordinal: 501)
        XCTAssertNil(
            VersificationMapper.kjvaOrdinalRange(
                start: start,
                end: invalid,
                sourceVersification: "Vulg"
            )
        )
    }
}
