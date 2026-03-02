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
    case unknown = "Unknown"

    public init(typeString: String) {
        self = ModuleCategory(rawValue: typeString) ?? .unknown
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

/// Information about a single book in a Bible module's versification.
///
/// Contains the book name, OSIS abbreviation, display abbreviation,
/// chapter count, and testament (OT/NT). Used by the book chooser and
/// chapter navigation to dynamically adapt to the active module's canon.
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
