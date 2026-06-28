// BookCatalogTests.swift -- Reader book catalog parity tests

import XCTest
@testable import BibleUI
import SwordKit

/**
 BibleUI reader book-catalog parity coverage for fallback and module-provided metadata.

 These tests keep catalog behavior in the app-host-free `BibleUITests` package lane because the
 contract belongs to the BibleUI reader model, not app bootstrap. Failures indicate iOS has drifted
 from Android/JSword-compatible startup placeholders or active-module book ordering semantics.
 */
final class BookCatalogTests: XCTestCase {
    /**
     Protects the no-module compatibility catalog used before any SWORD Bible is available.

     Android normally reads this data through JSword, but iOS still needs deterministic placeholder
     rendering during startup/no-module states. A failure means the controller shims can regress
     static navigation, placeholder verse counts, or KJVA reading-progress identifiers.
     */
    func testBookCatalogNoModuleUsesStaticFallbackOnlyWhenNoBibleModuleIsActive() {
        let catalog = BibleReaderBookCatalog(activeModule: nil, moduleBookList: [])

        XCTAssertEqual(catalog.books.count, 66)
        XCTAssertEqual(catalog.chapterCount(for: "Genesis"), 50)
        XCTAssertEqual(catalog.osisBookId(for: "Genesis"), "Gen")
        XCTAssertEqual(catalog.bookName(forOsisId: "Rev"), "Revelation")
        XCTAssertFalse(catalog.isNewTestament("Genesis"))
        XCTAssertTrue(catalog.isNewTestament("Matthew"))
        XCTAssertEqual(catalog.verseCount(book: "Ruth", chapter: 4), 30)
        XCTAssertEqual(catalog.verseCount(book: "Revelation", chapter: 22), 21)
        XCTAssertEqual(catalog.kjvBookOrdinal(for: "Genesis"), 2)
        XCTAssertEqual(catalog.kjvBookOrdinal(for: "Matthew"), 42)
    }

    /**
     Protects the explicit module-provided book-list ordering rule.

     Android asks the active document versification for book/chapter metadata. If SWORD reports an
     active list, iOS must use that list rather than re-sorting or replacing it with the 66-book
     fallback, because that would change deuterocanonical and module-specific navigation semantics.
     */
    func testBookCatalogModuleBookListStateControlsLookupWithoutStaticFallback() {
        let moduleBooks = [
            BookInfo(name: "Genesis", osisId: "Gen", abbreviation: "Ge", chapterCount: 50, testament: 1),
            BookInfo(name: "Tobit", osisId: "Tob", abbreviation: "Tob", chapterCount: 14, testament: 1),
            BookInfo(name: "Matthew", osisId: "Matt", abbreviation: "Mt", chapterCount: 28, testament: 2),
        ]
        let catalog = BibleReaderBookCatalog(activeModule: nil, moduleBookList: moduleBooks)

        XCTAssertEqual(catalog.books, moduleBooks)
        XCTAssertEqual(catalog.chapterCount(for: "Tobit"), 14)
        XCTAssertEqual(catalog.nextBook(after: "Genesis"), "Tobit")
        XCTAssertEqual(catalog.previousBook(before: "Matthew"), "Tobit")
        XCTAssertEqual(catalog.osisBookId(for: "Tobit"), "Tob")
        XCTAssertEqual(catalog.bookName(forOsisId: "Tob"), "Tobit")
        XCTAssertFalse(catalog.isNewTestament("Tobit"))
    }

    /**
     Protects the documented compatibility ordinal math for no-module placeholder documents.

     Real Bible modules use SWORD/JSword intro-inclusive ordinals; this fallback exists only for
     generated placeholder content. A failure indicates placeholder rendering or bookmark test
     fixtures can drift while active-module paths remain correctly delegated elsewhere.
     */
    func testBookCatalogNoModuleOrdinalCompatibilityMatchesLegacyPlaceholderMath() {
        let catalog = BibleReaderBookCatalog(activeModule: nil, moduleBookList: [])

        XCTAssertEqual(catalog.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1), 1)
        XCTAssertEqual(catalog.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 1), 41)
        XCTAssertEqual(
            catalog.verseReference(book: "Genesis", ordinal: 41),
            VerseKeyReference(osisBookId: "Gen", chapter: 2, verse: 1, ordinal: 41)
        )
        let range = catalog.chapterOrdinalRange(book: "Genesis", chapter: 1)
        XCTAssertEqual(range?.start, 1)
        XCTAssertEqual(range?.end, 31)
        XCTAssertEqual(range?.verseCount, 31)
    }
}
