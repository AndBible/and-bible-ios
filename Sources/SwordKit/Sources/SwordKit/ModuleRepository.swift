// ModuleRepository.swift — Swift-native SWORD module catalog and installer
//
// Replaces libsword's InstallMgr network operations (which require curl,
// not compiled into our iOS build) with pure Swift URLSession downloads.
// Used for: catalog browsing, module downloading, module installation.

import Foundation
import CLibSword
import os.log

private let logger = Logger(subsystem: "org.andbible.ios", category: "ModuleRepository")

/**
 Internal HTTP-status failure used while downloading individual module files.

 `installModule` decides whether a 404 means "skip this optional testament group" or "fail the
 install" based on the module driver and where the failed file appears in its group. Keeping this
 separate from `ModuleRepositoryError.downloadFailed` preserves that context until the install loop
 can make the Android-parity decision.
 */
private struct ModuleFileHTTPStatusError: Error, LocalizedError, Sendable {
    /// Repository file name whose HTTP response was not successful.
    let fileName: String

    /// HTTP status code returned by the repository.
    let statusCode: Int

    /// User-visible failure text used when the missing file is required.
    var errorDescription: String? {
        "\(fileName) download failed (HTTP \(statusCode))"
    }
}

/**
 Downloads one file with native URLSession streaming and progress callbacks.

 The delegate moves the completed temporary download into the caller's staging path only after a
 200 response. It is separate from `ModuleRepository` so each file gets an isolated continuation
 and cancellation target.
 */
private final class ModuleFileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Destination inside the module staging directory.
    private let destinationURL: URL

    /// Repository file name used in failure messages.
    private let fileName: String

    /// Number of files completed before this task began.
    private let completedFiles: Int

    /// Total planned files after optional group pruning.
    private let totalFiles: Double

    /// Optional normalized progress callback supplied by the UI layer.
    private let progress: ((Double) -> Void)?

    /// Serializes continuation, task, and progress-throttle state across URLSession callbacks.
    private let lock = NSLock()

    /// Download task cancelled by the Swift task cancellation handler.
    private var task: URLSessionDownloadTask?

    /// Continuation resumed exactly once from `urlSession(_:task:didCompleteWithError:)`.
    private var continuation: CheckedContinuation<Void, Error>?

    /// Error produced while validating or moving the temporary downloaded file.
    private var finishError: Error?

    /// Tracks whether the temporary download was moved into staging.
    private var movedDownloadToDestination = false

    /// Last integer percent emitted so progress updates stay bounded.
    private var lastReportedPercent: Int

    /**
     Creates a delegate for one staged file download.

     - Parameters:
       - destinationURL: Final staging path for the downloaded file.
       - fileName: Repository file name used in diagnostics.
       - completedFiles: Number of files already staged.
       - totalFiles: Total planned files for progress scaling.
       - progress: Optional normalized progress callback.
     - Side effects: none until a URLSession task starts delivering callbacks.
     - Failure modes: none.
     */
    init(
        destinationURL: URL,
        fileName: String,
        completedFiles: Int,
        totalFiles: Double,
        progress: ((Double) -> Void)?
    ) {
        self.destinationURL = destinationURL
        self.fileName = fileName
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.progress = progress
        self.lastReportedPercent = Int((Double(completedFiles) / totalFiles * 100).rounded(.towardZero))
    }

    /**
     Stores the task and continuation before the download is resumed.

     - Parameters:
       - task: URLSession download task for this file.
       - continuation: Continuation to resume after URLSession completes.
     - Side effects: mutates delegate state under lock.
     - Failure modes: none.
     */
    func start(task: URLSessionDownloadTask, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.task = task
        self.continuation = continuation
        lock.unlock()
    }

    /**
     Cancels the active download task when the surrounding Swift task is cancelled.

     Side effects:
     - calls `cancel()` on the stored URLSession task

     Failure modes:
     - missing or already-completed tasks are ignored
     */
    func cancel() {
        lock.lock()
        let activeTask = task
        lock.unlock()
        activeTask?.cancel()
    }

    /**
     Records an error from the download-finish phase.

     - Parameter error: Failure to surface when URLSession reports completion.
     - Side effects: mutates delegate state under lock.
     - Failure modes: preserves the first recorded error when multiple callbacks race.
     */
    private func recordFinishError(_ error: Error) {
        lock.lock()
        if finishError == nil {
            finishError = error
        }
        lock.unlock()
    }

    /**
     Resumes the stored continuation once.

     - Parameter result: Success or failure for the staged file download.
     - Side effects: clears the stored continuation and task under lock.
     - Failure modes: duplicate completions are ignored.
     */
    private func resumeOnce(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        task = nil
        lock.unlock()

        guard let continuation else { return }
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    /**
     Reports native URLSession byte progress as normalized module-install progress.

     Side effects:
     - invokes the caller's progress callback when a new integer percent boundary is crossed

     Failure modes:
     - unknown content length disables in-file progress; file-completion progress still occurs in
       `ModuleRepository.installModule`
     */
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let currentFileFraction = min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1)
        let overallProgress = (Double(completedFiles) + currentFileFraction) / totalFiles
        let percent = Int((overallProgress * 100).rounded(.towardZero))

        lock.lock()
        let shouldReport = percent > lastReportedPercent
        if shouldReport {
            lastReportedPercent = percent
        }
        lock.unlock()

        if shouldReport {
            progress?(overallProgress)
        }
    }

    /**
     Validates the HTTP response and moves the temporary download into staging.

     Side effects:
     - creates the staging parent directory
     - removes any previous staged file at the same destination
     - moves the temporary URLSession file into `destinationURL`

     Failure modes:
     - records `ModuleFileHTTPStatusError` for non-200 responses
     - records file-system errors so completion can throw them to the install loop
     */
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let httpResponse = downloadTask.response as? HTTPURLResponse else {
            recordFinishError(ModuleRepositoryError.downloadFailed("\(fileName) download failed"))
            return
        }
        guard httpResponse.statusCode == 200 else {
            recordFinishError(ModuleFileHTTPStatusError(fileName: fileName, statusCode: httpResponse.statusCode))
            return
        }

        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: location, to: destinationURL)

            lock.lock()
            movedDownloadToDestination = true
            lock.unlock()
        } catch {
            recordFinishError(error)
        }
    }

    /**
     Converts URLSession completion into the async result for one file.

     Side effects:
     - resumes the stored continuation once

     Failure modes:
     - maps URLSession cancellation to `CancellationError`
     - returns previously recorded response or file-system errors
     */
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                resumeOnce(.failure(CancellationError()))
            } else {
                resumeOnce(.failure(error))
            }
            return
        }

        lock.lock()
        let finishError = finishError
        let movedDownloadToDestination = movedDownloadToDestination
        lock.unlock()

        if let finishError {
            resumeOnce(.failure(finishError))
        } else if movedDownloadToDestination {
            resumeOnce(.success(()))
        } else {
            resumeOnce(.failure(ModuleRepositoryError.downloadFailed("\(fileName) download failed")))
        }
    }
}

/// Configuration for a remote SWORD module source.
public struct SourceConfig: Sendable, Identifiable {
    public let name: String
    public let type: String  // "HTTP" or "FTP"
    public let host: String
    public let catalogPath: String

    public var id: String { name }

    /// Base URL for this source (HTTPS preferred).
    public var baseURL: URL? {
        URL(string: "https://\(host)\(catalogPath)")
    }
}

/// Parsed module entry from a SWORD catalog .conf file.
public struct CatalogModule: Sendable, Identifiable {
    public let name: String
    public let description: String
    public let category: ModuleCategory
    public let language: String
    public let modDrv: String
    public let dataPath: String
    public let confContent: String
    public let sourceName: String
    public let version: String
    public let size: String

    public var id: String { "\(sourceName):\(name)" }

    /// Convert to the public RemoteModuleInfo type.
    public var remoteModuleInfo: RemoteModuleInfo {
        RemoteModuleInfo(
            name: name,
            description: description,
            category: category,
            language: language,
            sourceName: sourceName,
            version: version,
            installSizeBytes: Self.installSizeBytes(from: size)
        )
    }

    /**
     Parses the SWORD `InstallSize` property into bytes for download-list display.

     - Parameter value: Raw catalog value from a module `.conf` file.
     - Returns: Byte count when the value is an integer number of kibibytes; otherwise `nil`.

     Side effects:
     - none

     Failure modes:
     - non-numeric values or values that overflow bytes return `nil`
     */
    private static func installSizeBytes(from value: String) -> Int64? {
        guard let kibibytes = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let bytes = kibibytes.multipliedReportingOverflow(by: 1024)
        return bytes.overflow ? nil : bytes.partialValue
    }
}

/**
 Pure Swift implementation of SWORD catalog browsing and module installation.

 Bypasses libsword's InstallMgr (which requires curl, not compiled for iOS)
 and uses URLSession for all HTTP operations.

 Usage:
 ```swift
 let repo = ModuleRepository()
 let sources = repo.loadSources()
 for source in sources {
     let modules = try await repo.refreshCatalog(for: source)
     // display modules...
 }
 try await repo.installModule(named: "KJV", from: sources[0])
 ```
 */
public final class ModuleRepository: @unchecked Sendable {
    private static let recommendedDocumentsURL = URL(
        string: "https://andbible.github.io/data/recommended_documents_v2.json")!
    private static let badDocumentsURL = URL(
        string: "https://andbible.github.io/data/bad_documents.json")!
    private static let defaultDocumentsURL = URL(
        string: "https://andbible.github.io/data/default_documents_v2.json")!
    private static let pseudoBooksURL = URL(string: "https://andbible.github.io/data/pseudo_books.json")!
    private static let unavailablePseudoSourceName = "Not Available"

    private let basePath: String
    private let swordPath: String
    private let session: URLSession

    /**
     Catalog entries cached per source name for install lookups after a refresh or disk restore.

     This repository is shared across SwiftUI tasks and marked `@unchecked Sendable` because
     `URLSession` and SWORD integration are thread-safe at the call boundary but the cache itself
     is ordinary mutable Swift state. Access must go through the cache helper methods below so
     concurrent catalog refreshes, restores, and installs cannot race on the dictionary storage.
     */
    private var catalogCache: [String: [CatalogModule]] = [:]

    /**
     Serializes access to `catalogCache`.

     Side effects:
     - blocks competing cache readers/writers until the current critical section completes

     Failure modes:
     - none; callers must avoid re-entering cache helper methods while already holding this lock
     */
    private let catalogCacheLock = NSLock()

    /// Directory for persisting catalog caches.
    private var cacheDir: String {
        let dir = (basePath as NSString).appendingPathComponent("catalog-cache")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Directory for AndBible metadata files that augment SWORD catalogs.
    private var metadataCacheDir: String {
        let dir = (basePath as NSString).appendingPathComponent("andbible-data")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private var pseudoBooksCachePath: String {
        (metadataCacheDir as NSString).appendingPathComponent("pseudo_books.json")
    }

    private var recommendedDocumentsCachePath: String {
        (metadataCacheDir as NSString).appendingPathComponent("recommended_documents_v2.json")
    }

    private var badDocumentsCachePath: String {
        (metadataCacheDir as NSString).appendingPathComponent("bad_documents.json")
    }

    private var defaultDocumentsCachePath: String {
        (metadataCacheDir as NSString).appendingPathComponent("default_documents_v2.json")
    }

    /**
     Reads cached catalog entries for one source.

     - Parameter sourceName: Repository source key from `SourceConfig.name`.
     - Returns: A value-copy of the cached entries when the source has been loaded; otherwise `nil`.

     Side effects:
     - briefly locks `catalogCacheLock`

     Failure modes:
     - none
     */
    private func cachedCatalogEntries(for sourceName: String) -> [CatalogModule]? {
        catalogCacheLock.lock()
        defer { catalogCacheLock.unlock() }
        return catalogCache[sourceName]
    }

    /**
     Replaces cached catalog entries for one source.

     - Parameters:
       - entries: Parsed catalog rows for the source.
       - sourceName: Repository source key from `SourceConfig.name`.

     Side effects:
     - mutates the in-memory catalog cache under `catalogCacheLock`

     Failure modes:
     - none
     */
    private func setCachedCatalogEntries(_ entries: [CatalogModule], for sourceName: String) {
        catalogCacheLock.lock()
        catalogCache[sourceName] = entries
        catalogCacheLock.unlock()
    }

    /**
     Captures a stable snapshot of the current source-to-catalog mapping.

     - Returns: A value-copy of the full cache suitable for iteration without holding the lock.

     Side effects:
     - briefly locks `catalogCacheLock`

     Failure modes:
     - none
     */
    private func catalogCacheSnapshot() -> [String: [CatalogModule]] {
        catalogCacheLock.lock()
        defer { catalogCacheLock.unlock() }
        return catalogCache
    }

    public init(basePath: String? = nil, swordPath: String? = nil, session: URLSession? = nil) {
        self.basePath = basePath ?? InstallManager.defaultBasePath()
        self.swordPath = swordPath ?? SwordManager.defaultModulePath()

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: config)
        }

        // Ensure sword directories exist
        let fm = FileManager.default
        try? fm.createDirectory(atPath: self.swordPath, withIntermediateDirectories: true)
        let modsD = (self.swordPath as NSString).appendingPathComponent("mods.d")
        try? fm.createDirectory(atPath: modsD, withIntermediateDirectories: true)
    }

    // MARK: - Source Configuration

    /// Parse sources from InstallMgr.conf.
    public func loadSources() -> [SourceConfig] {
        // Ensure config exists
        InstallManager.ensureDefaultConfigPublic(at: basePath)

        let configPath = (basePath as NSString).appendingPathComponent("InstallMgr.conf")
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return []
        }

        var sources: [SourceConfig] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("HTTPSource=") {
                let value = String(trimmed.dropFirst("HTTPSource=".count))
                let parts = value.components(separatedBy: "|")
                if parts.count >= 3 {
                    sources.append(SourceConfig(
                        name: parts[0],
                        type: "HTTP",
                        host: parts[1],
                        catalogPath: parts[2]
                    ))
                }
            } else if trimmed.hasPrefix("FTPSource=") {
                let value = String(trimmed.dropFirst("FTPSource=".count))
                let parts = value.components(separatedBy: "|")
                if parts.count >= 3 {
                    sources.append(SourceConfig(
                        name: parts[0],
                        type: "FTP",
                        host: parts[1],
                        catalogPath: parts[2]
                    ))
                }
            }
        }
        return sources
    }

    // MARK: - AndBible Metadata

    private struct PseudoBook: Decodable {
        let id: String
        let suggested: String?
    }

    /// Load cached unavailable module metadata from AndBible's pseudo-books feed.
    public func loadCachedPseudoModules() -> [RemoteModuleInfo] {
        guard let data = FileManager.default.contents(atPath: pseudoBooksCachePath) else {
            return []
        }

        do {
            return try Self.pseudoModules(from: data)
        } catch {
            logger.warning("Failed to decode cached pseudo books: \(error.localizedDescription)")
            return []
        }
    }

    /// Refresh unavailable module metadata from AndBible's pseudo-books feed and cache it locally.
    public func refreshPseudoModules() async throws -> [RemoteModuleInfo] {
        let (data, response) = try await session.data(from: Self.pseudoBooksURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ModuleRepositoryError.downloadFailed(
                "Pseudo books download failed (HTTP \(code))")
        }

        let modules = try Self.pseudoModules(from: data)

        do {
            try data.write(to: URL(fileURLWithPath: pseudoBooksCachePath), options: .atomic)
        } catch {
            logger.warning("Failed to cache pseudo books: \(error.localizedDescription)")
        }

        return modules
    }

    /**
     Loads cached Android recommended-document metadata.

     - Returns: Parsed metadata when the cache exists and decodes successfully, otherwise `nil`.

     Side effects:
     - reads the repository metadata cache from disk

     Failure modes:
     - missing or malformed cache files are logged and treated as absent metadata
     */
    public func loadCachedRecommendedDocuments() -> ModuleDownloadConfiguration? {
        loadCachedDownloadConfiguration(path: recommendedDocumentsCachePath, label: "recommended documents")
    }

    /**
     Loads cached Android bad-document metadata.

     - Returns: Parsed metadata when the cache exists and decodes successfully, otherwise `nil`.

     Side effects:
     - reads the repository metadata cache from disk

     Failure modes:
     - missing or malformed cache files are logged and treated as absent metadata
     */
    public func loadCachedBadDocuments() -> ModuleDownloadConfiguration? {
        loadCachedDownloadConfiguration(path: badDocumentsCachePath, label: "bad documents")
    }

    /**
     Loads cached Android default-document metadata for future startup/default-download flows.

     - Returns: Parsed metadata when the cache exists and decodes successfully, otherwise `nil`.

     Side effects:
     - reads the repository metadata cache from disk

     Failure modes:
     - missing or malformed cache files are logged and treated as absent metadata
     */
    public func loadCachedDefaultDocuments() -> ModuleDownloadConfiguration? {
        loadCachedDownloadConfiguration(path: defaultDocumentsCachePath, label: "default documents")
    }

    /**
     Refreshes Android recommended-document metadata and caches it locally.

     - Returns: Parsed metadata from AndBible's hosted JSON feed.
     - Throws: `ModuleRepositoryError.downloadFailed` when the response is not HTTP 200, or a
       decoding/file-system error from `URLSession`, `JSONDecoder`, or cache writes.

     Side effects:
     - downloads network metadata
     - overwrites the local recommended-document metadata cache on success
     */
    public func refreshRecommendedDocuments() async throws -> ModuleDownloadConfiguration {
        try await refreshDownloadConfiguration(
            url: Self.recommendedDocumentsURL,
            cachePath: recommendedDocumentsCachePath,
            label: "recommended documents"
        )
    }

    /**
     Refreshes Android bad-document metadata and caches it locally.

     - Returns: Parsed metadata from AndBible's hosted JSON feed.
     - Throws: `ModuleRepositoryError.downloadFailed` when the response is not HTTP 200, or a
       decoding/file-system error from `URLSession`, `JSONDecoder`, or cache writes.

     Side effects:
     - downloads network metadata
     - overwrites the local bad-document metadata cache on success
     */
    public func refreshBadDocuments() async throws -> ModuleDownloadConfiguration {
        try await refreshDownloadConfiguration(
            url: Self.badDocumentsURL,
            cachePath: badDocumentsCachePath,
            label: "bad documents"
        )
    }

    /**
     Refreshes Android default-document metadata and caches it locally.

     - Returns: Parsed metadata from AndBible's hosted JSON feed.
     - Throws: `ModuleRepositoryError.downloadFailed` when the response is not HTTP 200, or a
       decoding/file-system error from `URLSession`, `JSONDecoder`, or cache writes.

     Side effects:
     - downloads network metadata
     - overwrites the local default-document metadata cache on success
     */
    public func refreshDefaultDocuments() async throws -> ModuleDownloadConfiguration {
        try await refreshDownloadConfiguration(
            url: Self.defaultDocumentsURL,
            cachePath: defaultDocumentsCachePath,
            label: "default documents"
        )
    }

    /**
     Decodes one cached Android metadata configuration.

     - Parameters:
       - path: Cache file path to read.
       - label: Human-readable metadata name used in warning logs.
     - Returns: Parsed metadata or `nil` when absent/malformed.

     Side effects:
     - reads a file from the metadata cache directory

     Failure modes:
     - decode failures are logged and treated as missing metadata
     */
    private func loadCachedDownloadConfiguration(path: String, label: String) -> ModuleDownloadConfiguration? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }

        do {
            return try JSONDecoder().decode(ModuleDownloadConfiguration.self, from: data)
        } catch {
            logger.warning("Failed to decode cached \(label): \(error.localizedDescription)")
            return nil
        }
    }

    /**
     Downloads, decodes, and caches one Android metadata configuration.

     - Parameters:
       - url: Hosted AndBible JSON endpoint.
       - cachePath: Local metadata cache file path.
       - label: Human-readable metadata name used in errors and logs.
     - Returns: Parsed metadata configuration.
     - Throws: Network, HTTP-status, decode, or cache-write errors.

     Side effects:
     - performs a network request
     - writes the response body into the local metadata cache
     */
    private func refreshDownloadConfiguration(
        url: URL,
        cachePath: String,
        label: String
    ) async throws -> ModuleDownloadConfiguration {
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ModuleRepositoryError.downloadFailed(
                "\(label.capitalized) download failed (HTTP \(code))")
        }

        let configuration = try JSONDecoder().decode(ModuleDownloadConfiguration.self, from: data)

        do {
            try data.write(to: URL(fileURLWithPath: cachePath), options: .atomic)
        } catch {
            logger.warning("Failed to cache \(label): \(error.localizedDescription)")
        }

        return configuration
    }

    static func pseudoModules(from data: Data) throws -> [RemoteModuleInfo] {
        try JSONDecoder().decode([PseudoBook].self, from: data)
            .compactMap { book in
                let name = book.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }

                let description = Self.pseudoBookDescription(suggested: book.suggested ?? "")
                return RemoteModuleInfo(
                    name: name,
                    description: description,
                    category: .bible,
                    language: "en",
                    sourceName: Self.unavailablePseudoSourceName,
                    availability: .unavailable,
                    unavailableReason: description,
                    version: "0.0"
                )
            }
    }

    private static func pseudoBookDescription(suggested: String) -> String {
        let base = "This popular translation is not available due to Copyright Holder not granting us distribution permission."
        let trimmedSuggestion = suggested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSuggestion.isEmpty else { return base }
        return "\(base) \(trimmedSuggestion)"
    }

    // MARK: - Catalog Cache (Disk)

    /// Codable wrapper for persisting catalog entries to disk.
    private struct CachedCatalog: Codable {
        var timestamp: Date
        var modules: [CachedModule]
    }

    private struct CachedModule: Codable {
        var name: String
        var description: String
        var category: String
        var language: String
        var sourceName: String
        var modDrv: String
        var dataPath: String
        var confContent: String
        var version: String
        var size: String
    }

    /// Load all cached catalogs from disk. Returns combined RemoteModuleInfo list.
    public func loadCachedCatalogs() -> [RemoteModuleInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: cacheDir) else { return [] }

        var allModules: [RemoteModuleInfo] = []
        for file in files where file.hasSuffix(".json") {
            let path = (cacheDir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let cached = try? JSONDecoder().decode(CachedCatalog.self, from: data) else {
                continue
            }

            // Also restore in-memory catalogCache for install operations
            var entries: [CatalogModule] = []
            for m in cached.modules {
                let cat = ModuleCategory(typeString: m.category)
                let entry = CatalogModule(
                    name: m.name,
                    description: m.description,
                    category: cat,
                    language: m.language,
                    modDrv: m.modDrv,
                    dataPath: m.dataPath,
                    confContent: m.confContent,
                    sourceName: m.sourceName,
                    version: m.version,
                    size: m.size
                )
                entries.append(entry)
                allModules.append(entry.remoteModuleInfo)
            }

            let sourceName = String(file.dropLast(5)) // remove .json
            setCachedCatalogEntries(entries, for: sourceName)
        }

        return allModules
    }

    /// Save a source's catalog entries to disk.
    private func saveCatalogToDisk(sourceName: String, entries: [CatalogModule]) {
        let cached = CachedCatalog(
            timestamp: Date(),
            modules: entries.map { e in
                CachedModule(
                    name: e.name,
                    description: e.description,
                    category: e.category.rawValue,
                    language: e.language,
                    sourceName: e.sourceName,
                    modDrv: e.modDrv,
                    dataPath: e.dataPath,
                    confContent: e.confContent,
                    version: e.version,
                    size: e.size
                )
            }
        )

        guard let data = try? JSONEncoder().encode(cached) else { return }
        let path = (cacheDir as NSString).appendingPathComponent("\(sourceName).json")
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// Age of the cached catalog for a source, or nil if not cached.
    public func catalogCacheAge(for sourceName: String) -> TimeInterval? {
        let path = (cacheDir as NSString).appendingPathComponent("\(sourceName).json")
        guard let data = FileManager.default.contents(atPath: path),
              let cached = try? JSONDecoder().decode(CachedCatalog.self, from: data) else {
            return nil
        }
        return Date().timeIntervalSince(cached.timestamp)
    }

    // MARK: - Catalog Refresh

    /**
     Download and parse the module catalog for a source.
     - Returns: List of available modules from this source.
     */
    public func refreshCatalog(for source: SourceConfig) async throws -> [RemoteModuleInfo] {
        guard source.type == "HTTP" else {
            logger.info("Skipping FTP source '\(source.name)' — FTP is not supported on iOS")
            return []
        }

        guard let baseURL = source.baseURL else {
            throw ModuleRepositoryError.invalidURL(source.name)
        }

        // Download mods.d.tar.gz
        let catalogURL = baseURL.appendingPathComponent("mods.d.tar.gz")
        let (data, response) = try await session.data(from: catalogURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ModuleRepositoryError.downloadFailed(
                "Catalog download from \(source.name) failed (HTTP \(code))")
        }

        // Decompress gzip
        let tarData = try decompressGzip(data)

        // Parse tar archive to extract .conf files
        let tarEntries = parseTar(tarData)

        // Parse each .conf file into a catalog entry
        var catalogEntries: [CatalogModule] = []
        for entry in tarEntries {
            // Only process .conf files
            guard entry.name.hasSuffix(".conf") else { continue }

            guard let content = String(data: entry.data, encoding: .utf8) ??
                                String(data: entry.data, encoding: .isoLatin1) else {
                continue
            }

            if let module = parseModuleConf(content, sourceName: source.name) {
                catalogEntries.append(module)
            }
        }

        // Cache in memory and persist to disk
        setCachedCatalogEntries(catalogEntries, for: source.name)
        saveCatalogToDisk(sourceName: source.name, entries: catalogEntries)

        return catalogEntries.map(\.remoteModuleInfo)
    }

    // MARK: - Module Installation

    /**
     Installs one remote SWORD module by streaming data files into a staging directory before
     publishing it.

     - Parameters:
       - moduleName: Module abbreviation from the refreshed catalog, such as `KJV`.
       - source: Remote source whose in-memory catalog entry supplies URLs and module metadata.
       - progress: Optional callback receiving normalized completion in the range `0.0...1.0`.
     - Side effects:
       - creates a temporary staging directory next to the target module directory
       - streams downloaded data files into staging so large modules are not fully buffered in memory
       - skips absent optional OT/NT file groups so single-testament modules can install
       - replaces the target module directory only after all required files have downloaded
       - writes the module `.conf` file only after staged data is ready to publish
       - invalidates SWORD's module cache after a successful install
     - Throws:
       - `ModuleRepositoryError.moduleNotFound` when the source catalog does not contain the module
       - `ModuleRepositoryError.invalidURL` when the source cannot produce a base URL
       - `ModuleRepositoryError.downloadFailed` when any required data file returns a non-200 HTTP
         response, no optional data group is available, or transport fails
       - `CancellationError` when the surrounding task is cancelled before the install completes
       - file-system errors from directory creation, data writes, or config writes
     - Important: The `.conf` file is the installed marker consumed by `SwordManager`, and updates
       may already have an installed marker. Data files are therefore staged and swapped with a
       rollback path so failed or cancelled installs do not corrupt an existing module.
     */
    public func installModule(named moduleName: String, from source: SourceConfig,
                              progress: ((Double) -> Void)? = nil) async throws {
        guard let entries = cachedCatalogEntries(for: source.name),
              let entry = entries.first(where: { $0.name == moduleName }) else {
            throw ModuleRepositoryError.moduleNotFound(moduleName)
        }

        guard let baseURL = source.baseURL else {
            throw ModuleRepositoryError.invalidURL(source.name)
        }

        let fm = FileManager.default

        // 1. Determine local directory and remote base path.
        //    For verse-keyed modules (ztext, rawtext, zcom, rawcom), DataPath is a directory
        //    (e.g. "modules/texts/ztext/kjv/") and files go directly inside.
        //    For lexicon/genbook modules (rawld, zld, rawgenbook), DataPath ends with a
        //    filename prefix (e.g. "modules/lexdict/rawld/strongshebrew/strongshebrew")
        //    — the parent is the directory, and files like "strongshebrew.dat" go there.
        let driver = entry.modDrv.lowercased()
        let usesFilePrefix = ["rawld", "rawld4", "zld", "rawgenbook"].contains(driver)
        let localDir: String
        let remoteBase: String
        if usesFilePrefix {
            // DataPath's parent is the actual directory
            localDir = ((swordPath as NSString).appendingPathComponent(entry.dataPath) as NSString).deletingLastPathComponent
            remoteBase = (entry.dataPath as NSString).deletingLastPathComponent
        } else {
            localDir = (swordPath as NSString).appendingPathComponent(entry.dataPath)
            remoteBase = entry.dataPath
        }
        let localDirURL = URL(fileURLWithPath: localDir, isDirectory: true)
        let localParentURL = localDirURL.deletingLastPathComponent()
        try fm.createDirectory(at: localParentURL, withIntermediateDirectories: true)
        let stagingDirURL = localParentURL.appendingPathComponent(
            ".\(localDirURL.lastPathComponent)-\(UUID().uuidString).installing",
            isDirectory: true
        )
        try fm.createDirectory(at: stagingDirURL, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: stagingDirURL)
        }

        // 2. Determine files to download based on ModDrv
        let fileGroups = moduleFileGroups(for: entry.modDrv, dataPath: entry.dataPath)

        // 3. Download each file
        var plannedFileCount = fileGroups.reduce(0) { $0 + $1.files.count }
        var downloaded = 0
        var stagedFileCount = 0

        for group in fileGroups {
            var downloadedInGroup = 0

            for (index, fileName) in group.files.enumerated() {
                try Task.checkCancellation()

                let remoteURL = baseURL
                    .appendingPathComponent(remoteBase)
                    .appendingPathComponent(fileName)

                do {
                    logger.info("Downloading \(remoteURL.absoluteString)")
                    let stagedFileURL = stagingDirURL.appendingPathComponent(fileName)
                    try await downloadRequiredModuleFile(
                        from: remoteURL,
                        to: stagedFileURL,
                        fileName: fileName,
                        completedFiles: downloaded,
                        totalFiles: Double(max(plannedFileCount, 1)),
                        progress: progress
                    )
                    logger.info("Staged \(fileName) to \(stagedFileURL.path)")
                    downloaded += 1
                    downloadedInGroup += 1
                    stagedFileCount += 1
                    progress?(Double(downloaded) / Double(max(plannedFileCount, 1)))
                } catch let statusError as ModuleFileHTTPStatusError
                    where !group.required && downloadedInGroup == 0 && index == 0 && statusError.statusCode == 404 {
                    plannedFileCount -= group.files.count
                    if downloaded > 0 {
                        progress?(Double(downloaded) / Double(max(plannedFileCount, 1)))
                    }
                    logger.info("Skipping missing optional module file group starting with \(fileName)")
                    break
                } catch let statusError as ModuleFileHTTPStatusError {
                    logger.warning("Download failed for \(fileName): \(statusError.localizedDescription)")
                    throw ModuleRepositoryError.downloadFailed(statusError.localizedDescription)
                } catch {
                    logger.warning("Download failed for \(fileName): \(error.localizedDescription)")
                    throw error
                }
            }
        }

        guard stagedFileCount > 0 else {
            throw ModuleRepositoryError.downloadFailed("No module data files were available for \(moduleName)")
        }

        // 4. Publish staged files and write .conf marker with rollback for updates.
        try commitStagedModuleInstall(
            stagingDirURL: stagingDirURL,
            localDirURL: localDirURL,
            moduleName: moduleName,
            confContent: entry.confContent
        )

        // 5. Invalidate SWORD's module cache so new SWMgr instances rescan
        invalidateModuleCache()

        progress?(1.0)
    }

    /**
     Streams one module file into a staging destination using URLSession's native download task.

     - Parameters:
       - remoteURL: Fully resolved repository URL for the required module file.
       - destinationURL: Staging-file destination that will be created or replaced.
       - fileName: Repository file name used in user-visible failure messages.
       - completedFiles: Number of required files already staged before this download.
       - totalFiles: Total required files for the module install, used for progress scaling.
       - progress: Optional progress callback receiving throttled normalized completion.

     Side effects:
     - creates the destination parent directory
     - creates a short-lived URLSession with the same configuration as the repository session
     - moves URLSession's temporary download file to `destinationURL` after a 200 response
     - invokes `progress` as URLSession reports integer percent boundaries

     Failure modes:
     - throws `ModuleFileHTTPStatusError` for non-200 responses so the install loop can distinguish
       optional 404 groups from required-file failures
     - throws `CancellationError` when the surrounding task is cancelled
     - propagates transport and file I/O errors
     */
    private func downloadRequiredModuleFile(
        from remoteURL: URL,
        to destinationURL: URL,
        fileName: String,
        completedFiles: Int,
        totalFiles: Double,
        progress: ((Double) -> Void)?
    ) async throws {
        try Task.checkCancellation()
        let delegate = ModuleFileDownloadDelegate(
            destinationURL: destinationURL,
            fileName: fileName,
            completedFiles: completedFiles,
            totalFiles: totalFiles,
            progress: progress
        )
        let downloadSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer {
            downloadSession.invalidateAndCancel()
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = downloadSession.downloadTask(with: remoteURL)
                delegate.start(task: task, continuation: continuation)
                task.resume()
            }
        } onCancel: {
            delegate.cancel()
        }

        try Task.checkCancellation()
    }

    /**
     Publishes a fully staged module install with rollback protection for updates.

     - Parameters:
       - stagingDirURL: Directory containing all freshly downloaded required files.
       - localDirURL: Final SWORD module data directory.
       - moduleName: Module abbreviation used to resolve the `.conf` marker path.
       - confContent: Catalog `.conf` content to publish after staged data is in place.

     Side effects:
     - moves the previous module data directory and config marker to hidden backups when present
     - moves the staged directory into the final location
     - writes the `.conf` installed marker atomically
     - removes backups after a successful publish

     Failure modes:
     - restores previous data/config backups when any publish step fails, then rethrows the error
     - best-effort cleanup is used for rollback failures because the original error is the caller's
       actionable failure
     */
    private func commitStagedModuleInstall(
        stagingDirURL: URL,
        localDirURL: URL,
        moduleName: String,
        confContent: String
    ) throws {
        let fm = FileManager.default
        let nonce = UUID().uuidString
        let localParentURL = localDirURL.deletingLastPathComponent()
        let backupDirURL = localParentURL.appendingPathComponent(
            ".\(localDirURL.lastPathComponent)-\(nonce).backup",
            isDirectory: true
        )
        let modsDirURL = URL(fileURLWithPath: swordPath, isDirectory: true)
            .appendingPathComponent("mods.d", isDirectory: true)
        try fm.createDirectory(at: modsDirURL, withIntermediateDirectories: true)
        let confURL = modsDirURL.appendingPathComponent(moduleName.lowercased() + ".conf")
        let backupConfURL = modsDirURL.appendingPathComponent(
            ".\(moduleName.lowercased()).conf-\(nonce).backup"
        )

        var movedExistingDir = false
        var movedExistingConf = false
        var movedStagingIntoPlace = false

        do {
            if fm.fileExists(atPath: localDirURL.path) {
                try fm.moveItem(at: localDirURL, to: backupDirURL)
                movedExistingDir = true
            }
            if fm.fileExists(atPath: confURL.path) {
                try fm.moveItem(at: confURL, to: backupConfURL)
                movedExistingConf = true
            }

            try fm.moveItem(at: stagingDirURL, to: localDirURL)
            movedStagingIntoPlace = true
            try confContent.write(to: confURL, atomically: true, encoding: .utf8)

            if movedExistingDir {
                try? fm.removeItem(at: backupDirURL)
            }
            if movedExistingConf {
                try? fm.removeItem(at: backupConfURL)
            }
        } catch {
            if movedStagingIntoPlace {
                try? fm.removeItem(at: localDirURL)
            }
            if movedExistingDir {
                try? fm.moveItem(at: backupDirURL, to: localDirURL)
            }
            if movedStagingIntoPlace || movedExistingConf {
                try? fm.removeItem(at: confURL)
            }
            if movedExistingConf {
                try? fm.moveItem(at: backupConfURL, to: confURL)
            }
            throw error
        }
    }

    /// Uninstall a module by removing its data and conf files.
    public func uninstallModule(named moduleName: String) throws {
        let fm = FileManager.default

        // Find and read .conf file
        let modsDir = (swordPath as NSString).appendingPathComponent("mods.d")
        let confPath = (modsDir as NSString)
            .appendingPathComponent(moduleName.lowercased() + ".conf")

        // Read DataPath before deleting
        var dataPath: String?
        if let content = try? String(contentsOfFile: confPath, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("datapath=") {
                    let idx = trimmed.index(trimmed.startIndex, offsetBy: 9)
                    dataPath = String(trimmed[idx...])
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "./", with: "")
                    break
                }
            }
        }

        // Remove .conf file
        try? fm.removeItem(atPath: confPath)

        // Remove data directory
        if let dataPath, !dataPath.isEmpty {
            let fullDataPath = (swordPath as NSString).appendingPathComponent(dataPath)
            try? fm.removeItem(atPath: fullDataPath)
        }

        // Invalidate SWORD's module cache
        invalidateModuleCache()
    }

    /// Delete SWORD's modules-conf.cache so the next SWMgr instance rescans mods.d/.
    private func invalidateModuleCache() {
        let cachePath = (swordPath as NSString)
            .appendingPathComponent("mods.d")
            .appending("/modules-conf.cache")
        try? FileManager.default.removeItem(atPath: cachePath)
    }

    // MARK: - Install from ZIP

    /**
     Install a SWORD module from a local `.zip` file.

     The archive must contain one or more module config files under `mods.d/` plus the
     corresponding module data directory, such as `modules/`.

     - Parameter url: Local archive URL to install.
     - Returns: The installed module identifier derived from the config filename.
     - Side effects:
       - extracts archive entries into the configured SWORD home directory
       - invalidates the SWORD module cache after extraction completes
     - Failure modes:
       - throws `ModuleRepositoryError.invalidZip` when the file cannot be read, parsed, or does
         not contain a valid module layout
       - rethrows filesystem failures while creating directories or writing extracted files
     */
    public func installFromZip(at url: URL) throws -> String {
        let fm = FileManager.default

        // Read ZIP data
        guard let zipData = try? Data(contentsOf: url) else {
            throw ModuleRepositoryError.invalidZip("Could not read ZIP file")
        }

        // Parse ZIP entries
        let entries = try parseZip(zipData)
        guard !entries.isEmpty else {
            throw ModuleRepositoryError.invalidZip("ZIP file is empty")
        }

        // Find .conf files in mods.d/
        let confEntries = entries.filter { entry in
            let name = entry.name.lowercased()
            return (name.hasPrefix("mods.d/") || name.contains("/mods.d/"))
                && name.hasSuffix(".conf")
        }

        guard !confEntries.isEmpty else {
            throw ModuleRepositoryError.invalidZip("No module .conf files found in mods.d/")
        }

        var installedModuleName = ""

        for entry in entries {
            // Normalize path — remove leading "./" or module folder prefix
            var relativePath = entry.name
            if relativePath.hasPrefix("./") {
                relativePath = String(relativePath.dropFirst(2))
            }
            // Some zips nest everything under a folder like "KJV/"
            // Detect if all paths share a common prefix that's not mods.d/ or modules/
            if relativePath.isEmpty || relativePath.hasSuffix("/") { continue }

            let destPath = (swordPath as NSString).appendingPathComponent(relativePath)
            let destDir = (destPath as NSString).deletingLastPathComponent

            try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            try entry.data.write(to: URL(fileURLWithPath: destPath))

            // Track the module name from .conf filename
            if relativePath.lowercased().hasPrefix("mods.d/") && relativePath.lowercased().hasSuffix(".conf") {
                let confName = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
                installedModuleName = confName.uppercased()
            }
        }

        // Invalidate SWORD's module cache
        invalidateModuleCache()

        guard !installedModuleName.isEmpty else {
            throw ModuleRepositoryError.invalidZip("No module name found in .conf files")
        }

        return installedModuleName
    }

    // MARK: - ZIP Parsing

    private struct ZipEntry {
        let name: String
        let data: Data
    }

    /**
     Parse ZIP file data and extract all entries.
     Supports stored (method 0) and deflated (method 8) entries.
     */
    private func parseZip(_ data: Data) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        var offset = 0

        while offset + 30 <= data.count {
            // Local file header signature: 0x04034b50
            let sig = data.subdata(in: offset..<offset+4)
            guard sig == Data([0x50, 0x4b, 0x03, 0x04]) else { break }

            let method = readUInt16(data, at: offset + 8)
            let compressedSize = Int(readUInt32(data, at: offset + 18))
            let uncompressedSize = Int(readUInt32(data, at: offset + 22))
            let nameLen = Int(readUInt16(data, at: offset + 26))
            let extraLen = Int(readUInt16(data, at: offset + 28))

            let nameStart = offset + 30
            guard nameStart + nameLen <= data.count else { break }
            let name = String(data: data[nameStart..<nameStart+nameLen], encoding: .utf8) ?? ""

            let dataStart = nameStart + nameLen + extraLen
            guard dataStart + compressedSize <= data.count else { break }
            let compressedData = data[dataStart..<dataStart+compressedSize]

            if !name.isEmpty && !name.hasSuffix("/") {
                let fileData: Data
                switch method {
                case 0: // Stored
                    fileData = Data(compressedData)
                case 8: // Deflated
                    fileData = try inflateData(Data(compressedData), uncompressedSize: uncompressedSize)
                default:
                    // Skip unsupported compression methods
                    offset = dataStart + compressedSize
                    continue
                }
                entries.append(ZipEntry(name: name, data: fileData))
            }

            offset = dataStart + compressedSize
        }

        return entries
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        return data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        return data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    /// Inflate deflated data using the C adapter's inflate_raw_data().
    private func inflateData(_ compressed: Data, uncompressedSize: Int) throws -> Data {
        return try compressed.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = ptr.baseAddress else {
                throw ModuleRepositoryError.decompressionFailed
            }

            var outputLen: UInt = 0
            guard let output = inflate_raw_data(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(compressed.count),
                UInt(uncompressedSize),
                &outputLen
            ) else {
                throw ModuleRepositoryError.decompressionFailed
            }

            defer { gunzip_free(output) }
            return Data(bytes: output, count: Int(outputLen))
        }
    }

    /// Find the source for a given module name from the catalog cache.
    public func source(for moduleName: String) -> SourceConfig? {
        let sources = loadSources()
        for (sourceName, entries) in catalogCacheSnapshot() {
            if entries.contains(where: { $0.name == moduleName }) {
                return sources.first(where: { $0.name == sourceName })
            }
        }
        return nil
    }

    // MARK: - Gzip Decompression

    private func decompressGzip(_ data: Data) throws -> Data {
        return try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = ptr.baseAddress else {
                throw ModuleRepositoryError.decompressionFailed
            }

            var outputLen: UInt = 0
            guard let output = gunzip_data(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(data.count),
                &outputLen
            ) else {
                throw ModuleRepositoryError.decompressionFailed
            }

            defer { gunzip_free(output) }
            return Data(bytes: output, count: Int(outputLen))
        }
    }

    // MARK: - Tar Parsing

    private struct TarEntry {
        let name: String
        let data: Data
    }

    private func parseTar(_ data: Data) -> [TarEntry] {
        var entries: [TarEntry] = []
        var offset = 0

        while offset + 512 <= data.count {
            // Read 512-byte header
            let headerStart = offset
            offset += 512

            // Check for end-of-archive (zero block)
            let isZeroBlock = data[headerStart..<headerStart + 512]
                .allSatisfy { $0 == 0 }
            if isZeroBlock { break }

            // File name: bytes 0-99 (null-terminated)
            let nameBytes = data[headerStart..<headerStart + 100]
            var nameEnd = nameBytes.startIndex
            while nameEnd < nameBytes.endIndex && data[nameEnd] != 0 {
                nameEnd = data.index(after: nameEnd)
            }
            let name = String(
                bytes: data[nameBytes.startIndex..<nameEnd],
                encoding: .utf8
            ) ?? ""

            // File size: bytes 124-135 (octal ASCII, null/space terminated)
            let sizeStart = headerStart + 124
            let sizeBytes = data[sizeStart..<sizeStart + 12]
            var sizeStr = ""
            for byte in sizeBytes {
                if byte == 0 || byte == 0x20 { break }
                sizeStr.append(Character(UnicodeScalar(byte)))
            }
            let size = Int(sizeStr, radix: 8) ?? 0

            // Type flag: byte 156 ('0' or NUL = regular file)
            let typeFlag = data[headerStart + 156]
            let isFile = typeFlag == 0 || typeFlag == 0x30 // '0'

            // Extract file data
            if size > 0 && isFile && offset + size <= data.count {
                let fileData = Data(data[offset..<offset + size])
                if !name.isEmpty {
                    entries.append(TarEntry(name: name, data: fileData))
                }
            }

            // Advance past data to next 512-byte boundary
            if size > 0 {
                let dataBlocks = (size + 511) / 512
                offset += dataBlocks * 512
            }
        }

        return entries
    }

    // MARK: - .conf File Parsing

    private func parseModuleConf(_ content: String, sourceName: String) -> CatalogModule? {
        var name = ""
        var description = ""
        var categoryStr = ""
        var language = "en"
        var modDrv = ""
        var dataPath = ""
        var version = ""
        var installSize = ""

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Section header [ModuleName]
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if name.isEmpty {
                    name = String(trimmed.dropFirst().dropLast())
                }
                continue
            }

            // Skip continuation lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Key=Value
            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eqIdx)...])
                .trimmingCharacters(in: .whitespaces)

            switch key {
            case "Description": description = value
            case "Category": categoryStr = value
            case "Lang": language = value
            case "ModDrv": modDrv = value
            case "DataPath":
                dataPath = value
                // Strip leading ./ prefix
                if dataPath.hasPrefix("./") {
                    dataPath = String(dataPath.dropFirst(2))
                }
                // Ensure trailing slash
                if !dataPath.hasSuffix("/") {
                    dataPath += "/"
                }
            case "Version": version = value
            case "InstallSize": installSize = value
            default: break
            }
        }

        guard !name.isEmpty, !modDrv.isEmpty else { return nil }

        // Determine category
        let category: ModuleCategory
        if !categoryStr.isEmpty {
            category = ModuleCategory(typeString: categoryStr)
        } else {
            // Infer from ModDrv
            let driver = modDrv.lowercased()
            if driver.contains("text") {
                category = .bible
            } else if driver.contains("com") {
                category = .commentary
            } else if driver.contains("ld") {
                category = .dictionary
            } else if driver.contains("genbook") {
                category = .generalBook
            } else {
                category = .unknown
            }
        }

        return CatalogModule(
            name: name,
            description: description,
            category: category,
            language: language,
            modDrv: modDrv,
            dataPath: dataPath,
            confContent: content,
            sourceName: sourceName,
            version: version,
            size: installSize
        )
    }

    // MARK: - Module File Patterns

    /**
     Describes one group of module data files that must be handled together.

     Verse-keyed Bibles and commentaries can be single-testament modules, so their OT and NT groups
     are optional until the first file in a group exists. Dictionary and genbook drivers need every
     file in their group to produce a usable module.
     */
    private struct ModuleFileGroup {
        /// Repository file names in the order they should be downloaded.
        let files: [String]

        /// Whether a missing first file fails the install instead of skipping the group.
        let required: Bool
    }

    /**
     Determines the module file groups to download based on the SWORD module driver.

     - Parameters:
       - modDrv: SWORD driver name from the module `.conf`.
       - dataPath: Normalized `DataPath` from the module `.conf`.
     - Returns: Ordered file groups. Optional groups model Android/libsword behavior for
       single-testament verse-keyed modules; required groups remain all-or-nothing.
     - Side effects: none.
     - Failure modes: unknown drivers fall back to optional ztext-style testament groups.
     */
    private func moduleFileGroups(for modDrv: String, dataPath: String) -> [ModuleFileGroup] {
        let driver = modDrv.lowercased()

        switch driver {
        case "ztext", "ztext4":
            return [
                ModuleFileGroup(files: ["ot.bzs", "ot.bzz", "ot.bzv"], required: false),
                ModuleFileGroup(files: ["nt.bzs", "nt.bzz", "nt.bzv"], required: false)
            ]
        case "rawtext", "rawtext4":
            return [
                ModuleFileGroup(files: ["ot", "ot.vss"], required: false),
                ModuleFileGroup(files: ["nt", "nt.vss"], required: false)
            ]
        case "zcom", "zcom2", "zcom4":
            return [
                ModuleFileGroup(files: ["ot.bzs", "ot.bzz", "ot.bzv"], required: false),
                ModuleFileGroup(files: ["nt.bzs", "nt.bzz", "nt.bzv"], required: false)
            ]
        case "rawcom", "rawcom4":
            return [
                ModuleFileGroup(files: ["ot", "ot.vss"], required: false),
                ModuleFileGroup(files: ["nt", "nt.vss"], required: false)
            ]
        case "zld":
            let name = lastComponent(of: dataPath)
            return [ModuleFileGroup(files: ["\(name).dat", "\(name).idx", "\(name).zdx", "\(name).zdt"], required: true)]
        case "rawld", "rawld4":
            let name = lastComponent(of: dataPath)
            return [ModuleFileGroup(files: ["\(name).dat", "\(name).idx"], required: true)]
        case "rawgenbook":
            let name = lastComponent(of: dataPath)
            return [ModuleFileGroup(files: ["\(name).bdt", "\(name).bks", "\(name).bky"], required: true)]
        default:
            // Best effort for unknown types
            return [
                ModuleFileGroup(files: ["ot.bzs", "ot.bzz", "ot.bzv"], required: false),
                ModuleFileGroup(files: ["nt.bzs", "nt.bzz", "nt.bzv"], required: false)
            ]
        }
    }

    /// Get the last path component, stripping trailing slashes.
    private func lastComponent(of path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }
}

/// Errors from ModuleRepository operations.
public enum ModuleRepositoryError: Error, LocalizedError {
    case invalidURL(String)
    case downloadFailed(String)
    case decompressionFailed
    case moduleNotFound(String)
    case installFailed(String)
    case invalidZip(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let source): return "Invalid URL for source: \(source)"
        case .downloadFailed(let msg): return msg
        case .decompressionFailed: return "Failed to decompress catalog data"
        case .moduleNotFound(let name): return "Module '\(name)' not found in catalog"
        case .installFailed(let msg): return "Installation failed: \(msg)"
        case .invalidZip(let msg): return "Invalid ZIP module: \(msg)"
        }
    }
}
