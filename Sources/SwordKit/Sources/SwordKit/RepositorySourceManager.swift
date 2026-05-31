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
 Owns custom repository validation and source persistence for the Downloads source UI.

 The manager intentionally follows Android's `CustomRepositoryEditor` sequence: require HTTPS,
 try the supplied URL as a manifest, try `manifest.json`, then fall back to probing a direct
 SWORD catalog containing the base URL, `packages`, and `mods.d.tar.gz`. SWORD custom sources
 are written to `InstallMgr.conf` because SWORD consumes that file directly. Android-compatible
 MyBible sources are persisted in `CustomRepositories.json` because they are not SWORD sources
 but still need stable edit/delete metadata and Downloads catalog refresh support.

 - Important: This type is `@unchecked Sendable` because it stores `URLSession` and
   `FileManager`; callers should treat it as a small service object and serialize UI-driven
   mutations from the main actor.
 */
public final class RepositorySourceManager: @unchecked Sendable {
    /// Posted after add, replace, delete, or reset actions successfully rewrite source configuration.
    public static let sourcesDidChangeNotification = Notification.Name(
        "org.andbible.RepositorySourceManager.sourcesDidChange"
    )

    private let basePath: String
    private let session: URLSession
    private let fileManager: FileManager

    private var configURL: URL {
        URL(fileURLWithPath: basePath, isDirectory: true)
            .appendingPathComponent("InstallMgr.conf")
    }

    private var customRepositoriesURL: URL {
        URL(fileURLWithPath: basePath, isDirectory: true)
            .appendingPathComponent("CustomRepositories.json")
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
    public init(basePath: String? = nil, session: URLSession? = nil, fileManager: FileManager = .default) {
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
    }

    /**
     Loads configured repository sources from SWORD config and custom repository metadata.

     SWORD rows are read from `InstallMgr.conf` and enriched from the custom metadata sidecar
     when available. MyBible rows live only in the sidecar and are appended after config-backed
     sources, matching Android's built-in-then-custom source ordering.

     - Returns: Source rows in persisted SWORD order followed by non-SWORD custom rows. If the
       SWORD config cannot be read, sidecar-only MyBible rows are still returned in sidecar order.

     Side effects:
     - creates or migrates default repository configuration through `InstallManager`.

     Failure modes:
     - omits config-backed SWORD rows if the SWORD config file cannot be read
     - ignores malformed custom metadata records instead of failing all Downloads sources
     */
    public func loadSources() -> [SourceConfig] {
        InstallManager.ensureDefaultConfigPublic(at: basePath)
        let customRecords = loadCustomRepositoryRecords()

        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return customRecords
                .filter { $0.type == SourceConfig.myBibleHTTPSRepositoryType }
                .map(\.source)
        }

        let persistedSources = Self.sourceLines(in: content).map(\.source)
        let recordsByName = Dictionary(customRecords.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        var namesInConfig: Set<String> = []
        let configSources = persistedSources.map { source in
            namesInConfig.insert(source.name)
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
                packageDirectory: record.packageDirectory.isEmpty ? nil : record.packageDirectory,
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

     - Parameter rawURL: User-entered manifest URL or direct SWORD catalog URL.
     - Returns: Resolved repository registration that was persisted.

     Side effects:
     - performs HTTPS requests for manifest/direct-catalog validation
     - appends an `HTTPSource` row for SWORD repositories, or writes a MyBible metadata record
     - posts `sourcesDidChangeNotification` after a successful write

     - Throws: `RepositorySourceManagementError` for validation, duplicate, or persistence failures.
     */
    @discardableResult
    public func addCustomSource(from rawURL: String) async throws -> RepositorySourceRegistration {
        let registration = try await resolveCustomSource(from: rawURL)
        try writeCustomRegistration(registration, replacing: nil)
        NotificationCenter.default.post(name: Self.sourcesDidChangeNotification, object: nil)
        return registration
    }

    /**
     Validates and replaces an existing custom source with a new HTTPS repository source.

     - Parameters:
       - originalName: Current custom source name in `InstallMgr.conf`.
       - rawURL: Replacement manifest URL or direct SWORD catalog URL.
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
        with rawURL: String
    ) async throws -> RepositorySourceRegistration {
        guard !InstallManager.isDefaultSourceName(originalName) else {
            throw RepositorySourceManagementError.protectedDefaultSource(originalName)
        }

        guard loadSources().contains(where: { $0.name == originalName && !isDefaultSource($0) }) else {
            throw RepositorySourceManagementError.sourceNotFound(originalName)
        }

        let registration = try await resolveCustomSource(from: rawURL)
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

        let customRecords = loadCustomRepositoryRecords()
        let matchingRecord = customRecords.first { $0.name == name }
        do {
            let content = try currentConfigContent()
            try writeConfig(Self.configContent(content, removing: name))
        } catch RepositorySourceManagementError.configReadFailed
            where matchingRecord?.type == SourceConfig.myBibleHTTPSRepositoryType {
        }
        try removeCustomRepositoryRecord(named: name)
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
        if fileManager.fileExists(atPath: configURL.path) {
            do {
                try fileManager.removeItem(at: configURL)
            } catch {
                throw RepositorySourceManagementError.configWriteFailed(error.localizedDescription)
            }
        }
        if fileManager.fileExists(atPath: customRepositoriesURL.path) {
            do {
                try fileManager.removeItem(at: customRepositoriesURL)
            } catch {
                throw RepositorySourceManagementError.configWriteFailed(error.localizedDescription)
            }
        }

        InstallManager.ensureDefaultConfigPublic(at: basePath)
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw RepositorySourceManagementError.configWriteFailed("default configuration was not recreated")
        }

        NotificationCenter.default.post(name: Self.sourcesDidChangeNotification, object: nil)
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

        /// Optional Android package directory for SWORD package fallback.
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
                packageDirectory: packageDirectory.isEmpty ? nil : packageDirectory,
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
            self.packageDirectory = registration.packageDirectory
            self.manifestURL = registration.manifestURL.absoluteString
            self.sourceURL = registration.sourceURL.absoluteString
        }
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

     - Returns: Persisted records, or an empty array when the sidecar is absent or unreadable.
     - Side effects: reads `CustomRepositories.json`.
     - Failure modes: malformed sidecars are treated as empty so Downloads can still load built-in
       SWORD sources.
     */
    private func loadCustomRepositoryRecords() -> [CustomRepositoryRecord] {
        guard let data = fileManager.contents(atPath: customRepositoriesURL.path) else {
            return []
        }
        return (try? JSONDecoder().decode(CustomRepositoryStore.self, from: data).repositories) ?? []
    }

    /**
     Writes the complete custom repository sidecar.

     - Parameter records: Records to persist in deterministic array order.
     - Side effects: creates the source-config directory and atomically writes
       `CustomRepositories.json`.
     - Throws: `RepositorySourceManagementError.configWriteFailed` for encoding or file-system
       failures.
     */
    private func writeCustomRepositoryRecords(_ records: [CustomRepositoryRecord]) throws {
        let store = CustomRepositoryStore(version: 1, repositories: records)
        do {
            try fileManager.createDirectory(
                at: customRepositoriesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(store)
            try data.write(to: customRepositoriesURL, options: .atomic)
        } catch {
            throw RepositorySourceManagementError.configWriteFailed(error.localizedDescription)
        }
    }

    /**
     Removes one custom repository sidecar record.

     - Parameter name: Repository name to remove.
     - Side effects: rewrites or deletes `CustomRepositories.json`.
     - Throws: `RepositorySourceManagementError.configWriteFailed` when the sidecar cannot be
       updated.
     */
    private func removeCustomRepositoryRecord(named name: String) throws {
        let records = loadCustomRepositoryRecords()
        let updatedRecords = records.filter { $0.name != name }
        if updatedRecords.isEmpty {
            if fileManager.fileExists(atPath: customRepositoriesURL.path) {
                do {
                    try fileManager.removeItem(at: customRepositoriesURL)
                } catch {
                    throw RepositorySourceManagementError.configWriteFailed(error.localizedDescription)
                }
            }
        } else if updatedRecords.count != records.count {
            try writeCustomRepositoryRecords(updatedRecords)
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
     */
    private func writeCustomRegistration(
        _ registration: RepositorySourceRegistration,
        replacing originalName: String?
    ) throws {
        let source = registration.source
        let content = try currentConfigContent()
        let sourceLines = Self.sourceLines(in: content)
        let customRecords = loadCustomRepositoryRecords()
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

        let existingNames = Set(
            (sourceLines.map(\.source.name) + visibleCustomRecords.map(\.name))
                .filter { $0 != originalName }
        )

        guard !existingNames.contains(source.name) else {
            throw RepositorySourceManagementError.duplicateSourceName(source.name)
        }

        let updated: String
        if source.isMyBibleRepository {
            updated = Self.configContent(content, removing: originalName)
        } else if let originalName,
                  sourceLines.contains(where: { $0.source.name == originalName }) {
            let sourceLine = Self.sourceLine(for: source)
            updated = Self.configContent(content, inserting: sourceLine, replacing: originalName)
        } else {
            let sourceLine = Self.sourceLine(for: source)
            updated = Self.configContent(
                Self.configContent(content, removing: originalName),
                inserting: sourceLine,
                replacing: nil
            )
        }
        try writeConfig(updated)

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
        try writeCustomRepositoryRecords(updatedRecords)
    }

    private func writeConfig(_ content: String) throws {
        var normalized = content
        if !normalized.hasSuffix("\n") {
            normalized += "\n"
        }

        do {
            try normalized.write(to: configURL, atomically: true, encoding: .utf8)
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
        let packageDirectory = manifest.packageDirectory ?? Self.appendingPathComponent(
            "packages",
            toPath: source.catalogPath
        )
        let sourceURL = try Self.httpsURL(host: source.host, path: source.catalogPath)
        let reportedManifestURL = manifest.manifestUrl.flatMap(URL.init(string:)) ?? manifestURL

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

    /**
     Validates one source model before it can be persisted or used as a catalog cache key.

     Source names are used as catalog-cache filenames, so the name must not contain path
     separators that could escape the intended cache directory during a later refresh. MyBible
     sources additionally require an HTTPS manifest URL because their catalog is the manifest.
     Free-form metadata such as descriptions is stored in JSON and is not constrained by
     `InstallMgr.conf` separators.

     - Parameter source: Normalized source row candidate.
     - Throws: `RepositorySourceManagementError.invalidManifest` when a field is missing or
       source identity contains config/file-path syntax that cannot be safely persisted;
       `httpsRequired` when a MyBible source lacks an HTTPS manifest.
     */
    private static func validateSourceFields(_ source: SourceConfig) throws {
        try validateConfigFields(source)
        guard !source.repositoryType.isEmpty,
              !containsConfigSeparator(source.repositoryType) else {
            throw RepositorySourceManagementError.invalidManifest(source.name)
        }
        if source.isMyBibleRepository {
            guard source.manifestURL?.scheme?.lowercased() == "https" else {
                throw RepositorySourceManagementError.httpsRequired
            }
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
