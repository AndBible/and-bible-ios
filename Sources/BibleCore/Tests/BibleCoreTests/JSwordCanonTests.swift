import Foundation
import SwordKit
import XCTest
@testable import BibleCore

/**
 Contract tests for JSword's intro-inclusive canon ordering and parser-only ordinal behavior.

 Expected ordinals are accumulated directly from the pinned Android canon dimensions rather than
 from `JSwordCanon` helpers. The tests read immutable package resources and exercise process-local
 lazy caches; they perform no persistence or network I/O.
 */
final class JSwordCanonTests: XCTestCase {
    /// Test-only shape of the pinned Android canon fixture.
    private struct CanonFixture: Decodable {
        /// JSword revision that produced the dimensions.
        let jswordRevision: String
        /// Canon dimensions keyed by exact JSword system name.
        let systems: [String: FixtureSystem]
    }

    /// Ordered books in one Android JSword system.
    private struct FixtureSystem: Decodable {
        /// Books including Bible and testament introduction pseudo-books.
        let books: [FixtureBook]
    }

    /// One OSIS identifier and its last verse number for every represented chapter.
    private struct FixtureBook: Decodable {
        /// Exact JSword OSIS identifier.
        let osis: String
        /// Last verses indexed by chapter, including chapter zero.
        let chapters: [Int]
    }

    /**
     Verifies every valid fixture coordinate has its independently accumulated ordinal and inverse.

     The traversal includes Bible, testament, book, and chapter introductions because verse zero is
     enumerated for every nonnegative chapter dimension. It reports only the first mismatch so a
     failure identifies the exact system, coordinate, direction, and expected ordinal without
     creating hundreds of thousands of XCTest assertion records.
     */
    func testEveryPinnedCoordinateHasStrictOrdinalAndExactInverse() throws {
        let fixture = try loadFixture()

        for name in fixture.systems.keys.sorted() {
            let system = try XCTUnwrap(fixture.systems[name])
            var expectedOrdinal = 0
            for book in system.books {
                for (chapter, lastVerse) in book.chapters.enumerated() where lastVerse >= 0 {
                    for verse in 0...lastVerse {
                        let reference = makeReference(book: book.osis, chapter: chapter, verse: verse)
                        let actualOrdinal = JSwordCanon.referenceIndex(
                            for: reference,
                            versification: name
                        )
                        guard actualOrdinal == expectedOrdinal else {
                            XCTFail(
                                "\(name) \(book.osis).\(chapter).\(verse): expected strict "
                                    + "ordinal \(expectedOrdinal), got \(String(describing: actualOrdinal))"
                            )
                            return
                        }

                        let inverse = JSwordCanon.reference(
                            forIndex: expectedOrdinal,
                            versification: name
                        )
                        guard inverse == reference else {
                            XCTFail(
                                "\(name) ordinal \(expectedOrdinal): expected inverse "
                                    + "\(describe(reference)), got \(describe(inverse))"
                            )
                            return
                        }
                        expectedOrdinal += 1
                    }
                }
            }
        }
    }

    /**
     Verifies strict lookup rejects coordinates and ordinals absent from the pinned dimensions.

     Every book is checked at its negative, first absent, and maximum chapter boundaries; every
     represented chapter is checked at negative, first absent, and maximum verse boundaries. A
     failure means compact lookup accepted a coordinate Android's finite canon does not contain.
     */
    func testStrictLookupRejectsAbsentAndExtremeCoordinates() throws {
        let fixture = try loadFixture()

        for name in fixture.systems.keys.sorted() {
            let system = try XCTUnwrap(fixture.systems[name])
            var coordinateCount = 0
            for book in system.books {
                for invalidChapter in [-1, book.chapters.count, Int.max] {
                    let reference = makeReference(
                        book: book.osis,
                        chapter: invalidChapter,
                        verse: 0
                    )
                    guard JSwordCanon.referenceIndex(for: reference, versification: name) == nil else {
                        XCTFail("\(name) accepted absent chapter \(describe(reference))")
                        return
                    }
                }

                for (chapter, lastVerse) in book.chapters.enumerated() {
                    guard lastVerse >= 0 else {
                        let reference = makeReference(book: book.osis, chapter: chapter, verse: 0)
                        guard JSwordCanon.referenceIndex(
                            for: reference,
                            versification: name
                        ) == nil else {
                            XCTFail("\(name) accepted negative fixture dimension \(describe(reference))")
                            return
                        }
                        continue
                    }
                    coordinateCount += lastVerse + 1
                    for invalidVerse in [-1, lastVerse + 1, Int.max] {
                        let reference = makeReference(
                            book: book.osis,
                            chapter: chapter,
                            verse: invalidVerse
                        )
                        guard JSwordCanon.referenceIndex(
                            for: reference,
                            versification: name
                        ) == nil else {
                            XCTFail("\(name) accepted absent verse \(describe(reference))")
                            return
                        }
                    }
                }
            }

            for invalidIndex in [-1, coordinateCount, Int.max] {
                guard JSwordCanon.reference(
                    forIndex: invalidIndex,
                    versification: name
                ) == nil else {
                    XCTFail("\(name) accepted out-of-range canon index \(invalidIndex)")
                    return
                }
            }
        }

        let unknownBook = makeReference(book: "Not.A.Book", chapter: 0, verse: 0)
        let knownBook = makeReference(book: "Gen", chapter: 1, verse: 1)
        XCTAssertNil(JSwordCanon.referenceIndex(for: unknownBook, versification: "KJV"))
        XCTAssertNil(JSwordCanon.referenceIndex(for: knownBook, versification: "NotAVersification"))
        XCTAssertNil(JSwordCanon.reference(forIndex: 0, versification: "NotAVersification"))
        XCTAssertNil(JSwordCanon.mappingReferenceIndex(for: unknownBook, versification: "KJV"))
        XCTAssertNil(
            JSwordCanon.mappingReferenceIndex(for: knownBook, versification: "NotAVersification")
        )
    }

    /**
     Verifies parser-only ordinals use unchecked verse addition without escaping the finite canon.

     For every represented chapter, the expected spillover is calculated from an independent
     running chapter-start ordinal. The strict API must reject the same noncanonical verse. Extreme
     inputs separately exercise negative rejection, arithmetic overflow, and final-range rejection.
     */
    func testParserOnlyLookupMatchesIndependentSpilloverAndOverflowBounds() throws {
        let fixture = try loadFixture()

        for name in fixture.systems.keys.sorted() {
            let system = try XCTUnwrap(fixture.systems[name])
            let coordinateCount = system.books.reduce(into: 0) { total, book in
                total += book.chapters.filter { $0 >= 0 }.reduce(0) { $0 + $1 + 1 }
            }
            var chapterStart = 0
            for book in system.books {
                for (chapter, lastVerse) in book.chapters.enumerated() where lastVerse >= 0 {
                    let spillVerse = lastVerse + 3
                    let reference = makeReference(
                        book: book.osis,
                        chapter: chapter,
                        verse: spillVerse
                    )
                    let candidate = chapterStart + spillVerse
                    let expected: Int? = candidate < coordinateCount ? candidate : nil
                    let actual = JSwordCanon.mappingReferenceIndex(
                        for: reference,
                        versification: name
                    )
                    guard actual == expected else {
                        XCTFail(
                            "\(name) parser spillover \(describe(reference)): expected "
                                + "\(String(describing: expected)), got \(String(describing: actual))"
                        )
                        return
                    }
                    guard JSwordCanon.referenceIndex(
                        for: reference,
                        versification: name
                    ) == nil else {
                        XCTFail("\(name) strict lookup accepted parser spillover \(describe(reference))")
                        return
                    }
                    chapterStart += lastVerse + 1
                }
            }
        }

        let overflowing = makeReference(book: "Gen", chapter: 1, verse: Int.max)
        let negativeVerse = makeReference(book: "Gen", chapter: 1, verse: -1)
        let absentChapter = makeReference(book: "Gen", chapter: Int.max, verse: 0)
        XCTAssertNil(JSwordCanon.mappingReferenceIndex(for: overflowing, versification: "KJV"))
        XCTAssertNil(JSwordCanon.mappingReferenceIndex(for: negativeVerse, versification: "KJV"))
        XCTAssertNil(JSwordCanon.mappingReferenceIndex(for: absentChapter, versification: "KJV"))
    }

    /// Decodes the immutable Android-derived dimensions used to calculate independent expectations.
    private func loadFixture() throws -> CanonFixture {
        let data = try XCTUnwrap(JSwordVersificationRegistry.canonFixtureData())
        let fixture = try JSONDecoder().decode(CanonFixture.self, from: data)
        XCTAssertEqual(fixture.jswordRevision, JSwordVersificationRegistry.pinnedRevision)
        _ = try XCTUnwrap(fixture.systems.first, "Pinned canon fixture must contain a system")
        return fixture
    }

    /// Constructs one coordinate without consulting the compact canon implementation.
    private func makeReference(
        book: String,
        chapter: Int,
        verse: Int
    ) -> SwordVersification.Reference {
        .init(osisBookId: book, chapter: chapter, verse: verse)
    }

    /// Formats an optional coordinate for one precise XCTest failure diagnostic.
    private func describe(_ reference: SwordVersification.Reference?) -> String {
        guard let reference else { return "nil" }
        return "\(reference.osisBookId).\(reference.chapter).\(reference.verse)"
    }
}
