// SwordModuleConfig.swift -- Shared SWORD/Android module config projection

import Foundation

/**
 Parsed metadata from one SWORD-compatible `.conf` file.

 Android stores custom MyBible/MySword/EPUB modules in the same installed book registry as normal
 SWORD modules by registering custom JSword `BookType`s. iOS needs the same metadata projection even
 when libsword cannot open those custom drivers, so this parser owns the shared config rules used by
 catalog refresh, installed-module inventory, and feature detection.
 */
struct SwordModuleConfig: Sendable {
    /// Exact config file that produced this value, or nil for an in-memory parse.
    let sourceURL: URL?

    /// Module initials from the section header.
    let name: String

    /// User-visible module description.
    let description: String

    /// Raw `Category` value when present.
    let categoryString: String

    /// Module language code.
    let language: String

    /// Raw `ModDrv` value.
    let modDrv: String

    /// Normalized `DataPath` value with leading `./` removed and directory-like paths suffixed.
    let dataPath: String

    /// Module version string.
    let version: String

    /// Raw `InstallSize` value.
    let installSize: String

    /// Raw text direction value.
    let direction: String

    /// Feature flags collected from repeated `Feature` and `GlobalOptionFilter` lines.
    let features: ModuleFeatures

    /// JSword-compatible version history values collected from `History` and `History_x.y` lines.
    let history: [String]

    /// Case-sensitive config values keyed by the exact Java `IniSection` property spelling.
    let values: [String: [String]]

    /// Original config content.
    let content: String

    /// Category resolved through Android custom-driver and SWORD fallback rules.
    var category: ModuleCategory {
        ModuleCategory(typeString: categoryString, modDrv: modDrv)
    }

    /// Android `CommonUtils.showAbout(...)` metadata projected from config values.
    var aboutMetadata: ModuleAboutMetadata {
        ModuleAboutMetadata(
            about: Self.firstValue("About", in: values) ?? "",
            shortPromo: Self.firstValue("ShortPromo", in: values) ?? "",
            shortCopyright: Self.firstValue("ShortCopyright", in: values) ?? "",
            copyright: Self.firstValue("Copyright", in: values) ?? "",
            distributionLicense: Self.firstValue("DistributionLicense", in: values) ?? "",
            unlockInfo: Self.firstValue("UnlockInfo", in: values) ?? "",
            history: history,
            versification: Self.firstValue("Versification", in: values) ?? "",
            osisId: name,
            repository: Self.firstValue("Repository", in: values) ?? "",
            isBadDocument: Self.firstValue("BadDocument", in: values) != nil,
            swordVersionDate: Self.firstValue("SwordVersionDate", in: values) ?? ""
        )
    }

    /// Whether the config belongs to an Android custom book driver that libsword does not expose.
    var isAndroidCustomDriver: Bool {
        switch modDrv.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mybiblebible",
             "mybiblecommentary",
             "mybibledictionary",
             "myswordbible",
             "myswordcommentary",
             "mysworddictionary",
             "eswordbible",
             "epubbook":
            return true
        default:
            return values["AndBibleMySwordModule"]?.isEmpty == false ||
                values["AndBibleESwordModule"]?.isEmpty == false ||
                values["AndBibleEpubModule"]?.isEmpty == false
        }
    }

    /// Projects this config into the common module metadata row.
    var moduleInfo: ModuleInfo {
        ModuleInfo(
            name: name,
            description: description,
            category: category,
            language: language,
            moduleDriver: modDrv,
            version: version,
            features: features,
            isRightToLeft: direction.caseInsensitiveCompare("RtoL") == .orderedSame,
            aboutMetadata: aboutMetadata
        )
    }

    /**
     Parses one SWORD-compatible config file.

     - Parameters:
       - content: UTF-8 or Latin-1 decoded `.conf` contents.
       - sourceURL: Exact file owner when parsing an installed config, otherwise nil.
     - Returns: Parsed config when the file has a section name and `ModDrv`; otherwise `nil`.
     - Side effects: none.
     - Failure modes: Unknown keys and malformed lines are ignored.
     */
    static func parse(_ content: String, sourceURL: URL? = nil) -> SwordModuleConfig? {
        var name = ""
        var values: [String: [String]] = [:]
        var history: [String] = []

        let lines = content.components(separatedBy: .newlines)
        var lineIndex = 0
        /**
         Consumes the next meaningful config line from the captured source.

         - Returns: The next Java-trimmed, BOM-adjusted nonempty noncomment line, or `nil` at EOF.
         - Side effects: Advances captured `lineIndex` across every inspected line, including lines
           skipped because they are empty or begin with `#` or `;`.
         - Failure modes: None; scanning is deterministic and does not throw.
         */
        func nextMeaningfulLine() -> String? {
            while lineIndex < lines.count {
                var line = SwordJavaStringIdentity.trim(lines[lineIndex])
                lineIndex += 1
                if line.hasPrefix("\u{FEFF}") {
                    line.removeFirst()
                }
                guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else {
                    continue
                }
                return line
            }
            return nil
        }

        while let line = nextMeaningfulLine() {
            if line.hasPrefix("[") && line.hasSuffix("]") {
                name = String(line.dropFirst().dropLast())
                continue
            }

            guard let equalsIndex = line.firstIndex(of: "=") else {
                continue
            }

            let key = SwordJavaStringIdentity.trim(String(line[..<equalsIndex]))
            var value = SwordJavaStringIdentity.trim(
                String(line[line.index(after: equalsIndex)...])
            )
            while value.hasSuffix("\\") {
                value = SwordJavaStringIdentity.trim(String(value.dropLast())) + "\n"
                guard let continuation = nextMeaningfulLine() else { break }
                value += continuation
            }
            values[key, default: []].append(value)

            if key == "History" {
                history.append(value)
            } else if key.hasPrefix("History_") {
                let version = String(key.dropFirst("History_".count))
                history.append("\(version) \(value)")
            }
        }

        guard !name.isEmpty,
              let modDrv = firstValue("ModDrv", in: values),
              !modDrv.isEmpty else {
            return nil
        }

        return SwordModuleConfig(
            sourceURL: sourceURL,
            name: name,
            description: firstValue("Description", in: values) ?? name,
            categoryString: firstValue("Category", in: values) ?? "",
            language: firstValue("Lang", in: values) ?? "en",
            modDrv: modDrv,
            dataPath: normalizedDataPath(firstValue("DataPath", in: values) ?? "", modDrv: modDrv),
            // JSword's SwordBookMetaData defaults a missing Version to 1.0; Android compares that
            // default on both sides, so versionless modules never report a phantom update.
            version: firstValue("Version", in: values).flatMap { $0.isEmpty ? nil : $0 } ?? "1.0",
            installSize: firstValue("InstallSize", in: values) ?? "",
            direction: firstValue("Direction", in: values) ?? "LtoR",
            features: ModuleFeatures.fromConfigValues(
                (values["Feature"] ?? []) + (values["GlobalOptionFilter"] ?? [])
            ),
            history: history,
            values: values,
            content: content
        )
    }

    /**
     Reads and parses a module config by its Java section identity.

     Config filenames are conventions rather than book identity. Exact UTF-16 section initials win;
     a unique Java case-insensitive alias is retained for compatibility, while ambiguous aliases fail
     closed so `FOO` and `foo` cannot borrow each other's metadata.

     - Parameters:
       - name: Exact module initials or one unambiguous Java case-insensitive alias.
       - modulePath: SWORD module root containing `mods.d`.
     - Returns: The exact config, otherwise one unique case-insensitive match.
     - Side effects: Enumerates and reads installed config files.
     - Failure modes: Missing, malformed, and ambiguous config identities return `nil`.
     */
    static func read(name: String, modulePath: String) -> SwordModuleConfig? {
        let configs = readAll(modulePath: modulePath)
        let identity = SwordJavaExactStringIdentity(name)
        let exactMatches = configs.filter {
            SwordJavaExactStringIdentity($0.name) == identity
        }
        if exactMatches.count == 1 {
            return exactMatches[0]
        }
        guard exactMatches.isEmpty else { return nil }
        let aliases = configs.filter {
            SwordJavaStringIdentity.equalsIgnoreCase($0.name, name)
        }
        return aliases.count == 1 ? aliases[0] : nil
    }

    /**
     Reads and parses every config in an installed module directory.

     Pinned JSword's `SwordBookPath.getBookList(File)` returns `File.list(FilenameFilter)` directly,
     and `SwordBookDriver` consumes that array without sorting it. Public book order is imposed later
     by `Books`' `TreeSet`; this lower-level reader must therefore preserve the platform directory
     sequence rather than applying a host-locale or initials sort. The same filename filter accepts
     only case-sensitive `.conf` suffixes and excludes the reserved `globals.` prefix.

     - Parameter modulePath: SWORD module root containing `mods.d`.
     - Returns: Parsed configs in the order supplied by the platform directory enumeration.
     - Side effects: Reads the `mods.d` directory and config files.
     - Failure modes: Missing directories or malformed configs are skipped.
     */
    static func readAll(modulePath: String) -> [SwordModuleConfig] {
        let modsURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: modsURL,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []

        return urls
            .filter {
                $0.lastPathComponent.hasSuffix(".conf")
                    && !$0.lastPathComponent.hasPrefix("globals.")
            }
            .compactMap(read(url:))
    }

    /**
     Reads and parses one config file URL.

     - Parameter url: Local config file URL.
     JSword first parses UTF-8 only to inspect the exact case-sensitive `Encoding` property. Java's
     decoders replace malformed input with U+FFFD. JSword keeps that lossy UTF-8 parse only for a
     case-insensitive `UTF-8` value; missing, wrong-case, and every non-UTF-8 declaration cause the
     original bytes to be reloaded with the same replacement policy as Windows-1252 (`Latin-1`).

     - Returns: Parsed config under JSword's selected character encoding when readable.
     - Side effects: Reads `url` from disk.
     - Failure modes: Unreadable bytes, malformed metadata, and decode failures return `nil`.
     */
    static func read(url: URL) -> SwordModuleConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let utf8Content = String(decoding: data, as: UTF8.self)
        if let utf8Config = parse(utf8Content, sourceURL: url),
           utf8Config.values["Encoding"]?.first?
            .caseInsensitiveCompare("UTF-8") == .orderedSame {
            return utf8Config
        }
        let latin1Content = decodeWindows1252ReplacingMalformed(data)
        return parse(latin1Content, sourceURL: url)
    }

    /**
     Decodes bytes with Java's Windows-1252 replacement behavior used by JSword's config reload.

     Foundation's strict Windows-1252 initializer can reject the five undefined C1 bytes, while
     Java's default `CharsetDecoder` substitutes U+FFFD and continues parsing the file. This table
     pins every C1 mapping explicitly; ASCII and U+00A0...U+00FF retain their scalar values.

     - Parameter data: Original config bytes after the UTF-8 encoding probe is not retained.
     - Returns: A complete string with every undefined Windows-1252 byte replaced by U+FFFD.
     - Side effects: None.
     - Failure modes: None; every byte has either a defined scalar or the replacement scalar.
     - Complexity: O(N) time and output storage for N input bytes.
     */
    private static func decodeWindows1252ReplacingMalformed(_ data: Data) -> String {
        let c1Scalars: [UInt32] = [
            0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
            0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
            0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
            0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
        ]
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(data.count)
        for byte in data {
            let scalarValue: UInt32
            if (0x80...0x9F).contains(byte) {
                scalarValue = c1Scalars[Int(byte - 0x80)]
            } else {
                scalarValue = UInt32(byte)
            }
            scalars.append(Unicode.Scalar(scalarValue)!)
        }
        return String(scalars)
    }

    /**
     Returns the first config value for one exact case-sensitive Java property key.

     - Parameters:
       - key: Canonical config key spelling used by pinned JSword callers.
       - values: Parsed config value map.
     - Returns: First value, or `nil` when absent.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func firstValue(_ key: String, in values: [String: [String]]) -> String? {
        values[key]?.first
    }

    /**
     Normalizes `DataPath` for catalog and install consumers.

     - Parameters:
       - value: Raw `DataPath` value.
       - modDrv: Raw module driver.
     - Returns: Relative path with leading `./` removed. Directory-like paths end in `/`.
     - Side effects: none.
     - Failure modes: Empty paths remain empty.
     */
    private static func normalizedDataPath(_ value: String, modDrv: String) -> String {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("./") {
            path = String(path.dropFirst(2))
        }
        guard !path.isEmpty else { return path }

        let driver = modDrv.lowercased()
        let singleFileDrivers: Set<String> = ["rawld", "rawld4", "zld", "rawgenbook", "rawfiles"]
        if singleFileDrivers.contains(driver) {
            return path
        }
        return path.hasSuffix("/") ? path : "\(path)/"
    }
}
