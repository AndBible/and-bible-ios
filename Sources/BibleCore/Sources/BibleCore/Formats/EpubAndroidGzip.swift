// EpubAndroidGzip.swift -- bounded Android optimized-artifact decompression

import Foundation

/**
 Decodes one strict Android gzip member without allowing unbounded in-memory inflation.

 Android stores both its optimized Room database and each generated XHTML fragment as gzip. The
 decoder retains one no-follow source descriptor from strict framing inspection through bounded
 inflation, then verifies the declared size and CRC before exposing bytes.
 */
enum EpubAndroidGzipDecoder {
    /**
     Expands one strict gzip member into a caller-owned destination file.

     - Parameters:
       - sourceURL: Readable Android `.gz` artifact.
       - destinationURL: Unique output path that must not already exist.
       - maximumOutputBytes: Hard ceiling applied before every output write.
     - Side effects: Reads `sourceURL`, creates parent directories, writes `destinationURL`, and
       removes a partial destination on every validation or decompression failure.
     - Throws: File-system errors or `EpubError.decompressionFailed` for oversized, malformed,
       multi-member, trailing, checksum-mismatched, or size-mismatched gzip data.
     - Important: Existing files and symbolic links at `destinationURL` are never replaced.
     */
    static func inflate(
        sourceURL: URL,
        destinationURL: URL,
        maximumOutputBytes: UInt64
    ) throws {
        let fileManager = FileManager.default
        guard let maximumCompressedByteCount = Int(exactly: EpubReader.maximumArchiveEntryByteCount),
              let maximumExpandedByteCount = Int(exactly: maximumOutputBytes) else {
            throw EpubError.decompressionFailed
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            let member = try RemoteSyncBoundedFileIO.inspectGzip(
                at: sourceURL,
                maximumCompressedByteCount: maximumCompressedByteCount,
                maximumExpandedByteCount: maximumExpandedByteCount
            )
            try RemoteSyncBoundedFileIO.inflateGzip(
                member,
                from: sourceURL,
                to: destinationURL,
                maximumExpandedByteCount: maximumExpandedByteCount
            )
        } catch {
            throw EpubError.decompressionFailed
        }
    }

    /**
     Expands one strict gzip member and returns its bounded bytes.

     - Parameters:
       - sourceURL: Readable Android XHTML gzip artifact.
       - temporaryDirectoryURL: Existing or creatable caller-owned scratch directory.
       - maximumOutputBytes: Hard expansion ceiling.
     - Returns: Fully checksum-validated uncompressed bytes.
     - Side effects: Creates and removes one unique temporary file under `temporaryDirectoryURL`.
     - Throws: File-system errors or `EpubError.decompressionFailed` from `inflate`.
     */
    static func data(
        sourceURL: URL,
        temporaryDirectoryURL: URL,
        maximumOutputBytes: UInt64
    ) throws -> Data {
        let outputURL = temporaryDirectoryURL.appendingPathComponent(
            ".android-gzip-\(UUID().uuidString).decoded"
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try inflate(
            sourceURL: sourceURL,
            destinationURL: outputURL,
            maximumOutputBytes: maximumOutputBytes
        )
        do {
            guard let maximumByteCount = Int(exactly: maximumOutputBytes) else {
                throw EpubError.decompressionFailed
            }
            return try RemoteSyncBoundedFileIO.readRegularFile(
                at: outputURL,
                maximumByteCount: maximumByteCount
            )
        } catch {
            throw EpubError.decompressionFailed
        }
    }
}
