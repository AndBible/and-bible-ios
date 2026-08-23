// SearchContracts.swift - Android/JSword-compatible search domain contracts

import Foundation
import SwordKit

/**
 Canonical scope applied to indexed Bible searches.

 Android decorates Lucene queries with JSword `BibleBook` ranges (`Gen-Mal`, `Matt-Rev`, or the
 current OSIS book). The iOS index stores that identity separately from localized display keys so
 scope filtering never depends on English prefixes.
 */
public enum SearchCanonicalScope: Sendable, Equatable {
    /// Search every indexed canonical and deuterocanonical book.
    case wholeBible

    /// Search JSword's `Gen-Mal` range.
    case oldTestament

    /// Search JSword's `Matt-Rev` range.
    case newTestament

    /// Search one exact OSIS book identifier.
    case currentBook(osisBookId: String)
}

/// Canon section persisted with each indexed verse for language-independent scope filtering.
public enum SearchCanonSection: String, Sendable, Codable {
    case oldTestament = "ot"
    case newTestament = "nt"
    case other = "other"
}

/** Search-index facet that must be transactionally complete before a query can run. */
public enum SearchIndexRequirement: Sendable, Equatable {
    /// Analyzer-backed verse text is complete.
    case text

    /// The Strong's token scan is complete, including modules that contain zero tokens.
    case strongs
}

/**
 Durable identity of the installed source generation that owns one generated Search index.

 Module initials alone are insufficient because an upgrade can publish different content under the
 same name. The version remains inspectable for diagnostics while `fingerprint` includes the stable
 source metadata/storage generation used for readiness comparisons.
 */
public struct SearchIndexSourceIdentity: Sendable, Hashable {
    /// Exact installed module initials that own generated rows.
    public let moduleName: String

    /// Installed module version, which may be empty for manually imported modules.
    public let version: String

    /// Stable lowercase SHA-256 fingerprint of source metadata and storage revision.
    public let fingerprint: String

    /**
     Creates one immutable readiness identity already derived by a source adapter.

     - Parameters:
       - moduleName: Exact installed initials that own the generated rows.
       - version: Declared installed version, including an intentionally empty value.
       - fingerprint: Stable lowercase SHA-256 source-generation digest.
     - Side effects: None; hashing and storage inspection happen before initialization.
     - Failure modes: Values are retained verbatim; readiness checks fail closed for an empty or
       mismatched fingerprint rather than normalizing caller input.
     */
    public init(moduleName: String, version: String, fingerprint: String) {
        self.moduleName = moduleName
        self.version = version
        self.fingerprint = fingerprint
    }

    /**
     Compares installed Search generations while preserving Java's exact module-name identity.

     - Parameters:
       - lhs: First installed source generation.
       - rhs: Second installed source generation.
     - Returns: `true` only when module initials have the same UTF-16 code units and the version and
       fingerprint match their retained Swift values.
     - Side effects: None.
     - Failure modes: None; every Swift string exposes a deterministic UTF-16 view.
     */
    public static func == (lhs: Self, rhs: Self) -> Bool {
        SwordJavaStringIdentity.equals(lhs.moduleName, rhs.moduleName)
            && lhs.version == rhs.version
            && lhs.fingerprint == rhs.fingerprint
    }

    /**
     Hashes the same fields used by equality without canonically folding module initials.

     - Parameter hasher: Process-local Swift hasher receiving the exact source identity.
     - Side effects: Mutates only `hasher`; source values are not normalized or retained elsewhere.
     - Failure modes: None.
     */
    public func hash(into hasher: inout Hasher) {
        hasher.combine(SwordJavaExactStringIdentity(moduleName))
        hasher.combine(version)
        hasher.combine(fingerprint)
    }
}

/** Controls how Search derives a hit's visible book name without changing canonical identity. */
public enum SearchBookNamePresentation: String, Sendable, Codable {
    /// Preserve the source module's own display name, used by native SWORD entries.
    case source

    /// Resolve the canonical OSIS identifier through the current JSword locale at presentation time.
    case localizedCanonical
}

/**
 Stable canonical identity shared by equivalent verse hits from different modules.

 `canonicalBookOrder` follows the pinned JSword `BibleBook` enum, not a localized key string or a
 module's internal SWORD ordinal. This lets two modules with different display languages group and
 sort the same OSIS verse together.
 */
public struct SearchVerseIdentity: Sendable, Hashable, Comparable {
    public let osisBookId: String
    public let canonicalBookOrder: Int
    public let chapter: Int
    public let verse: Int

    public init(osisBookId: String, canonicalBookOrder: Int, chapter: Int, verse: Int) {
        self.osisBookId = osisBookId
        self.canonicalBookOrder = canonicalBookOrder
        self.chapter = chapter
        self.verse = verse
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.canonicalBookOrder != rhs.canonicalBookOrder {
            return lhs.canonicalBookOrder < rhs.canonicalBookOrder
        }
        if lhs.osisBookId != rhs.osisBookId {
            return lhs.osisBookId < rhs.osisBookId
        }
        if lhs.chapter != rhs.chapter {
            return lhs.chapter < rhs.chapter
        }
        return lhs.verse < rhs.verse
    }
}

/**
 Exact UTF-16 identity used by SwiftUI rows whose visible value contains Android module initials.

 Swift `String` identifiers merge canonically equivalent Unicode spellings, while Java book
 identity does not. This wrapper preserves a readable raw value for diagnostics/accessibility and
 uses Java `String.equals` code-unit identity for `Hashable`, allowing both exact owners to render.
 */
public struct SearchModuleRowIdentity: Sendable, Hashable, CustomStringConvertible {
    /// Readable identifier value retained without normalization.
    public let rawValue: String

    /// Exact Java identity that defines equality and hashing for SwiftUI diffing.
    private let exactIdentity: SwordJavaExactStringIdentity

    /**
     Creates one row identity from an already formatted module-aware value.

     - Parameter rawValue: Identifier string whose exact UTF-16 code units must remain distinct.
     - Side effects: None.
     - Failure modes: None; the value is retained verbatim.
     */
    public init(_ rawValue: String) {
        self.rawValue = rawValue
        exactIdentity = SwordJavaExactStringIdentity(rawValue)
    }

    /**
     Returns the readable unnormalized identifier for diagnostics and accessibility output.

     - Returns: The exact `rawValue` supplied at initialization.
     - Side effects: None.
     - Failure modes: None.
     */
    public var description: String { rawValue }

    /**
     Compares row identifiers with Java `String.equals` UTF-16 semantics.

     - Parameters:
       - lhs: First exact row identity.
       - rhs: Second exact row identity.
     - Returns: `true` only when every UTF-16 code unit matches.
     - Side effects: None.
     - Failure modes: None.
     */
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.exactIdentity == rhs.exactIdentity
    }

    /**
     Hashes the exact UTF-16 identity used by equality.

     - Parameter hasher: Process-local Swift hasher receiving the Java-exact identity.
     - Side effects: Mutates only `hasher`.
     - Failure modes: None.
     */
    public func hash(into hasher: inout Hasher) {
        hasher.combine(exactIdentity)
    }
}

/** One module's hit for a canonical verse. */
public struct SearchModuleHit: Sendable, Identifiable, Equatable {
    public let moduleName: String
    public let key: String
    /// Source display value retained for native SWORD modules and canonical fallback diagnostics.
    private let storedDisplayBook: String

    /// Strategy used to derive `displayBook` when the result is presented.
    public let bookNamePresentation: SearchBookNamePresentation

    /// Complete stored visible preview; collapsed presentation may apply its own visual line limit.
    public let snippet: String
    public let identity: SearchVerseIdentity

    /**
     User-visible book name resolved against the process's current locale.

     SQLite modules use canonical OSIS identity so locale changes do not require reindexing. Native
     SWORD modules preserve the exact source display name already emitted by their versification.
     */
    public var displayBook: String {
        displayBook(locale: .current)
    }

    /**
     Returns the exact module-and-verse identity used by SwiftUI result rows.

     - Returns: Readable row identity whose hashing preserves Java-distinct module spellings.
     - Side effects: None.
     - Failure modes: None.
     */
    public var id: SearchModuleRowIdentity {
        SearchModuleRowIdentity(
            "\(moduleName):\(identity.osisBookId).\(identity.chapter).\(identity.verse)"
        )
    }

    /**
     Creates one module-aware hit while keeping canonical and visible book identity separate.

     - Parameters:
       - moduleName: Exact generated-index owner.
       - key: Backend display key retained for diagnostics and stable source lookup.
       - displayBook: Source display name or canonical OSIS fallback persisted with the row.
       - snippet: Complete stored visible preview returned by Search; callers may visually collapse it.
       - identity: Locale-independent OSIS verse identity used for grouping and navigation.
       - bookNamePresentation: Presentation strategy; SQLite rows use `localizedCanonical`.
     - Side effects: None.
     - Failure modes: Values are retained verbatim; unknown canonical names fall back at presentation.
     */
    public init(
        moduleName: String,
        key: String,
        displayBook: String,
        snippet: String,
        identity: SearchVerseIdentity,
        bookNamePresentation: SearchBookNamePresentation = .source
    ) {
        self.moduleName = moduleName
        self.key = key
        storedDisplayBook = displayBook
        self.bookNamePresentation = bookNamePresentation
        self.snippet = snippet
        self.identity = identity
    }

    /**
     Resolves the visible book name for an explicit locale.

     - Parameter locale: Interface locale whose pinned JSword catalog should supply canonical names.
     - Returns: Localized canonical name for SQLite hits, otherwise the source name. Unknown OSIS ids
       fall back to the stored source value and then the OSIS identifier.
     - Side effects: Lazily reads immutable bundled JSword name catalogs.
     - Failure modes: Missing locale resources use JSword's English fallback without throwing.
     */
    public func displayBook(locale: Locale) -> String {
        guard bookNamePresentation == .localizedCanonical else { return storedDisplayBook }
        return JSwordKJVAVersification.localizedLongBookName(
            osisId: identity.osisBookId,
            locale: locale
        ) ?? (storedDisplayBook.isEmpty ? identity.osisBookId : storedDisplayBook)
    }
}

/** Search hits and truncation state for one module. */
public struct SearchModuleResults: Sendable, Equatable {
    public let moduleName: String
    public let hits: [SearchModuleHit]
    public let isTruncated: Bool

    public init(moduleName: String, hits: [SearchModuleHit], isTruncated: Bool = false) {
        self.moduleName = moduleName
        self.hits = hits
        self.isTruncated = isTruncated
    }
}

/** One canonical verse with every selected translation that matched it. */
public struct SearchGroupedVerseResult: Sendable, Identifiable, Equatable {
    public let identity: SearchVerseIdentity
    public let matches: [SearchModuleHit]

    public var id: String {
        "\(identity.osisBookId).\(identity.chapter).\(identity.verse)"
    }

    public var displayReference: String {
        let book = matches.first?.displayBook ?? identity.osisBookId
        return "\(book) \(identity.chapter):\(identity.verse)"
    }

    public init(identity: SearchVerseIdentity, matches: [SearchModuleHit]) {
        self.identity = identity
        self.matches = matches
    }
}

/// Per-module hit count retained even when that selected module has no matches.
public struct SearchModuleCount: Sendable, Equatable {
    public let moduleName: String
    public let count: Int

    public init(moduleName: String, count: Int) {
        self.moduleName = moduleName
        self.count = count
    }
}

/** One selected module that could not execute while other selected modules returned normally. */
public struct SearchModuleFailure: Sendable, Identifiable, Equatable {
    /// Exact selected module initials.
    public let moduleName: String

    /// User-visible error describing why this module could not be searched.
    public let message: String

    /**
     Returns the exact module identity used by SwiftUI failure rows.

     - Returns: Readable row identity whose hashing preserves Java-distinct initials.
     - Side effects: None.
     - Failure modes: None.
     */
    public var id: SearchModuleRowIdentity { SearchModuleRowIdentity(moduleName) }

    /**
     Creates one immutable failure row for a selected module that did not execute successfully.

     - Parameters:
       - moduleName: Exact selected module initials used for ordering and row identity.
       - message: User-visible localized error supplied by the failed module operation.
     - Side effects: None.
     - Failure modes: Empty messages are retained so callers can detect an incomplete error mapping.
     */
    public init(moduleName: String, message: String) {
        self.moduleName = moduleName
        self.message = message
    }
}

/**
 Grouped result set returned by both text and Strong's multi-module searches.

 Grouping uses canonical OSIS identity. Match order follows the caller's selected module order,
 while verse groups follow JSword `BibleBook` order and numeric chapter/verse order.
 */
public struct SearchGroupedResults: Sendable, Equatable {
    public let groups: [SearchGroupedVerseResult]
    public let moduleCounts: [SearchModuleCount]
    /// Ordered failures for selected modules omitted from `moduleCounts` and result groups.
    public let moduleFailures: [SearchModuleFailure]
    public let totalHitCount: Int
    public let isTruncated: Bool

    /**
     Groups successful module hits and retains explicit failures in selected-module order.

     - Parameters:
       - moduleResults: Modules that executed successfully, including zero-hit results.
       - moduleOrder: Caller-selected module order used for matches, counts, and failures.
       - moduleFailures: Modules whose individual query execution failed.
     - Side effects: None.
     - Failure modes: Duplicate Java-exact module results or failures keep dictionary construction's
       precondition; service callers de-duplicate selected names before constructing this value.
     */
    public init(
        moduleResults: [SearchModuleResults],
        moduleOrder: [String],
        moduleFailures: [SearchModuleFailure] = []
    ) {
        let resultsByModule = Dictionary(
            uniqueKeysWithValues: moduleResults.map {
                (SwordJavaExactStringIdentity($0.moduleName), $0)
            }
        )
        let selectedKeys = Set(moduleOrder.map { SwordJavaExactStringIdentity($0) })
        let unexpectedNames = resultsByModule.values
            .map(\.moduleName)
            .filter { !selectedKeys.contains(SwordJavaExactStringIdentity($0)) }
            .sorted(by: Self.javaStringPrecedes)
        let orderedNames = Self.orderedUniqueModuleNames(
            moduleOrder.filter {
                resultsByModule[SwordJavaExactStringIdentity($0)] != nil
            } + unexpectedNames
        )
        let failuresByModule = Dictionary(
            uniqueKeysWithValues: moduleFailures.map {
                (SwordJavaExactStringIdentity($0.moduleName), $0)
            }
        )
        let unexpectedFailureNames = failuresByModule.values
            .map(\.moduleName)
            .filter { !selectedKeys.contains(SwordJavaExactStringIdentity($0)) }
            .sorted(by: Self.javaStringPrecedes)
        let orderedFailureNames = Self.orderedUniqueModuleNames(
            moduleOrder.filter {
                failuresByModule[SwordJavaExactStringIdentity($0)] != nil
            } + unexpectedFailureNames
        )

        var grouped: [SearchVerseIdentity: [SearchModuleHit]] = [:]
        for moduleName in orderedNames {
            for hit in resultsByModule[SwordJavaExactStringIdentity(moduleName)]?.hits ?? [] {
                grouped[hit.identity, default: []].append(hit)
            }
        }

        groups = grouped
            .map { SearchGroupedVerseResult(identity: $0.key, matches: $0.value) }
            .sorted { $0.identity < $1.identity }
        moduleCounts = orderedNames.map {
            SearchModuleCount(
                moduleName: $0,
                count: resultsByModule[SwordJavaExactStringIdentity($0)]?.hits.count ?? 0
            )
        }
        self.moduleFailures = orderedFailureNames.compactMap {
            failuresByModule[SwordJavaExactStringIdentity($0)]
        }
        totalHitCount = moduleCounts.reduce(0) { $0 + $1.count }
        isTruncated = moduleResults.contains(where: \.isTruncated)
    }

    /**
     Keeps the first value for each exact Java UTF-16 module identity.

     - Parameter values: Ordered module initials from successful/failing results and caller order.
     - Returns: First-occurrence order with only code-unit-identical duplicates removed.
     - Side effects: None.
     - Failure modes: None; canonically equivalent spellings intentionally remain separate.
     */
    private static func orderedUniqueModuleNames(_ values: [String]) -> [String] {
        var seen = Set<SwordJavaExactStringIdentity>()
        return values.filter {
            seen.insert(SwordJavaExactStringIdentity($0)).inserted
        }
    }

    /**
     Orders otherwise-unselected module names with Java `String.compareTo` code-unit semantics.

     - Parameters:
       - lhs: First exact initials value.
       - rhs: Second exact initials value.
     - Returns: Whether `lhs` precedes `rhs` by unsigned UTF-16 code-unit lexicographic order.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func javaStringPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
    }
}

/** Exact module-aware destination emitted when a search result is selected. */
public struct SearchNavigationTarget: Sendable, Equatable {
    public let moduleName: String
    public let osisBookId: String
    public let displayBook: String
    public let chapter: Int
    public let verse: Int

    public init(
        moduleName: String,
        osisBookId: String,
        displayBook: String,
        chapter: Int,
        verse: Int
    ) {
        self.moduleName = moduleName
        self.osisBookId = osisBookId
        self.displayBook = displayBook
        self.chapter = chapter
        self.verse = verse
    }

    public init(hit: SearchModuleHit) {
        self.init(
            moduleName: hit.moduleName,
            osisBookId: hit.identity.osisBookId,
            displayBook: hit.displayBook,
            chapter: hit.identity.chapter,
            verse: hit.identity.verse
        )
    }
}

/**
 Pinned JSword `BibleBook` ordering and testament boundaries used by Android Search.

 The list is copied from `org.crosswire.jsword.versification.BibleBook` at Android's pinned JSword
 revision `0da7412d7716731f402c9002a0b92e4c00ef30eb`. Intro entries are retained in the order map but
 index creation excludes their chapter/verse-zero records.
 */
public enum SearchCanonicalBookCatalog {
    public static let pinnedJSwordRevision = "0da7412d7716731f402c9002a0b92e4c00ef30eb"

    private static let orderedOSISBookIds = [
        "Intro.Bible", "Intro.OT",
        "Gen", "Exod", "Lev", "Num", "Deut", "Josh", "Judg", "Ruth", "1Sam", "2Sam",
        "1Kgs", "2Kgs", "1Chr", "2Chr", "Ezra", "Neh", "Esth", "Job", "Ps", "Prov",
        "Eccl", "Song", "Isa", "Jer", "Lam", "Ezek", "Dan", "Hos", "Joel", "Amos",
        "Obad", "Jonah", "Mic", "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal", "Intro.NT",
        "Matt", "Mark", "Luke", "John", "Acts", "Rom", "1Cor", "2Cor", "Gal", "Eph",
        "Phil", "Col", "1Thess", "2Thess", "1Tim", "2Tim", "Titus", "Phlm", "Heb", "Jas",
        "1Pet", "2Pet", "1John", "2John", "3John", "Jude", "Rev",
        "Tob", "Jdt", "AddEsth", "Wis", "Sir", "Bar", "EpJer", "PrAzar", "Sus", "Bel",
        "1Macc", "2Macc", "3Macc", "4Macc", "PrMan", "1Esd", "2Esd", "Ps151", "Odes",
        "PssSol", "EpLao", "3Esd", "4Esd", "5Esd", "1En", "Jub", "4Bar", "AscenIsa",
        "PsJos", "AposCon", "1Clem", "2Clem", "3Cor", "EpCorPaul", "JosAsen", "T12Patr",
        "T12Patr.TAsh", "T12Patr.TBenj", "T12Patr.TDan", "T12Patr.TGad", "T12Patr.TIss",
        "T12Patr.TJos", "T12Patr.TJud", "T12Patr.TLevi", "T12Patr.TNaph", "T12Patr.TReu",
        "T12Patr.TSim", "T12Patr.TZeb", "2Bar", "EpBar", "Barn", "Herm", "Herm.Mand",
        "Herm.Sim", "Herm.Vis", "AddDan", "AddPs", "EsthGr",
    ]

    private static let orderByOSIS = Dictionary(
        uniqueKeysWithValues: orderedOSISBookIds.enumerated().map { ($0.element, $0.offset) }
    )

    private static let oldTestamentRange = Set(
        orderedOSISBookIds[(orderByOSIS["Gen"] ?? 0)...(orderByOSIS["Mal"] ?? 0)]
    )

    private static let newTestamentRange = Set(
        orderedOSISBookIds[(orderByOSIS["Matt"] ?? 0)...(orderByOSIS["Rev"] ?? 0)]
    )

    /** Returns the pinned JSword enum order, with unknown books sorted after known books. */
    public static func order(of osisBookId: String) -> Int {
        orderByOSIS[osisBookId] ?? Int.max - 1
    }

    /** Returns JSword's canonical Search section for an OSIS identifier. */
    public static func section(of osisBookId: String) -> SearchCanonSection {
        if oldTestamentRange.contains(osisBookId) {
            return .oldTestament
        }
        if newTestamentRange.contains(osisBookId) {
            return .newTestament
        }
        return .other
    }
}
