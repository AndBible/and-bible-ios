import Foundation
import XCTest
@testable import BibleCore

/**
 Adversarial ZIP64 coverage for the shared Android-backup and EPUB archive reader.

 Every fixture uses real ZIP64 EOCD, locator, and extended-information records despite containing
 small payloads. This forces the ZIP64 parser paths without creating multi-gigabyte test files.
 */
final class ZipArchiveReaderZIP64Tests: XCTestCase {
    /// Temporary roots and archives removed after each test.
    private var temporaryURLs: [URL] = []

    /**
     Removes every temporary artifact created by the current test.

     - Side effects: Deletes recorded files and directories.
     - Failure modes: Cleanup errors are ignored so they do not obscure the primary test failure.
     */
    override func tearDown() {
        for url in temporaryURLs.reversed() {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    /**
     Verifies eager and file-backed readers resolve every ZIP64 sentinel from canonical metadata.

     Failure means a valid ZIP64 archive accepted by Android cannot reach shared backup/import
     consumers on iOS.
     */
    func testZIP64ReaderSupportsEOCDLocatorRecordAndExtendedEntryFields() throws {
        let fixture = makeZIP64StoredArchive(entries: [
            ("folder/alpha.txt", Data("alpha".utf8)),
            ("beta.txt", Data("beta".utf8)),
        ])

        let eagerEntries = try ZipArchiveReader.entries(in: fixture.data)
        XCTAssertEqual(eagerEntries.map(\.name), ["folder/alpha.txt", "beta.txt"])
        XCTAssertEqual(eagerEntries.map(\.data), [Data("alpha".utf8), Data("beta".utf8)])

        let archiveURL = try writeTemporaryArchive(fixture.data, suffix: ".zip")
        XCTAssertEqual(
            try ZipArchiveReader.entryNames(inArchiveAt: archiveURL),
            ["folder/alpha.txt", "beta.txt"]
        )
        let fileEntries = try ZipArchiveReader.fileEntries(inArchiveAt: archiveURL)
        XCTAssertEqual(fileEntries.map(\.compressedSize), [5, 4])
        XCTAssertEqual(fileEntries.map(\.uncompressedSize), [5, 4])
        XCTAssertEqual(
            try ZipArchiveReader.data(for: fileEntries[0], inArchiveAt: archiveURL, maximumByteCount: 16),
            Data("alpha".utf8)
        )
    }

    /**
     Verifies malformed ZIP64 trailer variants fail before central-directory allocation or scans.

     Failure means an archive can redirect the reader through an unbounded locator lookup, use a
     truncated record, or conceal contradictory single-disk metadata.
     */
    func testZIP64ReaderRejectsMalformedLocatorAndRecordMetadata() {
        let fixture = makeZIP64StoredArchive(entries: [("alpha.txt", Data("alpha".utf8))])
        let mutations: [(String, (inout Data) -> Void)] = [
            ("missing locator", { data in
                replaceZIP64UInt32(0, in: &data, at: fixture.locatorOffset)
            }),
            ("locator target outside archive", { data in
                replaceZIP64UInt64(UInt64.max, in: &data, at: fixture.locatorOffset + 8)
            }),
            ("short record", { data in
                replaceZIP64UInt64(43, in: &data, at: fixture.zip64RecordOffset + 4)
            }),
            ("old required version", { data in
                replaceZIP64UInt16(20, in: &data, at: fixture.zip64RecordOffset + 14)
            }),
            ("mismatched per-disk count", { data in
                replaceZIP64UInt64(2, in: &data, at: fixture.zip64RecordOffset + 24)
            }),
            ("classic count conflicts with ZIP64", { data in
                replaceZIP64UInt16(0, in: &data, at: fixture.endRecordOffset + 8)
            }),
            ("multi-disk locator", { data in
                replaceZIP64UInt32(2, in: &data, at: fixture.locatorOffset + 16)
            }),
        ]

        for (label, mutate) in mutations {
            var archive = fixture.data
            mutate(&archive)
            XCTAssertThrowsError(try ZipArchiveReader.entries(in: archive), label)
        }
    }

    /**
     Verifies required ZIP64 extra values cannot be omitted, truncated, or redirected.

     Failure means sentinel entry fields can fall back to attacker-controlled classic values or
     local payload offsets inside the central directory.
     */
    func testZIP64ReaderRejectsMalformedExtraFieldsAndPayloadOffsets() {
        let fixture = makeZIP64StoredArchive(entries: [("alpha.txt", Data("alpha".utf8))])
        var missingExtra = fixture.data
        replaceZIP64UInt16(0x9999, in: &missingExtra, at: fixture.centralExtraHeaderOffsets[0])
        XCTAssertThrowsError(try ZipArchiveReader.entries(in: missingExtra))

        var truncatedExtra = fixture.data
        replaceZIP64UInt16(16, in: &truncatedExtra, at: fixture.centralExtraHeaderOffsets[0] + 2)
        XCTAssertThrowsError(try ZipArchiveReader.entries(in: truncatedExtra))

        var payloadInDirectory = fixture.data
        replaceZIP64UInt64(
            UInt64(fixture.centralDirectoryOffset),
            in: &payloadInDirectory,
            at: fixture.centralExtraPayloadOffsets[0] + 16
        )
        XCTAssertThrowsError(try ZipArchiveReader.entries(in: payloadInDirectory))

        var nonzeroDiskStart = fixture.data
        replaceZIP64UInt32(
            1,
            in: &nonzeroDiskStart,
            at: fixture.centralExtraPayloadOffsets[0] + 24
        )
        XCTAssertThrowsError(try ZipArchiveReader.entries(in: nonzeroDiskStart))
    }

    /**
     Verifies ZIP64 central-directory and member size declarations remain archive bounded.

     Failure means 64-bit arithmetic can wrap or point metadata/payload ranges outside the source
     archive.
     */
    func testZIP64ReaderRejectsOutOfBoundsDirectoryAndMemberSizes() throws {
        let fixture = makeZIP64StoredArchive(entries: [("alpha.txt", Data("alpha".utf8))])
        var directoryOutsideArchive = fixture.data
        replaceZIP64UInt64(
            UInt64(fixture.data.count + 1),
            in: &directoryOutsideArchive,
            at: fixture.zip64RecordOffset + 48
        )
        XCTAssertThrowsError(try ZipArchiveReader.entries(in: directoryOutsideArchive))

        var memberOutsidePayloadArea = fixture.data
        let oversizedMember = UInt64(fixture.centralDirectoryOffset)
        replaceZIP64UInt64(
            oversizedMember,
            in: &memberOutsidePayloadArea,
            at: fixture.centralExtraPayloadOffsets[0]
        )
        replaceZIP64UInt64(
            oversizedMember,
            in: &memberOutsidePayloadArea,
            at: fixture.centralExtraPayloadOffsets[0] + 8
        )
        let archiveURL = try writeTemporaryArchive(memberOutsidePayloadArea, suffix: ".zip")
        XCTAssertThrowsError(try ZipArchiveReader.fileEntries(inArchiveAt: archiveURL))
    }

    /**
     Verifies ZIP64 declarations honor a caller-supplied materialization limit.

     Failure means the bounded metadata API can allocate a ZIP64 payload larger than the caller
     explicitly permits even though the shared streaming parser has no arbitrary fixed byte cap.
     */
    func testZIP64ReaderEnforcesExpansionLimitBeforeMaterialization() throws {
        let fixture = makeZIP64StoredArchive(entries: [("alpha.txt", Data("alpha".utf8))])
        let archiveURL = try writeTemporaryArchive(fixture.data, suffix: ".zip")
        let entry = try XCTUnwrap(ZipArchiveReader.fileEntries(inArchiveAt: archiveURL).first)
        XCTAssertThrowsError(
            try ZipArchiveReader.data(
                for: entry,
                inArchiveAt: archiveURL,
                maximumByteCount: 4
            )
        ) { error in
            XCTAssertEqual(
                error as? ZipArchiveReaderError,
                .invalidArchive("ZIP entry exceeds maximum supported size")
            )
        }
    }

    /**
     Verifies file-backed ZIP64 metadata accepts entries beyond the removed 256/512 MiB ceilings.

     The fixture uses a real sparse payload range, so parser boundary checks see a complete archive
     without allocating or writing hundreds of megabytes. Failure means a legacy fixed byte cap was
     reintroduced instead of leaving capacity policy to the streaming consumer.
     */
    func testZIP64FileMetadataAcceptsEntryPastLegacyFixedLimits() throws {
        let payloadSize = UInt64(512 * 1024 * 1024 + 1)
        let archiveURL = try writeSparseZIP64StoredArchive(
            name: "large/module.dat",
            payloadSize: payloadSize
        )

        let entry = try XCTUnwrap(ZipArchiveReader.fileEntries(inArchiveAt: archiveURL).first)

        XCTAssertEqual(entry.name, "large/module.dat")
        XCTAssertEqual(entry.compressedSize, payloadSize)
        XCTAssertEqual(entry.uncompressedSize, payloadSize)
    }

    /**
     Verifies a valid ZIP64 Android module backup publishes through the shared transaction path.

     Failure means ZIP64 metadata works in isolation but remains incompatible with transactional
     config-to-payload validation or canonical module-store publisher.
     */
    func testZIP64AndroidModuleBackupRestoresConfigAndOwnedPayload() throws {
        let moduleRoot = try makeTemporaryDirectory(named: "zip64-module-root")
            .appendingPathComponent("sword", isDirectory: true)
        let fixture = makeZIP64StoredArchive(entries: androidModuleEntries())
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)

        let report = try service.restoreArchive(from: fixture.data)

        XCTAssertEqual(report.installedModuleNames, ["ZIP64"])
        XCTAssertEqual(
            try Data(contentsOf: moduleRoot.appendingPathComponent("modules/texts/rawtext/zip64/ot")),
            Data("module-data".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: moduleRoot.appendingPathComponent("mods.d/zip64.conf").path))
    }

    /**
     Verifies ZIP64 does not weaken Android module-backup traversal rejection.

     Failure means enabling 64-bit archive metadata creates a path-normalization bypass before
     staged module ownership validation.
     */
    func testZIP64AndroidModuleBackupRejectsTraversalBeforeMutation() throws {
        let moduleRoot = try makeTemporaryDirectory(named: "zip64-module-traversal")
            .appendingPathComponent("sword", isDirectory: true)
        var entries = androidModuleEntries()
        entries.append(("modules/../../outside.txt", Data("escape".utf8)))
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)

        XCTAssertThrowsError(try service.restoreArchive(from: makeZIP64StoredArchive(entries: entries).data))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moduleRoot.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: moduleRoot.deletingLastPathComponent().appendingPathComponent("outside.txt").path
            )
        )
    }

    /**
     Verifies a complete EPUB package installs from a forced-ZIP64 archive.

     Failure means the file-backed reader resolves ZIP64 metadata but EPUB extraction, checksum
     validation, or package publication still diverges from Android.
     */
    func testZIP64EPUBInstallsAndPublishesReadableContent() throws {
        let libraryRoot = try makeTemporaryDirectory(named: "zip64-epub-library")
        let archiveURL = try writeTemporaryArchive(
            makeZIP64StoredArchive(entries: minimalEpubEntries(title: "ZIP64 Book")).data,
            suffix: ".epub"
        )

        let identifier = try EpubReader.install(epubURL: archiveURL, libraryRootURL: libraryRoot)
        let reader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: libraryRoot))
        let firstEntry = try XCTUnwrap(reader.tableOfContents().first)
        let content = try XCTUnwrap(reader.content(forKey: firstEntry.key))

        XCTAssertEqual(reader.title, "ZIP64 Book")
        XCTAssertTrue(content.html.contains("ZIP64 content"))
    }

    /**
     Verifies ZIP64 EPUB traversal fails before any package or outside file is published.

     Failure means ZIP64 entry resolution bypasses the EPUB library's canonical path validation.
     */
    func testZIP64EPUBRejectsTraversalWithoutPublication() throws {
        let libraryRoot = try makeTemporaryDirectory(named: "zip64-epub-traversal")
        var entries = minimalEpubEntries(title: "Unsafe ZIP64")
        entries.append(("../outside.txt", Data("escape".utf8)))
        let archiveURL = try writeTemporaryArchive(
            makeZIP64StoredArchive(entries: entries).data,
            suffix: ".epub"
        )

        XCTAssertThrowsError(try EpubReader.install(epubURL: archiveURL, libraryRootURL: libraryRoot))
        XCTAssertTrue(EpubReader.installedEpubs(libraryRootURL: libraryRoot).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: libraryRoot.deletingLastPathComponent().appendingPathComponent("outside.txt").path
            )
        )
    }

    /**
     Verifies ZIP64 EPUB declarations remain subject to the package expansion cap.

     Failure means a tiny deflated member can claim an unbounded 64-bit output size and reach
     extraction before the EPUB consumer performs aggregate accounting.
     */
    func testZIP64EPUBEnforcesExpansionLimitBeforeExtraction() throws {
        let libraryRoot = try makeTemporaryDirectory(named: "zip64-epub-expansion")
        var fixture = makeZIP64StoredArchive(entries: minimalEpubEntries(title: "Oversized ZIP64"))
        var archive = fixture.data
        replaceZIP64UInt16(8, in: &archive, at: fixture.localHeaderOffsets[0] + 8)
        replaceZIP64UInt16(8, in: &archive, at: fixture.centralHeaderOffsets[0] + 10)
        replaceZIP64UInt64(
            UInt64(512 * 1024 * 1024),
            in: &archive,
            at: fixture.localExtraPayloadOffsets[0]
        )
        replaceZIP64UInt64(
            UInt64(512 * 1024 * 1024),
            in: &archive,
            at: fixture.centralExtraPayloadOffsets[0]
        )
        fixture.data = archive
        let archiveURL = try writeTemporaryArchive(fixture.data, suffix: ".epub")

        XCTAssertThrowsError(try EpubReader.install(epubURL: archiveURL, libraryRootURL: libraryRoot)) { error in
            guard case let EpubError.invalidEpub(message) = error else {
                return XCTFail("Expected invalidEpub, got \(error)")
            }
            XCTAssertTrue(message.contains("extraction limit"))
        }
        XCTAssertTrue(EpubReader.installedEpubs(libraryRootURL: libraryRoot).isEmpty)
    }

    /** Creates and records an isolated temporary directory. */
    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    /** Writes and records one temporary archive. */
    private func writeTemporaryArchive(_ data: Data, suffix: String) throws -> URL {
        let directory = try makeTemporaryDirectory(named: "zip64-archive")
        let url = directory.appendingPathComponent("fixture\(suffix)")
        try data.write(to: url, options: .atomic)
        return url
    }

    /**
     Writes one complete sparse ZIP64 stored archive without materializing its payload bytes.

     - Parameters:
       - name: UTF-8 member path.
       - payloadSize: Logical zero-filled payload size represented by the sparse range.
     - Returns: Recorded temporary archive URL.
     - Side effects: Creates a sparse file under the test temporary directory.
     - Failure modes: Rethrows file creation, seek, and write failures.
     */
    private func writeSparseZIP64StoredArchive(name: String, payloadSize: UInt64) throws -> URL {
        let directory = try makeTemporaryDirectory(named: "zip64-sparse-archive")
        let url = directory.appendingPathComponent("fixture.zip")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let nameData = Data(name.utf8)

        var localHeader = Data()
        appendZIP64UInt32(0x0403_4b50, to: &localHeader)
        appendZIP64UInt16(45, to: &localHeader)
        appendZIP64UInt16(0, to: &localHeader)
        appendZIP64UInt16(0, to: &localHeader)
        appendZIP64UInt16(0, to: &localHeader)
        appendZIP64UInt16(0, to: &localHeader)
        appendZIP64UInt32(0, to: &localHeader)
        appendZIP64UInt32(UInt32.max, to: &localHeader)
        appendZIP64UInt32(UInt32.max, to: &localHeader)
        appendZIP64UInt16(UInt16(nameData.count), to: &localHeader)
        appendZIP64UInt16(20, to: &localHeader)
        localHeader.append(nameData)
        appendZIP64UInt16(0x0001, to: &localHeader)
        appendZIP64UInt16(16, to: &localHeader)
        appendZIP64UInt64(payloadSize, to: &localHeader)
        appendZIP64UInt64(payloadSize, to: &localHeader)
        try handle.write(contentsOf: localHeader)

        let centralDirectoryOffset = UInt64(localHeader.count) + payloadSize
        try handle.seek(toOffset: centralDirectoryOffset)
        var centralDirectory = Data()
        appendZIP64UInt32(0x0201_4b50, to: &centralDirectory)
        appendZIP64UInt16(45, to: &centralDirectory)
        appendZIP64UInt16(45, to: &centralDirectory)
        appendZIP64UInt16(0, to: &centralDirectory)
        appendZIP64UInt16(0, to: &centralDirectory)
        appendZIP64UInt16(0, to: &centralDirectory)
        appendZIP64UInt16(0, to: &centralDirectory)
        appendZIP64UInt32(0, to: &centralDirectory)
        appendZIP64UInt32(UInt32.max, to: &centralDirectory)
        appendZIP64UInt32(UInt32.max, to: &centralDirectory)
        appendZIP64UInt16(UInt16(nameData.count), to: &centralDirectory)
        appendZIP64UInt16(32, to: &centralDirectory)
        appendZIP64UInt16(0, to: &centralDirectory)
        appendZIP64UInt16(UInt16.max, to: &centralDirectory)
        appendZIP64UInt16(0, to: &centralDirectory)
        appendZIP64UInt32(0, to: &centralDirectory)
        appendZIP64UInt32(UInt32.max, to: &centralDirectory)
        centralDirectory.append(nameData)
        appendZIP64UInt16(0x0001, to: &centralDirectory)
        appendZIP64UInt16(28, to: &centralDirectory)
        appendZIP64UInt64(payloadSize, to: &centralDirectory)
        appendZIP64UInt64(payloadSize, to: &centralDirectory)
        appendZIP64UInt64(0, to: &centralDirectory)
        appendZIP64UInt32(0, to: &centralDirectory)
        try handle.write(contentsOf: centralDirectory)

        let zip64RecordOffset = centralDirectoryOffset + UInt64(centralDirectory.count)
        var trailer = Data()
        appendZIP64UInt32(0x0606_4b50, to: &trailer)
        appendZIP64UInt64(44, to: &trailer)
        appendZIP64UInt16(45, to: &trailer)
        appendZIP64UInt16(45, to: &trailer)
        appendZIP64UInt32(0, to: &trailer)
        appendZIP64UInt32(0, to: &trailer)
        appendZIP64UInt64(1, to: &trailer)
        appendZIP64UInt64(1, to: &trailer)
        appendZIP64UInt64(UInt64(centralDirectory.count), to: &trailer)
        appendZIP64UInt64(centralDirectoryOffset, to: &trailer)
        appendZIP64UInt32(0x0706_4b50, to: &trailer)
        appendZIP64UInt32(0, to: &trailer)
        appendZIP64UInt64(zip64RecordOffset, to: &trailer)
        appendZIP64UInt32(1, to: &trailer)
        appendZIP64UInt32(0x0605_4b50, to: &trailer)
        appendZIP64UInt16(0, to: &trailer)
        appendZIP64UInt16(0, to: &trailer)
        appendZIP64UInt16(UInt16.max, to: &trailer)
        appendZIP64UInt16(UInt16.max, to: &trailer)
        appendZIP64UInt32(UInt32.max, to: &trailer)
        appendZIP64UInt32(UInt32.max, to: &trailer)
        appendZIP64UInt16(0, to: &trailer)
        try handle.write(contentsOf: trailer)
        try handle.synchronize()
        return url
    }

    /** Returns a complete Android module-backup payload with one owned RawText module. */
    private func androidModuleEntries() -> [(String, Data)] {
        [
            (
                "AndBibleBackupManifest.json",
                Data(#"{"backupType":"MODULE_BACKUP","manifestVersion":1}"#.utf8)
            ),
            (
                "mods.d/zip64.conf",
                Data("""
                [ZIP64]
                DataPath=modules/texts/rawtext/zip64/
                ModDrv=RawText
                Description=ZIP64

                """.utf8)
            ),
            ("modules/texts/rawtext/zip64/ot", Data("module-data".utf8)),
        ]
    }

    /** Returns a minimal EPUB 3 package suitable for installation and index publication. */
    private func minimalEpubEntries(title: String) -> [(String, Data)] {
        zip64StringEntries([
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles>
                <rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """),
            ("OPS/package.opf", """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="book-id">urn:test:zip64</dc:identifier>
                <dc:title>\(title)</dc:title>
                <dc:creator>Archive Test</dc:creator>
                <dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="chapter"/></spine>
            </package>
            """),
            ("OPS/nav.xhtml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
              <body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">Chapter</a></li></ol></nav></body>
            </html>
            """),
            ("OPS/chapter.xhtml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><body><p>ZIP64 content.</p></body></html>
            """),
        ])
    }
}

/** Small ZIP64 fixture plus exact metadata offsets used by malformed-archive tests. */
private struct ZIP64StoredArchiveFixture {
    var data: Data
    let centralDirectoryOffset: Int
    let localHeaderOffsets: [Int]
    let localExtraPayloadOffsets: [Int]
    let centralHeaderOffsets: [Int]
    let centralExtraHeaderOffsets: [Int]
    let centralExtraPayloadOffsets: [Int]
    let zip64RecordOffset: Int
    let locatorOffset: Int
    let endRecordOffset: Int
}

/** Converts string fixtures to UTF-8 ZIP entries. */
private func zip64StringEntries(_ entries: [(String, String)]) -> [(String, Data)] {
    entries.map { ($0.0, Data($0.1.utf8)) }
}

/**
 Builds a standards-shaped stored ZIP whose classic and central-entry fields force ZIP64 parsing.

 - Parameter entries: File names and uncompressed payload bytes.
 - Returns: Archive bytes and mutation offsets for adversarial tests.
 - Side effects: none.
 - Failure modes: Preconditions fail only if a test name exceeds ZIP's 16-bit metadata limit.
 */
private func makeZIP64StoredArchive(entries: [(String, Data)]) -> ZIP64StoredArchiveFixture {
    var archive = Data()
    var localOffsets: [UInt64] = []
    var localHeaderOffsets: [Int] = []
    var localExtraPayloadOffsets: [Int] = []

    for entry in entries {
        let name = Data(entry.0.utf8)
        precondition(name.count <= Int(UInt16.max))
        localHeaderOffsets.append(archive.count)
        localOffsets.append(UInt64(archive.count))
        let checksum = zip64FixtureCRC32(entry.1)
        appendZIP64UInt32(0x0403_4b50, to: &archive)
        appendZIP64UInt16(45, to: &archive)
        appendZIP64UInt16(0, to: &archive)
        appendZIP64UInt16(0, to: &archive)
        appendZIP64UInt16(0, to: &archive)
        appendZIP64UInt16(0, to: &archive)
        appendZIP64UInt32(checksum, to: &archive)
        appendZIP64UInt32(UInt32.max, to: &archive)
        appendZIP64UInt32(UInt32.max, to: &archive)
        appendZIP64UInt16(UInt16(name.count), to: &archive)
        appendZIP64UInt16(20, to: &archive)
        archive.append(name)
        appendZIP64UInt16(0x0001, to: &archive)
        appendZIP64UInt16(16, to: &archive)
        localExtraPayloadOffsets.append(archive.count)
        appendZIP64UInt64(UInt64(entry.1.count), to: &archive)
        appendZIP64UInt64(UInt64(entry.1.count), to: &archive)
        archive.append(entry.1)
    }

    let centralDirectoryOffset = archive.count
    var centralHeaderOffsets: [Int] = []
    var centralExtraHeaderOffsets: [Int] = []
    var centralExtraPayloadOffsets: [Int] = []
    for (index, entry) in entries.enumerated() {
        let name = Data(entry.0.utf8)
        centralHeaderOffsets.append(archive.count)
        appendZIP64UInt32(0x0201_4b50, to: &archive)
        appendZIP64UInt16(45, to: &archive)
        appendZIP64UInt16(45, to: &archive)
        appendZIP64UInt16(0, to: &archive)
        appendZIP64UInt16(0, to: &archive)
        appendZIP64UInt16(0, to: &archive)
        appendZIP64UInt16(0, to: &archive)
        appendZIP64UInt32(zip64FixtureCRC32(entry.1), to: &archive)
        appendZIP64UInt32(UInt32.max, to: &archive)
        appendZIP64UInt32(UInt32.max, to: &archive)
        appendZIP64UInt16(UInt16(name.count), to: &archive)
        appendZIP64UInt16(32, to: &archive)
        appendZIP64UInt16(0, to: &archive)
        appendZIP64UInt16(UInt16.max, to: &archive)
        appendZIP64UInt16(0, to: &archive)
        appendZIP64UInt32(0, to: &archive)
        appendZIP64UInt32(UInt32.max, to: &archive)
        archive.append(name)
        centralExtraHeaderOffsets.append(archive.count)
        appendZIP64UInt16(0x0001, to: &archive)
        appendZIP64UInt16(28, to: &archive)
        centralExtraPayloadOffsets.append(archive.count)
        appendZIP64UInt64(UInt64(entry.1.count), to: &archive)
        appendZIP64UInt64(UInt64(entry.1.count), to: &archive)
        appendZIP64UInt64(localOffsets[index], to: &archive)
        appendZIP64UInt32(0, to: &archive)
    }

    let centralDirectorySize = archive.count - centralDirectoryOffset
    let zip64RecordOffset = archive.count
    appendZIP64UInt32(0x0606_4b50, to: &archive)
    appendZIP64UInt64(44, to: &archive)
    appendZIP64UInt16(45, to: &archive)
    appendZIP64UInt16(45, to: &archive)
    appendZIP64UInt32(0, to: &archive)
    appendZIP64UInt32(0, to: &archive)
    appendZIP64UInt64(UInt64(entries.count), to: &archive)
    appendZIP64UInt64(UInt64(entries.count), to: &archive)
    appendZIP64UInt64(UInt64(centralDirectorySize), to: &archive)
    appendZIP64UInt64(UInt64(centralDirectoryOffset), to: &archive)

    let locatorOffset = archive.count
    appendZIP64UInt32(0x0706_4b50, to: &archive)
    appendZIP64UInt32(0, to: &archive)
    appendZIP64UInt64(UInt64(zip64RecordOffset), to: &archive)
    appendZIP64UInt32(1, to: &archive)

    let endRecordOffset = archive.count
    appendZIP64UInt32(0x0605_4b50, to: &archive)
    appendZIP64UInt16(0, to: &archive)
    appendZIP64UInt16(0, to: &archive)
    appendZIP64UInt16(UInt16.max, to: &archive)
    appendZIP64UInt16(UInt16.max, to: &archive)
    appendZIP64UInt32(UInt32.max, to: &archive)
    appendZIP64UInt32(UInt32.max, to: &archive)
    appendZIP64UInt16(0, to: &archive)

    return ZIP64StoredArchiveFixture(
        data: archive,
        centralDirectoryOffset: centralDirectoryOffset,
        localHeaderOffsets: localHeaderOffsets,
        localExtraPayloadOffsets: localExtraPayloadOffsets,
        centralHeaderOffsets: centralHeaderOffsets,
        centralExtraHeaderOffsets: centralExtraHeaderOffsets,
        centralExtraPayloadOffsets: centralExtraPayloadOffsets,
        zip64RecordOffset: zip64RecordOffset,
        locatorOffset: locatorOffset,
        endRecordOffset: endRecordOffset
    )
}

/** Computes the standard ZIP CRC32 for one fixture payload. */
private func zip64FixtureCRC32(_ data: Data) -> UInt32 {
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

/** Appends one little-endian 16-bit integer. */
private func appendZIP64UInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
}

/** Appends one little-endian 32-bit integer. */
private func appendZIP64UInt32(_ value: UInt32, to data: inout Data) {
    for shift in stride(from: 0, through: 24, by: 8) {
        data.append(UInt8((value >> UInt32(shift)) & 0xff))
    }
}

/** Appends one little-endian 64-bit integer. */
private func appendZIP64UInt64(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 0, through: 56, by: 8) {
        data.append(UInt8((value >> UInt64(shift)) & 0xff))
    }
}

/** Replaces one little-endian 16-bit integer at an exact fixture offset. */
private func replaceZIP64UInt16(_ value: UInt16, in data: inout Data, at offset: Int) {
    var bytes = Data()
    appendZIP64UInt16(value, to: &bytes)
    data.replaceSubrange(offset..<(offset + 2), with: bytes)
}

/** Replaces one little-endian 32-bit integer at an exact fixture offset. */
private func replaceZIP64UInt32(_ value: UInt32, in data: inout Data, at offset: Int) {
    var bytes = Data()
    appendZIP64UInt32(value, to: &bytes)
    data.replaceSubrange(offset..<(offset + 4), with: bytes)
}

/** Replaces one little-endian 64-bit integer at an exact fixture offset. */
private func replaceZIP64UInt64(_ value: UInt64, in data: inout Data, at offset: Int) {
    var bytes = Data()
    appendZIP64UInt64(value, to: &bytes)
    data.replaceSubrange(offset..<(offset + 8), with: bytes)
}
