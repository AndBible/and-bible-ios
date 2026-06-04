// ZipArchiveReader.swift — ZIP central-directory extraction helper

import CLibSword
import Foundation

/**
 Errors raised while reading ZIP archives.

 The reader is intentionally small and supports the ZIP shapes AndBible consumes locally:
 central-directory based stored or deflated file entries. Unsupported compression methods and
 malformed offsets are rejected explicitly so callers can surface actionable archive errors instead
 of treating missing entries as valid empty archives.
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

    /**
     Extracts supported file entries from raw ZIP data.

     - Parameter data: Raw ZIP archive bytes.
     - Returns: Uncompressed non-directory entries in central-directory order.
     - Side effects: none.
     - Failure modes:
       - throws `ZipArchiveReaderError.missingCentralDirectory` when the archive is not ZIP-shaped
       - throws `ZipArchiveReaderError.invalidArchive` when a header is truncated or inconsistent
       - throws `ZipArchiveReaderError.unsupportedCompressionMethod` for non-stored/non-deflated entries
       - throws `ZipArchiveReaderError.decompressionFailed` when the C inflater cannot decode an entry
     */
    public static func entries(in data: Data) throws -> [ZipArchiveEntry] {
        let endRecordOffset = try endOfCentralDirectoryOffset(in: data)
        let entryCount = Int(readUInt16(data, at: endRecordOffset + 10))
        let centralDirectorySize = Int(readUInt32(data, at: endRecordOffset + 12))
        let centralDirectoryOffsetRaw = readUInt32(data, at: endRecordOffset + 16)

        guard centralDirectoryOffsetRaw != zip64Sentinel else {
            throw ZipArchiveReaderError.invalidArchive("ZIP64 archives are not supported")
        }
        let centralDirectoryOffset = Int(centralDirectoryOffsetRaw)
        guard centralDirectoryOffset >= 0,
              centralDirectorySize >= 0,
              centralDirectoryOffset + centralDirectorySize <= data.count else {
            throw ZipArchiveReaderError.invalidArchive("Central directory points outside archive")
        }
        let centralDirectoryEnd = centralDirectoryOffset + centralDirectorySize

        var entries: [ZipArchiveEntry] = []
        var offset = centralDirectoryOffset
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
            let compressedData = try compressedEntryData(
                archive: data,
                localHeaderOffset: localHeaderOffset,
                compressedSize: compressedSize
            )

            let fileData: Data
            switch method {
            case 0:
                fileData = compressedData
            case 8:
                fileData = try inflateData(compressedData, uncompressedSize: uncompressedSize)
            default:
                throw ZipArchiveReaderError.unsupportedCompressionMethod(method)
            }
            entries.append(ZipArchiveEntry(name: name, data: fileData))
        }
        guard offset == centralDirectoryEnd else {
            throw ZipArchiveReaderError.invalidArchive("Central directory contains trailing bytes")
        }

        return entries
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
