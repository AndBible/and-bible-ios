// ModuleStoreInstalledRegistrationReader.swift -- side-effect-free installed registration metadata

import Foundation

/**
 One installed registration read directly from SWORD configuration metadata.

 Normal SWORD configurations and iOS' durable Android-family registrations share `mods.d`, but
 callers must preserve their ownership distinction. Android-family rows carry the exact backing
 path and family that Android's startup registrars own; ordinary SWORD rows own their configuration
 and SWORD payload instead.
 */
public struct ModuleStoreInstalledRegistration: Sendable {
    /** Identifies which registrar owns the installed row. */
    public enum Ownership: Equatable, Sendable {
        /// An ordinary supported SWORD configuration.
        case swordConfiguration

        /// A durable iOS projection of an Android raw-file registrar.
        case androidFamily(family: String, relativePath: String)
    }

    /// Installed module metadata projected from the configuration.
    public let moduleInfo: ModuleInfo

    /// Registrar ownership used by backup identity allocation.
    public let ownership: Ownership

    /// Exact module-root-relative `.conf` path that produced this registration.
    public let configurationRelativePath: String

    /**
     Creates one immutable registration snapshot.

     - Parameters:
       - moduleInfo: Parsed installed-book metadata.
       - ownership: Registrar that owns the row and its backing payload.
       - configurationRelativePath: Exact validated `.conf` path below the module root.
     - Side effects: none.
     - Failure modes: This initializer cannot fail; the reader validates each supplied path.
     */
    public init(
        moduleInfo: ModuleInfo,
        ownership: Ownership,
        configurationRelativePath: String = ""
    ) {
        self.moduleInfo = moduleInfo
        self.ownership = ownership
        self.configurationRelativePath = configurationRelativePath
    }
}

/**
 Reads installed registration metadata without constructing libsword's mutable manager.

 `SWMgr` initialization can create global configuration and cache files even when a caller only
 wants inventory. Backup inspection and other read-only workflows use this reader so observation
 cannot mutate the module tree. Malformed, unsupported, incomplete, or escaped registrations are
 omitted just as Android omits books that fail startup registration.
 */
public enum ModuleStoreInstalledRegistrationReader {
    /** Metadata-only support predicate used instead of `ModuleInfo.isSupported`. */
    public typealias StaticSupportValidator = @Sendable (ModuleInfo) -> Bool

    /// Upper bound for one installed `.conf`, matching the metadata-scale contract of installers.
    private static let maximumConfigurationByteCount = 1_024 * 1_024

    /// Case-insensitive JSword drivers registered by Android before installed-book discovery.
    private static let androidSupportedModuleDrivers: Set<String> = [
        "rawtext", "ztext", "ztext4",
        "rawcom", "rawcom4", "zcom", "zcom4", "hrefcom", "rawfiles",
        "rawld", "rawld4", "zld", "rawgenbook",
        "mybiblebible", "mybiblecommentary", "mybibledictionary",
        "myswordbible", "myswordcommentary", "mysworddictionary",
        "epubbook", "eswordbible",
    ]

    /// Supported generated-registration background image extensions.
    private static let backgroundExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]

    /// Canonical durable family markers paired with their required module-root directories.
    private static let generatedFamilyRoots: [String: String] = [
        "myBible": "mybible",
        "mySword": "mysword",
        "eSword": "esword",
        "epub": "epub",
        "ttf": "ttf",
        "background": "background",
        "prompts": "prompts",
    ]

    /**
     Default side-effect-free support predicate for installed configuration snapshots.

     The predicate intentionally stops at Android's static driver and JSword versification
     registries. It never asks libsword whether a Bible canon can be rendered.
     */
    public static let metadataOnlySupportValidator: StaticSupportValidator = { module in
        let driver = module.moduleDriver
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ModuleStoreInstalledRegistrationReader.androidSupportedModuleDrivers.contains(driver)
            && JSwordVersificationRegistry.supports(module.aboutMetadata.versification)
    }

    /**
     Reads supported SWORD rows and validated durable Android-family registrations.

     - Parameters:
       - modulePath: SWORD root containing `mods.d` and Android-family backing files.
       - fileManager: Filesystem implementation used for backing-path validation.
       - staticSupportValidator: Injectable metadata-only admission seam. Production uses the static
         Android driver and JSword versification registries without consulting libsword globals.
     - Returns: Registrations in the same deterministic configuration order used by `SwordManager`.
     - Side effects: Reads configuration and backing-file metadata only; creates no directories,
       cache files, globals, or migration output.
     - Failure modes: Missing roots and malformed rows produce an empty or partial snapshot. A bad
       row never hides independently readable siblings.
     */
    public static func read(
        modulePath: String,
        fileManager: FileManager = .default,
        staticSupportValidator: StaticSupportValidator = metadataOnlySupportValidator
    ) -> [ModuleStoreInstalledRegistration] {
        let requestedRootURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .standardizedFileURL
        guard let rootValues = try? requestedRootURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        rootValues.isDirectory == true,
        rootValues.isSymbolicLink != true else {
            return []
        }
        let rootURL = requestedRootURL.resolvingSymlinksInPath().standardizedFileURL

        return readConfigurations(rootURL: rootURL, fileManager: fileManager).compactMap { row in
            let config = row.configuration
            if isGeneratedRegistration(config) {
                guard let ownership = validatedGeneratedOwnership(
                    config: config,
                    rootURL: rootURL,
                    fileManager: fileManager
                ) else {
                    return nil
                }
                return ModuleStoreInstalledRegistration(
                    moduleInfo: config.moduleInfo,
                    ownership: ownership,
                    configurationRelativePath: row.relativePath
                )
            }

            let configurationStem = ((row.relativePath as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            guard !config.isAndroidCustomDriver,
                  configurationStem.caseInsensitiveCompare(config.name) == .orderedSame,
                  staticSupportValidator(config.moduleInfo) else {
                return nil
            }
            return ModuleStoreInstalledRegistration(
                moduleInfo: config.moduleInfo,
                ownership: .swordConfiguration,
                configurationRelativePath: row.relativePath
            )
        }
    }

    /** Parsed configuration paired with its exact module-root-relative source path. */
    private struct ConfigurationRow {
        /// Parsed configuration metadata.
        let configuration: SwordModuleConfig

        /// Exact direct `mods.d` file path.
        let relativePath: String
    }

    /**
     Reads direct real `.conf` files with containment and allocation bounds.

     Each malformed sibling is skipped independently. Files are parsed with SWORD's shared config
     parser after UTF-8 or ISO-Latin-1 decoding, preserving the same metadata semantics as the live
     manager without invoking it.
     */
    private static func readConfigurations(
        rootURL: URL,
        fileManager: FileManager
    ) -> [ConfigurationRow] {
        let modsURL = rootURL.appendingPathComponent("mods.d", isDirectory: true)
        guard let modsValues = try? modsURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        modsValues.isDirectory == true,
        modsValues.isSymbolicLink != true else {
            return []
        }
        let resolvedModsURL = modsURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard resolvedModsURL.path.hasPrefix(rootPrefix),
              let urls = try? fileManager.contentsOfDirectory(
                at: modsURL,
                includingPropertiesForKeys: [
                    .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        let modsPrefix = resolvedModsURL.path.hasSuffix("/")
            ? resolvedModsURL.path
            : resolvedModsURL.path + "/"

        return urls.compactMap { url -> ConfigurationRow? in
            guard url.pathExtension.caseInsensitiveCompare("conf") == .orderedSame,
                  let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let byteCount = values.fileSize,
                  byteCount <= maximumConfigurationByteCount else {
                return nil
            }
            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedURL.path.hasPrefix(modsPrefix),
                  let data = boundedData(at: resolvedURL, fileManager: fileManager),
                  let content = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                return nil
            }
            guard let configuration = SwordModuleConfig.parse(content) else { return nil }
            return ConfigurationRow(
                configuration: configuration,
                relativePath: "mods.d/\(url.lastPathComponent)"
            )
        }
        .sorted {
            $0.configuration.name.localizedCaseInsensitiveCompare($1.configuration.name)
                == .orderedAscending
        }
    }

    /** Reads at most the configured metadata limit plus one sentinel byte. */
    private static func boundedData(at url: URL, fileManager: FileManager) -> Data? {
        guard fileManager.isReadableFile(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumConfigurationByteCount + 1),
              data.count <= maximumConfigurationByteCount else {
            return nil
        }
        return data
    }

    /** Returns whether a config declares iOS' durable Android-family registration marker. */
    private static func isGeneratedRegistration(_ config: SwordModuleConfig) -> Bool {
        config.values["AndBibleIOSGeneratedRegistration"]?.first?
            .caseInsensitiveCompare("true") == .orderedSame
    }

    /** Returns a trimmed non-empty metadata value. */
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /** Validates every generated-registration invariant before its identity can be reserved. */
    private static func validatedGeneratedOwnership(
        config: SwordModuleConfig,
        rootURL: URL,
        fileManager: FileManager
    ) -> ModuleStoreInstalledRegistration.Ownership? {
        guard let descriptor = generatedRegistrationDescriptor(config),
              let familyRoot = generatedFamilyRoots[descriptor.family] else {
            return nil
        }
        let family = descriptor.family
        let relativePath = descriptor.relativePath
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        let components = normalized
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !normalized.hasPrefix("/"),
              !normalized.contains("\0"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }

        var lexicalURL = rootURL
        for component in components {
            lexicalURL.appendPathComponent(component)
            guard let values = try? lexicalURL.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            ), values.isSymbolicLink != true else {
                return nil
            }
        }
        let targetURL = lexicalURL.standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard targetURL.path.hasPrefix(rootPrefix), fileManager.isReadableFile(atPath: targetURL.path)
        else {
            return nil
        }
        guard let values = try? targetURL.resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return nil
        }
        guard values.isSymbolicLink != true,
              generatedRegistrationMatches(
                config: config,
                family: family,
                familyRoot: familyRoot,
                relativePath: normalized,
                components: components,
                isRegularFile: values.isRegularFile == true,
                isDirectory: values.isDirectory == true
              ) else {
            return nil
        }
        return .androidFamily(family: family, relativePath: normalized)
    }

    /** Resolves current markers or the bounded legacy manual-TTF registration shape. */
    private static func generatedRegistrationDescriptor(
        _ config: SwordModuleConfig
    ) -> (family: String, relativePath: String)? {
        if let family = nonEmpty(config.values["AndBibleIOSRegistrationFamily"]?.first),
           let relativePath = nonEmpty(config.values["AndBibleIOSRegistrationPath"]?.first) {
            return (family, relativePath)
        }
        guard config.values["AndBibleIOSManualTtf"]?.first?
            .caseInsensitiveCompare("true") == .orderedSame,
            config.values["AndBibleProvidesFont"]?.count == 1,
            let provider = config.values["AndBibleProvidesFont"]?.first,
            let separator = provider.firstIndex(of: ";") else {
            return nil
        }
        let fileName = provider[provider.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = config.dataPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !fileName.isEmpty, parent == "ttf" || parent.hasPrefix("ttf/") else {
            return nil
        }
        return ("ttf", "\(parent)/\(fileName)")
    }

    /**
     Applies the complete generated-registration schema for one Android family.

     - Parameters:
       - config: Parsed durable configuration whose generated marker was already recognized.
       - family: Canonical Android family marker.
       - familyRoot: Required module-root directory for the family.
       - relativePath: Exact validated backing path.
       - components: Lexical path components below the module root.
       - isRegularFile: Whether the no-follow backing node is a regular file.
       - isDirectory: Whether the no-follow backing node is a directory.
     - Returns: `true` only when category, driver, family markers, identity, path, extension, depth,
       and backing-node type match a configuration generated by the restore service.
     - Side effects: None.
     - Failure modes: Missing, repeated, malformed, or cross-family metadata returns `false`.
     */
    private static func generatedRegistrationMatches(
        config: SwordModuleConfig,
        family: String,
        familyRoot: String,
        relativePath: String,
        components: [String],
        isRegularFile: Bool,
        isDirectory: Bool
    ) -> Bool {
        guard components.count >= 2, components[0] == familyRoot else { return false }
        let fileName = components.last ?? ""
        let stem = (fileName as NSString).deletingPathExtension
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        let driver = config.modDrv.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expectedParent = components.dropLast().joined(separator: "/")
        let dataPath = config.dataPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let singleValue: (String) -> String? = { key in
            guard let values = config.values[key], values.count == 1 else { return nil }
            return values[0]
        }
        let categoryMatches: (String) -> Bool = { expected in
            singleValue("Category")?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(expected) == .orderedSame
        }
        let markerEquals: (String, String) -> Bool = { key, expected in
            singleValue(key) == expected
        }
        let databaseCategory: String?
        switch driver {
        case "mybiblebible", "myswordbible", "eswordbible":
            databaseCategory = "Biblical Texts"
        case "mybiblecommentary", "myswordcommentary":
            databaseCategory = "Commentaries"
        case "mybibledictionary", "mysworddictionary":
            databaseCategory = "Lexicons / Dictionaries"
        default:
            databaseCategory = nil
        }

        switch family {
        case "myBible":
            return isRegularFile
                && fileExtension == "sqlite3"
                && ["mybiblebible", "mybiblecommentary", "mybibledictionary"].contains(driver)
                && databaseCategory.map(categoryMatches) == true
                && config.name.caseInsensitiveCompare(
                    "MyBible-" + MyBibleAndroidFilenameIdentity.sanitizeModuleName(stem)
                ) == .orderedSame
                && markerEquals("AndBibleMyBibleModule", "1")
                && markerEquals("AndBibleDbFile", relativePath)
                && dataPath == expectedParent
        case "mySword":
            return isRegularFile
                && fileName.lowercased().hasSuffix(".mybible")
                && ["myswordbible", "myswordcommentary", "mysworddictionary"].contains(driver)
                && databaseCategory.map(categoryMatches) == true
                && config.name.caseInsensitiveCompare(
                    "MySword-" + sanitizeMySwordModuleName(stem)
                ) == .orderedSame
                && markerEquals("AndBibleMySwordModule", "1")
                && markerEquals("AndBibleDbFile", relativePath)
                && dataPath == expectedParent
        case "eSword":
            return isRegularFile
                && components.count == 2
                && ["bblx", "bbli"].contains(fileExtension)
                && driver == "eswordbible"
                && categoryMatches("Biblical Texts")
                && config.name.caseInsensitiveCompare(
                    "ESword-" + sanitizeESwordModuleName(stem)
                ) == .orderedSame
                && markerEquals("AndBibleESwordModule", "1")
                && markerEquals("AndBibleDbFile", relativePath)
                && dataPath == expectedParent
        case "epub":
            return isDirectory
                && components.count == 2
                && driver == "epubbook"
                && categoryMatches("Generic Books")
                && config.name.caseInsensitiveCompare(epubInitials(fileName)) == .orderedSame
                && markerEquals("AndBibleEpubModule", "1")
                && markerEquals("AndBibleEpubDir", relativePath)
                && dataPath == relativePath
        case "ttf":
            let description = singleValue("Description") ?? ""
            return isRegularFile
                && fileExtension == "ttf"
                && driver == "rawgenbook"
                && categoryMatches("And Bible")
                && config.name.caseInsensitiveCompare("TTF_\(stem)") == .orderedSame
                && markerEquals("AndBibleProvidesFont", "\(description);\(fileName)")
                && dataPath == expectedParent
        case "background":
            let base = "BGIMG_" + syntheticResourceSuffix(stem)
            let name = config.name
            let suffix = name.dropFirst(min(name.count, base.count))
            let validSuffix = name.caseInsensitiveCompare(base) == .orderedSame
                || (name.lowercased().hasPrefix(base.lowercased() + "_")
                    && (Int(suffix.dropFirst()) ?? 0) >= 2)
            let description = singleValue("Description") ?? ""
            return isRegularFile
                && backgroundExtensions.contains(fileExtension)
                && driver == "rawgenbook"
                && categoryMatches("And Bible")
                && validSuffix
                && markerEquals(
                    "AndBibleProvidesBackgroundImage",
                    "\(description);\(fileName)"
                )
                && dataPath == expectedParent
        case "prompts":
            return isRegularFile
                && components.count == 2
                && fileExtension == "csv"
                && driver == "rawgenbook"
                && categoryMatches("And Bible")
                && config.name.caseInsensitiveCompare("Prompts_\(stem)") == .orderedSame
                && markerEquals("AndBibleProvidesPrompts", fileName)
                && dataPath == expectedParent
        default:
            return false
        }
    }

    /**
     Applies Android's historical MySword `[^a-zA-z0-9]` replacement.

     - Parameter value: Exact payload basename before the `MySword-` prefix.
     - Returns: ASCII digits and code points `A...z` unchanged; every other Unicode scalar becomes
       one underscore.
     - Side effects: None.
     - Failure modes: None; every Swift string has a finite Unicode-scalar projection.
     */
    private static func sanitizeMySwordModuleName(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            let code = scalar.value
            return (48...57).contains(code) || (65...122).contains(code)
                ? String(scalar)
                : "_"
        }.joined()
    }

    /** Applies e-Sword's exact Android `[^A-Za-z0-9]` replacement. */
    private static func sanitizeESwordModuleName(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            let code = scalar.value
            return (48...57).contains(code)
                || (65...90).contains(code)
                || (97...122).contains(code)
                ? String(scalar)
                : "_"
        }.joined()
    }

    /** Derives Android's EPUB identity from the exact display directory name. */
    private static func epubInitials(_ value: String) -> String {
        "Epub-" + value.unicodeScalars.map { scalar in
            let code = scalar.value
            return (48...57).contains(code) || (65...122).contains(code)
                ? String(scalar)
                : "_"
        }.joined()
    }

    /** Mirrors Android's synthetic background identity token. */
    private static func syntheticResourceSuffix(_ value: String) -> String {
        let mapped = value.replacingOccurrences(
            of: "[^A-Za-z0-9]+",
            with: "_",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return mapped.isEmpty ? "image" : mapped
    }
}
