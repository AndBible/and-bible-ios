// ZipArchiveWriter+AndroidModuleBackup.swift - Android ZipOutputStream-compatible module archives

import CLibSword
import Foundation

/**
 Testable thresholds that select classic ZIP fields or their ZIP64 equivalents.

 Production uses the format maxima. Focused tests can lower the thresholds to exercise ZIP64
 grammar without allocating multi-gigabyte fixtures; field values still contain the true sizes and
 offsets, so the resulting archives remain standards-compliant.
 */
struct ZipArchiveWriterFormatThresholds: Sendable, Equatable {
    /// Largest value emitted directly in a classic 32-bit size or offset field.
    let classicValueMaximum: UInt64

    /// Largest entry count emitted directly in the classic EOCD record.
    let classicEntryCountMaximum: UInt64

    /// Production ZIP and ZIP64 field boundary.
    static let standard = ZipArchiveWriterFormatThresholds(
        classicValueMaximum: UInt64(UInt32.max),
        classicEntryCountMaximum: UInt64(UInt16.max)
    )
}

extension ZipArchiveWriter {
    /// ZIP flags used by Java `ZipOutputStream` for UTF-8 names and post-payload descriptors.
    private static var androidModuleFlags: UInt16 { 0x0800 | 0x0008 }

    /// Raw DEFLATE method and classic/ZIP64 extraction versions.
    private static var androidDeflateMethod: UInt16 { 8 }
    private static var androidClassicVersion: UInt16 { 20 }
    private static var androidZip64Version: UInt16 { 45 }

    /// Bounded read/compression buffer and ZIP64 extra-field identifier.
    private static var androidStreamingChunkByteCount: Int { 64 * 1024 }
    private static var androidZip64ExtraFieldIdentifier: UInt16 { 0x0001 }

    /** One source pinned before archive output begins. */
    private enum AndroidDeflateSource {
        case data(Data)
        case pinnedFile(ZipArchiveWriterPinnedFileSource)
    }

    /** Validated entry metadata retained across local-header, payload, and central writes. */
    private struct PreparedAndroidDeflateEntry {
        let name: String
        let nameData: Data
        let source: AndroidDeflateSource
        let expandedByteCount: UInt64
        let dosTime: UInt16
        let dosDate: UInt16
    }

    /** Final metadata produced by one descriptor-bound DEFLATE stream. */
    private struct CompletedAndroidDeflateEntry {
        let nameData: Data
        let checksum: UInt32
        let compressedByteCount: UInt64
        let expandedByteCount: UInt64
        let localHeaderOffset: UInt64
        let dosTime: UInt16
        let dosDate: UInt16
        let usesZip64Sizes: Bool
    }

    /** Raw-DEFLATE metadata returned only after zlib reaches stream end. */
    private struct AndroidDeflateMetadata {
        let checksum: UInt32
        let expandedByteCount: UInt64
        let compressedByteCount: UInt64
    }

    /**
     Writes a streaming ZIP whose observable contract matches Android's module-backup writer.

     Entries remain in caller order, use raw DEFLATE, UTF-8 names, current DOS timestamps, and
     signed data descriptors. File sources are opened once with `O_NOFOLLOW`; CRC calculation and
     compressed output consume the same descriptor bytes, followed by an identity/size/time
     `fstat` verification. ZIP64 records are emitted whenever sizes, offsets, or counts cross their
     classic field boundaries.

     - Parameters:
       - entries: Manifest and selected module files in exact Android selection order.
       - destinationURL: File that receives the complete archive.
       - fileManager: Filesystem service used for destination creation and storage preflight.
       - timestampProvider: Supplies each entry's creation time; tests inject a fixed timestamp.
       - formatThresholds: Classic-field boundaries; production uses ZIP specification maxima.
     - Side effects: Creates or replaces `destinationURL`, opens source descriptors, and streams
       compressed bytes to disk.
     - Throws: Cancellation, source-integrity, compression, storage, ZIP-format, or filesystem
       errors. A caller should remove a partial destination after failure.
     */
    static func writeAndroidCompatibleDeflatedArchive(
        entries: [ZipArchiveWriterFileEntry],
        to destinationURL: URL,
        fileManager: FileManager = .default,
        timestampProvider: () -> Date = Date.init,
        formatThresholds: ZipArchiveWriterFormatThresholds = .standard
    ) throws {
        let preparedEntries = try prepareAndroidDeflateEntries(
            entries,
            timestampProvider: timestampProvider
        )
        try Task.checkCancellation()
        try preflightAndroidArchiveStorage(
            preparedEntries,
            at: destinationURL,
            fileManager: fileManager
        )

        try Task.checkCancellation()
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: destinationURL, options: .atomic)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        var archiveOffset: UInt64 = 0
        var completedEntries: [CompletedAndroidDeflateEntry] = []
        completedEntries.reserveCapacity(preparedEntries.count)

        for entry in preparedEntries {
            try Task.checkCancellation()
            let localHeaderOffset = archiveOffset
            let anticipatedZip64Sizes = shouldUseZip64Sizes(
                expandedByteCount: entry.expandedByteCount,
                thresholds: formatThresholds
            )
            let localExtra = anticipatedZip64Sizes
                ? localZip64Extra(expandedByteCount: entry.expandedByteCount)
                : Data()
            var localHeader = Data()
            appendAndroidUInt32(0x0403_4b50, to: &localHeader)
            appendAndroidUInt16(
                anticipatedZip64Sizes ? androidZip64Version : androidClassicVersion,
                to: &localHeader
            )
            appendAndroidUInt16(androidModuleFlags, to: &localHeader)
            appendAndroidUInt16(androidDeflateMethod, to: &localHeader)
            appendAndroidUInt16(entry.dosTime, to: &localHeader)
            appendAndroidUInt16(entry.dosDate, to: &localHeader)
            appendAndroidUInt32(0, to: &localHeader)
            appendAndroidUInt32(anticipatedZip64Sizes ? UInt32.max : 0, to: &localHeader)
            appendAndroidUInt32(anticipatedZip64Sizes ? UInt32.max : 0, to: &localHeader)
            appendAndroidUInt16(UInt16(entry.nameData.count), to: &localHeader)
            appendAndroidUInt16(UInt16(localExtra.count), to: &localHeader)
            localHeader.append(entry.nameData)
            localHeader.append(localExtra)
            try output.write(contentsOf: localHeader)
            archiveOffset = try adding(UInt64(localHeader.count), to: archiveOffset)

            let metadata = try writeAndroidDeflatedPayload(
                entry.source,
                named: entry.name,
                to: output
            )
            guard metadata.expandedByteCount == entry.expandedByteCount else {
                throw ZipArchiveWriterError.sourceChanged(entry.name)
            }
            archiveOffset = try adding(metadata.compressedByteCount, to: archiveOffset)

            let actualZip64Sizes = metadata.expandedByteCount > formatThresholds.classicValueMaximum
                || metadata.compressedByteCount > formatThresholds.classicValueMaximum
            guard !actualZip64Sizes || anticipatedZip64Sizes else {
                throw ZipArchiveWriterError.archiveTooLarge
            }
            var descriptor = Data()
            appendAndroidUInt32(0x0807_4b50, to: &descriptor)
            appendAndroidUInt32(metadata.checksum, to: &descriptor)
            if anticipatedZip64Sizes {
                appendAndroidUInt64(metadata.compressedByteCount, to: &descriptor)
                appendAndroidUInt64(metadata.expandedByteCount, to: &descriptor)
            } else {
                appendAndroidUInt32(UInt32(metadata.compressedByteCount), to: &descriptor)
                appendAndroidUInt32(UInt32(metadata.expandedByteCount), to: &descriptor)
            }
            try output.write(contentsOf: descriptor)
            archiveOffset = try adding(UInt64(descriptor.count), to: archiveOffset)

            completedEntries.append(CompletedAndroidDeflateEntry(
                nameData: entry.nameData,
                checksum: metadata.checksum,
                compressedByteCount: metadata.compressedByteCount,
                expandedByteCount: metadata.expandedByteCount,
                localHeaderOffset: localHeaderOffset,
                dosTime: entry.dosTime,
                dosDate: entry.dosDate,
                usesZip64Sizes: anticipatedZip64Sizes
            ))
        }

        try Task.checkCancellation()
        let centralDirectoryOffset = archiveOffset
        for entry in completedEntries {
            let usesZip64Offset = entry.localHeaderOffset > formatThresholds.classicValueMaximum
            let extra = centralZip64Extra(entry: entry, usesZip64Offset: usesZip64Offset)
            var record = Data()
            appendAndroidUInt32(0x0201_4b50, to: &record)
            appendAndroidUInt16(
                entry.usesZip64Sizes || usesZip64Offset ? androidZip64Version : androidClassicVersion,
                to: &record
            )
            appendAndroidUInt16(
                entry.usesZip64Sizes || usesZip64Offset ? androidZip64Version : androidClassicVersion,
                to: &record
            )
            appendAndroidUInt16(androidModuleFlags, to: &record)
            appendAndroidUInt16(androidDeflateMethod, to: &record)
            appendAndroidUInt16(entry.dosTime, to: &record)
            appendAndroidUInt16(entry.dosDate, to: &record)
            appendAndroidUInt32(entry.checksum, to: &record)
            appendAndroidUInt32(
                entry.usesZip64Sizes ? UInt32.max : UInt32(entry.compressedByteCount),
                to: &record
            )
            appendAndroidUInt32(
                entry.usesZip64Sizes ? UInt32.max : UInt32(entry.expandedByteCount),
                to: &record
            )
            appendAndroidUInt16(UInt16(entry.nameData.count), to: &record)
            appendAndroidUInt16(UInt16(extra.count), to: &record)
            appendAndroidUInt16(0, to: &record)
            appendAndroidUInt16(0, to: &record)
            appendAndroidUInt16(0, to: &record)
            appendAndroidUInt32(0, to: &record)
            appendAndroidUInt32(
                usesZip64Offset ? UInt32.max : UInt32(entry.localHeaderOffset),
                to: &record
            )
            record.append(entry.nameData)
            record.append(extra)
            try output.write(contentsOf: record)
            archiveOffset = try adding(UInt64(record.count), to: archiveOffset)
        }
        let centralDirectoryByteCount = archiveOffset - centralDirectoryOffset

        let needsZip64EndRecords = UInt64(completedEntries.count)
                > formatThresholds.classicEntryCountMaximum
            || centralDirectoryByteCount > formatThresholds.classicValueMaximum
            || centralDirectoryOffset > formatThresholds.classicValueMaximum
            || completedEntries.contains(where: { entry in
                entry.usesZip64Sizes
                    || entry.localHeaderOffset > formatThresholds.classicValueMaximum
            })
        if needsZip64EndRecords {
            let zip64EndOffset = archiveOffset
            var zip64End = Data()
            appendAndroidUInt32(0x0606_4b50, to: &zip64End)
            appendAndroidUInt64(44, to: &zip64End)
            appendAndroidUInt16(androidZip64Version, to: &zip64End)
            appendAndroidUInt16(androidZip64Version, to: &zip64End)
            appendAndroidUInt32(0, to: &zip64End)
            appendAndroidUInt32(0, to: &zip64End)
            appendAndroidUInt64(UInt64(completedEntries.count), to: &zip64End)
            appendAndroidUInt64(UInt64(completedEntries.count), to: &zip64End)
            appendAndroidUInt64(centralDirectoryByteCount, to: &zip64End)
            appendAndroidUInt64(centralDirectoryOffset, to: &zip64End)
            try output.write(contentsOf: zip64End)
            archiveOffset = try adding(UInt64(zip64End.count), to: archiveOffset)

            var locator = Data()
            appendAndroidUInt32(0x0706_4b50, to: &locator)
            appendAndroidUInt32(0, to: &locator)
            appendAndroidUInt64(zip64EndOffset, to: &locator)
            appendAndroidUInt32(1, to: &locator)
            try output.write(contentsOf: locator)
            archiveOffset = try adding(UInt64(locator.count), to: archiveOffset)
        }

        var end = Data()
        appendAndroidUInt32(0x0605_4b50, to: &end)
        appendAndroidUInt16(0, to: &end)
        appendAndroidUInt16(0, to: &end)
        let classicEntryCount = needsZip64EndRecords
            ? UInt16.max
            : UInt16(completedEntries.count)
        appendAndroidUInt16(classicEntryCount, to: &end)
        appendAndroidUInt16(classicEntryCount, to: &end)
        appendAndroidUInt32(
            needsZip64EndRecords ? UInt32.max : UInt32(centralDirectoryByteCount),
            to: &end
        )
        appendAndroidUInt32(
            needsZip64EndRecords ? UInt32.max : UInt32(centralDirectoryOffset),
            to: &end
        )
        appendAndroidUInt16(0, to: &end)
        try output.write(contentsOf: end)
        try output.synchronize()
    }

    /** Validates names, pins every file, rejects aliases, and captures entry timestamps. */
    private static func prepareAndroidDeflateEntries(
        _ entries: [ZipArchiveWriterFileEntry],
        timestampProvider: () -> Date
    ) throws -> [PreparedAndroidDeflateEntry] {
        var sourceIdentities = Set<String>()
        var prepared: [PreparedAndroidDeflateEntry] = []
        prepared.reserveCapacity(entries.count)
        for entry in entries {
            try Task.checkCancellation()
            guard let nameData = entry.name.data(using: .utf8),
                  nameData.count <= Int(UInt16.max) else {
                throw ZipArchiveWriterError.entryTooLarge(entry.name)
            }
            let source: AndroidDeflateSource
            let expandedByteCount: UInt64
            switch entry.payload {
            case .data(let data):
                source = .data(data)
                expandedByteCount = UInt64(data.count)
            case .file(let fileURL):
                let pinned = try ZipArchiveWriterPinnedFileSource(fileURL: fileURL)
                guard sourceIdentities.insert(pinned.identityKey).inserted else {
                    throw ZipArchiveWriterError.unsafeSource(fileURL.path)
                }
                source = .pinnedFile(pinned)
                expandedByteCount = pinned.byteCount
            case .pinnedFile(let pinned):
                guard sourceIdentities.insert(pinned.identityKey).inserted else {
                    throw ZipArchiveWriterError.unsafeSource(pinned.fileURL.path)
                }
                source = .pinnedFile(pinned)
                expandedByteCount = pinned.byteCount
            }
            let timestamp = androidDosTimestamp(timestampProvider())
            prepared.append(PreparedAndroidDeflateEntry(
                name: entry.name,
                nameData: nameData,
                source: source,
                expandedByteCount: expandedByteCount,
                dosTime: timestamp.time,
                dosDate: timestamp.date
            ))
        }
        return prepared
    }

    /** Checks destination capacity using a conservative raw-DEFLATE and metadata bound. */
    private static func preflightAndroidArchiveStorage(
        _ entries: [PreparedAndroidDeflateEntry],
        at destinationURL: URL,
        fileManager: FileManager
    ) throws {
        var required: UInt64 = 22 + 76
        for entry in entries {
            required = try adding(deflateUpperBound(entry.expandedByteCount), to: required)
            required = try adding(UInt64(entry.nameData.count) * 2 + 160, to: required)
        }
        let directory = destinationURL.deletingLastPathComponent()
        let probeURL = fileManager.fileExists(atPath: directory.path)
            ? directory
            : directory.deletingLastPathComponent()
        let values = try? probeURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let signedAvailable = values?.volumeAvailableCapacityForImportantUsage,
              signedAvailable >= 0 else {
            return
        }
        let available = UInt64(signedAvailable)
        guard required <= available else {
            throw ZipArchiveWriterError.insufficientStorage(required: required, available: available)
        }
    }

    /** Streams one source through raw zlib DEFLATE and verifies its final descriptor metadata. */
    private static func writeAndroidDeflatedPayload(
        _ source: AndroidDeflateSource,
        named entryName: String,
        to output: FileHandle
    ) throws -> AndroidDeflateMetadata {
        guard let context = raw_deflater_create() else {
            throw ZipArchiveWriterError.compressionFailed(entryName)
        }
        defer { raw_deflater_destroy(context) }

        switch source {
        case .data(let data):
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let end = min(offset + androidStreamingChunkByteCount, data.count)
                let chunk = data.subdata(in: offset..<end)
                try consumeAndroidDeflateInput(
                    chunk,
                    finish: false,
                    context: context,
                    entryName: entryName,
                    output: output
                )
                offset = end
            }
        case .pinnedFile(let pinned):
            try pinned.rewind()
            while true {
                try Task.checkCancellation()
                let chunk = try pinned.read(upToCount: androidStreamingChunkByteCount)
                if chunk.isEmpty { break }
                try consumeAndroidDeflateInput(
                    chunk,
                    finish: false,
                    context: context,
                    entryName: entryName,
                    output: output
                )
            }
        }

        try finishAndroidDeflateStream(context: context, entryName: entryName, output: output)
        var checksum: UInt32 = 0
        var expandedByteCount: UInt64 = 0
        var compressedByteCount: UInt64 = 0
        guard raw_deflater_metadata(
            context,
            &checksum,
            &expandedByteCount,
            &compressedByteCount
        ) == 0 else {
            throw ZipArchiveWriterError.compressionFailed(entryName)
        }
        if case .pinnedFile(let pinned) = source {
            try pinned.validateAfterStreaming(streamedByteCount: expandedByteCount)
        }
        return AndroidDeflateMetadata(
            checksum: checksum,
            expandedByteCount: expandedByteCount,
            compressedByteCount: compressedByteCount
        )
    }

    /** Supplies one complete input chunk, draining compressor output until every byte is consumed. */
    private static func consumeAndroidDeflateInput(
        _ input: Data,
        finish: Bool,
        context: UnsafeMutableRawPointer,
        entryName: String,
        output: FileHandle
    ) throws {
        var inputOffset = 0
        repeat {
            try Task.checkCancellation()
            var outputBuffer = Data(count: androidStreamingChunkByteCount)
            let outputCapacity = UInt32(outputBuffer.count)
            var consumed: UInt32 = 0
            var produced: UInt32 = 0
            let result: Int32 = outputBuffer.withUnsafeMutableBytes { outputBytes in
                input.withUnsafeBytes { inputBytes in
                    let inputPointer = inputBytes.baseAddress?
                        .assumingMemoryBound(to: UInt8.self)
                        .advanced(by: inputOffset)
                    return raw_deflater_process(
                        context,
                        inputPointer,
                        UInt32(input.count - inputOffset),
                        finish ? 1 : 0,
                        outputBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        outputCapacity,
                        &consumed,
                        &produced
                    )
                }
            }
            guard result >= 0, result != 1 || finish else {
                throw ZipArchiveWriterError.compressionFailed(entryName)
            }
            if produced > 0 {
                try output.write(contentsOf: outputBuffer.prefix(Int(produced)))
            }
            guard consumed > 0 || produced > 0 || result == 1 else {
                throw ZipArchiveWriterError.compressionFailed(entryName)
            }
            inputOffset += Int(consumed)
        } while inputOffset < input.count
    }

    /** Finishes a raw-DEFLATE stream and writes every trailing compressed byte. */
    private static func finishAndroidDeflateStream(
        context: UnsafeMutableRawPointer,
        entryName: String,
        output: FileHandle
    ) throws {
        while true {
            try Task.checkCancellation()
            var outputBuffer = Data(count: androidStreamingChunkByteCount)
            let outputCapacity = UInt32(outputBuffer.count)
            var consumed: UInt32 = 0
            var produced: UInt32 = 0
            let result = outputBuffer.withUnsafeMutableBytes { outputBytes in
                raw_deflater_process(
                    context,
                    nil,
                    0,
                    1,
                    outputBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    outputCapacity,
                    &consumed,
                    &produced
                )
            }
            guard result >= 0 else {
                throw ZipArchiveWriterError.compressionFailed(entryName)
            }
            if produced > 0 {
                try output.write(contentsOf: outputBuffer.prefix(Int(produced)))
            }
            if result == 1 { return }
            guard produced > 0 else {
                throw ZipArchiveWriterError.compressionFailed(entryName)
            }
        }
    }

    /** Returns whether known input and worst-case DEFLATE output require ZIP64 size fields. */
    private static func shouldUseZip64Sizes(
        expandedByteCount: UInt64,
        thresholds: ZipArchiveWriterFormatThresholds
    ) -> Bool {
        expandedByteCount > thresholds.classicValueMaximum
            || deflateUpperBound(expandedByteCount) > thresholds.classicValueMaximum
    }

    /** Conservative zlib-compatible upper bound without allocating compressed storage. */
    private static func deflateUpperBound(_ byteCount: UInt64) -> UInt64 {
        let eighth = byteCount / 8 + (byteCount % 8 == 0 ? 0 : 1)
        let sixtyFourth = byteCount / 64 + (byteCount % 64 == 0 ? 0 : 1)
        var total = byteCount
        for addition in [eighth, sixtyFourth, 11] {
            let result = total.addingReportingOverflow(addition)
            if result.overflow { return .max }
            total = result.partialValue
        }
        return total
    }

    /** Creates local ZIP64 placeholders for descriptor-backed sizes. */
    private static func localZip64Extra(expandedByteCount: UInt64) -> Data {
        var extra = Data()
        appendAndroidUInt16(androidZip64ExtraFieldIdentifier, to: &extra)
        appendAndroidUInt16(16, to: &extra)
        appendAndroidUInt64(expandedByteCount, to: &extra)
        appendAndroidUInt64(0, to: &extra)
        return extra
    }

    /** Creates central ZIP64 values in the specification-required sentinel-field order. */
    private static func centralZip64Extra(
        entry: CompletedAndroidDeflateEntry,
        usesZip64Offset: Bool
    ) -> Data {
        guard entry.usesZip64Sizes || usesZip64Offset else { return Data() }
        var payload = Data()
        if entry.usesZip64Sizes {
            appendAndroidUInt64(entry.expandedByteCount, to: &payload)
            appendAndroidUInt64(entry.compressedByteCount, to: &payload)
        }
        if usesZip64Offset {
            appendAndroidUInt64(entry.localHeaderOffset, to: &payload)
        }
        var extra = Data()
        appendAndroidUInt16(androidZip64ExtraFieldIdentifier, to: &extra)
        appendAndroidUInt16(UInt16(payload.count), to: &extra)
        extra.append(payload)
        return extra
    }

    /** Converts one wall-clock instant to the local-time DOS date/time fields Java ZIP emits. */
    private static func androidDosTimestamp(_ value: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: value
        )
        components.year = min(max(components.year ?? 1980, 1980), 2107)
        let year = UInt16((components.year ?? 1980) - 1980)
        let month = UInt16(min(max(components.month ?? 1, 1), 12))
        let day = UInt16(min(max(components.day ?? 1, 1), 31))
        let hour = UInt16(min(max(components.hour ?? 0, 0), 23))
        let minute = UInt16(min(max(components.minute ?? 0, 0), 59))
        let second = UInt16(min(max(components.second ?? 0, 0), 59) / 2)
        return (
            time: hour << 11 | minute << 5 | second,
            date: year << 9 | month << 5 | day
        )
    }

    /** Adds archive offsets while rejecting integer wraparound. */
    private static func adding(_ value: UInt64, to total: UInt64) throws -> UInt64 {
        let result = total.addingReportingOverflow(value)
        guard !result.overflow else { throw ZipArchiveWriterError.archiveTooLarge }
        return result.partialValue
    }

    /** Appends a little-endian 16-bit ZIP field. */
    private static func appendAndroidUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    /** Appends a little-endian 32-bit ZIP field. */
    private static func appendAndroidUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    /** Appends a little-endian 64-bit ZIP64 field. */
    private static func appendAndroidUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }
}
