// ZipArchiveReader.swift — ZIP central-directory extraction helper

import CLibSword
import Foundation
import SwordKit

/**
 Errors raised while reading ZIP archives.

 The reader is intentionally small and supports the ZIP shapes AndBible consumes locally:
 central-directory based stored or deflated file entries. Unsupported compression methods and
 malformed offsets/sizes are rejected explicitly so callers can surface actionable archive errors
 instead of treating missing entries as valid empty archives.
 */
public enum ZipArchiveReaderError: Error, Equatable {
    /// The archive did not contain a readable ZIP end-of-central-directory record.
    case missingCentralDirectory

    /// A central-directory or local-file header was malformed or pointed outside the payload.
    case invalidArchive(String)

    /// The archive used a compression method this reader does not support.
    case unsupportedCompressionMethod(UInt16)

    /// A deflated member could not be inflated to the declared size.
    case decompressionFailed
}

/**
 One extracted file entry from a ZIP archive.

 Directory entries are omitted by `ZipArchiveReader.entries(in:)`, so every returned entry has a
 non-empty file name and materialized file bytes.
 */
public struct ZipArchiveEntry: Sendable, Equatable {
    /// Path-like entry name recorded in the ZIP central directory.
    public let name: String

    /// Uncompressed file payload.
    public let data: Data

    /**
     Creates one extracted ZIP entry.

     - Parameters:
       - name: Path-like entry name recorded in the ZIP central directory.
       - data: Uncompressed file payload.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/**
 One ZIP entry whose payload remains in a file-backed archive.

 File-backed entries are used by Android backup restore so large archive members can be copied or
 inflated directly to staging files without loading the full archive or full payload into memory.
 */
public struct ZipArchiveFileEntry: Sendable, Equatable {
    /// Path-like entry name recorded in the ZIP central directory.
    public let name: String

    /// ZIP compression method: `0` for stored, `8` for raw deflate.
    public let compressionMethod: UInt16

    /// Compressed payload byte count from the central directory.
    public let compressedSize: UInt64

    /// Uncompressed payload byte count from the central directory.
    public let uncompressedSize: UInt64

    /// CRC32 of the uncompressed payload from the central directory.
    let checksum: UInt32

    /// Offset of the local file header in the archive.
    let localHeaderOffset: UInt64

    /// Offset of the compressed payload bytes in the archive.
    let dataOffset: UInt64

    /**
     Creates one file-backed ZIP entry descriptor.

     - Parameters:
       - name: Path-like ZIP entry name.
       - compressionMethod: ZIP compression method.
       - compressedSize: Compressed payload byte count.
       - uncompressedSize: Uncompressed payload byte count.
       - checksum: CRC32 of the uncompressed payload.
       - localHeaderOffset: Local file header offset.
       - dataOffset: Compressed payload byte offset.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    init(
        name: String,
        compressionMethod: UInt16,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        checksum: UInt32,
        localHeaderOffset: UInt64,
        dataOffset: UInt64
    ) {
        self.name = name
        self.compressionMethod = compressionMethod
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.checksum = checksum
        self.localHeaderOffset = localHeaderOffset
        self.dataOffset = dataOffset
    }
}

/**
 Extracts stored and deflated ZIP file members using the archive's central directory.

 Android's `ZipOutputStream` may write data descriptors after deflated entries, leaving local-file
 header size fields unset. Reading the central directory first mirrors how platform ZIP readers
 resolve those archives and prevents iOS backup restore from rejecting valid Android backups.
 */
public enum ZipArchiveReader {
    private static let localFileHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x0201_4b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let zip64EndOfCentralDirectorySignature: UInt32 = 0x0606_4b50
    private static let zip64EndOfCentralDirectoryLocatorSignature: UInt32 = 0x0706_4b50
    private static let zip64ExtendedInformationExtraFieldID: UInt16 = 0x0001
    private static let zip64Sentinel: UInt32 = 0xffff_ffff
    private static let zip64EntryCountSentinel: UInt16 = 0xffff
    private static let zip64DiskSentinel: UInt16 = 0xffff
    private static let encryptedEntryFlag: UInt16 = 0x0001
    private static let storedCompressionMethod: UInt16 = 0
    private static let deflatedCompressionMethod: UInt16 = 8
    private static let endOfCentralDirectoryMinimumByteCount = 22
    private static let zip64EndOfCentralDirectoryMinimumByteCount = 56
    private static let zip64EndOfCentralDirectoryLocatorByteCount = 20
    private static let maximumZipCommentByteCount = 0xffff
    private static let localFileHeaderByteCount = 30
    private static let centralDirectoryHeaderByteCount = 46
    private static let fileExtractionChunkByteCount = 64 * 1024
    /// Hard metadata bound applied before reserving arrays or scanning central-directory entries.
    private static let maximumCentralDirectoryEntryCount = 1_000_000

    /// Shared parser policy for generic file-backed/eager ZIP APIs without arbitrary byte ceilings.
    private static var sharedMetadataLimits: AndroidModuleBackupArchiveLimits {
        AndroidModuleBackupArchiveLimits(
            maximumArchiveByteCount: .max,
            maximumEntryCount: maximumCentralDirectoryEntryCount,
            maximumEntryCompressedByteCount: .max,
            maximumEntryExpandedByteCount: .max,
            maximumAggregateCompressedByteCount: .max,
            maximumAggregateExpandedByteCount: .max,
            maximumExpansionRatio: .max,
            maximumMetadataEntryByteCount: .max,
            maximumPathByteCount: UInt64(UInt16.max)
        )
    }

    /**
     Central-directory metadata for one file entry that passed pre-extraction validation.
     */
    private struct CentralDirectoryFileEntry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let checksum: UInt32
        let localHeaderOffset: Int
    }

    /**
     File-backed central-directory location parsed from a ZIP end record.
     */
    private struct FileBackedCentralDirectory {
        let offset: UInt64
        let size: UInt64
        let entryCount: Int
    }

    /**
     Resolved central-directory fields after applying a ZIP64 extended-information record.
     */
    private struct ResolvedCentralDirectoryEntry {
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    /**
     Reads ZIP entry names from central-directory metadata without materializing payload bytes.

     This is intended for routing decisions that only need archive structure, such as detecting an
     EPUB that arrived through a ZIP-looking document provider. It opens the archive, scans only the
     legal end-of-central-directory search window, then reads one central-directory header/name at a
     time so large module payloads are never mapped or copied into memory.

     - Parameter url: File URL for a ZIP archive.
     - Returns: Entry names in central-directory order.
     - Side effects: Opens, seeks, and reads `url`.
     - Throws:
       - `ZipArchiveReaderError.missingCentralDirectory` when no ZIP end record is present
      - `ZipArchiveReaderError.invalidArchive` when central-directory metadata is malformed,
        truncated, multi-disk, or contains a non-UTF-8 entry name
       - file-system errors from opening, seeking, or reading the archive
     */
    public static func entryNames(inArchiveAt url: URL) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        let fileSize = try handle.seekToEnd()
        let centralDirectory = try fileBackedCentralDirectory(from: handle, fileSize: fileSize)
        return try fileBackedEntryNames(from: handle, centralDirectory: centralDirectory)
    }

    /**
     Reads file-backed ZIP entry metadata without materializing payload bytes.

     Unlike `entries(in:)`, this API is intended for restore paths that stream selected payloads to
     disk. It validates central-directory, local-header, compression, and payload-range metadata,
     but does not apply the eager reader's memory caps because no archive member is allocated here.

     - Parameter url: File URL for a ZIP archive.
     - Returns: Non-directory file entries in central-directory order.
     - Side effects: Opens, seeks, and reads metadata from `url`.
     - Throws:
       - `ZipArchiveReaderError.missingCentralDirectory` when no ZIP end record is present
      - `ZipArchiveReaderError.invalidArchive` for malformed, spanned, encrypted, or out-of-bounds
        entries
       - `ZipArchiveReaderError.unsupportedCompressionMethod` for non-stored/non-deflated entries
       - file-system errors from opening, seeking, or reading the archive
     */
    public static func fileEntries(inArchiveAt url: URL) throws -> [ZipArchiveFileEntry] {
        let metadata: AndroidModuleBackupZIPMetadata
        do {
            metadata = try AndroidModuleBackupZIPMetadataParser.parse(
                at: url,
                limits: sharedMetadataLimits
            )
        } catch let error as AndroidModuleBackupArchivePlannerError {
            throw zipReaderError(error)
        }
        return metadata.entries
            .filter { !$0.isDirectory }
            .sorted { $0.centralDirectoryPosition < $1.centralDirectoryPosition }
            .map { entry in
                ZipArchiveFileEntry(
                    name: entry.rawPath,
                    compressionMethod: entry.compressionMethod,
                    compressedSize: entry.compressedByteCount,
                    uncompressedSize: entry.expandedByteCount,
                    checksum: entry.crc32,
                    localHeaderOffset: entry.localHeaderOffset,
                    dataOffset: entry.payloadOffset
                )
            }
    }

    /**
     Extracts one file-backed ZIP entry to a destination file.

     Stored entries are copied in bounded chunks. Deflated entries are streamed through the shared
     zlib C bridge, so Android backup restore can handle large database/module payloads without
     allocating the compressed or uncompressed member as `Data`.

     - Parameters:
       - entry: File-backed entry metadata returned by `fileEntries(inArchiveAt:)`.
       - url: File URL for the ZIP archive that owns `entry`.
       - destinationURL: File URL to create with the uncompressed payload.
       - fileManager: File manager used for parent-directory creation and cleanup.
     - Side effects: Creates or replaces `destinationURL`.
     - Failure modes:
       - throws `ZipArchiveReaderError.invalidArchive` when the payload range is outside the
         archive or size metadata is inconsistent
       - throws `ZipArchiveReaderError.unsupportedCompressionMethod` for non-stored/non-deflated
         entries
       - throws `ZipArchiveReaderError.decompressionFailed` when zlib cannot inflate the entry or
         writes a byte count that does not match central-directory metadata
       - rethrows file-system errors from reading or writing files
     */
    public static func extract(
        _ entry: ZipArchiveFileEntry,
        fromArchiveAt url: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try Task.checkCancellation()
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: destinationURL)

        do {
            switch entry.compressionMethod {
            case storedCompressionMethod:
                try copyStoredFileEntry(entry, fromArchiveAt: url, to: destinationURL, fileManager: fileManager)
            case deflatedCompressionMethod:
                try inflateDeflatedFileEntry(entry, fromArchiveAt: url, to: destinationURL, fileManager: fileManager)
            default:
                throw ZipArchiveReaderError.unsupportedCompressionMethod(entry.compressionMethod)
            }
            try Task.checkCancellation()
            guard try ArchiveCRC32.checksum(fileAt: destinationURL) == entry.checksum else {
                throw ZipArchiveReaderError.invalidArchive(
                    "ZIP entry checksum mismatch: \(entry.name)"
                )
            }
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    /**
     Reads a small file-backed ZIP entry into memory.

     Restore services use this only for manifests and similar metadata. Large database and module
     payloads should be streamed with `extract(_:fromArchiveAt:to:fileManager:)`.

     - Parameters:
       - entry: File-backed entry metadata returned by `fileEntries(inArchiveAt:)`.
       - url: File URL for the ZIP archive that owns `entry`.
       - maximumByteCount: Largest uncompressed payload the caller is willing to materialize.
       - fileManager: File manager used for temporary extraction and cleanup.
     - Returns: Uncompressed entry payload bytes.
     - Side effects: Creates and removes one temporary file.
     - Failure modes: Throws when `entry` exceeds `maximumByteCount`, extraction fails, or the
       temporary file cannot be read.
     */
    public static func data(
        for entry: ZipArchiveFileEntry,
        inArchiveAt url: URL,
        maximumByteCount: Int,
        fileManager: FileManager = .default
    ) throws -> Data {
        guard entry.uncompressedSize <= UInt64(maximumByteCount) else {
            throw ZipArchiveReaderError.invalidArchive("ZIP entry exceeds maximum supported size")
        }
        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("zip-entry-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }
        try extract(entry, fromArchiveAt: url, to: temporaryURL, fileManager: fileManager)
        return try Data(contentsOf: temporaryURL)
    }

    /**
     Extracts supported file entries from raw ZIP data.

     This compatibility API is intentionally eager because its caller already owns complete archive
     bytes. It applies platform-size checks but no fixed 256/512 MiB policy; production large-file
     restore uses `fileEntries(inArchiveAt:)` plus bounded streaming extraction.

     - Parameter data: Raw ZIP archive bytes.
     - Returns: Uncompressed non-directory entries in central-directory order.
     - Side effects: none.
     - Failure modes:
       - throws `ZipArchiveReaderError.missingCentralDirectory` when the archive is not ZIP-shaped
       - throws `ZipArchiveReaderError.invalidArchive` when a header is truncated or inconsistent
       - throws `ZipArchiveReaderError.invalidArchive` when the end record describes a spanned
         archive instead of the single-disk ZIP shape Android backups use
       - throws `ZipArchiveReaderError.invalidArchive` when declared sizes exceed platform indexes
       - throws `ZipArchiveReaderError.invalidArchive` when materialized entry sizes do not match
         central-directory declarations
       - throws `ZipArchiveReaderError.unsupportedCompressionMethod` for non-stored/non-deflated entries
       - throws `ZipArchiveReaderError.decompressionFailed` when the C inflater cannot decode an entry
     */
    public static func entries(in data: Data) throws -> [ZipArchiveEntry] {
        let metadata: AndroidModuleBackupZIPMetadata
        do {
            metadata = try AndroidModuleBackupZIPMetadataParser.parse(
                data,
                limits: sharedMetadataLimits
            )
        } catch let error as AndroidModuleBackupArchivePlannerError {
            throw zipReaderError(error)
        }
        return try metadata.entries
            .filter { !$0.isDirectory }
            .sorted { $0.centralDirectoryPosition < $1.centralDirectoryPosition }
            .map { entry in
            try Task.checkCancellation()
            guard entry.payloadOffset <= UInt64(Int.max),
                  entry.compressedByteCount <= UInt64(Int.max),
                  entry.expandedByteCount <= UInt64(Int.max),
                  entry.payloadOffset <= UInt64(data.count),
                  entry.compressedByteCount <= UInt64(data.count) - entry.payloadOffset else {
                throw ZipArchiveReaderError.invalidArchive("ZIP entry exceeds platform limits")
            }
            let start = Int(entry.payloadOffset)
            let compressedSize = Int(entry.compressedByteCount)
            let compressedData = Data(data[start..<(start + compressedSize)])
            let fileData: Data
            switch entry.compressionMethod {
            case storedCompressionMethod:
                fileData = compressedData
            case deflatedCompressionMethod:
                fileData = try inflateData(
                    compressedData,
                    uncompressedSize: Int(entry.expandedByteCount)
                )
                try validateInflatedEntrySize(
                    fileData.count,
                    expectedSize: Int(entry.expandedByteCount)
                )
            default:
                throw ZipArchiveReaderError.unsupportedCompressionMethod(entry.compressionMethod)
            }
            guard ArchiveCRC32.checksum(of: fileData) == entry.crc32 else {
                throw ZipArchiveReaderError.invalidArchive(
                    "ZIP entry checksum mismatch: \(entry.rawPath)"
                )
            }
            return ZipArchiveEntry(name: entry.rawPath, data: fileData)
        }
    }

    /**
     Resolves standard or ZIP64 central-directory metadata from an in-memory archive.

     - Parameters:
       - data: Complete ZIP archive bytes.
       - endRecordOffset: Validated EOCD offset in `data`.
     - Returns: Bounded central-directory location and entry count.
     - Side effects: none.
     - Failure modes: Throws for malformed ZIP64 locators/records, multi-disk metadata, excessive
       entry counts, or directory ranges outside the archive.
     */
    private static func dataBackedCentralDirectory(
        in data: Data,
        endRecordOffset: Int
    ) throws -> FileBackedCentralDirectory {
        let endRecord = Data(
            data[endRecordOffset..<(endRecordOffset + endOfCentralDirectoryMinimumByteCount)]
        )
        return try resolvedCentralDirectory(
            endRecord: endRecord,
            endRecordArchiveOffset: UInt64(endRecordOffset),
            archiveSize: UInt64(data.count),
            readBytes: { offset, count in
                guard offset <= UInt64(data.count),
                      UInt64(count) <= UInt64(data.count) - offset,
                      offset <= UInt64(Int.max) else {
                    throw ZipArchiveReaderError.invalidArchive("ZIP64 structure points outside archive")
                }
                let start = Int(offset)
                return Data(data[start..<(start + count)])
            }
        )
    }

    /**
     Resolves the central directory described by one classic EOCD and an optional ZIP64 trailer.

     ZIP64 lookup is bounded to the fixed locator immediately before the classic EOCD. The locator
     must point to a complete record ending exactly at that locator, preventing an attacker from
     triggering an unbounded signature scan or redirecting metadata reads into entry payloads.

     - Parameters:
       - endRecord: The fixed 22-byte classic EOCD prefix.
       - endRecordArchiveOffset: Absolute EOCD offset in the archive.
       - archiveSize: Complete archive byte count.
       - readBytes: Exact bounded archive reader.
     - Returns: Validated central-directory location and count.
     - Side effects: Invokes `readBytes` for ZIP64 metadata when classic fields contain sentinels.
     - Failure modes: Throws for malformed, inconsistent, multi-disk, oversized, or out-of-bounds
       central-directory metadata.
     */
    private static func resolvedCentralDirectory(
        endRecord: Data,
        endRecordArchiveOffset: UInt64,
        archiveSize: UInt64,
        readBytes: (UInt64, Int) throws -> Data
    ) throws -> FileBackedCentralDirectory {
        let diskNumberRaw = readUInt16(endRecord, at: 4)
        let centralDirectoryDiskRaw = readUInt16(endRecord, at: 6)
        let diskEntryCountRaw = readUInt16(endRecord, at: 8)
        let entryCountRaw = readUInt16(endRecord, at: 10)
        let centralDirectorySizeRaw = readUInt32(endRecord, at: 12)
        let centralDirectoryOffsetRaw = readUInt32(endRecord, at: 16)
        let requiresZip64 = diskNumberRaw == zip64DiskSentinel
            || centralDirectoryDiskRaw == zip64DiskSentinel
            || diskEntryCountRaw == zip64EntryCountSentinel
            || entryCountRaw == zip64EntryCountSentinel
            || centralDirectorySizeRaw == zip64Sentinel
            || centralDirectoryOffsetRaw == zip64Sentinel

        if requiresZip64 {
            return try zip64CentralDirectory(
                endRecordArchiveOffset: endRecordArchiveOffset,
                archiveSize: archiveSize,
                diskNumberRaw: diskNumberRaw,
                centralDirectoryDiskRaw: centralDirectoryDiskRaw,
                diskEntryCountRaw: diskEntryCountRaw,
                entryCountRaw: entryCountRaw,
                centralDirectorySizeRaw: centralDirectorySizeRaw,
                centralDirectoryOffsetRaw: centralDirectoryOffsetRaw,
                readBytes: readBytes
            )
        }

        guard diskNumberRaw == 0,
              centralDirectoryDiskRaw == 0,
              diskEntryCountRaw == entryCountRaw else {
            throw ZipArchiveReaderError.invalidArchive("Multi-disk ZIP archives are not supported")
        }
        return try validatedCentralDirectory(
            offset: UInt64(centralDirectoryOffsetRaw),
            size: UInt64(centralDirectorySizeRaw),
            entryCount: UInt64(entryCountRaw),
            trailerOffset: endRecordArchiveOffset,
            archiveSize: archiveSize
        )
    }

    /**
     Parses a ZIP64 locator and EOCD record without scanning outside their fixed trailer positions.

     - Parameters: Classic EOCD values plus archive bounds and an exact byte reader.
     - Returns: ZIP64 central-directory metadata after consistency checks against non-sentinel
       classic fields.
     - Side effects: Reads the 20-byte locator and fixed ZIP64 EOCD prefix.
     - Failure modes: Throws for missing/truncated records, multi-disk archives, inconsistent legacy
       fields, invalid versions, or records that do not end at the locator.
     */
    private static func zip64CentralDirectory(
        endRecordArchiveOffset: UInt64,
        archiveSize: UInt64,
        diskNumberRaw: UInt16,
        centralDirectoryDiskRaw: UInt16,
        diskEntryCountRaw: UInt16,
        entryCountRaw: UInt16,
        centralDirectorySizeRaw: UInt32,
        centralDirectoryOffsetRaw: UInt32,
        readBytes: (UInt64, Int) throws -> Data
    ) throws -> FileBackedCentralDirectory {
        guard endRecordArchiveOffset >= UInt64(zip64EndOfCentralDirectoryLocatorByteCount) else {
            throw ZipArchiveReaderError.invalidArchive("ZIP64 end-of-central-directory locator is missing")
        }
        let locatorOffset = endRecordArchiveOffset - UInt64(zip64EndOfCentralDirectoryLocatorByteCount)
        let locator = try readBytes(locatorOffset, zip64EndOfCentralDirectoryLocatorByteCount)
        guard readUInt32(locator, at: 0) == zip64EndOfCentralDirectoryLocatorSignature else {
            throw ZipArchiveReaderError.invalidArchive("ZIP64 end-of-central-directory locator is missing")
        }
        let recordDisk = readUInt32(locator, at: 4)
        let recordOffset = readUInt64(locator, at: 8)
        let totalDisks = readUInt32(locator, at: 16)
        guard recordDisk == 0, totalDisks == 1 else {
            throw ZipArchiveReaderError.invalidArchive("Multi-disk ZIP archives are not supported")
        }
        guard recordOffset <= locatorOffset,
              UInt64(zip64EndOfCentralDirectoryMinimumByteCount) <= locatorOffset - recordOffset else {
            throw ZipArchiveReaderError.invalidArchive("ZIP64 end-of-central-directory record is truncated")
        }

        let record = try readBytes(recordOffset, zip64EndOfCentralDirectoryMinimumByteCount)
        guard readUInt32(record, at: 0) == zip64EndOfCentralDirectorySignature else {
            throw ZipArchiveReaderError.invalidArchive("ZIP64 end-of-central-directory record is missing")
        }
        let recordPayloadSize = readUInt64(record, at: 4)
        guard recordPayloadSize >= 44,
              recordPayloadSize <= UInt64.max - 12,
              recordPayloadSize + 12 == locatorOffset - recordOffset else {
            throw ZipArchiveReaderError.invalidArchive("ZIP64 end-of-central-directory record has an invalid size")
        }
        guard readUInt16(record, at: 14) >= 45 else {
            throw ZipArchiveReaderError.invalidArchive("ZIP64 end-of-central-directory version is invalid")
        }

        let diskNumber = readUInt32(record, at: 16)
        let centralDirectoryDisk = readUInt32(record, at: 20)
        let diskEntryCount = readUInt64(record, at: 24)
        let entryCount = readUInt64(record, at: 32)
        let centralDirectorySize = readUInt64(record, at: 40)
        let centralDirectoryOffset = readUInt64(record, at: 48)
        guard diskNumber == 0,
              centralDirectoryDisk == 0,
              diskEntryCount == entryCount else {
            throw ZipArchiveReaderError.invalidArchive("Multi-disk ZIP archives are not supported")
        }
        guard (diskNumberRaw == zip64DiskSentinel || UInt32(diskNumberRaw) == diskNumber),
              (centralDirectoryDiskRaw == zip64DiskSentinel
                  || UInt32(centralDirectoryDiskRaw) == centralDirectoryDisk),
              (diskEntryCountRaw == zip64EntryCountSentinel
                  || UInt64(diskEntryCountRaw) == diskEntryCount),
              (entryCountRaw == zip64EntryCountSentinel || UInt64(entryCountRaw) == entryCount),
              (centralDirectorySizeRaw == zip64Sentinel
                  || UInt64(centralDirectorySizeRaw) == centralDirectorySize),
              (centralDirectoryOffsetRaw == zip64Sentinel
                  || UInt64(centralDirectoryOffsetRaw) == centralDirectoryOffset) else {
            throw ZipArchiveReaderError.invalidArchive("ZIP64 metadata conflicts with the classic end record")
        }

        return try validatedCentralDirectory(
            offset: centralDirectoryOffset,
            size: centralDirectorySize,
            entryCount: entryCount,
            trailerOffset: recordOffset,
            archiveSize: archiveSize
        )
    }

    /**
     Applies archive and allocation bounds to resolved central-directory metadata.

     - Parameters:
       - offset: Absolute central-directory offset.
       - size: Central-directory byte count.
       - entryCount: Declared number of central-directory entries.
       - trailerOffset: First byte of the ZIP trailer following the directory.
       - archiveSize: Complete archive byte count.
     - Returns: Integer-sized metadata safe for parser loops and array reservation.
     - Side effects: none.
     - Failure modes: Throws for overflow, out-of-bounds ranges, impossible entry counts, or the
       configured metadata-count limit.
     */
    private static func validatedCentralDirectory(
        offset: UInt64,
        size: UInt64,
        entryCount: UInt64,
        trailerOffset: UInt64,
        archiveSize: UInt64
    ) throws -> FileBackedCentralDirectory {
        guard offset <= archiveSize,
              size <= archiveSize - offset,
              offset <= trailerOffset,
              size <= trailerOffset - offset else {
            throw ZipArchiveReaderError.invalidArchive("Central directory points outside archive")
        }
        guard entryCount <= UInt64(maximumCentralDirectoryEntryCount),
              entryCount <= UInt64(Int.max) else {
            throw ZipArchiveReaderError.invalidArchive("ZIP archive contains too many entries")
        }
        guard entryCount == 0 ? size == 0 : entryCount <= size / UInt64(centralDirectoryHeaderByteCount) else {
            throw ZipArchiveReaderError.invalidArchive("Central directory entry count mismatch")
        }
        return FileBackedCentralDirectory(offset: offset, size: size, entryCount: Int(entryCount))
    }

    /**
     Parses the central-directory range from a file-backed ZIP end record.

     - Parameters:
       - handle: Open ZIP file handle, owned by the caller.
       - fileSize: Total archive byte count.
     - Returns: Central-directory byte range and entry count.
     - Side effects: Seeks and reads from `handle`.
     - Failure modes: Throws when the end record is missing or describes unsupported/malformed ZIP
       metadata.
     */
    private static func fileBackedCentralDirectory(
        from handle: FileHandle,
        fileSize: UInt64
    ) throws -> FileBackedCentralDirectory {
        guard fileSize >= UInt64(endOfCentralDirectoryMinimumByteCount) else {
            throw ZipArchiveReaderError.missingCentralDirectory
        }

        let searchLength = min(
            fileSize,
            UInt64(endOfCentralDirectoryMinimumByteCount + maximumZipCommentByteCount)
        )
        let tail = try readZipBytes(
            from: handle,
            offset: fileSize - searchLength,
            count: Int(searchLength)
        )
        let endRecordOffset = try endOfCentralDirectoryOffset(inTail: tail)
        let absoluteEndRecordOffset = fileSize - searchLength + UInt64(endRecordOffset)
        let endRecord = Data(
            tail[endRecordOffset..<(endRecordOffset + endOfCentralDirectoryMinimumByteCount)]
        )
        return try resolvedCentralDirectory(
            endRecord: endRecord,
            endRecordArchiveOffset: absoluteEndRecordOffset,
            archiveSize: fileSize,
            readBytes: { offset, count in
                try readZipBytes(from: handle, offset: offset, count: count)
            }
        )
    }

    /**
     Reads central-directory entry names one header at a time from an open archive.

     - Parameters:
       - handle: Open ZIP file handle, owned by the caller.
       - centralDirectory: Central-directory range parsed from the end record.
     - Returns: UTF-8 entry names in central-directory order.
     - Side effects: Seeks and reads from `handle`.
     - Failure modes: Throws when the central directory is truncated, malformed, or contains a
       non-UTF-8 name.
     */
    private static func fileBackedEntryNames(
        from handle: FileHandle,
        centralDirectory: FileBackedCentralDirectory
    ) throws -> [String] {
        guard centralDirectory.size > 0 else {
            return []
        }

        var names: [String] = []
        names.reserveCapacity(centralDirectory.entryCount)
        var offset = centralDirectory.offset
        let directoryEnd = centralDirectory.offset + centralDirectory.size
        for _ in 0..<centralDirectory.entryCount {
            guard UInt64(centralDirectoryHeaderByteCount) <= directoryEnd - offset else {
                throw ZipArchiveReaderError.invalidArchive("Central directory entry is truncated")
            }
            let header = try readZipBytes(
                from: handle,
                offset: offset,
                count: centralDirectoryHeaderByteCount
            )
            guard readUInt32(header, at: 0) == centralDirectoryHeaderSignature else {
                throw ZipArchiveReaderError.invalidArchive("Central directory entry has an invalid signature")
            }

            let nameLength = UInt64(readUInt16(header, at: 28))
            let extraLength = UInt64(readUInt16(header, at: 30))
            let commentLength = UInt64(readUInt16(header, at: 32))
            let metadataLength = UInt64(centralDirectoryHeaderByteCount) + nameLength + extraLength + commentLength
            guard metadataLength <= directoryEnd - offset else {
                throw ZipArchiveReaderError.invalidArchive("Central directory entry metadata is truncated")
            }

            let extraData = try readZipBytes(
                from: handle,
                offset: offset + UInt64(centralDirectoryHeaderByteCount) + nameLength,
                count: Int(extraLength)
            )
            _ = try resolvedCentralDirectoryEntry(
                compressedSizeRaw: readUInt32(header, at: 20),
                uncompressedSizeRaw: readUInt32(header, at: 24),
                localHeaderOffsetRaw: readUInt32(header, at: 42),
                diskStartRaw: readUInt16(header, at: 34),
                extraFieldData: extraData
            )

            let nameData = try readZipBytes(
                from: handle,
                offset: offset + UInt64(centralDirectoryHeaderByteCount),
                count: Int(nameLength)
            )
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ZipArchiveReaderError.invalidArchive("Central directory entry name is not UTF-8")
            }
            names.append(name)
            offset += metadataLength
        }

        guard offset == directoryEnd else {
            throw ZipArchiveReaderError.invalidArchive("Central directory contains trailing bytes")
        }
        return names
    }

    /**
     Reads file-backed central-directory entries and validates their local payload ranges.

     - Parameters:
       - handle: Open ZIP file handle, owned by the caller.
       - centralDirectory: Central-directory range parsed from the end record.
       - fileSize: Total archive byte count.
     - Returns: File-backed entry descriptors in central-directory order.
     - Side effects: Seeks and reads metadata from `handle`.
     - Failure modes: Throws when directory metadata, local headers, compression methods, or payload
       ranges are unsupported or malformed.
     */
    private static func fileBackedEntries(
        from handle: FileHandle,
        centralDirectory: FileBackedCentralDirectory,
        fileSize: UInt64
    ) throws -> [ZipArchiveFileEntry] {
        guard centralDirectory.size > 0 else {
            return []
        }

        var entries: [ZipArchiveFileEntry] = []
        entries.reserveCapacity(centralDirectory.entryCount)
        var offset = centralDirectory.offset
        let directoryEnd = centralDirectory.offset + centralDirectory.size
        for _ in 0..<centralDirectory.entryCount {
            guard UInt64(centralDirectoryHeaderByteCount) <= directoryEnd - offset else {
                throw ZipArchiveReaderError.invalidArchive("Central directory entry is truncated")
            }
            let header = try readZipBytes(
                from: handle,
                offset: offset,
                count: centralDirectoryHeaderByteCount
            )
            guard readUInt32(header, at: 0) == centralDirectoryHeaderSignature else {
                throw ZipArchiveReaderError.invalidArchive("Central directory entry has an invalid signature")
            }

            let generalPurposeFlags = readUInt16(header, at: 8)
            let method = readUInt16(header, at: 10)
            let checksum = readUInt32(header, at: 16)
            let compressedSizeRaw = readUInt32(header, at: 20)
            let uncompressedSizeRaw = readUInt32(header, at: 24)
            let nameLength = UInt64(readUInt16(header, at: 28))
            let extraLength = UInt64(readUInt16(header, at: 30))
            let commentLength = UInt64(readUInt16(header, at: 32))
            let diskStartRaw = readUInt16(header, at: 34)
            let localHeaderOffsetRaw = readUInt32(header, at: 42)
            try validateCompressionMethod(method)
            guard generalPurposeFlags & encryptedEntryFlag == 0 else {
                throw ZipArchiveReaderError.invalidArchive("Encrypted ZIP entries are not supported")
            }

            let metadataLength = UInt64(centralDirectoryHeaderByteCount) + nameLength + extraLength + commentLength
            guard metadataLength <= directoryEnd - offset else {
                throw ZipArchiveReaderError.invalidArchive("Central directory entry metadata is truncated")
            }

            let extraData = try readZipBytes(
                from: handle,
                offset: offset + UInt64(centralDirectoryHeaderByteCount) + nameLength,
                count: Int(extraLength)
            )
            let resolved = try resolvedCentralDirectoryEntry(
                compressedSizeRaw: compressedSizeRaw,
                uncompressedSizeRaw: uncompressedSizeRaw,
                localHeaderOffsetRaw: localHeaderOffsetRaw,
                diskStartRaw: diskStartRaw,
                extraFieldData: extraData
            )
            if method == storedCompressionMethod,
               resolved.compressedSize != resolved.uncompressedSize {
                throw ZipArchiveReaderError.invalidArchive("Stored ZIP entry size metadata is inconsistent")
            }

            let nameData = try readZipBytes(
                from: handle,
                offset: offset + UInt64(centralDirectoryHeaderByteCount),
                count: Int(nameLength)
            )
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ZipArchiveReaderError.invalidArchive("Central directory entry name is not UTF-8")
            }
            offset += metadataLength

            guard !name.isEmpty, !name.hasSuffix("/") else {
                continue
            }

            let compressedSize = resolved.compressedSize
            let uncompressedSize = resolved.uncompressedSize
            let localHeaderOffset = resolved.localHeaderOffset
            let dataOffset = try fileBackedDataOffset(
                localHeaderOffset: localHeaderOffset,
                from: handle,
                fileSize: fileSize
            )
            guard localHeaderOffset < centralDirectory.offset,
                  dataOffset <= centralDirectory.offset,
                  compressedSize <= centralDirectory.offset - dataOffset else {
                throw ZipArchiveReaderError.invalidArchive("Local file payload points outside archive")
            }

            entries.append(
                ZipArchiveFileEntry(
                    name: name,
                    compressionMethod: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    checksum: checksum,
                    localHeaderOffset: localHeaderOffset,
                    dataOffset: dataOffset
                )
            )
        }

        guard offset == directoryEnd else {
            throw ZipArchiveReaderError.invalidArchive("Central directory contains trailing bytes")
        }
        return entries
    }

    /**
     Resolves ZIP64 sentinel fields from one central-directory extended-information extra field.

     Values are consumed in the order required by the ZIP specification and only when the matching
     32-bit or 16-bit header field contains its sentinel. All extra-field TLVs are bounds checked,
     duplicate ZIP64 fields are rejected, and disk-start metadata must describe a single-disk ZIP.

     - Parameters:
       - compressedSizeRaw: Classic 32-bit compressed size.
       - uncompressedSizeRaw: Classic 32-bit uncompressed size.
       - localHeaderOffsetRaw: Classic 32-bit local-header offset.
       - diskStartRaw: Classic 16-bit disk-start number.
       - extraFieldData: Complete central-directory extra-field byte sequence.
     - Returns: Fully resolved 64-bit sizes and local-header offset.
     - Side effects: none.
     - Failure modes: Throws for truncated/duplicate extra fields, missing required ZIP64 values, or
       multi-disk metadata.
     */
    private static func resolvedCentralDirectoryEntry(
        compressedSizeRaw: UInt32,
        uncompressedSizeRaw: UInt32,
        localHeaderOffsetRaw: UInt32,
        diskStartRaw: UInt16,
        extraFieldData: Data
    ) throws -> ResolvedCentralDirectoryEntry {
        var zip64Payload: Data?
        var offset = 0
        while offset < extraFieldData.count {
            guard extraFieldData.count - offset >= 4 else {
                throw ZipArchiveReaderError.invalidArchive("ZIP extra field header is truncated")
            }
            let identifier = readUInt16(extraFieldData, at: offset)
            let payloadSize = Int(readUInt16(extraFieldData, at: offset + 2))
            let payloadStart = offset + 4
            guard payloadSize <= extraFieldData.count - payloadStart else {
                throw ZipArchiveReaderError.invalidArchive("ZIP extra field payload is truncated")
            }
            let payloadEnd = payloadStart + payloadSize
            if identifier == zip64ExtendedInformationExtraFieldID {
                guard zip64Payload == nil else {
                    throw ZipArchiveReaderError.invalidArchive("Duplicate ZIP64 extended-information field")
                }
                zip64Payload = Data(extraFieldData[payloadStart..<payloadEnd])
            }
            offset = payloadEnd
        }

        let requiresZip64 = compressedSizeRaw == zip64Sentinel
            || uncompressedSizeRaw == zip64Sentinel
            || localHeaderOffsetRaw == zip64Sentinel
            || diskStartRaw == zip64DiskSentinel
        guard !requiresZip64 || zip64Payload != nil else {
            throw ZipArchiveReaderError.invalidArchive("ZIP64 extended-information field is missing")
        }

        let payload = zip64Payload ?? Data()
        var payloadOffset = 0
        func nextUInt64(_ field: String) throws -> UInt64 {
            guard payload.count - payloadOffset >= 8 else {
                throw ZipArchiveReaderError.invalidArchive("ZIP64 \(field) is truncated")
            }
            defer { payloadOffset += 8 }
            return readUInt64(payload, at: payloadOffset)
        }
        func nextUInt32(_ field: String) throws -> UInt32 {
            guard payload.count - payloadOffset >= 4 else {
                throw ZipArchiveReaderError.invalidArchive("ZIP64 \(field) is truncated")
            }
            defer { payloadOffset += 4 }
            return readUInt32(payload, at: payloadOffset)
        }

        let uncompressedSize = try uncompressedSizeRaw == zip64Sentinel
            ? nextUInt64("uncompressed size")
            : UInt64(uncompressedSizeRaw)
        let compressedSize = try compressedSizeRaw == zip64Sentinel
            ? nextUInt64("compressed size")
            : UInt64(compressedSizeRaw)
        let localHeaderOffset = try localHeaderOffsetRaw == zip64Sentinel
            ? nextUInt64("local-header offset")
            : UInt64(localHeaderOffsetRaw)
        let diskStart = try diskStartRaw == zip64DiskSentinel
            ? nextUInt32("disk-start number")
            : UInt32(diskStartRaw)
        guard diskStart == 0 else {
            throw ZipArchiveReaderError.invalidArchive("Multi-disk ZIP archives are not supported")
        }

        return ResolvedCentralDirectoryEntry(
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            localHeaderOffset: localHeaderOffset
        )
    }

    /**
     Validates that one central-directory entry uses a compression method supported by the reader.

     - Parameter method: Compression method from the central-directory file header.
     - Side effects: none.
     - Failure modes: Throws when the entry is not stored or raw-deflated.
     */
    private static func validateCompressionMethod(_ method: UInt16) throws {
        guard method == storedCompressionMethod || method == deflatedCompressionMethod else {
            throw ZipArchiveReaderError.unsupportedCompressionMethod(method)
        }
    }

    /**
     Validates central-directory size consistency for one stored ZIP entry.

     Stored entries are not compressed, so ZIP metadata must declare identical compressed and
     uncompressed sizes. Enforcing that invariant keeps aggregate size accounting honest before the
     reader materializes the payload.

     - Parameters:
       - compressedSize: Declared compressed byte count for the stored entry.
       - uncompressedSize: Declared uncompressed byte count for the stored entry.
     - Side effects: none.
     - Failure modes: Throws when stored-entry size metadata is internally inconsistent.
     */
    private static func validateStoredEntrySize(compressedSize: Int, uncompressedSize: Int) throws {
        guard compressedSize == uncompressedSize else {
            throw ZipArchiveReaderError.invalidArchive("Stored ZIP entry size metadata is inconsistent")
        }
    }

    /**
     Validates that an inflated ZIP entry produced the central-directory declared byte count.

     The C inflater can report success for a smaller output than the declared size. The eager reader
     rejects that mismatch so callers never receive truncated data that passed size accounting.

     - Parameters:
       - inflatedSize: Actual byte count returned by the inflater.
       - expectedSize: Declared uncompressed byte count from the central directory.
     - Side effects: none.
     - Failure modes: Throws when inflated output does not match the declared uncompressed size.
     */
    private static func validateInflatedEntrySize(_ inflatedSize: Int, expectedSize: Int) throws {
        guard inflatedSize == expectedSize else {
            throw ZipArchiveReaderError.invalidArchive("Deflated ZIP entry size metadata is inconsistent")
        }
    }

    /**
     Finds the ZIP end-of-central-directory record by scanning backwards from the archive tail.

     - Parameter data: Raw ZIP archive bytes.
     - Returns: Byte offset of the EOCD signature.
     - Side effects: none.
     - Failure modes: throws when the signature cannot be found inside the legal ZIP comment range.
     */
    private static func endOfCentralDirectoryOffset(in data: Data) throws -> Int {
        guard data.count >= endOfCentralDirectoryMinimumByteCount else {
            throw ZipArchiveReaderError.missingCentralDirectory
        }
        let minimumOffset = max(0, data.count - endOfCentralDirectoryMinimumByteCount - maximumZipCommentByteCount)
        var offset = data.count - endOfCentralDirectoryMinimumByteCount
        while offset >= minimumOffset {
            if readUInt32(data, at: offset) == endOfCentralDirectorySignature {
                let commentLength = Int(readUInt16(data, at: offset + 20))
                if offset + endOfCentralDirectoryMinimumByteCount + commentLength == data.count {
                    return offset
                }
            }
            if offset == 0 { break }
            offset -= 1
        }
        throw ZipArchiveReaderError.missingCentralDirectory
    }

    /**
     Finds the ZIP end-of-central-directory record in a bounded file tail.

     - Parameter tail: Last bytes of a ZIP archive, limited to the legal EOCD comment range.
     - Returns: Byte offset of the EOCD signature within `tail`.
     - Side effects: none.
     - Failure modes: Throws when the signature cannot be found at a valid tail position.
     */
    private static func endOfCentralDirectoryOffset(inTail tail: Data) throws -> Int {
        guard tail.count >= endOfCentralDirectoryMinimumByteCount else {
            throw ZipArchiveReaderError.missingCentralDirectory
        }
        var offset = tail.count - endOfCentralDirectoryMinimumByteCount
        while offset >= 0 {
            if readUInt32(tail, at: offset) == endOfCentralDirectorySignature {
                let commentLength = Int(readUInt16(tail, at: offset + 20))
                if offset + endOfCentralDirectoryMinimumByteCount + commentLength == tail.count {
                    return offset
                }
            }
            if offset == 0 {
                break
            }
            offset -= 1
        }
        throw ZipArchiveReaderError.missingCentralDirectory
    }

    /**
     Locates one local-file payload using central-directory size metadata.

     - Parameters:
       - archive: Raw ZIP archive bytes.
       - localHeaderOffset: Offset of the matching local-file header.
       - compressedSize: Compressed payload size from the central directory.
       - payloadUpperBound: First central-directory byte; entry payloads must end before it.
     - Returns: Compressed entry payload.
     - Side effects: none.
     - Failure modes: throws when the local header or payload range is malformed.
     */
    private static func compressedEntryData(
        archive: Data,
        localHeaderOffset: Int,
        compressedSize: Int,
        payloadUpperBound: Int
    ) throws -> Data {
        guard payloadUpperBound >= localFileHeaderByteCount,
              payloadUpperBound <= archive.count,
              localHeaderOffset >= 0,
              localHeaderOffset <= payloadUpperBound - localFileHeaderByteCount,
              readUInt32(archive, at: localHeaderOffset) == localFileHeaderSignature else {
            throw ZipArchiveReaderError.invalidArchive("Local file header is missing or truncated")
        }

        let localNameLength = Int(readUInt16(archive, at: localHeaderOffset + 26))
        let localExtraLength = Int(readUInt16(archive, at: localHeaderOffset + 28))
        let metadataLength = localFileHeaderByteCount + localNameLength + localExtraLength
        guard metadataLength <= payloadUpperBound - localHeaderOffset else {
            throw ZipArchiveReaderError.invalidArchive("Local file payload points outside archive")
        }
        let dataStart = localHeaderOffset + metadataLength
        guard compressedSize >= 0,
              compressedSize <= payloadUpperBound - dataStart else {
            throw ZipArchiveReaderError.invalidArchive("Local file payload points outside archive")
        }

        return Data(archive[dataStart..<dataStart + compressedSize])
    }

    /**
     Computes the compressed payload offset for one local-file header in a file-backed archive.

     - Parameters:
       - localHeaderOffset: Offset of the local file header.
       - handle: Open ZIP file handle, owned by the caller.
       - fileSize: Total archive byte count.
     - Returns: Absolute offset where the compressed payload starts.
     - Side effects: Seeks and reads local-header metadata from `handle`.
     - Failure modes: Throws when the local header is missing, truncated, or points outside the
       archive.
     */
    private static func fileBackedDataOffset(
        localHeaderOffset: UInt64,
        from handle: FileHandle,
        fileSize: UInt64
    ) throws -> UInt64 {
        guard UInt64(localFileHeaderByteCount) <= fileSize,
              localHeaderOffset <= fileSize - UInt64(localFileHeaderByteCount) else {
            throw ZipArchiveReaderError.invalidArchive("Local file header is missing or truncated")
        }
        let header = try readZipBytes(
            from: handle,
            offset: localHeaderOffset,
            count: localFileHeaderByteCount
        )
        guard readUInt32(header, at: 0) == localFileHeaderSignature else {
            throw ZipArchiveReaderError.invalidArchive("Local file header is missing or truncated")
        }

        let localNameLength = UInt64(readUInt16(header, at: 26))
        let localExtraLength = UInt64(readUInt16(header, at: 28))
        let metadataLength = UInt64(localFileHeaderByteCount) + localNameLength + localExtraLength
        guard metadataLength <= fileSize - localHeaderOffset else {
            throw ZipArchiveReaderError.invalidArchive("Local file payload points outside archive")
        }
        return localHeaderOffset + metadataLength
    }

    /**
     Copies one stored file-backed ZIP entry into a destination file in bounded chunks.

     - Parameters:
       - entry: Stored file-backed entry metadata.
       - url: ZIP archive URL.
       - destinationURL: Output file URL.
       - fileManager: File manager used to create the destination file.
     - Side effects: Creates and writes `destinationURL`.
     - Failure modes: Throws malformed archive errors for truncated payloads and rethrows
       file-system errors.
     */
    private static func copyStoredFileEntry(
        _ entry: ZipArchiveFileEntry,
        fromArchiveAt url: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        guard entry.compressedSize == entry.uncompressedSize else {
            throw ZipArchiveReaderError.invalidArchive("Stored ZIP entry size metadata is inconsistent")
        }
        let input = try FileHandle(forReadingFrom: url)
        defer {
            try? input.close()
        }
        let fileSize = try input.seekToEnd()
        guard entry.dataOffset <= fileSize,
              entry.compressedSize <= fileSize - entry.dataOffset else {
            throw ZipArchiveReaderError.invalidArchive("Local file payload points outside archive")
        }

        fileManager.createFile(atPath: destinationURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: destinationURL)
        do {
            try input.seek(toOffset: entry.dataOffset)
            var remaining = entry.compressedSize
            while remaining > 0 {
                try Task.checkCancellation()
                let chunkSize = Int(min(remaining, UInt64(fileExtractionChunkByteCount)))
                guard let chunk = try input.read(upToCount: chunkSize),
                      !chunk.isEmpty else {
                    throw ZipArchiveReaderError.invalidArchive("Truncated stored ZIP entry")
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
     Inflates one deflated file-backed ZIP entry into a destination file.

     - Parameters:
       - entry: Deflated file-backed entry metadata.
       - url: ZIP archive URL.
       - destinationURL: Output file URL.
       - fileManager: File manager used to inspect the output file.
     - Side effects: Streams compressed bytes through the shared zlib bridge into `destinationURL`.
     - Failure modes: Throws cancellation, malformed archive errors for oversized platform offsets,
       or `decompressionFailed` when zlib rejects the entry or writes an unexpected byte count.
     */
    private static func inflateDeflatedFileEntry(
        _ entry: ZipArchiveFileEntry,
        fromArchiveAt url: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        guard let context = raw_inflater_create() else {
            throw ZipArchiveReaderError.decompressionFailed
        }
        defer { raw_inflater_destroy(context) }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let archiveByteCount = try input.seekToEnd()
        guard entry.dataOffset <= archiveByteCount,
              entry.compressedSize <= archiveByteCount - entry.dataOffset else {
            throw ZipArchiveReaderError.invalidArchive("Local file payload points outside archive")
        }
        fileManager.createFile(atPath: destinationURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: destinationURL)
        do {
            try input.seek(toOffset: entry.dataOffset)
            var remaining = entry.compressedSize
            var reachedStreamEnd = false
            while remaining > 0 {
                try Task.checkCancellation()
                let chunkByteCount = Int(min(remaining, UInt64(fileExtractionChunkByteCount)))
                guard let chunk = try input.read(upToCount: chunkByteCount),
                      chunk.count == chunkByteCount else {
                    throw ZipArchiveReaderError.invalidArchive("Truncated deflated ZIP entry")
                }
                remaining -= UInt64(chunk.count)
                reachedStreamEnd = try consumeInflateInput(
                    chunk,
                    context: context,
                    output: output,
                    outputLimit: entry.uncompressedSize
                )
                if reachedStreamEnd, remaining != 0 {
                    throw ZipArchiveReaderError.decompressionFailed
                }
            }
            while !reachedStreamEnd {
                try Task.checkCancellation()
                reachedStreamEnd = try consumeInflateInput(
                    Data(),
                    context: context,
                    output: output,
                    outputLimit: entry.uncompressedSize
                )
            }
            try output.close()
        } catch {
            try? output.close()
            throw error
        }

        var consumedByteCount: UInt64 = 0
        var writtenByteCount: UInt64 = 0
        guard raw_inflater_metadata(
            context,
            &consumedByteCount,
            &writtenByteCount
        ) == 0,
            consumedByteCount == entry.compressedSize,
            writtenByteCount == entry.uncompressedSize else {
            throw ZipArchiveReaderError.decompressionFailed
        }
    }

    /** Drains one compressed input slice through the cancellable raw inflater. */
    private static func consumeInflateInput(
        _ input: Data,
        context: UnsafeMutableRawPointer,
        output: FileHandle,
        outputLimit: UInt64
    ) throws -> Bool {
        var inputOffset = 0
        repeat {
            try Task.checkCancellation()
            var outputBuffer = Data(count: fileExtractionChunkByteCount)
            let outputCapacity = UInt32(outputBuffer.count)
            var consumed: UInt32 = 0
            var produced: UInt32 = 0
            let result: Int32 = outputBuffer.withUnsafeMutableBytes { outputBytes in
                input.withUnsafeBytes { inputBytes in
                    let inputPointer = inputBytes.baseAddress?
                        .assumingMemoryBound(to: UInt8.self)
                        .advanced(by: inputOffset)
                    return raw_inflater_process(
                        context,
                        inputPointer,
                        UInt32(input.count - inputOffset),
                        outputBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        outputCapacity,
                        &consumed,
                        &produced
                    )
                }
            }
            guard result >= 0 else { throw ZipArchiveReaderError.decompressionFailed }
            if produced > 0 {
                let currentOffset = try output.offset()
                guard currentOffset <= outputLimit,
                      UInt64(produced) <= outputLimit - currentOffset else {
                    throw ZipArchiveReaderError.decompressionFailed
                }
                try output.write(contentsOf: outputBuffer.prefix(Int(produced)))
            }
            inputOffset += Int(consumed)
            if result == 1 {
                guard inputOffset == input.count else {
                    throw ZipArchiveReaderError.decompressionFailed
                }
                return true
            }
            guard consumed > 0 || produced > 0 else {
                throw ZipArchiveReaderError.decompressionFailed
            }
        } while inputOffset < input.count || input.isEmpty
        return false
    }

    /**
     Reads an exact byte range from a file-backed ZIP archive.

     - Parameters:
       - handle: Open ZIP file handle, owned by the caller.
       - offset: Absolute byte offset to read from.
       - count: Number of bytes required.
     - Returns: Data containing exactly `count` bytes.
     - Side effects: Seeks and reads from `handle`.
     - Failure modes: Throws when the requested range cannot be read fully.
     */
    private static func readZipBytes(from handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try Task.checkCancellation()
        try handle.seek(toOffset: offset)
        guard count > 0 else {
            return Data()
        }
        guard let data = try handle.read(upToCount: count),
              data.count == count else {
            throw ZipArchiveReaderError.invalidArchive("Truncated ZIP structure")
        }
        return data
    }

    /** Maps the shared strict metadata parser into the stable generic ZIP-reader error contract. */
    private static func zipReaderError(
        _ error: AndroidModuleBackupArchivePlannerError
    ) -> ZipArchiveReaderError {
        if case .invalidArchive(let message) = error {
            if message.contains("end-of-central-directory record is missing") {
                return .missingCentralDirectory
            }
            if message.hasPrefix("Unsupported ZIP compression method "),
               let method = UInt16(message.split(separator: " ").last ?? "") {
                return .unsupportedCompressionMethod(method)
            }
            return .invalidArchive(message)
        }
        return .invalidArchive(error.localizedDescription)
    }

    /**
     Reads a little-endian `UInt16` from the archive byte stream.

     - Parameters:
       - data: Source bytes.
       - offset: Byte offset where the integer starts.
     - Returns: Decoded little-endian integer.
     - Side effects: none.
     - Failure modes: Callers must ensure the range exists before invoking this helper.
     */
    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1]) << 8
        return b0 | b1
    }

    /**
     Reads a little-endian `UInt32` from the archive byte stream.

     - Parameters:
       - data: Source bytes.
       - offset: Byte offset where the integer starts.
     - Returns: Decoded little-endian integer.
     - Side effects: none.
     - Failure modes: Callers must ensure the range exists before invoking this helper.
     */
    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    /**
     Reads a little-endian `UInt64` from the archive byte stream.

     - Parameters:
       - data: Source bytes.
       - offset: Byte offset where the integer starts.
     - Returns: Decoded little-endian integer.
     - Side effects: none.
     - Failure modes: Callers must ensure the range exists before invoking this helper.
     */
    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byteIndex in 0..<8 {
            value |= UInt64(data[offset + byteIndex]) << UInt64(byteIndex * 8)
        }
        return value
    }

    /**
     Inflates one raw deflated ZIP member through the shared C adapter.

     - Parameters:
       - compressed: Deflated ZIP member bytes.
       - uncompressedSize: Declared uncompressed size from the central directory.
     - Returns: Inflated member bytes.
     - Side effects: allocates and releases a C buffer through `CLibSword`.
     - Failure modes: throws when the inflater cannot decode the supplied payload.
     */
    private static func inflateData(_ compressed: Data, uncompressedSize: Int) throws -> Data {
        try compressed.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = ptr.baseAddress else {
                throw ZipArchiveReaderError.decompressionFailed
            }

            var outputLength: UInt = 0
            guard let output = inflate_raw_data(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(compressed.count),
                UInt(uncompressedSize),
                &outputLength
            ) else {
                throw ZipArchiveReaderError.decompressionFailed
            }

            defer { gunzip_free(output) }
            return Data(bytes: output, count: Int(outputLength))
        }
    }
}
