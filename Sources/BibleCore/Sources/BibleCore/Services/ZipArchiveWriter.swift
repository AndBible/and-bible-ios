// ZipArchiveWriter.swift — ZIP archive writer for Android-compatible backup exports

import Foundation

/**
 Errors raised while creating ZIP archives for backup export.

 The writer intentionally supports the small stored-entry ZIP shape needed by Android backup
 parity instead of becoming a general-purpose archive library.
 */
public enum ZipArchiveWriterError: Error, LocalizedError, Equatable {
    /// One entry path or payload exceeds the non-ZIP64 limits supported by this writer.
    case entryTooLarge(String)

    /// The number of entries or central-directory byte count exceeds the non-ZIP64 ZIP shape.
    case archiveTooLarge

    /// User-visible error description.
    public var errorDescription: String? {
        switch self {
        case .entryTooLarge(let name):
            return "ZIP entry is too large for Android-compatible export: \(name)"
        case .archiveTooLarge:
            return "ZIP archive is too large for Android-compatible export."
        }
    }
}

/**
 One file entry to be written into a stored ZIP archive.

 Directory entries are intentionally omitted. Android's module backup reader only needs regular
 file entries and resolves directories from the file paths while extracting.
 */
public struct ZipArchiveWriterEntry: Sendable, Equatable {
    /// Relative ZIP entry path using `/` separators.
    public let name: String

    /// Uncompressed file bytes for the entry.
    public let data: Data

    /**
     Creates one ZIP writer entry.

     - Parameters:
       - name: Relative archive path. Callers are responsible for supplying a safe path.
       - data: Uncompressed file bytes.
     - Side effects: none.
     - Failure modes: This initializer cannot fail; size validation happens during archive writing.
     */
    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/**
 Creates non-ZIP64 stored ZIP archives with central-directory metadata.

 Android backup import uses Java's `ZipInputStream`, which accepts stored entries when CRC and
 size metadata are present. This writer calculates CRC32 and writes central-directory records so
 exported iOS module backups can be restored by Android and re-read by `ZipArchiveReader`.
 */
public enum ZipArchiveWriter {
    /// ZIP general-purpose EFS flag that tells Android/Java readers file names are UTF-8.
    private static let utf8FileNameFlag: UInt16 = 0x0800

    /**
     Builds a ZIP archive containing the supplied entries without compression.

     - Parameter entries: File entries in the exact archive order to emit.
     - Returns: Raw ZIP archive bytes.
     - Side effects: none.
     - Throws: `ZipArchiveWriterError` when the entry count, path length, payload size, or central
       directory exceeds the non-ZIP64 ZIP limits supported by Android-compatible backup export.
     - Note: The output is deterministic for the same ordered entries; timestamps are written as
       zero because Android's module backup contract does not depend on ZIP entry dates. File-name
       headers set the ZIP UTF-8 flag so Android's Java ZIP readers do not reinterpret paths with
       platform-default encodings.
     */
    public static func storedArchive(entries: [ZipArchiveWriterEntry]) throws -> Data {
        guard entries.count <= Int(UInt16.max) else {
            throw ZipArchiveWriterError.archiveTooLarge
        }

        var archive = Data()
        var centralDirectory = Data()
        var localHeaderOffsets: [UInt32] = []
        localHeaderOffsets.reserveCapacity(entries.count)

        for entry in entries {
            guard let nameData = entry.name.data(using: .utf8),
                  nameData.count <= Int(UInt16.max) else {
                throw ZipArchiveWriterError.entryTooLarge(entry.name)
            }
            guard entry.data.count <= Int(UInt32.max) else {
                throw ZipArchiveWriterError.entryTooLarge(entry.name)
            }
            guard archive.count <= Int(UInt32.max) else {
                throw ZipArchiveWriterError.archiveTooLarge
            }

            localHeaderOffsets.append(UInt32(archive.count))
            let checksum = crc32(entry.data)
            appendUInt32(0x0403_4b50, to: &archive)
            appendUInt16(20, to: &archive)
            appendUInt16(Self.utf8FileNameFlag, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt32(checksum, to: &archive)
            appendUInt32(UInt32(entry.data.count), to: &archive)
            appendUInt32(UInt32(entry.data.count), to: &archive)
            appendUInt16(UInt16(nameData.count), to: &archive)
            appendUInt16(0, to: &archive)
            archive.append(nameData)
            archive.append(entry.data)
        }

        guard archive.count <= Int(UInt32.max) else {
            throw ZipArchiveWriterError.archiveTooLarge
        }
        let centralDirectoryOffset = UInt32(archive.count)
        for (index, entry) in entries.enumerated() {
            guard let nameData = entry.name.data(using: .utf8),
                  nameData.count <= Int(UInt16.max) else {
                throw ZipArchiveWriterError.entryTooLarge(entry.name)
            }

            let checksum = crc32(entry.data)
            appendUInt32(0x0201_4b50, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(Self.utf8FileNameFlag, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(checksum, to: &centralDirectory)
            appendUInt32(UInt32(entry.data.count), to: &centralDirectory)
            appendUInt32(UInt32(entry.data.count), to: &centralDirectory)
            appendUInt16(UInt16(nameData.count), to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(0, to: &centralDirectory)
            appendUInt32(localHeaderOffsets[index], to: &centralDirectory)
            centralDirectory.append(nameData)
        }

        guard centralDirectory.count <= Int(UInt32.max) else {
            throw ZipArchiveWriterError.archiveTooLarge
        }
        archive.append(centralDirectory)
        appendUInt32(0x0605_4b50, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(UInt16(entries.count), to: &archive)
        appendUInt16(UInt16(entries.count), to: &archive)
        appendUInt32(UInt32(centralDirectory.count), to: &archive)
        appendUInt32(centralDirectoryOffset, to: &archive)
        appendUInt16(0, to: &archive)
        return archive
    }

    /**
     Calculates standard ZIP CRC32 for one uncompressed payload.

     - Parameter data: Payload bytes to checksum.
     - Returns: CRC32 value written into local and central ZIP headers.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let tableIndex = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ crc32Table[tableIndex]
        }
        return crc ^ 0xffff_ffff
    }

    /// Lookup table used by `crc32(_:)`.
    private static let crc32Table: [UInt32] = {
        (0..<256).map { value in
            var crc = UInt32(value)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = 0xedb8_8320 ^ (crc >> 1)
                } else {
                    crc >>= 1
                }
            }
            return crc
        }
    }()

    /**
     Appends a little-endian 16-bit integer to ZIP output.

     - Parameters:
       - value: Unsigned value to append.
       - data: Mutable archive buffer.
     - Side effects: Appends two bytes to `data`.
     - Failure modes: none.
     */
    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    /**
     Appends a little-endian 32-bit integer to ZIP output.

     - Parameters:
       - value: Unsigned value to append.
       - data: Mutable archive buffer.
     - Side effects: Appends four bytes to `data`.
     - Failure modes: none.
     */
    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
}
