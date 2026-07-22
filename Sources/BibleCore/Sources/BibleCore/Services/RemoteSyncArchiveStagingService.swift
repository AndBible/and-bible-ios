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
    /// Maximum accepted compressed initial-backup bytes.
    static let maximumCompressedInitialBackupByteCount = 64 * 1_024 * 1_024

    /// Maximum accepted expanded initial-backup SQLite bytes.
    static let maximumExpandedInitialBackupByteCount = 256 * 1_024 * 1_024

    /// Maximum accepted compressed bytes for one patch archive.
    static let maximumCompressedPatchByteCount = 16 * 1_024 * 1_024

    /// Maximum accepted expanded SQLite bytes for one patch archive.
    static let maximumExpandedPatchByteCount = 64 * 1_024 * 1_024

    /// Maximum cumulative expanded SQLite bytes staged in one patch batch.
    static let maximumCumulativeExpandedPatchByteCount = 256 * 1_024 * 1_024

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
     - category: Sync category represented by the staged database.
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
       - throws `RemoteSyncArchiveStagingError.incompatibleInitialBackupVersion` when the extracted
         database generation is not an authoritative migratable source or needs a newer schema
         version than `currentSchemaVersion`
     */
    public func downloadInitialBackup(
        _ remoteFile: RemoteSyncFile,
        category: RemoteSyncCategory,
        currentSchemaVersion: Int
    ) async throws -> RemoteSyncStagedInitialBackup {
        let archiveURL = stagingURL(prefix: "remote-sync-initial-", suffix: ".sqlite3.gz")
        let databaseURL = stagingURL(prefix: "remote-sync-initial-", suffix: ".sqlite3")

        do {
            try Task.checkCancellation()
            _ = try await adapter.download(
                id: remoteFile.id,
                to: archiveURL,
                maximumByteCount: Self.maximumCompressedInitialBackupByteCount
            )
            try Task.checkCancellation()
            let member = try RemoteSyncBoundedFileIO.inspectGzip(
                at: archiveURL,
                maximumCompressedByteCount: Self.maximumCompressedInitialBackupByteCount,
                maximumExpandedByteCount: Self.maximumExpandedInitialBackupByteCount
            )
            try RemoteSyncBoundedFileIO.inflateGzip(
                member,
                from: archiveURL,
                to: databaseURL,
                maximumExpandedByteCount: Self.maximumExpandedInitialBackupByteCount
            )
            try Task.checkCancellation()

            let schemaVersion = try Self.sqliteUserVersion(at: databaseURL)
            let isUnsupportedWorkspaceGeneration = category == .workspaces
                && !RemoteSyncWorkspaceDatabaseMigrator.supportsSourceVersion(schemaVersion)
            let isUnsupportedAISettingsGeneration = category == .aiSettings
                && !RemoteSyncAISettingsDatabaseMigrator.supportsSourceVersion(schemaVersion)
            if schemaVersion > currentSchemaVersion
                || isUnsupportedWorkspaceGeneration
                || isUnsupportedAISettingsGeneration {
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
        var createdArchiveURLs: [URL] = []
        var cumulativeExpandedByteCount: UInt64 = 0

        do {
            for patch in patches {
                try Task.checkCancellation()
                let archiveURL = stagingURL(prefix: "remote-sync-patch-", suffix: ".sqlite3.gz")
                createdArchiveURLs.append(archiveURL)
                _ = try await adapter.download(
                    id: patch.file.id,
                    to: archiveURL,
                    maximumByteCount: Self.maximumCompressedPatchByteCount
                )
                try Task.checkCancellation()
                let member = try RemoteSyncBoundedFileIO.inspectGzip(
                    at: archiveURL,
                    maximumCompressedByteCount: Self.maximumCompressedPatchByteCount,
                    maximumExpandedByteCount: Self.maximumExpandedPatchByteCount
                )
                let (nextCumulative, overflow) = cumulativeExpandedByteCount
                    .addingReportingOverflow(member.expandedByteCount)
                guard !overflow,
                      nextCumulative <= UInt64(Self.maximumCumulativeExpandedPatchByteCount) else {
                    throw RemoteSyncBoundedFileError.expandedSizeExceeded(
                        overflow ? UInt64.max : nextCumulative
                    )
                }
                cumulativeExpandedByteCount = nextCumulative
                stagedArchives.append(
                    RemoteSyncStagedPatchArchive(patch: patch, archiveFileURL: archiveURL)
                )
            }
            return stagedArchives
        } catch {
            cleanup(urls: createdArchiveURLs)
            throw error
        }
    }

    /**
     Streams one patch SQLite database into the exact inbound-compatible gzip contract.

     - Parameters:
       - databaseURL: Existing patch database written by a category-specific Room exporter.
       - archiveURL: Unique durable outbox location that must not already exist.
     - Returns: Exact archive size and SHA-256 digest produced during the write.
     - Side Effects: Reads `databaseURL`, creates and fsyncs `archiveURL`, and removes partial output
       on every failure or cancellation.
     - Throws: Cancellation or `RemoteSyncBoundedFileError` for unsafe files, compression failure,
       an expanded database above 64 MiB, or a complete gzip archive above 16 MiB.
     */
    static func gzipPatchDatabase(
        at databaseURL: URL,
        to archiveURL: URL
    ) throws -> RemoteSyncRegularFileFingerprint {
        try RemoteSyncBoundedFileIO.gzipRegularFile(
            at: databaseURL,
            to: archiveURL,
            maximumInputByteCount: maximumExpandedPatchByteCount,
            maximumOutputByteCount: maximumCompressedPatchByteCount
        )
    }

    /**
     Streams one full initial database into the larger bootstrap archive contract.

     - Parameters:
       - databaseURL: Existing full Android-compatible category database.
       - archiveURL: Unique durable retry location that must not already exist.
     - Returns: Exact archive size and SHA-256 digest produced during the write.
     - Side Effects: Reads `databaseURL`, creates and fsyncs `archiveURL`, and removes partial output
       on every failure or cancellation.
     - Throws: Cancellation or `RemoteSyncBoundedFileError` for unsafe files, compression failure,
       an expanded database above 256 MiB, or a complete gzip archive above 64 MiB.
     */
    static func gzipInitialBackupDatabase(
        at databaseURL: URL,
        to archiveURL: URL
    ) throws -> RemoteSyncRegularFileFingerprint {
        try RemoteSyncBoundedFileIO.gzipRegularFile(
            at: databaseURL,
            to: archiveURL,
            maximumInputByteCount: maximumExpandedInitialBackupByteCount,
            maximumOutputByteCount: maximumCompressedInitialBackupByteCount
        )
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
     - Failure modes: Throws `RemoteSyncArchiveStagingError.compressionFailed` when input, output,
       or compressor metadata exceeds the remote-sync archive contract.
     */
    static func gzip(_ data: Data) throws -> Data {
        guard data.count <= maximumExpandedInitialBackupByteCount,
              let context = raw_deflater_create() else {
            throw RemoteSyncArchiveStagingError.compressionFailed
        }
        defer { raw_deflater_destroy(context) }

        let maximumOutputByteCount = maximumCompressedInitialBackupByteCount
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        var inputOffset = 0
        while inputOffset < data.count {
            let inputEnd = min(inputOffset + 64 * 1_024, data.count)
            _ = try consumeGzipInput(
                data,
                range: inputOffset..<inputEnd,
                finish: false,
                context: context,
                output: &output,
                maximumOutputByteCount: maximumOutputByteCount
            )
            inputOffset = inputEnd
        }

        var reachedStreamEnd = false
        while !reachedStreamEnd {
            reachedStreamEnd = try consumeGzipInput(
                data,
                range: data.endIndex..<data.endIndex,
                finish: true,
                context: context,
                output: &output,
                maximumOutputByteCount: maximumOutputByteCount
            )
        }

        var checksum: UInt32 = 0
        var expandedByteCount: UInt64 = 0
        var compressedByteCount: UInt64 = 0
        guard raw_deflater_metadata(
            context,
            &checksum,
            &expandedByteCount,
            &compressedByteCount
        ) == 0,
            expandedByteCount == UInt64(data.count),
            compressedByteCount == UInt64(output.count - 10),
            output.count <= maximumOutputByteCount - 8 else {
            throw RemoteSyncArchiveStagingError.compressionFailed
        }

        try appendLittleEndian(checksum, to: &output, maximumByteCount: maximumOutputByteCount)
        try appendLittleEndian(
            UInt32(truncatingIfNeeded: expandedByteCount),
            to: &output,
            maximumByteCount: maximumOutputByteCount
        )
        return output
    }

    /** Supplies one bounded input range and appends only output admitted by the gzip ceiling. */
    private static func consumeGzipInput(
        _ input: Data,
        range: Range<Int>,
        finish: Bool,
        context: UnsafeMutableRawPointer,
        output: inout Data,
        maximumOutputByteCount: Int
    ) throws -> Bool {
        var inputOffset = range.lowerBound
        repeat {
            var outputBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
            let outputCapacity = UInt32(outputBuffer.count)
            var consumed: UInt32 = 0
            var produced: UInt32 = 0
            let result = outputBuffer.withUnsafeMutableBytes { outputBytes in
                input.withUnsafeBytes { inputBytes in
                    raw_deflater_process(
                        context,
                        inputBytes.baseAddress?
                            .assumingMemoryBound(to: UInt8.self)
                            .advanced(by: inputOffset),
                        UInt32(range.upperBound - inputOffset),
                        finish ? 1 : 0,
                        outputBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        outputCapacity,
                        &consumed,
                        &produced
                    )
                }
            }
            guard result >= 0,
                  result != 1 || finish,
                  output.count <= maximumOutputByteCount,
                  Int(produced) <= maximumOutputByteCount - output.count else {
                throw RemoteSyncArchiveStagingError.compressionFailed
            }
            if produced > 0 {
                output.append(contentsOf: outputBuffer.prefix(Int(produced)))
            }
            inputOffset += Int(consumed)
            if result == 1 {
                guard inputOffset == range.upperBound else {
                    throw RemoteSyncArchiveStagingError.compressionFailed
                }
                return true
            }
            guard consumed > 0 || produced > 0 else {
                throw RemoteSyncArchiveStagingError.compressionFailed
            }
        } while inputOffset < range.upperBound || range.isEmpty
        return false
    }

    /** Appends one gzip trailer word without crossing the compressed-byte ceiling. */
    private static func appendLittleEndian(
        _ value: UInt32,
        to output: inout Data,
        maximumByteCount: Int
    ) throws {
        guard output.count <= maximumByteCount - 4 else {
            throw RemoteSyncArchiveStagingError.compressionFailed
        }
        output.append(UInt8(truncatingIfNeeded: value))
        output.append(UInt8(truncatingIfNeeded: value >> 8))
        output.append(UInt8(truncatingIfNeeded: value >> 16))
        output.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func stagingURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    private func cleanup(urls: [URL]) {
        for url in urls {
            try? fileManager.removeItem(at: url)
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
