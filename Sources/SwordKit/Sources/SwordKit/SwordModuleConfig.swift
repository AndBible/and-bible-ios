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

    /// Case-insensitive config values keyed by lowercased property name.
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
            about: Self.firstValue("about", in: values) ?? "",
            shortPromo: Self.firstValue("shortpromo", in: values) ?? "",
            shortCopyright: Self.firstValue("shortcopyright", in: values) ?? "",
            copyright: Self.firstValue("copyright", in: values) ?? "",
            distributionLicense: Self.firstValue("distributionlicense", in: values) ?? "",
            unlockInfo: Self.firstValue("unlockinfo", in: values) ?? "",
            history: history,
            versification: Self.firstValue("versification", in: values) ?? "",
            osisId: name,
            repository: Self.firstValue("repository", in: values) ?? "",
            isBadDocument: Self.firstValue("baddocument", in: values) != nil,
            swordVersionDate: Self.firstValue("swordversiondate", in: values) ?? ""
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
            return values["andbiblemyswordmodule"]?.isEmpty == false ||
                values["andbibleeswordmodule"]?.isEmpty == false ||
                values["andbibleepubmodule"]?.isEmpty == false
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

     - Parameter content: UTF-8 or Latin-1 decoded `.conf` contents.
     - Returns: Parsed config when the file has a section name and `ModDrv`; otherwise `nil`.
     - Side effects: none.
     - Failure modes: Unsupported continuation syntax and unknown keys are ignored.
     */
    static func parse(_ content: String) -> SwordModuleConfig? {
        var name = ""
        var values: [String: [String]] = [:]
        var history: [String] = []

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if name.isEmpty {
                    name = String(trimmed.dropFirst().dropLast())
                }
                continue
            }

            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let equalsIndex = trimmed.firstIndex(of: "=") else {
                continue
            }

            let rawKey = String(trimmed[..<equalsIndex])
                .trimmingCharacters(in: .whitespaces)
            let key = rawKey.lowercased()
            let value = String(trimmed[trimmed.index(after: equalsIndex)...])
                .trimmingCharacters(in: .whitespaces)
            values[key, default: []].append(value)

            if key == "history" {
                history.append(value)
            } else if key.hasPrefix("history_") {
                let version = String(rawKey.dropFirst("history_".count))
                history.append("\(version) \(value)")
            }
        }

        guard !name.isEmpty,
              let modDrv = firstValue("moddrv", in: values),
              !modDrv.isEmpty else {
            return nil
        }

        return SwordModuleConfig(
            name: name,
            description: firstValue("description", in: values) ?? "",
            categoryString: firstValue("category", in: values) ?? "",
            language: firstValue("lang", in: values) ?? "en",
            modDrv: modDrv,
            dataPath: normalizedDataPath(firstValue("datapath", in: values) ?? "", modDrv: modDrv),
            // JSword's SwordBookMetaData defaults a missing Version to 1.0; Android compares that
            // default on both sides, so versionless modules never report a phantom update.
            version: firstValue("version", in: values).flatMap { $0.isEmpty ? nil : $0 } ?? "1.0",
            installSize: firstValue("installsize", in: values) ?? "",
            direction: firstValue("direction", in: values) ?? "LtoR",
            features: ModuleFeatures.fromConfigValues(
                (values["feature"] ?? []) + (values["globaloptionfilter"] ?? [])
            ),
            history: history,
            values: values,
            content: content
        )
    }

    /**
     Reads and parses a module config by name.

     - Parameters:
       - name: Module initials.
       - modulePath: SWORD module root containing `mods.d`.
     - Returns: Parsed config when the file can be read and parsed.
     - Side effects: Reads one file from disk.
     - Failure modes: Missing or malformed configs return `nil`.
     */
    static func read(name: String, modulePath: String) -> SwordModuleConfig? {
        let confURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("\(name.lowercased()).conf")
        return read(url: confURL)
    }

    /**
     Reads and parses every config in an installed module directory.

     - Parameter modulePath: SWORD module root containing `mods.d`.
     - Returns: Parsed configs sorted by module initials.
     - Side effects: Reads the `mods.d` directory and config files.
     - Failure modes: Missing directories or malformed configs are skipped.
     */
    static func readAll(modulePath: String) -> [SwordModuleConfig] {
        let modsURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: modsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.pathExtension.lowercased() == "conf" }
            .compactMap(read(url:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /**
     Reads and parses one config file URL.

     - Parameter url: Local config file URL.
     - Returns: Parsed config when readable.
     - Side effects: Reads `url` from disk.
     - Failure modes: UTF-8 and Latin-1 decode failures return `nil`.
     */
    private static func read(url: URL) -> SwordModuleConfig? {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) ??
                String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        return parse(content)
    }

    /**
     Returns the first config value for a lowercased key.

     - Parameters:
       - key: Lowercased config key.
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
