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
    /**
     One supported native SWORD book registered with the fields used by JSword's `BookSet`.

     The module handle is created from the exact config initials and retained beside the fresh
     session-adjusted metadata. Values are immutable after construction; creating a registration may
     populate the manager cache but does not read document content.
     */
    private struct NativeModuleRegistration {
        /// Exact native module handle whose metadata initials match `info.name` by Java equality.
        let module: SwordModule

        /// Inclusive installed metadata, including current locked/unlocked ownership state.
        let info: ModuleInfo

        /// Parsed JSword abbreviation, falling back to exact initials when absent or Java-empty.
        let abbreviation: String

        /// Exact config `Description` used by JSword's full-name map and final TreeSet tie-break.
        let fullName: String

        /// Exact installed config owner used for verified cipher-key persistence.
        let configURL: URL
    }

    /**
     Captures native inventory separately from registrations whose backend ownership is proven.

     `installedRegistrations` may retain comparator-distinct metadata rows that share exact
     initials, matching JSword's public TreeSet inventory. `resolvableRegistrations` excludes every
     raw duplicate-exact-initial collision before a `SwordModule` wrapper can enter the manager
     cache. Values are immutable after the single config/native capture and read no content.
     */
    private struct NativeModuleRegistrySnapshot {
        /// Supported native metadata rows eligible for installed-TreeSet projection.
        let installedRegistrations: [InstalledModuleRegistration]

        /// Ownership-proven registrations keyed by unique exact initials.
        let exactInitials: [SwordJavaExactStringIdentity: NativeModuleRegistration]

        /// Ownership-proven registrations keyed only by unique exact full names.
        let exactFullNames: [SwordJavaExactStringIdentity: NativeModuleRegistration]

        /// Exact full-name keys intentionally withheld because multiple books claim them.
        let ambiguousExactFullNames: Set<SwordJavaExactStringIdentity>

        /// Ownership-proven registrations in installed JSword TreeSet order for alias lookup.
        let treeSetRegistrations: [NativeModuleRegistration]
    }

    /**
     Metadata and the JSword abbreviation required to merge every installed book family.

     Native registrations retain their parsed abbreviation, while sidecar formats without that
     field use initials just as their Android-compatible metadata constructors do. Values are
     immutable and perform no work after construction.
     */
    private struct InstalledModuleRegistration {
        /// Inclusive installed metadata returned through the public inventory API.
        let info: ModuleInfo

        /// Exact JSword abbreviation used after category in installed-TreeSet ordering.
        let abbreviation: String

        /// Exact user-visible name used by JSword's final raw UTF-16 tie-break.
        let fullName: String
    }

    /**
     Concrete JSword `AbstractBook` subclass participating in native driver-set equality.

     `AbstractBook.equals` rejects a different concrete class before delegating to metadata equality.
     The discriminator therefore preserves same-metadata books produced by different supported
     `BookType`s while remaining independent of Swift runtime type names.
     */
    private enum NativeSwordBookClassIdentity: Hashable {
        /// Verse-keyed `SwordBook` produced by text/commentary/raw-files book types.
        case swordBook

        /// List-keyed `SwordDictionary` produced by native lexical-data book types.
        case swordDictionary

        /// Calendar-keyed `SwordDailyDevotion` produced by daily-devotional lexical data.
        case swordDailyDevotion

        /// Tree-keyed `SwordGenBook` produced by native generic-book data.
        case swordGenBook
    }

    /**
     Hash identity used by `SwordBookDriver` before it returns its arbitrary-order book array.

     Pinned `AbstractBook.equals` first requires the same concrete class, then
     `AbstractBookMetaData.equals` compares exact category, full name, and initials. Its `HashSet`
     therefore drops only same-class books with all three exact metadata fields equal. Exact UTF-16
     keys avoid Swift canonical-equivalence collapse.
     */
    private struct NativeSwordBookHashIdentity: Hashable {
        /// Concrete `AbstractBook` subclass created by the config's supported JSword `BookType`.
        let bookClass: NativeSwordBookClassIdentity

        /// Pinned JSword category ordinal participating in metadata equality.
        let categoryOrdinal: Int

        /// Exact Java initials participating in metadata equality.
        let initials: SwordJavaExactStringIdentity

        /// Exact Java full name participating in metadata equality.
        let fullName: SwordJavaExactStringIdentity
    }

    /** Hash identity for one comparator slot in JSword's installed `TreeSet`. */
    private struct InstalledBookSetIdentity: Hashable {
        /// Pinned JSword category ordinal, the comparator's first field.
        let categoryOrdinal: Int

        /// Java case-insensitive abbreviation identity, the comparator's second field.
        let abbreviation: SwordJavaStringIdentity

        /// Exact Java initials, the comparator's third field.
        let initials: SwordJavaExactStringIdentity

        /// Exact Java full name, the comparator's final field.
        let fullName: SwordJavaExactStringIdentity
    }

    private let handle: UnsafeMutableRawPointer

    /// Internal access to the C handle for InstallManager operations.
    var rawHandle: UnsafeMutableRawPointer { handle }
    /// Native handle cache keyed by Java-exact UTF-16 initials rather than Swift canonical equality.
    private var moduleCache: [SwordJavaExactStringIdentity: SwordModule] = [:]

    /// One manager-lifetime config/registry capture, invalidated by unlock and explicit refresh.
    private var nativeRegistrySnapshotCache: NativeModuleRegistrySnapshot?

    /// Current-session unlock overrides keyed by the exact canonical initials that were verified.
    private var sessionUnlockedModuleNames: Set<SwordJavaExactStringIdentity> = []

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

     - Returns: SWORD modules and readable Android custom modules projected through JSword's
       category/abbreviation/initials/name TreeSet comparator. Canonically equivalent Java-distinct
       UTF-16 spellings and comparator-distinct duplicate-initial metadata remain separate books.
     - Side effects: Reads `mods.d` configs, sidecar metadata, and checks custom payload files.
     - Failure modes: Malformed configs, modules libsword cannot resolve, and custom rows without
       readable payloads are skipped.
     - Note: Locked encrypted modules remain visible with `isUnlocked == false`; a key verified in
       this manager session overrides only that module's stale native metadata snapshot.
     */
    public func installedModules() -> [ModuleInfo] {
        let swordModules = nativeModuleRegistrySnapshot().installedRegistrations
        let restoredCustomModules = Self.androidCustomInstalledRegistrations(modulePath: modulePath)
        let packageModules = Self.admittedMyBiblePackageRegistrations(
            Self.myBiblePackageRegistrations(modulePath: modulePath),
            after: swordModules + restoredCustomModules
        )

        let merged = Self.mergedInstalledModules(
            swordModules: swordModules,
            customModules: restoredCustomModules + packageModules
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
            sessionUnlockedModuleNames.insert(SwordJavaExactStringIdentity(canonicalName))
            nativeRegistrySnapshotCache = nil
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
     - Failure modes: Custom, missing, cross-resolved, and unsupported configs are omitted from
       native inventory. Duplicate identity detection occurs before those filters, preventing one
       filtered config from making a surviving backend appear safely owned. Exact full-name
       collisions remain individually readable by initials but fail closed through the name map.
     - Important: All native work executes through the re-entrant `SwordRuntime` serialization gate.
     - Complexity: O(N log N) once per cache lifetime; cached exact lookup is O(1).
     */
    private func nativeModuleRegistrySnapshot() -> NativeModuleRegistrySnapshot {
        SwordRuntime.sync {
            if let nativeRegistrySnapshotCache { return nativeRegistrySnapshotCache }
            let configs = SwordModuleConfig.readAll(modulePath: modulePath)
            var exactInitialCounts: [SwordJavaExactStringIdentity: Int] = [:]
            for config in configs {
                exactInitialCounts[SwordJavaExactStringIdentity(config.name), default: 0] += 1
            }
            let ambiguousExactInitials = Set(
                exactInitialCounts.compactMap { identity, count in
                    count > 1 ? identity : nil
                }
            )

            let deterministicConfigs = configs.sorted {
                Self.javaStringCompare($0.sourceURL?.path ?? "", $1.sourceURL?.path ?? "") < 0
            }
            var nativeHashIdentities: Set<NativeSwordBookHashIdentity> = []
            var installedRegistrations: [InstalledModuleRegistration] = []
            var resolvableRegistrations: [NativeModuleRegistration] = []
            for config in deterministicConfigs {
                guard !config.isAndroidCustomDriver,
                      let configURL = config.sourceURL,
                      let moduleHandle = SWMgr_getModuleByName(handle, config.name) else {
                    continue
                }
                let nativeName = String(cString: SWModule_getName(moduleHandle))
                guard SwordJavaStringIdentity.equals(nativeName, config.name) else {
                    continue
                }

                let persistedCipherKey = config.values["CipherKey"]?.first
                let isEncrypted = persistedCipherKey != nil
                let isUnlocked = !isEncrypted || sessionUnlockedModuleNames.contains(
                    SwordJavaExactStringIdentity(config.name)
                ) || (persistedCipherKey?.isEmpty == false)
                let info = Self.moduleInfo(
                    config: config,
                    overridingUnlocked: isUnlocked
                )
                guard info.isSupported else { continue }

                let nativeHashIdentity = NativeSwordBookHashIdentity(
                    bookClass: Self.nativeSwordBookClassIdentity(for: config),
                    categoryOrdinal: Self.jswordCategoryOrdinal(info.category),
                    initials: SwordJavaExactStringIdentity(info.name),
                    fullName: SwordJavaExactStringIdentity(config.description)
                )
                guard nativeHashIdentities.insert(nativeHashIdentity).inserted else { continue }

                let configuredAbbreviation = config.values["Abbreviation"]?.first
                    .map(SwordJavaStringIdentity.trim)
                let abbreviation = configuredAbbreviation.flatMap { $0.isEmpty ? nil : $0 }
                    ?? info.name
                installedRegistrations.append(
                    InstalledModuleRegistration(
                        info: info,
                        abbreviation: abbreviation,
                        fullName: config.description
                    )
                )

                let exactInitials = SwordJavaExactStringIdentity(config.name)
                guard !ambiguousExactInitials.contains(exactInitials),
                      let module = exactModule(
                        name: config.name,
                        handle: moduleHandle,
                        config: config
                      ) else {
                    continue
                }
                resolvableRegistrations.append(
                    NativeModuleRegistration(
                        module: module,
                        info: info,
                        abbreviation: abbreviation,
                        fullName: config.description,
                        configURL: configURL
                    )
                )
            }
            let treeSetRegistrations = resolvableRegistrations.sorted {
                Self.nativeBookSetComparison($0, $1) < 0
            }
            var exactInitials: [SwordJavaExactStringIdentity: NativeModuleRegistration] = [:]
            var exactFullNameCounts: [SwordJavaExactStringIdentity: Int] = [:]
            for registration in treeSetRegistrations {
                exactInitials[SwordJavaExactStringIdentity(registration.info.name)] = registration
                exactFullNameCounts[
                    SwordJavaExactStringIdentity(registration.fullName),
                    default: 0
                ] += 1
            }
            var exactFullNames: [SwordJavaExactStringIdentity: NativeModuleRegistration] = [:]
            for registration in treeSetRegistrations {
                let identity = SwordJavaExactStringIdentity(registration.fullName)
                if exactFullNameCounts[identity] == 1 {
                    exactFullNames[identity] = registration
                }
            }
            let snapshot = NativeModuleRegistrySnapshot(
                installedRegistrations: installedRegistrations,
                exactInitials: exactInitials,
                exactFullNames: exactFullNames,
                ambiguousExactFullNames: Set(
                    exactFullNameCounts.compactMap { identity, count in
                        count > 1 ? identity : nil
                    }
                ),
                treeSetRegistrations: treeSetRegistrations
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
     Compares native registrations with JSword `AbstractBookMetaData.compareTo` fields.

     - Parameters describe two supported native registrations.
     - Returns: Negative, zero, or positive for category, abbreviation, initials, then full name.
     - Side effects: Loads the pinned Android character table for abbreviation comparison.
     - Failure modes: None; categories and strings have total deterministic orderings.
     */
    private static func nativeBookSetComparison(
        _ lhs: NativeModuleRegistration,
        _ rhs: NativeModuleRegistration
    ) -> Int {
        let categoryOrder = jswordCategoryOrdinal(lhs.info.category)
            - jswordCategoryOrdinal(rhs.info.category)
        if categoryOrder != 0 { return categoryOrder }

        let abbreviationOrder = SwordJavaStringIdentity.compareIgnoreCase(
            lhs.abbreviation,
            rhs.abbreviation
        )
        if abbreviationOrder != 0 { return abbreviationOrder }

        let initialsOrder = javaStringCompare(lhs.info.name, rhs.info.name)
        if initialsOrder != 0 { return initialsOrder }
        return javaStringCompare(lhs.fullName, rhs.fullName)
    }

    /**
     Creates or returns one native module cache row keyed by exact Java initials.

     - Parameters:
       - name: Exact config initials used to request `handle` from libsword.
       - handle: Native module handle owned by this manager.
       - config: Already-parsed exact config owner from the one-pass registry scan.
     - Returns: Stable wrapper only when its reported initials exactly match the requested identity.
     - Side effects: Inserts one validated wrapper into the manager cache on first access.
     - Failure modes: A cross-resolved native handle returns nil and is never cached under `name`.
     */
    private func exactModule(
        name: String,
        handle: UnsafeMutableRawPointer,
        config: SwordModuleConfig
    ) -> SwordModule? {
        let identity = SwordJavaExactStringIdentity(name)
        if let cached = moduleCache[identity] { return cached }
        let module = SwordModule(
            handle: handle,
            modulePath: modulePath,
            parsedConfig: config
        )
        guard SwordJavaExactStringIdentity(module.info.name) == identity else { return nil }
        moduleCache[identity] = module
        return module
    }

    /**
     Merges libsword and Android custom-driver registrations through JSword TreeSet semantics.

     - Parameters:
       - swordModules: Modules enumerated by libsword.
       - customModules: Config-projected custom modules.
     - Returns: Comparator-distinct modules sorted by pinned category, abbreviation, exact initials,
       and exact full name. Same-initials books with different comparator fields remain installed.
     - Side effects: Loads the pinned Android character table used by the sort comparator.
     - Failure modes: none.
     */
    private static func mergedInstalledModules(
        swordModules: [InstalledModuleRegistration],
        customModules: [InstalledModuleRegistration]
    ) -> [ModuleInfo] {
        installedRegistrationOrderProjection(swordModules + customModules)
            .map(\.info)
    }

    /**
     Replays comparator-equal replacement for the combined installed registration sequence.

     - Parameter registrations: Native and custom books in their captured add sequence.
     - Returns: Surviving registrations in pinned TreeSet order, with a later comparator-equal owner
       replacing the earlier.
     - Side effects: Loads the pinned Android character table for abbreviation comparison.
     - Failure modes: None; an empty sequence returns an empty projection.
     - Complexity: O(N log N), using the exact comparator identity instead of repeated array scans.
     */
    private static func installedRegistrationOrderProjection(
        _ registrations: [InstalledModuleRegistration]
    ) -> [InstalledModuleRegistration] {
        var surviving: [InstalledBookSetIdentity: InstalledModuleRegistration] = [:]
        for registration in registrations {
            surviving[installedBookSetIdentity(registration)] = registration
        }
        return surviving.values.sorted { installedModuleComparison($0, $1) < 0 }
    }

    /**
     Builds the exact hash identity for a zero-valued JSword installed-book comparison.

     - Parameter registration: Installed metadata and abbreviation to identify.
     - Returns: Category, case-folded abbreviation, exact initials, and exact full-name fields.
     - Side effects: Loads the pinned Android case-fold table for the abbreviation.
     - Failure modes: None; every registration has a complete deterministic identity.
     */
    private static func installedBookSetIdentity(
        _ registration: InstalledModuleRegistration
    ) -> InstalledBookSetIdentity {
        InstalledBookSetIdentity(
            categoryOrdinal: jswordCategoryOrdinal(registration.info.category),
            abbreviation: SwordJavaStringIdentity(registration.abbreviation),
            initials: SwordJavaExactStringIdentity(registration.info.name),
            fullName: SwordJavaExactStringIdentity(registration.fullName)
        )
    }

    /**
     Orders installed registrations through pinned JSword comparator fields.

     - Parameters:
       - lhs: First installed registration.
       - rhs: Second installed registration.
     - Returns: Negative, zero, or positive for category, abbreviation, initials, then full name.
     - Side effects: Loads the pinned Android character table for abbreviation comparison.
     - Failure modes: None; categories and strings have total deterministic orderings.
     */
    private static func installedModuleComparison(
        _ lhs: InstalledModuleRegistration,
        _ rhs: InstalledModuleRegistration
    ) -> Int {
        let categoryOrder = jswordCategoryOrdinal(lhs.info.category)
            - jswordCategoryOrdinal(rhs.info.category)
        if categoryOrder != 0 { return categoryOrder }

        let abbreviationOrder = SwordJavaStringIdentity.compareIgnoreCase(
            lhs.abbreviation,
            rhs.abbreviation
        )
        if abbreviationOrder != 0 { return abbreviationOrder }

        let initialsOrder = javaStringCompare(lhs.info.name, rhs.info.name)
        if initialsOrder != 0 { return initialsOrder }
        return javaStringCompare(lhs.fullName, rhs.fullName)
    }

    /**
     Returns the pinned JSword `BookCategory.ordinal()` for one installed metadata row.

     - Parameter category: iOS projection of one pinned JSword book category.
     - Returns: Exact Android enum ordinal used as the first installed TreeSet comparator field.
     - Side effects: None.
     - Failure modes: None; the switch exhaustively maps every `ModuleCategory` case.
     */
    private static func jswordCategoryOrdinal(_ category: ModuleCategory) -> Int {
        switch category {
        case .bible: return 0
        case .dictionary: return 1
        case .commentary: return 2
        case .dailyDevotion: return 3
        case .glossary: return 4
        case .questionable: return 5
        case .essays: return 6
        case .images: return 7
        case .map: return 8
        case .generalBook: return 9
        case .unknown: return 10
        case .addon: return 11
        }
    }

    /**
     Compares strings by Java `String.compareTo` unsigned UTF-16 semantics.

     - Parameters describe the left and right exact Java strings.
     - Returns: First code-unit difference, or the UTF-16 length difference when one is a prefix.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func javaStringCompare(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.utf16
        let right = rhs.utf16
        for (leftUnit, rightUnit) in zip(left, right) where leftUnit != rightUnit {
            return Int(leftUnit) - Int(rightUnit)
        }
        return left.count - right.count
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
        installedRegistrationOrderProjection(
            admittedMyBiblePackageRegistrations(
                myBiblePackageRegistrations(modulePath: modulePath),
                after: []
            )
        ).map(\.info)
    }

    /**
     Reads payload-owned MyBible registrations from every valid iOS package sidecar directory.

     - Parameter modulePath: SWORD root containing the `mybible` package directory.
     - Returns: Registrations in deterministic exact UTF-16 directory and payload-path order.
     - Side effects: Enumerates sidecars and opens/closes candidate SQLite databases read-only.
     - Failure modes: Missing/unreadable directories, malformed sidecars, and unsupported payloads
       are skipped independently.
     */
    private static func myBiblePackageRegistrations(
        modulePath: String
    ) -> [InstalledModuleRegistration] {
        let fm = FileManager.default
        let installDirectory = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mybible", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: installDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        return entries.sorted {
            javaStringCompare($0.path, $1.path) < 0
        }.flatMap { url -> [InstalledModuleRegistration] in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return []
            }
            let metadataURL = url.appendingPathComponent("module.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(InstalledMyBibleModule.self, from: data) else {
                return []
            }
            return InstalledMyBibleBookReader.registrations(in: url, sidecar: metadata).map {
                InstalledModuleRegistration(
                    info: $0.info,
                    abbreviation: $0.abbreviation,
                    fullName: $0.info.description
                )
            }
        }
    }

    /**
     Applies Android's pre-add `Books.getBook(metadata.initials)` gate to manual MyBible books.

     Native/restored config books are supplied first because Android registers them before scanning
     manually installed MyBible databases. Each accepted package immediately participates in exact
     initials/full-name and case-insensitive TreeSet alias lookup for the next candidate. Android's
     filesystem discovery winner is runtime-dependent; iOS uses exact path order but preserves the
     deterministic observable contract that at most the first matching identity is admitted.

     - Parameters:
       - candidates: Database-derived registrations in deterministic payload discovery order.
       - existing: Books registered before manual MyBible discovery.
     - Returns: Candidate registrations whose initials do not resolve through the current BookSet.
     - Side effects: Loads the pinned Android case table for alias comparison.
     - Failure modes: Colliding candidates are skipped; an empty sequence returns an empty array.
     - Complexity: O(N) expected time using exact and pinned case-fold identity indexes, avoiding a
       repeated full config/database projection or BookSet scan for each module.
     */
    private static func admittedMyBiblePackageRegistrations(
        _ candidates: [InstalledModuleRegistration],
        after existing: [InstalledModuleRegistration]
    ) -> [InstalledModuleRegistration] {
        var exactInitials = Set(existing.map { SwordJavaExactStringIdentity($0.info.name) })
        var exactFullNames = Set(existing.map { SwordJavaExactStringIdentity($0.fullName) })
        var foldedInitials = Set(existing.map { SwordJavaStringIdentity($0.info.name) })
        var foldedFullNames = Set(existing.map { SwordJavaStringIdentity($0.fullName) })
        var admitted: [InstalledModuleRegistration] = []
        for candidate in candidates {
            let lookup = candidate.info.name
            let exactLookup = SwordJavaExactStringIdentity(lookup)
            let hasExactMatch = exactInitials.contains(exactLookup)
                || exactFullNames.contains(exactLookup)
            let foldedLookup = SwordJavaStringIdentity(lookup)
            let hasAliasMatch = !hasExactMatch && (
                foldedInitials.contains(foldedLookup) || foldedFullNames.contains(foldedLookup)
            )
            guard !hasExactMatch, !hasAliasMatch else { continue }

            exactInitials.insert(SwordJavaExactStringIdentity(candidate.info.name))
            exactFullNames.insert(SwordJavaExactStringIdentity(candidate.fullName))
            foldedInitials.insert(SwordJavaStringIdentity(candidate.info.name))
            foldedFullNames.insert(SwordJavaStringIdentity(candidate.fullName))
            admitted.append(candidate)
        }
        return admitted
    }

    /**
     Reads Android add-on modules that provide reading-plan files.

     Android discovers add-on plans from repeated `AndBibleProvidesReadingPlan` config values and
     resolves each file relative to the module's adjusted `DataPath` location. Providers are
     admitted only from `And Bible` books whose minimum version is compatible, then traversed in
     the installed TreeSet order that defines Android's duplicate-plan ownership.

     - Parameters:
       - modulePath: SWORD module root containing `mods.d` and module payloads.
       - applicationVersionNumber: Android version-code compatibility implemented by this iOS build.
         Nil uses the pinned current-stable compatibility level; tests may inject an exact boundary.
     - Returns: Readable admitted providers in first-plan TreeSet order, with a later TreeSet book
       replacing an earlier provider that declares the same plan code.
     - Side effects: Reads local config files and checks provider file metadata.
     - Failure modes: Missing configs, unreadable files, and escaped paths are skipped.
     */
    public static func readingPlanProviders(
        modulePath: String = SwordManager.defaultModulePath(),
        applicationVersionNumber: Int? = nil
    ) -> [SwordReadingPlanProvider] {
        var providersByCode: [String: SwordReadingPlanProvider] = [:]
        var orderedCodes: [String] = []
        let compatibleVersion = applicationVersionNumber
            ?? androidCompatibilityVersionNumber

        let configs = addonConfigsInInstalledOrder(
            SwordModuleConfig.readAll(modulePath: modulePath),
            applicationVersionNumber: compatibleVersion
        )
        for config in configs {
            let planFileNames = config.values["AndBibleProvidesReadingPlan"] ?? []
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
     Android current-stable version code whose add-on feature contract this iOS build implements.

     Pinned And Bible commit `00b4ea24` declares version code 1115. This deliberately does not read
     `CFBundleVersion`: iOS local builds use `1`, while release automation uses dotted UTC stamps, so
     neither value represents Android add-on compatibility. Advancing this constant requires parity
     review of add-on features introduced after the pinned Android version.
     */
    private static let androidCompatibilityVersionNumber = 1115

    /**
     Filters and orders configs through Android's `AndBibleAddonFilter` plus installed TreeSet.

     - Parameters:
       - configs: Parsed installed configs in the captured platform enumeration sequence.
       - applicationVersionNumber: Android version-code compatibility supported by this build.
     - Returns: Comparator-distinct admitted add-on configs in pinned installed-book order.
     - Side effects: Loads the pinned Android character table for category and abbreviation matching.
     - Failure modes: Missing minimum version defaults to zero; malformed/overflowing minimum values
       fail closed instead of reproducing Android's process-level `NumberFormatException`.
     */
    private static func addonConfigsInInstalledOrder(
        _ configs: [SwordModuleConfig],
        applicationVersionNumber: Int
    ) -> [SwordModuleConfig] {
        let deterministicConfigs = configs.sorted {
            javaStringCompare($0.sourceURL?.path ?? "", $1.sourceURL?.path ?? "") < 0
        }
        var nativeBooks: Set<NativeSwordBookHashIdentity> = []
        var surviving: [InstalledBookSetIdentity: (SwordModuleConfig, InstalledModuleRegistration)] = [:]
        for config in deterministicConfigs where addonConfigIsAdmitted(
            config,
            applicationVersionNumber: applicationVersionNumber
        ) {
            let registration = installedRegistration(for: config)
            let nativeIdentity = NativeSwordBookHashIdentity(
                bookClass: nativeSwordBookClassIdentity(for: config),
                categoryOrdinal: jswordCategoryOrdinal(registration.info.category),
                initials: SwordJavaExactStringIdentity(registration.info.name),
                fullName: SwordJavaExactStringIdentity(registration.fullName)
            )
            guard nativeBooks.insert(nativeIdentity).inserted else { continue }
            surviving[installedBookSetIdentity(registration)] = (config, registration)
        }
        return surviving.values.sorted {
            installedModuleComparison($0.1, $1.1) < 0
        }.map(\.0)
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
     Applies Android's add-on category and minimum-version admission rule to one parsed config.

     - Parameters:
       - config: Candidate installed config.
       - applicationVersionNumber: Android compatibility version implemented by this iOS build.
     - Returns: True for `And Bible` category and a missing/parseable compatible minimum version.
     - Side effects: Loads the pinned Android character table through category resolution.
     - Failure modes: Malformed and overflowing version values fail closed.
     */
    private static func addonConfigIsAdmitted(
        _ config: SwordModuleConfig,
        applicationVersionNumber: Int
    ) -> Bool {
        guard config.category == .addon, config.moduleInfo.isSupported else { return false }
        let rawMinimum = config.values["AndBibleMinimumVersion"]?.first ?? "0"
        guard let minimumVersion = Int64(rawMinimum) else { return false }
        return minimumVersion <= Int64(applicationVersionNumber)
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
            nativeRegistrySnapshotCache = nil
            moduleCache.removeAll()
        }
        // Recreate is the simplest way to refresh libsword's module list.
        // The caller should create a new SwordManager instance for a full refresh.
    }
}
