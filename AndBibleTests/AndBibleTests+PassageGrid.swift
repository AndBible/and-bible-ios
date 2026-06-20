import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import SwordKit

extension AndBibleTests {
    /**
     Verifies the chooser option state machine mirrors Android's overflow-menu behavior.

     Android's `GridChoosePassageBook` persists the row-order, category grouping, long-name, and
     progress options under `book_grid_*` keys. Grouping forces Bible-book order and row order,
     while alphabetical and row-order changes clear grouping without resetting unrelated options.
     Failure means the iOS menu is only cosmetically similar and will drift from Android behavior.
     */
    func testPassageChooserOptionsMirrorAndroidMenuStateTransitions() {
        var options = PassageChooserOptions.androidDefault

        XCTAssertFalse(options.alphabeticalOrder)
        XCTAssertFalse(options.rowOrder)
        XCTAssertFalse(options.groupByCategory)
        XCTAssertFalse(options.showLongBookName)
        XCTAssertTrue(options.showProgressBars)

        options.apply(.groupByCategory)
        XCTAssertFalse(options.alphabeticalOrder)
        XCTAssertTrue(options.rowOrder)
        XCTAssertTrue(options.groupByCategory)

        options.apply(.alphabeticalOrder)
        XCTAssertTrue(options.alphabeticalOrder)
        XCTAssertTrue(options.rowOrder)
        XCTAssertFalse(options.groupByCategory)

        options.apply(.rowOrder)
        XCTAssertTrue(options.alphabeticalOrder)
        XCTAssertFalse(options.rowOrder)
        XCTAssertFalse(options.groupByCategory)

        options.apply(.showLongBookName)
        options.apply(.showProgressBars)
        XCTAssertTrue(options.showLongBookName)
        XCTAssertFalse(options.showProgressBars)
    }

    /**
     Verifies iOS exposes Android's full passage-chooser overflow menu contract.

     Android's top-right chooser menu includes sorting, row ordering, category grouping, long/short
     book names, and progress bars in this order. Failure means the iOS popup may look present while
     still omitting or reordering Android-visible behavior.
     */
    func testPassageChooserMenuEntriesMirrorAndroidOrderAndLabels() {
        let entries = PassageChooserMenuEntry.androidBookChooserOrder

        XCTAssertEqual(
            entries.map(\.option),
            [.alphabeticalOrder, .rowOrder, .groupByCategory, .showLongBookName, .showProgressBars]
        )
        XCTAssertEqual(
            entries.map(\.localizationKey),
            [
                "sort_by_alphabetical",
                "book_menu_sort_row_opt",
                "book_menu_group_by_category",
                "book_menu_show_long_book_name",
                "book_menu_show_progress_bars",
            ]
        )
        XCTAssertEqual(
            entries.map(\.defaultTitle),
            [
                "Alphabetical order",
                "Order books horizontally",
                "Group books by category",
                "Show long book name",
                "Show progress bars",
            ]
        )
    }

    /**
     Verifies iOS uses Android/JSword short book labels instead of SWORD abbreviations.

     The Android chooser calls `versification.getShortName(book)`, producing labels like `2 Ki`,
     `Psa`, `Act`, and `Phile`. The previous iOS grid used module abbreviations such as `2Kgs`,
     `Ps`, `Acts`, and `Phlm`, so the two platforms did not present the same picker. Long-name mode
     should follow Android's uppercase short-name plus description format.
     */
    func testPassageBookDisplayNamesMirrorAndroidShortAndLongNames() {
        let expectations: [(osisId: String, shortName: String)] = [
            ("2Kgs", "2 Ki"),
            ("1Chr", "1 Ch"),
            ("Ps", "Psa"),
            ("Acts", "Act"),
            ("Phil", "Phili"),
            ("Phlm", "Phile"),
            ("Jas", "Jam"),
            ("1Pet", "1 Pe"),
        ]

        for expectation in expectations {
            let book = try! XCTUnwrap(BibleReaderController.defaultBooks.first { $0.osisId == expectation.osisId })
            XCTAssertEqual(PassageBookDisplayName.shortName(for: book), expectation.shortName, expectation.osisId)
        }

        let genesis = try! XCTUnwrap(BibleReaderController.defaultBooks.first { $0.osisId == "Gen" })
        XCTAssertEqual(PassageBookDisplayName.title(for: genesis, showLongName: false), "Gen")
        XCTAssertEqual(PassageBookDisplayName.title(for: genesis, showLongName: true), "GEN\nGenesis")
    }

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
     Verifies book ordering is driven by the Android overflow-menu options.

     Android defaults to Bible-book order with portrait column-major placement. Alphabetical mode
     sorts the source books but still uses the current row-order setting for visual placement. The
     row-order option fills the visual row left-to-right, and category grouping inserts spacer cells
     when the Android `GroupB` bucket changes. Failure means menu state is not actually controlling
     the rendered grid, even if the menu rows appear.
     */
    func testPassageBookOrderingOptionsMirrorAndroidMenu() {
        var defaultOptions = PassageChooserOptions.androidDefault
        var slots = PassageBookOrdering.displaySlots(
            for: BibleReaderController.defaultBooks,
            options: defaultOptions,
            orientation: .portrait
        )
        XCTAssertEqual(slots[0]?.osisId, "Gen")
        XCTAssertEqual(slots[1]?.osisId, "2Kgs")
        XCTAssertEqual(slots[6]?.osisId, "Exod")

        defaultOptions.apply(.rowOrder)
        slots = PassageBookOrdering.displaySlots(
            for: BibleReaderController.defaultBooks,
            options: defaultOptions,
            orientation: .portrait
        )
        XCTAssertEqual(slots[0]?.osisId, "Gen")
        XCTAssertEqual(slots[1]?.osisId, "Exod")

        var groupedOptions = PassageChooserOptions.androidDefault
        groupedOptions.apply(.groupByCategory)
        let groupedSlots = PassageBookOrdering.displaySlots(
            for: BibleReaderController.defaultBooks,
            options: groupedOptions,
            orientation: .portrait
        )
        XCTAssertEqual(groupedSlots.prefix(6).map { $0?.osisId }, ["Gen", "Exod", "Lev", "Num", "Deut", nil])
        XCTAssertEqual(groupedSlots[6]?.osisId, "Josh")

        var alphabeticalOptions = PassageChooserOptions.androidDefault
        alphabeticalOptions.apply(.alphabeticalOrder)
        let alphabeticalSlots = PassageBookOrdering.displaySlots(
            for: BibleReaderController.defaultBooks,
            options: alphabeticalOptions,
            orientation: .portrait
        )
        XCTAssertEqual(alphabeticalSlots[0]?.osisId, "Acts")
        XCTAssertEqual(alphabeticalSlots[6]?.osisId, "Amos")
        XCTAssertEqual(alphabeticalSlots[1]?.osisId, "Esth")
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

    /**
     Verifies the passage chooser uses Android's fixed dark activity palette.

     Android's chooser sets `allowThemeChange = false` and uses `GridChoosePassageTheme`, so the
     picker remains a dark full-screen surface even when the reader itself is in day mode. Failure
     means iOS can accidentally inherit the reader theme and diverge from the Android screenshots.
     */
    func testPassageChooserSurfacePaletteMirrorsAndroidFixedDarkTheme() {
        XCTAssertEqual(PassageChooserSurfacePalette.background, PassageGridRGBColor(red: 0x30, green: 0x30, blue: 0x30))
        XCTAssertEqual(PassageChooserSurfacePalette.toolbarBackground, PassageGridRGBColor(red: 0x00, green: 0x00, blue: 0x00))
        XCTAssertEqual(PassageGridProgress.readingColor, PassageGridRGBColor(red: 0x4C, green: 0xAF, blue: 0x50))
        XCTAssertEqual(PassageGridProgress.memorizationColor, PassageGridRGBColor(red: 0xFF, green: 0xD7, blue: 0x00))
    }

    /**
     Verifies iOS derives square cell dimensions from Android's matrix columns.

     Android gives every `TableRow` and every cell the same weighted width/height within the
     calculated matrix. The SwiftUI grid should therefore size each button with the same width and
     height instead of keeping Android rows/columns but rendering wide rectangular buttons.
     */
    func testPassageGridMetricsDeriveSquareCellSideFromAvailableWidth() {
        let metrics = PassageGridMetrics.squareCells(
            availableWidth: 393,
            columns: 6,
            spacing: 4,
            horizontalPadding: 12
        )

        XCTAssertEqual(metrics.cellSide, 58.166, accuracy: 0.001)
        XCTAssertEqual(metrics.gridWidth, 369, accuracy: 0.001)
    }

    /**
     Verifies chooser grids apply their shared outer inset horizontally only.

     `PassageGridMetrics.horizontalPadding` is part of the square-cell width calculation. Applying
     it to every edge adds unrelated vertical spacing and makes the metric contract misleading, so
     each Android-style chooser grid should use it only for leading and trailing padding.
     */
    func testPassageGridViewsApplyHorizontalOnlyOuterPadding() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "Sources/BibleUI/Sources/BibleUI/Navigation/BookChooserView.swift",
            "Sources/BibleUI/Sources/BibleUI/Navigation/ChapterChooserView.swift",
            "Sources/BibleUI/Sources/BibleUI/Navigation/VerseChooserView.swift"
        ]

        for relativePath in relativePaths {
            let sourceURL = repoRoot.appendingPathComponent(relativePath)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)

            XCTAssertTrue(
                source.contains(".padding(.horizontal, PassageGridMetrics.horizontalPadding)"),
                relativePath
            )
            XCTAssertFalse(
                source.contains(".padding(PassageGridMetrics.horizontalPadding)"),
                relativePath
            )
        }
    }

    /**
     Verifies the book chooser title follows Android's activity-title workspace suffix.

     Android `GridChoosePassageBook.onCreate` appends `SharedActivityState.currentWorkspaceName` to
     the chooser title. The iOS picker should use the same user-facing contract and omit the suffix
     only when there is no usable workspace name. Failure means the drawer may no longer identify
     which workspace the navigation target belongs to.
     */
    func testPassageChooserTitleAppendsWorkspaceNameLikeAndroid() {
        XCTAssertEqual(
            PassageChooserTitle.bookSelectionTitle(baseTitle: "Choose Book", workspaceName: "Workspace 1"),
            "Choose Book (Workspace 1)"
        )
        XCTAssertEqual(
            PassageChooserTitle.bookSelectionTitle(baseTitle: "Choose Book", workspaceName: "   "),
            "Choose Book"
        )
    }

    /**
     Verifies the Android chooser app bar is owned by the chooser content itself.

     `BibleReaderView` hides native navigation chrome for the custom reader toolbar, and iOS can fail
     to render a nested native `NavigationStack` toolbar from the reader overlay. Android's chooser
     activity owns a visible app bar containing the back button, title, and top-right overflow menu,
     so iOS must render that app bar explicitly inside `BookChooserView`.
     */
    func testPassageChooserOwnsExplicitAndroidAppBar() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chooserViewURL = repoRoot.appendingPathComponent(
            "Sources/BibleUI/Sources/BibleUI/Navigation/BookChooserView.swift"
        )

        let source = try String(contentsOf: chooserViewURL, encoding: .utf8)

        XCTAssertTrue(source.contains("PassageChooserAppBar("))
        XCTAssertTrue(source.contains(".toolbar(.hidden, for: .navigationBar)"))
        XCTAssertFalse(source.contains("ToolbarItem(placement: .navigation)"))
    }

    /**
     Verifies chooser progress fractions follow Android's JSword KJVA semantics.

     Android computes book reading progress from distinct read KJVA chapters in the active cycle,
     book memorization progress from memorized KJVA verse ordinals across the book, chapter progress
     from the selected chapter's KJVA verse range, and verse progress as one full bar for a
     memorized verse. Failure means the progress bars are decorative or tied to an iOS-only address
     space rather than Android's `ProgressControl` behavior.
     */
    func testPassageGridProgressUsesAndroidKJVARanges() throws {
        let genesis = try XCTUnwrap(BibleReaderController.defaultBooks.first { $0.osisId == "Gen" })
        let genesisOrdinal = try XCTUnwrap(JSwordKJVAVersification.bibleBookOrdinal(forOsisId: "Gen"))
        let genesisStart = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1))
        let genesisChapterOneEnd = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 31))

        let readingSnapshot = ReadingProgressSnapshot(
            history: [
                ReadingProgressHistoryRow(
                    bookInitials: "KJV",
                    startOrdinal: genesisStart,
                    kjvBookOrdinal: genesisOrdinal,
                    chapter: 1,
                    cycle: 3,
                    readAt: 1,
                    source: .manual
                ),
                ReadingProgressHistoryRow(
                    bookInitials: "KJV",
                    startOrdinal: genesisChapterOneEnd + 1,
                    kjvBookOrdinal: genesisOrdinal,
                    chapter: 2,
                    cycle: 3,
                    readAt: 2,
                    source: .manual
                ),
                ReadingProgressHistoryRow(
                    bookInitials: "KJV",
                    startOrdinal: genesisStart,
                    kjvBookOrdinal: genesisOrdinal,
                    chapter: 1,
                    cycle: 2,
                    readAt: 3,
                    source: .manual
                ),
            ],
            settings: ReadingProgressSettingsSnapshot(activeCycle: 3)
        )
        let memorizationSnapshot = MemorizationProgressSnapshot(
            memorizedRanges: [
                MemorizationProgressRange(bookInitials: "", startOrdinal: genesisStart, endOrdinal: genesisStart + 2),
            ]
        )

        let bookProgress = PassageGridProgressCalculator.bookProgress(
            book: genesis,
            readingSnapshot: readingSnapshot,
            memorizationSnapshot: memorizationSnapshot,
            activeBookInitials: "KJV"
        )
        XCTAssertEqual(bookProgress.readingFraction, 2.0 / 50.0, accuracy: 0.0001)
        XCTAssertEqual(bookProgress.memorizationFraction, 3.0 / 1533.0, accuracy: 0.0001)

        let chapterProgress = PassageGridProgressCalculator.chapterProgress(
            book: genesis,
            chapter: 1,
            readingSnapshot: readingSnapshot,
            memorizationSnapshot: memorizationSnapshot,
            activeBookInitials: "KJV"
        )
        XCTAssertEqual(chapterProgress.readingFraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(chapterProgress.memorizationFraction, 3.0 / 31.0, accuracy: 0.0001)

        let verseProgress = PassageGridProgressCalculator.verseProgress(
            book: genesis,
            chapter: 1,
            verse: 1,
            readingSnapshot: readingSnapshot,
            memorizationSnapshot: memorizationSnapshot,
            activeBookInitials: "KJV"
        )
        XCTAssertEqual(verseProgress.readingFraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(verseProgress.memorizationFraction, 1.0, accuracy: 0.0001)
    }

    /**
     Verifies book reading progress aggregates read chapters in one pass.

     Android progress is chapter-based for book cells. SwiftUI can re-render visible cells often, so
     the iOS calculator should preserve the same distinct-chapter behavior without allocating
     filter/map intermediates before building the chapter set.
     */
    func testPassageGridBookProgressUsesSinglePassReadingChapterAggregation() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent(
            "Sources/BibleUI/Sources/BibleUI/Navigation/PassageGrid.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let bookProgressStart = try XCTUnwrap(source.range(of: "static func bookProgress("))
        let bookProgressEnd = try XCTUnwrap(
            source.range(of: "static func chapterProgress(", range: bookProgressStart.upperBound..<source.endIndex)
        )
        let bookProgressSource = source[bookProgressStart.lowerBound..<bookProgressEnd.lowerBound]

        XCTAssertTrue(bookProgressSource.contains("var readChapters = Set<Int>()"))
        XCTAssertFalse(bookProgressSource.contains(".filter { row in"))
        XCTAssertFalse(bookProgressSource.contains(".map(\\.chapter)"))
    }

    /**
     Verifies memorization progress counts unique KJVA ordinals from merged Android ranges.

     Android memorization data can contain overlapping neutral and module-scoped ranges. The grid
     should count their union, ignore other modules, and avoid treating repeated ordinals as extra
     progress.
     */
    func testPassageGridProgressMergesOverlappingMemorizationRanges() throws {
        let genesis = try XCTUnwrap(BibleReaderController.defaultBooks.first { $0.osisId == "Gen" })
        let genesisStart = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1))

        let memorizationSnapshot = MemorizationProgressSnapshot(
            memorizedRanges: [
                MemorizationProgressRange(bookInitials: "", startOrdinal: genesisStart, endOrdinal: genesisStart + 9),
                MemorizationProgressRange(bookInitials: "KJV", startOrdinal: genesisStart + 4, endOrdinal: genesisStart + 14),
                MemorizationProgressRange(bookInitials: "KJV", startOrdinal: genesisStart + 15, endOrdinal: genesisStart + 19),
                MemorizationProgressRange(bookInitials: "ESV", startOrdinal: genesisStart + 20, endOrdinal: genesisStart + 30),
            ]
        )

        let chapterProgress = PassageGridProgressCalculator.chapterProgress(
            book: genesis,
            chapter: 1,
            readingSnapshot: nil,
            memorizationSnapshot: memorizationSnapshot,
            activeBookInitials: "KJV"
        )

        XCTAssertEqual(chapterProgress.memorizationFraction, 20.0 / 31.0, accuracy: 0.0001)
    }
}
