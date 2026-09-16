import Foundation

/**
 Resolves annotation book names with Android's locale and lookup precedence.

 Exact OSIS identifiers precede localized exact names, English exact names, localized fuzzy names,
 and English fuzzy names. Catalogs normalize their immutable names once. English is retained for
 the process lifetime; a locked single-entry cache retains only the latest other locale, while
 callers can safely finish with an older immutable value after a locale change.
 */
enum SwordAnnotationBookResolver {
    /// English supplies Android's OSIS normalization and cross-locale fallback.
    private static let english = Locale(identifier: "en")

    /// Canonical identifiers indexed once using Android's English normalization.
    private static let osisIDs: [String: String] = Dictionary(
        uniqueKeysWithValues: SwordBibleNameResources.orderedOSISIDs.map {
            (normalize($0, locale: english), $0)
        }
    )

    /// Android's NT, OT, and remaining-name groups, preserving order within each group.
    private static let nameGroups: [[String]] = {
        let identifiers = SwordBibleNameResources.orderedOSISIDs
        guard let oldTestament = identifiers.firstIndex(of: "Gen"),
              let remaining = identifiers.firstIndex(of: "Intro.Bible") else { return [] }
        return [
            Array(identifiers[..<oldTestament]),
            Array(identifiers[oldTestament..<remaining]),
            Array(identifiers[remaining...]),
        ]
    }()

    /// Immutable fallback built lazily once rather than reconstructed for every annotation.
    private static let englishCatalog = Catalog(locale: english)

    /// Bounded locale cache; its lock protects only lookup and publication of immutable catalogs.
    private static let localeCache = LocaleCatalogCache()

    /**
     Resolves one token after Android-compatible endpoint tokenization has removed separators.

     - Parameters:
       - token: One book-name token, retaining Android's normalized word boundaries.
       - locale: Interface locale captured by the caller for this reference resolution.
     - Returns: Canonical OSIS book identifier, or nil when no exact or fuzzy name matches.
     - Side effects: First use prepares English and the requested locale's immutable lookup data.
       Concurrent cache misses may prepare the same data twice; no module cursor or files change.
     - Failure modes: Empty/non-letter input and missing or unknown names return nil. A resolved
       identifier still requires validation against the selected source's versification.
     */
    static func osisID(matching token: String, locale: Locale) -> String? {
        guard token.contains(where: \.isLetter) else { return nil }
        let normalizedEnglish = normalize(token, locale: english)
        if let exact = osisIDs[normalizedEnglish] { return exact }

        let localized = locale.identifier == english.identifier
            ? englishCatalog
            : localeCache.catalog(for: locale)
        let normalizedLocal = normalize(token, locale: locale)
        if let exact = localized.exactNames[normalizedLocal]
            ?? englishCatalog.exactNames[normalizedEnglish] { return exact }
        return localized.fuzzyMatch(normalizedLocal)
            ?? englishCatalog.fuzzyMatch(normalizedEnglish)
    }

    /** One name row normalized once in its catalog's locale, in Android insertion order. */
    private struct BookName: Sendable {
        /// Canonical result independent of the localized source spelling.
        let osisID: String
        /// Normalized Full resource value.
        let longName: String
        /// Normalized Short value; only an empty value falls back to Full.
        let shortName: String
        /// Normalized Alt values; Android's undefined # placeholder produces no alternatives.
        let alternateNames: [String]

        /** Checks Android's ordered alternate/long/short prefix rules without new normalization. */
        func fuzzyMatches(_ candidate: String) -> Bool {
            alternateNames.contains {
                $0.hasPrefix(candidate) || candidate.hasPrefix($0)
            }
                || longName.hasPrefix(candidate)
                || shortName.hasPrefix(candidate)
                || (!shortName.isEmpty && candidate.hasPrefix(shortName))
        }
    }

    /** Immutable exact maps and ordered fuzzy rows for one locale's pinned name resources. */
    private struct Catalog: Sendable {
        /// Flattened nine-map lookup retaining NT/OT/remaining and Full/Short/Alt precedence.
        let exactNames: [String: String]
        /// Rows in Android NameList insertion order, used only when exact matching fails.
        let names: [BookName]

        /**
         Prepares lookup values once from the selected immutable resource dictionary.

         - Parameter locale: Locale used for resource selection and name normalization.
         - Side effects: First resource access can load the shared bundle snapshot.
         - Failure modes: Missing resources produce empty lookups. Within each exact map later
           rows replace earlier duplicates, matching Java HashMap.put; earlier maps retain priority.
         */
        init(locale: Locale) {
            guard let values = SwordBibleNameResources.catalog(for: locale) else {
                exactNames = [:]
                names = []
                return
            }
            var exact: [String: String] = [:]
            var ordered: [BookName] = []
            for group in nameGroups {
                let rows: [BookName] = group.compactMap { osisID in
                    guard let full = values["\(osisID).Full"], !full.isEmpty else { return nil }
                    let short = values["\(osisID).Short"] ?? ""
                    let alternate = values["\(osisID).Alt"] ?? ""
                    let alternates = alternate.hasPrefix("#")
                        ? []
                        : alternate.split(separator: ",", omittingEmptySubsequences: true)
                            .map { normalize(String($0), locale: locale) }
                    return BookName(
                        osisID: osisID,
                        longName: normalize(full, locale: locale),
                        shortName: normalize(short.isEmpty ? full : short, locale: locale),
                        alternateNames: alternates
                    )
                }
                var full: [String: String] = [:]
                var short: [String: String] = [:]
                var alternate: [String: String] = [:]
                for row in rows {
                    full[row.longName] = row.osisID
                    short[row.shortName] = row.osisID
                    for name in row.alternateNames { alternate[name] = row.osisID }
                }
                for map in [full, short, alternate] {
                    for (name, identifier) in map where exact[name] == nil {
                        exact[name] = identifier
                    }
                }
                ordered.append(contentsOf: rows)
            }
            exactNames = exact
            names = ordered
        }

        /** Returns the first fuzzy match in Android insertion order, without changing the catalog. */
        func fuzzyMatch(_ candidate: String) -> String? {
            names.first(where: { $0.fuzzyMatches(candidate) })?.osisID
        }
    }

    /**
     Holds one immutable locale catalog while allowing concurrent resolutions to finish safely.

     The lock owns all access to the cached tuple. Catalog construction runs outside the lock and
     callers receive value snapshots; replacing the cache cannot change an in-flight resolution.
     Retained cache size does not grow with arbitrary locale identifiers.
     */
    private final class LocaleCatalogCache: @unchecked Sendable {
        /// Protects the optional cached tuple; never held while constructing lookup data.
        private let lock = NSLock()
        /// Most recently requested locale and its immutable prepared catalog.
        private var current: (identifier: String, catalog: Catalog)?

        /** Returns a matching snapshot or builds and publishes this locale's replacement. */
        func catalog(for locale: Locale) -> Catalog {
            lock.lock()
            if let current, current.identifier == locale.identifier {
                lock.unlock()
                return current.catalog
            }
            lock.unlock()

            let prepared = Catalog(locale: locale)
            lock.lock()
            current = (locale.identifier, prepared)
            lock.unlock()
            return prepared
        }
    }

    /** Removes periods and ASCII spaces, then lowercases in the supplied locale like JSword. */
    private static func normalize(_ value: String, locale: Locale) -> String {
        value.replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased(with: locale)
    }
}
