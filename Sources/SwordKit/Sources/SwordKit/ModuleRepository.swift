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

    /// Records cancellation that arrives before a URLSession task has been stored.
    private var cancellationRequested = false

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
     - Returns: `true` when the caller should resume the task, or `false` when cancellation was
       already requested before the task could be stored.
     - Side effects: mutates delegate state under lock.
     - Failure modes: resumes `continuation` with `CancellationError` when cancellation already won
       the start race.
     */
    func start(task: URLSessionDownloadTask, continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        if cancellationRequested {
            lock.unlock()
            task.cancel()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.task = task
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /**
     Cancels the active download task when the surrounding Swift task is cancelled.

     Side effects:
     - records cancellation so a task created after this point is not resumed
     - calls `cancel()` on the stored URLSession task

     Failure modes:
     - missing or already-completed tasks are ignored
     */
    func cancel() {
        lock.lock()
        cancellationRequested = true
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

/**
 Configuration for a remote module source consumed by Downloads.

 The struct keeps the legacy SWORD tuple (`type`, `host`, `catalogPath`) while also carrying
 Android custom-repository metadata. SWORD rows use `sword-https` by default and can be projected
 into `InstallMgr.conf`; MyBible rows use `mybible-https` and are refreshed from their manifest
 URL without pretending to be SWORD sources.

 - Note: This type is immutable and has no side effects. Validation is owned by
   `RepositorySourceManager` before records are persisted.
 */
public struct SourceConfig: Sendable, Identifiable {
    /// Android custom repository type for HTTPS SWORD repositories accepted by Downloads.
    public static let swordHTTPSRepositoryType = "sword-https"

    /// Android custom repository type for MyBible manifest repositories accepted by Downloads.
    public static let myBibleHTTPSRepositoryType = "mybible-https"

    /// Stable repository name shown to users and used for cache identity.
    public let name: String

    /// SWORD transport value from `InstallMgr.conf`; MyBible custom rows use `HTTP` for UI parity.
    public let type: String  // "HTTP" or "FTP"

    /// Network host and optional port for SWORD rows, or the manifest host for MyBible rows.
    public let host: String

    /// SWORD catalog path, or manifest path for MyBible custom rows.
    public let catalogPath: String

    /// Android repository family that determines refresh and install behavior.
    public let repositoryType: String

    /// Optional manifest description retained for edit/display context.
    public let description: String?

    /// Optional Android package directory used by SWORD package fallback installs.
    public let packageDirectory: String?

    /// Optional custom repository manifest URL used for edit context and MyBible refresh.
    public let manifestURL: URL?

    /// Optional resolved source URL used for display and diagnostics.
    public let sourceURL: URL?

    public var id: String { name }

    /// HTTPS base URL for SWORD catalog refresh, when the host/path tuple is usable.
    public var baseURL: URL? {
        URL(string: "https://\(host)\(catalogPath)")
    }

    /// Whether this source is backed by an Android MyBible repository manifest.
    public var isMyBibleRepository: Bool {
        repositoryType == Self.myBibleHTTPSRepositoryType
    }

    /**
     Creates a remote repository source row with optional Android custom-repository metadata.

     - Parameters:
       - name: Stable repository name shown in Downloads and used for cache keys.
       - type: Transport row from `InstallMgr.conf`, normally `HTTP` or `FTP`.
       - host: Network host and optional port for SWORD-style sources.
       - catalogPath: SWORD catalog path, or the manifest path for MyBible sources.
       - repositoryType: Android repository type. Defaults to `sword-https` for HTTP rows and
         `ftp` for FTP rows so existing callers keep their previous behavior.
       - description: Optional human-readable manifest description.
       - packageDirectory: Optional Android package directory for SWORD package fallback.
       - manifestURL: Optional custom repository manifest URL.
       - sourceURL: Optional resolved source URL used for display/edit context.
     - Side effects: none.
     - Failure modes: none; validation is owned by `RepositorySourceManager`.
     */
    public init(
        name: String,
        type: String,
        host: String,
        catalogPath: String,
        repositoryType: String? = nil,
        description: String? = nil,
        packageDirectory: String? = nil,
        manifestURL: URL? = nil,
        sourceURL: URL? = nil
    ) {
        self.name = name
        self.type = type
        self.host = host
        self.catalogPath = catalogPath
        self.repositoryType = repositoryType ?? (type == "FTP" ? "ftp" : Self.swordHTTPSRepositoryType)
        self.description = description
        self.packageDirectory = packageDirectory
        self.manifestURL = manifestURL
        self.sourceURL = sourceURL
    }
}

/**
 Parsed remote module entry from a repository catalog.

 SWORD entries carry the original `.conf` payload required for the SWORD installer. MyBible
 entries carry a direct package URL and package filename instead. Keeping both shapes in one
 model lets the Downloads list sort, filter, cache, and install rows without branching in UI code.

 - Note: The struct is immutable and performs no file or network I/O.
 */
public struct CatalogModule: Sendable, Identifiable {
    /// Module initials shown in Downloads and used as install identity.
    public let name: String

    /// User-visible module description.
    public let description: String

    /// Downloads category inferred from SWORD metadata or MyBible filename conventions.
    public let category: ModuleCategory

    /// Module language code.
    public let language: String

    /// SWORD module driver name; empty for non-SWORD repository rows.
    public let modDrv: String

    /// SWORD data path; empty for non-SWORD repository rows.
    public let dataPath: String

    /// Full SWORD `.conf` content required by SWORD installation.
    public let confContent: String

    /// Repository source name that produced this catalog entry.
    public let sourceName: String

    /// Remote catalog version or update marker.
    public let version: String

    /// Remote install-size value as reported by SWORD catalogs.
    public let size: String

    /// Android repository family that produced this row.
    public let repositoryType: String

    /// Direct package URL for non-SWORD installers.
    public let downloadURL: URL?

    /// Original package filename from the repository manifest.
    public let packageFileName: String?

    public var id: String { "\(sourceName):\(name)" }

    /**
     Creates a catalog entry from either a SWORD `.conf` row or an Android-compatible custom
     repository manifest.

     - Parameters:
       - name: Module initials shown in Downloads.
       - description: User-visible module description.
       - category: Download category.
       - language: Module language code.
       - modDrv: SWORD driver name; empty for non-SWORD repository rows.
       - dataPath: SWORD data path; empty for non-SWORD repository rows.
       - confContent: Full SWORD `.conf` content; empty for non-SWORD repository rows.
       - sourceName: Repository source name.
       - version: Remote version/update marker.
       - size: SWORD install-size value in KiB when available.
       - repositoryType: Android repository type that produced the row.
       - downloadURL: Direct package URL for non-SWORD installers.
       - packageFileName: Original package filename from the manifest.
     - Side effects: none.
     - Failure modes: none.
     */
    public init(
        name: String,
        description: String,
        category: ModuleCategory,
        language: String,
        modDrv: String,
        dataPath: String,
        confContent: String,
        sourceName: String,
        version: String,
        size: String,
        repositoryType: String = SourceConfig.swordHTTPSRepositoryType,
        downloadURL: URL? = nil,
        packageFileName: String? = nil
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.language = language
        self.modDrv = modDrv
        self.dataPath = dataPath
        self.confContent = confContent
        self.sourceName = sourceName
        self.version = version
        self.size = size
        self.repositoryType = repositoryType
        self.downloadURL = downloadURL
        self.packageFileName = packageFileName
    }

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

    /// Directory where Android-compatible MyBible packages are installed outside the SWORD tree.
    private var myBibleInstallDir: URL {
        let dir = URL(fileURLWithPath: swordPath, isDirectory: true)
            .appendingPathComponent("mybible", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /**
     Persisted metadata for one installed MyBible package.

     The SQLite payload is not a SWORD module, so Downloads stores a small sidecar beside the
     extracted package. This lets the list render installed state and uninstall safely without
     inventing fake `mods.d` rows that SWORD would try to load.
     */
    private struct InstalledMyBibleModule: Codable {
        /// Installed module initials used by Downloads and uninstall.
        var name: String

        /// User-visible module description from the repository manifest.
        var description: String

        /// Raw `ModuleCategory` value captured at install time.
        var category: String

        /// Module language code captured from the manifest row.
        var language: String

        /// Manifest update marker captured as the installed version.
        var version: String

        /// Repository source name that produced this installed module.
        var sourceName: String

        /// Original package filename from the MyBible manifest.
        var packageFileName: String

        /// HTTPS package URL used for the install.
        var downloadURL: String

        /// Local install timestamp for future diagnostics and migrations.
        var installedAt: Date

        /// Converts sidecar metadata into the common installed-module row model.
        var moduleInfo: ModuleInfo {
            ModuleInfo(
                name: name,
                description: description,
                category: ModuleCategory(typeString: category),
                language: language,
                version: version
            )
        }
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

    /**
     Loads repository sources visible to Downloads.

     The canonical loader lives in `RepositorySourceManager` so SWORD `InstallMgr.conf` rows and
     Android custom repository sidecar records are interpreted consistently by the manager UI and
     module browser.

     - Returns: Built-in and custom sources in display/refresh order.
     - Side effects: may create or migrate default source configuration through
       `RepositorySourceManager`.
     - Failure modes: unreadable `InstallMgr.conf` data omits config-backed SWORD rows, while
       valid sidecar-only MyBible sources can still be returned.
     */
    public func loadSources() -> [SourceConfig] {
        RepositorySourceManager(basePath: basePath).loadSources()
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
        var repositoryType: String?
        var downloadURL: String?
        var packageFileName: String?
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
                    size: m.size,
                    repositoryType: m.repositoryType ?? SourceConfig.swordHTTPSRepositoryType,
                    downloadURL: m.downloadURL.flatMap(URL.init(string:)),
                    packageFileName: m.packageFileName
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
                    size: e.size,
                    repositoryType: e.repositoryType,
                    downloadURL: e.downloadURL?.absoluteString,
                    packageFileName: e.packageFileName
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
        if source.isMyBibleRepository {
            return try await refreshMyBibleCatalog(for: source)
        }

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

    /**
     Downloads and converts an Android-compatible MyBible repository manifest into Downloads rows.
     Module language codes are trimmed before storage, with empty values defaulting to English.

     - Parameter source: Custom source whose `manifestURL` points at a MyBible manifest.
     - Returns: Installable remote rows for manifest modules with HTTPS package URLs.
     - Side effects:
       - performs a network request
       - updates the in-memory and disk catalog cache for the source
     - Failure modes:
       - throws `ModuleRepositoryError.invalidURL` when the source has no usable manifest URL
       - throws `ModuleRepositoryError.downloadFailed` for non-200 manifest responses
       - propagates JSON decoding failures for malformed manifests
     */
    private func refreshMyBibleCatalog(for source: SourceConfig) async throws -> [RemoteModuleInfo] {
        guard let manifestURL = source.manifestURL else {
            throw ModuleRepositoryError.invalidURL(source.name)
        }

        let (data, response) = try await session.data(from: manifestURL)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ModuleRepositoryError.downloadFailed(
                "MyBible manifest from \(source.name) failed (HTTP \(code))"
            )
        }

        let manifest = try JSONDecoder().decode(MyBibleRepositoryManifest.self, from: data)
        let entries = manifest.modules.compactMap { module -> CatalogModule? in
            let normalizedDownloadURL = Self.normalizedMyBibleDownloadURL(module.downloadURL)
            guard let downloadURL = normalizedDownloadURL else { return nil }
            let languageCode = module.languageCode.trimmingCharacters(in: .whitespacesAndNewlines)

            return CatalogModule(
                name: Self.myBibleModuleInitials(fileName: module.fileName),
                description: module.description,
                category: Self.myBibleCategory(fileName: module.fileName),
                language: languageCode.isEmpty
                    ? "en"
                    : languageCode,
                modDrv: "",
                dataPath: "",
                confContent: "",
                sourceName: source.name,
                version: module.updateDate,
                size: "",
                repositoryType: SourceConfig.myBibleHTTPSRepositoryType,
                downloadURL: downloadURL,
                packageFileName: module.fileName
            )
        }

        setCachedCatalogEntries(entries, for: source.name)
        saveCatalogToDisk(sourceName: source.name, entries: entries)

        return entries.map(\.remoteModuleInfo)
    }

    /**
     Normalizes Android MyBible module download URLs while preserving HTTPS-only behavior.

     Android rewrites cached `http://` MyBible module URLs to HTTPS before exposing module rows.
     iOS mirrors that compatibility path, then drops rows that still cannot produce an HTTPS URL.

     - Parameter rawURL: Manifest `download_url` value.
     - Returns: HTTPS URL suitable for package download, or `nil` when the row is unsupported.
     - Side effects: none.
     - Failure modes: malformed URLs are skipped.
     */
    private static func normalizedMyBibleDownloadURL(_ rawURL: String) -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let httpsString = trimmed.hasPrefix("http://")
            ? "https://" + String(trimmed.dropFirst("http://".count))
            : trimmed
        guard let url = URL(string: String(httpsString)),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    /**
     Builds Android-compatible MyBible module initials from a package filename.

     - Parameter fileName: Manifest `file_name`, usually a `.SQLite3.zip` package.
     - Returns: Initials prefixed with `MyBible-` and sanitized for local identifiers.
     - Side effects: none.
     - Failure modes: empty filenames collapse to `MyBible-module`.
     */
    private static func myBibleModuleInitials(fileName: String) -> String {
        let base = ((fileName as NSString).deletingPathExtension as NSString).lastPathComponent
        let fallback = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "module" : base
        return "MyBible-" + sanitizeMyBibleModuleName(fallback)
    }

    /**
     Maps Android MyBible filename conventions to common module categories.

     - Parameter fileName: Manifest package filename.
     - Returns: Commentaries for `.commentaries`, dictionaries for `.dictionaries`, otherwise Bible.
     - Side effects: none.
     - Failure modes: unknown filename families intentionally fall back to Bible, matching Android's
       default category behavior.
     */
    private static func myBibleCategory(fileName: String) -> ModuleCategory {
        let lowercased = fileName.lowercased()
        if lowercased.contains(".commentaries") {
            return .commentary
        }
        if lowercased.contains(".dictionaries") {
            return .dictionary
        }
        return .bible
    }

    /**
     Sanitizes MyBible package basenames using Android's identifier policy.

     - Parameter name: Package basename without its outer archive extension.
     - Returns: ASCII alphanumerics preserved and every other scalar replaced with `_`.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func sanitizeMyBibleModuleName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(name.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
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

        if source.isMyBibleRepository || entry.repositoryType == SourceConfig.myBibleHTTPSRepositoryType {
            try await installMyBibleModule(entry, progress: progress)
            return
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
        let moduleDataPath = moduleDataDirectoryPath(for: entry.dataPath, driver: driver)
        let localDir = (swordPath as NSString).appendingPathComponent(moduleDataPath)
        let remoteBase = moduleDataPath
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
        let fileGroups = moduleFileGroups(
            for: entry.modDrv,
            dataPath: entry.dataPath,
            confContent: entry.confContent
        )

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
                    if statusError.statusCode == 404 {
                        let installedFromPackage = try await installModulePackageFallback(
                            named: moduleName,
                            entry: entry,
                            source: source,
                            localDirURL: localDirURL,
                            progress: progress
                        )
                        if installedFromPackage {
                            return
                        }
                    }
                    throw ModuleRepositoryError.downloadFailed(statusError.localizedDescription)
                } catch {
                    logger.warning("Download failed for \(fileName): \(error.localizedDescription)")
                    throw error
                }
            }
        }

        guard stagedFileCount > 0 else {
            let installedFromPackage = try await installModulePackageFallback(
                named: moduleName,
                entry: entry,
                source: source,
                localDirURL: localDirURL,
                progress: progress
            )
            if installedFromPackage {
                return
            }
            throw ModuleRepositoryError.downloadFailed("No module data files were available for \(moduleName)")
        }
        try Task.checkCancellation()

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
                if delegate.start(task: task, continuation: continuation) {
                    task.resume()
                }
            }
        } onCancel: {
            delegate.cancel()
        }

        try Task.checkCancellation()
    }

    /**
     Installs one Android-compatible MyBible ZIP package into the local MyBible module store.

     - Parameters:
       - entry: Catalog row produced from a MyBible manifest.
       - progress: Optional normalized progress callback shared with the Downloads row.
     - Side effects:
       - downloads the MyBible ZIP package to a temporary file
       - streams readable MyBible SQLite payloads into a staged directory
       - writes installed-module metadata beside the extracted payload
       - atomically replaces any previous install for the same MyBible module initials
     - Throws:
       - `ModuleRepositoryError.invalidURL` when the manifest row has no HTTPS package URL
       - `ModuleRepositoryError.invalidZip` when the package is empty or lacks a MyBible payload
       - `CancellationError` when the surrounding task is cancelled
       - file-system errors from staging or publishing the package
     */
    private func installMyBibleModule(
        _ entry: CatalogModule,
        progress: ((Double) -> Void)?
    ) async throws {
        guard let downloadURL = entry.downloadURL else {
            throw ModuleRepositoryError.invalidURL(entry.name)
        }

        let fm = FileManager.default
        let packageDownloadURL = fm.temporaryDirectory
            .appendingPathComponent("\(entry.name)-\(UUID().uuidString).zip")
        defer {
            try? fm.removeItem(at: packageDownloadURL)
        }

        try await downloadRequiredModuleFile(
            from: downloadURL,
            to: packageDownloadURL,
            fileName: downloadURL.lastPathComponent,
            completedFiles: 0,
            totalFiles: 1,
            progress: progress
        )

        try Task.checkCancellation()
        let stagingDirURL = myBibleInstallDir
            .appendingPathComponent(".\(entry.name)-\(UUID().uuidString).installing", isDirectory: true)
        try fm.createDirectory(at: stagingDirURL, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: stagingDirURL)
        }

        let extractionResult = try extractMyBiblePackagePayloads(
            from: packageDownloadURL,
            to: stagingDirURL,
            packageFileName: entry.packageFileName
        )
        guard extractionResult.entryCount > 0 else {
            throw ModuleRepositoryError.invalidZip("\(downloadURL.lastPathComponent) is empty")
        }

        guard extractionResult.payloadCount > 0 else {
            throw ModuleRepositoryError.invalidZip(
                "\(downloadURL.lastPathComponent) did not contain a MyBible SQLite payload"
            )
        }

        let metadata = InstalledMyBibleModule(
            name: entry.name,
            description: entry.description,
            category: entry.category.rawValue,
            language: entry.language,
            version: entry.version,
            sourceName: entry.sourceName,
            packageFileName: entry.packageFileName ?? downloadURL.lastPathComponent,
            downloadURL: downloadURL.absoluteString,
            installedAt: Date()
        )
        let metadataData = try JSONEncoder().encode(metadata)
        try metadataData.write(
            to: stagingDirURL.appendingPathComponent("module.json"),
            options: .atomic
        )

        try Task.checkCancellation()
        try commitStagedMyBibleInstall(stagingDirURL: stagingDirURL, moduleName: entry.name)
        progress?(1.0)
    }

    /**
     Counts ZIP entries inspected and MyBible payloads published during file-backed extraction.

     The installer needs both values so empty archives keep their specific error while archives
     that only contain unsupported or unsafe entries report the more useful "no MyBible payload"
     failure.
     */
    private struct MyBiblePackageExtractionResult {
        /// Number of ZIP file entries discovered in the package.
        let entryCount: Int

        /// Number of normalized MyBible payload files written into staging.
        let payloadCount: Int
    }

    /**
     Describes one ZIP entry whose compressed payload remains in the package file.

     - Note: Sizes and offsets come from the central directory when available, or from a local
       header fallback for stream-style archives. The actual entry bytes are read only when the
       MyBible payload name passes normalization.
     */
    private struct FileBackedZipEntry {
        /// Entry path as recorded in the ZIP metadata.
        let name: String

        /// Compression method from ZIP metadata: 0 for stored, 8 for raw deflate.
        let compressionMethod: UInt16

        /// General-purpose flags; encrypted and data-descriptor-only local entries need special handling.
        let generalPurposeFlags: UInt16

        /// Compressed byte count for the entry payload.
        let compressedSize: UInt64

        /// Uncompressed byte count advertised by ZIP metadata.
        let uncompressedSize: UInt64

        /// Offset of the entry's local file header in the package file.
        let localHeaderOffset: UInt64
    }

    /**
     Extracts safe MyBible SQLite payload entries from a downloaded package without loading it all.

     - Parameters:
       - zipURL: Temporary package file produced by `downloadRequiredModuleFile`.
       - stagingDirURL: Empty installation staging directory for the module.
       - packageFileName: Manifest package name used to accept legacy payloads without an extension.
     - Returns: Counts for total entries inspected and MyBible payload files written.
     - Side effects: reads ZIP metadata from `zipURL` and writes matching payload files into
       `stagingDirURL`.
     - Throws: `ModuleRepositoryError.invalidZip` for malformed ZIP structure, unsupported
       encrypted payloads, or unsupported ZIP64 entries; `ModuleRepositoryError.decompressionFailed`
       when zlib cannot inflate a deflated payload; file-system errors from staging writes; and
       `CancellationError` when the install task is cancelled between entries.
     */
    private func extractMyBiblePackagePayloads(
        from zipURL: URL,
        to stagingDirURL: URL,
        packageFileName: String?
    ) throws -> MyBiblePackageExtractionResult {
        let entries = try readFileBackedZipEntries(from: zipURL)
        let fm = FileManager.default
        var payloadCount = 0

        for entry in entries {
            try Task.checkCancellation()
            guard let fileName = Self.normalizedMyBiblePackageEntryName(
                entry.name,
                packageFileName: packageFileName
            ) else {
                continue
            }

            guard entry.generalPurposeFlags & 0x0001 == 0 else {
                throw ModuleRepositoryError.invalidZip("Encrypted ZIP entries are not supported")
            }

            let destinationURL = stagingDirURL.appendingPathComponent(fileName)
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }

            do {
                switch entry.compressionMethod {
                case 0:
                    try copyStoredZipEntry(entry, from: zipURL, to: destinationURL)
                case 8:
                    try inflateDeflatedZipEntry(entry, from: zipURL, to: destinationURL)
                default:
                    continue
                }
                payloadCount += 1
            } catch {
                try? fm.removeItem(at: destinationURL)
                throw error
            }
        }

        return MyBiblePackageExtractionResult(entryCount: entries.count, payloadCount: payloadCount)
    }

    /**
     Copies one stored ZIP payload from the package file to staging in bounded chunks.

     - Parameters:
       - entry: ZIP entry metadata whose compression method is stored.
       - zipURL: Package file containing the payload.
       - destinationURL: Staged payload path to create.
     - Side effects: creates and writes `destinationURL`; reads the source package through
       `FileHandle`.
     - Throws: `ModuleRepositoryError.invalidZip` when the local header or payload range is
       truncated, plus file-system errors from opening, reading, writing, or closing files.
     */
    private func copyStoredZipEntry(
        _ entry: FileBackedZipEntry,
        from zipURL: URL,
        to destinationURL: URL
    ) throws {
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer {
            try? handle.close()
        }
        let fileSize = try handle.seekToEnd()
        let dataOffset = try zipEntryDataOffset(entry, in: handle, fileSize: fileSize)

        _ = FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: destinationURL)
        do {
            try handle.seek(toOffset: dataOffset)
            var remaining = entry.compressedSize
            while remaining > 0 {
                try Task.checkCancellation()
                let chunkSize = Int(min(remaining, UInt64(64 * 1024)))
                guard let chunk = try handle.read(upToCount: chunkSize),
                      !chunk.isEmpty else {
                    throw ModuleRepositoryError.invalidZip("Truncated stored ZIP entry")
                }
                try output.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
    }

    /**
     Inflates one raw-deflate ZIP payload directly from the package file into staging.

     - Parameters:
       - entry: ZIP entry metadata whose compression method is deflated.
       - zipURL: Package file containing the compressed payload.
       - destinationURL: Staged payload path to create.
     - Side effects: invokes the C zlib bridge to read `zipURL` and write `destinationURL`.
     - Throws: `ModuleRepositoryError.invalidZip` when the payload range is outside the package,
       `ModuleRepositoryError.decompressionFailed` when zlib rejects the deflate stream or writes
       the wrong byte count, plus file-system errors from checking the staged file.
     */
    private func inflateDeflatedZipEntry(
        _ entry: FileBackedZipEntry,
        from zipURL: URL,
        to destinationURL: URL
    ) throws {
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer {
            try? handle.close()
        }
        let fileSize = try handle.seekToEnd()
        let dataOffset = try zipEntryDataOffset(entry, in: handle, fileSize: fileSize)

        guard dataOffset <= UInt64(UInt.max),
              entry.compressedSize <= UInt64(UInt.max) else {
            throw ModuleRepositoryError.invalidZip("ZIP entry is too large")
        }

        let result = zipURL.withUnsafeFileSystemRepresentation { inputPath in
            destinationURL.withUnsafeFileSystemRepresentation { outputPath in
                guard let inputPath, let outputPath else {
                    return Int32(-1)
                }
                return inflate_raw_file_range_to_file(
                    inputPath,
                    UInt(dataOffset),
                    UInt(entry.compressedSize),
                    outputPath
                )
            }
        }
        guard result == 0 else {
            throw ModuleRepositoryError.decompressionFailed
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
        guard let writtenSize = (attributes[.size] as? NSNumber)?.uint64Value,
              writtenSize == entry.uncompressedSize else {
            throw ModuleRepositoryError.decompressionFailed
        }
    }

    /**
     Normalizes one ZIP entry from a MyBible package to a safe local payload filename.

     - Parameters:
       - path: ZIP entry path.
       - packageFileName: Manifest package filename used to identify expected payload names.
     - Returns: A flat filename to write into the module directory, or `nil` for unsupported or
       unsafe entries.
     - Side effects: none.
     - Failure modes: unsafe paths are skipped rather than failing unrelated package contents.
     */
    private static func normalizedMyBiblePackageEntryName(
        _ path: String,
        packageFileName: String?
    ) -> String? {
        var relativePath = path.replacingOccurrences(of: "\\", with: "/")
        while relativePath.hasPrefix("./") {
            relativePath = String(relativePath.dropFirst(2))
        }
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/") else {
            return nil
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." || $0.isEmpty }),
              let fileName = components.last.map(String.init) else {
            return nil
        }

        let lowercasedFileName = fileName.lowercased()
        if lowercasedFileName.hasSuffix(".sqlite3") || lowercasedFileName.hasSuffix(".mybible") {
            return fileName
        }

        let expectedPayloadName = packageFileName.flatMap { packageFileName -> String? in
            let payloadName = (packageFileName as NSString).deletingPathExtension
            return payloadName.isEmpty ? nil : payloadName
        }
        if let expectedPayloadName, fileName == expectedPayloadName {
            return fileName
        }

        return nil
    }

    /**
     Atomically publishes a staged MyBible module directory with rollback protection.

     - Parameters:
       - stagingDirURL: Directory containing extracted MyBible payload and sidecar metadata.
       - moduleName: MyBible module initials used as the final directory name.
     - Side effects:
       - moves any existing install to a backup directory
       - moves the staging directory into the final MyBible install location
       - removes the backup after a successful publish
     - Failure modes:
       - restores the previous directory on publish failure, then rethrows the original error.
     */
    private func commitStagedMyBibleInstall(stagingDirURL: URL, moduleName: String) throws {
        let fm = FileManager.default
        let finalDirURL = myBibleInstallDir.appendingPathComponent(moduleName, isDirectory: true)
        let backupDirURL = myBibleInstallDir
            .appendingPathComponent(".\(moduleName)-\(UUID().uuidString).backup", isDirectory: true)
        var movedExisting = false

        do {
            if fm.fileExists(atPath: finalDirURL.path) {
                try fm.moveItem(at: finalDirURL, to: backupDirURL)
                movedExisting = true
            }

            try fm.moveItem(at: stagingDirURL, to: finalDirURL)

            if movedExisting {
                try? fm.removeItem(at: backupDirURL)
            }
        } catch {
            if movedExisting {
                try? fm.removeItem(at: finalDirURL)
                try? fm.moveItem(at: backupDirURL, to: finalDirURL)
            }
            throw error
        }
    }

    /**
     Installs a module from a repository ZIP package when raw data-file probing cannot find usable
     files.

     Android's installer can use package directories such as `zip/` or `packages/rawzip/` for
     repositories that do not expose raw module data files. The Swift installer first tries raw file
     paths so it can preserve streaming progress, then calls this fallback only when no module data
     has been staged.

     - Parameters:
       - moduleName: Catalog module abbreviation whose package should be downloaded.
       - entry: Parsed catalog entry providing `DataPath`, `ModDrv`, and `.conf` content.
       - source: Repository source used to derive package ZIP candidate URLs.
       - localDirURL: Final module data directory that will receive the extracted package data.
       - progress: Optional normalized progress callback shared with the caller.
     - Returns: `true` when a candidate package was downloaded, extracted, and committed; `false`
       when no package candidate was available.
     - Side effects:
       - downloads a candidate ZIP into a temporary file
       - extracts only `modules/` entries into a temporary staging tree
       - commits the staged module data and catalog `.conf` through the rollback-safe publish path
       - invalidates SWORD's module cache after a successful package install
     - Throws:
       - `CancellationError` when the surrounding task is cancelled
       - `ModuleRepositoryError.invalidZip` when a downloaded candidate is malformed or lacks the
         catalog data directory
       - file-system errors from temporary extraction or final publish
     */
    private func installModulePackageFallback(
        named moduleName: String,
        entry: CatalogModule,
        source: SourceConfig,
        localDirURL: URL,
        progress: ((Double) -> Void)?
    ) async throws -> Bool {
        let candidates = packageZipCandidateURLs(for: moduleName, source: source)
        guard !candidates.isEmpty else { return false }

        let fm = FileManager.default
        let packageDownloadURL = fm.temporaryDirectory
            .appendingPathComponent("\(moduleName)-\(UUID().uuidString).zip")
        defer {
            try? fm.removeItem(at: packageDownloadURL)
        }

        var downloadedPackageURL: URL?
        for candidate in candidates {
            try Task.checkCancellation()
            do {
                logger.info("Trying package fallback \(candidate.absoluteString)")
                try await downloadRequiredModuleFile(
                    from: candidate,
                    to: packageDownloadURL,
                    fileName: candidate.lastPathComponent,
                    completedFiles: 0,
                    totalFiles: 1,
                    progress: progress
                )
                downloadedPackageURL = candidate
                break
            } catch let statusError as ModuleFileHTTPStatusError where statusError.statusCode == 404 {
                logger.info("Skipping missing package fallback \(candidate.absoluteString)")
                try? fm.removeItem(at: packageDownloadURL)
            }
        }

        guard let downloadedPackageURL else { return false }

        let zipData = try Data(contentsOf: packageDownloadURL)
        let entries = try parseZip(zipData)
        guard !entries.isEmpty else {
            throw ModuleRepositoryError.invalidZip("\(downloadedPackageURL.lastPathComponent) is empty")
        }

        let moduleDataPath = moduleDataDirectoryPath(for: entry.dataPath, driver: entry.modDrv)
        let extractionRootURL = fm.temporaryDirectory
            .appendingPathComponent("\(moduleName)-\(UUID().uuidString).package", isDirectory: true)
        try fm.createDirectory(at: extractionRootURL, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: extractionRootURL)
        }

        let dataPathPrefix = moduleDataPath.hasSuffix("/") ? moduleDataPath : "\(moduleDataPath)/"
        var extractedDataFileCount = 0

        for entry in entries {
            try Task.checkCancellation()
            guard let relativePath = normalizedSwordPackageEntryPath(entry.name),
                  relativePath.hasPrefix(dataPathPrefix) else {
                continue
            }

            let destinationURL = extractionRootURL.appendingPathComponent(relativePath)
            try fm.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try entry.data.write(to: destinationURL)
            extractedDataFileCount += 1
        }

        let stagedDataDirURL = extractionRootURL.appendingPathComponent(moduleDataPath, isDirectory: true)
        guard extractedDataFileCount > 0,
              fm.fileExists(atPath: stagedDataDirURL.path) else {
            throw ModuleRepositoryError.invalidZip(
                "\(downloadedPackageURL.lastPathComponent) did not contain \(moduleDataPath)"
            )
        }

        try Task.checkCancellation()
        try commitStagedModuleInstall(
            stagingDirURL: stagedDataDirURL,
            localDirURL: localDirURL,
            moduleName: moduleName,
            confContent: entry.confContent
        )
        invalidateModuleCache()
        progress?(1.0)
        return true
    }

    /**
     Builds repository package ZIP candidates that match Android/SWORD repository layouts.

     - Parameters:
       - moduleName: Catalog module abbreviation used as the package filename.
       - source: Repository source whose host and catalog path anchor package locations.
     - Returns: De-duplicated HTTPS URLs, ordered from source-local packages to CrossWire-style
       parent `packages/rawzip` locations.
     - Side effects: none.
     - Failure modes: malformed host/path combinations are skipped rather than thrown because raw
       file installation remains the primary path.
     */
    private func packageZipCandidateURLs(for moduleName: String, source: SourceConfig) -> [URL] {
        let packageFileName = "\(moduleName).zip"
        var paths: [String] = []
        if let androidPackageDirectory = androidPackageDirectory(for: source) {
            paths.append(appendingPathComponent(packageFileName, toPath: androidPackageDirectory))
        }
        paths += [
            appendingPathComponent("zip/\(packageFileName)", toPath: source.catalogPath),
            appendingPathComponent("packages/\(packageFileName)", toPath: source.catalogPath),
            appendingPathComponent("packages/rawzip/\(packageFileName)", toPath: source.catalogPath)
        ]

        if let rawParentPath = parentPathForRawPackageDirectory(source.catalogPath) {
            paths.append(appendingPathComponent("packages/rawzip/\(packageFileName)", toPath: rawParentPath))
        }

        var seen = Set<String>()
        return paths.compactMap { path in
            guard let url = URL(string: "https://\(source.host)\(path)") else { return nil }
            guard seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    /**
     Returns the Android-parity package directory for known default SWORD repositories.

     Android keeps package and catalog directories as distinct repository fields. iOS persists only
     the catalog-style `HTTPSource` row today, so default sources need an explicit package-directory
     map to avoid guessing wrong locations for repositories such as STEP, IBT, Wycliffe, and
     Lockman.

     - Parameter source: Repository source loaded from `InstallMgr.conf`.
     - Returns: Package directory path from Android's `repositories.txt` when the source matches a
       built-in repository, otherwise the direct-catalog custom fallback `catalogPath/packages`.
     - Side effects: none.
     - Failure modes: none.
     */
    private func androidPackageDirectory(for source: SourceConfig) -> String? {
        if let packageDirectory = source.packageDirectory,
           !packageDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return packageDirectory
        }

        switch (source.name, source.host, source.catalogPath) {
        case ("CrossWire", "crosswire.org", "/ftpmirror/pub/sword/raw"):
            return "/ftpmirror/pub/sword/packages/rawzip"
        case ("Crosswire Beta", "crosswire.org", "/ftpmirror/pub/sword/betaraw"):
            return "/ftpmirror/pub/sword/betapackages/rawzip"
        case ("AndBible Extra", "andbible.github.io", "/andbible-extra"):
            return "/andbible-extra/zip"
        case ("AndBible", "andbible.github.io", "/data/andbible"):
            return "/data/andbible/zip"
        case ("AndBible Beta", "andbible.github.io", "/data/andbible/beta"):
            return "/data/andbible/beta/zip"
        case ("IBT", "ibtrussia.org", "/ftpmirror/pub/modsword/raw"):
            return "/ftpmirror/pub/modsword/rawzip"
        case ("Wycliffe (CrossWire)", "crosswire.org", "/ftpmirror/pub/sword/wyclifferaw"):
            return "/ftpmirror/pub/sword/wycliffepackages/rawzip"
        case ("eBible", "ebible.org", "/sword"):
            return "/sword/zip"
        case ("Lockman (CrossWire)", "crosswire.org", "/ftpmirror/pub/sword/lockmanraw"):
            return "/ftpmirror/pub/sword/lockmanpackages"
        case ("STEP Bible (Tyndale)", "public.modules.stepbible.org", "/catalog"):
            return "/packages"
        default:
            return appendingPathComponent("packages", toPath: source.catalogPath)
        }
    }

    /**
     Resolves the parent repository path whose `packages/rawzip/` directory pairs with a raw data
     catalog.

     - Parameter catalogPath: Source catalog path from `InstallMgr.conf`.
     - Returns: The parent path when the final path component is a raw catalog directory, otherwise
       `nil`.
     - Side effects: none.
     - Failure modes: none.
     */
    private func parentPathForRawPackageDirectory(_ catalogPath: String) -> String? {
        let trimmedPath = catalogPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = trimmedPath.split(separator: "/").map(String.init)
        guard let lastComponent = components.last,
              lastComponent.lowercased().contains("raw") else {
            return nil
        }

        let parentComponents = components.dropLast()
        return "/" + parentComponents.joined(separator: "/")
    }

    /**
     Appends a relative component to a repository path without requiring URL filesystem semantics.

     - Parameters:
       - component: Relative path component or subpath to append.
       - path: Absolute repository path beginning with `/`.
     - Returns: A normalized absolute path with exactly one separator between `path` and
       `component`.
     - Side effects: none.
     - Failure modes: none.
     */
    private func appendingPathComponent(_ component: String, toPath path: String) -> String {
        let basePath = path.hasSuffix("/") ? String(path.dropLast()) : path
        let relativeComponent = component.hasPrefix("/") ? String(component.dropFirst()) : component
        if basePath.isEmpty {
            return "/\(relativeComponent)"
        }
        return "\(basePath)/\(relativeComponent)"
    }

    /**
     Normalizes a SWORD package ZIP entry to a safe path rooted at the local SWORD home.

     - Parameter path: Raw ZIP entry name.
     - Returns: A relative path beginning with `mods.d/` or `modules/`, with any single enclosing
       package folder removed; returns `nil` for absolute paths, traversal paths, directories, or
       unsupported archive entries.
     - Side effects: none.
     - Failure modes: unsafe paths are filtered out instead of throwing so unrelated archive entries
       do not fail an otherwise valid package.
     */
    private func normalizedSwordPackageEntryPath(_ path: String) -> String? {
        var relativePath = path.replacingOccurrences(of: "\\", with: "/")
        while relativePath.hasPrefix("./") {
            relativePath = String(relativePath.dropFirst(2))
        }
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/") else {
            return nil
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." || $0.isEmpty }) else {
            return nil
        }

        let lowercasedPath = relativePath.lowercased()
        if lowercasedPath.hasPrefix("mods.d/") || lowercasedPath.hasPrefix("modules/") {
            return relativePath
        }

        guard let slashIndex = relativePath.firstIndex(of: "/") else { return nil }
        let nestedPath = String(relativePath[relativePath.index(after: slashIndex)...])
        let lowercasedNestedPath = nestedPath.lowercased()
        guard lowercasedNestedPath.hasPrefix("mods.d/")
            || lowercasedNestedPath.hasPrefix("modules/") else {
            return nil
        }
        return nestedPath
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

    /**
     Loads installed MyBible module metadata from the local non-SWORD module store.

     - Returns: Installed MyBible modules as common `ModuleInfo` rows for Downloads state.
     - Side effects:
       - creates the MyBible install directory if needed
       - reads `module.json` sidecars from installed MyBible module directories
     - Failure modes:
       - unreadable or malformed sidecars are logged and skipped so one bad install cannot hide the
       rest of the Downloads list.
     */
    public func loadInstalledMyBibleModules() -> [ModuleInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: myBibleInstallDir,
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
            do {
                let data = try Data(contentsOf: metadataURL)
                return try JSONDecoder().decode(InstalledMyBibleModule.self, from: data).moduleInfo
            } catch {
                logger.warning("Failed to load MyBible install metadata \(metadataURL.path): \(error.localizedDescription)")
                return nil
            }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /**
     Uninstalls either a MyBible sidecar module or a SWORD module by name.

     MyBible modules are removed from the non-SWORD install store only when their `module.json`
     sidecar is present. Other names follow the existing SWORD uninstall path, which deletes data
     and config files and invalidates SWORD's module cache.

     - Parameter moduleName: Installed module initials to remove.
     - Side effects: deletes module files and may invalidate SWORD's module cache.
     - Throws: file-system errors when deletion fails; SWORD lookup failures surface as
       `ModuleRepositoryError.moduleNotFound`.
     */
    public func uninstallModule(named moduleName: String) throws {
        if try uninstallMyBibleModuleIfPresent(named: moduleName) {
            return
        }

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

    /**
     Removes one installed MyBible module directory when it has a valid sidecar marker.

     - Parameter moduleName: MyBible module initials to remove.
     - Returns: `true` when a MyBible install was found and removed, otherwise `false`.
     - Side effects: deletes the installed MyBible module directory.
     - Failure modes: propagates file-system deletion errors.
     */
    private func uninstallMyBibleModuleIfPresent(named moduleName: String) throws -> Bool {
        let moduleDirURL = myBibleInstallDir.appendingPathComponent(moduleName, isDirectory: true)
        let metadataURL = moduleDirURL.appendingPathComponent("module.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return false
        }
        try FileManager.default.removeItem(at: moduleDirURL)
        return true
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

    /**
     Reads ZIP metadata from disk while leaving compressed payload bytes in the package file.

     - Parameter zipURL: Package file to inspect.
     - Returns: File-backed ZIP entries in archive order, or an empty list for an empty archive.
     - Side effects: opens, seeks, and reads `zipURL`; no payload file data is decompressed here.
     - Throws: `ModuleRepositoryError.invalidZip` when central-directory or local-header metadata
       is malformed, truncated, spans multiple disks, uses unsupported ZIP64 fields, or requires a
       data descriptor without a central directory.
     */
    private func readFileBackedZipEntries(from zipURL: URL) throws -> [FileBackedZipEntry] {
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer {
            try? handle.close()
        }

        let fileSize = try handle.seekToEnd()
        if let centralDirectoryEntries = try readZipCentralDirectoryEntries(
            from: handle,
            fileSize: fileSize
        ) {
            return centralDirectoryEntries
        }
        return try readLocalZipEntries(from: handle, fileSize: fileSize)
    }

    /**
     Parses the ZIP central directory when the archive has a standard end record.

     - Parameters:
       - handle: Open package file handle, owned by the caller.
       - fileSize: Total package byte count.
     - Returns: Central-directory entries, or `nil` when no end-of-central-directory record exists
       so callers can use the local-header streaming fallback.
     - Side effects: seeks and reads `handle`.
     - Throws: `ModuleRepositoryError.invalidZip` when central-directory metadata is truncated,
       inconsistent, multi-disk, or ZIP64-only.
     */
    private func readZipCentralDirectoryEntries(
        from handle: FileHandle,
        fileSize: UInt64
    ) throws -> [FileBackedZipEntry]? {
        let minimumEndRecordSize = 22
        guard fileSize >= UInt64(minimumEndRecordSize) else {
            return nil
        }

        let searchLength = min(fileSize, UInt64(minimumEndRecordSize + 0xffff))
        let tail = try readZipBytes(
            from: handle,
            offset: fileSize - searchLength,
            count: Int(searchLength)
        )

        var endRecordOffset: Int?
        var candidateOffset = tail.count - minimumEndRecordSize
        while candidateOffset >= 0 {
            if tail[candidateOffset] == 0x50,
               tail[candidateOffset + 1] == 0x4b,
               tail[candidateOffset + 2] == 0x05,
               tail[candidateOffset + 3] == 0x06 {
                let commentLength = Int(readUInt16(tail, at: candidateOffset + 20))
                if candidateOffset + minimumEndRecordSize + commentLength == tail.count {
                    endRecordOffset = candidateOffset
                    break
                }
            }

            if candidateOffset == 0 {
                break
            }
            candidateOffset -= 1
        }

        guard let endRecordOffset else {
            return nil
        }

        let diskNumber = readUInt16(tail, at: endRecordOffset + 4)
        let centralDirectoryDisk = readUInt16(tail, at: endRecordOffset + 6)
        let entriesOnDisk = readUInt16(tail, at: endRecordOffset + 8)
        let totalEntries = readUInt16(tail, at: endRecordOffset + 10)
        let centralDirectorySize32 = readUInt32(tail, at: endRecordOffset + 12)
        let centralDirectoryOffset32 = readUInt32(tail, at: endRecordOffset + 16)

        guard diskNumber == 0,
              centralDirectoryDisk == 0,
              entriesOnDisk == totalEntries else {
            throw ModuleRepositoryError.invalidZip("Multi-disk ZIP packages are not supported")
        }
        guard totalEntries != UInt16.max,
              centralDirectorySize32 != UInt32.max,
              centralDirectoryOffset32 != UInt32.max else {
            throw ModuleRepositoryError.invalidZip("ZIP64 MyBible packages are not supported")
        }

        let centralDirectorySize = UInt64(centralDirectorySize32)
        let centralDirectoryOffset = UInt64(centralDirectoryOffset32)
        guard centralDirectoryOffset <= fileSize,
              centralDirectorySize <= fileSize - centralDirectoryOffset else {
            throw ModuleRepositoryError.invalidZip("Truncated ZIP central directory")
        }
        guard centralDirectorySize <= UInt64(Int.max) else {
            throw ModuleRepositoryError.invalidZip("ZIP central directory is too large")
        }
        guard centralDirectorySize > 0 else {
            guard totalEntries == 0 else {
                throw ModuleRepositoryError.invalidZip("ZIP central directory entry count mismatch")
            }
            return []
        }

        let centralDirectory = try readZipBytes(
            from: handle,
            offset: centralDirectoryOffset,
            count: Int(centralDirectorySize)
        )
        var entries: [FileBackedZipEntry] = []
        var offset = 0

        while offset < centralDirectory.count {
            guard offset + 46 <= centralDirectory.count else {
                throw ModuleRepositoryError.invalidZip("Truncated ZIP central directory entry")
            }
            guard centralDirectory[offset] == 0x50,
                  centralDirectory[offset + 1] == 0x4b,
                  centralDirectory[offset + 2] == 0x01,
                  centralDirectory[offset + 3] == 0x02 else {
                throw ModuleRepositoryError.invalidZip("Malformed ZIP central directory")
            }

            let generalPurposeFlags = readUInt16(centralDirectory, at: offset + 8)
            let compressionMethod = readUInt16(centralDirectory, at: offset + 10)
            let compressedSize32 = readUInt32(centralDirectory, at: offset + 20)
            let uncompressedSize32 = readUInt32(centralDirectory, at: offset + 24)
            let nameLength = Int(readUInt16(centralDirectory, at: offset + 28))
            let extraLength = Int(readUInt16(centralDirectory, at: offset + 30))
            let commentLength = Int(readUInt16(centralDirectory, at: offset + 32))
            let entryDisk = readUInt16(centralDirectory, at: offset + 34)
            let localHeaderOffset32 = readUInt32(centralDirectory, at: offset + 42)
            let nameStart = offset + 46
            let nextOffset = nameStart + nameLength + extraLength + commentLength

            guard nextOffset <= centralDirectory.count else {
                throw ModuleRepositoryError.invalidZip("Truncated ZIP central directory entry")
            }
            guard entryDisk == 0 else {
                throw ModuleRepositoryError.invalidZip("Multi-disk ZIP entries are not supported")
            }
            guard compressedSize32 != UInt32.max,
                  uncompressedSize32 != UInt32.max,
                  localHeaderOffset32 != UInt32.max else {
                throw ModuleRepositoryError.invalidZip("ZIP64 MyBible entries are not supported")
            }

            let nameData = Data(centralDirectory[nameStart..<(nameStart + nameLength)])
            let name = String(data: nameData, encoding: .utf8) ?? ""
            entries.append(FileBackedZipEntry(
                name: name,
                compressionMethod: compressionMethod,
                generalPurposeFlags: generalPurposeFlags,
                compressedSize: UInt64(compressedSize32),
                uncompressedSize: UInt64(uncompressedSize32),
                localHeaderOffset: UInt64(localHeaderOffset32)
            ))
            offset = nextOffset
        }

        guard entries.count == Int(totalEntries) else {
            throw ModuleRepositoryError.invalidZip("ZIP central directory entry count mismatch")
        }
        return entries
    }

    /**
     Parses local ZIP headers for stream-style archives without a central directory.

     - Parameters:
       - handle: Open package file handle, owned by the caller.
       - fileSize: Total package byte count.
     - Returns: File-backed entries whose sizes are available in their local headers.
     - Side effects: seeks and reads `handle`.
     - Throws: `ModuleRepositoryError.invalidZip` when a local header is truncated, ZIP64-sized,
       or depends on a trailing data descriptor that cannot be skipped without central metadata.
     */
    private func readLocalZipEntries(
        from handle: FileHandle,
        fileSize: UInt64
    ) throws -> [FileBackedZipEntry] {
        var entries: [FileBackedZipEntry] = []
        var offset: UInt64 = 0

        while offset + 30 <= fileSize {
            let header = try readZipBytes(from: handle, offset: offset, count: 30)
            guard header[0] == 0x50,
                  header[1] == 0x4b,
                  header[2] == 0x03,
                  header[3] == 0x04 else {
                break
            }

            let generalPurposeFlags = readUInt16(header, at: 6)
            guard generalPurposeFlags & 0x0008 == 0 else {
                throw ModuleRepositoryError.invalidZip(
                    "ZIP entries with data descriptors require a central directory"
                )
            }

            let compressionMethod = readUInt16(header, at: 8)
            let compressedSize32 = readUInt32(header, at: 18)
            let uncompressedSize32 = readUInt32(header, at: 22)
            let nameLength = Int(readUInt16(header, at: 26))
            let extraLength = Int(readUInt16(header, at: 28))
            guard compressedSize32 != UInt32.max,
                  uncompressedSize32 != UInt32.max else {
                throw ModuleRepositoryError.invalidZip("ZIP64 MyBible entries are not supported")
            }

            let metadataLength = UInt64(30 + nameLength + extraLength)
            guard metadataLength <= fileSize - offset else {
                throw ModuleRepositoryError.invalidZip("Truncated ZIP local header")
            }
            let nameData = try readZipBytes(
                from: handle,
                offset: offset + 30,
                count: nameLength
            )
            let dataOffset = offset + metadataLength
            let compressedSize = UInt64(compressedSize32)
            guard compressedSize <= fileSize - dataOffset else {
                throw ModuleRepositoryError.invalidZip("Truncated ZIP payload")
            }

            let name = String(data: nameData, encoding: .utf8) ?? ""
            entries.append(FileBackedZipEntry(
                name: name,
                compressionMethod: compressionMethod,
                generalPurposeFlags: generalPurposeFlags,
                compressedSize: compressedSize,
                uncompressedSize: UInt64(uncompressedSize32),
                localHeaderOffset: offset
            ))
            offset = dataOffset + compressedSize
        }

        return entries
    }

    /**
     Computes the payload offset for an entry by validating its local file header.

     - Parameters:
       - entry: Central-directory or local-header entry metadata.
       - handle: Open package file handle, owned by the caller.
       - fileSize: Total package byte count.
     - Returns: Byte offset where the compressed payload starts.
     - Side effects: seeks and reads `handle`.
     - Throws: `ModuleRepositoryError.invalidZip` when the local header signature, metadata, or
       payload range is inconsistent with the package file.
     */
    private func zipEntryDataOffset(
        _ entry: FileBackedZipEntry,
        in handle: FileHandle,
        fileSize: UInt64
    ) throws -> UInt64 {
        guard entry.localHeaderOffset <= fileSize,
              30 <= fileSize - entry.localHeaderOffset else {
            throw ModuleRepositoryError.invalidZip("Truncated ZIP local header")
        }

        let header = try readZipBytes(from: handle, offset: entry.localHeaderOffset, count: 30)
        guard header[0] == 0x50,
              header[1] == 0x4b,
              header[2] == 0x03,
              header[3] == 0x04 else {
            throw ModuleRepositoryError.invalidZip("Malformed ZIP local header")
        }

        let nameLength = Int(readUInt16(header, at: 26))
        let extraLength = Int(readUInt16(header, at: 28))
        let metadataLength = UInt64(30 + nameLength + extraLength)
        guard metadataLength <= fileSize - entry.localHeaderOffset else {
            throw ModuleRepositoryError.invalidZip("Truncated ZIP local header")
        }

        let dataOffset = entry.localHeaderOffset + metadataLength
        guard entry.compressedSize <= fileSize - dataOffset else {
            throw ModuleRepositoryError.invalidZip("Truncated ZIP payload")
        }
        return dataOffset
    }

    /**
     Reads an exact byte range from a ZIP file handle.

     - Parameters:
       - handle: Open package file handle, owned by the caller.
       - offset: Absolute byte offset to read from.
       - count: Exact number of bytes required.
     - Returns: Data containing exactly `count` bytes.
     - Side effects: seeks and reads `handle`.
     - Throws: `ModuleRepositoryError.invalidZip` when the requested range cannot be read fully,
       plus file-system errors from `FileHandle` seeking or reading.
     */
    private func readZipBytes(
        from handle: FileHandle,
        offset: UInt64,
        count: Int
    ) throws -> Data {
        try handle.seek(toOffset: offset)
        guard count > 0 else {
            return Data()
        }
        guard let data = try handle.read(upToCount: count),
              data.count == count else {
            throw ModuleRepositoryError.invalidZip("Truncated ZIP structure")
        }
        return data
    }

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

    /**
     Reads a little-endian 16-bit integer from ZIP bytes without assuming pointer alignment.

     - Parameters:
       - data: ZIP data buffer.
       - offset: Byte offset of the integer.
     - Returns: Parsed unsigned integer.
     - Side effects: none.
     - Failure modes: callers guarantee bounds before reading local ZIP headers.
     */
    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    /**
     Reads a little-endian 32-bit integer from ZIP bytes without assuming pointer alignment.

     - Parameters:
       - data: ZIP data buffer.
       - offset: Byte offset of the integer.
     - Returns: Parsed unsigned integer.
     - Side effects: none.
     - Failure modes: callers guarantee bounds before reading local ZIP headers.
     */
    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
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
       - confContent: Full `.conf` content used for zCom `BlockType` file extension parity.
     - Returns: Ordered file groups. Optional groups model Android/libsword behavior for
       single-testament verse-keyed modules; required groups remain all-or-nothing.
     - Side effects: none.
     - Failure modes: unknown drivers fall back to optional ztext-style testament groups.
     */
    private func moduleFileGroups(
        for modDrv: String,
        dataPath: String,
        confContent: String
    ) -> [ModuleFileGroup] {
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
            let compressedStem = compressedCommentaryFileStem(from: confContent)
            return [
                ModuleFileGroup(
                    files: ["ot.\(compressedStem)zs", "ot.\(compressedStem)zz", "ot.\(compressedStem)zv"],
                    required: false
                ),
                ModuleFileGroup(
                    files: ["nt.\(compressedStem)zs", "nt.\(compressedStem)zz", "nt.\(compressedStem)zv"],
                    required: false
                )
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

    /**
     Maps zCom `BlockType` metadata to the compressed commentary filename stem.

     - Parameter confContent: Full module `.conf` content from the repository catalog.
     - Returns: `b` for book-block modules or missing metadata, `c` for chapter-block modules,
       and `v` for verse-block modules.
     - Side effects: none.
     - Failure modes: unknown `BlockType` values fall back to book-block filenames because that is
       the historical SWORD default and preserves current behavior for modules without metadata.
     */
    private func compressedCommentaryFileStem(from confContent: String) -> String {
        guard let blockType = confValue(named: "BlockType", in: confContent)?.lowercased() else {
            return "b"
        }

        switch blockType {
        case "chapter":
            return "c"
        case "verse":
            return "v"
        default:
            return "b"
        }
    }

    /**
     Reads one key from a SWORD `.conf` document without requiring the module to be reparsed.

     - Parameters:
       - key: Case-insensitive key name to read.
       - confContent: Full module `.conf` content.
     - Returns: The trimmed key value when present, otherwise `nil`.
     - Side effects: none.
     - Failure modes: malformed lines, comments, and section headers are ignored.
     */
    private func confValue(named key: String, in confContent: String) -> String? {
        for line in confContent.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  !trimmed.hasPrefix("["),
                  let separator = trimmed.firstIndex(of: "=") else {
                continue
            }

            let candidateKey = String(trimmed[..<separator])
                .trimmingCharacters(in: .whitespaces)
            guard candidateKey.caseInsensitiveCompare(key) == .orderedSame else {
                continue
            }

            return String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
        }

        return nil
    }

    /**
     Resolves the directory that contains data files for a module `DataPath`.

     - Parameters:
       - dataPath: Normalized SWORD `DataPath` from the catalog.
       - driver: SWORD module driver name.
     - Returns: A relative path under the SWORD home where data files should be read or written.
     - Side effects: none.
     - Failure modes: none; unknown drivers treat `DataPath` as a directory.
     */
    private func moduleDataDirectoryPath(for dataPath: String, driver: String) -> String {
        var normalizedPath = dataPath
        if normalizedPath.hasPrefix("./") {
            normalizedPath = String(normalizedPath.dropFirst(2))
        }
        while normalizedPath.hasSuffix("/") {
            normalizedPath = String(normalizedPath.dropLast())
        }

        let normalizedDriver = driver.lowercased()
        if ["rawld", "rawld4", "zld", "rawgenbook"].contains(normalizedDriver) {
            return (normalizedPath as NSString).deletingLastPathComponent
        }
        return normalizedPath
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
