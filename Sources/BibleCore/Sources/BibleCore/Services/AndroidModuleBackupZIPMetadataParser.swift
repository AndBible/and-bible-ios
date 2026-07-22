import Foundation

/**
 Metadata for one ZIP member after its central and local records agree.

 `rawPathBytes` is retained because Swift `String` equality treats canonically equivalent Unicode
 spellings as equal. ZIP identity is byte based, so callers that bind this metadata to another ZIP
 reader must compare the bytes as well as the decoded path.
 */
struct AndroidModuleBackupZIPMetadataEntry: Sendable, Equatable {
    /// Zero-based position in local-header order.
    let archivePosition: Int

    /// Zero-based position in central-directory order.
    let centralDirectoryPosition: Int

    /// UTF-8 decoded member name.
    let rawPath: String

    /// Exact central-directory member-name bytes.
    let rawPathBytes: Data

    /// ZIP method, limited to stored (`0`) or deflated (`8`).
    let compressionMethod: UInt16

    /// Compressed payload byte count resolved through ZIP64 when required.
    let compressedByteCount: UInt64

    /// Expanded payload byte count resolved through ZIP64 when required.
    let expandedByteCount: UInt64

    /// CRC32 declared by the central directory.
    let crc32: UInt32

    /// Absolute local-header offset.
    let localHeaderOffset: UInt64

    /// Absolute compressed-payload offset.
    let payloadOffset: UInt64

    /// Whether the path is an explicit ZIP directory entry.
    let isDirectory: Bool

    /// Whether Unix mode metadata identifies a symbolic link.
    let isSymbolicLink: Bool
}

/**
 Complete bounded metadata result for one ZIP archive.
 */
struct AndroidModuleBackupZIPMetadata: Sendable, Equatable {
    /// Entries sorted by local-header offset and assigned local archive positions.
    let entries: [AndroidModuleBackupZIPMetadataEntry]

    /// Checked sum of compressed member sizes.
    let aggregateCompressedByteCount: UInt64

    /// Checked sum of expanded member sizes.
    let aggregateExpandedByteCount: UInt64
}

/**
 Parses the ZIP metadata needed by Android module-backup planning.

 Both entry names are compared as exact bytes, local ZIP64 size sentinels are resolved even when
 the central record fits classic fields, and every offset calculation uses subtraction-based range
 checks. The URL API reads only the legal ZIP trailer window and individual metadata records.
 */
enum AndroidModuleBackupZIPMetadataParser {
    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let endRecordSignature: UInt32 = 0x0605_4b50
    private static let zip64EndRecordSignature: UInt32 = 0x0606_4b50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    private static let zip64ExtraFieldIdentifier: UInt16 = 0x0001
    private static let zip64UInt16Sentinel: UInt16 = 0xffff
    private static let zip64UInt32Sentinel: UInt32 = 0xffff_ffff
    private static let dataDescriptorFlag: UInt16 = 0x0008
    private static let encryptedFlag: UInt16 = 0x0001
    private static let storedMethod: UInt16 = 0
    private static let deflatedMethod: UInt16 = 8
    private static let localHeaderByteCount: UInt64 = 30
    private static let centralHeaderByteCount: UInt64 = 46
    private static let endRecordByteCount = 22
    private static let maximumCommentByteCount = 0xffff
    private static let zip64LocatorByteCount: UInt64 = 20
    private static let zip64EndRecordMinimumByteCount = 56
    private static let dataDescriptorSignature: UInt32 = 0x0807_4b50

    /**
     Random-access source used by both in-memory and file-backed parsing.

     - Side effects: `readBytes` may seek and read an open file handle.
     */
    private struct ArchiveSource {
        let byteCount: UInt64
        let readBytes: (UInt64, Int) throws -> Data
    }

    /**
     Resolved central-directory range and entry count.
     */
    private struct CentralDirectory {
        let offset: UInt64
        let byteCount: UInt64
        let entryCount: Int
        let trailerOffset: UInt64
    }

    /**
     Mutable parse record before local archive positions are assigned.
     */
    private struct ParsedEntry {
        let centralDirectoryPosition: Int
        let rawPath: String
        let rawPathBytes: Data
        let compressionMethod: UInt16
        let compressedByteCount: UInt64
        let expandedByteCount: UInt64
        let crc32: UInt32
        let localHeaderOffset: UInt64
        let payloadOffset: UInt64
        let payloadEndOffset: UInt64
        let usesDataDescriptor: Bool
        let usesZip64DataDescriptor: Bool
        let isDirectory: Bool
        let isSymbolicLink: Bool
    }

    /**
     ZIP64 values resolved from a central-directory extra field.
     */
    private struct ResolvedCentralEntry {
        let compressedByteCount: UInt64
        let expandedByteCount: UInt64
        let localHeaderOffset: UInt64
        let usesZip64Sizes: Bool
    }

    /**
     Parses metadata from complete in-memory ZIP bytes.

     - Parameters:
       - data: Complete ZIP archive.
       - limits: Planner resource ceilings.
     - Returns: Validated entries and aggregate sizes.
     - Side effects: none.
     - Throws: `AndroidModuleBackupArchivePlannerError` for malformed or over-limit metadata.
     */
    static func parse(
        _ data: Data,
        limits: AndroidModuleBackupArchiveLimits
    ) throws -> AndroidModuleBackupZIPMetadata {
        let source = ArchiveSource(byteCount: UInt64(data.count)) { offset, count in
            try Task.checkCancellation()
            try checkedRange(offset: offset, byteCount: UInt64(count), upperBound: UInt64(data.count))
            guard offset <= UInt64(Int.max), UInt64(count) <= UInt64(Int.max) - offset else {
                throw invalidArchive("ZIP metadata exceeds platform limits")
            }
            let start = Int(offset)
            return Data(data[start..<(start + count)])
        }
        return try parse(source, limits: limits)
    }

    /**
     Parses metadata directly from a local ZIP file without mapping payload bytes.

     - Parameters:
       - url: Readable local archive URL.
       - limits: Planner resource ceilings.
     - Returns: Validated entries and aggregate sizes.
     - Side effects: Opens, seeks, reads, and closes `url`.
     - Throws: File-system errors or typed malformed/resource-limit errors.
     */
    static func parse(
        at url: URL,
        limits: AndroidModuleBackupArchiveLimits
    ) throws -> AndroidModuleBackupZIPMetadata {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let byteCount = try handle.seekToEnd()
        let source = ArchiveSource(byteCount: byteCount) { offset, count in
            try Task.checkCancellation()
            try checkedRange(offset: offset, byteCount: UInt64(count), upperBound: byteCount)
            try handle.seek(toOffset: offset)
            let bytes = try handle.read(upToCount: count) ?? Data()
            guard bytes.count == count else {
                throw invalidArchive("ZIP metadata is truncated")
            }
            return bytes
        }
        return try parse(source, limits: limits)
    }

    /**
     Parses and cross-checks central and local records from one random-access source.

     - Parameters:
       - source: Exact bounded archive reader.
       - limits: Planner resource ceilings.
     - Returns: Validated metadata in local order.
     - Side effects: Reads bounded metadata ranges from `source`.
     - Throws: Typed malformed and resource-limit errors.
     */
    private static func parse(
        _ source: ArchiveSource,
        limits: AndroidModuleBackupArchiveLimits
    ) throws -> AndroidModuleBackupZIPMetadata {
        try Task.checkCancellation()
        try enforceLimit(
            .archiveBytes,
            actual: source.byteCount,
            maximum: limits.maximumArchiveByteCount
        )
        let directory = try centralDirectory(in: source)
        try enforceLimit(
            .entryCount,
            actual: UInt64(directory.entryCount),
            maximum: UInt64(max(0, limits.maximumEntryCount))
        )

        var parsed: [ParsedEntry] = []
        parsed.reserveCapacity(directory.entryCount)
        var offset = directory.offset
        let directoryEnd = try checkedSum(directory.offset, directory.byteCount)
        var aggregateCompressed: UInt64 = 0
        var aggregateExpanded: UInt64 = 0

        for position in 0..<directory.entryCount {
            try Task.checkCancellation()
            try checkedRange(
                offset: offset,
                byteCount: centralHeaderByteCount,
                upperBound: directoryEnd
            )
            let header = try source.readBytes(offset, Int(centralHeaderByteCount))
            guard readUInt32(header, at: 0) == centralHeaderSignature else {
                throw invalidArchive("Central-directory entry has an invalid signature")
            }

            let versionMadeBy = readUInt16(header, at: 4)
            let flags = readUInt16(header, at: 8)
            let method = readUInt16(header, at: 10)
            let crc32 = readUInt32(header, at: 16)
            let compressedRaw = readUInt32(header, at: 20)
            let expandedRaw = readUInt32(header, at: 24)
            let nameLength = UInt64(readUInt16(header, at: 28))
            let extraLength = UInt64(readUInt16(header, at: 30))
            let commentLength = UInt64(readUInt16(header, at: 32))
            let diskStartRaw = readUInt16(header, at: 34)
            let externalAttributes = readUInt32(header, at: 38)
            let localOffsetRaw = readUInt32(header, at: 42)

            guard flags & encryptedFlag == 0 else {
                throw invalidArchive("Encrypted ZIP entries are not supported")
            }
            guard method == storedMethod || method == deflatedMethod else {
                throw invalidArchive("Unsupported ZIP compression method \(method)")
            }

            let nameOffset = try checkedSum(offset, centralHeaderByteCount)
            let extraOffset = try checkedSum(nameOffset, nameLength)
            let commentOffset = try checkedSum(extraOffset, extraLength)
            let nextOffset = try checkedSum(commentOffset, commentLength)
            guard nextOffset <= directoryEnd else {
                throw invalidArchive("Central-directory entry metadata is truncated")
            }
            let rawPathBytes = try source.readBytes(nameOffset, Int(nameLength))
            guard !rawPathBytes.isEmpty,
                  let rawPath = String(data: rawPathBytes, encoding: .utf8) else {
                throw invalidArchive("ZIP entry name is empty or not UTF-8")
            }
            let extraData = try source.readBytes(extraOffset, Int(extraLength))
            let resolved = try resolveCentralEntry(
                compressedRaw: compressedRaw,
                expandedRaw: expandedRaw,
                localOffsetRaw: localOffsetRaw,
                diskStartRaw: diskStartRaw,
                extraData: extraData
            )
            let isDirectory = rawPathBytes.last == 0x2f
            if isDirectory,
               (resolved.compressedByteCount != 0 || resolved.expandedByteCount != 0) {
                throw invalidArchive("ZIP directory entry has a payload")
            }
            if method == storedMethod,
               resolved.compressedByteCount != resolved.expandedByteCount {
                throw invalidArchive("Stored ZIP entry size metadata is inconsistent")
            }

            try enforceEntryLimits(
                compressed: resolved.compressedByteCount,
                expanded: resolved.expandedByteCount,
                limits: limits
            )
            aggregateCompressed = try checkedAggregate(
                aggregateCompressed,
                adding: resolved.compressedByteCount,
                resource: .aggregateCompressedBytes,
                maximum: limits.maximumAggregateCompressedByteCount
            )
            aggregateExpanded = try checkedAggregate(
                aggregateExpanded,
                adding: resolved.expandedByteCount,
                resource: .aggregateExpandedBytes,
                maximum: limits.maximumAggregateExpandedByteCount
            )

            let local = try validateLocalHeader(
                source: source,
                directoryOffset: directory.offset,
                rawPathBytes: rawPathBytes,
                flags: flags,
                method: method,
                crc32: crc32,
                compressedByteCount: resolved.compressedByteCount,
                expandedByteCount: resolved.expandedByteCount,
                localHeaderOffset: resolved.localHeaderOffset
            )
            parsed.append(ParsedEntry(
                centralDirectoryPosition: position,
                rawPath: rawPath,
                rawPathBytes: rawPathBytes,
                compressionMethod: method,
                compressedByteCount: resolved.compressedByteCount,
                expandedByteCount: resolved.expandedByteCount,
                crc32: crc32,
                localHeaderOffset: resolved.localHeaderOffset,
                payloadOffset: local.payloadOffset,
                payloadEndOffset: local.payloadEndOffset,
                usesDataDescriptor: flags & dataDescriptorFlag != 0,
                usesZip64DataDescriptor: resolved.usesZip64Sizes
                    || local.usesZip64Sizes,
                isDirectory: isDirectory,
                isSymbolicLink: isUnixSymbolicLink(
                    versionMadeBy: versionMadeBy,
                    externalAttributes: externalAttributes
                )
            ))
            offset = nextOffset
        }

        guard offset == directoryEnd else {
            throw invalidArchive("Central directory contains trailing bytes")
        }

        let inLocalOrder = parsed.sorted {
            if $0.localHeaderOffset == $1.localHeaderOffset {
                return $0.centralDirectoryPosition < $1.centralDirectoryPosition
            }
            return $0.localHeaderOffset < $1.localHeaderOffset
        }
        for index in inLocalOrder.indices {
            try Task.checkCancellation()
            let entry = inLocalOrder[index]
            let boundary = index + 1 < inLocalOrder.count
                ? inLocalOrder[index + 1].localHeaderOffset
                : directory.offset
            guard entry.localHeaderOffset < boundary,
                  entry.payloadEndOffset <= boundary else {
                throw invalidArchive("ZIP local entries overlap or share a header")
            }
            if entry.usesDataDescriptor {
                try validateDataDescriptor(
                    source: source,
                    offset: entry.payloadEndOffset,
                    boundary: boundary,
                    usesZip64: entry.usesZip64DataDescriptor,
                    crc32: entry.crc32,
                    compressedByteCount: entry.compressedByteCount,
                    expandedByteCount: entry.expandedByteCount
                )
            } else if entry.payloadEndOffset != boundary {
                throw invalidArchive("ZIP local entry contains trailing bytes")
            }
        }

        let entries = inLocalOrder.enumerated().map { position, entry in
            AndroidModuleBackupZIPMetadataEntry(
                archivePosition: position,
                centralDirectoryPosition: entry.centralDirectoryPosition,
                rawPath: entry.rawPath,
                rawPathBytes: entry.rawPathBytes,
                compressionMethod: entry.compressionMethod,
                compressedByteCount: entry.compressedByteCount,
                expandedByteCount: entry.expandedByteCount,
                crc32: entry.crc32,
                localHeaderOffset: entry.localHeaderOffset,
                payloadOffset: entry.payloadOffset,
                isDirectory: entry.isDirectory,
                isSymbolicLink: entry.isSymbolicLink
            )
        }
        return AndroidModuleBackupZIPMetadata(
            entries: entries,
            aggregateCompressedByteCount: aggregateCompressed,
            aggregateExpandedByteCount: aggregateExpanded
        )
    }

    /**
     Finds and resolves the classic or ZIP64 central-directory trailer.

     - Parameter source: Exact bounded archive reader.
     - Returns: Validated central-directory range.
     - Side effects: Reads only the legal EOCD search window and fixed ZIP64 records.
     - Throws: `invalidArchive` for missing, spanned, inconsistent, or overflowing metadata.
     */
    private static func centralDirectory(in source: ArchiveSource) throws -> CentralDirectory {
        guard source.byteCount >= UInt64(endRecordByteCount) else {
            throw invalidArchive("ZIP end-of-central-directory record is missing")
        }
        let tailLength = min(
            source.byteCount,
            UInt64(endRecordByteCount + maximumCommentByteCount)
        )
        let tailOffset = source.byteCount - tailLength
        let tail = try source.readBytes(tailOffset, Int(tailLength))
        var candidate = tail.count - endRecordByteCount
        var endOffsetInTail: Int?
        while candidate >= 0 {
            if candidate & 0x0fff == 0 {
                try Task.checkCancellation()
            }
            if readUInt32(tail, at: candidate) == endRecordSignature {
                let commentLength = Int(readUInt16(tail, at: candidate + 20))
                if candidate <= tail.count - endRecordByteCount,
                   commentLength == tail.count - candidate - endRecordByteCount {
                    endOffsetInTail = candidate
                    break
                }
            }
            if candidate == 0 { break }
            candidate -= 1
        }
        guard let endOffsetInTail else {
            throw invalidArchive("ZIP end-of-central-directory record is missing")
        }
        let endRecordOffset = try checkedSum(tailOffset, UInt64(endOffsetInTail))
        let endRecord = Data(tail[endOffsetInTail..<(endOffsetInTail + endRecordByteCount)])
        let diskRaw = readUInt16(endRecord, at: 4)
        let directoryDiskRaw = readUInt16(endRecord, at: 6)
        let diskCountRaw = readUInt16(endRecord, at: 8)
        let countRaw = readUInt16(endRecord, at: 10)
        let sizeRaw = readUInt32(endRecord, at: 12)
        let offsetRaw = readUInt32(endRecord, at: 16)
        let requiresZip64 = diskRaw == zip64UInt16Sentinel
            || directoryDiskRaw == zip64UInt16Sentinel
            || diskCountRaw == zip64UInt16Sentinel
            || countRaw == zip64UInt16Sentinel
            || sizeRaw == zip64UInt32Sentinel
            || offsetRaw == zip64UInt32Sentinel

        if requiresZip64 {
            return try zip64CentralDirectory(
                source: source,
                endRecordOffset: endRecordOffset,
                diskRaw: diskRaw,
                directoryDiskRaw: directoryDiskRaw,
                diskCountRaw: diskCountRaw,
                countRaw: countRaw,
                sizeRaw: sizeRaw,
                offsetRaw: offsetRaw
            )
        }

        guard diskRaw == 0, directoryDiskRaw == 0, diskCountRaw == countRaw else {
            throw invalidArchive("Multi-disk ZIP archives are not supported")
        }
        return try validatedCentralDirectory(
            offset: UInt64(offsetRaw),
            byteCount: UInt64(sizeRaw),
            entryCount: UInt64(countRaw),
            trailerOffset: endRecordOffset,
            archiveByteCount: source.byteCount
        )
    }

    /**
     Resolves one ZIP64 EOCD using checked subtraction instead of attacker-controlled addition.

     - Returns: Validated ZIP64 central-directory metadata.
     - Side effects: Reads the fixed locator and fixed record prefix.
     - Throws: `invalidArchive` for malformed sizes, versions, disks, or classic-field conflicts.
     */
    private static func zip64CentralDirectory(
        source: ArchiveSource,
        endRecordOffset: UInt64,
        diskRaw: UInt16,
        directoryDiskRaw: UInt16,
        diskCountRaw: UInt16,
        countRaw: UInt16,
        sizeRaw: UInt32,
        offsetRaw: UInt32
    ) throws -> CentralDirectory {
        guard endRecordOffset >= zip64LocatorByteCount else {
            throw invalidArchive("ZIP64 end-of-central-directory locator is missing")
        }
        let locatorOffset = endRecordOffset - zip64LocatorByteCount
        let locator = try source.readBytes(locatorOffset, Int(zip64LocatorByteCount))
        guard readUInt32(locator, at: 0) == zip64LocatorSignature,
              readUInt32(locator, at: 4) == 0,
              readUInt32(locator, at: 16) == 1 else {
            throw invalidArchive("ZIP64 locator is missing or describes multiple disks")
        }
        let recordOffset = readUInt64(locator, at: 8)
        guard recordOffset <= locatorOffset else {
            throw invalidArchive("ZIP64 end record points outside archive")
        }
        let completeRecordByteCount = locatorOffset - recordOffset
        guard completeRecordByteCount >= UInt64(zip64EndRecordMinimumByteCount) else {
            throw invalidArchive("ZIP64 end-of-central-directory record is truncated")
        }
        let record = try source.readBytes(recordOffset, zip64EndRecordMinimumByteCount)
        guard readUInt32(record, at: 0) == zip64EndRecordSignature else {
            throw invalidArchive("ZIP64 end-of-central-directory record is missing")
        }
        let bodyByteCount = readUInt64(record, at: 4)
        guard bodyByteCount >= 44,
              completeRecordByteCount >= 12,
              bodyByteCount == completeRecordByteCount - 12 else {
            throw invalidArchive("ZIP64 end-of-central-directory record has an invalid size")
        }
        guard readUInt16(record, at: 14) >= 45 else {
            throw invalidArchive("ZIP64 end-of-central-directory version is invalid")
        }

        let disk = readUInt32(record, at: 16)
        let directoryDisk = readUInt32(record, at: 20)
        let diskCount = readUInt64(record, at: 24)
        let count = readUInt64(record, at: 32)
        let size = readUInt64(record, at: 40)
        let offset = readUInt64(record, at: 48)
        guard disk == 0, directoryDisk == 0, diskCount == count else {
            throw invalidArchive("Multi-disk ZIP archives are not supported")
        }
        guard (diskRaw == zip64UInt16Sentinel || UInt32(diskRaw) == disk),
              (directoryDiskRaw == zip64UInt16Sentinel
                || UInt32(directoryDiskRaw) == directoryDisk),
              (diskCountRaw == zip64UInt16Sentinel || UInt64(diskCountRaw) == diskCount),
              (countRaw == zip64UInt16Sentinel || UInt64(countRaw) == count),
              (sizeRaw == zip64UInt32Sentinel || UInt64(sizeRaw) == size),
              (offsetRaw == zip64UInt32Sentinel || UInt64(offsetRaw) == offset) else {
            throw invalidArchive("ZIP64 metadata conflicts with the classic end record")
        }
        return try validatedCentralDirectory(
            offset: offset,
            byteCount: size,
            entryCount: count,
            trailerOffset: recordOffset,
            archiveByteCount: source.byteCount
        )
    }

    /**
     Bounds a resolved central directory before allocation or iteration.

     - Returns: Integer-sized directory metadata.
     - Side effects: none.
     - Throws: `invalidArchive` for overflow, impossible counts, or out-of-archive ranges.
     */
    private static func validatedCentralDirectory(
        offset: UInt64,
        byteCount: UInt64,
        entryCount: UInt64,
        trailerOffset: UInt64,
        archiveByteCount: UInt64
    ) throws -> CentralDirectory {
        try checkedRange(offset: offset, byteCount: byteCount, upperBound: archiveByteCount)
        guard offset <= trailerOffset, byteCount <= trailerOffset - offset else {
            throw invalidArchive("Central directory points outside the ZIP trailer")
        }
        guard entryCount <= UInt64(Int.max) else {
            throw invalidArchive("ZIP entry count exceeds platform limits")
        }
        guard entryCount == 0
                ? byteCount == 0
                : entryCount <= byteCount / centralHeaderByteCount else {
            throw invalidArchive("Central-directory entry count is inconsistent")
        }
        return CentralDirectory(
            offset: offset,
            byteCount: byteCount,
            entryCount: Int(entryCount),
            trailerOffset: trailerOffset
        )
    }

    /**
     Resolves central size, offset, and disk fields from ZIP64 extra metadata when required.

     - Returns: Concrete 64-bit size and local-offset values.
     - Side effects: none.
     - Throws: `invalidArchive` for malformed, duplicate, missing, or spanned ZIP64 metadata.
     */
    private static func resolveCentralEntry(
        compressedRaw: UInt32,
        expandedRaw: UInt32,
        localOffsetRaw: UInt32,
        diskStartRaw: UInt16,
        extraData: Data
    ) throws -> ResolvedCentralEntry {
        let zip64Payload = try uniqueExtraField(
            identifier: zip64ExtraFieldIdentifier,
            in: extraData
        )
        let needsZip64 = compressedRaw == zip64UInt32Sentinel
            || expandedRaw == zip64UInt32Sentinel
            || localOffsetRaw == zip64UInt32Sentinel
            || diskStartRaw == zip64UInt16Sentinel
        guard !needsZip64 || zip64Payload != nil else {
            throw invalidArchive("ZIP64 central extended-information field is missing")
        }
        let payload = zip64Payload ?? Data()
        var payloadOffset = 0

        let expanded = try expandedRaw == zip64UInt32Sentinel
            ? consumeUInt64(from: payload, offset: &payloadOffset, field: "expanded size")
            : UInt64(expandedRaw)
        let compressed = try compressedRaw == zip64UInt32Sentinel
            ? consumeUInt64(from: payload, offset: &payloadOffset, field: "compressed size")
            : UInt64(compressedRaw)
        let localOffset = try localOffsetRaw == zip64UInt32Sentinel
            ? consumeUInt64(from: payload, offset: &payloadOffset, field: "local-header offset")
            : UInt64(localOffsetRaw)
        let diskStart = try diskStartRaw == zip64UInt16Sentinel
            ? consumeUInt32(from: payload, offset: &payloadOffset, field: "disk-start number")
            : UInt32(diskStartRaw)
        guard diskStart == 0 else {
            throw invalidArchive("Multi-disk ZIP archives are not supported")
        }
        return ResolvedCentralEntry(
            compressedByteCount: compressed,
            expandedByteCount: expanded,
            localHeaderOffset: localOffset,
            usesZip64Sizes: compressedRaw == zip64UInt32Sentinel
                || expandedRaw == zip64UInt32Sentinel
        )
    }

    /**
     Cross-checks a central record against its referenced local header.

     ZIP permits data-descriptor local fields to be zero and permits producers to force ZIP64 local
     size fields even when the central values fit in 32 bits. Sentinel local values are therefore
     resolved independently before comparison.

     - Returns: Checked compressed-payload start and end offsets.
     - Side effects: Reads one local header, name, and extra-field sequence.
     - Throws: `invalidArchive` for mismatched bytes, fields, ZIP64 values, or payload ranges.
     */
    private static func validateLocalHeader(
        source: ArchiveSource,
        directoryOffset: UInt64,
        rawPathBytes: Data,
        flags: UInt16,
        method: UInt16,
        crc32: UInt32,
        compressedByteCount: UInt64,
        expandedByteCount: UInt64,
        localHeaderOffset: UInt64
    ) throws -> (
        payloadOffset: UInt64,
        payloadEndOffset: UInt64,
        usesZip64Sizes: Bool
    ) {
        try checkedRange(
            offset: localHeaderOffset,
            byteCount: localHeaderByteCount,
            upperBound: directoryOffset
        )
        let header = try source.readBytes(localHeaderOffset, Int(localHeaderByteCount))
        guard readUInt32(header, at: 0) == localHeaderSignature else {
            throw invalidArchive("Local file header is missing or truncated")
        }
        let localFlags = readUInt16(header, at: 6)
        let localMethod = readUInt16(header, at: 8)
        let localCRC32 = readUInt32(header, at: 14)
        let localCompressedRaw = readUInt32(header, at: 18)
        let localExpandedRaw = readUInt32(header, at: 22)
        let localNameLength = UInt64(readUInt16(header, at: 26))
        let localExtraLength = UInt64(readUInt16(header, at: 28))
        guard localFlags == flags, localMethod == method else {
            throw invalidArchive("ZIP local and central entry flags or method differ")
        }

        let nameOffset = try checkedSum(localHeaderOffset, localHeaderByteCount)
        let extraOffset = try checkedSum(nameOffset, localNameLength)
        let payloadOffset = try checkedSum(extraOffset, localExtraLength)
        guard payloadOffset <= directoryOffset else {
            throw invalidArchive("Local file metadata points into the central directory")
        }
        let localNameBytes = try source.readBytes(nameOffset, Int(localNameLength))
        guard localNameBytes == rawPathBytes else {
            throw invalidArchive("ZIP local and central entry-name bytes differ")
        }
        let localExtra = try source.readBytes(extraOffset, Int(localExtraLength))
        let localZip64Payload = try uniqueExtraField(
            identifier: zip64ExtraFieldIdentifier,
            in: localExtra
        )
        var zip64Offset = 0
        let localExpanded: UInt64?
        if localExpandedRaw == zip64UInt32Sentinel {
            guard let localZip64Payload else {
                throw invalidArchive("ZIP64 local expanded size is missing")
            }
            localExpanded = try consumeUInt64(
                from: localZip64Payload,
                offset: &zip64Offset,
                field: "local expanded size"
            )
        } else {
            localExpanded = UInt64(localExpandedRaw)
        }
        let localCompressed: UInt64?
        if localCompressedRaw == zip64UInt32Sentinel {
            guard let localZip64Payload else {
                throw invalidArchive("ZIP64 local compressed size is missing")
            }
            localCompressed = try consumeUInt64(
                from: localZip64Payload,
                offset: &zip64Offset,
                field: "local compressed size"
            )
        } else {
            localCompressed = UInt64(localCompressedRaw)
        }

        let usesDescriptor = flags & dataDescriptorFlag != 0
        guard localValue(
            localExpanded,
            rawValue: localExpandedRaw,
            agreesWith: expandedByteCount,
            mayBeDeferred: usesDescriptor
        ), localValue(
            localCompressed,
            rawValue: localCompressedRaw,
            agreesWith: compressedByteCount,
            mayBeDeferred: usesDescriptor
        ) else {
            throw invalidArchive("ZIP local and central entry sizes differ")
        }
        if usesDescriptor {
            guard localCRC32 == 0 || localCRC32 == crc32 else {
                throw invalidArchive("ZIP local and central checksums differ")
            }
        } else {
            guard localCRC32 == crc32 else {
                throw invalidArchive("ZIP local and central checksums differ")
            }
        }

        try checkedRange(
            offset: payloadOffset,
            byteCount: compressedByteCount,
            upperBound: directoryOffset
        )
        return (
            payloadOffset: payloadOffset,
            payloadEndOffset: try checkedSum(payloadOffset, compressedByteCount),
            usesZip64Sizes: localCompressedRaw == zip64UInt32Sentinel
                || localExpandedRaw == zip64UInt32Sentinel
        )
    }

    /**
     Applies ZIP data-descriptor rules to one local size field.

     - Returns: `true` when the local value either matches or is a permitted deferred zero.
     - Side effects: none.
     - Failure modes: This comparison cannot throw.
     */
    private static func localValue(
        _ resolvedValue: UInt64?,
        rawValue: UInt32,
        agreesWith expectedValue: UInt64,
        mayBeDeferred: Bool
    ) -> Bool {
        if mayBeDeferred, rawValue == 0 || resolvedValue == 0 {
            return true
        }
        return resolvedValue == expectedValue
    }

    /**
     Parses one complete post-payload data descriptor and rejects every unaccounted byte.

     ZIP permits an optional signature and selects 32-bit or 64-bit size fields from the entry's
     ZIP64 size encoding. The boundary supplied by local-header ordering removes the CRC/signature
     ambiguity: only the exact legal length for that form is accepted.

     - Parameters:
       - source: Exact random-access archive source.
       - offset: First byte immediately after the compressed payload.
       - boundary: Next local header or the first central-directory byte.
       - usesZip64: Whether descriptor sizes must use ZIP64 width.
       - crc32: Central-directory checksum.
       - compressedByteCount: Central-directory compressed size.
       - expandedByteCount: Central-directory expanded size.
     - Side effects: Reads exactly one descriptor from `source`.
     - Throws: `invalidArchive` for missing, extra, malformed, or inconsistent descriptor bytes.
     */
    private static func validateDataDescriptor(
        source: ArchiveSource,
        offset: UInt64,
        boundary: UInt64,
        usesZip64: Bool,
        crc32: UInt32,
        compressedByteCount: UInt64,
        expandedByteCount: UInt64
    ) throws {
        guard offset <= boundary else {
            throw invalidArchive("ZIP data descriptor overlaps the next entry")
        }
        let unsignedByteCount: UInt64 = usesZip64 ? 20 : 12
        let signedByteCount = unsignedByteCount + 4
        let descriptorByteCount = boundary - offset
        let isSigned: Bool
        if descriptorByteCount == signedByteCount {
            isSigned = true
        } else if descriptorByteCount == unsignedByteCount {
            isSigned = false
        } else {
            throw invalidArchive("ZIP data descriptor has an invalid boundary")
        }
        guard descriptorByteCount <= UInt64(Int.max) else {
            throw invalidArchive("ZIP data descriptor exceeds platform limits")
        }
        let descriptor = try source.readBytes(offset, Int(descriptorByteCount))
        let valueOffset = isSigned ? 4 : 0
        if isSigned, readUInt32(descriptor, at: 0) != dataDescriptorSignature {
            throw invalidArchive("ZIP data descriptor signature is invalid")
        }
        guard readUInt32(descriptor, at: valueOffset) == crc32 else {
            throw invalidArchive("ZIP data descriptor checksum differs from central metadata")
        }
        let descriptorCompressed: UInt64
        let descriptorExpanded: UInt64
        if usesZip64 {
            descriptorCompressed = readUInt64(descriptor, at: valueOffset + 4)
            descriptorExpanded = readUInt64(descriptor, at: valueOffset + 12)
        } else {
            descriptorCompressed = UInt64(readUInt32(descriptor, at: valueOffset + 4))
            descriptorExpanded = UInt64(readUInt32(descriptor, at: valueOffset + 8))
        }
        guard descriptorCompressed == compressedByteCount,
              descriptorExpanded == expandedByteCount else {
            throw invalidArchive("ZIP data descriptor sizes differ from central metadata")
        }
    }

    /**
     Finds at most one extra field with a requested identifier while validating every TLV.

     - Returns: A copied payload, or `nil` when the field is absent.
     - Side effects: none.
     - Throws: `invalidArchive` for truncated or duplicate fields.
     */
    private static func uniqueExtraField(
        identifier: UInt16,
        in data: Data
    ) throws -> Data? {
        var result: Data?
        var offset = 0
        while offset < data.count {
            guard data.count - offset >= 4 else {
                throw invalidArchive("ZIP extra-field header is truncated")
            }
            let fieldIdentifier = readUInt16(data, at: offset)
            let payloadByteCount = Int(readUInt16(data, at: offset + 2))
            let payloadOffset = offset + 4
            guard payloadByteCount <= data.count - payloadOffset else {
                throw invalidArchive("ZIP extra-field payload is truncated")
            }
            let payloadEnd = payloadOffset + payloadByteCount
            if fieldIdentifier == identifier {
                guard result == nil else {
                    throw invalidArchive("ZIP extra field is duplicated")
                }
                result = Data(data[payloadOffset..<payloadEnd])
            }
            offset = payloadEnd
        }
        return result
    }

    /**
     Consumes one little-endian 64-bit ZIP64 field.

     - Returns: Decoded integer.
     - Side effects: Advances `offset` by eight on success.
     - Throws: `invalidArchive` when the field is truncated.
     */
    private static func consumeUInt64(
        from data: Data,
        offset: inout Int,
        field: String
    ) throws -> UInt64 {
        guard offset <= data.count, data.count - offset >= 8 else {
            throw invalidArchive("ZIP64 \(field) is truncated")
        }
        defer { offset += 8 }
        return readUInt64(data, at: offset)
    }

    /**
     Consumes one little-endian 32-bit ZIP64 field.

     - Returns: Decoded integer.
     - Side effects: Advances `offset` by four on success.
     - Throws: `invalidArchive` when the field is truncated.
     */
    private static func consumeUInt32(
        from data: Data,
        offset: inout Int,
        field: String
    ) throws -> UInt32 {
        guard offset <= data.count, data.count - offset >= 4 else {
            throw invalidArchive("ZIP64 \(field) is truncated")
        }
        defer { offset += 4 }
        return readUInt32(data, at: offset)
    }

    /**
     Identifies Unix symbolic links and other non-file special nodes.

     - Returns: `true` for unsafe Unix node types, otherwise `false`.
     - Side effects: none.
     - Failure modes: This bit-field check cannot fail.
     */
    private static func isUnixSymbolicLink(
        versionMadeBy: UInt16,
        externalAttributes: UInt32
    ) -> Bool {
        let originatingSystem = UInt8((versionMadeBy >> 8) & 0xff)
        guard originatingSystem == 3 else { return false }
        let fileType = UInt16((externalAttributes >> 16) & 0o170000)
        return fileType != 0 && fileType != 0o100000 && fileType != 0o040000
    }

    /**
     Enforces per-entry byte and expansion-ratio ceilings.

     - Side effects: none.
     - Throws: Typed resource violations. A non-empty expansion with zero compressed bytes is
       represented as the largest possible ratio without arithmetic overflow.
     */
    private static func enforceEntryLimits(
        compressed: UInt64,
        expanded: UInt64,
        limits: AndroidModuleBackupArchiveLimits
    ) throws {
        try enforceLimit(
            .entryCompressedBytes,
            actual: compressed,
            maximum: limits.maximumEntryCompressedByteCount
        )
        try enforceLimit(
            .entryExpandedBytes,
            actual: expanded,
            maximum: limits.maximumEntryExpandedByteCount
        )
        guard expanded > 0 else { return }
        let ratio: UInt64
        if compressed == 0 {
            ratio = UInt64.max
        } else {
            let quotient = expanded / compressed
            ratio = quotient + (expanded % compressed == 0 ? 0 : 1)
        }
        try enforceLimit(
            .expansionRatio,
            actual: ratio,
            maximum: limits.maximumExpansionRatio
        )
    }

    /**
     Adds one aggregate member size without overflow and enforces its ceiling.

     - Returns: Checked aggregate.
     - Side effects: none.
     - Throws: `invalidArchive` on integer overflow or a typed resource violation above policy.
     */
    private static func checkedAggregate(
        _ aggregate: UInt64,
        adding value: UInt64,
        resource: AndroidModuleBackupArchiveResource,
        maximum: UInt64
    ) throws -> UInt64 {
        let (result, overflow) = aggregate.addingReportingOverflow(value)
        guard !overflow else {
            throw invalidArchive("ZIP aggregate size overflows 64-bit accounting")
        }
        try enforceLimit(resource, actual: result, maximum: maximum)
        return result
    }

    /**
     Enforces one planner resource ceiling.

     - Side effects: none.
     - Throws: `resourceLimitExceeded` when `actual` is greater than `maximum`.
     */
    private static func enforceLimit(
        _ resource: AndroidModuleBackupArchiveResource,
        actual: UInt64,
        maximum: UInt64
    ) throws {
        guard actual <= maximum else {
            throw AndroidModuleBackupArchivePlannerError.resourceLimitExceeded(
                resource: resource,
                limit: maximum,
                actual: actual
            )
        }
    }

    /**
     Adds two offsets with explicit overflow reporting.

     - Returns: Checked sum.
     - Side effects: none.
     - Throws: `invalidArchive` when the addition overflows `UInt64`.
     */
    private static func checkedSum(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw invalidArchive("ZIP offset arithmetic overflow")
        }
        return sum
    }

    /**
     Validates a half-open byte range using subtraction-based arithmetic.

     - Side effects: none.
     - Throws: `invalidArchive` when the range lies outside `upperBound`.
     */
    private static func checkedRange(
        offset: UInt64,
        byteCount: UInt64,
        upperBound: UInt64
    ) throws {
        guard offset <= upperBound, byteCount <= upperBound - offset else {
            throw invalidArchive("ZIP metadata points outside archive")
        }
    }

    /**
     Creates a consistently typed malformed-archive failure.

     - Returns: Planner error containing diagnostic context.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func invalidArchive(_ message: String) -> AndroidModuleBackupArchivePlannerError {
        .invalidArchive(message)
    }

    /**
     Reads one little-endian 16-bit value from an already range-checked metadata buffer.
     */
    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(byte(data, at: offset))
            | (UInt16(byte(data, at: offset + 1)) << 8)
    }

    /**
     Reads one little-endian 32-bit value from an already range-checked metadata buffer.
     */
    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        var result: UInt32 = 0
        for index in 0..<4 {
            result |= UInt32(byte(data, at: offset + index)) << UInt32(index * 8)
        }
        return result
    }

    /**
     Reads one little-endian 64-bit value from an already range-checked metadata buffer.
     */
    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<8 {
            result |= UInt64(byte(data, at: offset + index)) << UInt64(index * 8)
        }
        return result
    }

    /**
     Reads one byte using `Data`'s actual start index.
     */
    private static func byte(_ data: Data, at offset: Int) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }
}
