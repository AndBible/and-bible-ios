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
    private var sessionUnlockedModuleNames: Set<String> = []

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

     Normal SWORD configs are enumerated from `mods.d` and resolved through libsword one by one.
     This avoids the flat bridge's process-global module-list cache while preserving locked modules
     in inventory so they can expose Android's unlock action. Android custom drivers restored from
     Android module backups, such as `MyBibleDictionary`, are stored as `.conf` rows plus SQLite
     payloads but are not opened by libsword. Manifest-installed MyBible packages are stored in iOS'
     sidecar package directory. Android exposes both families through `Books.installed().books`;
     iOS mirrors that inventory here by projecting readable custom modules into `ModuleInfo` rows.

     - Returns: SWORD modules and readable Android custom modules, de-duplicated by initials.
     - Side effects: Reads `mods.d` configs, sidecar metadata, and checks custom payload files.
     - Failure modes: Malformed configs, modules libsword cannot resolve, and custom rows without
       readable payloads are skipped.
     - Note: Locked encrypted modules remain visible with `isUnlocked == false`; a key verified in
       this manager session overrides only that module's stale native metadata snapshot.
     */
    public func installedModules() -> [ModuleInfo] {
        let swordModules = SwordRuntime.sync {
            var modules: [ModuleInfo] = []
            for config in SwordModuleConfig.readAll(modulePath: modulePath) {
                guard !config.isAndroidCustomDriver else { continue }
                let name = config.name
                guard let modHandle = SWMgr_getModuleByName(handle, name) else { continue }

                let mod = getOrCreateModule(name: name, handle: modHandle)
                let persistedCipherKey = config.values["cipherkey"]?.first
                let isUnlocked = sessionUnlockedModuleNames.contains(name)
                    || (persistedCipherKey.map { !$0.isEmpty } ?? mod.info.isUnlocked)
                modules.append(Self.moduleInfo(mod.info, overridingUnlocked: isUnlocked))
            }
            return modules
        }

        let merged = Self.mergedInstalledModules(
            swordModules: swordModules,
            customModules: Self.androidCustomInstalledModules(modulePath: modulePath) +
                Self.myBiblePackageInstalledModules(modulePath: modulePath)
        )
        // Exclude modules SWORD cannot fully use (e.g. a Bible with an unrecognized versification),
        // mirroring Android's `Books.installed()`, which never contains an unsupported book. Such a
        // module is then invisible everywhere — not readable, not in pickers, and shown as
        // not-installed in Downloads (so it appears re-downloadable, which overwrites a broken conf).
        // Uninstall/index operate by name and are unaffected. See ADR-0010.
        //
        // `isSupported` reads SWORD's versification manager per Bible module; run the whole filter in
        // one serialization hop (re-entrant `SwordRuntime.sync`) so a large library costs a single
        // queue round-trip rather than one per module.
        return SwordRuntime.sync { merged.filter(\.isSupported) }
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
            let resolved: SwordModule?
            if let cached = moduleCache[name] {
                resolved = cached
            } else if let modHandle = SWMgr_getModuleByName(handle, name) {
                resolved = getOrCreateModule(name: name, handle: modHandle)
            } else {
                resolved = nil
            }
            // Do not surface an unsupported module (e.g. a Bible with an unrecognized versification),
            // mirroring Android's `Books.installed().getBook()`, which returns null for such a book.
            // The cache entry is left intact so enumeration internals are unaffected. See ADR-0010.
            guard let resolved, resolved.info.isSupported else { return nil }
            return resolved
        }
    }

    /**
     Applies and verifies a cipher key for an installed encrypted module.

     - Parameters:
       - name: Installed module initials.
       - cipherKey: Non-empty decryption key supplied by the user.
     - Returns: `true` only when the candidate key produces readable module content and is saved to
       the module configuration for subsequent launches.
     - Side Effects: Creates a temporary SWORD manager, applies the candidate only there for
       validation, persists a verified `CipherKey`, then applies it to the live manager and marks
       only the named module unlocked in current inventory snapshots.
     - Failure Modes: Empty keys, missing/plain modules, unreadable decrypted content, and config
       persistence failures leave the live manager key unchanged, restore the original config bytes
       after a failed write, and return `false`.
     */
    public func unlockModule(named name: String, withCipherKey cipherKey: String) -> Bool {
        guard !cipherKey.isEmpty else { return false }
        return SwordRuntime.sync {
            guard let moduleHandle = SWMgr_getModuleByName(handle, name) else { return false }
            let module = getOrCreateModule(name: name, handle: moduleHandle)
            guard module.info.isEncrypted else { return false }

            // SWORD can add a cipher filter at runtime but cannot remove it. Probe through an isolated
            // manager so a failed first unlock leaves the live reader exactly as it was.
            guard let validationManager = SWMgr_new(modulePath) else { return false }
            defer { SWMgr_delete(validationManager) }
            guard let validationModule = SWMgr_getModuleByName(validationManager, name) else {
                return false
            }
            SWMgr_setCipherKey(validationManager, name, cipherKey)
            guard Self.moduleHasReadableCipherContent(validationModule, info: module.info),
                  Self.persistVerifiedCipherKey(
                    cipherKey,
                    moduleName: name,
                    modulePath: modulePath
                  ) else {
                return false
            }

            SWMgr_setCipherKey(handle, name, cipherKey)
            sessionUnlockedModuleNames.insert(name)
            return true
        }
    }

    /**
     Probes real module entries after applying a candidate cipher key.

     Android's JSword `Book.unlock` double-checks the key by reading the first global entry with
     backend read errors enabled. SWORD's raw ciphers are unauthenticated, so a wrong key can still
     produce bytes without a backend error. The probe therefore requires the first non-empty entry
     to decode under the module's configured SWORD character encoding without cipher-like controls,
     then requires the native source-to-OSIS result to parse for the module's category and contain
     renderable content before the key can be persisted. Because the C bridge can truncate wrong-key
     bytes at an embedded NUL, the bounded traversal requires at least 16 validated source scalars
     across readable entries rather than accepting a one-character prefix as proof.

     - Parameters:
       - moduleHandle: Installed module whose manager cipher filter was just updated.
       - info: Module metadata selecting Bible, commentary, dictionary, or general-book processing.
     - Returns: `true` when the first readable global entries are structurally valid and provide at
       least 16 source scalars of evidence.
     - Side Effects: Temporarily advances and then restores the module cursor.
     - Failure Modes: Backend errors, invalid configured encoding, malformed OSIS, control bytes,
       empty modules, and modules with no readable entry in the bounded traversal return `false`.
     */
    private static func moduleHasReadableCipherContent(
        _ moduleHandle: UnsafeMutableRawPointer,
        info: ModuleInfo
    ) -> Bool {
        let savedKey = String(cString: SWModule_getKeyText(moduleHandle))
        defer { SWModule_setKeyText(moduleHandle, savedKey) }

        SWModule_begin(moduleHandle)
        guard SWModule_popError(moduleHandle) == 0 else { return false }

        var visitedEntryCount = 0
        var validatedScalarCount = 0
        while SWModule_isEnd(moduleHandle) == 0, visitedEntryCount < 1_024 {
            visitedEntryCount += 1
            guard let rawPointer = SWModule_getRawEntry(moduleHandle),
                  SWModule_popError(moduleHandle) == 0,
                  let rawText = decodedCipherEntry(
                      rawPointer,
                      configuredEncoding: SWModule_getConfigEntry(moduleHandle, "Encoding")
                  ) else {
                return false
            }
            if !rawText.isEmpty {
                guard isPlausibleDecryptedModuleText(rawText),
                      let osisPointer = SWModule_getOSISFragment(moduleHandle),
                      SWModule_popError(moduleHandle) == 0,
                      let osisFragment = String(validatingUTF8: osisPointer) else {
                    return false
                }
                guard cipherEntryIsStructurallyReadable(
                    osisFragment: osisFragment,
                    category: info.category,
                    moduleInitials: info.name
                ) else {
                    return false
                }
                validatedScalarCount += min(rawText.unicodeScalars.count, 64)
                if validatedScalarCount >= 16 {
                    return true
                }
            }
            if SWModule_next(moduleHandle) != 0 {
                break
            }
        }
        return false
    }

    /**
     Decodes one native raw-entry C string using JSword's SWORD encoding defaults.

     - Parameters:
       - pointer: NUL-terminated bytes returned by the SWORD backend for the current entry.
       - configuredEncoding: Optional module `Encoding` config value; missing values mean Latin-1
         under the SWORD/JSword config contract.
     - Returns: Strictly decoded text for UTF-8 or Latin-1 modules, otherwise `nil`.
     - Side effects: Reads the native C strings without moving the module cursor.
     - Failure modes: Invalid UTF-8 or unsupported declared encodings return `nil`; Latin-1 byte
       controls remain in the string for `isPlausibleDecryptedModuleText` to reject.
     */
    private static func decodedCipherEntry(
        _ pointer: UnsafePointer<CChar>,
        configuredEncoding: UnsafePointer<CChar>?
    ) -> String? {
        let encoding = configuredEncoding
            .flatMap(String.init(validatingUTF8:))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "latin-1"
        switch encoding {
        case "utf-8", "utf8":
            return String(validatingUTF8: pointer)
        case "latin-1", "latin1", "iso-8859-1", "iso8859-1", "":
            return String(cString: pointer, encoding: .isoLatin1)
        default:
            return nil
        }
    }

    /**
     Rejects decoded raw text that cannot represent a readable SWORD document entry.

     JSword validates a candidate key by decoding and reading the first global entry with backend
     errors enabled. libsword's cipher has no authentication result, so this companion check rejects
     replacement, C0/C1 control, and private-use scalars that commonly result from a wrong key.

     - Parameter text: Entry decoded according to the module's configured SWORD character encoding.
     - Returns: `true` for non-empty text containing only document-safe Unicode scalars.
     - Side effects: none.
     - Failure modes: Empty text or forbidden scalars return `false`; no errors are thrown.
     */
    static func isPlausibleDecryptedModuleText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0xFFFD
                || (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D)
                || (0x7F...0x9F).contains(value)
                || (0xE000...0xF8FF).contains(value)
                || (0xF0000...0xFFFFD).contains(value)
                || (0x100000...0x10FFFD).contains(value) {
                return false
            }
        }
        return true
    }

    /**
     Validates decrypted entry shape independently of SWORD's unauthenticated backend status.

     - Parameters:
       - osisFragment: UTF-8 fragment emitted by the native source-to-OSIS filter.
       - category: Module category controlling commentary and generic-book structural processing.
       - moduleInitials: Exact initials used by source-specific OSIS repair.
     - Returns: `true` only for non-empty, control-safe content that parses into renderable OSIS.
     - Side Effects: Parses an in-memory XML fragment only.
     - Failure Modes: Empty text, forbidden control scalars, malformed XML, or non-renderable
       fragments return `false`.
     */
    static func cipherEntryIsStructurallyReadable(
        osisFragment: String,
        category: ModuleCategory,
        moduleInitials: String
    ) -> Bool {
        let meaningfulOSIS = osisFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !meaningfulOSIS.isEmpty,
              isPlausibleDecryptedModuleText(osisFragment) else {
            return false
        }
        do {
            return try SwordOSISFragmentProcessor.process(
                sourceXML: osisFragment,
                category: category,
                moduleInitials: moduleInitials
            ).hasRenderableContent
        } catch {
            return false
        }
    }

    /**
     Persists a cipher key that has already passed module-content verification.

     - Parameters:
       - cipherKey: Verified module key.
       - moduleName: Installed module section/initials.
       - modulePath: SWORD root containing `mods.d`.
     - Returns: `true` only when the exact key can be read back from the saved module config.
     - Side Effects: Atomically updates the module's `CipherKey` config entry on disk after retaining
       the original bytes for rollback.
     - Failure Modes: Missing configs, write failures, or read-back mismatches restore the original
       config bytes and return `false`.
     */
    static func persistVerifiedCipherKey(
        _ cipherKey: String,
        moduleName: String,
        modulePath: String
    ) -> Bool {
        guard !cipherKey.isEmpty,
              let configURL = moduleConfigURL(named: moduleName, modulePath: modulePath),
              let originalData = try? Data(contentsOf: configURL),
              let parsedConfig = parseModuleConfig(at: configURL),
              let config = SwordConfig(filePath: configURL.path) else {
            return false
        }

        var didVerifyPersistence = false
        defer {
            if !didVerifyPersistence {
                try? originalData.write(to: configURL, options: .atomic)
            }
        }
        config.setValue(section: parsedConfig.name, key: "CipherKey", value: cipherKey)
        config.save()
        didVerifyPersistence = parseModuleConfig(at: configURL)?.values["cipherkey"]?.first == cipherKey
        return didVerifyPersistence
    }

    /** Locates an installed module config without assuming case-sensitive filename spelling. */
    private static func moduleConfigURL(named name: String, modulePath: String) -> URL? {
        let directory = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d", isDirectory: true)
        let expectedName = "\(name).conf"
        return try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first { url in
            url.lastPathComponent.caseInsensitiveCompare(expectedName) == .orderedSame
        }
    }

    /** Reads one module config using the parser shared with installed-module inventory. */
    private static func parseModuleConfig(at url: URL) -> SwordModuleConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        return content.flatMap(SwordModuleConfig.parse)
    }

    /** Copies module metadata while overriding only the current unlock state. */
    private static func moduleInfo(
        _ info: ModuleInfo,
        overridingUnlocked isUnlocked: Bool
    ) -> ModuleInfo {
        ModuleInfo(
            name: info.name,
            description: info.description,
            category: info.category,
            language: info.language,
            moduleDriver: info.moduleDriver,
            version: info.version,
            isEncrypted: info.isEncrypted,
            isUnlocked: isUnlocked,
            features: info.features,
            isRightToLeft: info.isRightToLeft,
            aboutMetadata: info.aboutMetadata
        )
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
            if config.values["andbibledbfile"]?.first != nil {
                return androidDatabaseFileExists(config, modulePath: modulePath)
            }
            guard !config.dataPath.isEmpty else { return false }
            return readablePath(
                appending: "module.SQLite3",
                to: config.dataPath,
                modulePath: modulePath,
                isDirectory: false
            )
        case "myswordbible", "myswordcommentary", "mysworddictionary":
            if config.values["andbibledbfile"]?.first != nil {
                return androidDatabaseFileExists(config, modulePath: modulePath)
            }
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
