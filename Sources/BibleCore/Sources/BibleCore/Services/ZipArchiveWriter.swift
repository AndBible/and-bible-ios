// ZipArchiveWriter.swift — ZIP archive writer for Android-compatible backup exports

import Darwin
import Foundation
import SwordKit

/**
 Errors raised while creating ZIP archives for backup export.

 The writer intentionally supports the small stored-entry ZIP shape needed by Android backup
 parity instead of becoming a general-purpose archive library.
 */
public enum ZipArchiveWriterError: Error, LocalizedError, Equatable {
    /// One entry path exceeds a ZIP field limit that ZIP64 cannot extend.
    case entryTooLarge(String)

    /// Archive metadata arithmetic or an internal ZIP invariant cannot be represented safely.
    case archiveTooLarge

    /// The destination volume cannot hold a conservative bound for the streaming archive.
    case insufficientStorage(required: UInt64, available: UInt64)

    /// A file source is a symbolic link, hard link, special node, or otherwise unsafe to export.
    case unsafeSource(String)

    /// A pinned source changed while its bytes were being written.
    case sourceChanged(String)

    /// The raw-DEFLATE encoder could not complete a ZIP member.
    case compressionFailed(String)

    /// User-visible error description.
    public var errorDescription: String? {
        switch self {
        case .entryTooLarge(let name):
            return "ZIP entry is too large for Android-compatible export: \(name)"
        case .archiveTooLarge:
            return "ZIP archive is too large for Android-compatible export."
        case .insufficientStorage(let required, let available):
            return "ZIP export needs \(required) bytes, but only \(available) bytes are available."
        case .unsafeSource(let path):
            return "ZIP export source is not a private regular file: \(path)"
        case .sourceChanged(let path):
            return "ZIP export source changed while it was being archived: \(path)"
        case .compressionFailed(let name):
            return "ZIP entry could not be compressed: \(name)"
        }
    }
}

/**
 Pins one regular export source to a no-follow descriptor for the inventory-to-writer lifetime.

 The descriptor, rather than a pathname reopen, is the source of truth for archive bytes. Hard
 links are rejected so one selected family cannot alias another family's payload. A final `fstat`
 comparison detects same-inode mutation during streaming.
 */
final class ZipArchiveWriterPinnedFileSource: @unchecked Sendable {
    /// Original path retained only for diagnostics.
    let fileURL: URL

    /// Open no-follow descriptor owned by `handle`.
    private let handle: FileHandle

    /// Device/inode/size/time identity captured when the descriptor was opened.
    private let initialStat: stat

    /**
     Opens and validates one immutable-by-contract export source.

     - Parameter fileURL: Contained candidate file selected by the installed-content catalog.
     - Side effects: Opens a read-only descriptor that remains live until this object is released.
     - Throws: POSIX errors or `unsafeSource` for symlinks, special nodes, and hardlinks.
     */
    init(fileURL: URL) throws {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0 else {
            Darwin.close(descriptor)
            throw ZipArchiveWriterError.unsafeSource(fileURL.path)
        }
        self.fileURL = fileURL
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.initialStat = metadata
    }

    /// Declared uncompressed byte count captured from the pinned descriptor.
    var byteCount: UInt64 { UInt64(initialStat.st_size) }

    /// Stable device/inode key used to reject one source selected through multiple archive families.
    var identityKey: String { "\(initialStat.st_dev):\(initialStat.st_ino)" }

    /** Rewinds the pinned descriptor before its single sequential export read. */
    func rewind() throws {
        guard Darwin.lseek(handle.fileDescriptor, 0, SEEK_SET) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /** Reads the next bounded source chunk from the pinned descriptor. */
    func read(upToCount count: Int) throws -> Data {
        try handle.read(upToCount: count) ?? Data()
    }

    /**
     Reads small metadata with a descriptor stat preflight and a hard `limit + 1` boundary.

     - Parameter maximumByteCount: Largest accepted metadata payload.
     - Returns: Complete bytes when the pinned file fits within the limit.
     - Side effects: Rewinds and reads this descriptor, then rewinds it for archive streaming.
     - Throws: `entryTooLarge`, cancellation, descriptor read/seek errors, or `sourceChanged`.
     */
    func boundedData(maximumByteCount: Int) throws -> Data {
        guard maximumByteCount >= 0,
              byteCount <= UInt64(maximumByteCount) else {
            throw ZipArchiveWriterError.entryTooLarge(fileURL.lastPathComponent)
        }
        try rewind()
        var data = Data()
        let hardLimit = maximumByteCount == Int.max ? Int.max : maximumByteCount + 1
        while data.count < hardLimit {
            try Task.checkCancellation()
            let remaining = hardLimit - data.count
            let chunk = try read(upToCount: min(64 * 1024, remaining))
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maximumByteCount else {
            throw ZipArchiveWriterError.entryTooLarge(fileURL.lastPathComponent)
        }
        try validateAfterStreaming(streamedByteCount: UInt64(data.count))
        try rewind()
        return data
    }

    /**
     Confirms the same private inode supplied exactly the bytes recorded by the compressor.

     - Parameter streamedByteCount: Uncompressed bytes consumed by the raw-DEFLATE encoder.
     - Side effects: Reads descriptor metadata only.
     - Throws: `sourceChanged` if size, identity, link count, or modification/change time differs.
     */
    func validateAfterStreaming(streamedByteCount: UInt64) throws {
        var finalStat = stat()
        guard Darwin.fstat(handle.fileDescriptor, &finalStat) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard streamedByteCount == byteCount,
              finalStat.st_dev == initialStat.st_dev,
              finalStat.st_ino == initialStat.st_ino,
              finalStat.st_nlink == 1,
              finalStat.st_size == initialStat.st_size,
              finalStat.st_mtimespec.tv_sec == initialStat.st_mtimespec.tv_sec,
              finalStat.st_mtimespec.tv_nsec == initialStat.st_mtimespec.tv_nsec,
              finalStat.st_ctimespec.tv_sec == initialStat.st_ctimespec.tv_sec,
              finalStat.st_ctimespec.tv_nsec == initialStat.st_ctimespec.tv_nsec else {
            throw ZipArchiveWriterError.sourceChanged(fileURL.path)
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
struct ZipArchiveWriterFileEntry: Sendable {
    /// Relative ZIP entry path using `/` separators.
    let name: String

    /// Source payload for the entry.
    let payload: Payload

    /**
     Source payload used by the streaming ZIP writer.

     `data` is intended for small generated entries such as manifests. `file` is intended for SQLite
     databases and other large backup payloads that should be copied incrementally.
     */
    enum Payload: Sendable {
        /// In-memory bytes for a small generated entry.
        case data(Data)

        /// File URL for an entry copied in chunks.
        case file(URL)

        /// No-follow descriptor pinned while the installed-content inventory is validated.
        case pinnedFile(ZipArchiveWriterPinnedFileSource)
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

    /** Creates a file-backed entry from an already validated, pinned source descriptor. */
    init(name: String, pinnedFile: ZipArchiveWriterPinnedFileSource) {
        self.name = name
        payload = .pinnedFile(pinnedFile)
    }
}

/**
 Creates ZIP archives with central-directory metadata.

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
            let checksum = ArchiveCRC32.checksum(of: entry.data)
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

            let checksum = ArchiveCRC32.checksum(of: entry.data)
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
            checksum = ArchiveCRC32.checksum(of: data)
        case .file(let fileURL):
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max
            checksum = try ArchiveCRC32.checksum(fileAt: fileURL)
        case .pinnedFile(let source):
            throw ZipArchiveWriterError.unsafeSource(source.fileURL.path)
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
        case .pinnedFile(let source):
            throw ZipArchiveWriterError.unsafeSource(source.fileURL.path)
        }
    }

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
