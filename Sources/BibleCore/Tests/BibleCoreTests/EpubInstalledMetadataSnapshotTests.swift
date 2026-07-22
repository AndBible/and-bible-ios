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

        XCTAssertEqual(try fileSnapshot(under: library), before)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.identifier, identifier)
        XCTAssertEqual(books.first?.initials, "Epub-Source_Book_epub")
        XCTAssertEqual(books.first?.sourceFileName, "Source Book.epub")
        XCTAssertEqual(books.first?.title, "Snapshot Android Book")
        XCTAssertEqual(books.first?.author, "Android Fixture")
        XCTAssertEqual(books.first?.language, "en")
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
