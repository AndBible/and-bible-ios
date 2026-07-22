import Foundation
import XCTest
@testable import BibleCore

/**
 Adversarial contract tests for Android-compatible streaming module-backup output.

 Fixtures are produced by the real descriptor-backed writer, then parsed by the production archive
 planner and shared ZIP reader. Targeted byte edits remove optional descriptor signatures or alter
 exact boundaries without replacing either side with a synthetic parser.
 */
final class AndroidModuleBackupArchiveWriterTests: XCTestCase {
    /**
     Verifies Android's observable writer contract and complete manifest order.

     The literal manifest, config, and payload are emitted in caller order with UTF-8 plus
     data-descriptor flags, raw DEFLATE, one fixed local timestamp, and signed classic descriptors.
     Both production readers must recover the original bytes. Failure makes an iOS export differ
     from Java `ZipOutputStream` in metadata Android consumes.
     */
    func testWriterEmitsAndroidDeflateDescriptorTimestampAndManifestOrder() throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let archiveURL = fixture.appendingPathComponent("contract.abmd.zip")
        let manifest = Data(
            #"{"backupType":"MODULE_BACKUP","contains":null,"manifestVersion":1,"andBibleVersion":777}"#.utf8
        )
        let config = Data(
            """
            [KJV]
            DataPath=./modules/texts/rawtext/kjv/
            ModDrv=RawText
            Description=King James Version

            """.utf8
        )
        let payload = Data("Genesis content".utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let timestamp = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2024,
            month: 5,
            day: 6,
            hour: 14,
            minute: 8,
            second: 10
        )))

        try ZipArchiveWriter.writeAndroidCompatibleDeflatedArchive(
            entries: [
                ZipArchiveWriterFileEntry(
                    name: "AndBibleBackupManifest.json",
                    data: manifest
                ),
                ZipArchiveWriterFileEntry(name: "mods.d/kjv.conf", data: config),
                ZipArchiveWriterFileEntry(
                    name: "modules/texts/rawtext/kjv/ot",
                    data: payload
                ),
            ],
            to: archiveURL,
            timestampProvider: { timestamp }
        )

        let archive = try Data(contentsOf: archiveURL)
        let localOffsets = try localHeaderOffsets(in: archive)
        XCTAssertEqual(localOffsets.count, 3)
        let expectedTime = UInt16(14 << 11 | 8 << 5 | 5)
        let expectedDate = UInt16((2024 - 1980) << 9 | 5 << 5 | 6)
        for offset in localOffsets {
            XCTAssertEqual(try uint16(archive, at: offset + 6), 0x0808)
            XCTAssertEqual(try uint16(archive, at: offset + 8), 8)
            XCTAssertEqual(try uint16(archive, at: offset + 10), expectedTime)
            XCTAssertEqual(try uint16(archive, at: offset + 12), expectedDate)
        }
        XCTAssertEqual(signatureCount(0x0807_4b50, in: archive), 3)
        XCTAssertEqual(
            try ZipArchiveReader.entries(in: archive).map(\.name),
            [
                "AndBibleBackupManifest.json",
                "mods.d/kjv.conf",
                "modules/texts/rawtext/kjv/ot",
            ]
        )
        let plan = try AndroidModuleBackupArchivePlanner().planArchive(from: archive)
        XCTAssertEqual(plan.swordModuleNames, ["KJV"])
        XCTAssertEqual(
            plan.manifestDisposition,
            .validatedFirstEntry(AndroidModuleBackupArchiveManifest(
                backupType: .moduleBackup,
                contains: nil,
                manifestVersion: 1,
                andBibleVersion: 777
            ))
        )
    }

    /**
     Verifies all four legal data-descriptor grammars and exact boundary rejection.

     Production creates signed classic and ZIP64 archives. Removing only each optional descriptor
     signature and repairing downstream offsets yields standards-valid unsigned variants. Adding
     one unaccounted byte before the central directory must fail planning. Failure accepts ambiguous
     payload tails or rejects Android archives written by another conforming ZIP implementation.
     */
    func testPlannerAcceptsSignedAndUnsignedClassicAndZIP64DescriptorsOnlyAtExactBoundary() throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let entry = ZipArchiveWriterFileEntry(
            name: "background/image.png",
            data: Data("image bytes".utf8)
        )
        let classicURL = fixture.appendingPathComponent("classic.zip")
        try ZipArchiveWriter.writeAndroidCompatibleDeflatedArchive(
            entries: [entry],
            to: classicURL,
            timestampProvider: { Date(timeIntervalSince1970: 0) }
        )
        let signedClassic = try Data(contentsOf: classicURL)
        let unsignedClassic = try removingDescriptorSignature(
            from: signedClassic,
            zip64: false
        )

        let zip64URL = fixture.appendingPathComponent("zip64.zip")
        try ZipArchiveWriter.writeAndroidCompatibleDeflatedArchive(
            entries: [entry],
            to: zip64URL,
            timestampProvider: { Date(timeIntervalSince1970: 0) },
            formatThresholds: ZipArchiveWriterFormatThresholds(
                classicValueMaximum: 1,
                classicEntryCountMaximum: 0
            )
        )
        let signedZIP64 = try Data(contentsOf: zip64URL)
        let unsignedZIP64 = try removingDescriptorSignature(from: signedZIP64, zip64: true)

        for archive in [signedClassic, unsignedClassic, signedZIP64, unsignedZIP64] {
            let plan = try AndroidModuleBackupArchivePlanner().planArchive(from: archive)
            XCTAssertEqual(plan.entries.map(\.relativePath), ["background/image.png"])
            XCTAssertEqual(
                try ZipArchiveReader.entries(in: archive).map(\.data),
                [Data("image bytes".utf8)]
            )
        }

        let malformed = try insertingDescriptorBoundaryByte(into: signedClassic)
        XCTAssertThrowsError(
            try AndroidModuleBackupArchivePlanner().planArchive(from: malformed)
        ) { error in
            guard case .invalidArchive = error as? AndroidModuleBackupArchivePlannerError else {
                return XCTFail("Expected invalid descriptor boundary, received \(error)")
            }
        }
    }

    /**
     Verifies source aliases and same-inode mutation cannot cross validation and write phases.

     A hard-linked file is rejected before destination creation. A second source is opened once,
     then overwritten through the same inode from the timestamp callback after pinning but before
     compression; final descriptor metadata must detect the change. Failure reintroduces archive
     family aliasing or permits CRC validation and emitted bytes to observe different source states.
     */
    func testWriterRejectsHardlinksAndMutationAfterDescriptorPinning() throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source.bin")
        let alias = fixture.appendingPathComponent("alias.bin")
        try Data("original".utf8).write(to: source)
        try FileManager.default.linkItem(at: source, to: alias)
        let hardlinkArchive = fixture.appendingPathComponent("hardlink.zip")

        XCTAssertThrowsError(try ZipArchiveWriter.writeAndroidCompatibleDeflatedArchive(
            entries: [ZipArchiveWriterFileEntry(name: "ttf/source.ttf", fileURL: source)],
            to: hardlinkArchive
        )) { error in
            guard case .unsafeSource = error as? ZipArchiveWriterError else {
                return XCTFail("Expected hardlink rejection, received \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: hardlinkArchive.path))

        try FileManager.default.removeItem(at: alias)
        let mutableSource = fixture.appendingPathComponent("mutable.bin")
        try Data(repeating: 0x41, count: 128 * 1_024).write(to: mutableSource)
        let mutationArchive = fixture.appendingPathComponent("mutation.zip")
        var didMutate = false
        XCTAssertThrowsError(try ZipArchiveWriter.writeAndroidCompatibleDeflatedArchive(
            entries: [ZipArchiveWriterFileEntry(
                name: "background/mutable.png",
                fileURL: mutableSource
            )],
            to: mutationArchive,
            timestampProvider: {
                if !didMutate {
                    didMutate = true
                    let handle = try! FileHandle(forWritingTo: mutableSource)
                    try! handle.seek(toOffset: 0)
                    try! handle.write(contentsOf: Data(repeating: 0x42, count: 128 * 1_024))
                    try! handle.synchronize()
                    try! handle.close()
                }
                return Date(timeIntervalSince1970: 0)
            }
        )) { error in
            guard case .sourceChanged = error as? ZipArchiveWriterError else {
                return XCTFail("Expected pinned-source mutation rejection, received \(error)")
            }
        }
    }

    /**
     Verifies cancellation after descriptor pinning but before output mutation leaves no archive.

     The timestamp callback is the deterministic boundary after source preparation. Cancellation is
     delivered while that callback is blocked; the writer's immediate preflight checkpoint must
     throw before creating the destination. Failure makes the retained Settings task unable to stop
     an export without leaving a misleading partial file.
     */
    func testWriterCancellationBeforeMutationLeavesNoDestination() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let destination = fixture.appendingPathComponent("cancelled.zip")
        let reachedTimestamp = DispatchSemaphore(value: 0)
        let releaseTimestamp = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try ZipArchiveWriter.writeAndroidCompatibleDeflatedArchive(
                entries: [ZipArchiveWriterFileEntry(
                    name: "background/cancel.png",
                    data: Data(repeating: 0x43, count: 64 * 1_024)
                )],
                to: destination,
                timestampProvider: {
                    reachedTimestamp.signal()
                    releaseTimestamp.wait()
                    return Date(timeIntervalSince1970: 0)
                }
            )
        }
        XCTAssertEqual(reachedTimestamp.wait(timeout: .now() + 5), .success)
        task.cancel()
        releaseTimestamp.signal()

        do {
            try await task.value
            XCTFail("Expected cancellation before destination mutation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /** Creates one test-owned directory for archive and source fixtures. */
    private func makeFixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "android-module-writer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /** Returns local-header offsets in physical order up to the central directory. */
    private func localHeaderOffsets(in archive: Data) throws -> [Int] {
        let central = try signatureOffset(0x0201_4b50, in: archive)
        var offsets: [Int] = []
        var cursor = 0
        while cursor < central {
            guard try uint32(archive, at: cursor) == 0x0403_4b50 else {
                throw AndroidModuleBackupArchiveWriterTestError.invalidFixture
            }
            offsets.append(cursor)
            let nameCount = Int(try uint16(archive, at: cursor + 26))
            let extraCount = Int(try uint16(archive, at: cursor + 28))
            let nextHeader = try nextLocalOrCentralOffset(
                after: cursor + 30 + nameCount + extraCount,
                in: archive,
                upperBound: central
            )
            cursor = nextHeader
        }
        return offsets
    }

    /** Finds the next local header or central directory after one descriptor-backed payload. */
    private func nextLocalOrCentralOffset(
        after start: Int,
        in data: Data,
        upperBound: Int
    ) throws -> Int {
        guard start <= upperBound else {
            throw AndroidModuleBackupArchiveWriterTestError.invalidFixture
        }
        for offset in start...upperBound {
            if offset + 4 <= data.count {
                let value = try uint32(data, at: offset)
                if value == 0x0403_4b50 || value == 0x0201_4b50 {
                    return offset
                }
            }
        }
        throw AndroidModuleBackupArchiveWriterTestError.invalidFixture
    }

    /** Removes one optional descriptor signature and repairs central/trailer offsets. */
    private func removingDescriptorSignature(from input: Data, zip64: Bool) throws -> Data {
        var data = input
        let descriptor = try signatureOffset(0x0807_4b50, in: data)
        let oldCentral = try signatureOffset(0x0201_4b50, in: data)
        data.removeSubrange(descriptor..<(descriptor + 4))
        let newCentral = oldCentral - 4
        if zip64 {
            let oldZIP64End = try signatureOffset(0x0606_4b50, in: input)
            let oldLocator = try signatureOffset(0x0706_4b50, in: input)
            replaceUInt64(UInt64(newCentral), in: &data, at: oldZIP64End - 4 + 48)
            replaceUInt64(UInt64(oldZIP64End - 4), in: &data, at: oldLocator - 4 + 8)
        } else {
            let oldEnd = try signatureOffset(0x0605_4b50, in: input)
            replaceUInt32(UInt32(newCentral), in: &data, at: oldEnd - 4 + 16)
        }
        return data
    }

    /** Inserts one illegal descriptor-tail byte while preserving the declared central offset. */
    private func insertingDescriptorBoundaryByte(into input: Data) throws -> Data {
        var data = input
        let oldCentral = try signatureOffset(0x0201_4b50, in: input)
        let oldEnd = try signatureOffset(0x0605_4b50, in: input)
        data.insert(0, at: oldCentral)
        replaceUInt32(UInt32(oldCentral + 1), in: &data, at: oldEnd + 1 + 16)
        return data
    }

    /** Counts one little-endian ZIP signature without assuming payload bytes exclude it. */
    private func signatureCount(_ signature: UInt32, in data: Data) -> Int {
        guard data.count >= 4 else { return 0 }
        return (0...(data.count - 4)).reduce(into: 0) { count, offset in
            if (try? uint32(data, at: offset)) == signature { count += 1 }
        }
    }

    /** Finds the first exact little-endian ZIP signature. */
    private func signatureOffset(_ signature: UInt32, in data: Data) throws -> Int {
        guard data.count >= 4 else {
            throw AndroidModuleBackupArchiveWriterTestError.invalidFixture
        }
        for offset in 0...(data.count - 4) where try uint32(data, at: offset) == signature {
            return offset
        }
        throw AndroidModuleBackupArchiveWriterTestError.invalidFixture
    }

    /** Reads one checked little-endian 16-bit test field. */
    private func uint16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= data.count - 2 else {
            throw AndroidModuleBackupArchiveWriterTestError.invalidFixture
        }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    /** Reads one checked little-endian 32-bit test field. */
    private func uint32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else {
            throw AndroidModuleBackupArchiveWriterTestError.invalidFixture
        }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    /** Replaces one little-endian 32-bit test field. */
    private func replaceUInt32(_ value: UInt32, in data: inout Data, at offset: Int) {
        for byte in 0..<4 {
            data[offset + byte] = UInt8((value >> UInt32(byte * 8)) & 0xff)
        }
    }

    /** Replaces one little-endian 64-bit test field. */
    private func replaceUInt64(_ value: UInt64, in data: inout Data, at offset: Int) {
        for byte in 0..<8 {
            data[offset + byte] = UInt8((value >> UInt64(byte * 8)) & 0xff)
        }
    }
}

/** Indicates a targeted writer fixture no longer has its documented ZIP shape. */
private enum AndroidModuleBackupArchiveWriterTestError: Error {
    case invalidFixture
}
