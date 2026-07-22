// RemoteSyncBoundedFileIO.swift -- Bounded archive and regular-file operations

import CLibSword
import CryptoKit
import Darwin
import Foundation
import SwordKit

/** Fail-visible size, type, and gzip-integrity failures for untrusted sync files. */
enum RemoteSyncBoundedFileError: Error, Equatable {
    /// The requested input path does not exist.
    case missingInput

    /// The input is not a regular no-follow file.
    case unsafeInput

    /// The destination cannot be created as a new regular no-follow file.
    case unsafeOutput

    /// Compressed bytes exceed the caller's accepted ceiling.
    case compressedSizeExceeded(Int64)

    /// The gzip trailer declares an expanded size above the accepted ceiling.
    case expandedSizeExceeded(UInt64)

    /// Gzip framing, flags, header fields, or trailer bounds are invalid.
    case malformedGzip

    /// Streaming inflation failed or exceeded the supplied output ceiling.
    case inflationFailed

    /// Streaming compression failed or could not satisfy the supplied byte ceilings.
    case compressionFailed

    /// Expanded size or CRC32 differs from the authenticated gzip trailer.
    case outputIntegrityMismatch
}

/** Exact size and SHA-256 identity produced while streaming one regular file. */
struct RemoteSyncRegularFileFingerprint: Sendable, Equatable {
    /// Number of bytes read from or written to the validated regular file.
    let byteCount: Int64

    /// Lowercase SHA-256 digest of those exact bytes.
    let sha256: String
}

/**
 Owns the validated descriptor and framing metadata for one strict gzip member.

 The descriptor remains open from header inspection through inflation, preventing a path replacement
 from changing the bytes consumed after validation. Deinitialization closes the descriptor on every
 success, failure, and inspection-only path.
 */
final class RemoteSyncGzipMember: Equatable {
    /// Complete compressed file size.
    let compressedByteCount: Int64

    /// Offset of the raw DEFLATE payload after the gzip header.
    let payloadOffset: UInt64

    /// Number of raw DEFLATE bytes before the eight-byte trailer.
    let payloadByteCount: UInt64

    /// CRC32 declared by the gzip trailer.
    let expandedChecksum: UInt32

    /// Expanded byte count declared by the gzip trailer.
    let expandedByteCount: UInt64

    /// Original source path used only to reject a caller/path mismatch before descriptor consumption.
    fileprivate let sourceURL: URL

    /// No-follow descriptor retained from inspection through inflation.
    fileprivate let descriptor: Int32

    /// Stable source identity and mutation metadata captured at open time.
    fileprivate let identity: RemoteSyncFileIdentity

    /** Creates a descriptor-owning member after complete framing validation. */
    fileprivate init(
        compressedByteCount: Int64,
        payloadOffset: UInt64,
        payloadByteCount: UInt64,
        expandedChecksum: UInt32,
        expandedByteCount: UInt64,
        sourceURL: URL,
        descriptor: Int32,
        identity: RemoteSyncFileIdentity
    ) {
        self.compressedByteCount = compressedByteCount
        self.payloadOffset = payloadOffset
        self.payloadByteCount = payloadByteCount
        self.expandedChecksum = expandedChecksum
        self.expandedByteCount = expandedByteCount
        self.sourceURL = sourceURL
        self.descriptor = descriptor
        self.identity = identity
    }

    /** Closes the source descriptor when the inspected member leaves scope. */
    deinit {
        Darwin.close(descriptor)
    }

    /** Compares framing and source identity without comparing process-local descriptor numbers. */
    static func == (lhs: RemoteSyncGzipMember, rhs: RemoteSyncGzipMember) -> Bool {
        lhs.compressedByteCount == rhs.compressedByteCount
            && lhs.payloadOffset == rhs.payloadOffset
            && lhs.payloadByteCount == rhs.payloadByteCount
            && lhs.expandedChecksum == rhs.expandedChecksum
            && lhs.expandedByteCount == rhs.expandedByteCount
            && lhs.sourceURL == rhs.sourceURL
            && lhs.identity == rhs.identity
    }
}

/** Immutable regular-file identity used to detect replacement or in-place mutation. */
fileprivate struct RemoteSyncFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    /** Captures fields that change when a path is replaced, resized, or modified in place. */
    init(status: stat) {
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
        size = Int64(status.st_size)
        modificationSeconds = Int64(status.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changeSeconds = Int64(status.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }
}

/**
 Performs no-follow inspection and bounded file-to-file gzip inflation.

 Inspection reads only fixed-size header/trailer fields through `pread`; compressed and expanded
 payloads are never materialized as `Data`. Inflation writes directly to a unique bounded file and
 verifies both exact output size and CRC32 before returning.
 */
enum RemoteSyncBoundedFileIO {
    /**
     Reads one bounded regular file without following a final-component symbolic link.

     - Parameters:
       - url: Local file whose exact bytes are required.
       - maximumByteCount: Maximum bytes admitted before allocation.
     - Returns: Exact file bytes after stable descriptor metadata is verified.
     - Side effects: Opens and reads one local file descriptor.
     - Throws: `missingInput`, `unsafeInput`, or `compressedSizeExceeded` before returning bytes.
     */
    static func readRegularFile(at url: URL, maximumByteCount: Int) throws -> Data {
        guard maximumByteCount >= 0 else { throw RemoteSyncBoundedFileError.unsafeInput }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw RemoteSyncBoundedFileError.missingInput }
            throw RemoteSyncBoundedFileError.unsafeInput
        }
        defer { Darwin.close(descriptor) }

        var initialStatus = stat()
        guard Darwin.fstat(descriptor, &initialStatus) == 0,
              (initialStatus.st_mode & S_IFMT) == S_IFREG,
              initialStatus.st_size >= 0 else {
            throw RemoteSyncBoundedFileError.unsafeInput
        }
        let identity = RemoteSyncFileIdentity(status: initialStatus)
        guard initialStatus.st_size <= off_t(maximumByteCount) else {
            throw RemoteSyncBoundedFileError.compressedSizeExceeded(
                Int64(initialStatus.st_size)
            )
        }
        guard let byteCount = Int(exactly: initialStatus.st_size) else {
            throw RemoteSyncBoundedFileError.compressedSizeExceeded(Int64.max)
        }

        var data = Data(count: byteCount)
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < byteCount {
                let readCount = Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    byteCount - offset
                )
                if readCount < 0, errno == EINTR { continue }
                guard readCount > 0 else { throw RemoteSyncBoundedFileError.unsafeInput }
                offset += readCount
            }
        }

        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0,
              RemoteSyncFileIdentity(status: finalStatus) == identity,
              pathStillNamesOpenedFile(url, identity: identity) else {
            throw RemoteSyncBoundedFileError.unsafeInput
        }
        return data
    }

    /**
     Inspects one strict gzip member without reading its payload into memory.

     - Parameters:
       - archiveURL: Local gzip file.
       - maximumCompressedByteCount: Maximum accepted input size.
       - maximumExpandedByteCount: Maximum accepted trailer size.
     - Returns: Validated member offsets and trailer metadata.
     - Side effects: Opens one no-follow descriptor and performs bounded positional reads.
     - Throws: `RemoteSyncBoundedFileError` for unsafe, oversized, or malformed input.
     */
    static func inspectGzip(
        at archiveURL: URL,
        maximumCompressedByteCount: Int,
        maximumExpandedByteCount: Int
    ) throws -> RemoteSyncGzipMember {
        guard maximumCompressedByteCount >= 0, maximumExpandedByteCount >= 0 else {
            throw RemoteSyncBoundedFileError.unsafeInput
        }
        let descriptor = Darwin.open(archiveURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw RemoteSyncBoundedFileError.missingInput }
            throw RemoteSyncBoundedFileError.unsafeInput
        }
        var descriptorOwnedByMember = false
        defer {
            if !descriptorOwnedByMember { Darwin.close(descriptor) }
        }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 18 else {
            throw RemoteSyncBoundedFileError.unsafeInput
        }
        let identity = RemoteSyncFileIdentity(status: status)
        guard pathStillNamesOpenedFile(archiveURL, identity: identity) else {
            throw RemoteSyncBoundedFileError.unsafeInput
        }
        guard status.st_size <= off_t(maximumCompressedByteCount) else {
            throw RemoteSyncBoundedFileError.compressedSizeExceeded(Int64(status.st_size))
        }

        let compressedSize = Int64(status.st_size)
        let trailerOffset = compressedSize - 8
        let fixedHeader = try readExactly(descriptor, offset: 0, count: 10)
        guard fixedHeader[0] == 0x1f,
              fixedHeader[1] == 0x8b,
              fixedHeader[2] == 8,
              fixedHeader[3] & 0xe0 == 0 else {
            throw RemoteSyncBoundedFileError.malformedGzip
        }

        var cursor: Int64 = 10
        let flags = fixedHeader[3]
        if flags & 0x04 != 0 {
            let lengthBytes = try readWithinHeader(
                descriptor,
                offset: cursor,
                count: 2,
                trailerOffset: trailerOffset
            )
            let extraLength = Int64(lengthBytes[0]) | (Int64(lengthBytes[1]) << 8)
            cursor += 2
            guard extraLength <= trailerOffset - cursor else {
                throw RemoteSyncBoundedFileError.malformedGzip
            }
            cursor += extraLength
        }
        if flags & 0x08 != 0 {
            cursor = try advancePastCString(
                descriptor,
                offset: cursor,
                trailerOffset: trailerOffset
            )
        }
        if flags & 0x10 != 0 {
            cursor = try advancePastCString(
                descriptor,
                offset: cursor,
                trailerOffset: trailerOffset
            )
        }
        if flags & 0x02 != 0 {
            let checksumBytes = try readWithinHeader(
                descriptor,
                offset: cursor,
                count: 2,
                trailerOffset: trailerOffset
            )
            let expectedHeaderChecksum = UInt16(checksumBytes[0])
                | (UInt16(checksumBytes[1]) << 8)
            let actualHeaderChecksum = UInt16(
                truncatingIfNeeded: try checksum(
                    descriptor,
                    offset: 0,
                    count: UInt64(cursor)
                )
            )
            guard actualHeaderChecksum == expectedHeaderChecksum else {
                throw RemoteSyncBoundedFileError.malformedGzip
            }
            cursor += 2
        }
        guard cursor < trailerOffset else {
            throw RemoteSyncBoundedFileError.malformedGzip
        }

        let trailer = try readExactly(descriptor, offset: trailerOffset, count: 8)
        let checksum = littleEndianUInt32(trailer[0..<4])
        let expandedSize = UInt64(littleEndianUInt32(trailer[4..<8]))
        guard expandedSize <= UInt64(maximumExpandedByteCount) else {
            throw RemoteSyncBoundedFileError.expandedSizeExceeded(expandedSize)
        }
        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0,
              RemoteSyncFileIdentity(status: finalStatus) == identity,
              pathStillNamesOpenedFile(archiveURL, identity: identity) else {
            throw RemoteSyncBoundedFileError.unsafeInput
        }
        let member = RemoteSyncGzipMember(
            compressedByteCount: compressedSize,
            payloadOffset: UInt64(cursor),
            payloadByteCount: UInt64(trailerOffset - cursor),
            expandedChecksum: checksum,
            expandedByteCount: expandedSize,
            sourceURL: archiveURL.standardizedFileURL,
            descriptor: descriptor,
            identity: identity
        )
        descriptorOwnedByMember = true
        return member
    }

    /**
     Inflates one previously inspected gzip member directly into a bounded output file.

     - Parameters:
       - member: Metadata returned for the same `archiveURL` by `inspectGzip`.
       - archiveURL: Source gzip file.
       - outputURL: Unique destination file.
       - maximumExpandedByteCount: Hard output limit enforced before every destination write.
     - Side effects: Creates `outputURL` exclusively; removes that inode on failure when it remains named.
     - Throws: Unsafe source/destination, inflation, output-size, or CRC32 failures.
     */
    static func inflateGzip(
        _ member: RemoteSyncGzipMember,
        from archiveURL: URL,
        to outputURL: URL,
        maximumExpandedByteCount: Int
    ) throws {
        guard maximumExpandedByteCount >= 0,
              archiveURL.standardizedFileURL == member.sourceURL,
              member.expandedByteCount <= UInt64(maximumExpandedByteCount) else {
            throw RemoteSyncBoundedFileError.unsafeInput
        }

        var sourceStatus = stat()
        guard Darwin.fstat(member.descriptor, &sourceStatus) == 0,
              RemoteSyncFileIdentity(status: sourceStatus) == member.identity,
              pathStillNamesOpenedFile(archiveURL, identity: member.identity) else {
            throw RemoteSyncBoundedFileError.unsafeInput
        }

        let outputDescriptor = Darwin.open(
            outputURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard outputDescriptor >= 0 else {
            throw RemoteSyncBoundedFileError.unsafeOutput
        }

        var createdStatus = stat()
        guard Darwin.fstat(outputDescriptor, &createdStatus) == 0,
              (createdStatus.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(outputDescriptor)
            throw RemoteSyncBoundedFileError.unsafeOutput
        }
        let outputDevice = UInt64(createdStatus.st_dev)
        let outputInode = UInt64(createdStatus.st_ino)

        do {
            guard let context = raw_inflater_create() else {
                throw RemoteSyncBoundedFileError.inflationFailed
            }
            defer { raw_inflater_destroy(context) }

            let chunkByteCount = 64 * 1_024
            var payloadOffset = member.payloadOffset
            var remainingPayload = member.payloadByteCount
            var reachedStreamEnd = false
            var writtenByteCount: UInt64 = 0
            var runningChecksum = UInt32.max

            while remainingPayload > 0 {
                try Task.checkCancellation()
                let inputByteCount = Int(min(UInt64(chunkByteCount), remainingPayload))
                let input = try readExactly(
                    member.descriptor,
                    offset: try platformOffset(payloadOffset),
                    count: inputByteCount
                )
                payloadOffset += UInt64(inputByteCount)
                remainingPayload -= UInt64(inputByteCount)

                let outcome = try consumeInflateInput(
                    input,
                    context: context,
                    outputDescriptor: outputDescriptor,
                    maximumExpandedByteCount: UInt64(maximumExpandedByteCount),
                    writtenByteCount: &writtenByteCount,
                    runningChecksum: &runningChecksum
                )
                if outcome {
                    guard remainingPayload == 0 else {
                        throw RemoteSyncBoundedFileError.inflationFailed
                    }
                    reachedStreamEnd = true
                    break
                }
            }

            while !reachedStreamEnd {
                try Task.checkCancellation()
                reachedStreamEnd = try consumeInflateInput(
                    [],
                    context: context,
                    outputDescriptor: outputDescriptor,
                    maximumExpandedByteCount: UInt64(maximumExpandedByteCount),
                    writtenByteCount: &writtenByteCount,
                    runningChecksum: &runningChecksum
                )
            }

            var consumedByteCount: UInt64 = 0
            var inflaterOutputByteCount: UInt64 = 0
            guard raw_inflater_metadata(
                context,
                &consumedByteCount,
                &inflaterOutputByteCount
            ) == 0,
                consumedByteCount == member.payloadByteCount,
                inflaterOutputByteCount == writtenByteCount,
                writtenByteCount == member.expandedByteCount,
                runningChecksum ^ UInt32.max == member.expandedChecksum else {
                throw RemoteSyncBoundedFileError.outputIntegrityMismatch
            }

            try Task.checkCancellation()

            guard Darwin.fsync(outputDescriptor) == 0 else {
                throw RemoteSyncBoundedFileError.unsafeOutput
            }
            var finalOutputStatus = stat()
            guard Darwin.fstat(outputDescriptor, &finalOutputStatus) == 0,
                  (finalOutputStatus.st_mode & S_IFMT) == S_IFREG,
                  finalOutputStatus.st_size == off_t(writtenByteCount),
                  pathStillNamesOpenedFile(
                      outputURL,
                      identity: RemoteSyncFileIdentity(status: finalOutputStatus)
                  ) else {
                throw RemoteSyncBoundedFileError.unsafeOutput
            }

            let trailerOffset = member.compressedByteCount - 8
            let trailer = try readExactly(member.descriptor, offset: trailerOffset, count: 8)
            var finalSourceStatus = stat()
            guard Darwin.fstat(member.descriptor, &finalSourceStatus) == 0,
                  RemoteSyncFileIdentity(status: finalSourceStatus) == member.identity,
                  pathStillNamesOpenedFile(archiveURL, identity: member.identity),
                  littleEndianUInt32(trailer[0..<4]) == member.expandedChecksum,
                  UInt64(littleEndianUInt32(trailer[4..<8])) == member.expandedByteCount else {
                throw RemoteSyncBoundedFileError.unsafeInput
            }

            guard Darwin.close(outputDescriptor) == 0 else {
                throw RemoteSyncBoundedFileError.unsafeOutput
            }
        } catch {
            Darwin.close(outputDescriptor)
            removeCreatedFile(
                at: outputURL,
                device: outputDevice,
                inode: outputInode
            )
            throw error
        }
    }

    /**
     Inspects and inflates one current gzip path through the same retained descriptor.

     - Parameters:
       - archiveURL: Untrusted local gzip archive.
       - outputURL: Unique SQLite output path that must not already exist.
       - maximumCompressedByteCount: Hard source-file ceiling.
       - maximumExpandedByteCount: Hard observed and trailer-declared output ceiling.
     - Returns: Exact verified expanded byte count.
     - Side Effects: Opens the source without following symlinks and creates `outputURL` exclusively.
     - Throws: Cancellation or `RemoteSyncBoundedFileError`; every failed output is removed.
     - Important: Header inspection, payload reads, and trailer revalidation use one descriptor, so
       replacing `archiveURL` between those phases cannot substitute different bytes.
     */
    @discardableResult
    static func inflateGzip(
        at archiveURL: URL,
        to outputURL: URL,
        maximumCompressedByteCount: Int,
        maximumExpandedByteCount: Int
    ) throws -> UInt64 {
        try Task.checkCancellation()
        let member = try inspectGzip(
            at: archiveURL,
            maximumCompressedByteCount: maximumCompressedByteCount,
            maximumExpandedByteCount: maximumExpandedByteCount
        )
        try Task.checkCancellation()
        try inflateGzip(
            member,
            from: archiveURL,
            to: outputURL,
            maximumExpandedByteCount: maximumExpandedByteCount
        )
        return member.expandedByteCount
    }

    /**
     Compresses one exact regular file directly into one bounded gzip member.

     - Parameters:
       - inputURL: Existing no-follow regular file to compress.
       - outputURL: Unique destination that must not already exist.
       - maximumInputByteCount: Maximum source bytes accepted before compression starts.
       - maximumOutputByteCount: Maximum complete gzip bytes, including header and trailer.
     - Returns: Exact output size and SHA-256 digest computed over bytes as they are written.
     - Side Effects: Reads `inputURL`, creates and fsyncs `outputURL`, and removes the created inode
       on every compression, cancellation, integrity, or filesystem failure.
     - Throws: Cancellation or `RemoteSyncBoundedFileError` for unsafe files, size limits, or codec I/O.
     */
    static func gzipRegularFile(
        at inputURL: URL,
        to outputURL: URL,
        maximumInputByteCount: Int,
        maximumOutputByteCount: Int
    ) throws -> RemoteSyncRegularFileFingerprint {
        guard maximumInputByteCount >= 0, maximumOutputByteCount >= 18 else {
            throw RemoteSyncBoundedFileError.compressionFailed
        }

        let inputDescriptor = Darwin.open(inputURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard inputDescriptor >= 0 else {
            if errno == ENOENT { throw RemoteSyncBoundedFileError.missingInput }
            throw RemoteSyncBoundedFileError.unsafeInput
        }
        defer { Darwin.close(inputDescriptor) }

        var initialInputStatus = stat()
        guard Darwin.fstat(inputDescriptor, &initialInputStatus) == 0,
              (initialInputStatus.st_mode & S_IFMT) == S_IFREG,
              initialInputStatus.st_size >= 0 else {
            throw RemoteSyncBoundedFileError.unsafeInput
        }
        let inputIdentity = RemoteSyncFileIdentity(status: initialInputStatus)
        guard initialInputStatus.st_size <= off_t(maximumInputByteCount),
              pathStillNamesOpenedFile(inputURL, identity: inputIdentity) else {
            if initialInputStatus.st_size > off_t(maximumInputByteCount) {
                throw RemoteSyncBoundedFileError.expandedSizeExceeded(
                    UInt64(initialInputStatus.st_size)
                )
            }
            throw RemoteSyncBoundedFileError.unsafeInput
        }

        let outputDescriptor = Darwin.open(
            outputURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard outputDescriptor >= 0 else {
            throw RemoteSyncBoundedFileError.unsafeOutput
        }
        var outputIsOpen = true
        var createdOutputStatus = stat()
        guard Darwin.fstat(outputDescriptor, &createdOutputStatus) == 0,
              (createdOutputStatus.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(outputDescriptor)
            throw RemoteSyncBoundedFileError.unsafeOutput
        }
        let outputDevice = UInt64(createdOutputStatus.st_dev)
        let outputInode = UInt64(createdOutputStatus.st_ino)

        do {
            guard let context = raw_deflater_create() else {
                throw RemoteSyncBoundedFileError.compressionFailed
            }
            defer { raw_deflater_destroy(context) }

            var hasher = SHA256()
            var writtenByteCount = UInt64(0)
            let gzipHeader = [UInt8](
                [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
            )
            try writeBoundedAndHash(
                gzipHeader,
                to: outputDescriptor,
                maximumByteCount: UInt64(maximumOutputByteCount),
                writtenByteCount: &writtenByteCount,
                hasher: &hasher
            )

            let chunkByteCount = 64 * 1_024
            var sourceByteCount = UInt64(0)
            while true {
                try Task.checkCancellation()
                var input = [UInt8](repeating: 0, count: chunkByteCount)
                let readCount = input.withUnsafeMutableBytes { buffer in
                    Darwin.read(inputDescriptor, buffer.baseAddress, buffer.count)
                }
                if readCount < 0, errno == EINTR { continue }
                guard readCount >= 0 else { throw RemoteSyncBoundedFileError.unsafeInput }
                if readCount == 0 { break }
                input.removeSubrange(readCount..<input.count)
                sourceByteCount += UInt64(readCount)
                guard sourceByteCount <= UInt64(maximumInputByteCount) else {
                    throw RemoteSyncBoundedFileError.expandedSizeExceeded(sourceByteCount)
                }
                _ = try consumeDeflateInput(
                    input,
                    finish: false,
                    context: context,
                    outputDescriptor: outputDescriptor,
                    maximumOutputByteCount: UInt64(maximumOutputByteCount),
                    writtenByteCount: &writtenByteCount,
                    hasher: &hasher
                )
            }

            var reachedStreamEnd = false
            while !reachedStreamEnd {
                try Task.checkCancellation()
                reachedStreamEnd = try consumeDeflateInput(
                    [],
                    finish: true,
                    context: context,
                    outputDescriptor: outputDescriptor,
                    maximumOutputByteCount: UInt64(maximumOutputByteCount),
                    writtenByteCount: &writtenByteCount,
                    hasher: &hasher
                )
            }

            var checksum: UInt32 = 0
            var compressedInputByteCount: UInt64 = 0
            var compressedPayloadByteCount: UInt64 = 0
            guard raw_deflater_metadata(
                context,
                &checksum,
                &compressedInputByteCount,
                &compressedPayloadByteCount
            ) == 0,
                compressedInputByteCount == sourceByteCount,
                compressedPayloadByteCount == writtenByteCount - UInt64(gzipHeader.count) else {
                throw RemoteSyncBoundedFileError.compressionFailed
            }

            let trailer = littleEndianBytes(checksum)
                + littleEndianBytes(UInt32(truncatingIfNeeded: sourceByteCount))
            try writeBoundedAndHash(
                trailer,
                to: outputDescriptor,
                maximumByteCount: UInt64(maximumOutputByteCount),
                writtenByteCount: &writtenByteCount,
                hasher: &hasher
            )
            try Task.checkCancellation()

            var finalInputStatus = stat()
            guard Darwin.fstat(inputDescriptor, &finalInputStatus) == 0,
                  RemoteSyncFileIdentity(status: finalInputStatus) == inputIdentity,
                  UInt64(finalInputStatus.st_size) == sourceByteCount,
                  pathStillNamesOpenedFile(inputURL, identity: inputIdentity),
                  Darwin.fsync(outputDescriptor) == 0 else {
                throw RemoteSyncBoundedFileError.unsafeInput
            }
            var finalOutputStatus = stat()
            guard Darwin.fstat(outputDescriptor, &finalOutputStatus) == 0,
                  (finalOutputStatus.st_mode & S_IFMT) == S_IFREG,
                  UInt64(finalOutputStatus.st_size) == writtenByteCount,
                  pathStillNamesOpenedFile(
                      outputURL,
                      identity: RemoteSyncFileIdentity(status: finalOutputStatus)
                  ) else {
                throw RemoteSyncBoundedFileError.unsafeOutput
            }
            guard Darwin.close(outputDescriptor) == 0 else {
                throw RemoteSyncBoundedFileError.unsafeOutput
            }
            outputIsOpen = false
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return RemoteSyncRegularFileFingerprint(
                byteCount: Int64(writtenByteCount),
                sha256: digest
            )
        } catch {
            if outputIsOpen { Darwin.close(outputDescriptor) }
            removeCreatedFile(at: outputURL, device: outputDevice, inode: outputInode)
            throw error
        }
    }

    /**
     Streams one regular file into SHA-256 without allocating in proportion to file size.

     - Parameters:
       - url: Existing no-follow regular file.
       - maximumByteCount: Hard source ceiling.
     - Returns: Exact descriptor size and digest after identity revalidation.
     - Side Effects: Opens and reads one local file.
     - Throws: Cancellation or a bounded-file safety/size error.
     */
    static func fingerprintRegularFile(
        at url: URL,
        maximumByteCount: Int
    ) throws -> RemoteSyncRegularFileFingerprint {
        guard maximumByteCount >= 0 else { throw RemoteSyncBoundedFileError.unsafeInput }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw RemoteSyncBoundedFileError.missingInput }
            throw RemoteSyncBoundedFileError.unsafeInput
        }
        defer { Darwin.close(descriptor) }

        var initialStatus = stat()
        guard Darwin.fstat(descriptor, &initialStatus) == 0,
              (initialStatus.st_mode & S_IFMT) == S_IFREG,
              initialStatus.st_size >= 0 else {
            throw RemoteSyncBoundedFileError.unsafeInput
        }
        let identity = RemoteSyncFileIdentity(status: initialStatus)
        guard initialStatus.st_size <= off_t(maximumByteCount) else {
            throw RemoteSyncBoundedFileError.compressedSizeExceeded(Int64(initialStatus.st_size))
        }

        var hasher = SHA256()
        var observedByteCount = Int64(0)
        while true {
            try Task.checkCancellation()
            var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
            let readCount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount >= 0 else { throw RemoteSyncBoundedFileError.unsafeInput }
            if readCount == 0 { break }
            observedByteCount += Int64(readCount)
            guard observedByteCount <= Int64(maximumByteCount) else {
                throw RemoteSyncBoundedFileError.compressedSizeExceeded(observedByteCount)
            }
            hasher.update(data: Data(bytes.prefix(readCount)))
        }

        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0,
              RemoteSyncFileIdentity(status: finalStatus) == identity,
              Int64(finalStatus.st_size) == observedByteCount,
              pathStillNamesOpenedFile(url, identity: identity) else {
            throw RemoteSyncBoundedFileError.unsafeInput
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return RemoteSyncRegularFileFingerprint(
            byteCount: observedByteCount,
            sha256: digest
        )
    }

    /** Returns one no-follow regular file size without reading payload bytes. */
    static func regularFileSize(at url: URL) throws -> Int64 {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RemoteSyncBoundedFileError.unsafeInput }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            throw RemoteSyncBoundedFileError.unsafeInput
        }
        return Int64(status.st_size)
    }

    /** Reads one exact positional range into a small bounded buffer. */
    private static func readExactly(_ descriptor: Int32, offset: Int64, count: Int) throws -> [UInt8] {
        guard offset >= 0, count >= 0 else {
            throw RemoteSyncBoundedFileError.malformedGzip
        }
        var bytes = [UInt8](repeating: 0, count: count)
        var totalRead = 0
        while totalRead < count {
            let readCount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress?.advanced(by: totalRead),
                    count - totalRead,
                    off_t(offset) + off_t(totalRead)
                )
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else { throw RemoteSyncBoundedFileError.malformedGzip }
            totalRead += readCount
        }
        return bytes
    }

    /** Reads a bounded header range that must end before the gzip trailer. */
    private static func readWithinHeader(
        _ descriptor: Int32,
        offset: Int64,
        count: Int,
        trailerOffset: Int64
    ) throws -> [UInt8] {
        guard offset >= 0, Int64(count) <= trailerOffset - offset else {
            throw RemoteSyncBoundedFileError.malformedGzip
        }
        return try readExactly(descriptor, offset: offset, count: count)
    }

    /** Advances over one NUL-terminated optional gzip header field without allocating it. */
    private static func advancePastCString(
        _ descriptor: Int32,
        offset: Int64,
        trailerOffset: Int64
    ) throws -> Int64 {
        var cursor = offset
        while cursor < trailerOffset {
            let chunkByteCount = Int(min(Int64(4_096), trailerOffset - cursor))
            let chunk = try readExactly(descriptor, offset: cursor, count: chunkByteCount)
            if let terminator = chunk.firstIndex(of: 0) {
                return cursor + Int64(terminator) + 1
            }
            cursor += Int64(chunkByteCount)
        }
        throw RemoteSyncBoundedFileError.malformedGzip
    }

    /** Converts an archive offset to the platform positional-I/O type without truncation. */
    private static func platformOffset(_ value: UInt64) throws -> Int64 {
        guard let offset = Int64(exactly: value) else {
            throw RemoteSyncBoundedFileError.malformedGzip
        }
        return offset
    }

    /** Drains one compressed slice while enforcing the output budget before each write. */
    private static func consumeInflateInput(
        _ input: [UInt8],
        context: UnsafeMutableRawPointer,
        outputDescriptor: Int32,
        maximumExpandedByteCount: UInt64,
        writtenByteCount: inout UInt64,
        runningChecksum: inout UInt32
    ) throws -> Bool {
        var inputOffset = 0
        repeat {
            try Task.checkCancellation()
            var output = [UInt8](repeating: 0, count: 64 * 1_024)
            let outputCapacity = UInt32(output.count)
            var consumed: UInt32 = 0
            var produced: UInt32 = 0
            let result = output.withUnsafeMutableBytes { outputBuffer in
                input.withUnsafeBytes { inputBuffer in
                    raw_inflater_process(
                        context,
                        inputBuffer.baseAddress?
                            .assumingMemoryBound(to: UInt8.self)
                            .advanced(by: inputOffset),
                        UInt32(input.count - inputOffset),
                        outputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        outputCapacity,
                        &consumed,
                        &produced
                    )
                }
            }
            guard result >= 0 else { throw RemoteSyncBoundedFileError.inflationFailed }

            let producedByteCount = UInt64(produced)
            guard writtenByteCount <= maximumExpandedByteCount,
                  producedByteCount <= maximumExpandedByteCount - writtenByteCount else {
                throw RemoteSyncBoundedFileError.expandedSizeExceeded(
                    writtenByteCount + producedByteCount
                )
            }
            if produced > 0 {
                runningChecksum = updateChecksum(
                    runningChecksum,
                    bytes: output,
                    count: Int(produced)
                )
                try output.withUnsafeBytes { buffer in
                    try writeAll(
                        outputDescriptor,
                        bytes: UnsafeRawBufferPointer(rebasing: buffer[..<Int(produced)])
                    )
                }
                writtenByteCount += producedByteCount
            }
            inputOffset += Int(consumed)

            if result == 1 {
                guard inputOffset == input.count else {
                    throw RemoteSyncBoundedFileError.inflationFailed
                }
                return true
            }
            guard consumed > 0 || produced > 0 else {
                throw RemoteSyncBoundedFileError.inflationFailed
            }
        } while inputOffset < input.count || input.isEmpty
        return false
    }

    /** Drains one DEFLATE input slice into a bounded output while updating its exact digest. */
    private static func consumeDeflateInput(
        _ input: [UInt8],
        finish: Bool,
        context: UnsafeMutableRawPointer,
        outputDescriptor: Int32,
        maximumOutputByteCount: UInt64,
        writtenByteCount: inout UInt64,
        hasher: inout SHA256
    ) throws -> Bool {
        var inputOffset = 0
        repeat {
            try Task.checkCancellation()
            var output = [UInt8](repeating: 0, count: 64 * 1_024)
            let outputCapacity = UInt32(output.count)
            var consumed: UInt32 = 0
            var produced: UInt32 = 0
            let result = output.withUnsafeMutableBytes { outputBuffer in
                input.withUnsafeBytes { inputBuffer in
                    raw_deflater_process(
                        context,
                        inputBuffer.baseAddress?
                            .assumingMemoryBound(to: UInt8.self)
                            .advanced(by: inputOffset),
                        UInt32(input.count - inputOffset),
                        finish ? 1 : 0,
                        outputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        outputCapacity,
                        &consumed,
                        &produced
                    )
                }
            }
            guard result >= 0, result != 1 || finish else {
                throw RemoteSyncBoundedFileError.compressionFailed
            }
            if produced > 0 {
                try writeBoundedAndHash(
                    Array(output.prefix(Int(produced))),
                    to: outputDescriptor,
                    maximumByteCount: maximumOutputByteCount,
                    writtenByteCount: &writtenByteCount,
                    hasher: &hasher
                )
            }
            inputOffset += Int(consumed)
            if result == 1 {
                guard inputOffset == input.count else {
                    throw RemoteSyncBoundedFileError.compressionFailed
                }
                return true
            }
            guard consumed > 0 || produced > 0 else {
                throw RemoteSyncBoundedFileError.compressionFailed
            }
        } while inputOffset < input.count || input.isEmpty
        return false
    }

    /** Writes one slice without crossing a complete-file ceiling and hashes the same bytes. */
    private static func writeBoundedAndHash(
        _ bytes: [UInt8],
        to descriptor: Int32,
        maximumByteCount: UInt64,
        writtenByteCount: inout UInt64,
        hasher: inout SHA256
    ) throws {
        guard writtenByteCount <= maximumByteCount,
              UInt64(bytes.count) <= maximumByteCount - writtenByteCount else {
            throw RemoteSyncBoundedFileError.compressedSizeExceeded(
                Int64(clamping: writtenByteCount + UInt64(bytes.count))
            )
        }
        try bytes.withUnsafeBytes { buffer in
            try writeAll(descriptor, bytes: buffer)
        }
        hasher.update(data: Data(bytes))
        writtenByteCount += UInt64(bytes.count)
    }

    /** Writes an entire output slice, retrying interrupted system calls. */
    private static func writeAll(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws {
        var written = 0
        while written < bytes.count {
            let result = Darwin.write(
                descriptor,
                bytes.baseAddress?.advanced(by: written),
                bytes.count - written
            )
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw RemoteSyncBoundedFileError.unsafeOutput }
            written += result
        }
    }

    /** Computes CRC32 for one descriptor range without allocating in proportion to input size. */
    private static func checksum(
        _ descriptor: Int32,
        offset: Int64,
        count: UInt64
    ) throws -> UInt32 {
        var cursor = UInt64(0)
        var runningChecksum = UInt32.max
        while cursor < count {
            let chunkByteCount = Int(min(UInt64(64 * 1_024), count - cursor))
            guard let absoluteOffset = Int64(exactly: cursor),
                  absoluteOffset <= Int64.max - offset else {
                throw RemoteSyncBoundedFileError.malformedGzip
            }
            let bytes = try readExactly(
                descriptor,
                offset: offset + absoluteOffset,
                count: chunkByteCount
            )
            runningChecksum = updateChecksum(
                runningChecksum,
                bytes: bytes,
                count: bytes.count
            )
            cursor += UInt64(bytes.count)
        }
        return runningChecksum ^ UInt32.max
    }

    /** Advances one standard CRC32 accumulator over a bounded byte prefix. */
    private static func updateChecksum(
        _ checksum: UInt32,
        bytes: [UInt8],
        count: Int
    ) -> UInt32 {
        var value = checksum
        for byte in bytes.prefix(count) {
            value = crc32Table[Int((value ^ UInt32(byte)) & 0xff)] ^ (value >> 8)
        }
        return value
    }

    /** Standard reflected CRC32 lookup table shared by header and payload validation. */
    private static let crc32Table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 0 ? value >> 1 : 0xedb8_8320 ^ (value >> 1)
        }
        return value
    }

    /** Confirms a path is still a regular file with the descriptor's complete captured identity. */
    private static func pathStillNamesOpenedFile(
        _ url: URL,
        identity: RemoteSyncFileIdentity
    ) -> Bool {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        return RemoteSyncFileIdentity(status: status) == identity
    }

    /** Removes only the output inode created by this operation, never a substituted path. */
    private static func removeCreatedFile(at url: URL, device: UInt64, inode: UInt64) {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              UInt64(status.st_dev) == device,
              UInt64(status.st_ino) == inode else {
            return
        }
        _ = Darwin.unlink(url.path)
    }

    /** Decodes four little-endian bytes without alignment assumptions. */
    private static func littleEndianUInt32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        let values = Array(bytes)
        return UInt32(values[0])
            | (UInt32(values[1]) << 8)
            | (UInt32(values[2]) << 16)
            | (UInt32(values[3]) << 24)
    }

    /** Encodes one gzip trailer word without alignment or host-endian assumptions. */
    private static func littleEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ]
    }
}
