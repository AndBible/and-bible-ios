// ZipArchiveReader.swift — ZIP central-directory extraction helper

import CLibSword
import Foundation

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
        localHeaderOffset: UInt64,
        dataOffset: UInt64
    ) {
        self.name = name
        self.compressionMethod = compressionMethod
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
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
    private static let zip64Sentinel: UInt32 = 0xffff_ffff
    private static let zip64EntryCountSentinel: UInt16 = 0xffff
    private static let encryptedEntryFlag: UInt16 = 0x0001
    private static let storedCompressionMethod: UInt16 = 0
    private static let deflatedCompressionMethod: UInt16 = 8
    private static let endOfCentralDirectoryMinimumByteCount = 22
    private static let maximumZipCommentByteCount = 0xffff
    private static let localFileHeaderByteCount = 30
    private static let centralDirectoryHeaderByteCount = 46
    private static let fileExtractionChunkByteCount = 64 * 1024
    /// Maximum compressed or uncompressed bytes accepted for one eagerly materialized entry.
    private static let maximumEntryByteCount = 256 * 1024 * 1024
    /// Maximum compressed bytes accepted across all extracted entries.
    private static let maximumTotalCompressedByteCount = 512 * 1024 * 1024
    /// Maximum uncompressed bytes accepted across all extracted entries.
    private static let maximumTotalUncompressedByteCount = 512 * 1024 * 1024

    /**
     Central-directory metadata for one file entry that passed pre-extraction validation.
     */
    private struct CentralDirectoryFileEntry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
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
         truncated, multi-disk, ZIP64-only, or contains a non-UTF-8 entry name
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
       - `ZipArchiveReaderError.invalidArchive` for malformed, spanned, ZIP64, encrypted, or
         out-of-bounds entries
       - `ZipArchiveReaderError.unsupportedCompressionMethod` for non-stored/non-deflated entries
       - file-system errors from opening, seeking, or reading the archive
     */
    public static func fileEntries(inArchiveAt url: URL) throws -> [ZipArchiveFileEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        let fileSize = try handle.seekToEnd()
        let centralDirectory = try fileBackedCentralDirectory(from: handle, fileSize: fileSize)
        return try fileBackedEntries(from: handle, centralDirectory: centralDirectory, fileSize: fileSize)
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

     The reader is intentionally eager because Android backup restore needs materialized database
     bytes before staging SQLite files. Size limits are enforced before local payload extraction or
     inflation so a malicious archive cannot force unbounded memory allocation.

     - Parameter data: Raw ZIP archive bytes.
     - Returns: Uncompressed non-directory entries in central-directory order.
     - Side effects: none.
     - Failure modes:
       - throws `ZipArchiveReaderError.missingCentralDirectory` when the archive is not ZIP-shaped
       - throws `ZipArchiveReaderError.invalidArchive` when a header is truncated or inconsistent
       - throws `ZipArchiveReaderError.invalidArchive` when the end record describes a spanned
         archive instead of the single-disk ZIP shape Android backups use
       - throws `ZipArchiveReaderError.invalidArchive` when declared entry/archive sizes exceed
         the eager extraction limits
       - throws `ZipArchiveReaderError.invalidArchive` when materialized entry sizes do not match
         central-directory declarations
       - throws `ZipArchiveReaderError.unsupportedCompressionMethod` for non-stored/non-deflated entries
       - throws `ZipArchiveReaderError.decompressionFailed` when the C inflater cannot decode an entry
     */
    public static func entries(in data: Data) throws -> [ZipArchiveEntry] {
        let endRecordOffset = try endOfCentralDirectoryOffset(in: data)
        let diskNumberRaw = readUInt16(data, at: endRecordOffset + 4)
        let centralDirectoryDiskRaw = readUInt16(data, at: endRecordOffset + 6)
        let diskEntryCountRaw = readUInt16(data, at: endRecordOffset + 8)
        let entryCountRaw = readUInt16(data, at: endRecordOffset + 10)
        let centralDirectorySizeRaw = readUInt32(data, at: endRecordOffset + 12)
        let centralDirectoryOffsetRaw = readUInt32(data, at: endRecordOffset + 16)

        guard diskEntryCountRaw != zip64EntryCountSentinel,
              entryCountRaw != zip64EntryCountSentinel,
              centralDirectorySizeRaw != zip64Sentinel,
              centralDirectoryOffsetRaw != zip64Sentinel else {
            throw ZipArchiveReaderError.invalidArchive("ZIP64 archives are not supported")
        }
        guard diskNumberRaw == 0,
              centralDirectoryDiskRaw == 0,
              diskEntryCountRaw == entryCountRaw else {
            throw ZipArchiveReaderError.invalidArchive("Multi-disk ZIP archives are not supported")
        }
        let entryCount = Int(entryCountRaw)
        let centralDirectorySize = Int(centralDirectorySizeRaw)
        let centralDirectoryOffset = Int(centralDirectoryOffsetRaw)
        guard centralDirectoryOffset >= 0,
              centralDirectorySize >= 0,
              centralDirectoryOffset + centralDirectorySize <= data.count else {
            throw ZipArchiveReaderError.invalidArchive("Central directory points outside archive")
        }
        let centralDirectoryEnd = centralDirectoryOffset + centralDirectorySize

        var fileEntries: [CentralDirectoryFileEntry] = []
        var offset = centralDirectoryOffset
        var totalCompressedSize = 0
        var totalUncompressedSize = 0
        for _ in 0..<entryCount {
            guard offset + 46 <= centralDirectoryEnd else {
                throw ZipArchiveReaderError.invalidArchive("Central directory entry is truncated")
            }
            guard readUInt32(data, at: offset) == centralDirectoryHeaderSignature else {
                throw ZipArchiveReaderError.invalidArchive("Central directory entry has an invalid signature")
            }

            let method = readUInt16(data, at: offset + 10)
            let compressedSizeRaw = readUInt32(data, at: offset + 20)
            let uncompressedSizeRaw = readUInt32(data, at: offset + 24)
            let nameLength = Int(readUInt16(data, at: offset + 28))
            let extraLength = Int(readUInt16(data, at: offset + 30))
            let commentLength = Int(readUInt16(data, at: offset + 32))
            let localHeaderOffsetRaw = readUInt32(data, at: offset + 42)

            guard compressedSizeRaw != zip64Sentinel,
                  uncompressedSizeRaw != zip64Sentinel,
                  localHeaderOffsetRaw != zip64Sentinel else {
                throw ZipArchiveReaderError.invalidArchive("ZIP64 entry sizes are not supported")
            }

            let nameStart = offset + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= centralDirectoryEnd else {
                throw ZipArchiveReaderError.invalidArchive("Central directory entry name is truncated")
            }
            guard let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) else {
                throw ZipArchiveReaderError.invalidArchive("Central directory entry name is not UTF-8")
            }
            let nextOffset = nameEnd + extraLength + commentLength
            guard nextOffset <= centralDirectoryEnd else {
                throw ZipArchiveReaderError.invalidArchive("Central directory entry metadata is truncated")
            }
            offset = nextOffset

            guard !name.isEmpty, !name.hasSuffix("/") else {
                continue
            }

            let localHeaderOffset = Int(localHeaderOffsetRaw)
            let compressedSize = Int(compressedSizeRaw)
            let uncompressedSize = Int(uncompressedSizeRaw)
            try validateEntrySize(compressedSize: compressedSize, uncompressedSize: uncompressedSize)
            try validateCompressionMethod(method)
            if method == storedCompressionMethod {
                try validateStoredEntrySize(compressedSize: compressedSize, uncompressedSize: uncompressedSize)
            }
            try accumulateEntrySizes(
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                totalCompressedSize: &totalCompressedSize,
                totalUncompressedSize: &totalUncompressedSize
            )
            fileEntries.append(
                CentralDirectoryFileEntry(
                    name: name,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                )
            )
        }
        guard offset == centralDirectoryEnd else {
            throw ZipArchiveReaderError.invalidArchive("Central directory contains trailing bytes")
        }

        return try fileEntries.map { entry in
            let compressedData = try compressedEntryData(
                archive: data,
                localHeaderOffset: entry.localHeaderOffset,
                compressedSize: entry.compressedSize
            )

            let fileData: Data
            switch entry.method {
            case storedCompressionMethod:
                fileData = compressedData
            case deflatedCompressionMethod:
                fileData = try inflateData(compressedData, uncompressedSize: entry.uncompressedSize)
                try validateInflatedEntrySize(fileData.count, expectedSize: entry.uncompressedSize)
            default:
                throw ZipArchiveReaderError.unsupportedCompressionMethod(entry.method)
            }
            return ZipArchiveEntry(name: entry.name, data: fileData)
        }
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

        let diskNumberRaw = readUInt16(tail, at: endRecordOffset + 4)
        let centralDirectoryDiskRaw = readUInt16(tail, at: endRecordOffset + 6)
        let diskEntryCountRaw = readUInt16(tail, at: endRecordOffset + 8)
        let entryCountRaw = readUInt16(tail, at: endRecordOffset + 10)
        let centralDirectorySizeRaw = readUInt32(tail, at: endRecordOffset + 12)
        let centralDirectoryOffsetRaw = readUInt32(tail, at: endRecordOffset + 16)

        guard diskEntryCountRaw != zip64EntryCountSentinel,
              entryCountRaw != zip64EntryCountSentinel,
              centralDirectorySizeRaw != zip64Sentinel,
              centralDirectoryOffsetRaw != zip64Sentinel else {
            throw ZipArchiveReaderError.invalidArchive("ZIP64 archives are not supported")
        }
        guard diskNumberRaw == 0,
              centralDirectoryDiskRaw == 0,
              diskEntryCountRaw == entryCountRaw else {
            throw ZipArchiveReaderError.invalidArchive("Multi-disk ZIP archives are not supported")
        }

        let entryCount = Int(entryCountRaw)
        let centralDirectorySize = UInt64(centralDirectorySizeRaw)
        let centralDirectoryOffset = UInt64(centralDirectoryOffsetRaw)
        guard centralDirectoryOffset <= fileSize,
              centralDirectorySize <= fileSize - centralDirectoryOffset else {
            throw ZipArchiveReaderError.invalidArchive("Central directory points outside archive")
        }
        guard centralDirectorySize > 0 || entryCount == 0 else {
            throw ZipArchiveReaderError.invalidArchive("Central directory entry count mismatch")
        }
        return FileBackedCentralDirectory(
            offset: centralDirectoryOffset,
            size: centralDirectorySize,
            entryCount: entryCount
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
            let compressedSizeRaw = readUInt32(header, at: 20)
            let uncompressedSizeRaw = readUInt32(header, at: 24)
            let nameLength = UInt64(readUInt16(header, at: 28))
            let extraLength = UInt64(readUInt16(header, at: 30))
            let commentLength = UInt64(readUInt16(header, at: 32))
            let localHeaderOffsetRaw = readUInt32(header, at: 42)

            guard compressedSizeRaw != zip64Sentinel,
                  uncompressedSizeRaw != zip64Sentinel,
                  localHeaderOffsetRaw != zip64Sentinel else {
                throw ZipArchiveReaderError.invalidArchive("ZIP64 entry sizes are not supported")
            }
            try validateCompressionMethod(method)
            if method == storedCompressionMethod {
                try validateStoredEntrySize(
                    compressedSize: Int(compressedSizeRaw),
                    uncompressedSize: Int(uncompressedSizeRaw)
                )
            }
            guard generalPurposeFlags & encryptedEntryFlag == 0 else {
                throw ZipArchiveReaderError.invalidArchive("Encrypted ZIP entries are not supported")
            }

            let metadataLength = UInt64(centralDirectoryHeaderByteCount) + nameLength + extraLength + commentLength
            guard metadataLength <= directoryEnd - offset else {
                throw ZipArchiveReaderError.invalidArchive("Central directory entry metadata is truncated")
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

            let compressedSize = UInt64(compressedSizeRaw)
            let uncompressedSize = UInt64(uncompressedSizeRaw)
            let localHeaderOffset = UInt64(localHeaderOffsetRaw)
            let dataOffset = try fileBackedDataOffset(
                localHeaderOffset: localHeaderOffset,
                from: handle,
                fileSize: fileSize
            )
            guard compressedSize <= fileSize - dataOffset else {
                throw ZipArchiveReaderError.invalidArchive("Local file payload points outside archive")
            }

            entries.append(
                ZipArchiveFileEntry(
                    name: name,
                    compressionMethod: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
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
     Validates one central-directory entry's declared compressed and uncompressed sizes.

     The ZIP reader materializes each supported entry in memory, so both the compressed payload
     slice and inflated result must stay below the per-entry cap before extraction starts.

     - Parameters:
       - compressedSize: Declared compressed byte count from the central directory.
       - uncompressedSize: Declared uncompressed byte count from the central directory.
     - Side effects: none.
     - Failure modes: Throws when either declared size exceeds the eager extraction cap.
     */
    private static func validateEntrySize(compressedSize: Int, uncompressedSize: Int) throws {
        guard compressedSize <= maximumEntryByteCount,
              uncompressedSize <= maximumEntryByteCount else {
            throw ZipArchiveReaderError.invalidArchive("ZIP entry exceeds maximum supported size")
        }
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
     Adds one entry's declared sizes to aggregate extraction totals.

     Aggregate caps protect against archives containing many individually acceptable entries that
     would still exhaust memory once the eager reader materializes them together.

     - Parameters:
       - compressedSize: Declared compressed byte count for the current file entry.
       - uncompressedSize: Declared uncompressed byte count for the current file entry.
       - totalCompressedSize: Running compressed byte total, mutated on success.
       - totalUncompressedSize: Running uncompressed byte total, mutated on success.
     - Side effects: Mutates the running totals after validating the addition.
     - Failure modes: Throws when adding the entry would exceed aggregate extraction caps.
     */
    private static func accumulateEntrySizes(
        compressedSize: Int,
        uncompressedSize: Int,
        totalCompressedSize: inout Int,
        totalUncompressedSize: inout Int
    ) throws {
        guard totalCompressedSize <= maximumTotalCompressedByteCount - compressedSize,
              totalUncompressedSize <= maximumTotalUncompressedByteCount - uncompressedSize else {
            throw ZipArchiveReaderError.invalidArchive("ZIP archive exceeds maximum supported size")
        }

        totalCompressedSize += compressedSize
        totalUncompressedSize += uncompressedSize
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
                return offset
            }
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
     - Returns: Compressed entry payload.
     - Side effects: none.
     - Failure modes: throws when the local header or payload range is malformed.
     */
    private static func compressedEntryData(
        archive: Data,
        localHeaderOffset: Int,
        compressedSize: Int
    ) throws -> Data {
        guard localHeaderOffset >= 0,
              localHeaderOffset + 30 <= archive.count,
              readUInt32(archive, at: localHeaderOffset) == localFileHeaderSignature else {
            throw ZipArchiveReaderError.invalidArchive("Local file header is missing or truncated")
        }

        let localNameLength = Int(readUInt16(archive, at: localHeaderOffset + 26))
        let localExtraLength = Int(readUInt16(archive, at: localHeaderOffset + 28))
        let dataStart = localHeaderOffset + 30 + localNameLength + localExtraLength
        guard compressedSize >= 0, dataStart >= 0, dataStart + compressedSize <= archive.count else {
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
     - Side effects: Invokes the shared zlib C bridge to create `destinationURL`.
     - Failure modes: Throws malformed archive errors for oversized platform offsets and
       `decompressionFailed` when zlib rejects the entry or writes an unexpected byte count.
     */
    private static func inflateDeflatedFileEntry(
        _ entry: ZipArchiveFileEntry,
        fromArchiveAt url: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        guard entry.dataOffset <= UInt64(UInt.max),
              entry.compressedSize <= UInt64(UInt.max) else {
            throw ZipArchiveReaderError.invalidArchive("ZIP entry is too large")
        }

        let result = url.withUnsafeFileSystemRepresentation { inputPath in
            destinationURL.withUnsafeFileSystemRepresentation { outputPath in
                guard let inputPath, let outputPath else {
                    return Int32(-1)
                }
                return inflate_raw_file_range_to_file(
                    inputPath,
                    UInt(entry.dataOffset),
                    UInt(entry.compressedSize),
                    outputPath
                )
            }
        }
        guard result == 0 else {
            throw ZipArchiveReaderError.decompressionFailed
        }

        let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
        guard let writtenSize = (attributes[.size] as? NSNumber)?.uint64Value,
              writtenSize == entry.uncompressedSize else {
            throw ZipArchiveReaderError.decompressionFailed
        }
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
