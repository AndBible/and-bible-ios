// ModuleInfo.swift — Module metadata types for SwordKit

import Foundation

/**
 Category of a SWORD/JSword installed book.

 Raw values are the config strings parsed by `SwordBookMetaData`; cases include every pinned
 `BookCategory` that can own a feature-bearing dictionary/general-book backend. Consumers must use
 the actual explicit category for payload metadata and installed-book ordering rather than infer a
 category from `ModDrv` when a recognized `Category=` value exists.

 - Side effects: Category parsing loads the pinned Android Java case-fold table.
 - Failure modes: Unrecognized category/driver combinations resolve to `.unknown`.
 */
public enum ModuleCategory: String, Sendable, Codable {
    case bible = "Biblical Texts"
    case commentary = "Commentaries"
    case dictionary = "Lexicons / Dictionaries"
    case generalBook = "Generic Books"
    case map = "Maps"
    case dailyDevotion = "Daily Devotional"
    case glossary = "Glossaries"
    case questionable = "Cults / Unorthodox / Questionable Material"
    case essays = "Essays"
    case images = "Images"
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
     - Side effects: Loads the pinned Android Java case-fold table for explicit category matching.
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
     - Side effects: Loads the pinned Android Java case-fold table for explicit category matching.
     - Failure modes: Unsupported drivers with missing category metadata resolve to `.unknown`.
     */
    public static func resolved(typeString: String, modDrv: String = "") -> ModuleCategory {
        if let driverCategory = androidDriverCategory(modDrv) {
            return driverCategory
        }

        let explicitCategories: [ModuleCategory] = [
            .bible,
            .commentary,
            .dictionary,
            .generalBook,
            .map,
            .dailyDevotion,
            .glossary,
            .questionable,
            .essays,
            .images,
            .addon,
        ]
        if let explicitCategory = explicitCategories.first(where: {
            SwordJavaStringIdentity.equalsIgnoreCase($0.rawValue, typeString)
        }) {
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

/**
 Android-compatible metadata used by module About dialogs.

 Android reloads `SwordBookMetaData` before opening `CommonUtils.showAbout(...)` and reads these
 optional config fields from the installed document. iOS carries the same values alongside
 `ModuleInfo` so UI code can render real metadata and omit unavailable fields instead of inventing
 Downloads-only substitutes.

 Side effects:
 - none; this is an immutable value type

 Failure modes:
 - none; missing metadata is represented by empty strings or an empty history array
 */
public struct ModuleAboutMetadata: Sendable, Equatable {
    /// Raw SWORD `About` text.
    public let about: String

    /// SWORD `ShortPromo` text.
    public let shortPromo: String

    /// SWORD `ShortCopyright` text.
    public let shortCopyright: String

    /// SWORD `Copyright` text.
    public let copyright: String

    /// SWORD `DistributionLicense` text.
    public let distributionLicense: String

    /// SWORD `UnlockInfo` text for encrypted modules.
    public let unlockInfo: String

    /// JSword-style `History` values, preserving config order.
    public let history: [String]

    /// SWORD versification name.
    public let versification: String

    /// OSIS/module identifier shown by Android About.
    public let osisId: String

    /// Distribution repository/source name when known.
    public let repository: String

    /// Whether Android metadata marks this as a bad document.
    public let isBadDocument: Bool

    /// SWORD `SwordVersionDate` value.
    public let swordVersionDate: String

    /**
     Creates an About metadata value.

     - Parameters:
       - about: Raw SWORD `About` text.
       - shortPromo: SWORD `ShortPromo` text.
       - shortCopyright: SWORD `ShortCopyright` text.
       - copyright: SWORD `Copyright` text.
       - distributionLicense: SWORD `DistributionLicense` text.
       - unlockInfo: SWORD `UnlockInfo` text.
       - history: JSword-style version history values in config order.
       - versification: SWORD versification name.
       - osisId: OSIS/module identifier.
       - repository: Distribution repository/source name.
       - isBadDocument: Whether Android should show the bad-document warning.
       - swordVersionDate: SWORD version date value.
     - Side effects: none.
     - Failure modes: none.
     */
    public init(
        about: String = "",
        shortPromo: String = "",
        shortCopyright: String = "",
        copyright: String = "",
        distributionLicense: String = "",
        unlockInfo: String = "",
        history: [String] = [],
        versification: String = "",
        osisId: String = "",
        repository: String = "",
        isBadDocument: Bool = false,
        swordVersionDate: String = ""
    ) {
        self.about = about
        self.shortPromo = shortPromo
        self.shortCopyright = shortCopyright
        self.copyright = copyright
        self.distributionLicense = distributionLicense
        self.unlockInfo = unlockInfo
        self.history = history
        self.versification = versification
        self.osisId = osisId
        self.repository = repository
        self.isBadDocument = isBadDocument
        self.swordVersionDate = swordVersionDate
    }

    /**
     Applies honest fallback identifiers to metadata that came from a smaller source.

     Module sidecars and test fixtures can omit OSIS ID or repository while the caller still knows those
     values from the selected installed or remote row. This method fills only blank values and preserves
     all source-backed fields.

     - Parameters:
       - fallbackOsisId: Module initials to use when `osisId` is blank.
       - fallbackRepository: Repository/source name to use when `repository` is blank.
     - Returns: Metadata with missing identifier fields filled.
     - Side effects: none.
     - Failure modes: none.
     */
    public func withFallbacks(
        osisId fallbackOsisId: String,
        repository fallbackRepository: String? = nil
    ) -> ModuleAboutMetadata {
        ModuleAboutMetadata(
            about: about,
            shortPromo: shortPromo,
            shortCopyright: shortCopyright,
            copyright: copyright,
            distributionLicense: distributionLicense,
            unlockInfo: unlockInfo,
            history: history,
            versification: versification,
            osisId: Self.nonEmpty(osisId) ?? fallbackOsisId,
            repository: Self.nonEmpty(repository) ?? Self.nonEmpty(fallbackRepository) ?? "",
            isBadDocument: isBadDocument,
            swordVersionDate: swordVersionDate
        )
    }

    /**
     Trims optional metadata text before fallback decisions.

     - Parameter value: Optional raw metadata text.
     - Returns: Trimmed non-empty text, otherwise `nil`.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
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
        if value.contains("RedLetterWords") || value.contains("OSISRedLetterWords")
            || value.contains("WordsOfChrist") {
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

/**
 Metadata about one installed or remote SWORD-compatible module.

 The value deliberately has no raw-`String` `Identifiable` conformance: callers at module-identity
 boundaries must use `SwordJavaExactStringIdentity` or a repository-scoped typed identity so Swift
 canonical Unicode equality cannot merge books that Java keeps distinct. Construction retains
 metadata only, performs no I/O, and does not fail; unsupported metadata remains diagnosable through
 `isSupported` rather than being discarded here.
 */
public struct ModuleInfo: Sendable {
    /// Case-insensitive SWORD/Android `ModDrv` names registered by Android at application startup.
    private static let androidSupportedModuleDrivers: Set<String> = [
        "rawtext", "ztext", "ztext4",
        "rawcom", "rawcom4", "zcom", "zcom4", "hrefcom", "rawfiles",
        "rawld", "rawld4", "zld", "rawgenbook",
        "mybiblebible", "mybiblecommentary", "mybibledictionary",
        "myswordbible", "myswordcommentary", "mysworddictionary",
        "epubbook", "eswordbible",
    ]

    /// Drivers whose pinned JSword `BookType` constructs a concrete `SwordBook`.
    private static let jswordSwordBookDrivers: Set<String> = [
        "rawtext", "ztext", "ztext4",
        "rawcom", "rawcom4", "zcom", "zcom4", "hrefcom", "rawfiles",
    ]

    /// Exact module initials (for example `KJV` or `ESV`), not a normalized Swift row identifier.
    public let name: String

    /// Full module description (e.g., "King James Version").
    public let description: String

    /// Module category.
    public let category: ModuleCategory

    /// ISO language code (e.g., "en", "el").
    public let language: String

    /// Module version string.
    public let version: String

    /// Raw SWORD/Android book driver declared by `ModDrv`.
    public let moduleDriver: String

    /// Whether the module requires a cipher key.
    public let isEncrypted: Bool

    /// Whether the module is currently unlocked.
    public let isUnlocked: Bool

    /// Supported features.
    public let features: ModuleFeatures

    /// Module text direction.
    public let isRightToLeft: Bool

    /// Android-compatible module About metadata.
    public let aboutMetadata: ModuleAboutMetadata

    /**
     Reports whether pinned JSword represents this driver as `SwordBook` rather than dictionary or
     generic-book subclasses.

     Android `OsisFragment` emits versification only when `book is SwordBook`, so reader payloads
     must use the concrete `BookType` driver map rather than infer from configured category.

     - Returns: `true` for the exact case-insensitive pinned SwordBook driver set.
     - Side effects: None.
     - Failure modes: Missing, custom, dictionary, and generic-book drivers return `false`.
     */
    public var isJSwordSwordBook: Bool {
        Self.jswordSwordBookDrivers.contains(
            moduleDriver.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    /**
     Whether the reader can use this module, mirroring JSword `SwordBookMetaData.isSupported()`.

     Android excludes an unsupported book from `Books.installed()` at the registry level, so it is
     invisible everywhere (not readable, not in pickers, not shown as installed). iOS mirrors that by
     filtering `SwordManager.installedModules()` and `module(named:)` on this predicate. JSword first
     requires `ModDrv` to name a registered `BookType`, then requires a registered versification for
     every category. Bible modules additionally need a libsword-renderable canon on iOS. Requiring
     those same metadata boundaries prevents malformed dictionaries, commentaries, books, and Bibles
     from entering the installed registry. See ADR-0010.
     - Returns: `true` only when Android recognizes the driver and versification and, for a Bible,
       libsword can render the same canon.
     - Side effects: Reads the validated bundled JSword registry and libsword's canon registry.
     - Failure modes: Missing or unknown drivers, unknown versifications, and unrenderable Bible
       canons fail closed.
     */
    public var isSupported: Bool {
        let normalizedDriver = moduleDriver
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard Self.androidSupportedModuleDrivers.contains(normalizedDriver),
              JSwordVersificationRegistry.supports(aboutMetadata.versification) else {
            return false
        }
        return category != .bible || SwordVersification.supports(aboutMetadata.versification)
    }

    /**
     Creates installed-module metadata used by inventory, reader, and Downloads surfaces.

     - Parameters:
       - name: Module initials.
       - description: User-visible module name.
       - category: Category resolved from driver and config metadata.
       - language: Module language code.
       - moduleDriver: Raw `ModDrv` value. An empty value remains unsupported, matching JSword.
       - version: Module version string.
       - isEncrypted: Whether a cipher key entry exists.
       - isUnlocked: Whether an encrypted module currently has a verified key.
       - features: Feature flags projected from module configuration.
       - isRightToLeft: Whether the module's configured text direction is right-to-left.
       - aboutMetadata: Android-compatible About and versification metadata.
     - Side effects: None.
     - Failure modes: Invalid support metadata is retained for diagnostics but `isSupported` returns
       `false`, keeping the module outside installed-book APIs.
     */
    public init(
        name: String,
        description: String,
        category: ModuleCategory,
        language: String,
        moduleDriver: String = "",
        version: String = "",
        isEncrypted: Bool = false,
        isUnlocked: Bool = true,
        features: ModuleFeatures = [],
        isRightToLeft: Bool = false,
        aboutMetadata: ModuleAboutMetadata = ModuleAboutMetadata()
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.language = language
        self.moduleDriver = moduleDriver
        self.version = version
        self.isEncrypted = isEncrypted
        self.isUnlocked = isUnlocked
        self.features = features
        self.isRightToLeft = isRightToLeft
        self.aboutMetadata = aboutMetadata.withFallbacks(osisId: name)
    }
}
