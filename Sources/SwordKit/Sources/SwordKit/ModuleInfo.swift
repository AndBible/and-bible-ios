// ModuleInfo.swift — Module metadata types for SwordKit

import Foundation

/// Category of a SWORD module.
public enum ModuleCategory: String, Sendable, Codable {
    case bible = "Biblical Texts"
    case commentary = "Commentaries"
    case dictionary = "Lexicons / Dictionaries"
    case generalBook = "Generic Books"
    case map = "Maps"
    case dailyDevotion = "Daily Devotional"
    case glossary = "Glossaries"
    /// Android/JSword add-on modules that provide fonts, features, styles, prompts, or similar app data.
    case addon = "And Bible"
    case unknown = "Unknown"

    /**
     Resolves a module category from SWORD/JSword metadata.

     Android registers several non-SWORD book drivers, such as `MyBibleDictionary`, as normal
     JSword `BookType`s. Their book category comes from the driver, not from an optional
     `Category=` line in the generated `.conf`. iOS mirrors that by accepting the driver name when
     callers have it, then falling back to SWORD category strings and legacy driver inference.

     - Parameters:
       - typeString: Raw SWORD/JSword category string, for example `Lexicons / Dictionaries`.
       - modDrv: Raw `ModDrv` value from the module config when available.
     - Returns: Android/JSword-compatible module category.
     - Side effects: none.
     - Failure modes: Unknown category and driver combinations return `.unknown`.
     */
    public init(typeString: String, modDrv: String = "") {
        self = Self.resolved(typeString: typeString, modDrv: modDrv)
    }

    /**
     Resolves Android-supported custom drivers and SWORD metadata into a module category.

     - Parameters:
       - typeString: Raw `Category`/type value.
       - modDrv: Raw module driver.
     - Returns: The category Android would expose for the same installed book metadata.
     - Side effects: none.
     - Failure modes: Unsupported drivers with missing category metadata resolve to `.unknown`.
     */
    public static func resolved(typeString: String, modDrv: String = "") -> ModuleCategory {
        if let driverCategory = androidDriverCategory(modDrv) {
            return driverCategory
        }

        if let explicitCategory = ModuleCategory(rawValue: typeString),
           explicitCategory != .unknown {
            return explicitCategory
        }

        return inferredFromDriver(modDrv)
    }

    /**
     Maps Android-registered custom JSword book drivers to their durable book categories.

     - Parameter modDrv: Raw `ModDrv` value from the module config.
     - Returns: Category owned by the Android `BookType`, or `nil` for normal SWORD drivers.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func androidDriverCategory(_ modDrv: String) -> ModuleCategory? {
        switch modDrv.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mybiblebible", "myswordbible", "eswordbible":
            return .bible
        case "mybiblecommentary", "myswordcommentary":
            return .commentary
        case "mybibledictionary", "mysworddictionary":
            return .dictionary
        case "epubbook":
            return .generalBook
        default:
            return nil
        }
    }

    /**
     Infers a category for catalog rows that omit `Category=`.

     - Parameter modDrv: Raw SWORD driver value.
     - Returns: Best-effort SWORD category, or `.unknown` when no Android/SWORD rule applies.
     - Side effects: none.
     - Failure modes: unknown drivers return `.unknown` instead of guessing a reader category.
     */
    private static func inferredFromDriver(_ modDrv: String) -> ModuleCategory {
        let driver = modDrv.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if driver.contains("genbook") {
            return .generalBook
        }
        if driver.contains("text") {
            return .bible
        }
        if driver.contains("com") {
            return .commentary
        }
        if driver.contains("ld") {
            return .dictionary
        }
        return .unknown
    }
}

/// Features a SWORD module may support.
public struct ModuleFeatures: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let strongsNumbers = ModuleFeatures(rawValue: 1 << 0)
    public static let morphology = ModuleFeatures(rawValue: 1 << 1)
    public static let footnotes = ModuleFeatures(rawValue: 1 << 2)
    public static let headings = ModuleFeatures(rawValue: 1 << 3)
    public static let redLetterWords = ModuleFeatures(rawValue: 1 << 4)
    public static let greekDef = ModuleFeatures(rawValue: 1 << 5)
    public static let hebrewDef = ModuleFeatures(rawValue: 1 << 6)
    public static let greekParse = ModuleFeatures(rawValue: 1 << 7)
    public static let hebrewParse = ModuleFeatures(rawValue: 1 << 8)
    public static let dailyDevotion = ModuleFeatures(rawValue: 1 << 9)
}

extension ModuleFeatures {
    /**
     Builds a feature set from SWORD/JSword config values.

     SWORD configs can repeat `Feature=` and `GlobalOptionFilter=` lines. Android and JSword treat
     those values as a combined feature list, so callers pass every value collected from the config
     parser rather than only the first value.

     - Parameter values: Raw feature/filter config values.
     - Returns: Combined module feature flags.
     - Side effects: none.
     - Failure modes: Unknown feature names are ignored.
     */
    static func fromConfigValues(_ values: [String]) -> ModuleFeatures {
        var features: ModuleFeatures = []
        for value in values {
            features.insertConfigValue(value)
        }
        return features
    }

    /**
     Adds feature flags represented by one config value.

     - Parameter value: A raw `Feature` or `GlobalOptionFilter` value.
     - Side effects: Mutates this option set.
     - Failure modes: Unknown feature values do not mutate the set.
     */
    mutating func insertConfigValue(_ value: String) {
        if value.contains("Strongs") || value.contains("OSISStrongs") {
            insert(.strongsNumbers)
        }
        if value.contains("Morphology") || value.contains("OSISMorph") {
            insert(.morphology)
        }
        if value.contains("Footnotes") || value.contains("OSISFootnotes") {
            insert(.footnotes)
        }
        if value.contains("Headings") || value.contains("OSISHeadings") {
            insert(.headings)
        }
        if value.contains("RedLetterWords") || value.contains("OSISRedLetterWords") {
            insert(.redLetterWords)
        }
        if value.contains("GreekDef") { insert(.greekDef) }
        if value.contains("HebrewDef") { insert(.hebrewDef) }
        if value.contains("GreekParse") { insert(.greekParse) }
        if value.contains("HebrewParse") { insert(.hebrewParse) }
        if value.contains("DailyDevotion") { insert(.dailyDevotion) }
    }
}

/**
 Information about a single book in a Bible module's versification.

 Contains the book name, OSIS abbreviation, display abbreviation,
 chapter count, and testament (OT/NT). Used by the book chooser and
 chapter navigation to dynamically adapt to the active module's canon.
 */
public struct BookInfo: Sendable, Identifiable, Equatable {
    /// Unique identifier (uses the OSIS book ID).
    public var id: String { osisId }

    /// Full book name as reported by SWORD (e.g., "Genesis", "1 Corinthians", "Tobit").
    public let name: String

    /// OSIS book abbreviation used in verse keys (e.g., "Gen", "1Cor", "Tob").
    public let osisId: String

    /// Short abbreviation for compact display (e.g., "Gen", "1Cor").
    public let abbreviation: String

    /// Number of chapters in this book.
    public let chapterCount: Int

    /// Testament number: 1 = Old Testament, 2 = New Testament.
    public let testament: Int

    /// Whether this book is in the New Testament.
    public var isNewTestament: Bool { testament == 2 }

    public init(name: String, osisId: String, abbreviation: String, chapterCount: Int, testament: Int) {
        self.name = name
        self.osisId = osisId
        self.abbreviation = abbreviation
        self.chapterCount = chapterCount
        self.testament = testament
    }
}

/// Metadata about a SWORD module (installed or remote).
public struct ModuleInfo: Sendable, Identifiable {
    /// Module abbreviation (e.g., "KJV", "ESV").
    public let name: String

    /// Full module description (e.g., "King James Version").
    public let description: String

    /// Module category.
    public let category: ModuleCategory

    /// ISO language code (e.g., "en", "el").
    public let language: String

    /// Module version string.
    public let version: String

    /// Whether the module requires a cipher key.
    public let isEncrypted: Bool

    /// Whether the module is currently unlocked.
    public let isUnlocked: Bool

    /// Supported features.
    public let features: ModuleFeatures

    /// Module text direction.
    public let isRightToLeft: Bool

    /// Unique identifier (uses module name).
    public var id: String { name }

    public init(
        name: String,
        description: String,
        category: ModuleCategory,
        language: String,
        version: String = "",
        isEncrypted: Bool = false,
        isUnlocked: Bool = true,
        features: ModuleFeatures = [],
        isRightToLeft: Bool = false
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.language = language
        self.version = version
        self.isEncrypted = isEncrypted
        self.isUnlocked = isUnlocked
        self.features = features
        self.isRightToLeft = isRightToLeft
    }
}
