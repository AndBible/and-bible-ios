// ArchiveCRC32.swift - Shared ZIP payload integrity checks

import Foundation

/**
 Calculates the standard reflected CRC32 used by ZIP central-directory entries.

 SWORD package, backup, writer, and EPUB paths share this implementation so every archive validates
 or emits the same checksum contract. File-backed checks use bounded sequential reads and never
 materialize the complete payload.
 */
public enum ArchiveCRC32 {
    /// Bounded chunk size used for file-backed checksum calculation.
    private static let chunkByteCount = 64 * 1024

    /**
     Calculates the finalized ZIP CRC32 for in-memory bytes.

     - Parameter data: Complete uncompressed entry payload.
     - Returns: Standard finalized CRC32 value.
     - Side effects: none.
     - Failure modes: This operation cannot fail.
     */
    public static func checksum(of data: Data) -> UInt32 {
        finalize(update(0xffff_ffff, with: data))
    }

    /**
     Calculates the finalized ZIP CRC32 for one file without loading it into memory.

     - Parameter fileURL: Readable file containing the complete uncompressed entry payload.
     - Returns: Standard finalized CRC32 value.
     - Side effects: Opens and sequentially reads `fileURL`, then closes the handle.
     - Throws: Cancellation or file-open and read failures from `FileHandle`.
     */
    public static func checksum(fileAt fileURL: URL) throws -> UInt32 {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var accumulator: UInt32 = 0xffff_ffff
        while let chunk = try handle.read(upToCount: chunkByteCount), !chunk.isEmpty {
            try Task.checkCancellation()
            accumulator = update(accumulator, with: chunk)
        }
        try Task.checkCancellation()
        return finalize(accumulator)
    }

    /**
     Advances one unfinalized CRC accumulator with additional bytes.

     - Parameters:
       - accumulator: Current unfinalized CRC value.
       - data: Next contiguous payload bytes.
     - Returns: Updated unfinalized accumulator.
     - Side effects: none.
     - Failure modes: This operation cannot fail.
     */
    private static func update(_ accumulator: UInt32, with data: Data) -> UInt32 {
        var accumulator = accumulator
        for byte in data {
            let tableIndex = Int((accumulator ^ UInt32(byte)) & 0xff)
            accumulator = (accumulator >> 8) ^ table[tableIndex]
        }
        return accumulator
    }

    /// Finalizes an in-progress ZIP CRC32 accumulator.
    private static func finalize(_ accumulator: UInt32) -> UInt32 {
        accumulator ^ 0xffff_ffff
    }

    /// Lookup table for the reflected ZIP CRC32 polynomial `0xedb88320`.
    private static let table: [UInt32] = {
        (0..<256).map { value in
            var crc = UInt32(value)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? 0xedb8_8320 ^ (crc >> 1) : crc >> 1
            }
            return crc
        }
    }()
}
