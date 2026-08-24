// SwordManager.swift — SWMgr wrapper for SwordKit

import Foundation
import CLibSword

/**
 Current reader-access classification for one installed SWORD module.

 Installed inventory deliberately includes encrypted locked modules so Downloads and document
 choosers can display and unlock them. Reader activation must use this narrower classification
 instead of treating every module returned by `module(named:)` as readable.

 The value contains no module handle and has no side effects. Single-name activation preflight may
 inspect it directly; arbitrary content readers should use `SwordManager.readableModule(named:)` so
 classification and canonical handle resolution share one fresh inventory snapshot. This keeps
 locked modules out of content-reading paths while preserving management visibility.
 */
public enum SwordModuleAccessState: Equatable, Sendable {
    /// No supported native SWORD module currently resolves for the requested identity.
    case unavailable

    /// The module is installed and encrypted, but has no verified current-session or persisted key.
    case locked

    /// The module is installed and can be activated for content reads.
    case readable
}

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
 if let kjv = manager.readableModule(named: "KJV") {
     kjv.setKey("Gen 1:1")
     let text = kjv.renderText()
 }
 ```
 */
public final class SwordManager: @unchecked Sendable {
    /** Result of JSword `SwordBookMetaData.adjustLocation` payload admission. */
    enum AdjustedModuleLocation {
        /// The book remains installed, but a slashless `DataPath` assigned no feature location.
        case noLocation

        /// The book remains installed with this validated directory location.
        case location(URL)

        /// Optional URL exposed to installed feature projections.
        var url: URL? {
            guard case .location(let url) = self else { return nil }
            return url
        }
    }

    private let handle: UnsafeMutableRawPointer

    /// Internal access to the C handle for InstallManager operations.
    var rawHandle: UnsafeMutableRawPointer { handle }
    /// Exact native wrapper and verified session-unlock ownership state.
    private let moduleAuthorizationCache = SwordModuleHandleAuthorizationCache()

    /// One manager-lifetime config/registry capture, invalidated by unlock and explicit refresh.
    private var nativeRegistrySnapshotCache: NativeModuleRegistrySnapshot?

    /// Complete installed generation shared by public book and feature projections.
    private var installedRegistryProjectionCache: InstalledRegistryProjection?

    /// Android-admitted add-ons in installed TreeSet order, invalidated with installed inventory.
    private var admittedAddonModulesCache: [SwordAdmittedAddonModule]?

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
            nativeRegistrySnapshotCache = nil
            installedRegistryProjectionCache = nil
            admittedAddonModulesCache = nil
            moduleAuthorizationCache.clear()
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
     sidecar package directory. Configless CSV files in `prompts` become Android `CsvPromptBook`
     registrations. Android exposes all of these families through `Books.installed().books`; iOS
     mirrors that inventory here through one cached installed-registry projection.

     - Returns: SWORD modules and readable Android custom modules projected through JSword's
       category/abbreviation/initials/name TreeSet comparator. Canonically equivalent Java-distinct
       UTF-16 spellings and comparator-distinct duplicate-initial metadata remain separate books.
     - Side effects: Reads `mods.d` configs, sidecar metadata, checks custom payload files, and
       enumerates readable direct-child CSV files in the `prompts` directory.
     - Failure modes: Malformed configs, modules libsword cannot resolve, and custom rows without
       readable payloads are skipped.
     - Note: Locked encrypted modules remain visible with `isUnlocked == false`; a key verified in
       this manager session overrides only that module's stale native metadata snapshot.
     */
    public func installedModules() -> [ModuleInfo] {
        installedBookRegistrations().map(\.moduleInfo)
    }

    /**
     Lists installed books with the exact JSword abbreviation retained through registry admission.

     - Returns: Comparator-distinct native, Android custom, and generated standalone prompt books
       in installed TreeSet order, carrying inclusive access state and display abbreviation.
     - Side effects: Builds the same cached native snapshot, reads custom payload metadata, and
       enumerates standalone prompt CSV files exactly as `installedModules()`; no content is read.
     - Failure modes: Malformed, unsupported, payload-missing, and shadowed books are omitted by the
       shared installed registry rather than approximated by consumers.
     */
    public func installedBookRegistrations() -> [SwordInstalledBookRegistration] {
        installedRegistryProjection().registrations
    }

    /**
     Builds one installed generation for every public inventory and add-on feature consumer.

     - Returns: Supported TreeSet registrations plus config/location-bearing add-on owners captured
       from the same native/custom/package/standalone add sequence.
     - Side effects: On first access, reads installed configs, package metadata, payload paths, and
       the standalone prompts directory; later access reuses the immutable manager snapshot.
     - Failure modes: Malformed, unsupported, payload-missing, shadowed, and unreadable books are
       omitted fail closed; an unreadable standalone directory contributes no synthetic books.
     */
    private func installedRegistryProjection() -> InstalledRegistryProjection {
        SwordRuntime.sync {
            if let installedRegistryProjectionCache { return installedRegistryProjectionCache }

            let nativeSnapshot = nativeModuleRegistrySnapshot()
            let swordModules = nativeSnapshot.installedRegistrations
            let restoredCustomModules = Self.androidCustomInstalledRegistrations(modulePath: modulePath)
            let packageModules = SwordInstalledMyBibleInventory.admittedRegistrations(
                modulePath: modulePath,
                after: swordModules + restoredCustomModules
            )
            var installedRegistrations = swordModules + restoredCustomModules + packageModules
            var addonCandidates: [InstalledAddonCandidate] = nativeSnapshot.installedBooks.compactMap { book in
                guard book.registration.info.category == .addon else { return nil }
                return InstalledAddonCandidate(
                    registration: book.registration,
                    config: book.config,
                    locationURL: book.locationURL,
                    removalTarget: Self.configRemovalTarget(
                        config: book.config,
                        registration: book.registration,
                        locationURL: book.locationURL,
                        modulePath: modulePath
                    )
                )
            }
            addonCandidates.append(contentsOf: Self.standalonePromptCandidates(
                modulePath: modulePath,
                installedRegistrations: &installedRegistrations
            ))
            let registrations = SwordInstalledBookSetProjection
                .registrationsInInstalledOrder(installedRegistrations)
                .filter(\.info.isSupported)
                .map {
                    SwordInstalledBookRegistration(
                        moduleInfo: $0.info,
                        abbreviation: $0.abbreviation
                    )
                }
            let projection = InstalledRegistryProjection(
                registrations: registrations,
                addonCandidates: addonCandidates
            )
            installedRegistryProjectionCache = projection
            return projection
        }
    }

    /// List installed modules filtered by category.
    public func installedModules(category: ModuleCategory) -> [ModuleInfo] {
        installedModules().filter { $0.category == category }
    }

    /**
     Classifies whether an installed native SWORD module can be activated for content reads.

     This query derives from the manager's immutable native-registration snapshot. A successful live
     unlock invalidates that snapshot before subsequent access, while external filesystem mutation
     becomes visible only after `refresh()`. Inventory and `module(named:)` remain inclusive for
     Downloads, About, uninstall, and unlock workflows.

     - Parameter name: Installed initials/full name resolved through JSword's exact maps followed by
       its case-insensitive installed-TreeSet tier.
     - Returns: `.readable` for a supported native module with current access, `.locked` for an
       encrypted module awaiting a verified key, or `.unavailable` for missing, unsupported, and
       Android custom-driver projections that do not have a native SWORD handle.
     - Side effects: The first lookup reads installed configuration and may populate the manager's
       registry/module caches; later lookups reuse them and do not mutate cipher or reader state.
     - Failure modes: Malformed configuration, unsupported modules, native lookup failures, and
       ambiguous duplicate exact initials are classified as `.unavailable` rather than exposing a
       partially readable or unowned handle.
     - Important: Libsword work is serialized by the existing `SwordRuntime` boundaries used by
       `installedModules()` and `module(named:)`.
     */
    public func moduleAccessState(named name: String) -> SwordModuleAccessState {
        guard !name.isEmpty,
              let registration = nativeModuleRegistration(named: name) else {
            return .unavailable
        }
        let info = registration.info
        if info.isEncrypted && !info.isUnlocked {
            return .locked
        }
        return .readable
    }

    /**
     Resolves one native module only when the manager's current snapshot authorizes content access.

     Inclusive `module(named:)` remains the inventory, unlock, uninstall, and metadata boundary.
     Content callers use this method so a cached native handle cannot bypass a later relock.

     - Parameter name: Installed initials/full name resolved through JSword exact-map precedence and
       the pinned case-insensitive TreeSet scan.
     - Returns: The canonical native handle when the current row is readable, otherwise nil.
     - Side effects: On first access, enumerates installed configuration and creates native wrappers;
       later calls reuse the immutable registry until unlock or explicit refresh invalidates it.
     - Failure modes: Empty, missing, unsupported, custom-driver, locked, and ambiguous duplicate
       exact-initial identities fail closed.
     */
    public func readableModule(named name: String) -> SwordModule? {
        guard !name.isEmpty,
              let registration = nativeModuleRegistration(named: name),
              !registration.info.isEncrypted || registration.info.isUnlocked else {
            return nil
        }
        return registration.module
    }

    /**
     Resolves an inclusive native module through Android's installed-book identity tiers.

     Exact initials win before exact full name. When neither exact map matches, the first
     case-insensitive initials/full-name match in pinned JSword TreeSet order wins. This prevents
     config enumeration order and Swift Unicode normalization from redirecting one identity to a
     different native backend.

     - Parameter name: Exact initials/full name or Java case-insensitive alias.
     - Returns: The supported native module selected by JSword rules, or nil when not installed.
     - Side effects: Reads installed configs and creates or reuses native handles in the exact-keyed
       manager cache; no document cursor or cipher state is mutated.
     - Failure modes: Empty, custom-driver, unsupported, unmatched, and ambiguous duplicate
       exact-initial identities return nil.
     */
    public func module(named name: String) -> SwordModule? {
        guard !name.isEmpty else { return nil }
        return nativeModuleRegistration(named: name)?.module
    }

    /**
     Applies and verifies a cipher key for an installed encrypted module.

     - Parameters:
       - name: Installed initials/full name or Java case-insensitive alias resolved through the same
         native BookSet contract as reader access.
       - cipherKey: Non-empty decryption key supplied by the user.
     - Returns: `true` only when the candidate key produces readable module content and is saved to
       the module configuration for subsequent launches.
     - Side Effects: Creates a temporary SWORD manager, applies the candidate only there for
       validation, persists a verified `CipherKey`, then applies it to the live manager and marks
       only the named module unlocked in current inventory snapshots.
     - Failure Modes: Empty keys, missing/plain modules, ambiguous duplicate exact initials,
       unreadable decrypted content, and config persistence failures leave the live manager key
       unchanged, restore the original config bytes after a failed write, and return `false`.
     */
    public func unlockModule(named name: String, withCipherKey cipherKey: String) -> Bool {
        guard !cipherKey.isEmpty else { return false }
        return SwordRuntime.sync {
            guard let registration = nativeModuleRegistration(named: name) else { return false }
            let canonicalName = registration.info.name
            let module = registration.module
            guard module.info.isEncrypted else { return false }

            // SWORD can add a cipher filter at runtime but cannot remove it. Probe through an isolated
            // manager so a failed first unlock leaves the live reader exactly as it was.
            guard let validationManager = SWMgr_new(modulePath) else { return false }
            defer { SWMgr_delete(validationManager) }
            guard let validationModule = SWMgr_getModuleByName(validationManager, canonicalName) else {
                return false
            }
            let validationName = String(cString: SWModule_getName(validationModule))
            guard SwordJavaExactStringIdentity(validationName)
                    == SwordJavaExactStringIdentity(canonicalName) else {
                return false
            }
            SWMgr_setCipherKey(validationManager, canonicalName, cipherKey)
            guard Self.moduleHasReadableCipherContent(validationModule, info: module.info),
                  Self.persistVerifiedCipherKey(
                    cipherKey,
                    moduleName: canonicalName,
                    modulePath: modulePath,
                    owningConfigURL: registration.configURL
                  ) else {
                return false
            }

            SWMgr_setCipherKey(handle, canonicalName, cipherKey)
            moduleAuthorizationCache.markSessionUnlocked(canonicalName)
            nativeRegistrySnapshotCache = nil
            installedRegistryProjectionCache = nil
            admittedAddonModulesCache = nil
            return true
        }
    }

    /**
     Probes real module entries after applying a candidate cipher key.

     Android's JSword `Book.unlock` double-checks the key by reading the first global entry with
     backend read errors enabled. SWORD's raw ciphers are unauthenticated, so a wrong key can still
     produce bytes without a backend error. The probe therefore requires the first non-empty entry
     to decode under the module's configured SWORD character encoding without cipher-like controls,
     then requires the shared Android-compatible source-to-OSIS result to parse for the module's
     category and contain
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
                      SWModule_popError(moduleHandle) == 0 else {
                    return false
                }
                let osisFragment = SwordSourceFormatOSISConverter.fragment(handle: moduleHandle)
                guard SWModule_popError(moduleHandle) == 0 else { return false }
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
       - osisFragment: UTF-8 fragment emitted by the shared Android-compatible source converter.
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
       - owningConfigURL: Exact config owned by a previously resolved native registration. When nil,
         direct callers require one unambiguous section owner.
       - publishVerifiedConfig: Atomic publisher for already-verified staged bytes. The default
         writes atomically; tests inject a failing publisher to exercise post-invalidation rollback.
     - Returns: `true` only when the exact key can be read back and the stale cache is absent.
     - Side Effects: Serializes and verifies the candidate in a sibling staging file, snapshots and
       removes `mods.d/modules-conf.cache`, then atomically publishes the verified bytes to the real
       config. A successful write leaves the cache absent for native reconstruction.
     - Failure Modes: Missing configs, staging failures, unreadable or unremovable cache state,
       publish failures, and read-back mismatches return `false`. Post-invalidation failures restore
       the config first; the prior cache is restored only after exact config restoration succeeds.
     - Important: The native streaming writer touches only staging. Once cache invalidation begins,
       every interruption-safe state has either old or new complete config bytes and no stale cache.
     */
    static func persistVerifiedCipherKey(
        _ cipherKey: String,
        moduleName: String,
        modulePath: String,
        owningConfigURL: URL? = nil,
        publishVerifiedConfig: (Data, URL) throws -> Void = { data, destinationURL in
            try data.write(to: destinationURL, options: .atomic)
        }
    ) -> Bool {
        guard !cipherKey.isEmpty,
              let configURL = owningConfigURL
                ?? moduleConfigURL(named: moduleName, modulePath: modulePath),
              isOwnedModuleConfigURL(configURL, modulePath: modulePath),
              let originalData = try? Data(contentsOf: configURL),
              let parsedConfig = parseModuleConfig(at: configURL) else {
            return false
        }
        let ownsRequestedIdentity = owningConfigURL != nil
            ? SwordJavaStringIdentity.equals(parsedConfig.name, moduleName)
            : SwordJavaStringIdentity.equalsIgnoreCase(parsedConfig.name, moduleName)
        guard ownsRequestedIdentity else {
            return false
        }

        let fileManager = FileManager.default
        let stagingURL = configURL.deletingLastPathComponent().appendingPathComponent(
            ".\(configURL.lastPathComponent).cipher-\(UUID().uuidString).staging"
        )
        defer {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
        }
        do {
            try originalData.write(to: stagingURL, options: .atomic)
        } catch {
            return false
        }
        guard let stagedConfig = SwordConfig(filePath: stagingURL.path) else {
            return false
        }
        stagedConfig.setValue(section: parsedConfig.name, key: "CipherKey", value: cipherKey)
        stagedConfig.save()
        guard parseModuleConfig(at: stagingURL)?.values["CipherKey"]?.first == cipherKey,
              let verifiedConfigData = try? Data(contentsOf: stagingURL) else {
            return false
        }

        let cacheURL = configURL.deletingLastPathComponent()
            .appendingPathComponent("modules-conf.cache")
        let cacheExisted = fileManager.fileExists(atPath: cacheURL.path)
        let originalCacheData: Data?
        if cacheExisted {
            guard let cacheData = try? Data(contentsOf: cacheURL) else { return false }
            originalCacheData = cacheData
        } else {
            originalCacheData = nil
        }

        var didBeginLiveMutation = false
        var didVerifyPersistence = false
        defer {
            if didBeginLiveMutation, !didVerifyPersistence {
                let didRestoreConfig: Bool
                do {
                    try originalData.write(to: configURL, options: .atomic)
                    didRestoreConfig = (try? Data(contentsOf: configURL)) == originalData
                } catch {
                    didRestoreConfig = false
                }
                if didRestoreConfig, let originalCacheData {
                    try? originalCacheData.write(to: cacheURL, options: .atomic)
                } else if fileManager.fileExists(atPath: cacheURL.path) {
                    try? fileManager.removeItem(at: cacheURL)
                }
            }
        }
        if cacheExisted {
            do {
                try fileManager.removeItem(at: cacheURL)
            } catch {
                return false
            }
        }
        didBeginLiveMutation = true
        do {
            try publishVerifiedConfig(verifiedConfigData, configURL)
        } catch {
            return false
        }
        didVerifyPersistence = parseModuleConfig(at: configURL)?
            .values["CipherKey"]?.first == cipherKey
            && !fileManager.fileExists(atPath: cacheURL.path)
        return didVerifyPersistence
    }

    /**
     Locates the config whose section initials match one Java module identity.

     Filenames are not authoritative and may differ in case from their section. Parsing each
     candidate prevents a `FOO` unlock from rewriting `foo.conf`, while exact UTF-16 comparison keeps
     canonically equivalent Java-distinct section names separate. A unique case-insensitive alias is
     retained for compatibility with direct persistence callers; an ambiguous alias fails closed.

     - Parameters:
       - name: Canonical native module initials selected by the manager's BookSet resolver.
       - modulePath: SWORD root containing `mods.d`.
     - Returns: One unambiguous exact config URL, otherwise one unambiguous Java case-insensitive
       match. Duplicate exact sections fail closed because no native registration owner was supplied.
     - Side effects: Enumerates and reads local config files without mutating them.
     - Failure modes: Missing directories and unreadable/malformed configs are ignored.
     */
    private static func moduleConfigURL(named name: String, modulePath: String) -> URL? {
        let candidates = SwordModuleConfig.readAll(modulePath: modulePath)
        let identity = SwordJavaExactStringIdentity(name)
        let exact = candidates.filter {
            SwordJavaExactStringIdentity($0.name) == identity
        }
        if exact.count == 1 {
            return exact[0].sourceURL
        }
        guard exact.isEmpty else { return nil }
        let aliases = candidates.filter {
            SwordJavaStringIdentity.equalsIgnoreCase($0.name, name)
        }
        return aliases.count == 1 ? aliases[0].sourceURL : nil
    }

    /**
     Validates that a resolved owner is one direct JSword config under this manager's `mods.d`.

     - Parameters:
       - url: Candidate exact config owner.
       - modulePath: SWORD root whose config directory defines the authorization boundary.
     - Returns: True only for a direct, lowercase-`.conf`, non-globals file under `mods.d`.
     - Side effects: Standardizes lexical file URLs; no filesystem mutation occurs.
     - Failure modes: Escaped, reserved, and differently suffixed paths return false.
     */
    private static func isOwnedModuleConfigURL(_ url: URL, modulePath: String) -> Bool {
        let directory = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d", isDirectory: true)
            .standardizedFileURL
        let candidate = url.standardizedFileURL
        return candidate.deletingLastPathComponent() == directory
            && candidate.lastPathComponent.hasSuffix(".conf")
            && !candidate.lastPathComponent.hasPrefix("globals.")
    }

    /** Reads one module config using the parser and encoding policy shared with inventory. */
    private static func parseModuleConfig(at url: URL) -> SwordModuleConfig? {
        SwordModuleConfig.read(url: url)
    }

    /**
     Builds one config-owned metadata row with its exact persisted encryption state.

     - Parameters:
       - config: Parsed config owner whose JSword metadata identifies this registration.
       - isUnlocked: Fresh persisted/session unlock projection for this exact initials identity.
     - Returns: Installed metadata with config-owned identity/order fields and native lock state.
     - Side effects: None.
     - Failure modes: Missing optional config values retain the parser's JSword defaults.
     */
    private static func moduleInfo(
        config: SwordModuleConfig,
        overridingUnlocked isUnlocked: Bool
    ) -> ModuleInfo {
        ModuleInfo(
            name: config.name,
            description: config.description,
            category: config.category,
            language: config.language,
            moduleDriver: config.modDrv,
            version: config.version,
            isEncrypted: config.values["CipherKey"] != nil,
            isUnlocked: isUnlocked,
            features: config.features,
            isRightToLeft: config.direction.caseInsensitiveCompare("RtoL") == .orderedSame,
            aboutMetadata: config.aboutMetadata
        )
    }

    /**
     Builds and caches supported native inventory plus ownership-proven lookup indexes.

     Pinned `SwordBookDriver` first filters supported configs through a `HashSet`, whose equality
     requires the same concrete `AbstractBook` class plus exact category/full-name/initials, then
     returns an arbitrary-order array to `Books.addBook`. iOS chooses the exact config-path minimum
     as a deterministic metadata representative for each equality group, but it never assigns
     content ownership to raw duplicate initials or exact full-name collisions because Android
     exposes no stable winner for those map keys.

     - Returns: One cached installed inventory, exact-initial/full-name indexes, and TreeSet alias
       order. Subsequent lookups reuse the same immutable snapshot until unlock or `refresh()`.
     - Side effects: On first access, reads installed configs, asks libsword for exact handles, and
       populates the exact-keyed module cache only for raw-unique identities. No content is read.
     - Failure modes: Custom, payload-invalid, missing, cross-resolved, and unsupported configs are
       omitted before driver HashSet ownership. Duplicate exact-initial detection still covers the
       raw config set, preventing a filtered duplicate from making content ownership appear safe.
       Exact full-name collisions remain individually readable by initials but fail closed through
       the name map.
     - Important: All native work executes through the re-entrant `SwordRuntime` serialization gate.
     - Complexity: O(N log N) once per cache lifetime; cached exact lookup is O(1).
     */
    private func nativeModuleRegistrySnapshot() -> NativeModuleRegistrySnapshot {
        SwordRuntime.sync {
            if let nativeRegistrySnapshotCache { return nativeRegistrySnapshotCache }
            let snapshot = SwordNativeModuleRegistry.capture(
                modulePath: modulePath,
                managerHandle: handle,
                authorizationCache: moduleAuthorizationCache,
                adjustedLocation: { [modulePath] config in
                    Self.adjustedModuleLocation(for: config, modulePath: modulePath)
                },
                moduleInfo: { config, isUnlocked in
                    Self.moduleInfo(config: config, overridingUnlocked: isUnlocked)
                },
                bookClassIdentity: Self.nativeSwordBookClassIdentity
            )
            nativeRegistrySnapshotCache = snapshot
            return snapshot
        }
    }
    /**
     Resolves one native registration with JSword `BookSet.getBook` precedence.

     - Parameter name: Exact initials/full name or Java case-insensitive lookup token.
     - Returns: Unique exact-initials match, unique exact-name match, then the first initials/name
       alias in category/abbreviation/initials/name TreeSet order.
     - Side effects: Builds the manager's registry cache on first access; later lookups read it only.
     - Failure modes: Empty, unmatched, duplicate exact-initial, and duplicate exact-full-name map
       identities return nil at their ambiguous tier. Locked books remain present because ownership
       resolution is separate from content authorization.
     - Important: Duplicate exact map keys are an intentional safety divergence for an
       Android-runtime-undefined collision. `File.list` to `HashSet.toArray` to `Books.addBook`
       provides no stable cross-platform winner, so iOS withholds only the ambiguous lookup tier
       instead of risking a backend cross-read or mutating a non-owner config.
     - Complexity: O(1) for exact tiers and O(N) only for the case-insensitive TreeSet scan.
     */
    private func nativeModuleRegistration(named name: String) -> NativeModuleRegistration? {
        guard !name.isEmpty else { return nil }
        let snapshot = nativeModuleRegistrySnapshot()
        let exactName = SwordJavaExactStringIdentity(name)
        if let exactInitials = snapshot.exactInitials[exactName] { return exactInitials }
        if snapshot.ambiguousExactFullNames.contains(exactName) { return nil }
        if let exactFullName = snapshot.exactFullNames[exactName] { return exactFullName }
        return snapshot.treeSetRegistrations.first {
            SwordJavaStringIdentity.equalsIgnoreCase($0.info.name, name)
                || SwordJavaStringIdentity.equalsIgnoreCase($0.fullName, name)
        }
    }

    /**
     Reads Android custom-driver configs that should be visible in installed-book inventory.

     - Parameter modulePath: SWORD module root containing `mods.d` and module payloads.
     - Returns: Metadata plus parsed JSword abbreviations for readable custom-driver modules.
     - Side effects: Reads local config files and checks payload existence.
     - Failure modes: Unsupported or incomplete custom-driver rows are skipped.
     */
    private static func androidCustomInstalledRegistrations(
        modulePath: String
    ) -> [InstalledModuleRegistration] {
        SwordModuleConfig.readAll(modulePath: modulePath)
            .filter { $0.isAndroidCustomDriver && customModulePayloadExists($0, modulePath: modulePath) }
            .map { config in
                let configuredAbbreviation = config.values["Abbreviation"]?.first
                    .map(SwordJavaStringIdentity.trim)
                return InstalledModuleRegistration(
                    info: config.moduleInfo,
                    abbreviation: configuredAbbreviation.flatMap { $0.isEmpty ? nil : $0 }
                        ?? config.name,
                    fullName: config.description
                )
            }
    }

    /**
     Reads iOS sidecar-installed MyBible package modules into Android-compatible inventory rows.

     - Parameter modulePath: SWORD module root containing the `mybible` sidecar package directory.
     - Returns: Database-derived package modules admitted in deterministic discovery order and then
       projected through pinned JSword installed-TreeSet order.
     - Side effects: Reads `module.json` sidecars and opens each immediate SQLite/MyBible payload
       read-only before loading the pinned Android comparison table.
     - Failure modes: Missing directories, malformed sidecars/databases, unsupported schemas, and a
       later package whose initials resolve to an already admitted package are skipped.
     */
    static func myBiblePackageInstalledModules(modulePath: String) -> [ModuleInfo] {
        SwordInstalledMyBibleInventory.installedModules(modulePath: modulePath)
    }

    /**
     Reads Android add-on modules that provide reading-plan files.

     Android discovers add-on plans from repeated `AndBibleProvidesReadingPlan` config values and
     resolves each file relative to the module's adjusted `DataPath` location. Providers are
     admitted only from `And Bible` books whose minimum version is compatible, then traversed in
     the installed TreeSet order that defines Android's duplicate-plan ownership.

     - Parameter modulePath: SWORD module root containing `mods.d` and module payloads.
     - Returns: Readable admitted providers in first-plan TreeSet order, with a later TreeSet book
       replacing an earlier provider that declares the same plan code.
     - Side effects: Reads local config files and checks provider file metadata.
     - Failure modes: Missing configs, unreadable files, and escaped paths are skipped.
     */
    public static func readingPlanProviders(
        modulePath: String = SwordManager.defaultModulePath()
    ) -> [SwordReadingPlanProvider] {
        readingPlanProviders(
            modulePath: modulePath,
            applicationVersionNumber: AndBibleAndroidCompatibility.currentVersionCode
        )
    }

    /**
     Reads Android add-on reading-plan providers at an explicit compatibility boundary for tests.

     - Parameters:
       - modulePath: Isolated SWORD root containing provider configs and payloads.
       - applicationVersionNumber: Exact Android version code used for admission.
     - Returns: Providers resolved with the same installed BookSet and duplicate-plan rules as the
       production overload.
     - Side effects: Reads local config files and checks provider file metadata.
     - Failure modes: Missing configs, unreadable files, and escaped paths are skipped.
     */
    static func readingPlanProviders(
        modulePath: String,
        applicationVersionNumber: Int
    ) -> [SwordReadingPlanProvider] {
        var providersByCode: [String: SwordReadingPlanProvider] = [:]
        var orderedCodes: [String] = []

        guard let manager = SwordManager(modulePath: modulePath) else { return [] }
        let candidates = manager.admittedAddonCandidates(
            applicationVersionNumber: applicationVersionNumber
        )
        for candidate in candidates {
            let config = candidate.config
            let planFileNames = config.values["AndBibleProvidesReadingPlan"] ?? []
            for fileName in planFileNames {
                guard let locationURL = candidate.locationURL,
                      let fileURL = readingPlanProviderFileURL(
                    fileName: fileName,
                    locationURL: locationURL,
                    modulePath: modulePath
                ) else {
                    continue
                }

                let planCode = readingPlanCode(from: fileName)
                guard !planCode.isEmpty else { continue }

                let provider = SwordReadingPlanProvider(
                    planCode: planCode,
                    name: displayName(for: config),
                    description: config.values["ShortPromo"]?.first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    fileURL: fileURL,
                    versification: nonEmpty(config.values["Versification"]?.first),
                    isDateBased: config.values["AndBibleReadingPlanDateBased"]?.first?
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
     Returns installed add-ons admitted by Android's shared feature filter and registry ordering.

     This is the common source for prompt packs and the Add-ons document picker. It applies pinned
     current-stable Android compatibility, supported-book admission, native driver HashSet identity,
     and JSword TreeSet replacement/order once, preventing feature surfaces from scanning or sorting
     raw SWORD configs independently.

     - Returns: Admitted add-on metadata and feature-file fields in installed TreeSet order.
     - Side effects: On first access, reads installed config files, enumerates standalone prompt CSV
       files, and caches the immutable result for this manager. `refresh()` invalidates the cache.
     - Failure modes: Malformed or unsupported configs and malformed/too-new minimum versions fail
       closed and are omitted. An unreadable config directory omits config-backed rows, while
       independently readable standalone prompt books may remain installed.
     */
    public func admittedAddonModules() -> [SwordAdmittedAddonModule] {
        SwordRuntime.sync {
            if let admittedAddonModulesCache { return admittedAddonModulesCache }
            let modules = admittedAddonModules(
                applicationVersionNumber: AndBibleAndroidCompatibility.currentVersionCode
            )
            admittedAddonModulesCache = modules
            return modules
        }
    }

    /**
     Returns Android's provided-font map values in stable insertion order.

     Android iterates admitted books in installed TreeSet order and writes each readable provider to
     a linked map keyed by exact Java font name. A later exact-name provider replaces the value
     without moving its original position; canonically equivalent Java-distinct names remain
     separate.

     - Returns: Winning readable font providers in Android map-value order.
     - Side effects: Builds or reuses the shared admitted add-on projection; no font bytes are read.
     - Failure modes: Malformed, missing, unreadable, escaped, or ambiguous providers are omitted
       fail closed by the shared projection.
     */
    public func admittedFonts() -> [SwordAdmittedFont] {
        var orderedNames: [SwordJavaExactStringIdentity] = []
        var providersByName: [SwordJavaExactStringIdentity: SwordAdmittedFont] = [:]
        for module in admittedAddonModules() {
            for provider in module.providedFonts {
                let key = SwordJavaExactStringIdentity(provider.name)
                if providersByName[key] == nil {
                    orderedNames.append(key)
                }
                providersByName[key] = provider
            }
        }
        return orderedNames.compactMap { providersByName[$0] }
    }

    /**
     Returns exact installed module names whose admitted owners carry Android's font marker.

     - Returns: Module initials in installed TreeSet order without Swift canonical folding.
     - Side effects: Builds or reuses the shared admitted add-on projection.
     - Failure modes: Rejected, exact-initials-ambiguous, and marker-free owners contribute no name;
       an unreadable provider still leaves Android's marker-owning reload row present.
     */
    public func admittedFontModuleNames() -> [String] {
        return admittedAddonModules().compactMap { module in
            module.providesFont ? module.moduleInfo.name : nil
        }
    }

    /**
     Returns admitted WebView feature-module names in installed TreeSet order.

     - Returns: Exact initials for owners carrying `AndBibleProvidesFeature`.
     - Side effects: Builds or reuses the shared admitted add-on projection.
     - Failure modes: Rejected owners and owners without the marker contribute no name.
     */
    public func admittedWebFeatureModuleNames() -> [String] {
        admittedAddonModules().compactMap { module in
            module.providesWebFeature ? module.moduleInfo.name : nil
        }
    }

    /**
     Returns admitted WebView style-module names in installed TreeSet order.

     - Returns: Exact initials for owners carrying `AndBibleProvidesStyle`.
     - Side effects: Builds or reuses the shared admitted add-on projection.
     - Failure modes: Rejected owners and owners without the marker contribute no name.
     */
    public func admittedWebStyleModuleNames() -> [String] {
        admittedAddonModules().compactMap { module in
            module.providesWebStyle ? module.moduleInfo.name : nil
        }
    }

    /**
     Projects installed configs through Android's add-on admission and BookSet contract.

     - Parameters:
       - modulePath: SWORD module root containing the installed `mods.d` configs.
       - applicationVersionNumber: Exact Android version-code boundary used by deterministic tests.
     - Returns: Admitted add-ons in pinned JSword TreeSet order, with singular prompt metadata.
     - Side effects: Reads local config files and the pinned Android comparison table.
     - Failure modes: Missing, malformed, unsupported, or future configs are omitted fail closed.
     */
    static func admittedAddonModules(
        modulePath: String,
        applicationVersionNumber: Int
    ) -> [SwordAdmittedAddonModule] {
        guard let manager = SwordManager(modulePath: modulePath) else { return [] }
        return manager.admittedAddonModules(applicationVersionNumber: applicationVersionNumber)
    }

    /**
     Projects only books that entered this manager's installed registry through Android admission.

     - Parameter applicationVersionNumber: Android compatibility version used by feature filtering.
     - Returns: Payload-admitted add-ons in installed TreeSet order with adjusted locations.
     - Side effects: Builds the manager's native registry snapshot, reads configs, and checks custom
       payload metadata; document content is not read.
     - Failure modes: Missing payloads, unsafe locations, unsupported drivers, and incompatible
       add-ons are omitted fail closed.
     */
    private func admittedAddonModules(
        applicationVersionNumber: Int
    ) -> [SwordAdmittedAddonModule] {
        SwordInstalledAddonInventory.modules(
            from: installedRegistryProjection().addonCandidates,
            applicationVersionNumber: applicationVersionNumber
        )
    }
    /**
     Builds the shared installed add-on owners before consumer-specific field projection.

     - Parameter applicationVersionNumber: Android compatibility version used by feature filtering.
     - Returns: Final installed TreeSet owners carrying their exact config, access state, and
       adjusted location.
     - Side effects: Builds the manager's native registry snapshot and enumerates standalone CSV
       prompt files; document content is not read.
     - Failure modes: Invalid native payloads, rejected custom owners, duplicate standalone
       identities, and incompatible final owners are omitted fail closed.
     */
    private func admittedAddonCandidates(
        applicationVersionNumber: Int
    ) -> [InstalledAddonCandidate] {
        return SwordInstalledAddonInventory.admittedCandidates(
            installedRegistryProjection().addonCandidates,
            applicationVersionNumber: applicationVersionNumber
        )
    }

    /**
     Synthesizes Android's configless CSV books under `modulesDir/prompts` after driver registration.

     - Parameters:
       - modulePath: Installed SWORD root containing the optional readable `prompts` directory.
       - installedRegistrations: Current Books registry in add order; accepted synthetic books are
         appended so later files replay Android's `Books.getBook(initials)` preflight.
     - Returns: Readable CSV prompt books in filesystem enumeration order with exact Android
       generated metadata and their prompts-directory location.
     - Side effects: Enumerates the prompts directory and reads file metadata without CSV content.
     - Failure modes: Missing/unreadable directories, non-files, non-CSV extensions, unreadable
       files, malformed generated metadata, and an existing lookup owner are omitted fail closed.
     */
    private static func standalonePromptCandidates(
        modulePath: String,
        installedRegistrations: inout [InstalledModuleRegistration]
    ) -> [InstalledAddonCandidate] {
        let fileManager = FileManager.default
        let promptDirectory = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("prompts", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: promptDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: promptDirectory.path),
              let files = try? fileManager.contentsOfDirectory(
                at: promptDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
              ) else {
            return []
        }

        var candidates: [InstalledAddonCandidate] = []
        for fileURL in files {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true,
                  fileManager.isReadableFile(atPath: fileURL.path),
                  SwordJavaStringIdentity.equalsIgnoreCase(fileURL.pathExtension, "csv") else {
                continue
            }
            let packName = fileURL.deletingPathExtension().lastPathComponent
            let initials = "Prompts_\(packName)"
            guard installedRegistration(named: initials, in: installedRegistrations) == nil else {
                continue
            }
            let content = """
            [\(initials)]
            Description=\(packName) prompts
            Category=And Bible
            ModDrv=RawGenBook
            DataPath=./prompts/
            Encoding=UTF-8
            AndBibleProvidesPrompts=\(fileURL.lastPathComponent)
            AndBibleMinimumVersion=892
            """
            guard let config = SwordModuleConfig.parse(content, sourceURL: fileURL),
                  SwordJavaStringIdentity.equals(config.name, initials),
                  config.values["AndBibleProvidesPrompts"]?.first == fileURL.lastPathComponent else {
                continue
            }
            let registration = installedRegistration(for: config)
            installedRegistrations.append(registration)
            candidates.append(
                InstalledAddonCandidate(
                    registration: registration,
                    config: config,
                    locationURL: promptDirectory.standardizedFileURL,
                    removalTarget: SwordInstalledAddonRemovalTarget(
                        standalonePromptFileName: fileURL.lastPathComponent,
                        moduleName: initials
                    )
                )
            )
        }
        return candidates
    }

    /**
     Captures the exact installed config owner used by add-on deletion.

     - Parameters:
       - config: Parsed, payload-admitted native config with a concrete source file.
       - registration: Installed Book metadata and abbreviation produced from that config.
       - locationURL: JSword-adjusted installed location, or nil when metadata retained none.
       - modulePath: Canonical manager root used to express the config as a bounded relative path.
     - Returns: Opaque config-backed removal identity.
     - Side effects: Resolves standardized filesystem paths without mutation.
     - Failure modes: None; native admission already requires a direct-root source config. A
       defensive nonrelative source produces a path that the mutation boundary rejects fail closed.
     */
    private static func configRemovalTarget(
        config: SwordModuleConfig,
        registration: InstalledModuleRegistration,
        locationURL: URL?,
        modulePath: String
    ) -> SwordInstalledAddonRemovalTarget {
        let rootURL = URL(fileURLWithPath: modulePath, isDirectory: true).standardizedFileURL
        let configURL = config.sourceURL?.standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let relativePath: String
        if let configURL, configURL.path.hasPrefix(rootPrefix) {
            relativePath = String(configURL.path.dropFirst(rootPrefix.count))
        } else {
            relativePath = configURL?.lastPathComponent ?? ""
        }
        let standardizedLocation = locationURL?.standardizedFileURL
        let locationRelativePath: String?
        if let standardizedLocation, standardizedLocation.path.hasPrefix(rootPrefix) {
            locationRelativePath = String(standardizedLocation.path.dropFirst(rootPrefix.count))
        } else {
            locationRelativePath = nil
        }
        return SwordInstalledAddonRemovalTarget(
            configRelativePath: relativePath,
            moduleName: registration.info.name,
            fullName: registration.fullName,
            abbreviation: registration.abbreviation,
            driver: config.modDrv,
            dataPath: config.dataPath,
            locationRelativePath: locationRelativePath
        )
    }

    /**
     Resolves one `Books.getBook` token against the current installed add sequence.

     - Parameters:
       - name: Exact initials/name or Java case-insensitive alias proposed by a synthetic book.
       - registrations: Books in Android add order before the new synthetic book.
     - Returns: The surviving exact-initials owner, exact-name owner, then first TreeSet alias.
     - Side effects: Loads the pinned Android case-fold table for TreeSet alias comparison.
     - Failure modes: Empty or unmatched names return nil without changing the registry.
     */
    private static func installedRegistration(
        named name: String,
        in registrations: [InstalledModuleRegistration]
    ) -> InstalledModuleRegistration? {
        var surviving: [InstalledModuleRegistration] = []
        for registration in registrations {
            let identity = SwordInstalledBookSetProjection.identity(for: registration)
            surviving.removeAll { SwordInstalledBookSetProjection.identity(for: $0) == identity }
            surviving.append(registration)
        }
        return surviving.last { SwordJavaStringIdentity.equals($0.info.name, name) }
            ?? surviving.last { SwordJavaStringIdentity.equals($0.fullName, name) }
            ?? surviving.sorted { SwordInstalledBookSetProjection.compare($0, $1) < 0 }.first {
                SwordJavaStringIdentity.equalsIgnoreCase($0.info.name, name)
                    || SwordJavaStringIdentity.equalsIgnoreCase($0.fullName, name)
            }
    }

    /**
     Resolves JSword's filesystem-adjusted book location for one installed config.

     JSword treats an existing `DataPath` directory as the book location even without a trailing
     slash. A declared directory must exist; otherwise `DataPath` is a file prefix whose `.dat`
     sentinel must exist and whose parent becomes the location.

     - Parameters:
       - config: Payload-admitted config whose first raw `DataPath` owns the book location.
       - modulePath: SWORD root that bounds all accepted feature files.
     - Returns: An admitted location state, including explicit no-location for slashless paths, or
       nil when JSword would reject the payload.
     - Side effects: Resolves symlinks and reads filesystem metadata without mutation.
     - Failure modes: An absent `DataPath`, escaped paths, and missing declared directories or
       prefix sentinels return nil.
     */
    static func adjustedModuleLocation(
        for config: SwordModuleConfig,
        modulePath: String
    ) -> AdjustedModuleLocation? {
        let root = URL(fileURLWithPath: modulePath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard let rawDataPath = config.values["DataPath"]?.first else { return nil }
        let trimmedDataPath = SwordJavaStringIdentity.trim(rawDataPath)
        guard !trimmedDataPath.isEmpty else { return .noLocation }
        if !trimmedDataPath.contains("/") {
            return .noLocation
        }
        let relativeDataPathWithShape = trimmedDataPath.hasPrefix("./")
            ? String(trimmedDataPath.dropFirst(2))
            : trimmedDataPath
        let declaredDirectory = relativeDataPathWithShape.hasSuffix("/")
        let relativeDataPath = declaredDirectory
            ? String(relativeDataPathWithShape.dropLast())
            : relativeDataPathWithShape
        let dataURL = root.appendingPathComponent(relativeDataPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : "\(root.path)/"
        guard dataURL == root || dataURL.path.hasPrefix(rootPrefix) else { return nil }

        var isDirectory: ObjCBool = false
        let dataPathExists = FileManager.default.fileExists(
            atPath: dataURL.path,
            isDirectory: &isDirectory
        )
        let location: URL
        if dataPathExists && isDirectory.boolValue {
            location = dataURL
        } else {
            guard !declaredDirectory else { return nil }
            let sentinelURL = URL(fileURLWithPath: dataURL.path + ".dat")
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard sentinelURL.path.hasPrefix(rootPrefix) else { return nil }
            var sentinelIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: sentinelURL.path,
                isDirectory: &sentinelIsDirectory
            ), !sentinelIsDirectory.boolValue else {
                return nil
            }
            location = dataURL.deletingLastPathComponent()
        }
        guard location == root || location.path.hasPrefix(rootPrefix) else { return nil }
        var locationIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: location.path,
            isDirectory: &locationIsDirectory
        ), locationIsDirectory.boolValue else {
            return nil
        }
        return .location(location)
    }

    /**
     Projects one supported native config to the concrete class created by pinned JSword `BookType`.

     JSword selects the `AbstractBook` subclass from the registered driver/book-type contract rather
     than from the configured category alone. Native text, commentary, and raw-file drivers create
     `SwordBook`; generic-book creates `SwordGenBook`; lexical data creates `SwordDictionary` except
     for its daily-devotional specialization.

     - Parameter config: Parsed config already proven supported by the calling registry/admission
       gate.
     - Returns: Stable discriminator matching the concrete JSword class used by `AbstractBook.equals`.
     - Side effects: None.
     - Failure modes: None. Callers admit only pinned native drivers; the remaining supported native
       branch is lexical data and therefore maps to `SwordDictionary`.
     */
    private static func nativeSwordBookClassIdentity(
        for config: SwordModuleConfig
    ) -> NativeSwordBookClassIdentity {
        let info = config.moduleInfo
        if info.isJSwordSwordBook {
            return .swordBook
        }

        let driver = config.modDrv
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if driver == "rawgenbook" {
            return .swordGenBook
        }
        if config.category == .dailyDevotion {
            return .swordDailyDevotion
        }
        return .swordDictionary
    }

    /**
     Projects one parsed config into the comparator fields used by JSword's installed TreeSet.

     - Parameter config: Parsed installed book metadata.
     - Returns: Registration with Java-trimmed abbreviation fallback and exact identity/name fields.
     - Side effects: None.
     - Failure modes: Missing or Java-empty abbreviation falls back to exact initials.
     */
    private static func installedRegistration(
        for config: SwordModuleConfig
    ) -> InstalledModuleRegistration {
        let abbreviation = config.values["Abbreviation"]?.first
            .map(SwordJavaStringIdentity.trim)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? config.name
        return InstalledModuleRegistration(
            info: config.moduleInfo,
            abbreviation: abbreviation,
            fullName: config.description
        )
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
            if config.values["AndBibleDbFile"]?.first != nil {
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
            if config.values["AndBibleDbFile"]?.first != nil {
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
            if config.values["AndBibleMySwordModule"]?.isEmpty == false ||
                config.values["AndBibleESwordModule"]?.isEmpty == false {
                return androidDatabaseFileExists(config, modulePath: modulePath)
            }
            if config.values["AndBibleEpubModule"]?.isEmpty == false,
               let epubDir = config.values["AndBibleEpubDir"]?.first {
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
        guard let dbFile = config.values["AndBibleDbFile"]?.first else { return false }
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
     Resolves one `AndBibleProvidesReadingPlan` file reference from an adjusted JSword location.

     - Parameters:
       - fileName: Config value containing the provider file name.
       - locationURL: Payload-admitted location assigned by JSword metadata adjustment.
       - modulePath: SWORD module root.
     - Returns: Validated provider file URL, or `nil` when the file is unavailable or unsafe.
     - Side effects: Checks file metadata on disk.
     - Failure modes: Escaped provider paths and unreadable files return `nil`.
     */
    private static func readingPlanProviderFileURL(
        fileName: String,
        locationURL: URL,
        modulePath: String
    ) -> URL? {
        let normalizedFileName = fileName
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFileName.isEmpty else { return nil }

        let root = URL(fileURLWithPath: modulePath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolved = locationURL.appendingPathComponent(normalizedFileName)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : "\(root.path)/"
        guard resolved.path.hasPrefix(rootPrefix),
              FileManager.default.isReadableFile(atPath: resolved.path) else {
            return nil
        }
        return resolved
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
     Invalidates Swift-owned snapshots after an installed-module state change.

     - Side effects: Clears native, complete installed-registry, add-on, and module-wrapper caches.
     - Failure modes: None. The underlying libsword manager is immutable; callers must construct a
       new `SwordManager` to discover newly installed native handles.
     */
    public func refresh() {
        SwordRuntime.sync {
            nativeRegistrySnapshotCache = nil
            installedRegistryProjectionCache = nil
            admittedAddonModulesCache = nil
            moduleAuthorizationCache.clear()
        }
        // Recreate is the simplest way to refresh libsword's module list.
        // The caller should create a new SwordManager instance for a full refresh.
    }
}
