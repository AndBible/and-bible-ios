// PassageGrid.swift - Android-aligned passage selector layout and palette

import SwiftUI
import BibleCore
import SwordKit

/**
 Android-compatible selector item kind used by the shared passage grid layout.

 The book selector has a fixed 66-book standard layout on Android. Chapter and verse selectors,
 plus non-standard book lists, use Android's dynamic row calculation.
 */
enum PassageGridItemKind: Equatable, Sendable {
    /// Book selector grid.
    case book

    /// Chapter or verse selector grid.
    case number
}

/**
 Orientation used by Android's `LayoutDesigner` passage-grid rules.

 The value is intentionally derived from the available chooser size instead of device orientation
 so iPad split views and resizable windows can choose the same portrait or landscape matrix Android
 would choose for the visible grid shape.
 */
enum PassageGridOrientation: Equatable, Sendable {
    /// Taller-than-wide passage chooser.
    case portrait

    /// Wider-than-tall passage chooser.
    case landscape

    /**
     Creates an orientation from a SwiftUI geometry size.

     - Parameter size: Available grid container size.
     */
    init(size: CGSize) {
        self = size.width > size.height ? .landscape : .portrait
    }
}

/**
 RGB color token copied from Android's passage selector constants.

 SwiftUI `Color` is not equatable, so tests assert against this value type while views convert it
 to `Color` only at render time.
 */
public struct PassageGridRGBColor: Equatable, Sendable {
    /// Red component in the Android 0...255 range.
    public let red: Int

    /// Green component in the Android 0...255 range.
    public let green: Int

    /// Blue component in the Android 0...255 range.
    public let blue: Int

    /**
     Creates an RGB color token.

     - Parameters:
       - red: Red component in `0...255`.
       - green: Green component in `0...255`.
       - blue: Blue component in `0...255`.
     - Side effects: none.
     - Failure modes: Components are not clamped; callers should pass Android source values.
     */
    public init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// SwiftUI color used by the rendered selector cell.
    public var swiftUIColor: Color {
        Color(
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0
        )
    }

    /// Android `Color.DKGRAY`.
    static let darkGray = PassageGridRGBColor(red: 0x44, green: 0x44, blue: 0x44)

    /// Android black toolbar tint used by the fixed passage-chooser activity theme.
    static let black = PassageGridRGBColor(red: 0x00, green: 0x00, blue: 0x00)

    /// Android default text color for unselected chapter and verse buttons.
    static let white = PassageGridRGBColor(red: 0xFF, green: 0xFF, blue: 0xFF)

    /// Android Old Testament button tint.
    static let oldTestamentTint = darkGray

    /// Android New Testament button tint.
    static let newTestamentTint = PassageGridRGBColor(red: 0x50, green: 0x50, blue: 0x50)

    /// Android Pentateuch category color.
    static let pentateuch = PassageGridRGBColor(red: 0xCC, green: 0xCC, blue: 0xFE)

    /// Android history category color.
    static let history = PassageGridRGBColor(red: 0xFE, green: 0xCC, blue: 0x9B)

    /// Android wisdom category color.
    static let wisdom = PassageGridRGBColor(red: 0x99, green: 0xFF, blue: 0x99)

    /// Android major-prophets category color.
    static let majorProphets = PassageGridRGBColor(red: 0xFF, green: 0x99, blue: 0xFF)

    /// Android minor-prophets category color.
    static let minorProphets = PassageGridRGBColor(red: 0xFF, green: 0xFE, blue: 0xCD)

    /// Android gospel category color.
    static let gospel = PassageGridRGBColor(red: 0xFF, green: 0x97, blue: 0x03)

    /// Android Acts category color.
    static let acts = PassageGridRGBColor(red: 0x00, green: 0x99, blue: 0xFF)

    /// Android Pauline epistles category color.
    static let pauline = PassageGridRGBColor(red: 0xFF, green: 0xFF, blue: 0x31)

    /// Android general epistles category color.
    static let generalEpistles = PassageGridRGBColor(red: 0x67, green: 0xCC, blue: 0x66)

    /// Android Revelation category color.
    static let revelation = PassageGridRGBColor(red: 0xFE, green: 0x33, blue: 0xFF)

    /// Android fallback color for books outside the canonical category ranges.
    static let other = acts

    /// Android passage chooser activity background.
    static let passageChooserBackground = PassageGridRGBColor(red: 0x30, green: 0x30, blue: 0x30)
}

/**
 Fixed Android passage-chooser surface palette.

 Android disables normal theme switching for `GridChoosePassageBook`, `GridChoosePassageChapter`,
 and `GridChoosePassageVerse`; those activities keep a dark grid surface and black toolbar in both
 day and night reader modes. The iOS chooser consumes this palette directly so it does not inherit
 the surrounding reader theme.
 */
enum PassageChooserSurfacePalette {
    /// Android `GridChoosePassageTheme` content background.
    static let background = PassageGridRGBColor.passageChooserBackground

    /// Android chooser action-bar background.
    static let toolbarBackground = PassageGridRGBColor.black
}

/**
 Android scripture/non-scripture book scope for the passage book chooser.

 Android passes the active document's own `BibleBook` list through `Scripture.isScripture`, where
 scripture means membership in JSword's KJV versification and excludes introduction pseudo-books.
 iOS receives `BookInfo` from the active SWORD module instead of JSword, so this helper applies the
 same KJV 66-book predicate over that module-provided list without replacing it as the data source.
 */
enum PassageBookScriptureScope: Equatable, Sendable {
    /// Android `isScriptureRequired = true`.
    case scripture

    /// Android `isScriptureRequired = false`, surfaced as the deuterocanonical toggle.
    case deuterocanonical

    /// JSword KJV scripture books used by Android `Scripture.isScripture`.
    private static let androidScriptureOsisIds: Set<String> = [
        "Gen", "Exod", "Lev", "Num", "Deut", "Josh", "Judg", "Ruth",
        "1Sam", "2Sam", "1Kgs", "2Kgs", "1Chr", "2Chr", "Ezra", "Neh",
        "Esth", "Job", "Ps", "Prov", "Eccl", "Song", "Isa", "Jer",
        "Lam", "Ezek", "Dan", "Hos", "Joel", "Amos", "Obad", "Jonah",
        "Mic", "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal", "Matt",
        "Mark", "Luke", "John", "Acts", "Rom", "1Cor", "2Cor", "Gal",
        "Eph", "Phil", "Col", "1Thess", "2Thess", "1Tim", "2Tim",
        "Titus", "Phlm", "Heb", "Jas", "1Pet", "2Pet", "1John",
        "2John", "3John", "Jude", "Rev",
    ]

    /**
     Filters an active-module book list with Android's scripture/non-scripture predicate.

     - Parameters:
       - books: Active module-provided books in document order.
       - scope: Android chooser scope to render.
     - Returns: Books matching the requested Android scope, preserving the module-provided order.
     - Side effects: none.
     - Failure modes: Unknown OSIS ids are treated as non-scripture, matching Android's KJV
       membership check for books outside `SystemKJV`.
     */
    static func books(from books: [BookInfo], scope: PassageBookScriptureScope) -> [BookInfo] {
        books.filter { book in
            switch scope {
            case .scripture:
                return isScripture(book)
            case .deuterocanonical:
                return !isScripture(book)
            }
        }
    }

    /**
     Returns whether Android would show the passage chooser deuterocanonical action item.

     - Parameter books: Active module-provided books in document order.
     - Returns: `true` when the module exposes at least one non-scripture book.
     - Side effects: none.
     - Failure modes: none.
     */
    static func hasDeuterocanonicalBooks(_ books: [BookInfo]) -> Bool {
        books.contains { !isScripture($0) }
    }

    /**
     Toggles the visible Android passage book scope.

     - Side effects: Mutates this scope only; Android does not persist this toggle.
     - Failure modes: none.
     */
    mutating func toggle() {
        self = self == .scripture ? .deuterocanonical : .scripture
    }

    /// Android `deut_toggle` title localization key for the current scope.
    var androidToolbarLocalizationKey: String {
        switch self {
        case .scripture:
            return "bible"
        case .deuterocanonical:
            return "deuterocanonical"
        }
    }

    /// English fallback for Android `deut_toggle` title when no iOS localization exists.
    var androidToolbarDefaultTitle: String {
        switch self {
        case .scripture:
            return "Bible"
        case .deuterocanonical:
            return "Deuterocanonical"
        }
    }

    /**
     Checks Android scripture membership for one book.

     - Parameter book: Active module book metadata.
     - Returns: `true` when the OSIS id belongs to JSword's KJV scripture versification.
     - Side effects: none.
     - Failure modes: Unknown ids return `false`.
     */
    private static func isScripture(_ book: BookInfo) -> Bool {
        androidScriptureOsisIds.contains(book.osisId)
    }
}

/**
 Android overflow-menu actions supported by the book chooser.

 Each case corresponds to a checkable item in Android `choose_passage_book_menu.xml`. The enum is
 intentionally separate from SwiftUI `Menu` construction so tests can verify Android state
 transitions without rendering a platform menu.
 */
enum PassageChooserMenuOption: Hashable, Sendable {
    /// Toggle alphabetical sort order.
    case alphabeticalOrder

    /// Toggle left-to-right row ordering.
    case rowOrder

    /// Toggle category grouping.
    case groupByCategory

    /// Toggle uppercase short name plus long description labels.
    case showLongBookName

    /// Toggle reading/memorization progress bars.
    case showProgressBars
}

/**
 Android book-chooser overflow menu row metadata.

 Android defines the passage-chooser popup in `choose_passage_book_menu.xml`. Keeping the row order,
 localization key, and fallback title as data lets the SwiftUI surface render an Android-style menu
 without duplicating the menu contract in tests and view code.
 */
struct PassageChooserMenuEntry: Equatable, Identifiable, Sendable {
    /// Android menu action represented by this row.
    let option: PassageChooserMenuOption

    /// Localization key shared with the Android preference/menu label.
    let localizationKey: String

    /// English fallback title used when no localized string is present.
    let defaultTitle: String

    /// Stable identity for SwiftUI row rendering.
    var id: PassageChooserMenuOption {
        option
    }

    /// Android `choose_passage_book_menu.xml` row order.
    static let androidBookChooserOrder: [PassageChooserMenuEntry] = [
        PassageChooserMenuEntry(
            option: .alphabeticalOrder,
            localizationKey: "sort_by_alphabetical",
            defaultTitle: "Alphabetical order"
        ),
        PassageChooserMenuEntry(
            option: .rowOrder,
            localizationKey: "book_menu_sort_row_opt",
            defaultTitle: "Order books horizontally"
        ),
        PassageChooserMenuEntry(
            option: .groupByCategory,
            localizationKey: "book_menu_group_by_category",
            defaultTitle: "Group books by category"
        ),
        PassageChooserMenuEntry(
            option: .showLongBookName,
            localizationKey: "book_menu_show_long_book_name",
            defaultTitle: "Show long book name"
        ),
        PassageChooserMenuEntry(
            option: .showProgressBars,
            localizationKey: "book_menu_show_progress_bars",
            defaultTitle: "Show progress bars"
        ),
    ]
}

/**
 Durable passage-chooser option state mirrored from Android `book_grid_*` settings.

 Android persists these flags globally and applies additional state transitions when certain menu
 rows are tapped. In particular, category grouping forces Bible-book order and horizontal row
 order; alphabetical and row-order changes clear grouping without resetting long-name or progress
 choices.
 */
struct PassageChooserOptions: Equatable, Sendable {
    /// Android `NavigationControl.BIBLE_BOOK_SORT_ORDER` shared preference key.
    private static let bibleBookSortOrderKey = "BibleBookSortOrder"

    /// Whether books are sorted alphabetically before grid placement.
    var alphabeticalOrder: Bool

    /// Whether grid source items fill rows left-to-right instead of Android's portrait column order.
    var rowOrder: Bool

    /// Whether books are grouped by Android's broad category buckets with spacer cells between groups.
    var groupByCategory: Bool

    /// Whether book cells show Android's long-name two-line label.
    var showLongBookName: Bool

    /// Whether reading and memorization progress bars are drawn at the bottom of grid cells.
    var showProgressBars: Bool

    /// Android defaults from `GridChoosePassageBook`: row/order/category/long-name off, progress on.
    static let androidDefault = PassageChooserOptions(
        alphabeticalOrder: false,
        rowOrder: false,
        groupByCategory: false,
        showLongBookName: false,
        showProgressBars: true
    )

    /**
     Loads passage chooser options from Android parity settings.

     - Parameter settingsStore: Settings source bound to the current SwiftData context.
     - Returns: Stored chooser options or Android defaults when no values have been persisted.
     - Side effects: Reads SwiftData through `SettingsStore`.
     - Failure modes: Missing or malformed booleans fall back through `AppPreferenceRegistry`.
     */
    static func from(settingsStore: SettingsStore) -> PassageChooserOptions {
        PassageChooserOptions(
            alphabeticalOrder: settingsStore.getString(Self.bibleBookSortOrderKey) == "ALPHABETICAL",
            rowOrder: settingsStore.getBool(.bookGridLeftToRight),
            groupByCategory: settingsStore.getBool(.bookGridGroupByCategory),
            showLongBookName: settingsStore.getBool(.bookGridShowLongName),
            showProgressBars: settingsStore.getBool(.bookGridShowProgress)
        )
    }

    /**
     Applies one Android overflow-menu action to the option state.

     - Parameter option: Menu row selected by the user.
     - Side effects: Mutates this value only; persistence is handled by `persist(to:)`.
     - Failure modes: none.
     */
    mutating func apply(_ option: PassageChooserMenuOption) {
        switch option {
        case .alphabeticalOrder:
            groupByCategory = false
            alphabeticalOrder.toggle()
        case .rowOrder:
            groupByCategory = false
            rowOrder.toggle()
        case .groupByCategory:
            alphabeticalOrder = false
            rowOrder = true
            groupByCategory.toggle()
        case .showLongBookName:
            showLongBookName.toggle()
        case .showProgressBars:
            showProgressBars.toggle()
        }
    }

    /**
     Persists options through Android-compatible `book_grid_*` keys.

     Android stores alphabetical order in `NavigationControl.BIBLE_BOOK_SORT_ORDER`, while the
     other chooser flags use `book_grid_*` keys. iOS writes the same durable keys so relaunches and
     reset/import behavior are not tied to view-local state.
     - Parameter settingsStore: Store receiving the durable option values.
     - Side effects: Writes SwiftData via `SettingsStore`.
     - Failure modes: `SettingsStore` save errors are swallowed by the store.
     */
    func persist(to settingsStore: SettingsStore) {
        settingsStore.setString(
            Self.bibleBookSortOrderKey,
            value: alphabeticalOrder ? "ALPHABETICAL" : "BIBLE_BOOK"
        )
        settingsStore.setBool(.bookGridLeftToRight, value: rowOrder)
        settingsStore.setBool(.bookGridGroupByCategory, value: groupByCategory)
        settingsStore.setBool(.bookGridShowLongName, value: showLongBookName)
        settingsStore.setBool(.bookGridShowProgress, value: showProgressBars)
    }
}

/**
 Book category resolved with Android's `GridChoosePassageBook.getBookColorAndGroup` boundaries.

 The category map is not used as a canon source; the chooser still renders the module-provided
 `BookInfo` list. This type only supplies Android's color and grouping semantics for whatever books
 the active module exposes.
 */
struct PassageBookCategory: Equatable, Sendable {
    /// Android fine-grained `GroupA` id for category coloring.
    let group: Int

    /// Android broad `GroupB` id used by the grouped-grid menu option.
    let groupingBucket: Int

    /// Android category color.
    let color: PassageGridRGBColor

    /**
     Resolves the Android category for an OSIS book id.

     - Parameter osisId: OSIS identifier from `BookInfo`.
     - Returns: Android category color and group, or `.other` for unsupported/deuterocanonical ids.
     */
    static func category(forOsisId osisId: String) -> PassageBookCategory {
        switch osisId {
        case "Gen", "Exod", "Lev", "Num", "Deut":
            PassageBookCategory(group: 0, groupingBucket: 1, color: .pentateuch)
        case "Josh", "Judg", "Ruth", "1Sam", "2Sam", "1Kgs", "2Kgs", "1Chr", "2Chr", "Ezra", "Neh", "Esth":
            PassageBookCategory(group: 1, groupingBucket: 2, color: .history)
        case "Job", "Ps", "Prov", "Eccl", "Song":
            PassageBookCategory(group: 2, groupingBucket: 3, color: .wisdom)
        case "Isa", "Jer", "Lam", "Ezek", "Dan":
            PassageBookCategory(group: 3, groupingBucket: 4, color: .majorProphets)
        case "Hos", "Joel", "Amos", "Obad", "Jonah", "Mic", "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal":
            PassageBookCategory(group: 4, groupingBucket: 5, color: .minorProphets)
        case "Matt", "Mark", "Luke", "John":
            PassageBookCategory(group: 5, groupingBucket: 6, color: .gospel)
        case "Acts":
            PassageBookCategory(group: 6, groupingBucket: 6, color: .acts)
        case "Rom", "1Cor", "2Cor", "Gal", "Eph", "Phil", "Col", "1Thess", "2Thess", "1Tim", "2Tim", "Titus", "Phlm":
            PassageBookCategory(group: 7, groupingBucket: 7, color: .pauline)
        case "Heb", "Jas", "1Pet", "2Pet", "1John", "2John", "3John", "Jude":
            PassageBookCategory(group: 8, groupingBucket: 8, color: .generalEpistles)
        case "Rev":
            PassageBookCategory(group: 9, groupingBucket: 8, color: .revelation)
        default:
            PassageBookCategory(group: 10, groupingBucket: 9, color: .other)
        }
    }
}

/**
 Android JSword book-label formatter.

 Android renders `versification.getShortName(book)` in the grid, which differs from SWORD module
 abbreviations for several books (`2 Ki`, `Psa`, `Act`, `Phile`, and similar labels). Long-name
 mode uses the uppercase short name on the first line and the book description on the second line.
 */
enum PassageBookDisplayName {
    /// Source-derived JSword short names by OSIS id.
    private static let shortNamesByOsisId: [String: String] = [
        "Gen": "Gen", "Exod": "Exo", "Lev": "Lev", "Num": "Num", "Deut": "Deu",
        "Josh": "Jos", "Judg": "Judg", "Ruth": "Rut", "1Sam": "1 Sa", "2Sam": "2 Sa",
        "1Kgs": "1 Ki", "2Kgs": "2 Ki", "1Chr": "1 Ch", "2Chr": "2 Ch", "Ezra": "Ezr",
        "Neh": "Neh", "Esth": "Est", "Job": "Job", "Ps": "Psa", "Prov": "Pro",
        "Eccl": "Ecc", "Song": "Song", "Isa": "Isa", "Jer": "Jer", "Lam": "Lam",
        "Ezek": "Eze", "Dan": "Dan", "Hos": "Hos", "Joel": "Joe", "Amos": "Amo",
        "Obad": "Obd", "Jonah": "Jon", "Mic": "Mic", "Nah": "Nah", "Hab": "Hab",
        "Zeph": "Zep", "Hag": "Hag", "Zech": "Zec", "Mal": "Mal", "Matt": "Mat",
        "Mark": "Mar", "Luke": "Luk", "John": "Joh", "Acts": "Act", "Rom": "Rom",
        "1Cor": "1 Cor", "2Cor": "2 Cor", "Gal": "Gal", "Eph": "Eph", "Phil": "Phili",
        "Col": "Col", "1Thess": "1 Th", "2Thess": "2 Th", "1Tim": "1 Tim",
        "2Tim": "2 Tim", "Titus": "Tit", "Phlm": "Phile", "Heb": "Heb", "Jas": "Jam",
        "1Pet": "1 Pe", "2Pet": "2 Pe", "1John": "1 Jo", "2John": "2 Jo",
        "3John": "3 Jo", "Jude": "Jude", "Rev": "Rev",
    ]

    /**
     Returns Android's short chooser label for a book.

     - Parameter book: Module-provided book metadata.
     - Returns: JSword short name when known, otherwise the module abbreviation as a safe fallback.
     - Side effects: none.
     - Failure modes: Unknown ids fall back to `book.abbreviation`.
     */
    static func shortName(for book: BookInfo) -> String {
        shortNamesByOsisId[book.osisId] ?? book.abbreviation
    }

    /**
     Returns the visible cell title for Android short-name or long-name mode.

     - Parameters:
       - book: Module-provided book metadata.
       - showLongName: Whether Android's "Show long book name" option is enabled.
     - Returns: One-line short label or two-line uppercase-short plus book name.
     - Side effects: none.
     - Failure modes: Unknown ids still render through the fallback abbreviation.
     */
    static func title(for book: BookInfo, showLongName: Bool) -> String {
        let shortName = shortName(for: book)
        guard showLongName else {
            return shortName
        }
        return "\(shortName.uppercased())\n\(book.name)"
    }
}

/**
 Android book-ordering coordinator for the chooser grid.

 The underlying `PassageGridLayout` knows Android's row/column matrix. This helper owns the
 additional book-menu ordering options: alphabetical sorting, row ordering, and broad category
 grouping with spacer cells at group boundaries.
 */
enum PassageBookOrdering {
    /// Android grouped-grid maximum column count.
    static let groupedColumnCount = 6

    /**
     Produces visual slots for the book grid under the active Android chooser options.

     - Parameters:
       - books: Module-provided book list in Bible-book order.
       - options: Current persisted/session chooser options.
       - orientation: Current visual orientation used by Android layout rules.
       - allowsCategoryGrouping: Whether Android category grouping is allowed for this book scope.
     - Returns: Row-major visual slots, with `nil` placeholders for empty cells/spacers.
     - Side effects: none.
     - Failure modes: Empty input returns an empty array.
     */
    static func displaySlots(
        for books: [BookInfo],
        options: PassageChooserOptions,
        orientation: PassageGridOrientation,
        allowsCategoryGrouping: Bool = true
    ) -> [BookInfo?] {
        guard !books.isEmpty else {
            return []
        }

        if options.groupByCategory, allowsCategoryGrouping {
            return groupedSlots(for: books)
        }

        let sortedBooks = options.alphabeticalOrder
            ? books.sorted { lhs, rhs in
                androidAlphabeticalSortKey(lhs) < androidAlphabeticalSortKey(rhs)
            }
            : books
        let layout = PassageGridLayout.androidDefault(
            itemCount: sortedBooks.count,
            kind: .book,
            orientation: orientation,
            rowOrder: options.rowOrder
        )
        return layout.displaySlots(for: sortedBooks)
    }

    /**
     Resolves the column count the rendered grid should use for the active options.

     - Parameters:
       - itemCount: Number of source books.
       - options: Current chooser options.
       - orientation: Current visual orientation.
       - allowsCategoryGrouping: Whether Android category grouping is allowed for this book scope.
     - Returns: Android grouped-grid column count or the layout-derived count.
     - Side effects: none.
     - Failure modes: Counts below one are clamped by callers.
     */
    static func columnCount(
        itemCount: Int,
        options: PassageChooserOptions,
        orientation: PassageGridOrientation,
        allowsCategoryGrouping: Bool = true
    ) -> Int {
        if options.groupByCategory, allowsCategoryGrouping {
            return groupedColumnCount
        }
        return PassageGridLayout.androidDefault(
            itemCount: itemCount,
            kind: .book,
            orientation: orientation,
            rowOrder: options.rowOrder
        ).columns
    }

    /**
     Groups canonical books by Android `GroupB`, inserting spacer cells between groups.

     Android's `ButtonGrid.addGroupedButtons` fills rows left-to-right, starts a new row when the
     broad category changes, and pads the current row with empty cells before beginning the next
     group.
     */
    private static func groupedSlots(for books: [BookInfo]) -> [BookInfo?] {
        var slots: [BookInfo?] = []
        var currentBucket: Int?

        for book in books {
            let bucket = PassageBookCategory.category(forOsisId: book.osisId).groupingBucket
            if let currentBucket, currentBucket != bucket {
                while !slots.count.isMultiple(of: groupedColumnCount) {
                    slots.append(nil)
                }
            }
            currentBucket = bucket
            slots.append(book)
        }

        while !slots.count.isMultiple(of: groupedColumnCount) {
            slots.append(nil)
        }
        return slots
    }

    /**
     Builds Android's alphabetical comparator key.

     Android sorts by localized JSword short names and moves leading digits to the end so `1 Cor`
     sorts with Corinthians instead of before Acts. This mirrors that behavior with the current
     locale-independent short labels available to iOS.
     */
    private static func androidAlphabeticalSortKey(_ book: BookInfo) -> String {
        let name = PassageBookDisplayName.shortName(for: book).lowercased()
        let nonDigits = name
            .filter { !$0.isNumber }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = name.filter(\.isNumber)
        return nonDigits + String(digits)
    }
}

/**
 Foreground/background pair used by Android passage selector buttons.

 Book buttons use category text over testament tint unless selected. Chapter and verse buttons use
 white text over dark tint unless selected. Selected buttons use the book category as background
 with Android dark-gray text.
 */
struct PassageGridCellPalette: Equatable, Sendable {
    /// Text color for the cell label.
    let foreground: PassageGridRGBColor

    /// Fill color for the cell background.
    let background: PassageGridRGBColor

    /**
     Builds the Android palette for a book button.

     - Parameters:
       - book: Module-provided book metadata.
       - currentOsisId: Current reader book OSIS id, if available.
     - Returns: Android selected or normal book palette.
     */
    static func bookPalette(for book: BookInfo, currentOsisId: String?) -> PassageGridCellPalette {
        let category = PassageBookCategory.category(forOsisId: book.osisId)
        guard book.osisId != currentOsisId else {
            return PassageGridCellPalette(foreground: .darkGray, background: category.color)
        }
        return PassageGridCellPalette(
            foreground: category.color,
            background: book.isNewTestament ? .newTestamentTint : .oldTestamentTint
        )
    }

    /**
     Builds the Android palette for a chapter or verse button.

     - Parameters:
       - number: One-based chapter or verse number.
       - currentNumber: Current reader chapter or verse number in the selected book context.
       - categoryColor: Selected book category color.
     - Returns: Android selected or normal numeric-button palette.
     */
    static func numberPalette(
        number: Int,
        currentNumber: Int?,
        categoryColor: PassageGridRGBColor
    ) -> PassageGridCellPalette {
        guard number != currentNumber else {
            return PassageGridCellPalette(foreground: .darkGray, background: categoryColor)
        }
        return PassageGridCellPalette(foreground: .white, background: .oldTestamentTint)
    }
}

/**
 Android passage selector matrix.

 The layout mirrors Android `LayoutDesigner` and `ButtonGrid`: standard 66-book canons use a fixed
 11-by-6 portrait or 6-by-11 landscape matrix; all other counts use Android's dynamic rows and
 minimum columns. In portrait, the default ordering fills columns first unless row order is enabled.
 */
struct PassageGridLayout: Equatable, Sendable {
    /// Number of visual rows in the grid.
    let rows: Int

    /// Number of visual columns in the grid.
    let columns: Int

    /// Whether source items fill down columns before moving right.
    let usesColumnMajorOrder: Bool

    /**
     Creates Android's passage-grid layout for a selector item count.

     - Parameters:
       - itemCount: Number of module-provided books, chapters, or verses.
       - kind: Book grids get Android's fixed 66-book layout when applicable.
       - orientation: Current visual orientation of the chooser.
       - rowOrder: Android row-order preference; default `false` preserves Android's default column order.
     - Returns: Rows, columns, and ordering semantics for rendering the grid.
     */
    static func androidDefault(
        itemCount: Int,
        kind: PassageGridItemKind,
        orientation: PassageGridOrientation,
        rowOrder: Bool = false
    ) -> PassageGridLayout {
        guard itemCount > 0 else {
            return PassageGridLayout(rows: 0, columns: 0, usesColumnMajorOrder: false)
        }

        let isPortrait = orientation == .portrait
        let rows: Int
        let columns: Int

        if kind == .book, itemCount == 66 {
            rows = isPortrait ? 11 : 6
            columns = isPortrait ? 6 : 11
        } else {
            if itemCount <= 50 {
                rows = isPortrait ? 10 : 5
            } else if itemCount <= 100 {
                rows = 10
            } else {
                rows = isPortrait ? 15 : 10
            }
            let calculatedColumns = Int(ceil(Double(itemCount) / Double(rows)))
            columns = max(isPortrait ? 5 : 8, calculatedColumns)
        }

        return PassageGridLayout(
            rows: rows,
            columns: columns,
            usesColumnMajorOrder: isPortrait && !rowOrder
        )
    }

    /**
     Converts source items into the visual slot order used by SwiftUI `LazyVGrid`.

     SwiftUI fills rows first, so this method precomputes visual slots from Android's source index
     calculation and includes `nil` placeholders for unused matrix cells.
     */
    func displaySlots<Item>(for items: [Item]) -> [Item?] {
        guard rows > 0, columns > 0 else {
            return []
        }

        return (0..<(rows * columns)).map { slot in
            let row = slot / columns
            let column = slot % columns
            let sourceIndex: Int
            if usesColumnMajorOrder {
                sourceIndex = column * rows + row
            } else {
                sourceIndex = row * columns + column
            }
            guard sourceIndex < items.count else {
                return nil
            }
            return items[sourceIndex]
        }
    }
}

/**
 Android-compatible sizing metrics for passage selector cells.

 Android `ButtonGrid` gives each table row and each cell equal weight, so a visible cell occupies
 the same width and height inside the calculated matrix. SwiftUI grids do not infer that contract
 from row/column counts, so callers use this value object to derive a fixed square side from the
 available drawer or sheet width.
 */
struct PassageGridMetrics: Equatable, Sendable {
    /// Width and height for every rendered grid cell.
    let cellSide: CGFloat

    /// Total width occupied by all fixed-width columns and inter-column spacing.
    let gridWidth: CGFloat

    /// Android-compatible spacing between cells.
    static let spacing: CGFloat = 4

    /// Horizontal inset around the grid, matching the existing selector padding.
    static let horizontalPadding: CGFloat = 12

    /**
     Derives fixed square cell dimensions from an available container width.

     - Parameters:
       - availableWidth: Width available to the selector content before grid padding is applied.
       - columns: Android layout column count. Values below one are clamped to one.
       - spacing: Space between neighboring cells.
       - horizontalPadding: Leading and trailing padding reserved around the grid.
     - Returns: Square cell side and total grid width. Widths clamp at zero when the container is
       too small, so SwiftUI never receives negative frame dimensions.
     */
    static func squareCells(
        availableWidth: CGFloat,
        columns: Int,
        spacing: CGFloat = Self.spacing,
        horizontalPadding: CGFloat = Self.horizontalPadding
    ) -> PassageGridMetrics {
        let columnCount = max(columns, 1)
        let availableGridWidth = max(0, availableWidth - (horizontalPadding * 2))
        let totalSpacing = spacing * CGFloat(max(columnCount - 1, 0))
        let cellSide = max(0, (availableGridWidth - totalSpacing) / CGFloat(columnCount))
        let gridWidth = (cellSide * CGFloat(columnCount)) + totalSpacing

        return PassageGridMetrics(cellSide: cellSide, gridWidth: gridWidth)
    }
}

/**
 Android passage-grid progress fractions for one cell.

 Android overlays reading progress in green and memorization progress in gold at the bottom of
 book, chapter, and verse buttons. This value carries normalized fractions only; rendering remains
 in `PassageGridButton` so tests can verify progress semantics without a UI surface.
 */
public struct PassageGridProgress: Equatable, Sendable {
    /// Fraction of reading progress in `0...1`.
    public let readingFraction: Double

    /// Fraction of memorization progress in `0...1`.
    public let memorizationFraction: Double

    /// Android reading progress bar color without alpha.
    public static let readingColor = PassageGridRGBColor(red: 0x4C, green: 0xAF, blue: 0x50)

    /// Android memorization progress bar color without alpha.
    public static let memorizationColor = PassageGridRGBColor(red: 0xFF, green: 0xD7, blue: 0x00)

    /// Empty progress state used when progress bars are disabled or unavailable.
    public static let none = PassageGridProgress(readingFraction: 0, memorizationFraction: 0)

    /**
     Creates clamped progress fractions.

     - Parameters:
       - readingFraction: Raw reading fraction; values outside `0...1` are clamped.
       - memorizationFraction: Raw memorization fraction; values outside `0...1` are clamped.
     - Returns: Normalized progress state.
     - Side effects: none.
     - Failure modes: Non-finite values are treated as zero.
     */
    public init(readingFraction: Double = 0, memorizationFraction: Double = 0) {
        self.readingFraction = Self.clamped(readingFraction)
        self.memorizationFraction = Self.clamped(memorizationFraction)
    }

    /// Whether either Android progress bar should be visible.
    var hasProgress: Bool {
        readingFraction > 0 || memorizationFraction > 0
    }

    /**
     Clamps a raw fraction into Android progress-bar bounds.

     - Parameter value: Candidate fraction.
     - Returns: A finite value in `0...1`.
     - Side effects: none.
     - Failure modes: Non-finite values return zero.
     */
    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else {
            return 0
        }
        return min(1, max(0, value))
    }
}

/**
 Android KJVA-backed progress calculator for passage-grid cells.

 `ProgressControl` on Android normalizes reading progress by JSword `BibleBook.ordinal()` and
 memorization progress by JSword KJVA verse ordinals. This calculator mirrors those rules against
 the iOS snapshots so rendered bars are not decorative or tied to SWORD's separate address space.
 */
enum PassageGridProgressCalculator {
    /**
     Computes book-level reading and memorization progress.

     - Parameters:
       - book: Module-provided book metadata.
       - readingSnapshot: Current reading progress snapshot, if available.
       - memorizationSnapshot: Current memorization progress snapshot, if available.
       - activeBookInitials: Active module initials used to match module-scoped memorization rows.
     - Returns: Android-compatible progress fractions for the book cell.
     - Side effects: none.
     - Failure modes: Unsupported books return `.none`.
     */
    static func bookProgress(
        book: BookInfo,
        readingSnapshot: ReadingProgressSnapshot?,
        memorizationSnapshot: MemorizationProgressSnapshot?,
        activeBookInitials: String
    ) -> PassageGridProgress {
        guard let kjvBookOrdinal = JSwordKJVAVersification.bibleBookOrdinal(forOsisId: book.osisId),
              let chapterCount = JSwordKJVAVersification.lastChapter(osisId: book.osisId),
              let verseCount = JSwordKJVAVersification.bookVerseCount(osisId: book.osisId),
              let bookRange = JSwordKJVAVersification.verseOrdinalRange(osisId: book.osisId) else {
            return .none
        }

        let readingFraction: Double
        if let readingSnapshot, chapterCount > 0 {
            let cycle = currentReadingCycle(in: readingSnapshot)
            var readChapters = Set<Int>()
            for row in readingSnapshot.history
                where row.kjvBookOrdinal == kjvBookOrdinal &&
                row.cycle == cycle &&
                row.chapter > 0 &&
                row.chapter <= chapterCount {
                readChapters.insert(row.chapter)
            }
            readingFraction = Double(readChapters.count) / Double(chapterCount)
        } else {
            readingFraction = 0
        }

        let memorizationFraction = fractionOfMemorizedOrdinals(
            in: bookRange,
            verseCount: verseCount,
            snapshot: memorizationSnapshot,
            activeBookInitials: activeBookInitials
        )
        return PassageGridProgress(
            readingFraction: readingFraction,
            memorizationFraction: memorizationFraction
        )
    }

    /**
     Computes chapter-level reading and memorization progress.

     Android marks a chapter as fully read when the active reading cycle has at least one matching
     row and divides memorized ordinals by the KJVA verse count in that chapter.
     */
    static func chapterProgress(
        book: BookInfo,
        chapter: Int,
        readingSnapshot: ReadingProgressSnapshot?,
        memorizationSnapshot: MemorizationProgressSnapshot?,
        activeBookInitials: String
    ) -> PassageGridProgress {
        guard let kjvBookOrdinal = JSwordKJVAVersification.bibleBookOrdinal(forOsisId: book.osisId),
              let verseCount = JSwordKJVAVersification.verseCount(osisId: book.osisId, chapter: chapter),
              let chapterRange = JSwordKJVAVersification.verseOrdinalRange(osisId: book.osisId, chapter: chapter) else {
            return .none
        }

        let readingFraction: Double
        if let readingSnapshot {
            let cycle = currentReadingCycle(in: readingSnapshot)
            readingFraction = readingSnapshot.history.contains { row in
                row.kjvBookOrdinal == kjvBookOrdinal &&
                    row.chapter == chapter &&
                    row.cycle == cycle
            } ? 1 : 0
        } else {
            readingFraction = 0
        }

        let memorizationFraction = fractionOfMemorizedOrdinals(
            in: chapterRange,
            verseCount: verseCount,
            snapshot: memorizationSnapshot,
            activeBookInitials: activeBookInitials
        )
        return PassageGridProgress(
            readingFraction: readingFraction,
            memorizationFraction: memorizationFraction
        )
    }

    /**
     Computes verse-level reading and memorization progress.

     Android shows a full reading bar for every verse in a read chapter and a full memorization bar
     when the exact KJVA verse ordinal is present in memorized ranges.
     */
    static func verseProgress(
        book: BookInfo,
        chapter: Int,
        verse: Int,
        readingSnapshot: ReadingProgressSnapshot?,
        memorizationSnapshot: MemorizationProgressSnapshot?,
        activeBookInitials: String
    ) -> PassageGridProgress {
        guard let kjvBookOrdinal = JSwordKJVAVersification.bibleBookOrdinal(forOsisId: book.osisId),
              let ordinal = JSwordKJVAVersification.verseOrdinal(
                osisId: book.osisId,
                chapter: chapter,
                verse: verse
              ) else {
            return .none
        }

        let readingFraction: Double
        if let readingSnapshot {
            let cycle = currentReadingCycle(in: readingSnapshot)
            readingFraction = readingSnapshot.history.contains { row in
                row.kjvBookOrdinal == kjvBookOrdinal &&
                    row.chapter == chapter &&
                    row.cycle == cycle
            } ? 1 : 0
        } else {
            readingFraction = 0
        }

        let memorizationFraction = memorizedOrdinalCount(
            in: ordinal...ordinal,
            snapshot: memorizationSnapshot,
            activeBookInitials: activeBookInitials
        ) > 0 ? 1.0 : 0.0
        return PassageGridProgress(
            readingFraction: readingFraction,
            memorizationFraction: memorizationFraction
        )
    }

    /**
     Resolves Android's active reading cycle fallback.

     - Parameter snapshot: Reading progress snapshot.
     - Returns: Explicit active cycle when set; otherwise the latest stored cycle or Android's `1`.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func currentReadingCycle(in snapshot: ReadingProgressSnapshot) -> Int {
        if snapshot.settings.activeCycle > 0 {
            return snapshot.settings.activeCycle
        }
        return snapshot.history.map(\.cycle).max() ?? 1
    }

    /**
     Converts memorized ordinal membership into a normalized progress fraction.

     - Parameters:
       - range: KJVA verse ordinal range being measured.
       - verseCount: Number of real verses represented by the range.
       - snapshot: Current memorization snapshot.
       - activeBookInitials: Module initials used for module-scoped ranges.
     - Returns: Memorized count divided by `verseCount`.
     - Side effects: none.
     - Failure modes: Missing snapshots or invalid counts return zero.
     */
    private static func fractionOfMemorizedOrdinals(
        in range: ClosedRange<Int>,
        verseCount: Int,
        snapshot: MemorizationProgressSnapshot?,
        activeBookInitials: String
    ) -> Double {
        guard verseCount > 0 else {
            return 0
        }
        return Double(
            memorizedOrdinalCount(
                in: range,
                snapshot: snapshot,
                activeBookInitials: activeBookInitials
            )
        ) / Double(verseCount)
    }

    /**
     Counts unique memorized KJVA ordinals that intersect a query range.

     Android imports can store module-neutral ranges, while existing iOS bridge writes are
     module-scoped. Matching accepts both empty `bookInitials` and the active module initials.
     */
    private static func memorizedOrdinalCount(
        in queryRange: ClosedRange<Int>,
        snapshot: MemorizationProgressSnapshot?,
        activeBookInitials: String
    ) -> Int {
        guard let snapshot else {
            return 0
        }

        var intersections: [ClosedRange<Int>] = []
        for range in snapshot.memorizedRanges where matches(range, activeBookInitials: activeBookInitials) {
            let start = max(range.startOrdinal, queryRange.lowerBound)
            let end = min(range.endOrdinal, queryRange.upperBound)
            guard start <= end else {
                continue
            }
            intersections.append(start...end)
        }
        return mergedOrdinalCount(in: intersections)
    }

    /**
     Counts unique ordinals represented by possibly overlapping or adjacent ranges.

     Android stores memorized passages as ranges, so progress can be counted from merged intervals
     without allocating one value per verse ordinal. Adjacent ranges are merged because their covered
     ordinal count is equivalent and avoids unnecessary segment churn.
    */
    private static func mergedOrdinalCount(in ranges: [ClosedRange<Int>]) -> Int {
        let sortedRanges = ranges.sorted(by: { $0.lowerBound < $1.lowerBound })
        guard let first = sortedRanges.first else {
            return 0
        }

        var count = 0
        var currentStart = first.lowerBound
        var currentEnd = first.upperBound

        for range in sortedRanges.dropFirst() {
            if range.lowerBound <= currentEnd + 1 {
                currentEnd = max(currentEnd, range.upperBound)
            } else {
                count += currentEnd - currentStart + 1
                currentStart = range.lowerBound
                currentEnd = range.upperBound
            }
        }

        return count + currentEnd - currentStart + 1
    }

    /**
     Checks whether a stored memorization range applies to the active module.

     - Parameters:
       - range: Persisted memorization range.
       - activeBookInitials: Active module initials.
     - Returns: `true` for Android-imported module-neutral ranges and matching module-scoped rows.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func matches(_ range: MemorizationProgressRange, activeBookInitials: String) -> Bool {
        range.bookInitials.isEmpty || range.bookInitials == activeBookInitials
    }
}

/**
 Android-compatible title formatting for the passage chooser.

 `GridChoosePassageBook` appends `SharedActivityState.currentWorkspaceName` to the activity title,
 while chapter and verse steps use the selected book/chapter titles. Keeping the formatter separate
 from SwiftUI view state makes the Android parity rule testable without rendering a navigation bar.
 */
enum PassageChooserTitle {
    /**
     Builds the book-selection title used for the first chooser step.

     - Parameters:
       - baseTitle: Localized base title, usually Android/iOS "Choose Book".
       - workspaceName: Active workspace name. Whitespace-only values are ignored.
     - Returns: `baseTitle (workspaceName)` when a workspace is known, otherwise `baseTitle`.
     */
    static func bookSelectionTitle(baseTitle: String, workspaceName: String?) -> String {
        guard let workspaceName = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspaceName.isEmpty else {
            return baseTitle
        }

        return "\(baseTitle) (\(workspaceName))"
    }
}

/**
 Shared passage-grid button with Android colors and stable accessibility metadata.

 The view is deliberately plain like Android's selector buttons; it avoids platform-specific card
 styling while using a fixed square frame derived from Android's row/column matrix so book,
 chapter, and verse cells do not drift into iOS-specific rectangular controls.
 */
struct PassageGridButton: View {
    /// Visible label rendered in the button.
    let title: String

    /// Accessibility label announced for the button.
    let accessibilityLabel: String

    /// Stable UI-test identifier for this button.
    let accessibilityIdentifier: String

    /// Android foreground/background colors.
    let palette: PassageGridCellPalette

    /// Label font tuned by selector type.
    let font: Font

    /// Android reading/memorization progress fractions for this cell.
    let progress: PassageGridProgress

    /// Fixed square width and height for the button.
    let cellSide: CGFloat

    /// Action invoked when the button is tapped.
    let action: () -> Void

    /**
     Creates a fixed-size Android passage-grid button.

     - Parameters:
       - title: Visible text, either one-line short label or two-line long-name label.
       - accessibilityLabel: VoiceOver label for the represented book/chapter/verse.
       - accessibilityIdentifier: Stable UI-test identifier.
       - palette: Android foreground/background colors.
       - font: Text style for the selector type.
       - progress: Optional Android reading/memorization progress overlays.
       - cellSide: Fixed square side derived from the Android grid matrix.
       - action: Tap handler.
     - Side effects: none; the action is invoked only when the button is tapped.
     - Failure modes: none.
     */
    init(
        title: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        palette: PassageGridCellPalette,
        font: Font,
        progress: PassageGridProgress = .none,
        cellSide: CGFloat,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.palette = palette
        self.font = font
        self.progress = progress
        self.cellSide = cellSide
        self.action = action
    }

    /// Renders the Android-style selector button.
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(palette.background.swiftUIColor)

                if progress.hasProgress {
                    progressBars
                }

                Text(title)
                    .font(font)
                    .lineLimit(title.contains("\n") ? 2 : 1)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.55)
                    .padding(.horizontal, 2)
                    .frame(width: cellSide, height: cellSide)
                    .foregroundStyle(palette.foreground.swiftUIColor)
            }
            .frame(width: cellSide, height: cellSide)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /// Android-style progress overlays anchored to the bottom of the button cell.
    @ViewBuilder
    private var progressBars: some View {
        let barHeight: CGFloat = 4
        let gap: CGFloat = 3

        if progress.memorizationFraction > 0 {
            Rectangle()
                .fill(PassageGridProgress.memorizationColor.swiftUIColor.opacity(0.8))
                .frame(width: cellSide * progress.memorizationFraction, height: barHeight)
        }

        if progress.readingFraction > 0 {
            Rectangle()
                .fill(PassageGridProgress.readingColor.swiftUIColor.opacity(0.8))
                .frame(width: cellSide * progress.readingFraction, height: barHeight)
                .padding(.bottom, progress.memorizationFraction > 0 ? barHeight + gap : 0)
        }
    }
}
