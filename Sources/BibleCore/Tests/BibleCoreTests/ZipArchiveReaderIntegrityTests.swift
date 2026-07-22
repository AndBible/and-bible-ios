import CLibSword
import SwordKit
import XCTest
@testable import BibleCore

/**
 Regression tests for ZIP payload integrity checks shared by eager and file-backed extraction.

 The fixtures keep local payload bytes valid while mutating matching local and central metadata,
 proving extraction fails closed and removes any file created before corruption is detected.
 */
final class ZipArchiveReaderIntegrityTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    /** Removes temporary archives and extraction directories created by each test. */
    override func tearDown() {
        for url in temporaryURLs.reversed() {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    /**
     Verifies a cancelled file-backed checksum stops before reading payload bytes.

     A semaphore holds the worker immediately before the production API call so cancellation is
     deterministic. Failure means archive extraction can spend unbounded time rehashing a large
     output after its owning restore task has already been cancelled.
     */
    func testFileBackedChecksumHonorsCancellationBeforeReading() async throws {
        let directory = try makeTemporaryDirectory(named: "zip-crc-cancellation")
        let fileURL = directory.appendingPathComponent("payload.bin")
        try Data(repeating: 0x41, count: 128 * 1_024).write(to: fileURL)
        let reachedChecksum = expectation(description: "checksum worker reached the read boundary")
        let releaseChecksum = ZipChecksumReleaseGate()
        let task = Task.detached {
            reachedChecksum.fulfill()
            await releaseChecksum.wait()
            return try ArchiveCRC32.checksum(fileAt: fileURL)
        }
        await fulfillment(of: [reachedChecksum], timeout: 5)
        task.cancel()
        await releaseChecksum.release()

        do {
            _ = try await task.value
            XCTFail("Expected file-backed checksum cancellation")
        } catch is CancellationError {
            // Expected before the first descriptor read.
        }
    }

    /**
     Verifies eager extraction rejects payload bytes that do not match declared ZIP CRC32 metadata.

     The fixture contains a valid stored member and both header checksums are changed. A failure
     means an in-memory Android backup import could accept corrupted bytes with otherwise valid ZIP
     structure and size metadata.
     */
    func testInMemoryExtractionRejectsCentralDirectoryChecksumMismatch() throws {
        let entryName = "db/bookmarks.sqlite3"
        let payload = Data("checksum-protected payload".utf8)
        var fixture = try makeClassicZIPFixture(
            name: entryName,
            payload: payload,
            compression: .stored
        )
        let invalidChecksum = zipFixtureCRC32(payload) ^ UInt32.max
        replaceLittleEndianUInt32(
            invalidChecksum,
            in: &fixture.data,
            at: fixture.localHeaderOffset + 14
        )
        replaceLittleEndianUInt32(
            invalidChecksum,
            in: &fixture.data,
            at: fixture.centralHeaderOffset + 16
        )

        XCTAssertThrowsError(try ZipArchiveReader.entries(in: fixture.data)) { error in
            XCTAssertEqual(
                error as? ZipArchiveReaderError,
                .invalidArchive("ZIP entry checksum mismatch: \(entryName)")
            )
        }
    }

    /**
     Verifies streamed extraction rejects a declared CRC32 mismatch and removes output.

     The file-backed reader first copies the valid stored payload, then compares it with the
     deliberately corrupted matching header checksums. The destination must not survive that failed
     validation; otherwise a restore caller could consume corrupted residue after an error.
     */
    func testFileBackedExtractionRejectsChecksumMismatchAndRemovesDestination() throws {
        let entryName = "db/bookmarks.sqlite3"
        let payload = Data("file-backed checksum payload".utf8)
        var fixture = try makeClassicZIPFixture(
            name: entryName,
            payload: payload,
            compression: .stored
        )
        let invalidChecksum = zipFixtureCRC32(payload) ^ UInt32.max
        replaceLittleEndianUInt32(
            invalidChecksum,
            in: &fixture.data,
            at: fixture.localHeaderOffset + 14
        )
        replaceLittleEndianUInt32(
            invalidChecksum,
            in: &fixture.data,
            at: fixture.centralHeaderOffset + 16
        )
        let archiveURL = try writeTemporaryArchive(fixture.data)
        let destinationURL = try makeTemporaryDirectory(named: "zip-crc-output")
            .appendingPathComponent("bookmarks.sqlite3")
        let entry = try XCTUnwrap(ZipArchiveReader.fileEntries(inArchiveAt: archiveURL).first)

        XCTAssertThrowsError(
            try ZipArchiveReader.extract(entry, fromArchiveAt: archiveURL, to: destinationURL)
        ) { error in
            XCTAssertEqual(
                error as? ZipArchiveReaderError,
                .invalidArchive("ZIP entry checksum mismatch: \(entryName)")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    /**
     Verifies streamed deflate extraction enforces the declared output bound before writing bytes.

     A valid raw-deflate member expands to 1,024 bytes, while matching local and central
     uncompressed-size fields declare 31 bytes. The observing file manager records the output
     size immediately before cleanup, proving the inflater never writes beyond that declaration and
     the public reader removes the destination after rejecting the entry.
     */
    func testFileBackedDeflateRejectsOutputBeyondDeclaredSizeWithoutResidue() throws {
        let payload = Data(repeating: 0x41, count: 1_024)
        let declaredUncompressedSize: UInt32 = 31
        var fixture = try makeClassicZIPFixture(
            name: "db/bookmarks.sqlite3",
            payload: payload,
            compression: .deflated
        )
        replaceLittleEndianUInt32(
            declaredUncompressedSize,
            in: &fixture.data,
            at: fixture.localHeaderOffset + 22
        )
        replaceLittleEndianUInt32(
            declaredUncompressedSize,
            in: &fixture.data,
            at: fixture.centralHeaderOffset + 24
        )
        let archiveURL = try writeTemporaryArchive(fixture.data)
        let destinationURL = try makeTemporaryDirectory(named: "zip-deflate-bound-output")
            .appendingPathComponent("bookmarks.sqlite3")
        let fileManager = RemovalObservingFileManager()
        let entry = try XCTUnwrap(ZipArchiveReader.fileEntries(inArchiveAt: archiveURL).first)

        XCTAssertEqual(entry.uncompressedSize, UInt64(declaredUncompressedSize))
        XCTAssertThrowsError(
            try ZipArchiveReader.extract(
                entry,
                fromArchiveAt: archiveURL,
                to: destinationURL,
                fileManager: fileManager
            )
        ) { error in
            XCTAssertEqual(error as? ZipArchiveReaderError, .decompressionFailed)
        }
        XCTAssertNotNil(fileManager.largestObservedRemovedFileSize)
        XCTAssertLessThanOrEqual(
            fileManager.largestObservedRemovedFileSize ?? UInt64.max,
            UInt64(declaredUncompressedSize)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    /** Creates and records an isolated temporary directory. */
    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    /** Writes and records one temporary ZIP archive. */
    private func writeTemporaryArchive(_ data: Data) throws -> URL {
        let directory = try makeTemporaryDirectory(named: "zip-integrity-archive")
        let url = directory.appendingPathComponent("fixture.zip")
        try data.write(to: url, options: .atomic)
        return url
    }
}

/** Async one-shot gate that avoids blocking a cooperative test task's executor thread. */
private actor ZipChecksumReleaseGate {
    /// Whether release happened before the waiter reached the actor.
    private var isReleased = false

    /// Suspended checksum task waiting for deterministic cancellation delivery.
    private var continuation: CheckedContinuation<Void, Never>?

    /** Suspends until `release()` is called, returning immediately after an early release. */
    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    /** Releases the current or next waiter exactly once. */
    func release() {
        guard !isReleased else { return }
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

/** Compression mode used by the structured classic-ZIP fixture builder. */
private enum ClassicZIPFixtureCompression {
    case stored
    case deflated
}

/** One-entry ZIP bytes plus exact local and central header offsets used for metadata tampering. */
private struct ClassicZIPFixture {
    var data: Data
    let localHeaderOffset: Int
    let centralHeaderOffset: Int
}

/**
 Builds a valid one-entry classic ZIP and records its authoritative central-header offset.

 - Parameters:
   - name: UTF-8 entry path written to local and central headers.
   - payload: Uncompressed payload bytes.
   - compression: Stored or raw-deflated ZIP encoding.
 - Returns: Complete archive bytes and exact local/central header mutation offsets.
 - Side effects: Deflated fixtures allocate and free a temporary C compression buffer.
 - Failure modes: Throws when compression fails or the fixture exceeds classic ZIP field limits.
 */
private func makeClassicZIPFixture(
    name: String,
    payload: Data,
    compression: ClassicZIPFixtureCompression
) throws -> ClassicZIPFixture {
    let nameData = Data(name.utf8)
    guard nameData.count <= Int(UInt16.max),
          payload.count <= Int(UInt32.max) else {
        throw ZipArchiveReaderError.invalidArchive("Test ZIP entry exceeds classic limits")
    }

    let compressedPayload: Data
    let compressionMethod: UInt16
    switch compression {
    case .stored:
        compressedPayload = payload
        compressionMethod = 0
    case .deflated:
        compressedPayload = try makeRawDeflateFixtureData(payload)
        compressionMethod = 8
    }
    guard compressedPayload.count <= Int(UInt32.max) else {
        throw ZipArchiveReaderError.invalidArchive("Test ZIP entry exceeds classic limits")
    }

    let checksum = zipFixtureCRC32(payload)
    var archive = Data()
    appendLittleEndianUInt32(0x0403_4b50, to: &archive)
    appendLittleEndianUInt16(20, to: &archive)
    appendLittleEndianUInt16(0, to: &archive)
    appendLittleEndianUInt16(compressionMethod, to: &archive)
    appendLittleEndianUInt16(0, to: &archive)
    appendLittleEndianUInt16(0, to: &archive)
    appendLittleEndianUInt32(checksum, to: &archive)
    appendLittleEndianUInt32(UInt32(compressedPayload.count), to: &archive)
    appendLittleEndianUInt32(UInt32(payload.count), to: &archive)
    appendLittleEndianUInt16(UInt16(nameData.count), to: &archive)
    appendLittleEndianUInt16(0, to: &archive)
    archive.append(nameData)
    archive.append(compressedPayload)

    let centralHeaderOffset = archive.count
    appendLittleEndianUInt32(0x0201_4b50, to: &archive)
    appendLittleEndianUInt16(20, to: &archive)
    appendLittleEndianUInt16(20, to: &archive)
    appendLittleEndianUInt16(0, to: &archive)
    appendLittleEndianUInt16(compressionMethod, to: &archive)
    appendLittleEndianUInt16(0, to: &archive)
    appendLittleEndianUInt16(0, to: &archive)
    appendLittleEndianUInt32(checksum, to: &archive)
    appendLittleEndianUInt32(UInt32(compressedPayload.count), to: &archive)
    appendLittleEndianUInt32(UInt32(payload.count), to: &archive)
    appendLittleEndianUInt16(UInt16(nameData.count), to: &archive)
    appendLittleEndianUInt16(0, to: &archive)
    appendLittleEndianUInt16(0, to: &archive)
    appendLittleEndianUInt16(0, to: &archive)
    appendLittleEndianUInt16(0, to: &archive)
    appendLittleEndianUInt32(0, to: &archive)
    appendLittleEndianUInt32(0, to: &archive)
    archive.append(nameData)

    let centralDirectorySize = archive.count - centralHeaderOffset
    appendLittleEndianUInt32(0x0605_4b50, to: &archive)
    appendLittleEndianUInt16(0, to: &archive)
    appendLittleEndianUInt16(0, to: &archive)
    appendLittleEndianUInt16(1, to: &archive)
    appendLittleEndianUInt16(1, to: &archive)
    appendLittleEndianUInt32(UInt32(centralDirectorySize), to: &archive)
    appendLittleEndianUInt32(UInt32(centralHeaderOffset), to: &archive)
    appendLittleEndianUInt16(0, to: &archive)

    return ClassicZIPFixture(
        data: archive,
        localHeaderOffset: 0,
        centralHeaderOffset: centralHeaderOffset
    )
}

/**
 Compresses payload bytes to the headerless raw-deflate representation used by ZIP method 8.

 - Parameter data: Uncompressed fixture payload.
 - Returns: Raw-deflate bytes with the gzip framing removed.
 - Side effects: Allocates and frees a C compression buffer.
 - Failure modes: Throws when the compressor fails or returns malformed framing.
 */
private func makeRawDeflateFixtureData(_ data: Data) throws -> Data {
    let gzipData = try data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else {
            throw ZipArchiveReaderError.invalidArchive("Test ZIP compression failed")
        }
        var outputLength: UInt = 0
        guard let output = gzip_data(
            baseAddress.assumingMemoryBound(to: UInt8.self),
            UInt(data.count),
            &outputLength
        ) else {
            throw ZipArchiveReaderError.invalidArchive("Test ZIP compression failed")
        }
        defer { gunzip_free(output) }
        return Data(bytes: output, count: Int(outputLength))
    }
    guard gzipData.count > 18 else {
        throw ZipArchiveReaderError.invalidArchive("Test ZIP compression returned malformed framing")
    }
    return Data(gzipData.dropFirst(10).dropLast(8))
}

/** Computes an independent ZIP CRC32 for fixture payloads. */
private func zipFixtureCRC32(_ data: Data) -> UInt32 {
    var checksum: UInt32 = 0xffff_ffff
    for byte in data {
        checksum ^= UInt32(byte)
        for _ in 0..<8 {
            checksum = checksum & 1 == 1
                ? (checksum >> 1) ^ 0xedb8_8320
                : checksum >> 1
        }
    }
    return checksum ^ 0xffff_ffff
}

/** Appends one little-endian 16-bit integer to fixture bytes. */
private func appendLittleEndianUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
}

/** Appends one little-endian 32-bit integer to fixture bytes. */
private func appendLittleEndianUInt32(_ value: UInt32, to data: inout Data) {
    for shift in stride(from: 0, through: 24, by: 8) {
        data.append(UInt8((value >> UInt32(shift)) & 0xff))
    }
}

/** Replaces one little-endian 32-bit central-directory field at an exact fixture offset. */
private func replaceLittleEndianUInt32(_ value: UInt32, in data: inout Data, at offset: Int) {
    var replacement = Data()
    appendLittleEndianUInt32(value, to: &replacement)
    data.replaceSubrange(offset..<(offset + 4), with: replacement)
}

/**
 Records destination sizes immediately before `ZipArchiveReader` removes failed extraction output.

 The production C inflater writes directly to the destination path, so observing cleanup is the
 deterministic test seam for proving an oversized stream never crossed its declared output bound.
 */
private final class RemovalObservingFileManager: FileManager, @unchecked Sendable {
    private(set) var largestObservedRemovedFileSize: UInt64?

    /** Records an existing file's size before delegating removal to `FileManager`. */
    override func removeItem(at URL: URL) throws {
        if fileExists(atPath: URL.path),
           let size = (try? attributesOfItem(atPath: URL.path)[.size] as? NSNumber)?.uint64Value {
            largestObservedRemovedFileSize = max(largestObservedRemovedFileSize ?? 0, size)
        }
        try super.removeItem(at: URL)
    }
}
