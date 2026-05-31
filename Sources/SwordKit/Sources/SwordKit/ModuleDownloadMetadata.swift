// ModuleDownloadMetadata.swift - Android download-list metadata support

import Foundation

/**
 Android-shaped metadata buckets used to annotate the Downloads module list.

 The Android `DownloadActivity` downloads JSON files whose top-level keys are grouped by document
 category and language. Each value is a module initials token, or a repository-scoped token such as
 `KJV::CrossWire`. Bad-document metadata uses the same category/language structure with entries in
 the form `initials::repository::version::action`.

 Inputs:
 - decoded JSON from AndBible metadata feeds
 - `RemoteModuleInfo` values from repository catalogs

 Outputs:
 - category/language lookups for recommended/default metadata
 - bad-document action decisions for remote rows

 Side effects:
 - none; this type is a deterministic value mapper

 Failure modes:
 - malformed entries are ignored instead of matching a module
 */
public struct ModuleDownloadConfiguration: Sendable, Codable, Equatable {
    /// Bible module entries keyed by language code.
    public var bibles: [String: [String]]

    /// Commentary module entries keyed by language code.
    public var commentaries: [String: [String]]

    /// Dictionary module entries keyed by language code.
    public var dictionaries: [String: [String]]

    /// General-book module entries keyed by language code.
    public var books: [String: [String]]

    /// Map module entries keyed by language code.
    public var maps: [String: [String]]

    /**
     Android add-on entries keyed by language code.

     These entries map to SWORD rows whose category is JSword's `AND_BIBLE` / `And Bible` bucket.
     They participate in Downloads filtering and metadata decisions only when the catalog exposes
     matching add-on rows.
     */
    public var addons: [String: [String]]

    private enum CodingKeys: String, CodingKey {
        case bibles
        case commentaries
        case dictionaries
        case books
        case maps
        case addons
    }

    /**
     Creates a metadata bucket with Android-compatible category maps.

     - Parameters:
       - bibles: Bible entries keyed by language code.
       - commentaries: Commentary entries keyed by language code.
       - dictionaries: Dictionary entries keyed by language code.
       - books: General-book entries keyed by language code.
       - maps: Map entries keyed by language code.
       - addons: Add-on entries keyed by language code.

     Side effects:
     - none

     Failure modes:
     - none
     */
    public init(
        bibles: [String: [String]] = [:],
        commentaries: [String: [String]] = [:],
        dictionaries: [String: [String]] = [:],
        books: [String: [String]] = [:],
        maps: [String: [String]] = [:],
        addons: [String: [String]] = [:]
    ) {
        self.bibles = bibles
        self.commentaries = commentaries
        self.dictionaries = dictionaries
        self.books = books
        self.maps = maps
        self.addons = addons
    }

    /**
     Decodes Android metadata while tolerating absent category buckets.

     - Parameter decoder: JSON decoder for an AndBible metadata file.
     - Throws: Decoding errors for malformed present fields.

     Side effects:
     - none

     Failure modes:
     - malformed bucket values throw so callers can keep prior cached metadata
     */
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bibles = try container.decodeIfPresent([String: [String]].self, forKey: .bibles) ?? [:]
        commentaries = try container.decodeIfPresent([String: [String]].self, forKey: .commentaries) ?? [:]
        dictionaries = try container.decodeIfPresent([String: [String]].self, forKey: .dictionaries) ?? [:]
        books = try container.decodeIfPresent([String: [String]].self, forKey: .books) ?? [:]
        maps = try container.decodeIfPresent([String: [String]].self, forKey: .maps) ?? [:]
        addons = try container.decodeIfPresent([String: [String]].self, forKey: .addons) ?? [:]
    }

    /**
     Returns the language-indexed metadata map for a module category.

     - Parameter category: SWORD/Android module category to map onto Android's metadata buckets.
     - Returns: A language-keyed token map; unsupported categories return an empty map.

     Side effects:
     - none

     Failure modes:
     - none
     */
    public func entries(for category: ModuleCategory) -> [String: [String]] {
        switch category {
        case .bible:
            return bibles
        case .commentary:
            return commentaries
        case .dictionary:
            return dictionaries
        case .generalBook:
            return books
        case .map:
            return maps
        case .addon:
            return addons
        default:
            return [:]
        }
    }

    /**
     Tests whether Android recommendation/default metadata contains a remote module.

     - Parameter module: Remote module row being rendered or sorted.
     - Returns: `true` when the category/language bucket contains the module initials, optionally
       scoped to the same repository name after `::`.

     Side effects:
     - none

     Failure modes:
     - malformed repository-scoped tokens are ignored
     */
    public func contains(_ module: RemoteModuleInfo) -> Bool {
        entries(for: module.category)[module.language, default: []].contains { token in
            let parts = token.components(separatedBy: "::")
            if parts.count >= 2 {
                return parts[0] == module.name && parts[1] == module.sourceName
            }
            return token == module.name
        }
    }

    /**
     Returns Android's bad-document action for a remote module.

     - Parameter module: Remote module row being considered for display.
     - Returns: The configured action, or `.none` when the row is not listed or the entry is
       malformed.

     Side effects:
     - none

     Failure modes:
     - malformed entries and non-matching versions/repositories return `.none`
     */
    public func badDocumentAction(for module: RemoteModuleInfo) -> ModuleBadDocumentAction {
        for token in entries(for: module.category)[module.language, default: []] {
            let parts = token.components(separatedBy: "::")
            guard parts.count >= 4 else { continue }
            guard parts[0] == module.name,
                  parts[1] == module.sourceName,
                  parts[2] == module.version else {
                continue
            }
            return ModuleBadDocumentAction(actionLetter: parts[3])
        }
        return .none
    }
}

/**
 Android bad-document action parsed from `bad_documents.json`.

 Android uses `W` to show a warning badge, `H` to hide a row, and any other value as no special
 handling. The enum keeps the same semantics while allowing iOS filtering and row badges to be
 tested without depending on raw strings.
 */
public enum ModuleBadDocumentAction: Sendable, Equatable {
    /// Show the row with a warning affordance.
    case warn

    /// Hide the row from the download list.
    case hide

    /// Render the row normally.
    case none

    /**
     Creates an action from Android's one-letter metadata code.

     - Parameter actionLetter: Android metadata action value.
     - Returns: `.warn` for `W`, `.hide` for `H`, and `.none` otherwise.

     Side effects:
     - none

     Failure modes:
     - unknown letters map to `.none`
     */
    public init(actionLetter: String) {
        switch actionLetter {
        case "W":
            self = .warn
        case "H":
            self = .hide
        default:
            self = .none
        }
    }
}
