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
            if method == 0 {
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
            case 0:
                fileData = compressedData
            case 8:
                fileData = try inflateData(compressedData, uncompressedSize: entry.uncompressedSize)
                try validateInflatedEntrySize(fileData.count, expectedSize: entry.uncompressedSize)
            default:
                throw ZipArchiveReaderError.unsupportedCompressionMethod(entry.method)
            }
            return ZipArchiveEntry(name: entry.name, data: fileData)
        }
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
        guard method == 0 || method == 8 else {
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
        guard data.count >= 22 else {
            throw ZipArchiveReaderError.missingCentralDirectory
        }
        let minimumOffset = max(0, data.count - 65_557)
        var offset = data.count - 22
        while offset >= minimumOffset {
            if readUInt32(data, at: offset) == endOfCentralDirectorySignature {
                return offset
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
