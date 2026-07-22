// ModuleStoreRecoveryJournal.swift - Crash recovery for exact-path module overlays

import Foundation
import Darwin

/**
 Persists enough intent to recover an interrupted exact-path module-store overlay.

 Overlay publication records each backup and destination before mutating the live tree. An active
 journal is rolled back on the next launch; a committed journal only has its backup residue removed.
 Journal paths are root-relative and revalidated before recovery so a corrupted journal cannot
 redirect cleanup outside the module store.
 */
final class ModuleStoreRecoveryJournal {
    /// On-disk schema for one interrupted transaction.
    struct Record: Codable, Equatable {
        /// Recovery behavior selected by the last durable transaction checkpoint.
        enum Phase: String, Codable {
            case active
            case committed
            case rolledBack
        }

        /// One live target that may have been moved into transaction backup storage.
        struct BackupMove: Codable, Equatable {
            let originalPath: String
            let backupPath: String
            var didMove: Bool
        }

        let version: Int
        let transactionID: UUID
        let backupRootPath: String
        var phase: Phase
        var backupMoves: [BackupMove]
        var publishedPaths: [String]
        var createdDirectoryPaths: [String]
    }

    private static let currentVersion = 1
    private static let journalDirectoryName = ".module-recovery"

    let rootURL: URL
    let fileManager: FileManager
    let resolver: ModuleStoreInstalledLayoutResolver

    /**
     Creates a journal store for one canonical module root.

     - Parameters:
       - rootURL: SWORD module root whose exact-path overlays are protected.
       - fileManager: Filesystem implementation shared with the transaction publisher.
     - Side effects: none; journal storage is created only when a transaction begins.
     - Failure modes: none.
     */
    init(rootURL: URL, fileManager: FileManager) {
        self.fileManager = fileManager
        self.resolver = ModuleStoreInstalledLayoutResolver(
            moduleRootURL: rootURL,
            fileManager: fileManager
        )
        self.rootURL = resolver.canonicalRootURL
    }

    /**
     Starts one durable active journal before the first live-tree mutation.

     - Parameter backupRoot: Same-volume directory that will hold displaced live files.
     - Returns: Mutable transaction journal owned by the caller's exclusive module-store lease.
     - Side effects: Creates and synchronizes the module root, journal directory, and journal file.
     - Throws: Filesystem, encoding, containment, or synchronization failures.
     */
    func begin(backupRoot: URL) throws -> ModuleStoreRecoveryTransaction {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let journalDirectory = rootURL.appendingPathComponent(
            Self.journalDirectoryName,
            isDirectory: true
        )
        try resolver.validateCanonicalContainment(of: journalDirectory, beneath: rootURL)
        try fileManager.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        try synchronizeDirectory(rootURL)

        let transactionID = UUID()
        let journalURL = journalDirectory.appendingPathComponent("\(transactionID.uuidString).json")
        let record = Record(
            version: Self.currentVersion,
            transactionID: transactionID,
            backupRootPath: try relativePath(for: backupRoot),
            phase: .active,
            backupMoves: [],
            publishedPaths: [],
            createdDirectoryPaths: []
        )
        let transaction = ModuleStoreRecoveryTransaction(
            store: self,
            journalURL: journalURL,
            record: record
        )
        try transaction.persist()
        return transaction
    }

    /**
     Recovers every durable journal under the canonical root.

     Active journals remove possibly published files and restore every existing backup. Committed
     journals preserve published files and only remove transaction residue.

     - Returns: `true` when at least one journal was recovered or cleaned.
     - Side effects: Mutates live files, backup roots, empty created directories, and journal files.
     - Throws: Corrupt journal data, unsafe paths, unsupported versions, or filesystem failures.
     */
    func recoverInterruptedTransactions() throws -> Bool {
        let journalDirectory = rootURL.appendingPathComponent(
            Self.journalDirectoryName,
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: journalDirectory.path) else { return false }
        try resolver.validateCanonicalContainment(of: journalDirectory, beneath: rootURL)
        let journalURLs = try fileManager.contentsOfDirectory(
            at: journalDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var recovered = false
        for journalURL in journalURLs {
            let values = try journalURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ModuleStoreMutationError.invalidConfiguration(journalURL.lastPathComponent)
            }
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: journalURL))
            guard record.version == Self.currentVersion else {
                throw ModuleStoreMutationError.invalidConfiguration(
                    "unsupported recovery journal version \(record.version)"
                )
            }
            try validate(record)
            switch record.phase {
            case .active:
                try rollback(record)
                var rolledBackRecord = record
                rolledBackRecord.phase = .rolledBack
                try persist(rolledBackRecord, to: journalURL)
                try removeIfPresent(try containedURL(for: record.backupRootPath))
            case .committed:
                try removeIfPresent(try containedURL(for: record.backupRootPath))
            case .rolledBack:
                try removeIfPresent(try containedURL(for: record.backupRootPath))
            }
            try removeIfPresent(journalURL)
            try synchronizeDirectory(journalDirectory)
            recovered = true
        }

        if try fileManager.contentsOfDirectory(atPath: journalDirectory.path).isEmpty {
            try fileManager.removeItem(at: journalDirectory)
            try synchronizeDirectory(rootURL)
        }
        return recovered
    }

    /** Validates every root-relative record path before recovery performs any mutation. */
    private func validate(_ record: Record) throws {
        _ = try containedURL(for: record.backupRootPath)
        guard record.backupRootPath.hasPrefix(".module-transaction-"),
              record.backupRootPath.hasSuffix(".backup") else {
            throw ModuleStoreMutationError.invalidConfiguration(record.backupRootPath)
        }
        for move in record.backupMoves {
            _ = try containedURL(for: move.originalPath)
            let backupURL = try containedURL(for: move.backupPath)
            let backupRootURL = try containedURL(for: record.backupRootPath)
            let backupPrefix = backupRootURL.path.hasSuffix("/")
                ? backupRootURL.path
                : backupRootURL.path + "/"
            guard backupURL.path.hasPrefix(backupPrefix) else {
                throw ModuleStoreMutationError.invalidConfiguration(move.backupPath)
            }
        }
        for path in record.publishedPaths + record.createdDirectoryPaths {
            _ = try containedURL(for: path)
        }
    }

    /**
     Rolls one active journal back while retaining its backup copies until a durable terminal marker.

     Published paths are removed and old destinations are copied from transaction storage rather
     than moved. Keeping the backup tree intact makes an interrupted rollback repeatable: recovery
     can safely run again until the caller persists `rolledBack`, after which only residue cleanup is
     required.

     - Parameter record: Validated active recovery record whose paths are contained by the module root.
     - Side effects: Removes published files, restores prior files by copy, and removes empty created
       directories. The recorded backup root remains intact.
     - Throws: Filesystem or containment failures, including a missing backup required for recovery.
     - Important: The caller must persist `.rolledBack` before deleting the retained backup root.
     */
    private func rollback(_ record: Record) throws {
        for move in record.backupMoves where move.didMove {
            let originalURL = try containedURL(for: move.originalPath)
            let backupURL = try containedURL(for: move.backupPath)
            guard fileManager.fileExists(atPath: backupURL.path) else {
                throw ModuleStoreMutationError.rollbackFailed(
                    original: "Interrupted module transaction lost its recorded backup.",
                    failures: [originalURL.path]
                )
            }
        }
        let backupByOriginal = Dictionary(
            record.backupMoves.map { (resolver.filesystemCollisionKey($0.originalPath), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for publishedPath in record.publishedPaths.reversed() {
            let destinationURL = try containedURL(for: publishedPath)
            let matchingMove = backupByOriginal[resolver.filesystemCollisionKey(publishedPath)]
            if let matchingMove {
                let backupURL = try containedURL(for: matchingMove.backupPath)
                guard fileManager.fileExists(atPath: backupURL.path) else {
                    // The intent was durable but the old destination was never displaced.
                    continue
                }
            }
            try removeIfPresent(destinationURL)
        }

        for move in record.backupMoves.reversed() {
            let originalURL = try containedURL(for: move.originalPath)
            let backupURL = try containedURL(for: move.backupPath)
            guard fileManager.fileExists(atPath: backupURL.path) else { continue }
            try fileManager.createDirectory(
                at: originalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try removeIfPresent(originalURL)
            try fileManager.copyItem(at: backupURL, to: originalURL)
            try synchronizeDirectory(originalURL.deletingLastPathComponent())
        }

        for path in record.createdDirectoryPaths.sorted(by: deeperPathFirst) {
            let directoryURL = try containedURL(for: path)
            guard fileManager.fileExists(atPath: directoryURL.path),
                  try fileManager.contentsOfDirectory(atPath: directoryURL.path).isEmpty else {
                continue
            }
            try fileManager.removeItem(at: directoryURL)
        }
    }

    /** Converts one contained URL to a normalized root-relative journal path. */
    func relativePath(for url: URL) throws -> String {
        let resolvedRoot = rootURL.standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL
        try resolver.validateCanonicalContainment(of: resolvedURL, beneath: resolvedRoot)
        let rootPrefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        let standardizedPath = resolvedURL.path
        guard standardizedPath.hasPrefix(rootPrefix) else {
            throw ModuleStoreMutationError.canonicalPathEscape(standardizedPath)
        }
        return String(standardizedPath.dropFirst(rootPrefix.count))
    }

    /** Resolves and validates one root-relative journal path without permitting traversal. */
    func containedURL(for relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0") else {
            throw ModuleStoreMutationError.invalidConfiguration(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ModuleStoreMutationError.invalidConfiguration(relativePath)
        }
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        try resolver.validateCanonicalContainment(of: url, beneath: rootURL)
        return url
    }

    /** Atomically writes and synchronizes one journal record. */
    func persist(_ record: Record, to journalURL: URL) throws {
        let data = try JSONEncoder().encode(record)
        try data.write(to: journalURL, options: .atomic)
        try synchronizeFile(journalURL)
        try synchronizeDirectory(journalURL.deletingLastPathComponent())
    }

    /** Removes a path when present and synchronizes its containing directory. */
    func removeIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    /** Synchronizes a regular file after publication and before a durable commit marker. */
    func synchronizeFile(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    /** Synchronizes directory metadata after create, move, or removal operations. */
    func synchronizeDirectory(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    /** Builds a Foundation POSIX error from the current Darwin errno value. */
    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /** Orders deeper root-relative directories before their parents during cleanup. */
    private func deeperPathFirst(_ lhs: String, _ rhs: String) -> Bool {
        lhs.split(separator: "/").count > rhs.split(separator: "/").count
    }
}

/**
 Mutable durable record for one exact-path overlay transaction.

 The transaction is used only while the process-wide module-store lease is held. Every intent method
 persists before the caller performs the corresponding mutation; `markCommitted` is written only
 after every published file and directory has been synchronized.
 */
final class ModuleStoreRecoveryTransaction {
    private let store: ModuleStoreRecoveryJournal
    let journalURL: URL
    private(set) var record: ModuleStoreRecoveryJournal.Record

    init(
        store: ModuleStoreRecoveryJournal,
        journalURL: URL,
        record: ModuleStoreRecoveryJournal.Record
    ) {
        self.store = store
        self.journalURL = journalURL
        self.record = record
    }

    /** Records one old destination before it may move to backup storage. */
    func recordBackupMove(originalURL: URL, backupURL: URL) throws {
        let move = ModuleStoreRecoveryJournal.Record.BackupMove(
            originalPath: try store.relativePath(for: originalURL),
            backupPath: try store.relativePath(for: backupURL),
            didMove: false
        )
        if !record.backupMoves.contains(move) {
            record.backupMoves.append(move)
            try persist()
        }
    }

    /** Records that one old destination reached backup storage after its move completed. */
    func markBackupMoveCompleted(originalURL: URL) throws {
        let originalPath = try store.relativePath(for: originalURL)
        guard let index = record.backupMoves.firstIndex(where: {
            store.resolver.filesystemCollisionKey($0.originalPath)
                == store.resolver.filesystemCollisionKey(originalPath)
        }) else {
            throw ModuleStoreMutationError.invalidConfiguration(originalPath)
        }
        guard !record.backupMoves[index].didMove else { return }
        record.backupMoves[index].didMove = true
        try persist()
    }

    /** Synchronizes both directory entries after a live destination moves to backup storage. */
    func synchronizeBackupMove(originalURL: URL, backupURL: URL) throws {
        try store.synchronizeDirectory(originalURL.deletingLastPathComponent())
        try store.synchronizeDirectory(backupURL.deletingLastPathComponent())
    }

    /** Records one destination before staged bytes may be copied or moved into it. */
    func recordPublishedURL(_ url: URL) throws {
        let path = try store.relativePath(for: url)
        if !record.publishedPaths.contains(path) {
            record.publishedPaths.append(path)
            try persist()
        }
    }

    /** Records one newly created directory for best-effort empty-directory rollback. */
    func recordCreatedDirectory(_ url: URL) throws {
        let path = try store.relativePath(for: url)
        if !record.createdDirectoryPaths.contains(path) {
            record.createdDirectoryPaths.append(path)
            try persist()
        }
    }

    /** Synchronizes every published file and relevant directory before commit is recorded. */
    func synchronizePublishedState() throws {
        for path in record.publishedPaths {
            let url = try store.containedURL(for: path)
            guard store.fileManager.fileExists(atPath: url.path) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try store.synchronizeFile(url)
            try store.synchronizeDirectory(url.deletingLastPathComponent())
        }
    }

    /** Durably marks the live overlay committed; recovery will preserve published files thereafter. */
    func markCommitted() throws {
        record.phase = .committed
        try persist()
    }

    /**
     Durably marks a completed rollback before its retained backups are discarded.

     - Side effects: Atomically rewrites and synchronizes the transaction journal.
     - Throws: Encoding, write, or synchronization failures. The journal remains active and its
       retained backups remain sufficient for startup to repeat rollback safely.
     - Note: Recovery treats a surviving rolled-back journal as cleanup-only state.
     */
    func markRolledBack() throws {
        record.phase = .rolledBack
        try persist()
    }

    /** Removes a completed/rolled-back journal after its filesystem state is stable. */
    func discard() throws {
        try store.removeIfPresent(journalURL)
        let journalDirectory = journalURL.deletingLastPathComponent()
        if store.fileManager.fileExists(atPath: journalDirectory.path),
           try store.fileManager.contentsOfDirectory(atPath: journalDirectory.path).isEmpty {
            try store.fileManager.removeItem(at: journalDirectory)
            try store.synchronizeDirectory(store.rootURL)
        }
    }

    /** Persists the current intent record before its matching live-tree action. */
    func persist() throws {
        try store.persist(record, to: journalURL)
    }
}
