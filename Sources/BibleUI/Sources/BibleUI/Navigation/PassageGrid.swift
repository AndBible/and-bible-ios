// PassageGrid.swift - Android-aligned passage selector layout and palette

import SwiftUI
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
struct PassageGridRGBColor: Equatable, Sendable {
    /// Red component in the Android 0...255 range.
    let red: Int

    /// Green component in the Android 0...255 range.
    let green: Int

    /// Blue component in the Android 0...255 range.
    let blue: Int

    /// SwiftUI color used by the rendered selector cell.
    var swiftUIColor: Color {
        Color(
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0
        )
    }

    /// Android `Color.DKGRAY`.
    static let darkGray = PassageGridRGBColor(red: 0x44, green: 0x44, blue: 0x44)

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
}

/**
 Book category resolved with Android's `GridChoosePassageBook.getBookColorAndGroup` boundaries.

 The category map is not used as a canon source; the chooser still renders the module-provided
 `BookInfo` list. This type only supplies Android's color and grouping semantics for whatever books
 the active module exposes.
 */
struct PassageBookCategory: Equatable, Sendable {
    /// Android group id for category sorting and future option support.
    let group: Int

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
            PassageBookCategory(group: 0, color: .pentateuch)
        case "Josh", "Judg", "Ruth", "1Sam", "2Sam", "1Kgs", "2Kgs", "1Chr", "2Chr", "Ezra", "Neh", "Esth":
            PassageBookCategory(group: 1, color: .history)
        case "Job", "Ps", "Prov", "Eccl", "Song":
            PassageBookCategory(group: 2, color: .wisdom)
        case "Isa", "Jer", "Lam", "Ezek", "Dan":
            PassageBookCategory(group: 3, color: .majorProphets)
        case "Hos", "Joel", "Amos", "Obad", "Jonah", "Mic", "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal":
            PassageBookCategory(group: 4, color: .minorProphets)
        case "Matt", "Mark", "Luke", "John":
            PassageBookCategory(group: 5, color: .gospel)
        case "Acts":
            PassageBookCategory(group: 6, color: .acts)
        case "Rom", "1Cor", "2Cor", "Gal", "Eph", "Phil", "Col", "1Thess", "2Thess", "1Tim", "2Tim", "Titus", "Phlm":
            PassageBookCategory(group: 7, color: .pauline)
        case "Heb", "Jas", "1Pet", "2Pet", "1John", "2John", "3John", "Jude":
            PassageBookCategory(group: 8, color: .generalEpistles)
        case "Rev":
            PassageBookCategory(group: 9, color: .revelation)
        default:
            PassageBookCategory(group: 10, color: .other)
        }
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
 Shared passage-grid button with Android colors and stable accessibility metadata.

 The view is deliberately small and rectangular like Android's selector buttons; it avoids
 platform-specific card styling while still using SwiftUI text sizing to keep abbreviations and
 numbers readable across compact iPhone and iPad sheet sizes.
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

    /// Minimum button height in points.
    let minHeight: CGFloat

    /// Action invoked when the button is tapped.
    let action: () -> Void

    /// Renders the Android-style selector button.
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, minHeight: minHeight)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(palette.background.swiftUIColor)
                )
                .foregroundStyle(palette.foreground.swiftUIColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
