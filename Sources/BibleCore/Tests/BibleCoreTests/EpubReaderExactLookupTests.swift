import Foundation
import XCTest
@testable import BibleCore

/** Exact persisted-key tests for EPUB bookmark navigation. */
final class EpubReaderExactLookupTests: XCTestCase {
    /// Temporary archive and library roots removed after each test.
    private var temporaryURLs: [URL] = []

    /** Removes every filesystem fixture created by the current test. */
    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    /**
     Verifies strict lookup accepts only the exact numeric key persisted by PageManager.

     The same fragment remains reachable through manifest-id and href compatibility aliases, proving
     those aliases exist and are deliberately rejected by the strict API. A missing numeric key and
     alternate decimal spelling also fail rather than substituting the first/current fragment.
     */
    func testExactPersistedKeyLookupRejectsAliasesAndMissingKeysWithoutFallback() throws {
        let library = try makeTemporaryDirectory(named: "exact-key-library")
        let archive = try writeArchive(named: "Exact.epub")
        let identifier = try EpubReader.install(epubURL: archive, libraryRootURL: library)
        let reader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))

        let exact = try reader.exactContent(forPersistedKey: "1")
        XCTAssertEqual(exact.persistedKey, "1")
        XCTAssertTrue(exact.html.contains("Exact persisted content"))
        XCTAssertEqual(reader.content(forKey: "chapter-1")?.persistedKey, "1")
        XCTAssertEqual(reader.content(forKey: exact.href)?.persistedKey, "1")

        for alias in ["chapter-1", exact.href, "01", "1#opening"] {
            XCTAssertThrowsError(try reader.exactContent(forPersistedKey: alias)) { error in
                XCTAssertEqual(error as? EpubPersistedKeyLookupError, .invalidPersistedKey(alias))
            }
        }
        XCTAssertThrowsError(try reader.exactContent(forPersistedKey: "999")) { error in
            XCTAssertEqual(error as? EpubPersistedKeyLookupError, .contentNotFound("999"))
        }
    }

    /** Creates and records an isolated temporary directory. */
    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    /**
     Writes a minimal real EPUB 3 archive with one manifest-addressable spine entry.

     - Parameter name: Archive filename retained as EPUB source identity.
     - Returns: URL of the generated stored ZIP archive.
     - Side effects: Creates a temporary directory and writes one archive file.
     - Failure modes: Rethrows ZIP construction and file-write errors.
     */
    private func writeArchive(named name: String) throws -> URL {
        let directory = try makeTemporaryDirectory(named: "exact-key-archive")
        let archiveURL = directory.appendingPathComponent(name, isDirectory: false)
        let entries: [(String, String)] = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles>
                <rootfile media-type="application/oebps-package+xml" full-path="OPS/package.opf"/>
              </rootfiles>
            </container>
            """),
            ("OPS/package.opf", """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="book-id">urn:test:exact-key</dc:identifier>
                <dc:title>Exact Key</dc:title>
                <dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="chapter-1" href="text/chapter1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="chapter-1"/></spine>
            </package>
            """),
            ("OPS/nav.xhtml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><title>Contents</title></head>
              <body><nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops"><ol>
                <li><a href="text/chapter1.xhtml#opening">Opening</a></li>
              </ol></nav></body>
            </html>
            """),
            ("OPS/text/chapter1.xhtml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><title>Opening</title></head>
              <body><p id="opening">Exact persisted content.</p></body>
            </html>
            """),
        ]
        let data = try ZipArchiveWriter.storedArchive(entries: entries.map {
            ZipArchiveWriterEntry(name: $0.0, data: Data($0.1.utf8))
        })
        try data.write(to: archiveURL, options: .atomic)
        return archiveURL
    }
}
