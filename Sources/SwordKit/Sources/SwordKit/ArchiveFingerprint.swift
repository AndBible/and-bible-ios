// ArchiveFingerprint.swift - Stable archive identity for preflight authorization

import CryptoKit
import Foundation

/**
 Computes stable SHA-256 identities for archive bytes and file-backed archives.

 Import confirmation retains this digest between read-only preflight and publication so replacing
 a provider-backed file cannot broaden the user's overwrite consent. File hashing streams bounded
 chunks and therefore does not buffer a large module archive in memory.
 */
public enum ArchiveFingerprint {
    /// Bounded read size used by file-backed hashing.
    private static let chunkByteCount = 1024 * 1024

    /**
     Computes a lowercase SHA-256 digest for immutable archive bytes.

     - Parameter data: Complete archive bytes.
     - Returns: Sixty-four-character lowercase hexadecimal SHA-256.
     - Side effects: none.
     - Failure modes: This operation cannot fail.
     */
    public static func sha256Hex(of data: Data) -> String {
        hexadecimal(SHA256.hash(data: data))
    }

    /**
     Computes a lowercase SHA-256 digest without loading the complete archive into memory.

     - Parameter url: Readable local file URL whose exact bytes identify the confirmed archive.
     - Returns: Sixty-four-character lowercase hexadecimal SHA-256.
     - Side effects: Opens and sequentially reads the file, then closes the handle.
     - Throws: File-open and read failures from `FileHandle`.
     - Note: The caller must hash again after extraction when the URL can be mutated concurrently.
     */
    public static func sha256Hex(at url: URL) throws -> String {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkByteCount), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        try Task.checkCancellation()
        return hexadecimal(hasher.finalize())
    }

    /** Converts a CryptoKit digest into canonical lowercase hexadecimal. */
    private static func hexadecimal<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
