import Foundation
import XCTest
@testable import BibleCore

/** Verifies nonmutating EPUB registration inventory for backup preflight. */
final class EpubInstalledMetadataSnapshotTests: XCTestCase {
    /**
     Reads one published generation without changing pointers, generations, or index bytes.

     - Side effects: Creates and removes isolated Android-tree and EPUB-library fixtures.
     - Failure modes: Fixture publication or snapshot I/O is surfaced through XCTest.
     */
    func testSnapshotReadsPublishedMetadataWithoutRepairingLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-metadata-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source Book.epub", isDirectory: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try EpubAndroidModuleBackupTestFixture.writeRawTree(at: source, label: "Snapshot")

        let identifier = try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: source,
            libraryRootURL: library
        )
        let before = try fileSnapshot(under: library)

        let books = EpubReader.readOnlyInstalledEpubs(libraryRootURL: library)
        let strictBooks = try EpubReader.throwingReadOnlyInstalledEpubs(
            libraryRootURL: library
        )

        XCTAssertEqual(try fileSnapshot(under: library), before)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.identifier, identifier)
        XCTAssertEqual(books.first?.initials, "Epub-Source_Book_epub")
        XCTAssertEqual(books.first?.sourceFileName, "Source Book.epub")
        XCTAssertEqual(books.first?.title, "Snapshot Android Book")
        XCTAssertEqual(books.first?.author, "Android Fixture")
        XCTAssertEqual(books.first?.language, "en")
        XCTAssertEqual(strictBooks, books)
    }

    /**
     Proves a leading-dot Android source name cannot create a hidden iOS registration pointer.

     - Setup: Publishes `.Hidden Book.epub`, whose provider-visible basename Android would include
       in raw `File.listFiles()` enumeration.
     - Expected result: The shared install-candidate sanitizer produces a visible stable identifier,
       publication uses that exact visible pointer, and both strict and permissive registration
       snapshots retain the owner while continuing to skip the internal `.epub-generations` tree.
     - Failure meaning: `.skipsHiddenFiles` could omit a valid installed owner and admit a later
       collision, so the registration snapshots would need to enumerate and classify hidden entries.
     - Side effects: Creates and removes one isolated native EPUB generation.
     */
    func testLeadingDotSourcePublishesVisibleIdentifierObservedByRegistrationSnapshots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-leading-dot-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(".Hidden Book.epub", isDirectory: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try EpubAndroidModuleBackupTestFixture.writeRawTree(at: source, label: "Hidden")
        let candidate = EpubReader.installCandidate(forEpubURL: source)

        XCTAssertFalse(candidate.identifier.hasPrefix("."))
        let identifier = try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: source,
            libraryRootURL: library
        )
        XCTAssertEqual(identifier, candidate.identifier)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: EpubReader.generationManifestURL(
                identifier: identifier,
                libraryRootURL: library
            ).path
        ))

        XCTAssertEqual(
            try EpubReader.throwingReadOnlyInstalledEpubs(
                libraryRootURL: library
            ).map(\.identifier),
            [identifier]
        )
        XCTAssertEqual(
            EpubReader.readOnlyInstalledEpubs(
                libraryRootURL: library
            ).map(\.identifier),
            [identifier]
        )
    }

    /**
     Preserves filesystem enumeration through every EPUB inventory used for first-owner replay.

     - Setup: Publishes Alpha and Zeta packages, then supplies their pointer files in Zeta-first
       order even though a source-filename sort would put Alpha first.
     - Expected result: Strict admission, permissive read-only inventory, and normal runtime
       inventory all retain the injected filesystem order.
     - Failure meaning: One iOS consumer is inventing an order Android's raw `File.listFiles()` does
       not impose, so case-variant collisions can resolve to different owners by call path.
     - Side effects: Creates and removes two isolated native EPUB generations.
     */
    func testInventoriesPreserveFilesystemEnumerationOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-enumeration-order-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library", isDirectory: true)
        let alphaSource = root.appendingPathComponent("Alpha.epub", isDirectory: true)
        let zetaSource = root.appendingPathComponent("Zeta.epub", isDirectory: true)
        try EpubAndroidModuleBackupTestFixture.writeRawTree(at: alphaSource, label: "Alpha")
        try EpubAndroidModuleBackupTestFixture.writeRawTree(at: zetaSource, label: "Zeta")
        let alphaIdentifier = try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: alphaSource,
            libraryRootURL: library
        )
        let zetaIdentifier = try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: zetaSource,
            libraryRootURL: library
        )
        let orderedFileManager = EpubPointerOrderFileManager(
            libraryRootURL: library,
            pointerNames: [
                zetaIdentifier + EpubReader.generationManifestSuffix,
                alphaIdentifier + EpubReader.generationManifestSuffix,
            ]
        )

        let strict = try EpubReader.throwingReadOnlyInstalledEpubs(
            libraryRootURL: library,
            fileManager: orderedFileManager
        )
        let permissive = EpubReader.readOnlyInstalledEpubs(
            libraryRootURL: library,
            fileManager: orderedFileManager
        )
        let runtime = EpubReader.installedEpubs(
            libraryRootURL: library,
            fileManager: orderedFileManager
        )

        let expected = ["Zeta.epub", "Alpha.epub"]
        XCTAssertEqual(strict.map(\.sourceFileName), expected)
        XCTAssertEqual(permissive.map(\.sourceFileName), expected)
        XCTAssertEqual(runtime.map(\.sourceFileName), expected)
    }

    /**
     Treats an absent library as an empty registry without creating its root.

     - Setup: Points the strict registration snapshot at a path that has never existed.
     - Expected: The result is empty and the path remains absent after the call.
     - Failure meaning: Read-only admission can create app storage before any candidate is admitted.
     - Side effects: Reads one nonexistent temporary path and creates no files.
     */
    func testStrictSnapshotLeavesAbsentLibraryRootAbsent() throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent(
            "absent-epub-registration-\(UUID().uuidString)",
            isDirectory: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))

        XCTAssertEqual(
            try EpubReader.throwingReadOnlyInstalledEpubs(libraryRootURL: library),
            []
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    /**
     Fails a corrupt existing registry closed without repairing, pruning, or staging artifacts.

     - Setup: Creates one malformed current-generation pointer and snapshots every byte before the
       strict read.
     - Expected: Decoding throws and the complete library snapshot remains byte-identical.
     - Failure meaning: Admission can suppress an earlier EPUB owner or mutate corrupt state while
       deciding whether a new identity is safe.
     - Side effects: Creates and removes one isolated corrupt library fixture.
     */
    func testStrictSnapshotPreservesCorruptRegistryWhileThrowing() throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent(
            "corrupt-epub-registration-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: library) }
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let pointer = library.appendingPathComponent(
            "corrupt\(EpubReader.generationManifestSuffix)"
        )
        try Data("not-json".utf8).write(to: pointer)
        let before = try fileSnapshot(under: library)

        XCTAssertThrowsError(try EpubReader.throwingReadOnlyInstalledEpubs(
            libraryRootURL: library
        ))

        XCTAssertEqual(try fileSnapshot(under: library), before)
    }

    /** Captures every regular library file for a byte-exact zero-mutation assertion. */
    private func fileSnapshot(under root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() {
            let url = root.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            result[path] = try Data(contentsOf: url)
        }
        return result
    }
}

/** File manager that makes one library root expose a deterministic Android-style pointer order. */
private final class EpubPointerOrderFileManager: FileManager, @unchecked Sendable {
    private let libraryRootPath: String
    private let pointerNames: [String]

    /**
     Creates a read-through filesystem whose target-root results put named pointers first.

     - Parameters:
       - libraryRootURL: Exact library root whose enumeration is controlled.
       - pointerNames: Pointer filenames in the order a native filesystem may return them.
     - Side effects: None; all reads and writes otherwise delegate to `FileManager`.
     - Failure modes: None during construction.
     */
    init(libraryRootURL: URL, pointerNames: [String]) {
        self.libraryRootPath = libraryRootURL.standardizedFileURL.path
        self.pointerNames = pointerNames
        super.init()
    }

    /** Returns target-root children in the injected order while preserving every unnamed child. */
    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        let children = try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
        guard url.standardizedFileURL.path == libraryRootPath else { return children }
        let requested = Set(pointerNames)
        let byName = Dictionary(uniqueKeysWithValues: children.map { ($0.lastPathComponent, $0) })
        return pointerNames.compactMap { byName[$0] }
            + children.filter { !requested.contains($0.lastPathComponent) }
    }
}
