import XCTest
@testable import BibleUI
@testable import SwordKit

extension AndBibleTests {
    /**
     Verifies that the 66-book portrait grid follows Android's default column-major layout.

     Android's `ButtonGrid` uses an 11-by-6 portrait matrix for the standard Protestant canon and
     fills columns before rows unless the row-order preference is enabled. The iOS selector must
     therefore render Genesis through 1 Kings down the first column, then continue with 2 Kings at
     the top of the second column.
     */
    func testPassageBookGridUsesAndroidColumnMajorPortraitOrderForStandardCanon() {
        let layout = PassageGridLayout.androidDefault(
            itemCount: BibleReaderController.defaultBooks.count,
            kind: .book,
            orientation: .portrait
        )
        let slots = layout.displaySlots(for: BibleReaderController.defaultBooks)

        XCTAssertEqual(layout.rows, 11)
        XCTAssertEqual(layout.columns, 6)
        XCTAssertTrue(layout.usesColumnMajorOrder)
        XCTAssertEqual(slots[0]?.osisId, "Gen")
        XCTAssertEqual(slots[6]?.osisId, "Exod")
        XCTAssertEqual(slots[60]?.osisId, "1Kgs")
        XCTAssertEqual(slots[1]?.osisId, "2Kgs")
    }

    /**
     Verifies Android's row-order option can be represented without changing the shared grid.

     The preference is not the default Android behavior, but the layout primitive must support it so
     the iOS chooser can add the user-facing option without another layout rewrite.
     */
    func testPassageBookGridCanUseAndroidRowOrderPreference() {
        let layout = PassageGridLayout.androidDefault(
            itemCount: BibleReaderController.defaultBooks.count,
            kind: .book,
            orientation: .portrait,
            rowOrder: true
        )
        let slots = layout.displaySlots(for: BibleReaderController.defaultBooks)

        XCTAssertFalse(layout.usesColumnMajorOrder)
        XCTAssertEqual(slots[0]?.osisId, "Gen")
        XCTAssertEqual(slots[1]?.osisId, "Exod")
    }

    /**
     Protects Android's category color boundaries for representative canonical books.

     These colors come from Android `GridChoosePassageBook.getBookColorAndGroup` and should not drift
     into iOS-specific palette choices.
     */
    func testPassageBookCategoryColorsMirrorAndroidBoundaries() {
        let expectations: [(osisId: String, color: PassageGridRGBColor)] = [
            ("Gen", .pentateuch),
            ("Josh", .history),
            ("Ps", .wisdom),
            ("Isa", .majorProphets),
            ("Mal", .minorProphets),
            ("Matt", .gospel),
            ("Rom", .pauline),
            ("Jas", .generalEpistles),
            ("Rev", .revelation),
        ]

        for expectation in expectations {
            XCTAssertEqual(
                PassageBookCategory.category(forOsisId: expectation.osisId).color,
                expectation.color,
                expectation.osisId
            )
        }
    }

    /**
     Verifies the highlighted current book uses Android's selected-button palette.

     Android paints the current book with its category color as the tint and dark gray text, while
     non-current books keep the category color as text over the testament tint.
     */
    func testPassageBookCellPaletteMirrorsAndroidCurrentAndNormalStates() {
        let current = PassageGridCellPalette.bookPalette(
            for: BookInfo(name: "Matthew", osisId: "Matt", abbreviation: "Matt", chapterCount: 28, testament: 2),
            currentOsisId: "Matt"
        )
        let oldTestamentNormal = PassageGridCellPalette.bookPalette(
            for: BookInfo(name: "Genesis", osisId: "Gen", abbreviation: "Gen", chapterCount: 50, testament: 1),
            currentOsisId: "Matt"
        )
        let newTestamentNormal = PassageGridCellPalette.bookPalette(
            for: BookInfo(name: "Romans", osisId: "Rom", abbreviation: "Rom", chapterCount: 16, testament: 2),
            currentOsisId: "Matt"
        )

        XCTAssertEqual(current.background, .gospel)
        XCTAssertEqual(current.foreground, .darkGray)
        XCTAssertEqual(oldTestamentNormal.background, .oldTestamentTint)
        XCTAssertEqual(oldTestamentNormal.foreground, .pentateuch)
        XCTAssertEqual(newTestamentNormal.background, .newTestamentTint)
        XCTAssertEqual(newTestamentNormal.foreground, .pauline)
    }

    /**
     Verifies chapter and verse grids share Android's selected-number palette.

     Android uses the selected book category color for the current chapter and current verse instead
     of inventing a separate iOS highlight treatment.
     */
    func testPassageNumberCellPaletteUsesBookCategoryForCurrentChapterAndVerse() {
        let current = PassageGridCellPalette.numberPalette(
            number: 3,
            currentNumber: 3,
            categoryColor: .gospel
        )
        let normal = PassageGridCellPalette.numberPalette(
            number: 4,
            currentNumber: 3,
            categoryColor: .gospel
        )

        XCTAssertEqual(current.background, .gospel)
        XCTAssertEqual(current.foreground, .darkGray)
        XCTAssertEqual(normal.background, .oldTestamentTint)
        XCTAssertEqual(normal.foreground, .white)
    }

    /**
     Verifies expanded module canons keep all books and use Android's dynamic non-66 layout.

     Modules with additional books must continue to use `BookInfo` as the data source. A 67-book
     module should not be forced into the 66-book 11-by-6 matrix or drop the extra book.
     */
    func testPassageBookGridUsesDynamicAndroidLayoutForExpandedCanons() {
        let expandedBooks = BibleReaderController.defaultBooks + [
            BookInfo(name: "Tobit", osisId: "Tob", abbreviation: "Tob", chapterCount: 14, testament: 1),
        ]
        let layout = PassageGridLayout.androidDefault(
            itemCount: expandedBooks.count,
            kind: .book,
            orientation: .portrait
        )
        let slots = layout.displaySlots(for: expandedBooks)

        XCTAssertEqual(layout.rows, 10)
        XCTAssertEqual(layout.columns, 7)
        XCTAssertTrue(slots.contains { $0?.osisId == "Tob" })
        XCTAssertEqual(PassageBookCategory.category(forOsisId: "Tob").color, .other)
    }
}
