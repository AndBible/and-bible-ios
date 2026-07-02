// SwordManager.swift — SWMgr wrapper for SwordKit

import Foundation
import CLibSword

/**
 Swift wrapper around SWORD's SWMgr (module manager).

 Manages the SWORD module installation directory, provides access to
 installed modules, and controls global rendering options.

 All libsword operations are serialized through `SwordRuntime` since
 the library and bridge keep process-global state and are not thread-safe.

 Usage:
 ```swift
 let manager = SwordManager(modulePath: "/path/to/sword/modules")
 let modules = manager.installedModules()
 if let kjv = manager.module(named: "KJV") {
     kjv.setKey("Gen 1:1")
     let text = kjv.renderText()
 }
 ```
 */
public final class SwordManager: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer

    /// Internal access to the C handle for InstallManager operations.
    var rawHandle: UnsafeMutableRawPointer { handle }
    private var moduleCache: [String: SwordModule] = [:]

    /// The filesystem path where SWORD modules are installed.
    public let modulePath: String

    /**
     Initialize a SwordManager with the given module path.
     - Parameter modulePath: Path to the SWORD modules directory.
       Pass nil to use the default system path.
     */
    public init?(modulePath: String? = nil) {
        let path = modulePath ?? SwordManager.defaultModulePath()
        self.modulePath = path

        guard let h = SwordRuntime.sync({ SWMgr_new(path) }) else { return nil }
        self.handle = h
    }

    deinit {
        SwordRuntime.sync {
            moduleCache.removeAll()
            SWMgr_delete(handle)
        }
    }

    /// Default path for SWORD modules in the app's documents directory.
    public static func defaultModulePath() -> String {
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let swordDir = documents.appendingPathComponent("sword", isDirectory: true)

        // Ensure the directory exists
        try? fileManager.createDirectory(at: swordDir, withIntermediateDirectories: true)

        return swordDir.path
    }

    // MARK: - Module Listing

    /// Get the number of installed modules visible to Android-compatible inventory.
    public var moduleCount: Int {
        installedModules().count
    }

    /**
     Lists all installed modules visible to Android/JSword-style book inventory.

     Normal SWORD modules come from libsword. Android custom drivers restored from Android module
     backups, such as `MyBibleDictionary`, are stored as `.conf` rows plus SQLite payloads but are
     not opened by libsword. Manifest-installed MyBible packages are stored in iOS' sidecar package
     directory. Android exposes both families through `Books.installed().books`; iOS mirrors that
     inventory here by projecting readable custom modules into `ModuleInfo` rows.

     - Returns: SWORD modules and readable Android custom modules, de-duplicated by initials.
     - Side effects: Reads `mods.d` configs, sidecar metadata, and checks custom payload files.
     - Failure modes: Malformed metadata and custom rows without readable payloads are skipped.
     */
    public func installedModules() -> [ModuleInfo] {
        let swordModules = SwordRuntime.sync {
            let count = SWMgr_getModuleCount(handle)
            var modules: [ModuleInfo] = []
            modules.reserveCapacity(Int(count))

            for i in 0..<count {
                guard let namePtr = SWMgr_getModuleNameByIndex(handle, i) else { continue }
                let name = String(cString: namePtr)
                guard let modHandle = SWMgr_getModuleByName(handle, name) else { continue }

                let mod = getOrCreateModule(name: name, handle: modHandle)
                modules.append(mod.info)
            }

            return modules
        }

        return Self.mergedInstalledModules(
            swordModules: swordModules,
            customModules: Self.androidCustomInstalledModules(modulePath: modulePath) +
                Self.myBiblePackageInstalledModules(modulePath: modulePath)
        )
    }

    /// List installed modules filtered by category.
    public func installedModules(category: ModuleCategory) -> [ModuleInfo] {
        installedModules().filter { $0.category == category }
    }

    /**
     Get a module by name.
     - Parameter name: The module abbreviation (e.g., "KJV").
     - Returns: The module, or nil if not installed.
     */
    public func module(named name: String) -> SwordModule? {
        SwordRuntime.sync {
            if let cached = moduleCache[name] { return cached }
            guard let modHandle = SWMgr_getModuleByName(handle, name) else { return nil }
            return getOrCreateModule(name: name, handle: modHandle)
        }
    }

    private func getOrCreateModule(name: String, handle: UnsafeMutableRawPointer) -> SwordModule {
        if let cached = moduleCache[name] { return cached }
        let mod = SwordModule(handle: handle, modulePath: modulePath)
        moduleCache[name] = mod
        return mod
    }

    /**
     Merges libsword modules and Android custom-driver modules using Android's initials identity.

     - Parameters:
       - swordModules: Modules enumerated by libsword.
       - customModules: Config-projected custom modules.
     - Returns: De-duplicated modules sorted by localized initials.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func mergedInstalledModules(
        swordModules: [ModuleInfo],
        customModules: [ModuleInfo]
    ) -> [ModuleInfo] {
        var seen = Set<String>()
        return (swordModules + customModules)
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /**
     Reads Android custom-driver configs that should be visible in installed-book inventory.

     - Parameter modulePath: SWORD module root containing `mods.d` and module payloads.
     - Returns: Module metadata rows for readable custom-driver modules.
     - Side effects: Reads local config files and checks payload existence.
     - Failure modes: Unsupported or incomplete custom-driver rows are skipped.
     */
    private static func androidCustomInstalledModules(modulePath: String) -> [ModuleInfo] {
        SwordModuleConfig.readAll(modulePath: modulePath)
            .filter { $0.isAndroidCustomDriver && customModulePayloadExists($0, modulePath: modulePath) }
            .map(\.moduleInfo)
    }

    /**
     Reads iOS sidecar-installed MyBible package modules into Android-compatible inventory rows.

     - Parameter modulePath: SWORD module root containing the `mybible` sidecar package directory.
     - Returns: Readable package modules sorted by initials.
     - Side effects: Reads `module.json` sidecars and checks extracted package payload files.
     - Failure modes: Missing directories, malformed sidecars, and sidecars without readable payloads
       are skipped.
     */
    static func myBiblePackageInstalledModules(modulePath: String) -> [ModuleInfo] {
        let fm = FileManager.default
        let installDirectory = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mybible", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: installDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let metadataURL = url.appendingPathComponent("module.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(InstalledMyBibleModule.self, from: data),
                  metadata.hasReadablePayload(in: url) else {
                return nil
            }
            return metadata.moduleInfo
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /**
     Reads Android add-on modules that provide reading-plan files.

     Android discovers add-on plans from repeated `AndBibleProvidesReadingPlan` config values and
     resolves each file relative to the module's adjusted `DataPath` location. iOS mirrors that
     behavior by using the config `DataPath` directory as the provider file base and by skipping
     missing or unsafe file references.

     - Parameter modulePath: SWORD module root containing `mods.d` and module payloads.
     - Returns: Readable add-on reading-plan providers in config order, de-duplicated by plan code.
     - Side effects: Reads local config files and checks provider file metadata.
     - Failure modes: Missing configs, unreadable files, and escaped paths are skipped.
     */
    public static func readingPlanProviders(
        modulePath: String = SwordManager.defaultModulePath()
    ) -> [SwordReadingPlanProvider] {
        var providersByCode: [String: SwordReadingPlanProvider] = [:]
        var orderedCodes: [String] = []

        for config in SwordModuleConfig.readAll(modulePath: modulePath) {
            let planFileNames = config.values["andbibleprovidesreadingplan"] ?? []
            for fileName in planFileNames {
                guard let fileURL = readingPlanProviderFileURL(
                    fileName: fileName,
                    config: config,
                    modulePath: modulePath
                ) else {
                    continue
                }

                let planCode = readingPlanCode(from: fileName)
                guard !planCode.isEmpty else { continue }

                let provider = SwordReadingPlanProvider(
                    planCode: planCode,
                    name: displayName(for: config),
                    description: config.values["shortpromo"]?.first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    fileURL: fileURL,
                    versification: nonEmpty(config.values["versification"]?.first),
                    isDateBased: config.values["andbiblereadingplandatebased"]?.first?
                        .caseInsensitiveCompare("True") == .orderedSame
                )

                if providersByCode[planCode] == nil {
                    orderedCodes.append(planCode)
                }
                providersByCode[planCode] = provider
            }
        }

        return orderedCodes.compactMap { providersByCode[$0] }
    }

    /**
     Validates that a custom Android module config points at a readable local payload.

     - Parameters:
       - config: Parsed module config.
       - modulePath: SWORD module root.
     - Returns: `true` when the expected payload exists.
     - Side effects: Checks file metadata on disk.
     - Failure modes: Missing or unreadable payloads return `false`.
     */
    private static func customModulePayloadExists(_ config: SwordModuleConfig, modulePath: String) -> Bool {
        let driver = config.modDrv.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch driver {
        case "mybiblebible", "mybiblecommentary", "mybibledictionary":
            guard !config.dataPath.isEmpty else { return false }
            return readablePath(
                appending: "module.SQLite3",
                to: config.dataPath,
                modulePath: modulePath,
                isDirectory: false
            )
        case "myswordbible", "myswordcommentary", "mysworddictionary":
            guard !config.dataPath.isEmpty else { return false }
            return readablePath(
                appending: "module.mybible",
                to: config.dataPath,
                modulePath: modulePath,
                isDirectory: false
            )
        case "eswordbible":
            return androidDatabaseFileExists(config, modulePath: modulePath)
        case "epubbook":
            guard !config.dataPath.isEmpty else { return false }
            return readablePath(config.dataPath, modulePath: modulePath, isDirectory: true)
        default:
            if config.values["andbiblemyswordmodule"]?.isEmpty == false ||
                config.values["andbibleeswordmodule"]?.isEmpty == false {
                return androidDatabaseFileExists(config, modulePath: modulePath)
            }
            if config.values["andbibleepubmodule"]?.isEmpty == false,
               let epubDir = config.values["andbibleepubdir"]?.first {
                return readablePath(epubDir, modulePath: modulePath, isDirectory: true)
            }
            return false
        }
    }

    /**
     Checks a custom Android SQLite-backed module's `AndBibleDbFile` payload.

     - Parameters:
       - config: Parsed module config with `AndBibleDbFile` metadata.
       - modulePath: SWORD module root.
     - Returns: `true` when the referenced database file is readable.
     - Side effects: Checks file metadata on disk.
     - Failure modes: Missing or unsafe paths return `false`.
     */
    private static func androidDatabaseFileExists(_ config: SwordModuleConfig, modulePath: String) -> Bool {
        guard let dbFile = config.values["andbibledbfile"]?.first else { return false }
        return readablePath(dbFile, modulePath: modulePath, isDirectory: false)
    }

    /**
     Builds and validates a child payload path under a config `DataPath`.

     - Parameters:
       - child: Expected payload filename.
       - dataPath: Config `DataPath` value.
       - modulePath: SWORD module root.
       - isDirectory: Whether the target should be checked as a directory path.
     - Returns: `true` when the resolved payload exists under the module root and is readable.
     - Side effects: Checks file metadata on disk.
     - Failure modes: Empty, escaped, missing, or unreadable paths return `false`.
     */
    private static func readablePath(
        appending child: String,
        to dataPath: String,
        modulePath: String,
        isDirectory: Bool
    ) -> Bool {
        let separator = dataPath.hasSuffix("/") ? "" : "/"
        return readablePath(
            "\(dataPath)\(separator)\(child)",
            modulePath: modulePath,
            isDirectory: isDirectory
        )
    }

    /**
     Resolves Android custom metadata paths inside the module root.

     - Parameters:
       - rawPath: Path from Android custom metadata.
       - modulePath: SWORD module root.
       - isDirectory: Whether the target should be checked as a directory path.
     - Returns: `true` when the resolved target is readable.
     - Side effects: Checks file metadata on disk.
     - Failure modes: Empty paths, parent-directory traversal, escaped absolute paths, and missing
       files return `false`.
     */
    private static func readablePath(_ rawPath: String, modulePath: String, isDirectory: Bool) -> Bool {
        readableURL(rawPath, modulePath: modulePath, isDirectory: isDirectory) != nil
    }

    /**
     Resolves Android custom metadata paths inside the module root and returns the readable URL.

     - Parameters:
       - rawPath: Path from Android custom metadata.
       - modulePath: SWORD module root.
       - isDirectory: Whether the target should be checked as a directory path.
     - Returns: Standardized URL when the resolved target is readable.
     - Side effects: Checks file metadata on disk.
     - Failure modes: Empty paths, parent-directory traversal, escaped absolute paths, and missing
       files return `nil`.
     */
    private static func readableURL(_ rawPath: String, modulePath: String, isDirectory: Bool) -> URL? {
        let normalized = rawPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !normalized.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." }) else {
            return nil
        }

        let rootURL = URL(fileURLWithPath: modulePath, isDirectory: true).standardizedFileURL
        let url = normalized.hasPrefix("/")
            ? URL(fileURLWithPath: normalized, isDirectory: isDirectory).standardizedFileURL
            : rootURL.appendingPathComponent(normalized, isDirectory: isDirectory).standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : "\(rootURL.path)/"
        guard url.path == rootURL.path || url.path.hasPrefix(rootPath) else {
            return nil
        }

        let fm = FileManager.default
        if isDirectory {
            var isDirectoryValue: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectoryValue),
                  isDirectoryValue.boolValue,
                  fm.isReadableFile(atPath: url.path) else {
                return nil
            }
            return url
        }
        return fm.isReadableFile(atPath: url.path) ? url : nil
    }

    /**
     Resolves one `AndBibleProvidesReadingPlan` file reference for a module config.

     - Parameters:
       - fileName: Config value containing the provider file name.
       - config: Parsed provider module config.
       - modulePath: SWORD module root.
     - Returns: Validated provider file URL, or `nil` when the file is unavailable or unsafe.
     - Side effects: Checks file metadata on disk.
     - Failure modes: Missing `DataPath`, escaped provider paths, and unreadable files return `nil`.
     */
    private static func readingPlanProviderFileURL(
        fileName: String,
        config: SwordModuleConfig,
        modulePath: String
    ) -> URL? {
        let normalizedFileName = fileName
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFileName.isEmpty else { return nil }

        let basePath = readingPlanProviderBasePath(config.dataPath)
        let separator = basePath.isEmpty || basePath.hasSuffix("/") ? "" : "/"
        return readableURL(
            "\(basePath)\(separator)\(normalizedFileName)",
            modulePath: modulePath,
            isDirectory: false
        )
    }

    /**
     Derives the Android add-on resource base from a module `DataPath`.

     JSword exposes add-on files relative to the adjusted module location. Directory `DataPath`
     values are already that location; single-file driver paths resolve through their parent
     directory, which is where add-on sidecar resources live.

     - Parameter dataPath: Normalized SWORD config `DataPath`.
     - Returns: Relative provider-file base path under the SWORD root.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func readingPlanProviderBasePath(_ dataPath: String) -> String {
        let path = dataPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasSuffix("/") else { return path }
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    /**
     Derives the stable Android plan code from a provider file reference.

     - Parameter fileName: `AndBibleProvidesReadingPlan` config value.
     - Returns: Last path component without its extension.
     - Side effects: none.
     - Failure modes: Empty or root-like paths return an empty string.
     */
    private static func readingPlanCode(from fileName: String) -> String {
        URL(fileURLWithPath: fileName)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /**
     Resolves the add-on display name Android uses for provided reading plans.

     - Parameter config: Provider module config.
     - Returns: Config description when present, otherwise module initials.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func displayName(for config: SwordModuleConfig) -> String {
        nonEmpty(config.description) ?? config.name
    }

    /**
     Trims optional config text and discards empty strings.

     - Parameter value: Raw config value.
     - Returns: Trimmed text, or `nil` when empty.
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

    // MARK: - Global Options

    /// Global rendering options that can be toggled.
    public enum GlobalOption: String, CaseIterable {
        case strongsNumbers = "Strong's Numbers"
        case morphology = "Morphological Tags"
        case footnotes = "Footnotes"
        case headings = "Headings"
        case crossReferences = "Cross-references"
        case redLetterWords = "Words of Christ in Red"
        case glosses = "Glosses"
        case morphSegmentation = "Morpheme Segmentation"
    }

    /**
     Set a global rendering option.
     - Parameters:
       - option: The option to set.
       - enabled: Whether the option should be enabled.
     */
    public func setGlobalOption(_ option: GlobalOption, enabled: Bool) {
        SwordRuntime.sync {
            SWMgr_setGlobalOption(handle, option.rawValue, enabled ? "On" : "Off")
        }
    }

    /**
     Get the current value of a global rendering option.
     - Parameter option: The option to query.
     - Returns: Whether the option is currently enabled.
     */
    public func isGlobalOptionEnabled(_ option: GlobalOption) -> Bool {
        SwordRuntime.sync {
            guard let value = SWMgr_getGlobalOption(handle, option.rawValue) else { return false }
            return String(cString: value) == "On"
        }
    }

    // MARK: - Paths

    /// The configuration path used by the manager.
    public var configPath: String {
        SwordRuntime.sync {
            guard let path = SWMgr_getConfigPath(handle) else { return "" }
            return String(cString: path)
        }
    }

    /// The prefix path (module install root).
    public var prefixPath: String {
        SwordRuntime.sync {
            guard let path = SWMgr_getPrefixPath(handle) else { return "" }
            return String(cString: path)
        }
    }

    // MARK: - Module Refresh

    /**
     Re-scan the module directory for changes.
     Call after installing or uninstalling modules.
     */
    public func refresh() {
        SwordRuntime.sync {
            moduleCache.removeAll()
        }
        // Recreate is the simplest way to refresh libsword's module list.
        // The caller should create a new SwordManager instance for a full refresh.
    }
}
