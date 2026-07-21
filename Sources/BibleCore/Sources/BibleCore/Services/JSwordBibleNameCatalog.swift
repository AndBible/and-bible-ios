// JSwordBibleNameCatalog.swift -- pinned localized JSword book-name resource lookup

import Foundation

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

    /** Returns the canonical bundle suffix key for one Foundation locale. */
    static func localeKey(for locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier
            ?? locale.identifier.split(separator: "_").first.map(String.init)
            ?? "en"
        let region = locale.region?.identifier
        let script = locale.language.script?.identifier
        if language == "zh" {
            if script == "Hant" || ["TW", "HK", "MO"].contains(region) { return "zh_TW" }
            if script == "Hans" || ["CN", "SG"].contains(region) { return "zh_CN" }
        }
        if language == "sr", script == "Latn" { return "sr_LT" }
        if language == "pt", region == "BR" { return "pt_BR" }
        if let region { return "\(language)_\(region)" }
        return language
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
     Loads every copied JSword locale catalog into immutable exact-match maps.

     - Returns: Catalogs keyed by Java resource suffix, with `""` representing the English base.
     - Side effects: Reads `Bundle.module/Resources/jsword-bible-names` once through the linker's
       immutable static initialization.
     - Failure modes: Missing base resources return an empty map so references remain plain text;
       malformed individual overlays are skipped without replacing another locale.
     */
    static func loadBundledCatalogs() -> [String: JSwordBibleNameCatalog] {
        guard let directory = Bundle.module.url(
            forResource: "jsword-bible-names",
            withExtension: nil
        ), let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ), let baseURL = files.first(where: { $0.lastPathComponent == "BibleNames.properties" }),
              let base = parseProperties(at: baseURL) else {
            return [:]
        }

        var result: [String: JSwordBibleNameCatalog] = [:]
        for file in files where file.pathExtension == "properties" {
            let name = file.deletingPathExtension().lastPathComponent
            guard name == "BibleNames" || name.hasPrefix("BibleNames_"),
                  let overlay = parseProperties(at: file) else {
                continue
            }
            let suffix = name == "BibleNames" ? "" : String(name.dropFirst("BibleNames_".count))
            let locale = Locale(identifier: suffix.isEmpty ? "en" : suffix)
            result[suffix] = makeCatalog(
                values: base.merging(overlay) { _, localeValue in localeValue },
                locale: locale
            )
        }
        return result
    }

    /** Parses the pinned UTF-8 `.properties` subset used by JSword's Bible-name resources. */
    private static func parseProperties(at url: URL) -> [String: String]? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \Character.isNewline) {
            let line = String(rawLine)
            guard !line.isEmpty, line.first != "#", line.first != "!",
                  let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
            result[key] = value
        }
        return result
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
