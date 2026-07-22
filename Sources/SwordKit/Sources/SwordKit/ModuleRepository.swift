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
 Internal HTTP-status failure used while downloading repository packages.

 Package installers convert this private transport detail into public repository errors. Keeping
 it separate from `ModuleRepositoryError.downloadFailed` preserves the status code until the
 SWORD package loop can decide whether a 404 means candidate unavailability.
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
 Downloads one repository payload with native URLSession streaming and progress callbacks.

 The delegate moves the completed temporary download into the caller's staging path only after a
 200 response. It is separate from `ModuleRepository` so each payload gets an isolated continuation
 and cancellation target.
 */
private final class ModuleFileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Destination inside the caller's temporary or staging directory.
    private let destinationURL: URL

    /// Repository payload name used in failure messages.
    private let fileName: String

    /// Number of files completed before this task began.
    private let completedFiles: Int

    /// Total planned files used to scale progress.
    private let totalFiles: Double

    /// Optional byte-progress callback; `nil` means the response length is indeterminate.
    private let progress: ((Double?) -> Void)?

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
       - progress: Optional byte-progress callback. A `nil` fraction represents an unknown response
         length and is emitted once before the task starts by the repository.
     - Side effects: none until a URLSession task starts delivering callbacks.
     - Failure modes: none.
     */
    init(
        destinationURL: URL,
        fileName: String,
        completedFiles: Int,
        totalFiles: Double,
        progress: ((Double?) -> Void)?
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
     - unknown content length produces no determinate fraction; the caller's pre-download
       indeterminate event remains current until another installer phase starts
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

    /// Optional Android package directory used by SWORD package installs.
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
       - packageDirectory: Optional Android package directory for SWORD package installs.
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
     - Returns: Byte count when the value is an integer byte count; otherwise `nil`.

     Side effects:
     - none

     Failure modes:
     - non-numeric or overflowing values return `nil`
     */
    private static func installSizeBytes(from value: String) -> Int64? {
        Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
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

    /// Shared Android-compatible capacity gate used by remote and local package paths.
    private let storagePreflight: ModuleStoragePreflight

    /// Process-wide, canonical-root transaction publisher shared by every repository instance.
    private let mutationPublisher: ModuleStoreTransactionPublisher

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

    /**
     Creates a repository facade for catalog and package operations.

     - Parameters:
       - basePath: Install-manager metadata/cache directory.
       - swordPath: Destination SWORD home containing `mods.d` and `modules`.
       - session: Optional URL session used by deterministic tests or custom networking.
       - storageCapacityProvider: Optional destination-volume capacity provider. Production reads
         Foundation volume metadata; tests can inject low-space conditions.
     - Side effects: none. Live module roots are created only inside a mutation transaction.
     - Failure modes: none during initialization.
     */
    public init(
        basePath: String? = nil,
        swordPath: String? = nil,
        session: URLSession? = nil,
        storageCapacityProvider: (@Sendable (URL) -> Int64?)? = nil
    ) {
        self.basePath = basePath ?? InstallManager.defaultBasePath()
        let resolvedSwordPath = swordPath ?? SwordManager.defaultModulePath()
        self.swordPath = resolvedSwordPath
        self.storagePreflight = ModuleStoragePreflight(capacityProvider: storageCapacityProvider)
        self.mutationPublisher = ModuleStoreTransactionPublisher(
            moduleRootURL: URL(fileURLWithPath: resolvedSwordPath, isDirectory: true)
        )

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: config)
        }
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
                let cat = ModuleCategory(typeString: m.category, modDrv: m.modDrv)
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
     Installs one remote SWORD module from Android's repository package ZIP.

     Android's Downloads path gives JSword a package directory and installs the selected module as
     a ZIP. iOS mirrors that remote-install contract instead of probing raw SWORD data files, so
     transient missing raw files cannot publish partial Bible or commentary data.

     - Parameters:
       - moduleName: Module abbreviation from the refreshed catalog, such as `KJV`.
       - source: Remote source whose in-memory catalog entry supplies package metadata and module
         layout.
       - progress: Optional callback receiving normalized completion in the range `0.0...1.0`.
     - Side effects:
       - downloads a package ZIP to a temporary file
       - extracts matching module data into a temporary staging directory
       - replaces the target module directory only after package extraction succeeds
       - writes the module `.conf` file only after staged data is ready to publish
       - invalidates SWORD's module cache after a successful install
     - Throws:
       - `ModuleRepositoryError.moduleNotFound` when the source catalog does not contain the module
       - `ModuleRepositoryError.invalidURL` when the source cannot produce a base URL
       - `ModuleRepositoryError.downloadFailed` when no package URL can be built or every package
         candidate is unavailable
       - `ModuleRepositoryError.invalidZip` when a downloaded package is malformed or does not
         contain the catalog module data path
       - `CancellationError` when the surrounding task is cancelled before the install completes
       - file-system errors from directory creation, data writes, or config writes
     - Important: The `.conf` file is the installed marker consumed by `SwordManager`, and updates
       may already have an installed marker. Data files are therefore staged and swapped with a
       rollback path so failed or cancelled installs do not corrupt an existing module.
     */
    public func installModule(named moduleName: String, from source: SourceConfig,
                              progress: ((Double) -> Void)? = nil) async throws {
        try await installModule(named: moduleName, from: source, progressState: { state in
            guard let progress,
                  let legacyFraction = Self.legacyOverallProgress(for: state) else {
                return
            }
            progress(legacyFraction)
        })
    }

    /**
     Installs one remote module while reporting durable Android-style job phases.

     - Parameters:
       - moduleName: Module initials from the selected catalog row.
       - source: Exact repository row that supplied the module.
       - progressState: Optional phase-aware progress observer. Download fractions are
         indeterminate when the server omits `Content-Length`; `.complete` is emitted only after
         publish and cache invalidation.
     - Side effects: Performs the same network, staging, publish, cache, and notification work as
       the compatibility `progress` overload.
     - Throws: The same repository, HTTP, ZIP, cancellation, storage, and filesystem errors as the
       compatibility overload.
     */
    public func installModule(
        named moduleName: String,
        from source: SourceConfig,
        progressState: ((ModuleInstallProgress) -> Void)?
    ) async throws {
        progressState?(ModuleInstallProgress(phase: .queued))
        guard let entries = cachedCatalogEntries(for: source.name),
              let entry = entries.first(where: { $0.name == moduleName }) else {
            throw ModuleRepositoryError.moduleNotFound(moduleName)
        }

        try requireStorageCapacity(estimatedAdditionalBytes: Self.installSizeBytes(from: entry.size))

        if source.isMyBibleRepository || entry.repositoryType == SourceConfig.myBibleHTTPSRepositoryType {
            try await installMyBibleModule(entry, progressState: progressState)
            return
        }

        guard source.baseURL != nil else {
            throw ModuleRepositoryError.invalidURL(source.name)
        }

        let layout: ModuleStoreInstalledLayout
        do {
            layout = try mutationPublisher.resolveCatalogLayout(
                moduleName: moduleName,
                configurationContent: entry.confContent
            )
        } catch {
            throw ModuleRepositoryError.invalidZip(error.localizedDescription)
        }

        let packageInstallResult = try await installModulePackage(
            named: moduleName,
            entry: entry,
            source: source,
            layout: layout,
            progressState: progressState
        )
        switch packageInstallResult {
        case .installed:
            return
        case .unavailable:
            throw ModuleRepositoryError.downloadFailed("Package ZIP was unavailable for \(moduleName)")
        case .noCandidates:
            throw ModuleRepositoryError.downloadFailed("No package ZIP location was available for \(moduleName)")
        }
    }

    /**
     Returns the current shared storage requirement without starting an install.

     - Parameter estimatedAdditionalBytes: Known package or expanded bytes beyond Android's 50 MiB
       reserve.
     - Returns: Capacity requirement when the destination volume reports capacity; otherwise `nil`.
     - Side effects: Reads destination-volume metadata.
     - Failure modes: Missing filesystem quota metadata returns `nil` rather than blocking work.
     */
    public func storageRequirement(
        estimatedAdditionalBytes: Int64? = nil
    ) -> ModuleStorageRequirement? {
        storagePreflight.requirement(
            for: URL(fileURLWithPath: swordPath, isDirectory: true),
            estimatedAdditionalBytes: estimatedAdditionalBytes
        )
    }

    /**
     Enforces Android's storage reserve plus any known install allocation.

     - Parameter estimatedAdditionalBytes: Known package or expanded bytes beyond the fixed reserve.
     - Side effects: Reads destination-volume metadata.
     - Throws: `ModuleRepositoryError.insufficientStorage` when reported capacity is below the
       requirement. Missing capacity metadata fails open because insufficiency cannot be established.
     */
    private func requireStorageCapacity(estimatedAdditionalBytes: Int64? = nil) throws {
        guard let requirement = storageRequirement(estimatedAdditionalBytes: estimatedAdditionalBytes),
              !requirement.isSatisfied else {
            return
        }
        throw ModuleRepositoryError.insufficientStorage(
            requiredBytes: requirement.requiredBytes,
            availableBytes: requirement.availableBytes
        )
    }

    /**
     Maps phase-aware progress onto the former normalized callback without reporting success early.

     - Parameter state: Current structured installer phase.
     - Returns: A monotonic best-effort overall fraction, or `nil` for indeterminate download work.
     - Side effects: none.
     - Failure modes: none; structured fractions are already normalized.
     */
    private static func legacyOverallProgress(for state: ModuleInstallProgress) -> Double? {
        switch state.phase {
        case .queued:
            return 0
        case .downloading:
            return state.fraction.map { $0 * 0.70 }
        case .extracting:
            return 0.70 + (state.fraction ?? 0) * 0.20
        case .committing:
            return 0.95
        case .complete:
            return 1
        }
    }

    /**
     Parses catalog `InstallSize` for storage preflight without changing display semantics.

     - Parameter value: Raw catalog install-size value.
     - Returns: Positive byte count, or `nil` when absent, malformed, or non-positive.
     - Side effects: none.
     - Failure modes: Numeric overflow returns `nil`.
     */
    private static func installSizeBytes(from value: String) -> Int64? {
        guard let bytes = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)), bytes > 0 else {
            return nil
        }
        return bytes
    }

    /**
     Streams one repository payload into a destination using URLSession's native download task.

     - Parameters:
       - remoteURL: Fully resolved repository URL for the required package payload.
       - destinationURL: Destination that will be created or replaced.
       - fileName: Repository payload name used in user-visible failure messages.
       - completedFiles: Number of payloads already staged before this download.
       - totalFiles: Total payload count for the install, used for progress scaling.
       - progress: Optional byte-progress callback; `nil` fractions represent unknown length.

     Side effects:
     - creates the destination parent directory
     - creates a short-lived URLSession with the same configuration as the repository session
     - moves URLSession's temporary download file to `destinationURL` after a 200 response
     - invokes `progress` as URLSession reports integer percent boundaries

     Failure modes:
     - throws `ModuleFileHTTPStatusError` for non-200 responses so package installers can
       distinguish unavailable packages from hard HTTP failures
     - throws `CancellationError` when the surrounding task is cancelled
     - propagates transport and file I/O errors
     */
    private func downloadRequiredModuleFile(
        from remoteURL: URL,
        to destinationURL: URL,
        fileName: String,
        completedFiles: Int,
        totalFiles: Double,
        progress: ((Double?) -> Void)?
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
       - posts `SwordModuleStore.modulesDidChangeNotification` after the staged install publishes
     - Throws:
       - `ModuleRepositoryError.invalidURL` when the manifest row has no HTTPS package URL
       - `ModuleRepositoryError.downloadFailed` when the package response returns an HTTP failure
       - `ModuleRepositoryError.invalidZip` when the package is empty or lacks a MyBible payload
       - `CancellationError` when the surrounding task is cancelled
       - file-system errors from staging or publishing the package
     */
    private func installMyBibleModule(
        _ entry: CatalogModule,
        progressState: ((ModuleInstallProgress) -> Void)?
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

        progressState?(ModuleInstallProgress(phase: .downloading))
        do {
            try await downloadRequiredModuleFile(
                from: downloadURL,
                to: packageDownloadURL,
                fileName: downloadURL.lastPathComponent,
                completedFiles: 0,
                totalFiles: 1,
                progress: { fraction in
                    progressState?(ModuleInstallProgress(phase: .downloading, fraction: fraction))
                }
            )
        } catch let statusError as ModuleFileHTTPStatusError {
            throw ModuleRepositoryError.downloadFailed(statusError.localizedDescription)
        }

        try Task.checkCancellation()
        let stagingDirURL = fm.temporaryDirectory
            .appendingPathComponent("mybible-\(entry.name)-\(UUID().uuidString).staging", isDirectory: true)
        try fm.createDirectory(at: stagingDirURL, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: stagingDirURL)
        }

        let packageEntries = try readFileBackedZipEntries(from: packageDownloadURL)
        try requireStorageCapacity(estimatedAdditionalBytes: try estimatedExpandedBytes(for: packageEntries))
        progressState?(ModuleInstallProgress(phase: .extracting, fraction: 0))
        let extractionResult = try extractMyBiblePackagePayloads(
            from: packageDownloadURL,
            to: stagingDirURL,
            packageFileName: entry.packageFileName,
            entries: packageEntries,
            progress: { fraction in
                progressState?(ModuleInstallProgress(phase: .extracting, fraction: fraction))
            }
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
        try mutationPublisher.publishStagedMyBibleInstall(
            from: stagingDirURL,
            moduleName: entry.name,
            onCommitStarted: {
                progressState?(ModuleInstallProgress(phase: .committing))
            }
        )
        progressState?(ModuleInstallProgress(phase: .complete, fraction: 1))
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

        /// CRC32 of the uncompressed payload advertised by ZIP metadata.
        let checksum: UInt32

        /// Offset of the entry's local file header in the package file.
        let localHeaderOffset: UInt64
    }

    /**
     Sums advertised uncompressed entry sizes for storage preflight.

     - Parameter entries: File-backed ZIP metadata entries to be considered for staging.
     - Returns: Saturation-safe signed byte estimate.
     - Side effects: none.
     - Throws: `ModuleRepositoryError.invalidZip` when an entry size or aggregate cannot fit in
       `Int64`, preventing a crafted archive from bypassing capacity checks through overflow.
     */
    private func estimatedExpandedBytes(for entries: [FileBackedZipEntry]) throws -> Int64 {
        var total: Int64 = 0
        for entry in entries {
            guard entry.uncompressedSize <= UInt64(Int64.max) else {
                throw ModuleRepositoryError.invalidZip("ZIP entry size exceeds supported limits")
            }
            let (next, overflow) = total.addingReportingOverflow(Int64(entry.uncompressedSize))
            guard !overflow else {
                throw ModuleRepositoryError.invalidZip("ZIP expanded size exceeds supported limits")
            }
            total = next
        }
        return total
    }

    /**
     Extracts safe MyBible SQLite payload entries from a downloaded package without loading it all.

     - Parameters:
       - zipURL: Temporary package file produced by `downloadRequiredModuleFile`.
       - stagingDirURL: Empty installation staging directory for the module.
       - packageFileName: Manifest package name used to accept legacy payloads without an extension.
       - entries: Validated file-backed entries read once before storage preflight.
       - progress: Optional extraction progress observer.
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
        packageFileName: String?,
        entries: [FileBackedZipEntry],
        progress: ((Double) -> Void)? = nil
    ) throws -> MyBiblePackageExtractionResult {
        let fm = FileManager.default
        var payloadCount = 0

        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            defer {
                progress?(Double(index + 1) / Double(max(entries.count, 1)))
            }
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
                try writeSwordZipEntry(entry, from: zipURL, to: destinationURL)
                payloadCount += 1
            } catch {
                try? fm.removeItem(at: destinationURL)
                throw error
            }
        }

        return MyBiblePackageExtractionResult(entryCount: entries.count, payloadCount: payloadCount)
    }

    /**
     Writes one SWORD ZIP entry to disk using the file-backed extractor shared by local imports and
     downloaded repository packages.

     - Parameters:
       - entry: ZIP entry metadata already accepted by SWORD path normalization.
       - zipURL: Archive containing the compressed payload.
       - destinationURL: Destination path inside a staging directory or SWORD home.
     - Side effects:
       - creates the destination parent directory
       - replaces any existing destination file with the extracted payload
       - reads compressed bytes from `zipURL`
     - Throws:
       - `ModuleRepositoryError.invalidZip` for encrypted entries or unsupported compression
         methods
       - `ModuleRepositoryError.decompressionFailed` when zlib rejects a deflated entry
       - file-system errors from creating directories, replacing files, or writing output
     */
    private func writeSwordZipEntry(
        _ entry: FileBackedZipEntry,
        from zipURL: URL,
        to destinationURL: URL
    ) throws {
        guard entry.generalPurposeFlags & 0x0001 == 0 else {
            throw ModuleRepositoryError.invalidZip("Encrypted ZIP entries are not supported")
        }

        let fm = FileManager.default
        try fm.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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
                throw ModuleRepositoryError.invalidZip(
                    "Unsupported ZIP compression method \(entry.compressionMethod)"
                )
            }
            let attributes = try fm.attributesOfItem(atPath: destinationURL.path)
            guard let writtenSize = (attributes[.size] as? NSNumber)?.uint64Value,
                  writtenSize == entry.uncompressedSize else {
                throw ModuleRepositoryError.decompressionFailed
            }
            guard try ArchiveCRC32.checksum(fileAt: destinationURL) == entry.checksum else {
                throw ModuleRepositoryError.invalidZip(
                    "ZIP entry checksum mismatch: \(entry.name)"
                )
            }
        } catch {
            if fm.fileExists(atPath: destinationURL.path) {
                try? fm.removeItem(at: destinationURL)
            }
            throw error
        }
    }

    /**
     Reads one staged config entry through the file-backed ZIP extractor used for publication.

     - Parameters:
       - entry: Direct-root `mods.d/<initials>.conf` entry whose size and compression metadata were parsed.
       - zipURL: Archive containing the config payload.
     - Returns: UTF-8 or Latin-1 config text for semantic layout validation.
     - Side effects: Writes and removes one temporary metadata file.
     - Throws: `ModuleRepositoryError.invalidZip` for oversized or undecodable config data, plus
       extractor and temporary filesystem errors.
     */
    private func configurationContent(
        for entry: FileBackedZipEntry,
        in zipURL: URL
    ) throws -> String {
        guard entry.uncompressedSize <= 1_024 * 1_024 else {
            throw ModuleRepositoryError.invalidZip("Module config exceeds the 1 MiB metadata limit")
        }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("module-config-\(UUID().uuidString).conf")
        defer {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        try writeSwordZipEntry(entry, from: zipURL, to: temporaryURL)
        let data = try Data(contentsOf: temporaryURL)
        guard let content = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ModuleRepositoryError.invalidZip("Module config is not UTF-8 or Latin-1 text")
        }
        return content
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
              entry.compressedSize <= UInt64(UInt.max),
              entry.uncompressedSize <= UInt64(UInt.max) else {
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
                    UInt(entry.uncompressedSize),
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
     Result of attempting a SWORD package ZIP install.

     The installer needs to distinguish an unavailable package from a source that cannot produce a
     package URL so the user-visible failure identifies whether repository metadata or repository
     availability blocked the Android-parity install.

     Side effects:
     - none; values summarize work performed by `installModulePackage`

     Failure modes:
     - none
     */
    private enum ModulePackageInstallResult: Equatable {
        /// A package ZIP was downloaded, extracted, and committed.
        case installed

        /// At least one package URL was attempted, but every candidate returned 404.
        case unavailable

        /// No package URL could be built for the selected source and heuristic mode.
        case noCandidates

    }

    /**
     Installs a module from an Android-compatible repository ZIP package.

     Android installs SWORD modules through repository package ZIPs. iOS follows that same remote
     path for built-in repositories, Android-compatible custom manifests, and direct SWORD catalog
     custom sources whose package directory is inferred as `catalogPath/packages`.

     - Parameters:
       - moduleName: Catalog module abbreviation whose package should be downloaded.
       - entry: Parsed catalog entry providing `DataPath`, `ModDrv`, and `.conf` content.
       - source: Repository source used to derive package ZIP candidate URLs.
       - layout: Catalog layout validated before any package request or destination creation. The
         downloaded package config must resolve to this same identity, driver, and data path.
       - progressState: Optional phase-aware progress observer shared with the caller.
     - Returns: `.installed` when a package was committed, `.unavailable` when package URLs existed
       but returned 404, or `.noCandidates` when no package URL could be built.
     - Side effects:
       - downloads a candidate ZIP into a temporary file
       - parses and validates the package's direct-root `.conf` against catalog metadata
       - extracts only payload owned by that validated package config into a temporary staging tree
       - commits the package `.conf` plus repository attribution through the rollback-safe path
       - invalidates SWORD's module cache after a successful package install
     - Throws:
       - `CancellationError` when the surrounding task is cancelled
       - `ModuleRepositoryError.downloadFailed` when a package candidate returns a non-404 HTTP
         failure
       - `ModuleRepositoryError.invalidZip` when a downloaded candidate is malformed, has a
         placeholder/mismatched config, or contains payload outside the catalog-owned data path
       - file-system errors from temporary extraction or final publish
     */
    private func installModulePackage(
        named moduleName: String,
        entry: CatalogModule,
        source: SourceConfig,
        layout: ModuleStoreInstalledLayout,
        progressState: ((ModuleInstallProgress) -> Void)?
    ) async throws -> ModulePackageInstallResult {
        let candidates = packageZipCandidateURLs(
            for: moduleName,
            source: source
        )
        guard !candidates.isEmpty else { return .noCandidates }

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
                logger.info("Trying package install \(candidate.absoluteString)")
                progressState?(ModuleInstallProgress(phase: .downloading))
                try await downloadRequiredModuleFile(
                    from: candidate,
                    to: packageDownloadURL,
                    fileName: candidate.lastPathComponent,
                    completedFiles: 0,
                    totalFiles: 1,
                    progress: { fraction in
                        progressState?(ModuleInstallProgress(phase: .downloading, fraction: fraction))
                    }
                )
                downloadedPackageURL = candidate
                break
            } catch let statusError as ModuleFileHTTPStatusError where statusError.statusCode == 404 {
                logger.info("Skipping missing package install \(candidate.absoluteString)")
                try? fm.removeItem(at: packageDownloadURL)
            } catch let statusError as ModuleFileHTTPStatusError {
                throw ModuleRepositoryError.downloadFailed(statusError.localizedDescription)
            }
        }

        guard let downloadedPackageURL else { return .unavailable }

        let entries = try readFileBackedZipEntries(from: packageDownloadURL)
        guard !entries.isEmpty else {
            throw ModuleRepositoryError.invalidZip("\(downloadedPackageURL.lastPathComponent) is empty")
        }
        try requireStorageCapacity(estimatedAdditionalBytes: try estimatedExpandedBytes(for: entries))

        let extractionRootURL = fm.temporaryDirectory
            .appendingPathComponent("\(moduleName)-\(UUID().uuidString).package", isDirectory: true)
        try fm.createDirectory(at: extractionRootURL, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: extractionRootURL)
        }

        var directRootEntries: [(FileBackedZipEntry, String)] = []
        for archiveEntry in entries {
            if archiveEntry.name.hasSuffix("/") {
                guard isDirectSwordPackageDirectoryPath(archiveEntry.name) else {
                    throw ModuleRepositoryError.invalidZip(
                        "Unsupported remote package entry path: \(archiveEntry.name)"
                    )
                }
                continue
            }
            guard let relativePath = normalizedSwordPackageEntryPath(archiveEntry.name) else {
                throw ModuleRepositoryError.invalidZip(
                    "Unsupported remote package entry path: \(archiveEntry.name)"
                )
            }
            directRootEntries.append((archiveEntry, relativePath))
        }
        let expectedConfigPath = layout.configRelativePath
        let packageConfigEntries = directRootEntries.filter { item in
            item.1.hasPrefix("mods.d/") && item.1.lowercased().hasSuffix(".conf")
        }
        guard packageConfigEntries.count == 1,
              let packageConfigEntry = packageConfigEntries.first,
              packageConfigEntry.1.caseInsensitiveCompare(expectedConfigPath) == .orderedSame else {
            throw ModuleRepositoryError.invalidZip(
                "\(downloadedPackageURL.lastPathComponent) must contain only \(expectedConfigPath) as its module config"
            )
        }
        let packageConfigurationContent = try configurationContent(
            for: packageConfigEntry.0,
            in: packageDownloadURL
        )
        let packageLayout = try validatedRemotePackageLayout(
            configurationContent: packageConfigurationContent,
            moduleName: moduleName,
            catalogEntry: entry,
            catalogLayout: layout
        )

        let matchingEntries = directRootEntries.filter { item in
            packageLayout.ownsPayload(atRelativePath: item.1)
        }
        let unexpectedEntries = directRootEntries.filter { item in
            item.1.caseInsensitiveCompare(expectedConfigPath) != .orderedSame
                && !packageLayout.ownsPayload(atRelativePath: item.1)
        }
        guard unexpectedEntries.isEmpty else {
            throw ModuleRepositoryError.invalidZip(
                "Package contains payload outside \(packageLayout.dataPath): \(unexpectedEntries[0].1)"
            )
        }
        progressState?(ModuleInstallProgress(phase: .extracting, fraction: 0))

        for (index, item) in matchingEntries.enumerated() {
            try Task.checkCancellation()
            let destinationPath = (extractionRootURL.path as NSString).appendingPathComponent(item.1)
            let destinationURL = URL(fileURLWithPath: destinationPath)
            try writeSwordZipEntry(item.0, from: packageDownloadURL, to: destinationURL)
            progressState?(ModuleInstallProgress(
                phase: .extracting,
                fraction: Double(index + 1) / Double(max(matchingEntries.count, 1))
            ))
        }

        guard !matchingEntries.isEmpty else {
            throw ModuleRepositoryError.invalidZip(
                "\(downloadedPackageURL.lastPathComponent) did not contain payload for \(packageLayout.dataPath)"
            )
        }

        let publishedConfContent = Self.confContent(
            packageConfigurationContent,
            settingRepository: source.name
        )
        let stagedConfigURL = extractionRootURL.appendingPathComponent(packageLayout.configRelativePath)
        try fm.createDirectory(
            at: stagedConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try publishedConfContent.write(to: stagedConfigURL, atomically: true, encoding: .utf8)
        let plan: ModuleStoreStagedInstallPlan
        do {
            plan = try mutationPublisher.validateStagedInstall(
                configurations: [ModuleStoreStagedConfiguration(
                    relativePath: packageLayout.configRelativePath,
                    content: publishedConfContent
                )],
                payloadRelativePaths: matchingEntries.map { $0.1 }
            )
        } catch {
            throw ModuleRepositoryError.invalidZip(error.localizedDescription)
        }

        try Task.checkCancellation()
        try mutationPublisher.publishStagedInstall(
            plan,
            from: extractionRootURL,
            allowOverwrite: true,
            kind: .remoteSword,
            onCommitStarted: {
                progressState?(ModuleInstallProgress(phase: .committing))
            }
        )
        progressState?(ModuleInstallProgress(phase: .complete, fraction: 1))
        return .installed
    }

    /**
     Parses one remote package config and proves it describes exactly the requested catalog module.

     SWORD permits repeated keys and multiple sections in a config file, while the shared metadata
     projection intentionally reads the first value. A package could otherwise pass validation with
     a matching first section/key and publish a second module or conflicting driver/path consumed by
     another backend. Remote packages therefore require one section and one `ModDrv`/`DataPath`.

     - Parameters:
       - configurationContent: UTF-8 or Latin-1 package `.conf` text extracted from the ZIP.
       - moduleName: Module initials requested by the caller and used for the package filename.
       - catalogEntry: Refreshed repository catalog row selected for installation.
       - catalogLayout: Safety-validated layout derived from the catalog config before download.
     - Returns: Safety-validated package layout identical to the catalog identity, driver, and path.
     - Side effects: Resolves existing module-root symlinks through the shared layout resolver; no
       package or installed files are written.
     - Throws: `ModuleRepositoryError.invalidZip` for malformed, ambiguous, placeholder, mismatched,
       or unsafe package configuration.
     */
    private func validatedRemotePackageLayout(
        configurationContent: String,
        moduleName: String,
        catalogEntry: CatalogModule,
        catalogLayout: ModuleStoreInstalledLayout
    ) throws -> ModuleStoreInstalledLayout {
        guard let parsedConfig = SwordModuleConfig.parse(configurationContent),
              Self.moduleConfigSectionNames(in: configurationContent) == [parsedConfig.name],
              parsedConfig.values["moddrv"]?.count == 1,
              parsedConfig.values["datapath"]?.count == 1 else {
            throw ModuleRepositoryError.invalidZip(
                "Package config for \(moduleName) must contain one module section, ModDrv, and DataPath"
            )
        }

        let packageLayout: ModuleStoreInstalledLayout
        do {
            packageLayout = try mutationPublisher.resolveCatalogLayout(
                moduleName: moduleName,
                configurationContent: configurationContent
            )
        } catch {
            throw ModuleRepositoryError.invalidZip(
                "Package config for \(moduleName) is invalid: \(error.localizedDescription)"
            )
        }
        guard packageLayout.moduleName.caseInsensitiveCompare(moduleName) == .orderedSame,
              packageLayout.moduleName.caseInsensitiveCompare(catalogEntry.name) == .orderedSame,
              packageLayout.moduleName.caseInsensitiveCompare(catalogLayout.moduleName) == .orderedSame else {
            throw ModuleRepositoryError.invalidZip(
                "Package config section \(packageLayout.moduleName) does not match catalog module \(moduleName)"
            )
        }
        guard packageLayout.driver.caseInsensitiveCompare(catalogLayout.driver) == .orderedSame else {
            throw ModuleRepositoryError.invalidZip(
                "Package ModDrv \(packageLayout.driver) does not match catalog ModDrv \(catalogLayout.driver)"
            )
        }
        guard packageLayout.dataPath == catalogLayout.dataPath else {
            throw ModuleRepositoryError.invalidZip(
                "Package DataPath \(packageLayout.dataPath) does not match catalog DataPath \(catalogLayout.dataPath)"
            )
        }
        return packageLayout
    }

    /**
     Collects exact section headers from a SWORD module config for ambiguity checks.

     - Parameter content: Package config text using SWORD's line-oriented INI syntax.
     - Returns: Trimmed section names in source order, or an empty array when any bracket-prefixed
       line is malformed.
     - Side effects: none.
     - Failure modes: Malformed section syntax returns an empty array so package validation fails
       closed; ordinary comments, blank lines, and key/value lines are ignored.
     */
    private static func moduleConfigSectionNames(in content: String) -> [String] {
        var sectionNames: [String] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") else { continue }
            guard trimmed.hasSuffix("]") else { return [] }
            let sectionName = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
            guard !sectionName.isEmpty else { return [] }
            sectionNames.append(sectionName)
        }
        return sectionNames
    }

    /**
     Persists Android's installed repository origin in a SWORD config before publish.

     Android records `SourceRepository` after JSword installation and uses it to distinguish
     same-initials rows from different repositories. iOS stores the equivalent value in the
     `Repository` config field already projected by `SwordModuleConfig.aboutMetadata`.

     - Parameters:
       - content: Validated package `.conf` content to publish.
       - repository: Exact source name selected for installation.
     - Returns: Config content with one canonical `Repository=` line.
     - Side effects: none.
     - Failure modes: Malformed non-key lines are preserved; any existing case-insensitive
       `Repository` assignments are replaced.
     */
    private static func confContent(_ content: String, settingRepository repository: String) -> String {
        var lines = content.components(separatedBy: .newlines).filter { line in
            let key = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return key?.caseInsensitiveCompare("Repository") != .orderedSame
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        lines.append("Repository=\(repository)")
        return lines.joined(separator: "\n") + "\n"
    }

    /**
     Builds the repository package ZIP URL that matches Android's installer source model.

     - Parameters:
       - moduleName: Catalog module abbreviation used as the package filename.
       - source: Repository source whose host and catalog path anchor package locations.
     - Returns: The package URL for the source, or an empty array when no package directory can be
       resolved.
     - Side effects: none.
     - Failure modes: malformed host/path combinations are skipped and cause the caller to surface
       a package-location failure.
     */
    private func packageZipCandidateURLs(
        for moduleName: String,
        source: SourceConfig
    ) -> [URL] {
        let packageFileName = "\(moduleName).zip"
        guard let packageDirectory = packageDirectory(for: source) else { return [] }
        let path = appendingPathComponent(packageFileName, toPath: packageDirectory)
        guard let url = URL(string: "https://\(source.host)\(path)") else { return [] }
        return [url]
    }

    /**
     Returns the package directory that Android would give to the SWORD installer.

     Android keeps package and catalog directories as distinct repository fields. iOS persists only
     the catalog-style `HTTPSource` row for local SWORD compatibility, so default-source metadata is
     restored through `InstallManager` before falling back to Android's direct custom-repository
     `catalogDirectory/packages` rule.

     - Parameter source: Repository source loaded from `InstallMgr.conf`.
     - Returns: Package directory path from Android's `repositories.txt` when the source matches a
       built-in repository, an explicit custom package directory, or the direct-catalog custom
       fallback `catalogPath/packages`.
     - Side effects: none.
     - Failure modes: none.
     */
    private func packageDirectory(for source: SourceConfig) -> String? {
        if let packageDirectory = source.packageDirectory,
           !packageDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalizedRepositoryPath(packageDirectory)
        }

        if let packageDirectory = InstallManager.defaultPackageDirectory(for: source) {
            return normalizedRepositoryPath(packageDirectory)
        }

        guard !source.isMyBibleRepository else { return nil }
        return appendingPathComponent("packages", toPath: source.catalogPath)
    }

    private func normalizedRepositoryPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
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
     - Returns: An unchanged relative path beginning exactly with `mods.d/` or `modules/`; returns
       `nil` for wrappers, absolute paths, traversal paths, backslashes, directories, or unsupported
       archive entries.
     - Side effects: none.
     - Failure modes: Invalid paths return `nil`; the caller rejects the entire remote package.
     */
    private func normalizedSwordPackageEntryPath(_ path: String) -> String? {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("./"),
              !path.hasSuffix("/"),
              !path.contains("\\"),
              !path.contains("%") else {
            return nil
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            return nil
        }

        guard path.hasPrefix("mods.d/") || path.hasPrefix("modules/") else {
            return nil
        }
        return path
    }

    /** Validates an optional directory marker rooted directly at `mods.d/` or `modules/`. */
    private func isDirectSwordPackageDirectoryPath(_ path: String) -> Bool {
        guard path.hasSuffix("/") else { return false }
        let filePath = String(path.dropLast())
        guard !filePath.isEmpty,
              !filePath.hasPrefix("/"),
              !filePath.hasPrefix("./"),
              !filePath.contains("\\"),
              !filePath.contains("%") else {
            return false
        }
        let components = filePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            return false
        }
        return filePath == "mods.d"
            || filePath == "modules"
            || filePath.hasPrefix("mods.d/")
            || filePath.hasPrefix("modules/")
    }

    /**
     Loads installed MyBible module metadata from the shared Android-compatible inventory scanner.

     - Returns: Installed MyBible modules as common `ModuleInfo` rows for Downloads state.
     - Side effects:
       - reads `module.json` sidecars from installed MyBible module directories
       - checks extracted MyBible payload files for readability
     - Failure modes:
       - unreadable or malformed sidecars and missing payloads are skipped so one bad install cannot
       hide the rest of the Downloads list.
     */
    public func loadInstalledMyBibleModules() -> [ModuleInfo] {
        SwordManager.myBiblePackageInstalledModules(modulePath: swordPath)
    }

    /**
     Uninstalls either a MyBible sidecar module or a SWORD module by name.

     MyBible modules are removed only when their `module.json` sidecar is present. SWORD modules are
     resolved through the shared driver-aware layout contract, then config and uniquely owned payload
     are moved to rollback storage before cache invalidation and notification. Bible removal is
     approved from fresh inventory while the shared mutation lease is held, so concurrent calls
     cannot both remove the final installed Bible.

     - Parameter moduleName: Installed module initials to remove.
     - Side effects:
       - acquires the process-wide canonical-root mutation lease
       - transactionally removes module files and posts the terminal store notification
     - Throws: `ModuleRepositoryError.moduleNotFound`, `.lastInstalledBible`,
       `.installedInventoryUnavailable`, unsafe-layout/ownership errors, public filesystem errors,
       or rollback failures.
     */
    public func uninstallModule(named moduleName: String) throws {
        do {
            try mutationPublisher.uninstallPreservingAtLeastOneBible(
                moduleName: moduleName,
                inventoryProvider: { [swordPath] in
                    SwordManager(modulePath: swordPath)?.installedModules()
                }
            )
        } catch ModuleStoreMutationError.moduleNotFound {
            throw ModuleRepositoryError.moduleNotFound(moduleName)
        } catch ModuleStoreBibleRetentionError.lastInstalledBible(let name) {
            throw ModuleRepositoryError.lastInstalledBible(name)
        } catch ModuleStoreBibleRetentionError.inventoryUnavailable {
            throw ModuleRepositoryError.installedInventoryUnavailable
        }
    }

    // MARK: - Install from ZIP

    /**
     Inspects a local SWORD ZIP using Android's exact root-layout and overwrite contract.

     Android accepts SWORD files only when `mods.d/` and `modules/` are archive-root directories;
     an enclosing package folder is invalid. Inspection performs no writes and returns destination
     conflicts so UI entry points can present Android's explicit overwrite confirmation.

     - Parameter url: Local archive URL to inspect.
     - Returns: Validated module names, conflicts, entry count, and expanded-size estimate.
     - Side effects: Reads ZIP metadata and checks destination file existence.
     - Throws: `ModuleRepositoryError.invalidZip` for empty, malformed, unsafe, duplicate,
       unsupported-root, config-less, or data-less archives.
     */
    public func inspectLocalSwordZip(at url: URL) throws -> LocalSwordZipInspection {
        try localSwordZipPlan(from: url).inspection
    }

    /**
     Installs a local SWORD ZIP without implicit overwrite permission.

     This source-compatible entry point now fails safely when destination files exist. Interactive
     callers must inspect, confirm, and invoke the explicit-policy overload.

     - Parameter url: Local Android-compatible SWORD archive.
     - Returns: First installed module initials in archive order.
     - Side effects: Stages and transactionally publishes package files, then invalidates SWORD's
       module cache.
     - Throws: ZIP validation, conflict, storage, extraction, or transactional filesystem errors.
     */
    public func installFromZip(at url: URL) throws -> String {
        try installFromZip(at: url, overwritePolicy: .reject, progressState: nil)
    }

    /**
     Installs a preflighted local SWORD ZIP with archive-bound overwrite consent and phase progress.

     Every accepted file is expanded under an isolated staging root. The archive digest is checked
     before and after extraction. Publish overlays only exact archive paths, moves existing files
     into a backup root, writes module data before `.conf` installed markers, and restores all moved
     files if any commit operation fails. Validation and conflict detection are repeated under the
     mutation lease so stale UI preflight cannot broaden overwrite consent.

     - Parameters:
       - url: Local Android-compatible SWORD archive.
       - overwritePolicy: Strict rejection or archive-bound authorization for exact conflicts shown
         during read-only preflight.
       - progressState: Optional phase-aware progress observer.
     - Returns: First installed module initials in archive order.
     - Side effects: Reads the archive; creates/removes staging and backup directories; may replace
       module files; invalidates module cache and posts the module-change notification on success.
     - Throws:
       - `ModuleRepositoryError.moduleFilesAlreadyExist` when conflicts exist under `.reject`
       - `ModuleRepositoryError.insufficientStorage` when known staging bytes violate the shared gate
       - `ModuleRepositoryError.invalidZip` for Android-incompatible layout or ZIP metadata
       - extraction and filesystem errors; rollback is attempted before they escape
     */
    public func installFromZip(
        at url: URL,
        overwritePolicy: LocalSwordZipOverwritePolicy,
        progressState: ((ModuleInstallProgress) -> Void)? = nil
    ) throws -> String {
        progressState?(ModuleInstallProgress(phase: .queued))
        let plan = try localSwordZipPlan(from: url)
        let authorizedExistingPaths: Set<String>
        switch overwritePolicy {
        case .reject:
            guard !plan.inspection.requiresOverwriteConfirmation else {
                throw ModuleRepositoryError.moduleFilesAlreadyExist(plan.inspection.conflictingPaths)
            }
            authorizedExistingPaths = []
        case .replaceExisting(let authorization):
            guard authorization.archiveSHA256 == plan.inspection.archiveSHA256 else {
                throw ModuleRepositoryError.invalidZip(
                    "Selected ZIP changed after overwrite confirmation. Inspect it again before installing."
                )
            }
            authorizedExistingPaths = Set(authorization.conflictingPaths)
        }
        try requireStorageCapacity(estimatedAdditionalBytes: plan.inspection.estimatedExpandedBytes)

        let fileManager = FileManager.default
        let stagingRootURL = fileManager.temporaryDirectory
            .appendingPathComponent("local-sword-\(UUID().uuidString).staging", isDirectory: true)
        try fileManager.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingRootURL) }

        progressState?(ModuleInstallProgress(phase: .extracting, fraction: 0))
        for (index, item) in plan.entries.enumerated() {
            let destinationURL = stagingRootURL.appendingPathComponent(item.path)
            try writeSwordZipEntry(item.entry, from: url, to: destinationURL)
            progressState?(ModuleInstallProgress(
                phase: .extracting,
                fraction: Double(index + 1) / Double(max(plan.entries.count, 1))
            ))
        }

        let extractedArchiveSHA256: String
        do {
            extractedArchiveSHA256 = try ArchiveFingerprint.sha256Hex(at: url)
        } catch {
            throw ModuleRepositoryError.invalidZip(
                "Unable to verify selected ZIP after extraction: \(error.localizedDescription)"
            )
        }
        guard extractedArchiveSHA256 == plan.inspection.archiveSHA256 else {
            throw ModuleRepositoryError.invalidZip(
                "Selected ZIP changed during installation. No module files were published."
            )
        }

        do {
            try mutationPublisher.publishStagedOverlay(
                plan.storePlan,
                from: stagingRootURL,
                authorizedExistingPaths: authorizedExistingPaths,
                kind: .localSwordZip,
                onCommitStarted: {
                    progressState?(ModuleInstallProgress(phase: .committing))
                }
            )
        } catch ModuleStoreMutationError.destinationFilesExist(let paths) {
            throw ModuleRepositoryError.moduleFilesAlreadyExist(paths)
        } catch ModuleStoreMutationError.destinationTypeConflict(let paths) {
            throw ModuleRepositoryError.invalidZip(
                "Module destinations are not replaceable regular files: \(paths.joined(separator: ", "))"
            )
        }
        progressState?(ModuleInstallProgress(phase: .complete, fraction: 1))

        guard let installedModuleName = plan.inspection.moduleNames.first else {
            throw ModuleRepositoryError.invalidZip("No module name found in .conf files")
        }
        return installedModuleName
    }

    /**
     One accepted local ZIP file entry and its exact Android-rooted destination path.
     */
    private struct LocalSwordZipPlannedEntry {
        /// File-backed ZIP metadata used by the shared extractor.
        let entry: FileBackedZipEntry

        /// Relative `mods.d/` or `modules/` destination path.
        let path: String
    }

    /**
     Validated local ZIP plan shared by inspection and installation.
     */
    private struct LocalSwordZipPlan {
        /// Public read-only facts used by UI and storage preflight.
        let inspection: LocalSwordZipInspection

        /// Accepted non-directory entries in archive order.
        let entries: [LocalSwordZipPlannedEntry]

        /// Config-to-payload ownership plan revalidated by the shared publisher under its lease.
        let storePlan: ModuleStoreStagedInstallPlan
    }

    /**
     Builds a strict Android-compatible local SWORD ZIP plan.

     - Parameter url: Archive URL to parse.
     - Returns: Validated plan containing only direct-root SWORD files.
     - Side effects: Reads ZIP metadata and destination existence.
     - Throws: `ModuleRepositoryError.invalidZip` for unsupported or unsafe layouts.
     */
    private func localSwordZipPlan(from url: URL) throws -> LocalSwordZipPlan {
        let initialArchiveSHA256: String
        do {
            initialArchiveSHA256 = try ArchiveFingerprint.sha256Hex(at: url)
        } catch {
            throw ModuleRepositoryError.invalidZip(
                "Unable to fingerprint selected ZIP: \(error.localizedDescription)"
            )
        }
        let archiveEntries = try readFileBackedZipEntries(from: url)
        guard !archiveEntries.isEmpty else {
            throw ModuleRepositoryError.invalidZip("ZIP file is empty")
        }

        let fileManager = FileManager.default
        var seenPaths: Set<String> = []
        var plannedEntries: [LocalSwordZipPlannedEntry] = []
        var configurations: [ModuleStoreStagedConfiguration] = []
        var payloadPaths: [String] = []
        var conflicts: [String] = []

        for archiveEntry in archiveEntries {
            let rawPath = archiveEntry.name
            if rawPath == "AndBibleBackupManifest.json" {
                continue
            }
            guard let relativePath = localSwordZipEntryPath(rawPath) else {
                throw ModuleRepositoryError.invalidZip("Unsupported ZIP entry path: \(archiveEntry.name)")
            }
            if relativePath.hasSuffix("/") {
                continue
            }
            guard seenPaths.insert(relativePath.lowercased()).inserted else {
                throw ModuleRepositoryError.invalidZip("Duplicate ZIP entry path: \(relativePath)")
            }

            if relativePath.hasPrefix("modules/") {
                payloadPaths.append(relativePath)
            }
            if relativePath.hasPrefix("mods.d/"), relativePath.hasSuffix(".conf") {
                configurations.append(ModuleStoreStagedConfiguration(
                    relativePath: relativePath,
                    content: try configurationContent(for: archiveEntry, in: url)
                ))
            }

            let destinationURL = URL(fileURLWithPath: swordPath, isDirectory: true)
                .appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: destinationURL.path) {
                let values = try destinationURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw ModuleRepositoryError.invalidZip(
                        "Module destination is not a replaceable regular file: \(relativePath)"
                    )
                }
                conflicts.append(relativePath)
            }
            plannedEntries.append(LocalSwordZipPlannedEntry(entry: archiveEntry, path: relativePath))
        }

        guard !plannedEntries.isEmpty else {
            throw ModuleRepositoryError.invalidZip("ZIP file did not contain installable module files")
        }
        let storePlan: ModuleStoreStagedInstallPlan
        do {
            storePlan = try mutationPublisher.validateStagedInstall(
                configurations: configurations,
                payloadRelativePaths: payloadPaths
            )
        } catch {
            throw ModuleRepositoryError.invalidZip(error.localizedDescription)
        }
        let finalArchiveSHA256: String
        do {
            finalArchiveSHA256 = try ArchiveFingerprint.sha256Hex(at: url)
        } catch {
            throw ModuleRepositoryError.invalidZip(
                "Unable to fingerprint selected ZIP: \(error.localizedDescription)"
            )
        }
        guard finalArchiveSHA256 == initialArchiveSHA256 else {
            throw ModuleRepositoryError.invalidZip(
                "Selected ZIP changed during inspection. Inspect it again before installing."
            )
        }

        return LocalSwordZipPlan(
            inspection: LocalSwordZipInspection(
                moduleNames: storePlan.moduleNames,
                conflictingPaths: Array(Set(conflicts)).sorted(),
                installableEntryCount: plannedEntries.count,
                estimatedExpandedBytes: try estimatedExpandedBytes(for: plannedEntries.map(\.entry)),
                archiveSHA256: finalArchiveSHA256
            ),
            entries: plannedEntries,
            storePlan: storePlan
        )
    }

    /**
     Validates one local ZIP entry against Android `InstallZip.checkZipFile()` root rules.

     - Parameter path: Raw archive entry name using slash or Android-accepted backslash separators.
     - Returns: Slash-normalized relative path for direct `mods.d/` or `modules/` entries, including
       directory entries, or `nil` for wrappers, traversal, absolute paths, and other roots.
     - Side effects: none.
     - Failure modes: Invalid paths return `nil` for the caller to reject with archive context.
     */
    private func localSwordZipEntryPath(_ path: String) -> String? {
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalizedPath.isEmpty,
              !normalizedPath.hasPrefix("/"),
              !normalizedPath.hasPrefix("./"),
              !normalizedPath.contains("%") else {
            return nil
        }
        let components = normalizedPath.split(separator: "/", omittingEmptySubsequences: false)
        for (index, component) in components.enumerated() {
            if component == ".." || component == "." || (component.isEmpty && index != components.indices.last) {
                return nil
            }
        }
        guard normalizedPath.hasPrefix("mods.d/") || normalizedPath.hasPrefix("modules/") else {
            return nil
        }
        return normalizedPath
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
            let checksum = readUInt32(centralDirectory, at: offset + 16)
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
                checksum: checksum,
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
            let checksum = readUInt32(header, at: 14)
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
                checksum: checksum,
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

    /**
     Parses one remote SWORD/Android config row into the Downloads catalog model.

     Android custom drivers such as `MyBibleDictionary` derive their category from the registered
     JSword `BookType`, not from an optional `Category=` property. The shared config projection keeps
     that behavior aligned with `SwordManager.installedModules()` so catalog rows and installed rows
     do not drift.

     - Parameters:
       - content: Raw `.conf` content from a repository catalog.
       - sourceName: Repository source that supplied the config.
     - Returns: Catalog row when the config has a module header and driver.
     - Side effects: none.
     - Failure modes: Malformed configs return `nil` and are skipped by catalog refresh.
     */
    private func parseModuleConf(_ content: String, sourceName: String) -> CatalogModule? {
        guard let config = SwordModuleConfig.parse(content) else { return nil }

        return CatalogModule(
            name: config.name,
            description: config.description,
            category: config.category,
            language: config.language,
            modDrv: config.modDrv,
            dataPath: config.dataPath,
            confContent: content,
            sourceName: sourceName,
            version: config.version,
            size: config.installSize
        )
    }

}

/// Errors from ModuleRepository operations.
public enum ModuleRepositoryError: Error, LocalizedError {
    case invalidURL(String)
    case downloadFailed(String)
    case decompressionFailed
    case moduleNotFound(String)
    /// Removal was rejected because the named module is the sole installed Bible.
    case lastInstalledBible(String)

    /// Removal was rejected before mutation because installed inventory could not be verified.
    case installedInventoryUnavailable
    case installFailed(String)
    case invalidZip(String)
    case moduleFilesAlreadyExist([String])
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let source): return "Invalid URL for source: \(source)"
        case .downloadFailed(let msg): return msg
        case .decompressionFailed: return "Failed to decompress catalog data"
        case .moduleNotFound(let name): return "Module '\(name)' not found in catalog"
        case .lastInstalledBible(let name):
            return "Module '\(name)' is the only installed Bible and cannot be removed"
        case .installedInventoryUnavailable:
            return "Installed module inventory could not be verified; no module was removed"
        case .installFailed(let msg): return "Installation failed: \(msg)"
        case .invalidZip(let msg): return "Invalid ZIP module: \(msg)"
        case .moduleFilesAlreadyExist(let paths):
            let listedPaths = paths.joined(separator: "\n")
            return listedPaths.isEmpty
                ? "Module files already exist. Confirm overwrite before installing."
                : "Module files already exist. Confirm overwrite before installing:\n\(listedPaths)"
        case .insufficientStorage(let requiredBytes, let availableBytes):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Insufficient local storage space. \(formatter.string(fromByteCount: availableBytes)) available; \(formatter.string(fromByteCount: requiredBytes)) required."
        }
    }
}
