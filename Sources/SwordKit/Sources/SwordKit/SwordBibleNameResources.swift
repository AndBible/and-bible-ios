import Foundation

/**
 Immutable pinned JSword book-name data shared by source parsing and reader presentation.

 The dictionaries retain every resource book and its Full, Short, and Alt entries. Consumers choose
 their own supported canon and exact/fuzzy lookup policy; this owner only loads and selects data.
 Swift's static initialization publishes one immutable snapshot safely to concurrent readers.
 */
public enum SwordBibleNameResources {
    /**
     Android's `BibleNames.NameList` insertion order for the full `BibleBook` domain.

     The pinned JSword `BibleBook` enum supplies identifiers; `BibleNames.initialize` orders New
     Testament books first, then Old Testament books, then introductions and remaining enum values.
     This is name-lookup precedence, not the book order of any particular versification.
     */
    public static let orderedOSISIDs: [String] = [
        "Matt", "Mark", "Luke", "John", "Acts", "Rom", "1Cor", "2Cor",
        "Gal", "Eph", "Phil", "Col", "1Thess", "2Thess", "1Tim", "2Tim",
        "Titus", "Phlm", "Heb", "Jas", "1Pet", "2Pet", "1John", "2John",
        "3John", "Jude", "Rev", "Gen", "Exod", "Lev", "Num", "Deut",
        "Josh", "Judg", "Ruth", "1Sam", "2Sam", "1Kgs", "2Kgs", "1Chr",
        "2Chr", "Ezra", "Neh", "Esth", "Job", "Ps", "Prov", "Eccl",
        "Song", "Isa", "Jer", "Lam", "Ezek", "Dan", "Hos", "Joel",
        "Amos", "Obad", "Jonah", "Mic", "Nah", "Hab", "Zeph", "Hag",
        "Zech", "Mal", "Intro.Bible", "Intro.OT", "Intro.NT", "Tob", "Jdt", "AddEsth",
        "Wis", "Sir", "Bar", "EpJer", "PrAzar", "Sus", "Bel", "1Macc",
        "2Macc", "3Macc", "4Macc", "PrMan", "1Esd", "2Esd", "Ps151", "Odes",
        "PssSol", "EpLao", "3Esd", "4Esd", "5Esd", "1En", "Jub", "4Bar",
        "AscenIsa", "PsJos", "AposCon", "1Clem", "2Clem", "3Cor", "EpCorPaul", "JosAsen",
        "T12Patr", "T12Patr.TAsh", "T12Patr.TBenj", "T12Patr.TDan", "T12Patr.TGad", "T12Patr.TIss", "T12Patr.TJos", "T12Patr.TJud",
        "T12Patr.TLevi", "T12Patr.TNaph", "T12Patr.TReu", "T12Patr.TSim", "T12Patr.TZeb", "2Bar", "EpBar", "Barn",
        "Herm", "Herm.Mand", "Herm.Sim", "Herm.Vis", "AddDan", "AddPs", "EsthGr",
    ]

    /**
     Locale-suffix dictionaries with each resource overlaid on the English base.

     The empty suffix identifies the English base. First access reads bundled resources once;
     missing or malformed base data produces an empty map, and invalid overlays are omitted.
     */
    public static let mergedCatalogs: [String: [String: String]] = loadBundledCatalogs()

    /** Returns the canonical bundle suffix key for one Foundation locale. */
    public static func localeKey(for locale: Locale) -> String {
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

    /**
     Selects the nearest pinned locale dictionary without resolving a book name.

     - Parameter locale: Interface or document locale captured by the caller.
     - Returns: Exact region/script catalog, language alias, or English base; nil if none is bundled.
     - Side effects: First use initializes the immutable bundled data snapshot.
     - Failure modes: Unknown locales fall back to the English base; missing base data returns nil.
     */
    public static func catalog(for locale: Locale) -> [String: String]? {
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
        for key in aliases {
            if let values = mergedCatalogs[key] { return values }
        }
        return mergedCatalogs[""]
    }

    /**
     Loads all pinned UTF-8 resource overlays without module, database, or network access.

     - Returns: Full-domain property dictionaries indexed by their Java resource suffix.
     - Side effects: Reads SwordKit's resource bundle during static initialization only.
     - Failure modes: Missing base resources return no catalogs; malformed overlays are skipped.
     */
    private static func loadBundledCatalogs() -> [String: [String: String]] {
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
        var result: [String: [String: String]] = [:]
        for file in files where file.pathExtension == "properties" {
            let name = file.deletingPathExtension().lastPathComponent
            guard name == "BibleNames" || name.hasPrefix("BibleNames_"),
                  let overlay = parseProperties(at: file) else { continue }
            let suffix = name == "BibleNames" ? "" : String(name.dropFirst("BibleNames_".count))
            result[suffix] = base.merging(overlay) { _, localeValue in localeValue }
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

}
