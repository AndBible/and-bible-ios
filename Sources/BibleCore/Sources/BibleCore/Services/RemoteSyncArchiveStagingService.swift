// RemoteSyncArchiveStagingService.swift — Temp-file staging for remote sync archives

import CLibSword
import Foundation
import SQLite3

/**
 Errors emitted while staging remote initial-backup or patch archives locally.
 */
public enum RemoteSyncArchiveStagingError: Error, Equatable {
    /// A raw payload could not be compressed into a gzip archive successfully.
    case compressionFailed

    /// The downloaded gzip payload could not be decompressed successfully.
    case decompressionFailed

    /// The extracted initial backup could not be opened as a readable SQLite database.
    case invalidSQLiteDatabase

    /// The downloaded initial backup requires a newer schema version than the current app supports.
    case incompatibleInitialBackupVersion(Int)
}

/**
 Locally staged initial-backup database extracted from a remote gzip archive.
 */
public struct RemoteSyncStagedInitialBackup: Sendable, Equatable {
    /// Remote file descriptor for the original initial-backup archive.
    public let remoteFile: RemoteSyncFile

    /// Temporary local SQLite database file extracted from the gzip archive.
    public let databaseFileURL: URL

    /// SQLite user-version reported by the extracted database.
    public let schemaVersion: Int

    /**
     Creates one staged initial-backup payload.

     - Parameters:
       - remoteFile: Remote file descriptor for the original initial-backup archive.
       - databaseFileURL: Temporary local SQLite database file extracted from the gzip archive.
       - schemaVersion: SQLite user-version reported by the extracted database.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(remoteFile: RemoteSyncFile, databaseFileURL: URL, schemaVersion: Int) {
        self.remoteFile = remoteFile
        self.databaseFileURL = databaseFileURL
        self.schemaVersion = schemaVersion
    }
}

/**
 Locally staged remote patch archive ready for later merge/application work.
 */
public struct RemoteSyncStagedPatchArchive: Sendable, Equatable {
    /// Remote patch metadata that produced this downloaded archive.
    public let patch: RemoteSyncDiscoveredPatch

    /// Temporary local gzip archive downloaded from the remote backend.
    public let archiveFileURL: URL

    /**
     Creates one staged patch-archive payload.

     - Parameters:
       - patch: Remote patch metadata that produced this downloaded archive.
       - archiveFileURL: Temporary local gzip archive downloaded from the remote backend.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(patch: RemoteSyncDiscoveredPatch, archiveFileURL: URL) {
        self.patch = patch
        self.archiveFileURL = archiveFileURL
    }
}

/**
 Downloads remote sync archives into temporary local files using Android-compatible staging rules.

 Android's `CloudSync` downloads `initial.sqlite3.gz` and per-device patch archives into temporary
 files before restoring or applying them. This service mirrors that staging boundary on iOS so the
 later merge engine can operate on local files instead of mixing remote I/O with SQLite work.

 Data dependencies:
 - `RemoteSyncAdapting` performs the remote download requests
 - `temporaryDirectory` provides the local scratch area for staged archive and database files

 Side effects:
 - creates and deletes temporary files beneath the configured temporary directory
 - performs remote downloads through the supplied adapter
 - opens extracted SQLite databases read-only to inspect their schema version

 Failure modes:
 - rethrows remote transport failures from the adapter
 - rethrows filesystem write errors while staging files
 - throws `RemoteSyncArchiveStagingError.decompressionFailed` when gzip extraction fails
 - throws `RemoteSyncArchiveStagingError.invalidSQLiteDatabase` when the extracted initial backup
   is not a readable SQLite database
 - throws `RemoteSyncArchiveStagingError.incompatibleInitialBackupVersion` when the extracted
   initial backup requires a newer schema version than the current app supports
 */
public final class RemoteSyncArchiveStagingService {
    private let adapter: any RemoteSyncAdapting
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    /**
     Creates an archive-staging service bound to one remote backend.

     - Parameters:
       - adapter: Remote backend adapter used for archive downloads.
       - fileManager: File manager used for temporary-file creation and cleanup.
       - temporaryDirectory: Scratch directory for staged files. Defaults to the process temporary directory.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        adapter: any RemoteSyncAdapting,
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) {
        self.adapter = adapter
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
    }

    /**
     Downloads and extracts a remote initial backup into a temporary SQLite database file.

     - Parameters:
     - remoteFile: Remote initial-backup archive descriptor.
     - currentSchemaVersion: Highest SQLite schema version this app can restore safely.
     - Returns: Staged SQLite database file and its extracted schema version.
     - Side effects:
       - downloads the remote gzip archive
       - writes temporary gzip and SQLite files
       - attempts to remove the intermediate gzip file after successful extraction
     - Failure modes:
       - rethrows remote transport failures from the adapter
       - rethrows filesystem write errors while staging files
       - throws `RemoteSyncArchiveStagingError.decompressionFailed` when gzip extraction fails
       - throws `RemoteSyncArchiveStagingError.invalidSQLiteDatabase` when the extracted file is not a readable SQLite database
       - throws `RemoteSyncArchiveStagingError.incompatibleInitialBackupVersion` when the extracted database needs a newer schema version than `currentSchemaVersion`
     */
    public func downloadInitialBackup(
        _ remoteFile: RemoteSyncFile,
        currentSchemaVersion: Int
    ) async throws -> RemoteSyncStagedInitialBackup {
        let archiveData = try await adapter.download(id: remoteFile.id)
        let archiveURL = stagingURL(prefix: "remote-sync-initial-", suffix: ".sqlite3.gz")
        let databaseURL = stagingURL(prefix: "remote-sync-initial-", suffix: ".sqlite3")

        do {
            try archiveData.write(to: archiveURL, options: .atomic)
            let databaseData = try Self.gunzip(archiveData)
            try databaseData.write(to: databaseURL, options: .atomic)

            let schemaVersion = try Self.sqliteUserVersion(at: databaseURL)
            if schemaVersion > currentSchemaVersion {
                throw RemoteSyncArchiveStagingError.incompatibleInitialBackupVersion(schemaVersion)
            }

            try? fileManager.removeItem(at: archiveURL)
            return RemoteSyncStagedInitialBackup(
                remoteFile: remoteFile,
                databaseFileURL: databaseURL,
                schemaVersion: schemaVersion
            )
        } catch {
            cleanup(urls: [archiveURL, databaseURL])
            throw error
        }
    }

    /**
     Downloads remote patch archives into temporary gzip files in the supplied order.

     - Parameter patches: Pending remote patch descriptors, typically already sorted by discovery order.
     - Returns: Temporary archive files paired with their originating remote patch metadata.
     - Side effects:
       - downloads each remote patch archive
       - writes one temporary gzip file per patch
       - removes already staged patch files if a later download or write fails
     - Failure modes:
       - rethrows remote transport failures from the adapter
       - rethrows filesystem write errors while staging files
     */
    public func downloadPatchArchives(
        _ patches: [RemoteSyncDiscoveredPatch]
    ) async throws -> [RemoteSyncStagedPatchArchive] {
        var stagedArchives: [RemoteSyncStagedPatchArchive] = []

        do {
            for patch in patches {
                let archiveData = try await adapter.download(id: patch.file.id)
                let archiveURL = stagingURL(prefix: "remote-sync-patch-", suffix: ".sqlite3.gz")
                try archiveData.write(to: archiveURL, options: .atomic)
                stagedArchives.append(
                    RemoteSyncStagedPatchArchive(patch: patch, archiveFileURL: archiveURL)
                )
            }
            return stagedArchives
        } catch {
            cleanup(urls: stagedArchives.map(\.archiveFileURL))
            throw error
        }
    }

    /**
     Removes one staged initial-backup database file when the caller is finished with it.

     - Parameter stagedBackup: Previously staged initial-backup payload.
     - Side effects: deletes the staged SQLite file when present.
     - Failure modes: Delete errors are swallowed because cleanup is best effort.
     */
    public func cleanupInitialBackup(_ stagedBackup: RemoteSyncStagedInitialBackup) {
        cleanup(urls: [stagedBackup.databaseFileURL])
    }

    /**
     Removes staged patch archives when the caller is finished with them.

     - Parameter stagedArchives: Previously staged patch archives.
     - Side effects: deletes the staged gzip files when present.
     - Failure modes: Delete errors are swallowed because cleanup is best effort.
     */
    public func cleanupPatchArchives(_ stagedArchives: [RemoteSyncStagedPatchArchive]) {
        cleanup(urls: stagedArchives.map(\.archiveFileURL))
    }

    /**
     Compresses raw bytes into a gzip payload.

     This helper exists so simulator tests can generate Android-compatible archive fixtures and so
     future upload work can reuse the same codec boundary.

     - Parameter data: Raw uncompressed payload bytes.
     - Returns: Gzip-compressed payload.
     - Side effects: none.
     - Failure modes: Throws `RemoteSyncArchiveStagingError.compressionFailed` when compression fails.
     */
    static func gzip(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = ptr.baseAddress else {
                throw RemoteSyncArchiveStagingError.compressionFailed
            }

            var outputLength: UInt = 0
            guard let output = gzip_data(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(data.count),
                &outputLength
            ) else {
                throw RemoteSyncArchiveStagingError.compressionFailed
            }

            defer { gunzip_free(output) }
            return Data(bytes: output, count: Int(outputLength))
        }
    }

    private func stagingURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    private func cleanup(urls: [URL]) {
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func gunzip(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = ptr.baseAddress else {
                throw RemoteSyncArchiveStagingError.decompressionFailed
            }

            var outputLength: UInt = 0
            guard let output = gunzip_data(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(data.count),
                &outputLength
            ) else {
                throw RemoteSyncArchiveStagingError.decompressionFailed
            }

            defer { gunzip_free(output) }
            return Data(bytes: output, count: Int(outputLength))
        }
    }

    private static func sqliteUserVersion(at url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            if let database {
                sqlite3_close(database)
            }
            throw RemoteSyncArchiveStagingError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            if let statement {
                sqlite3_finalize(statement)
            }
            throw RemoteSyncArchiveStagingError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw RemoteSyncArchiveStagingError.invalidSQLiteDatabase
        }
        return Int(sqlite3_column_int(statement, 0))
    }
}
