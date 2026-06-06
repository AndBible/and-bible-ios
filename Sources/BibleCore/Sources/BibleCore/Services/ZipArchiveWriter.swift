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
 File-backed entry source for writing stored ZIP archives without buffering every payload first.

 The writer still precomputes CRC and size metadata because Android/Java readers expect stored-entry
 local headers to contain those values up front, but file payloads are copied to the destination ZIP in
 chunks so large backup databases do not need to be loaded into memory as `Data`.
 */
struct ZipArchiveWriterFileEntry: Sendable, Equatable {
    /// Relative ZIP entry path using `/` separators.
    let name: String

    /// Source payload for the entry.
    let payload: Payload

    /**
     Source payload used by the streaming ZIP writer.

     `data` is intended for small generated entries such as manifests. `file` is intended for SQLite
     databases and other large backup payloads that should be copied incrementally.
     */
    enum Payload: Sendable, Equatable {
        /// In-memory bytes for a small generated entry.
        case data(Data)

        /// File URL for an entry copied in chunks.
        case file(URL)
    }

    /**
     Creates one small in-memory ZIP entry.

     - Parameters:
       - name: Relative archive path. Callers are responsible for supplying a safe path.
       - data: Uncompressed file bytes.
     - Side effects: none.
     - Failure modes: This initializer cannot fail; size validation happens during archive writing.
     */
    init(name: String, data: Data) {
        self.name = name
        payload = .data(data)
    }

    /**
     Creates one file-backed ZIP entry.

     - Parameters:
       - name: Relative archive path. Callers are responsible for supplying a safe path.
       - fileURL: File whose bytes should be copied into the archive.
     - Side effects: none.
     - Failure modes: This initializer cannot fail; file access and size validation happen during archive writing.
     */
    init(name: String, fileURL: URL) {
        self.name = name
        payload = .file(fileURL)
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
     Prepared metadata for one stored ZIP entry.

     Stored entries must publish CRC and uncompressed size before the payload bytes, so file-backed
     entries are scanned once for metadata before the writer emits any ZIP records.
     */
    private struct PreparedFileEntry {
        let name: String
        let nameData: Data
        let payload: ZipArchiveWriterFileEntry.Payload
        let checksum: UInt32
        let byteCount: UInt32
    }

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
     Writes a stored ZIP archive directly to a destination file.

     - Parameters:
       - entries: File entries in the exact archive order to emit.
       - destinationURL: File URL that will receive the complete ZIP archive.
       - fileManager: File manager used to inspect file-backed entries and create the destination path.
     - Side effects:
       - creates or replaces `destinationURL`
       - reads file-backed entry payloads and copies them into the archive in chunks
     - Throws: `ZipArchiveWriterError` when ZIP limits are exceeded, or filesystem errors when a
       source payload or destination file cannot be read or written.
     - Note: The output is deterministic for the same ordered entries and source bytes; timestamps are
       written as zero for parity with `storedArchive(entries:)`.
     */
    static func writeStoredArchive(
        entries: [ZipArchiveWriterFileEntry],
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard entries.count <= Int(UInt16.max) else {
            throw ZipArchiveWriterError.archiveTooLarge
        }

        let preparedEntries = try entries.map { try prepare($0, fileManager: fileManager) }
        var centralDirectory = Data()
        var localHeaderOffsets: [UInt32] = []
        localHeaderOffsets.reserveCapacity(preparedEntries.count)
        var archiveOffset: UInt64 = 0

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: destinationURL, options: .atomic)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        for entry in preparedEntries {
            guard archiveOffset <= UInt64(UInt32.max) else {
                throw ZipArchiveWriterError.archiveTooLarge
            }
            localHeaderOffsets.append(UInt32(archiveOffset))

            var localHeader = Data()
            appendUInt32(0x0403_4b50, to: &localHeader)
            appendUInt16(20, to: &localHeader)
            appendUInt16(Self.utf8FileNameFlag, to: &localHeader)
            appendUInt16(0, to: &localHeader)
            appendUInt16(0, to: &localHeader)
            appendUInt16(0, to: &localHeader)
            appendUInt32(entry.checksum, to: &localHeader)
            appendUInt32(entry.byteCount, to: &localHeader)
            appendUInt32(entry.byteCount, to: &localHeader)
            appendUInt16(UInt16(entry.nameData.count), to: &localHeader)
            appendUInt16(0, to: &localHeader)
            localHeader.append(entry.nameData)
            try output.write(contentsOf: localHeader)
            archiveOffset += UInt64(localHeader.count)

            try writePayload(entry.payload, to: output)
            archiveOffset += UInt64(entry.byteCount)
        }

        guard archiveOffset <= UInt64(UInt32.max) else {
            throw ZipArchiveWriterError.archiveTooLarge
        }
        let centralDirectoryOffset = UInt32(archiveOffset)
        for (index, entry) in preparedEntries.enumerated() {
            appendUInt32(0x0201_4b50, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(Self.utf8FileNameFlag, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(entry.checksum, to: &centralDirectory)
            appendUInt32(entry.byteCount, to: &centralDirectory)
            appendUInt32(entry.byteCount, to: &centralDirectory)
            appendUInt16(UInt16(entry.nameData.count), to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(0, to: &centralDirectory)
            appendUInt32(localHeaderOffsets[index], to: &centralDirectory)
            centralDirectory.append(entry.nameData)
        }

        guard centralDirectory.count <= Int(UInt32.max) else {
            throw ZipArchiveWriterError.archiveTooLarge
        }
        try output.write(contentsOf: centralDirectory)
        archiveOffset += UInt64(centralDirectory.count)

        var endRecord = Data()
        appendUInt32(0x0605_4b50, to: &endRecord)
        appendUInt16(0, to: &endRecord)
        appendUInt16(0, to: &endRecord)
        appendUInt16(UInt16(preparedEntries.count), to: &endRecord)
        appendUInt16(UInt16(preparedEntries.count), to: &endRecord)
        appendUInt32(UInt32(centralDirectory.count), to: &endRecord)
        appendUInt32(centralDirectoryOffset, to: &endRecord)
        appendUInt16(0, to: &endRecord)
        try output.write(contentsOf: endRecord)
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
        crc = updateCRC32(crc, with: data)
        return crc ^ 0xffff_ffff
    }

    /**
     Calculates standard ZIP CRC32 for a file payload without loading it all into memory.

     - Parameter fileURL: File whose bytes should be checksummed.
     - Returns: CRC32 value written into local and central ZIP headers.
     - Side effects: Opens and reads `fileURL` sequentially.
     - Failure modes: Rethrows file-open and file-read failures.
     */
    private static func crc32(fileURL: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var crc: UInt32 = 0xffff_ffff
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            crc = updateCRC32(crc, with: chunk)
        }
        return crc ^ 0xffff_ffff
    }

    /**
     Advances an in-progress ZIP CRC32 checksum with additional bytes.

     - Parameters:
       - crc: Current unfinalized CRC accumulator.
       - data: Additional payload bytes.
     - Returns: Updated unfinalized CRC accumulator.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func updateCRC32(_ crc: UInt32, with data: Data) -> UInt32 {
        var crc = crc
        for byte in data {
            let tableIndex = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ crc32Table[tableIndex]
        }
        return crc
    }

    /**
     Validates one file-backed ZIP entry and precomputes stored-entry metadata.

     - Parameters:
       - entry: Entry definition supplied by the caller.
       - fileManager: File manager used to inspect file payload sizes.
     - Returns: Prepared metadata used by the streaming writer.
     - Side effects: Reads file-backed entries to calculate CRC32.
     - Failure modes: Throws ZIP limit errors for oversized names or payloads, and rethrows file
       metadata/read errors for file-backed entries.
     */
    private static func prepare(
        _ entry: ZipArchiveWriterFileEntry,
        fileManager: FileManager
    ) throws -> PreparedFileEntry {
        guard let nameData = entry.name.data(using: .utf8),
              nameData.count <= Int(UInt16.max) else {
            throw ZipArchiveWriterError.entryTooLarge(entry.name)
        }

        let byteCount: UInt64
        let checksum: UInt32
        switch entry.payload {
        case .data(let data):
            byteCount = UInt64(data.count)
            checksum = crc32(data)
        case .file(let fileURL):
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max
            checksum = try crc32(fileURL: fileURL)
        }
        guard byteCount <= UInt64(UInt32.max) else {
            throw ZipArchiveWriterError.entryTooLarge(entry.name)
        }
        return PreparedFileEntry(
            name: entry.name,
            nameData: nameData,
            payload: entry.payload,
            checksum: checksum,
            byteCount: UInt32(byteCount)
        )
    }

    /**
     Copies one prepared payload into an open ZIP output stream.

     - Parameters:
       - payload: In-memory or file-backed payload to write.
       - output: Open file handle positioned at the next ZIP payload offset.
     - Side effects: Writes bytes to `output`; file payloads are opened and read sequentially.
     - Failure modes: Rethrows file-read or output-write failures.
     */
    private static func writePayload(
        _ payload: ZipArchiveWriterFileEntry.Payload,
        to output: FileHandle
    ) throws {
        switch payload {
        case .data(let data):
            try output.write(contentsOf: data)
        case .file(let fileURL):
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            while true {
                let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty {
                    break
                }
                try output.write(contentsOf: chunk)
            }
        }
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
