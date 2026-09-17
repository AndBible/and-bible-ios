// JSwordBibleNameCatalog.swift -- pinned localized JSword book-name resource lookup

import Foundation
import SwordKit

/**
 Immutable lookup projection of one pinned JSword `BibleNames` resource bundle.

 Java `ResourceBundle` inherits missing locale keys from the base catalog, so locale loading merges
 each UTF-8 locale file over `BibleNames.properties`. Maps retain JSword's NT, OT, noncanonical and
 full, short, alternate lookup priority; fuzzy prefix matching remains intentionally disabled.
 */
struct JSwordBibleNameCatalog {
    /// Lookup maps in exact JSword priority order.
    let lookupMaps: [[String: String]]

    /// Preferred localized long names keyed by canonical OSIS book id.
    let longNamesByOsisID: [String: String]

    /** Resolves one exact normalized localized name without fuzzy matching. */
    func osisID(for name: String, locale: Locale) -> String? {
        let normalized = Self.normalize(name, locale: locale)
        for map in lookupMaps {
            if let match = map[normalized] { return match }
        }
        return nil
    }

    /** Returns JSword's preferred localized long name for one canonical OSIS book id. */
    func longName(forOsisID osisID: String) -> String? {
        longNamesByOsisID[osisID]
    }

    /** Strips only periods and ASCII spaces before locale-aware lowercasing, matching JSword. */
    static func normalize(_ value: String, locale: Locale) -> String {
        value
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased(with: locale)
    }

    /** Returns the shared pinned resource suffix key for one Foundation locale. */
    static func localeKey(for locale: Locale) -> String {
        SwordBibleNameResources.localeKey(for: locale)
    }

    /** Selects the nearest bundled locale catalog, including Java's legacy language aliases. */
    static func catalog(
        for locale: Locale,
        in catalogs: [String: JSwordBibleNameCatalog]
    ) -> JSwordBibleNameCatalog? {
        let exact = localeKey(for: locale)
        let language = exact.split(separator: "_").first.map(String.init) ?? exact
        let aliases: [String]
        switch language {
        case "he": aliases = [exact, "he", "iw"]
        case "iw": aliases = [exact, "iw", "he"]
        case "id": aliases = [exact, "id", "in"]
        case "in": aliases = [exact, "in", "id"]
        default: aliases = [exact, language]
        }
        for key in aliases where catalogs[key] != nil { return catalogs[key] }
        return catalogs[""]
    }

    /**
     Builds the existing exact-match catalogs from SwordKit's shared immutable name resources.

     - Returns: Locale catalogs retaining the KJVA lookup domain and all-book display names.
     - Side effects: First access initializes the shared bundled resource snapshot once.
     - Failure modes: Missing shared resources return an empty map so references remain plain text.
     */
    static func loadBundledCatalogs() -> [String: JSwordBibleNameCatalog] {
        Dictionary(uniqueKeysWithValues: SwordBibleNameResources.mergedCatalogs.map { suffix, values in
            let locale = Locale(identifier: suffix.isEmpty ? "en" : suffix)
            return (suffix, makeCatalog(values: values, locale: locale))
        })
    }

    /**
     Builds JSword-priority parsing maps and display names from one merged locale dictionary.

     - Parameters:
       - values: Base JSword `BibleNames` properties overlaid with one locale resource.
       - locale: Locale used for JSword-compatible name normalization.
     - Returns: A catalog whose exact parsing maps retain the supported KJVA domain while its
       display-name map contains every JSword `BibleBook` represented by a `.Full` resource key.
     - Side effects: None.
     - Failure modes: Missing resource keys are omitted; callers fail closed on absent names.
     */
    private static func makeCatalog(
        values: [String: String],
        locale: Locale
    ) -> JSwordBibleNameCatalog {
        let nt = JSwordKJVAVersification.books.filter { (41...67).contains($0.bibleBookOrdinal) }
        let ot = JSwordKJVAVersification.books.filter { (2...40).contains($0.bibleBookOrdinal) }
        let nc = JSwordKJVAVersification.books.filter { $0.bibleBookOrdinal > 67 }
        var maps: [[String: String]] = []
        var longNamesByOsisID: [String: String] = [:]
        for (key, value) in values where key.hasSuffix(".Full") && !value.isEmpty {
            let osisID = String(key.dropLast(".Full".count))
            if !osisID.isEmpty {
                longNamesByOsisID[osisID] = value
            }
        }
        for books in [nt, ot, nc] {
            var full: [String: String] = [:]
            var short: [String: String] = [:]
            var alternate: [String: String] = [:]
            for book in books {
                guard let longName = values["\(book.osisId).Full"] else { continue }
                let shortName = values["\(book.osisId).Short"].flatMap { $0.isEmpty ? nil : $0 }
                    ?? longName
                full[normalize(longName, locale: locale)] = book.osisId
                short[normalize(shortName, locale: locale)] = book.osisId
                let alternateNames = values["\(book.osisId).Alt"] ?? ""
                if !alternateNames.hasPrefix("#") {
                    for name in alternateNames.split(separator: ",", omittingEmptySubsequences: true) {
                        alternate[normalize(String(name), locale: locale)] = book.osisId
                    }
                }
            }
            maps.append(contentsOf: [full, short, alternate])
        }
        return JSwordBibleNameCatalog(
            lookupMaps: maps,
            longNamesByOsisID: longNamesByOsisID
        )
    }
}
