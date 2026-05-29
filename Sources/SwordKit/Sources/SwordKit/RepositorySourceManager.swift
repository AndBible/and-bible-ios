// RepositorySourceManager.swift — Android-parity custom repository source management

import CryptoKit
import Foundation

/**
 Resolved custom repository data that can be persisted into the iOS SWORD source config.

 The registration mirrors Android's `CustomRepository` validation result closely enough for
 iOS's current SWORD catalog pipeline: the visible repository identity, catalog host/path, and
 source URL are preserved, while package-directory metadata is retained for diagnostics even
 though `InstallMgr.conf` cannot store it.
 */
public struct RepositorySourceRegistration: Sendable {
    /// Source row that will be written to `InstallMgr.conf`.
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
 input, an unreadable SWORD catalog, duplicate repository names, unsupported repository types,
 protected default-source deletion, or local config read/write failures.
 */
public enum RepositorySourceManagementError: Error, Equatable, LocalizedError, Sendable {
    /// The input string could not be parsed as an absolute URL.
    case invalidURL(String)

    /// Android accepts only `https://` custom repository URLs; iOS follows the same rule.
    case httpsRequired

    /// The URL and Android direct-catalog fallback probes did not return readable HTTPS resources.
    case repositoryUnreachable(String)

    /// A manifest was present but did not contain enough SWORD repository data for iOS to persist.
    case invalidManifest(String)

    /// The manifest describes a repository family iOS cannot consume through the SWORD catalog pipeline yet.
    case unsupportedRepositoryType(String)

    /// The resolved repository name already exists in default, beta, or custom source configuration.
    case duplicateSourceName(String)

    /// Default Android repositories are built-in and cannot be deleted from the custom-source UI.
    case protectedDefaultSource(String)

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
            return "Could not read a SWORD repository at \(value)."
        case .invalidManifest(let value):
            return "The repository manifest is not valid for iOS SWORD downloads: \(value)"
        case .unsupportedRepositoryType(let value):
            return "Repository type \(value) is not supported on iOS yet."
        case .duplicateSourceName(let value):
            return "A repository named \(value) already exists."
        case .protectedDefaultSource(let value):
            return "\(value) is a built-in repository and cannot be deleted here."
        case .configReadFailed:
            return "Could not read repository configuration."
        case .configWriteFailed(let value):
            return "Could not save repository configuration: \(value)"
        }
    }
}

/**
 Owns custom repository validation and `InstallMgr.conf` mutation for the Downloads source UI.

 The manager intentionally follows Android's `CustomRepositoryEditor` sequence: require HTTPS,
 try the supplied URL as a manifest, try `manifest.json`, then fall back to probing a direct
 SWORD catalog containing the base URL, `packages`, and `mods.d.tar.gz`. Mutations are persisted
 to `InstallMgr.conf`, the current iOS source-of-truth for SWORD catalogs.

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
     Loads configured repository sources from `InstallMgr.conf`.

     - Returns: Parsed HTTP and FTP source rows in persisted order.

     Side effects:
     - creates or migrates default repository configuration through `InstallManager`.

     Failure modes:
     - returns an empty array if the config file cannot be read.
     */
    public func loadSources() -> [SourceConfig] {
        InstallManager.ensureDefaultConfigPublic(at: basePath)

        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return []
        }

        return Self.sourceLines(in: content).compactMap(\.source)
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
     - appends an `HTTPSource` row to `InstallMgr.conf`
     - posts `sourcesDidChangeNotification` after a successful write

     - Throws: `RepositorySourceManagementError` for validation, duplicate, or persistence failures.
     */
    @discardableResult
    public func addCustomSource(from rawURL: String) async throws -> RepositorySourceRegistration {
        let registration = try await resolveCustomSource(from: rawURL)
        try writeCustomSource(registration.source, replacing: nil)
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
     - rewrites `InstallMgr.conf`, preserving the original custom row position when possible
     - posts `sourcesDidChangeNotification` after a successful write

     - Throws: `RepositorySourceManagementError` for default-source replacement attempts,
       validation, duplicate, or persistence failures.
     */
    @discardableResult
    public func replaceCustomSource(
        named originalName: String,
        with rawURL: String
    ) async throws -> RepositorySourceRegistration {
        guard !InstallManager.isDefaultSourceName(originalName) else {
            throw RepositorySourceManagementError.protectedDefaultSource(originalName)
        }

        let registration = try await resolveCustomSource(from: rawURL)
        try writeCustomSource(registration.source, replacing: originalName)
        NotificationCenter.default.post(name: Self.sourcesDidChangeNotification, object: nil)
        return registration
    }

    /**
     Deletes a custom source from `InstallMgr.conf`.

     - Parameter name: Repository source name to delete.

     Side effects:
     - rewrites `InstallMgr.conf` without matching HTTP/FTP source rows
     - posts `sourcesDidChangeNotification` after a successful write

     - Throws: `RepositorySourceManagementError.protectedDefaultSource` for built-in sources or a
       config persistence error when the file cannot be read or written.
     */
    public func deleteCustomSource(named name: String) throws {
        guard !InstallManager.isDefaultSourceName(name) else {
            throw RepositorySourceManagementError.protectedDefaultSource(name)
        }

        let content = try currentConfigContent()
        let lines = content.components(separatedBy: .newlines)
        let updatedLines = lines.filter { line in
            guard let parsed = Self.parseSourceLine(line) else { return true }
            return parsed.source.name != name
        }

        try writeConfig(updatedLines.joined(separator: "\n"))
        NotificationCenter.default.post(name: Self.sourcesDidChangeNotification, object: nil)
    }

    /**
     Restores the source config to iOS's packaged Android-parity defaults.

     Side effects:
     - removes the existing `InstallMgr.conf`
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

        InstallManager.ensureDefaultConfigPublic(at: basePath)
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw RepositorySourceManagementError.configWriteFailed("default configuration was not recreated")
        }

        NotificationCenter.default.post(name: Self.sourcesDidChangeNotification, object: nil)
    }

    /**
     Resolves a user-entered URL into a SWORD source registration without persisting it.

     - Parameter rawURL: HTTPS manifest URL or direct SWORD catalog URL.
     - Returns: Registration data suitable for `InstallMgr.conf`.

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

    private func currentConfigContent() throws -> String {
        InstallManager.ensureDefaultConfigPublic(at: basePath)
        do {
            return try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            throw RepositorySourceManagementError.configReadFailed
        }
    }

    private func writeCustomSource(_ source: SourceConfig, replacing originalName: String?) throws {
        try Self.validateConfigFields(source)

        let content = try currentConfigContent()
        let existingNames = Self.sourceLines(in: content)
            .map(\.source.name)
            .filter { $0 != originalName }

        guard !existingNames.contains(source.name) else {
            throw RepositorySourceManagementError.duplicateSourceName(source.name)
        }

        let sourceLine = Self.sourceLine(for: source)
        let updated = Self.configContent(content, inserting: sourceLine, replacing: originalName)
        try writeConfig(updated)
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
            guard type == "sword-https" else {
                throw RepositorySourceManagementError.unsupportedRepositoryType(type)
            }

            do {
                let manifest = try JSONDecoder().decode(SwordHTTPSManifest.self, from: data)
                return try registration(from: manifest, manifestURL: url)
            } catch let error as RepositorySourceManagementError {
                throw error
            } catch {
                throw RepositorySourceManagementError.invalidManifest(error.localizedDescription)
            }
        }

        if jsonObject["file_name"] != nil && jsonObject["url"] != nil {
            throw RepositorySourceManagementError.unsupportedRepositoryType("mybible-https")
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
     Validates one persisted `InstallMgr.conf` source row before it can be written.

     Source names are also used as catalog-cache filenames, so the name must not contain
     path separators that could escape the intended cache directory during a later refresh.

     - Parameter source: Normalized source row candidate.
     - Throws: `RepositorySourceManagementError.invalidManifest` when a field is missing or
       contains config/file-path syntax that cannot be safely persisted.
     */
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
