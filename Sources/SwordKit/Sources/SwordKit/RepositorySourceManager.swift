// RepositorySourceManager.swift — Android-parity custom repository source management

import CryptoKit
import Foundation

/**
 Resolved custom repository data that can be persisted by the iOS Downloads source manager.

 The registration mirrors Android's `CustomRepository` validation result closely enough for
 iOS's current catalog pipeline: the visible repository identity, repository family, manifest
 URL, package directory, and source URL are preserved. SWORD-compatible rows are projected into
 `InstallMgr.conf`; non-SWORD rows stay in the custom metadata store so edit/delete flows keep
 their original manifest context.
 */
public struct RepositorySourceRegistration: Sendable {
    /// Source identity and refresh metadata used by Downloads after persistence.
    public let source: SourceConfig

    /// Human-readable description returned by a manifest or synthesized from the source URL.
    public let description: String

    /// Remote package directory reported by Android-style manifests or inferred from a direct SWORD catalog URL.
    public let packageDirectory: String

    /// URL the user supplied or the manifest URL that produced this registration.
    public let manifestURL: URL

    /// HTTPS base URL used by the iOS catalog refresh path.
    public let sourceURL: URL

    /// Android custom-repository type that produced this registration.
    public let type: String

    /**
     Creates a resolved repository registration for persistence through `RepositorySourceManager`.

     - Parameters:
       - source: Source identity and refresh metadata used by Downloads after persistence.
       - description: Human-readable source description.
       - packageDirectory: Android-style package directory for SWORD repositories.
       - manifestURL: URL that produced this registration.
       - sourceURL: HTTPS base URL used by catalog refresh.
       - type: Android custom-repository type.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        source: SourceConfig,
        description: String,
        packageDirectory: String,
        manifestURL: URL,
        sourceURL: URL,
        type: String
    ) {
        self.source = source
        self.description = description
        self.packageDirectory = packageDirectory
        self.manifestURL = manifestURL
        self.sourceURL = sourceURL
        self.type = type
    }
}

/**
 Errors raised while validating or mutating repository source configuration.

 Each case maps to a user-actionable state from Android's custom repository flow: invalid HTTPS
 input, an unreadable repository endpoint, duplicate repository names, unsupported repository types,
 protected default-source deletion, stale edit targets, or local config read/write failures.
 */
public enum RepositorySourceManagementError: Error, Equatable, LocalizedError, Sendable {
    /// The input string could not be parsed as an absolute URL.
    case invalidURL(String)

    /// Android accepts only `https://` custom repository URLs; iOS follows the same rule.
    case httpsRequired

    /// The URL and Android fallback probes did not return a readable supported HTTPS repository.
    case repositoryUnreachable(String)

    /// A manifest was present but did not contain enough repository data for iOS to persist or refresh.
    case invalidManifest(String)

    /// The manifest describes a repository family iOS cannot consume through Downloads.
    case unsupportedRepositoryType(String)

    /// The package-directory override is not a safe repository path or targets a non-SWORD source.
    case invalidPackageDirectory(String)

    /// The resolved repository name already exists in default, beta, or custom source configuration.
    case duplicateSourceName(String)

    /// Default Android repositories are built-in and cannot be deleted from the custom-source UI.
    case protectedDefaultSource(String)

    /// The custom source being edited is no longer present in source config or metadata.
    case sourceNotFound(String)

    /// `InstallMgr.conf` could not be read after default configuration was created.
    case configReadFailed

    /// `InstallMgr.conf` could not be rewritten after a source-management action.
    case configWriteFailed(String)

    /// User-facing explanation for SwiftUI forms and alerts.
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "Invalid repository URL: \(value)"
        case .httpsRequired:
            return "Custom repositories must use an https:// URL."
        case .repositoryUnreachable(let value):
            return "Could not read a supported repository at \(value)."
        case .invalidManifest(let value):
            return "The repository manifest is not valid for iOS Downloads: \(value)"
        case .unsupportedRepositoryType(let value):
            return "Repository type \(value) is not supported on iOS yet."
        case .invalidPackageDirectory(let value):
            return "Invalid SWORD package directory: \(value)"
        case .duplicateSourceName(let value):
            return "A repository named \(value) already exists."
        case .protectedDefaultSource(let value):
            return "\(value) is a built-in repository and cannot be deleted here."
        case .sourceNotFound(let value):
            return "Repository named \(value) no longer exists."
        case .configReadFailed:
            return "Could not read repository configuration."
        case .configWriteFailed(let value):
            return "Could not save repository configuration: \(value)"
        }
    }
}

/**
 Atomic file-replacement dependency used by repository-source transactions.

 The live implementation delegates to `Data.write(options: .atomic)`. Package tests may replace
 exactly one write with a deterministic error so rollback and retained-journal recovery are tested
 through the same production transaction code.
 */
struct RepositorySourcePersistence {
    /// Atomically replaces the destination bytes or throws before the transaction may commit.
    let write: (_ data: Data, _ destination: URL) throws -> Void
    /// Removes one existing destination or throws before the transaction may commit.
    let remove: (_ destination: URL) throws -> Void

    /** Creates the live atomic writer. */
    init(fileManager: FileManager) {
        write = { data, destination in
            try data.write(to: destination, options: .atomic)
        }
        remove = { destination in
            try fileManager.removeItem(at: destination)
        }
    }

    /** Creates an injected writer for deterministic persistence tests. */
    init(
        write: @escaping (_ data: Data, _ destination: URL) throws -> Void,
        remove: @escaping (_ destination: URL) throws -> Void = { destination in
            try FileManager.default.removeItem(at: destination)
        }
    ) {
        self.write = write
        self.remove = remove
    }
}

/// File-system shape retained for one repository persistence target.
private enum RepositorySourceFileKind: String, Codable {
    case missing
    case regularFile
    case directory
}

/// Durable preimage for one repository persistence target.
private struct RepositorySourceFileSnapshot: Codable {
    let kind: RepositorySourceFileKind
    let data: Data?
}

/// Pre-commit journal that restores both repository stores as one logical transaction.
private struct RepositorySourcePersistenceJournal: Codable {
    let config: RepositorySourceFileSnapshot
    let customRepositories: RepositorySourceFileSnapshot
}

/**
 Owns custom repository validation and source persistence for the Downloads source UI.

 The manager intentionally follows Android's `CustomRepositoryEditor` sequence: require HTTPS,
 try the supplied URL as a manifest, try `manifest.json`, then fall back to probing a direct
 SWORD catalog containing the base URL, `packages`, and `mods.d.tar.gz`. SWORD custom sources
 are written to `InstallMgr.conf` because SWORD consumes that file directly. Android-compatible
 MyBible sources are persisted in `CustomRepositories.json` because they are not SWORD sources
 but still need stable edit/delete metadata and Downloads catalog refresh support.

 - Important: This type is `@unchecked Sendable` because it stores `URLSession` and `FileManager`.
   Persisted reads and mutations are serialized by a process-wide recursive lock; network
   validation remains independent and may run concurrently.
 */
public final class RepositorySourceManager: @unchecked Sendable {
    /// Posted after add, replace, delete, or reset actions successfully rewrite source configuration.
    public static let sourcesDidChangeNotification = Notification.Name(
        "org.andbible.RepositorySourceManager.sourcesDidChange"
    )

    private let basePath: String
    private let session: URLSession
    private let fileManager: FileManager
    private let persistence: RepositorySourcePersistence

    /// Serializes config/sidecar recovery and mutation across every manager instance in-process.
    private static let persistenceLock = NSRecursiveLock()

    private var configURL: URL {
        URL(fileURLWithPath: basePath, isDirectory: true)
            .appendingPathComponent("InstallMgr.conf")
    }

    private var customRepositoriesURL: URL {
        URL(fileURLWithPath: basePath, isDirectory: true)
            .appendingPathComponent("CustomRepositories.json")
    }

    private var persistenceJournalURL: URL {
        URL(fileURLWithPath: basePath, isDirectory: true)
            .appendingPathComponent("RepositorySources.transaction.json")
    }

    /**
     Creates a source manager for the SWORD install-manager config directory.

     - Parameters:
       - basePath: Directory containing `InstallMgr.conf`; defaults to `InstallManager.defaultBasePath()`.
       - session: URL session used for HTTPS manifest and direct-catalog validation.
       - fileManager: File-system dependency used for tests and config persistence.

     Side effects:
     - none during initialization; config files are created lazily by load or mutation methods.
     */
    public convenience init(
        basePath: String? = nil,
        session: URLSession? = nil,
        fileManager: FileManager = .default
    ) {
        self.init(
            basePath: basePath,
            session: session,
            fileManager: fileManager,
            persistence: RepositorySourcePersistence(fileManager: fileManager)
        )
    }

    /**
     Creates a source manager with an injectable atomic file writer for persistence-failure tests.

     Production callers use the public convenience initializer. Package tests inject a writer that
     fails one selected commit step, which verifies byte-for-byte rollback without weakening the
     production transaction path.

     - Parameters:
       - basePath: Directory containing the two repository stores.
       - session: URL session used for repository validation.
       - fileManager: File-system dependency used for reads, removal, and directory creation.
       - persistence: Atomic data writer used for journals and committed file replacements.
     - Side effects: None during initialization; interrupted transactions recover before the first
       load or mutation.
     - Failure modes: None during initialization.
     */
    init(
        basePath: String? = nil,
        session: URLSession? = nil,
        fileManager: FileManager = .default,
        persistence: RepositorySourcePersistence
    ) {
        self.basePath = basePath ?? InstallManager.defaultBasePath()
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration)
        }
        self.fileManager = fileManager
        self.persistence = persistence
    }

    /**
     Loads configured repository sources from SWORD config and custom repository metadata.

     SWORD rows are read from `InstallMgr.conf` and enriched from the custom metadata sidecar
     when available. MyBible rows live only in the sidecar and are appended after config-backed
     sources, matching Android's built-in-then-custom source ordering. Legacy custom SWORD rows
     that predate the sidecar are migrated by inferring Android-compatible direct-catalog metadata
     from their host and catalog path.

     - Returns: Source rows in persisted SWORD order followed by non-SWORD custom rows. If the
       SWORD config cannot be read, sidecar-only MyBible rows are still returned in sidecar order.

     Side effects:
     - creates or migrates default repository configuration through `InstallManager`.
     - best-effort writes `CustomRepositories.json` when legacy source-only custom rows can be
       backfilled and the sidecar is absent or decodable; load still returns enriched in-memory
       rows if the sidecar is unreadable or the write fails.

     Failure modes:
     - omits config-backed SWORD rows if the SWORD config file cannot be read
     - ignores malformed custom metadata records instead of failing all Downloads sources
     - skips backfill persistence when `CustomRepositories.json` exists but cannot be decoded,
       preserving the unreadable file for possible recovery
     */
    public func loadSources() -> [SourceConfig] {
        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }
        do {
            try recoverInterruptedPersistenceIfNeeded()
        } catch {
            return []
        }
        InstallManager.ensureDefaultConfigPublic(at: basePath)
        let customRecordLoad = loadCustomRepositoryRecordStore()
        var customRecords = customRecordLoad.records

        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return customRecords
                .filter { $0.type == SourceConfig.myBibleHTTPSRepositoryType }
                .map(\.source)
        }

        let persistedSources = Self.sourceLines(in: content).map(\.source)
        let backfilledRecords = Self.backfilledCustomRepositoryRecords(
            from: persistedSources,
            excludingNames: Set(customRecords.map(\.name))
        )
        if !backfilledRecords.isEmpty {
            customRecords.append(contentsOf: backfilledRecords)
            if customRecordLoad.canPersistBackfilledRecords {
                try? performJournaledPersistence {
                    try writeCustomRepositoryRecordsUnjournaled(customRecords)
                }
            }
        }
        let recordsByName = Dictionary(customRecords.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        var namesInConfig: Set<String> = []
        let configSources = persistedSources.map { persistedSource in
            namesInConfig.insert(persistedSource.name)
            let source = Self.sourceByApplyingAndroidDefaultMetadata(to: persistedSource)
            guard let record = recordsByName[source.name],
                  record.type == SourceConfig.swordHTTPSRepositoryType else {
                return source
            }
            return SourceConfig(
                name: source.name,
                type: source.type,
                host: source.host,
                catalogPath: source.catalogPath,
                repositoryType: record.type,
                description: record.description,
                packageDirectory: Self.normalizedOptionalPackageDirectory(record.packageDirectory),
                manifestURL: URL(string: record.manifestURL),
                sourceURL: URL(string: record.sourceURL)
            )
        }

        let myBibleSources = customRecords
            .filter { $0.type == SourceConfig.myBibleHTTPSRepositoryType && !namesInConfig.contains($0.name) }
            .map(\.source)

        return configSources + myBibleSources
    }

    /**
     Enriches a SWORD config row with Android default package-directory metadata.

     `InstallMgr.conf` is intentionally kept in SWORD's legacy three-field row shape, but built-in
     repositories still need Android's package directory before Downloads installs use them. Custom
     sidecar records already carry their own package directory and are applied later.

     - Parameter source: Source parsed from local SWORD config.
     - Returns: A source with Android package metadata when it matches a built-in repository.
     - Side effects: none.
     - Failure modes: non-default and already-enriched sources are returned unchanged.
     */
    private static func sourceByApplyingAndroidDefaultMetadata(to source: SourceConfig) -> SourceConfig {
        guard source.packageDirectory == nil,
              let packageDirectory = InstallManager.defaultPackageDirectory(for: source) else {
            return source
        }
        return SourceConfig(
            name: source.name,
            type: source.type,
            host: source.host,
            catalogPath: source.catalogPath,
            repositoryType: source.repositoryType,
            description: source.description,
            packageDirectory: packageDirectory,
            manifestURL: source.manifestURL,
            sourceURL: source.sourceURL
        )
    }

    /**
     Infers Android custom-repository metadata for legacy SWORD config rows with no sidecar record.

     Older iOS builds persisted custom SWORD repositories only as `HTTPSource` rows, losing
     Android's description, manifest URL, and package directory fields. When a row is not a
     packaged default and has no existing metadata record, the only durable source of truth is the
     SWORD host/catalog tuple, so the migration treats that tuple as a direct catalog URL and uses
     Android's direct-repository package-directory rule of `catalogDirectory/packages`.

     - Parameters:
       - sources: Parsed `InstallMgr.conf` source rows in persisted order.
       - excludingNames: Source names that already have custom metadata and must not be overwritten.
     - Returns: Valid sidecar records inferred from source-only custom rows, in config order.
     - Side effects: none; the caller owns persistence so source loading can decide how to handle
       write failures.
     - Failure modes: rows with default names, non-HTTP transports, malformed HTTPS URLs, duplicate
       metadata names, or invalid source fields are skipped because they cannot be backfilled safely.
     */
    private static func backfilledCustomRepositoryRecords(
        from sources: [SourceConfig],
        excludingNames: Set<String>
    ) -> [CustomRepositoryRecord] {
        var seenNames = excludingNames
        return sources.compactMap { source -> CustomRepositoryRecord? in
            guard source.type == "HTTP",
                  !InstallManager.isDefaultSourceName(source.name),
                  !seenNames.contains(source.name),
                  let sourceURL = try? httpsURL(host: source.host, path: source.catalogPath) else {
                return nil
            }
            seenNames.insert(source.name)

            let packageDirectory = appendingPathComponent("packages", toPath: source.catalogPath)
            let enrichedSource = SourceConfig(
                name: source.name,
                type: source.type,
                host: source.host,
                catalogPath: source.catalogPath,
                repositoryType: SourceConfig.swordHTTPSRepositoryType,
                description: sourceURL.absoluteString,
                packageDirectory: packageDirectory,
                manifestURL: sourceURL,
                sourceURL: sourceURL
            )

            guard (try? validateSourceFields(enrichedSource)) != nil else {
                return nil
            }

            return CustomRepositoryRecord(
                registration: RepositorySourceRegistration(
                    source: enrichedSource,
                    description: sourceURL.absoluteString,
                    packageDirectory: packageDirectory,
                    manifestURL: sourceURL,
                    sourceURL: sourceURL,
                    type: SourceConfig.swordHTTPSRepositoryType
                )
            )
        }
    }

    /**
     Tests whether a source belongs to Android's built-in normal or beta repository set.

     - Parameter source: Parsed source row.
     - Returns: `true` for default/beta rows that should be read-only in the custom repository UI.

     Side effects:
     - none
     */
    public func isDefaultSource(_ source: SourceConfig) -> Bool {
        InstallManager.isDefaultSourceName(source.name)
    }

    /**
     Validates and appends one custom HTTPS repository source.

     - Parameters:
       - rawURL: User-entered manifest URL or direct SWORD catalog URL.
       - packageDirectory: Optional user-edited SWORD package directory. Blank values preserve the
         manifest/default/direct-catalog directory discovered during validation.
     - Returns: Resolved repository registration that was persisted.

     Side effects:
     - performs HTTPS requests for manifest/direct-catalog validation
     - appends an `HTTPSource` row for SWORD repositories, or writes a MyBible metadata record
     - posts `sourcesDidChangeNotification` after a successful write

     - Throws: `RepositorySourceManagementError` for validation, duplicate, or persistence failures.
     */
    @discardableResult
    public func addCustomSource(
        from rawURL: String,
        packageDirectory: String? = nil
    ) async throws -> RepositorySourceRegistration {
        let resolvedRegistration = try await resolveCustomSource(from: rawURL)
        let registration = try Self.registration(
            byApplyingPackageDirectory: packageDirectory,
            to: resolvedRegistration
        )
        try writeCustomRegistration(registration, replacing: nil)
        NotificationCenter.default.post(name: Self.sourcesDidChangeNotification, object: nil)
        return registration
    }

    /**
     Validates and replaces an existing custom source with a new HTTPS repository source.

     - Parameters:
       - originalName: Current custom source name in `InstallMgr.conf`.
       - rawURL: Replacement manifest URL or direct SWORD catalog URL.
       - packageDirectory: Optional user-edited SWORD package directory. Blank values preserve the
         directory discovered during validation.
     - Returns: Resolved replacement registration that was persisted.

     Side effects:
     - performs HTTPS requests for validation
     - rewrites `InstallMgr.conf` and/or the custom metadata sidecar
     - posts `sourcesDidChangeNotification` after a successful write

     - Throws: `RepositorySourceManagementError` for default-source replacement attempts,
       missing edit targets, validation, duplicate, or persistence failures.
     */
    @discardableResult
    public func replaceCustomSource(
        named originalName: String,
        with rawURL: String,
        packageDirectory: String? = nil
    ) async throws -> RepositorySourceRegistration {
        guard !InstallManager.isDefaultSourceName(originalName) else {
            throw RepositorySourceManagementError.protectedDefaultSource(originalName)
        }

        guard loadSources().contains(where: { $0.name == originalName && !isDefaultSource($0) }) else {
            throw RepositorySourceManagementError.sourceNotFound(originalName)
        }

        let resolvedRegistration = try await resolveCustomSource(from: rawURL)
        let registration = try Self.registration(
            byApplyingPackageDirectory: packageDirectory,
            to: resolvedRegistration
        )
        try writeCustomRegistration(registration, replacing: originalName)
        NotificationCenter.default.post(name: Self.sourcesDidChangeNotification, object: nil)
        return registration
    }

    /**
     Deletes a custom source from SWORD config and custom repository metadata.

     - Parameter name: Repository source name to delete.

     Side effects:
     - rewrites `InstallMgr.conf` without matching HTTP/FTP source rows when it can be read
     - removes matching custom metadata records, including sidecar-only MyBible rows when the
       SWORD config is unreadable
     - posts `sourcesDidChangeNotification` after a successful write

     - Throws: `RepositorySourceManagementError.protectedDefaultSource` for built-in sources or a
       config persistence error when a config-backed source cannot be read or written.
     */
    public func deleteCustomSource(named name: String) throws {
        guard !InstallManager.isDefaultSourceName(name) else {
            throw RepositorySourceManagementError.protectedDefaultSource(name)
        }

        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }
        try recoverInterruptedPersistenceIfNeeded()

        let customRecords = loadCustomRepositoryRecords()
        let matchingRecord = customRecords.first { $0.name == name }
        let updatedConfig: String?
        do {
            let content = try currentConfigContent()
            updatedConfig = Self.configContent(content, removing: name)
        } catch RepositorySourceManagementError.configReadFailed
            where matchingRecord?.type == SourceConfig.myBibleHTTPSRepositoryType {
            updatedConfig = nil
        }
        let updatedRecords = customRecords.filter { $0.name != name }
        try performJournaledPersistence {
            if let updatedConfig {
                try writeConfigUnjournaled(updatedConfig)
            }
            try writeCustomRepositoryRecordsUnjournaled(updatedRecords)
        }
        NotificationCenter.default.post(name: Self.sourcesDidChangeNotification, object: nil)
    }

    /**
     Replaces every custom repository source with a restored Android repository set.

     Android's `repositories.sqlite3` is a restore-only database: restoring it replaces the custom
     repository table instead of importing individual rows. iOS preserves that boundary by routing
     the restored rows through the same validation and persistence model as the Downloads source UI,
     then removing any previous custom source rows from `InstallMgr.conf` and
     `CustomRepositories.json`.

     - Parameter registrations: Validated Android custom repository registrations to persist.
     - Side effects:
       - rewrites non-default SWORD source rows in `InstallMgr.conf`
       - rewrites `CustomRepositories.json` with every restored custom repository
       - posts `sourcesDidChangeNotification` after a successful replace
     - Throws: `RepositorySourceManagementError` when restored rows are invalid, duplicate a
       built-in source, duplicate each other, or cannot be persisted.
     */
    public func replaceCustomSources(with registrations: [RepositorySourceRegistration]) throws {
        var seenNames = Set<String>()
        for registration in registrations {
            let source = registration.source
            try Self.validateSourceFields(source)
            guard !InstallManager.isDefaultSourceName(source.name) else {
                throw RepositorySourceManagementError.duplicateSourceName(source.name)
            }
            guard seenNames.insert(source.name).inserted else {
                throw RepositorySourceManagementError.duplicateSourceName(source.name)
            }
        }

        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }
        try recoverInterruptedPersistenceIfNeeded()

        var content = try Self.configContentRemovingCustomSourceLines(currentConfigContent())
        for registration in registrations where !registration.source.isMyBibleRepository {
            content = Self.configContent(
                content,
                inserting: Self.sourceLine(for: registration.source),
                replacing: nil
            )
        }
        try performJournaledPersistence {
            try writeConfigUnjournaled(content)
            try writeCustomRepositoryRecordsUnjournaled(
                registrations.map(CustomRepositoryRecord.init)
            )
        }
        NotificationCenter.default.post(name: Self.sourcesDidChangeNotification, object: nil)
    }

    /**
     Restores the source config to iOS's packaged Android-parity defaults.

     Side effects:
     - removes the existing `InstallMgr.conf`
     - removes custom repository metadata
     - recreates the default/beta source set through `InstallManager`
     - posts `sourcesDidChangeNotification` after recreation

     - Throws: `RepositorySourceManagementError.configWriteFailed` if the config cannot be removed
       or recreated.
     */
    public func resetToDefaults() throws {
        let defaultConfig = try generatedDefaultConfigContent()
        try performJournaledPersistence {
            try writeConfigUnjournaled(defaultConfig)
            try removePersistenceFileIfPresent(at: customRepositoriesURL)
        }

        NotificationCenter.default.post(name: Self.sourcesDidChangeNotification, object: nil)
    }

    /**
     Builds Android-parity default repository config away from the live persistence directory.

     - Returns: Validated default `InstallMgr.conf` text generated by `InstallManager`.
     - Side effects: Creates and removes one temporary directory.
     - Throws: `configWriteFailed` when defaults cannot be generated or read. Live repository files
       remain untouched.
     */
    private func generatedDefaultConfigContent() throws -> String {
        let temporaryBaseURL = fileManager.temporaryDirectory
            .appendingPathComponent("RepositoryDefaults-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: temporaryBaseURL, withIntermediateDirectories: true)
        } catch {
            throw RepositorySourceManagementError.configWriteFailed(
                "could not prepare default repository configuration: \(error.localizedDescription)"
            )
        }
        defer {
            if fileManager.fileExists(atPath: temporaryBaseURL.path) {
                try? fileManager.removeItem(at: temporaryBaseURL)
            }
        }
        InstallManager.ensureDefaultConfigPublic(at: temporaryBaseURL.path)
        let generatedURL = temporaryBaseURL.appendingPathComponent("InstallMgr.conf")
        do {
            return try String(contentsOf: generatedURL, encoding: .utf8)
        } catch {
            throw RepositorySourceManagementError.configWriteFailed(
                "default configuration was not recreated: \(error.localizedDescription)"
            )
        }
    }

    /**
     Resolves a user-entered URL into a custom repository registration without persisting it.

     - Parameter rawURL: HTTPS manifest URL or direct SWORD catalog URL.
     - Returns: Registration data suitable for source persistence and catalog refresh.

     Side effects:
     - performs HTTPS requests against the supplied URL and Android fallback URLs

     - Throws: `RepositorySourceManagementError` for invalid schemes, unsupported manifests, or
       unreadable direct catalogs.
     */
    public func resolveCustomSource(from rawURL: String) async throws -> RepositorySourceRegistration {
        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.host?.isEmpty == false else {
            throw RepositorySourceManagementError.invalidURL(trimmedURL)
        }
        guard url.scheme?.lowercased() == "https" else {
            throw RepositorySourceManagementError.httpsRequired
        }

        if let manifestRegistration = try await readManifestRegistration(at: url) {
            return manifestRegistration
        }

        let defaultManifestURL = url.appendingPathComponent("manifest.json")
        if let manifestRegistration = try await readManifestRegistration(at: defaultManifestURL) {
            return manifestRegistration
        }

        async let baseReadable = isReadable(url)
        async let packagesReadable = isReadable(url.appendingPathComponent("packages"))
        async let modsReadable = isReadable(url.appendingPathComponent("mods.d.tar.gz"))

        let directProbeResults = await (baseReadable, packagesReadable, modsReadable)
        guard directProbeResults.0 && directProbeResults.1 && directProbeResults.2 else {
            throw RepositorySourceManagementError.repositoryUnreachable(trimmedURL)
        }

        return try directSwordRegistration(for: url, originalURLString: trimmedURL)
    }

    /**
     Applies an explicit package-directory field after repository URL validation.

     Android's editor resolves repository metadata first and then lets the user edit
     `CustomRepository.packageDirectory`. Blank input retains the validated manifest/default value;
     a nonblank value replaces it for SWORD repositories and is rejected for MyBible manifests.

     - Parameters:
       - rawPackageDirectory: Optional editor field value.
       - registration: Validated repository registration.
     - Returns: Registration containing the normalized explicit package directory when supplied.
     - Side effects: none.
     - Throws: `RepositorySourceManagementError.invalidPackageDirectory` for URL-like, traversal,
       malformed, or non-SWORD overrides.
     */
    private static func registration(
        byApplyingPackageDirectory rawPackageDirectory: String?,
        to registration: RepositorySourceRegistration
    ) throws -> RepositorySourceRegistration {
        guard let rawPackageDirectory else { return registration }
        let trimmed = rawPackageDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return registration }
        guard registration.type == SourceConfig.swordHTTPSRepositoryType else {
            throw RepositorySourceManagementError.invalidPackageDirectory(trimmed)
        }
        let packageDirectory = try validatedPackageDirectory(trimmed)
        let source = SourceConfig(
            name: registration.source.name,
            type: registration.source.type,
            host: registration.source.host,
            catalogPath: registration.source.catalogPath,
            repositoryType: registration.source.repositoryType,
            description: registration.source.description,
            packageDirectory: packageDirectory,
            manifestURL: registration.source.manifestURL,
            sourceURL: registration.source.sourceURL
        )
        return RepositorySourceRegistration(
            source: source,
            description: registration.description,
            packageDirectory: packageDirectory,
            manifestURL: registration.manifestURL,
            sourceURL: registration.sourceURL,
            type: registration.type
        )
    }

    /**
     Validates and normalizes an editor-supplied SWORD package directory.

     - Parameter rawPath: Nonblank package directory field.
     - Returns: Absolute repository path with one leading slash.
     - Side effects: none.
     - Throws: `RepositorySourceManagementError.invalidPackageDirectory` when the value is a URL,
       contains query/fragment/config syntax, traversal components, or no usable path components.
     */
    private static func validatedPackageDirectory(_ rawPath: String) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("://"),
              !trimmed.contains("?"),
              !trimmed.contains("#"),
              !trimmed.contains("|"),
              !trimmed.contains("\\") else {
            throw RepositorySourceManagementError.invalidPackageDirectory(rawPath)
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw RepositorySourceManagementError.invalidPackageDirectory(rawPath)
        }
        return "/" + components.joined(separator: "/")
    }

    private struct ParsedSourceLine {
        let prefix: String
        let source: SourceConfig
    }

    private struct SwordHTTPSManifest: Decodable {
        let name: String
        let description: String?
        let type: String
        let host: String
        let catalogDirectory: String
        let packageDirectory: String?
        let manifestUrl: String?
    }

    /// Versioned sidecar file that preserves Android custom repository metadata beyond SWORD rows.
    private struct CustomRepositoryStore: Codable {
        /// Sidecar schema version for future migrations.
        var version: Int

        /// Persisted custom repositories in display/edit order.
        var repositories: [CustomRepositoryRecord]

        static let empty = CustomRepositoryStore(version: 1, repositories: [])
    }

    /// One persisted custom repository record used to round-trip edit/delete context.
    private struct CustomRepositoryRecord: Codable, Sendable {
        /// Repository display name and unique source key.
        var name: String

        /// User-visible manifest description.
        var description: String

        /// Android repository family, such as `sword-https` or `mybible-https`.
        var type: String

        /// Host and optional port used by the common `SourceConfig` model.
        var host: String

        /// SWORD catalog directory or MyBible manifest path.
        var catalogDirectory: String

        /// Optional Android package directory for SWORD package installs.
        var packageDirectory: String

        /// Manifest URL used to repopulate the edit field.
        var manifestURL: String

        /// Resolved source URL used by display and diagnostics.
        var sourceURL: String

        /// Rehydrates a stored record into the common Downloads source model.
        var source: SourceConfig {
            SourceConfig(
                name: name,
                type: "HTTP",
                host: host,
                catalogPath: catalogDirectory,
                repositoryType: type,
                description: description,
                packageDirectory: RepositorySourceManager.normalizedOptionalPackageDirectory(packageDirectory),
                manifestURL: URL(string: manifestURL),
                sourceURL: URL(string: sourceURL)
            )
        }

        /// Captures a resolved registration in the stable sidecar schema.
        init(registration: RepositorySourceRegistration) {
            self.name = registration.source.name
            self.description = registration.description
            self.type = registration.type
            self.host = registration.source.host
            self.catalogDirectory = registration.source.catalogPath
            self.packageDirectory = RepositorySourceManager.normalizedPackageDirectory(registration.packageDirectory)
            self.manifestURL = registration.manifestURL.absoluteString
            self.sourceURL = registration.sourceURL.absoluteString
        }
    }

    /// Result of loading `CustomRepositories.json` with enough state to make safe repair decisions.
    private struct CustomRepositoryRecordLoad {
        /// Valid records decoded from the sidecar, or an empty array when records are absent/unusable.
        let records: [CustomRepositoryRecord]

        /// Whether source-only SWORD backfills may be written without risking overwrite of unknown data.
        let canPersistBackfilledRecords: Bool
    }

    private func currentConfigContent() throws -> String {
        InstallManager.ensureDefaultConfigPublic(at: basePath)
        do {
            return try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            throw RepositorySourceManagementError.configReadFailed
        }
    }

    /**
     Loads sidecar custom repository records.

     - Returns: Persisted records that pass source validation, or an empty array when the sidecar
       is absent or unreadable.
     - Side effects: reads `CustomRepositories.json`.
     - Failure modes: malformed sidecars are treated as empty, and malformed records are dropped,
       so Downloads can still load built-in SWORD sources and valid sidecar-only repositories.
     */
    private func loadCustomRepositoryRecords() -> [CustomRepositoryRecord] {
        loadCustomRepositoryRecordStore().records
    }

    /**
     Loads sidecar records and records whether the sidecar is safe to rewrite with inferred data.

     Backfill persistence is safe when the sidecar is absent or successfully decodes, because the
     manager either owns a new file or can preserve every decoded valid record in deterministic
     order. When the file exists but cannot be read or decoded, the unreadable bytes may still
     contain recoverable custom/MyBible metadata, so load-only callers receive no records and
     source-only backfills stay in memory without replacing the sidecar.

     - Returns: Decoded valid records plus a flag controlling whether inferred legacy records can
       be persisted.
     - Side effects: reads `CustomRepositories.json` and checks whether the sidecar path exists.
     - Failure modes: unreadable or undecodable sidecars return no records and disallow backfill
       persistence; malformed decoded records are dropped while still allowing a clean rewrite.
     */
    private func loadCustomRepositoryRecordStore() -> CustomRepositoryRecordLoad {
        let sidecarExists = fileManager.fileExists(atPath: customRepositoriesURL.path)
        guard let data = fileManager.contents(atPath: customRepositoriesURL.path) else {
            return CustomRepositoryRecordLoad(
                records: [],
                canPersistBackfilledRecords: !sidecarExists
            )
        }
        guard let records = try? JSONDecoder().decode(CustomRepositoryStore.self, from: data).repositories else {
            return CustomRepositoryRecordLoad(records: [], canPersistBackfilledRecords: false)
        }
        return CustomRepositoryRecordLoad(
            records: records.filter(Self.isValidCustomRepositoryRecord),
            canPersistBackfilledRecords: true
        )
    }

    /**
     Validates one decoded sidecar record before it can participate in source loading or mutation.

     - Parameter record: Record decoded from `CustomRepositories.json`.
     - Returns: `true` when the repository family is supported and the reconstructed source passes
       the same persistence safety checks used for newly resolved custom repositories.
     - Side effects: none.
     - Failure modes: validation failures are converted to `false` so a bad record cannot poison
       the entire sidecar.
     */
    private static func isValidCustomRepositoryRecord(_ record: CustomRepositoryRecord) -> Bool {
        guard record.type == SourceConfig.swordHTTPSRepositoryType
                || record.type == SourceConfig.myBibleHTTPSRepositoryType else {
            return false
        }
        do {
            try validateSourceFields(record.source)
            return true
        } catch {
            return false
        }
    }

    /**
     Writes the complete custom repository sidecar.

     - Parameter records: Records to persist in deterministic array order.
     - Side effects: creates the source-config directory and atomically writes
       `CustomRepositories.json`.
     - Throws: `RepositorySourceManagementError.configWriteFailed` for encoding or file-system
       failures.
     */
    private func writeCustomRepositoryRecordsUnjournaled(
        _ records: [CustomRepositoryRecord]
    ) throws {
        if records.isEmpty {
            try removePersistenceFileIfPresent(at: customRepositoriesURL)
            return
        }
        let store = CustomRepositoryStore(version: 1, repositories: records)
        do {
            try fileManager.createDirectory(
                at: customRepositoriesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(store)
            try persistence.write(data, customRepositoriesURL)
        } catch {
            throw RepositorySourceManagementError.configWriteFailed(error.localizedDescription)
        }
    }

    /**
     Persists a resolved custom repository registration across SWORD config and sidecar storage.

     - Parameters:
       - registration: Validated custom repository metadata to persist.
       - originalName: Existing repository name to replace, or `nil` when adding a new source.
     - Side effects: rewrites `InstallMgr.conf` and `CustomRepositories.json` as needed.
     - Throws: `RepositorySourceManagementError` when the visible edit target is missing, a
       visible source name conflicts, source fields are invalid, or either backing store cannot be
       written.
     - Note: Replacements keep the original sidecar index so display/edit ordering remains stable.
       Orphaned SWORD sidecar metadata is ignored for duplicate checks because `loadSources()`
       cannot surface it without the matching `InstallMgr.conf` row.
       Sidecar-only MyBible registrations can still be written when `InstallMgr.conf` is unreadable
       because SWORD does not consume those rows.
     */
    private func writeCustomRegistration(
        _ registration: RepositorySourceRegistration,
        replacing originalName: String?
    ) throws {
        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }
        try recoverInterruptedPersistenceIfNeeded()

        let source = registration.source
        let customRecords = loadCustomRepositoryRecords()
        let content: String?
        do {
            content = try currentConfigContent()
        } catch RepositorySourceManagementError.configReadFailed where source.isMyBibleRepository {
            content = nil
        }
        let sourceLines = content.map { Self.sourceLines(in: $0) } ?? []
        let sourceNamesInConfig = Set(sourceLines.map(\.source.name))
        let visibleCustomRecords = customRecords.filter {
            $0.type == SourceConfig.myBibleHTTPSRepositoryType || sourceNamesInConfig.contains($0.name)
        }

        if let originalName,
           !sourceLines.contains(where: { $0.source.name == originalName })
            && !visibleCustomRecords.contains(where: { $0.name == originalName })
        {
            throw RepositorySourceManagementError.sourceNotFound(originalName)
        }

        try Self.validateSourceFields(source)

        if InstallManager.isDefaultSourceName(source.name), source.name != originalName {
            throw RepositorySourceManagementError.duplicateSourceName(source.name)
        }

        let existingNames = Set(
            (sourceLines.map(\.source.name) + visibleCustomRecords.map(\.name))
                .filter { $0 != originalName }
        )

        guard !existingNames.contains(source.name) else {
            throw RepositorySourceManagementError.duplicateSourceName(source.name)
        }

        let updatedConfig: String?
        if let content {
            if source.isMyBibleRepository {
                updatedConfig = Self.configContent(content, removing: originalName)
            } else if let originalName,
                      sourceLines.contains(where: { $0.source.name == originalName }) {
                let sourceLine = Self.sourceLine(for: source)
                updatedConfig = Self.configContent(
                    content,
                    inserting: sourceLine,
                    replacing: originalName
                )
            } else {
                let sourceLine = Self.sourceLine(for: source)
                updatedConfig = Self.configContent(
                    Self.configContent(content, removing: originalName),
                    inserting: sourceLine,
                    replacing: nil
                )
            }
        } else {
            updatedConfig = nil
        }

        let replacementRecord = CustomRepositoryRecord(registration: registration)
        var updatedRecords: [CustomRepositoryRecord] = []
        var didReplaceRecord = false
        for record in customRecords {
            if let originalName, record.name == originalName {
                if !didReplaceRecord {
                    updatedRecords.append(replacementRecord)
                    didReplaceRecord = true
                }
            } else if record.name == source.name {
                if originalName == nil && !didReplaceRecord {
                    updatedRecords.append(replacementRecord)
                    didReplaceRecord = true
                }
            } else {
                updatedRecords.append(record)
            }
        }
        if !didReplaceRecord {
            updatedRecords.append(replacementRecord)
        }
        try performJournaledPersistence {
            if let updatedConfig {
                try writeConfigUnjournaled(updatedConfig)
            }
            try writeCustomRepositoryRecordsUnjournaled(updatedRecords)
        }
    }

    private func writeConfigUnjournaled(_ content: String) throws {
        var normalized = content
        if !normalized.hasSuffix("\n") {
            normalized += "\n"
        }

        do {
            try fileManager.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try persistence.write(Data(normalized.utf8), configURL)
        } catch {
            throw RepositorySourceManagementError.configWriteFailed(error.localizedDescription)
        }
    }

    /**
     Commits repository config and sidecar mutations behind one durable rollback journal.

     The journal contains byte-exact preimages for both files and is atomically durable before the
     first destination write. Any synchronous failure restores both preimages. A process death leaves
     the journal in place, and the next load or mutation restores the same preimages before exposing
     repository state.

     - Parameter mutation: Writes/removals that together form one logical repository transaction.
     - Side effects: Creates and removes `RepositorySources.transaction.json`, serializes mutations
       across manager instances, and may restore both persistence files after failure.
     - Throws: The original repository error after successful rollback, or `configWriteFailed` when
       journaling or rollback itself cannot complete. A failed rollback deliberately retains the
       journal for the next recovery attempt.
     */
    private func performJournaledPersistence(_ mutation: () throws -> Void) throws {
        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }

        try recoverInterruptedPersistenceIfNeeded()
        let journal = RepositorySourcePersistenceJournal(
            config: try snapshot(of: configURL),
            customRepositories: try snapshot(of: customRepositoriesURL)
        )
        do {
            try fileManager.createDirectory(
                at: persistenceJournalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try persistence.write(try JSONEncoder().encode(journal), persistenceJournalURL)
        } catch {
            throw RepositorySourceManagementError.configWriteFailed(error.localizedDescription)
        }

        do {
            try mutation()
            try removePersistenceFileIfPresent(at: persistenceJournalURL)
        } catch {
            let originalError = error
            do {
                try restore(journal.config, to: configURL)
                try restore(journal.customRepositories, to: customRepositoriesURL)
                try removePersistenceFileIfPresent(at: persistenceJournalURL)
            } catch {
                throw RepositorySourceManagementError.configWriteFailed(
                    "\(originalError.localizedDescription); rollback failed: \(error.localizedDescription)"
                )
            }
            if let repositoryError = originalError as? RepositorySourceManagementError {
                throw repositoryError
            }
            throw RepositorySourceManagementError.configWriteFailed(
                originalError.localizedDescription
            )
        }
    }

    /**
     Restores an interrupted repository transaction before any persisted state is read or changed.

     - Side effects: Replaces both repository files with journaled preimages and removes the journal
       only after both restores succeed.
     - Throws: `configWriteFailed` for unreadable journals or failed restores. The journal is retained
       after failure so a later attempt can retry recovery.
     */
    private func recoverInterruptedPersistenceIfNeeded() throws {
        guard fileManager.fileExists(atPath: persistenceJournalURL.path) else { return }
        do {
            let data = try Data(contentsOf: persistenceJournalURL)
            let journal = try JSONDecoder().decode(
                RepositorySourcePersistenceJournal.self,
                from: data
            )
            try restore(journal.config, to: configURL)
            try restore(journal.customRepositories, to: customRepositoriesURL)
            try removePersistenceFileIfPresent(at: persistenceJournalURL)
        } catch {
            throw RepositorySourceManagementError.configWriteFailed(
                "could not recover interrupted repository transaction: \(error.localizedDescription)"
            )
        }
    }

    /** Captures one persistence target as a byte-exact file or directory-shape preimage. */
    private func snapshot(of url: URL) throws -> RepositorySourceFileSnapshot {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return RepositorySourceFileSnapshot(kind: .missing, data: nil)
        }
        guard !isDirectory.boolValue else {
            return RepositorySourceFileSnapshot(kind: .directory, data: nil)
        }
        do {
            return RepositorySourceFileSnapshot(kind: .regularFile, data: try Data(contentsOf: url))
        } catch {
            throw RepositorySourceManagementError.configWriteFailed(
                "could not snapshot \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    /** Restores one journaled persistence target to its previous file-system shape and bytes. */
    private func restore(_ snapshot: RepositorySourceFileSnapshot, to url: URL) throws {
        switch snapshot.kind {
        case .missing:
            try removePersistenceFileIfPresent(at: url)
        case .directory:
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue else { return }
                try removePersistenceFileIfPresent(at: url)
            }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        case .regularFile:
            guard let data = snapshot.data else {
                throw RepositorySourceManagementError.configWriteFailed(
                    "transaction journal omitted \(url.lastPathComponent) bytes"
                )
            }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                try removePersistenceFileIfPresent(at: url)
            }
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try persistence.write(data, url)
        }
    }

    /** Removes one persistence file when present and translates file-system failures. */
    private func removePersistenceFileIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try persistence.remove(url)
        } catch {
            throw RepositorySourceManagementError.configWriteFailed(error.localizedDescription)
        }
    }

    private func readManifestRegistration(at url: URL) async throws -> RepositorySourceRegistration? {
        guard let data = await readHTTP200Data(from: url) else {
            return nil
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let type = jsonObject["type"] as? String {
            do {
                if type == SourceConfig.myBibleHTTPSRepositoryType {
                    let manifest = try JSONDecoder().decode(MyBibleRepositoryManifest.self, from: data)
                    return try registration(from: manifest, manifestURL: url)
                }
                guard type == SourceConfig.swordHTTPSRepositoryType else {
                    throw RepositorySourceManagementError.unsupportedRepositoryType(type)
                }
                let manifest = try JSONDecoder().decode(SwordHTTPSManifest.self, from: data)
                return try registration(from: manifest, manifestURL: url)
            } catch let error as RepositorySourceManagementError {
                throw error
            } catch {
                throw RepositorySourceManagementError.invalidManifest(error.localizedDescription)
            }
        }

        if jsonObject["file_name"] != nil && jsonObject["url"] != nil {
            do {
                let manifest = try JSONDecoder().decode(MyBibleRepositoryManifest.self, from: data)
                return try registration(from: manifest, manifestURL: url)
            } catch let error as RepositorySourceManagementError {
                throw error
            } catch {
                throw RepositorySourceManagementError.invalidManifest(error.localizedDescription)
            }
        }

        return nil
    }

    private func readHTTP200Data(from url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private func isReadable(_ url: URL) async -> Bool {
        await readHTTP200Data(from: url) != nil
    }

    private func registration(
        from manifest: SwordHTTPSManifest,
        manifestURL: URL
    ) throws -> RepositorySourceRegistration {
        guard manifest.type == "sword-https" else {
            throw RepositorySourceManagementError.unsupportedRepositoryType(manifest.type)
        }

        let source = try Self.source(
            name: manifest.name,
            host: manifest.host,
            catalogDirectory: manifest.catalogDirectory
        )
        let packageDirectory = Self.normalizedOptionalPackageDirectory(manifest.packageDirectory ?? "")
            ?? Self.normalizedPackageDirectory(Self.appendingPathComponent(
                "packages",
                toPath: source.catalogPath
            ))
        let sourceURL = try Self.httpsURL(host: source.host, path: source.catalogPath)
        let reportedManifestURL = Self.preferredHTTPSManifestURL(
            from: manifest.manifestUrl,
            fallback: manifestURL
        )

        return RepositorySourceRegistration(
            source: source,
            description: manifest.description ?? manifest.name,
            packageDirectory: packageDirectory,
            manifestURL: reportedManifestURL,
            sourceURL: sourceURL,
            type: manifest.type
        )
    }

    private func registration(
        from manifest: MyBibleRepositoryManifest,
        manifestURL: URL
    ) throws -> RepositorySourceRegistration {
        let reportedManifestURL = try Self.httpsURL(from: manifest.url, fallback: manifestURL)
        let host = Self.hostAndPort(for: reportedManifestURL) ?? reportedManifestURL.host ?? ""
        let source = SourceConfig(
            name: manifest.fileName.trimmingCharacters(in: .whitespacesAndNewlines),
            type: "HTTP",
            host: host,
            catalogPath: Self.normalizedCatalogDirectory(reportedManifestURL.path),
            repositoryType: SourceConfig.myBibleHTTPSRepositoryType,
            description: manifest.description,
            packageDirectory: nil,
            manifestURL: reportedManifestURL,
            sourceURL: reportedManifestURL
        )
        try Self.validateSourceFields(source)

        return RepositorySourceRegistration(
            source: source,
            description: manifest.description,
            packageDirectory: "",
            manifestURL: reportedManifestURL,
            sourceURL: reportedManifestURL,
            type: SourceConfig.myBibleHTTPSRepositoryType
        )
    }

    private func directSwordRegistration(
        for url: URL,
        originalURLString: String
    ) throws -> RepositorySourceRegistration {
        let displayHost = url.host ?? ""
        let host = Self.hostAndPort(for: url) ?? displayHost
        let catalogDirectory = Self.normalizedCatalogDirectory(url.path)
        let source = try Self.source(
            name: "\(displayHost)-\(Self.androidHashPrefix(for: originalURLString))",
            host: host,
            catalogDirectory: catalogDirectory
        )

        return RepositorySourceRegistration(
            source: source,
            description: originalURLString,
            packageDirectory: Self.appendingPathComponent("packages", toPath: source.catalogPath),
            manifestURL: url,
            sourceURL: url,
            type: "sword-https"
        )
    }

    private static func source(name: String, host: String, catalogDirectory: String) throws -> SourceConfig {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = normalizedHost(host)
        let normalizedPath = normalizedCatalogDirectory(catalogDirectory)

        let source = SourceConfig(
            name: trimmedName,
            type: "HTTP",
            host: normalizedHost,
            catalogPath: normalizedPath
        )
        try validateConfigFields(source)
        return source
    }

    private static func normalizedHost(_ rawHost: String) -> String {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil {
            return hostAndPort(for: url) ?? trimmed
        }
        return trimmed
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func hostAndPort(for url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else {
            return nil
        }

        let normalizedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        if let port = url.port {
            return "\(normalizedHost):\(port)"
        }
        return normalizedHost
    }

    private static func normalizedCatalogDirectory(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    private static func normalizedPackageDirectory(_ rawPath: String) -> String {
        normalizedCatalogDirectory(rawPath)
    }

    private static func normalizedOptionalPackageDirectory(_ rawPath: String) -> String? {
        let normalized = normalizedPackageDirectory(rawPath)
        return normalized.isEmpty ? nil : normalized
    }

    /**
     Validates one source model before it can be persisted or used as a catalog cache key.

     Source names are used as catalog-cache filenames, so the name must not contain path
     separators that could escape the intended cache directory during a later refresh. Persisted
     manifest URLs must be HTTPS because edit flows reuse them as user-entered repository URLs;
     MyBible sources additionally require a manifest URL because their catalog is the manifest.
     Free-form metadata such as descriptions is stored in JSON and is not constrained by
     `InstallMgr.conf` separators.

     - Parameter source: Normalized source row candidate.
     - Throws: `RepositorySourceManagementError.invalidManifest` when a field is missing or
       source identity contains config/file-path syntax that cannot be safely persisted;
       `httpsRequired` when persisted manifest metadata is not HTTPS or a MyBible source lacks a
       manifest URL.
     */
    private static func validateSourceFields(_ source: SourceConfig) throws {
        try validateConfigFields(source)
        guard !source.repositoryType.isEmpty,
              !containsConfigSeparator(source.repositoryType) else {
            throw RepositorySourceManagementError.invalidManifest(source.name)
        }
        if let manifestURL = source.manifestURL {
            guard manifestURL.scheme?.lowercased() == "https",
                  manifestURL.host?.isEmpty == false else {
                throw RepositorySourceManagementError.httpsRequired
            }
        } else if source.isMyBibleRepository {
            throw RepositorySourceManagementError.httpsRequired
        }
    }

    private static func validateConfigFields(_ source: SourceConfig) throws {
        guard source.type == "HTTP",
              !source.name.isEmpty,
              !source.host.isEmpty,
              !containsConfigSeparator(source.name),
              !containsPathSeparator(source.name),
              !containsConfigSeparator(source.host),
              !containsConfigSeparator(source.catalogPath) else {
            throw RepositorySourceManagementError.invalidManifest(source.name)
        }
    }

    private static func containsConfigSeparator(_ value: String) -> Bool {
        value.contains("|") || value.contains("\n") || value.contains("\r")
    }

    /**
     Returns whether a source name contains directory separators unsafe for cache filenames.

     - Parameter value: Source name candidate from a manifest or direct-catalog fallback.
     - Returns: `true` when the value could address a nested or parent directory as a filename.
     */
    private static func containsPathSeparator(_ value: String) -> Bool {
        value.contains("/") || value.contains("\\")
    }

    private static func httpsURL(host: String, path: String) throws -> URL {
        guard let url = URL(string: "https://\(host)\(path)") else {
            throw RepositorySourceManagementError.invalidURL("https://\(host)\(path)")
        }
        return url
    }

    /**
     Returns safe edit metadata from an optional SWORD manifest self-reference.

     SWORD manifests can include `manifestUrl` as descriptive metadata. The app only accepts HTTPS
     custom repository URLs, so non-HTTPS or malformed self-references are ignored and the HTTPS URL
     that was actually fetched is retained instead.

     - Parameters:
       - rawValue: Optional `manifestUrl` field from the decoded SWORD manifest.
       - fallback: HTTPS manifest URL used to fetch the manifest.
     - Returns: The HTTPS self-reference when valid, otherwise `fallback`.
     - Side effects: none.
     - Failure modes: malformed or non-HTTPS metadata is treated as absent.
     */
    private static func preferredHTTPSManifestURL(from rawValue: String?, fallback: URL) -> URL {
        guard let rawValue else {
            return fallback
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate = URL(string: trimmed),
              candidate.scheme?.lowercased() == "https",
              candidate.host?.isEmpty == false else {
            return fallback
        }
        return candidate
    }

    private static func httpsURL(from rawValue: String, fallback: URL) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = URL(string: trimmed) ?? fallback
        guard candidate.scheme?.lowercased() == "https",
              candidate.host?.isEmpty == false else {
            throw RepositorySourceManagementError.httpsRequired
        }
        return candidate
    }

    private static func sourceLines(in content: String) -> [ParsedSourceLine] {
        content.components(separatedBy: .newlines).compactMap(Self.parseSourceLine)
    }

    private static func parseSourceLine(_ line: String) -> ParsedSourceLine? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix: String
        let type: String
        if trimmed.hasPrefix("HTTPSource=") {
            prefix = "HTTPSource"
            type = "HTTP"
        } else if trimmed.hasPrefix("FTPSource=") {
            prefix = "FTPSource"
            type = "FTP"
        } else {
            return nil
        }

        let value = String(trimmed.dropFirst("\(prefix)=".count))
        let parts = value.components(separatedBy: "|")
        guard parts.count >= 3 else { return nil }

        return ParsedSourceLine(
            prefix: prefix,
            source: SourceConfig(
                name: parts[0],
                type: type,
                host: parts[1],
                catalogPath: parts[2]
            )
        )
    }

    private static func sourceLine(for source: SourceConfig) -> String {
        "HTTPSource=\(source.name)|\(source.host)|\(source.catalogPath)"
    }

    private static func configContent(
        _ content: String,
        inserting sourceLine: String,
        replacing originalName: String?
    ) -> String {
        var lines = content.components(separatedBy: .newlines)

        if let originalName {
            var insertedReplacement = false
            lines = lines.compactMap { line in
                guard let parsed = parseSourceLine(line),
                      parsed.source.name == originalName else {
                    return line
                }
                if insertedReplacement {
                    return nil
                }
                insertedReplacement = true
                return sourceLine
            }

            if insertedReplacement {
                return lines.joined(separator: "\n")
            }
        }

        let sourcesIndex = lines.firstIndex {
            $0.trimmingCharacters(in: .whitespaces) == "[Sources]"
        }

        var insertionIndex = lines.endIndex
        if let sourcesIndex {
            insertionIndex = lines[lines.index(after: sourcesIndex)...]
                .firstIndex { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
                } ?? lines.endIndex
        }

        if insertionIndex == lines.endIndex, lines.last == "" {
            insertionIndex = lines.index(before: lines.endIndex)
        }

        lines.insert(sourceLine, at: insertionIndex)
        return lines.joined(separator: "\n")
    }

    private static func configContent(_ content: String, removing sourceName: String?) -> String {
        guard let sourceName else { return content }
        let lines = content.components(separatedBy: .newlines)
        let updatedLines = lines.filter { line in
            guard let parsed = parseSourceLine(line) else { return true }
            return parsed.source.name != sourceName
        }
        return updatedLines.joined(separator: "\n")
    }

    private static func configContentRemovingCustomSourceLines(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        let updatedLines = lines.filter { line in
            guard let parsed = parseSourceLine(line) else { return true }
            return InstallManager.isDefaultSourceName(parsed.source.name)
        }
        return updatedLines.joined(separator: "\n")
    }

    private static func appendingPathComponent(_ component: String, toPath path: String) -> String {
        var base = path
        if base.isEmpty {
            base = "/"
        }
        if base.hasSuffix("/") {
            return "\(base)\(component)"
        }
        return "\(base)/\(component)"
    }

    private static func androidHashPrefix(for value: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(value.utf8))
        return digest
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(3)
            .description
    }
}
