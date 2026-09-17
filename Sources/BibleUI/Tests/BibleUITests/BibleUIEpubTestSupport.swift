// BibleUIEpubTestSupport.swift -- low-level EPUB fixtures isolated from production publication APIs

import Foundation
import SwordKit
@testable import BibleCore

/**
 Installs one EPUB fixture into the app-default test library without constructing UI import state.

 - Parameter epubURL: Test-owned archive URL that remains readable for the duration of installation.
 - Returns: Stable fixture identifier used by `EpubReader` open and cleanup calls.
 - Side effects: Acquires the production module-store mutation coordinator, writes one staged EPUB
   generation into the simulator test container, and publishes its current-generation pointer.
 - Throws: Propagates archive, validation, indexing, coordinator, and filesystem failures.
 - Important: This helper exists only in the `BibleUITests` target. It intentionally supplies a
   no-op registry validator so controller tests can seed backend state without restoring the removed
   production bypass. Every caller must delete the returned identifier or reset its app container.
 */
func installDefaultLibraryEpubFixture(epubURL: URL) throws -> String {
    try EpubReader.install(
        epubURL: epubURL,
        moduleStoreRootURL: URL(
            fileURLWithPath: SwordManager.defaultModulePath(),
            isDirectory: true
        ),
        admittingCandidateWith: { _ in }
    )
}

/** Writes a two-spine EPUB whose second href canonicalizes to persisted key `2`. */
func makeDefaultLibraryEpubArchiveFixture(title: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("epub-shared-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let archiveURL = directory.appendingPathComponent("\(title).epub")
    let entries: [(String, String)] = [
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
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(title)</dc:title><dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="first" href="text/first.xhtml" media-type="application/xhtml+xml"/>
            <item id="second" href="text/second.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="first"/><itemref idref="second"/></spine>
        </package>
        """),
        ("OPS/nav.xhtml", """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <body><nav epub:type="toc"><ol>
            <li><a href="text/first.xhtml#start">First</a></li>
            <li><a href="text/second.xhtml#target">Second</a></li>
          </ol></nav></body>
        </html>
        """),
        ("OPS/text/first.xhtml", """
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
          <section id="start"><p>First shared fixture section.</p></section>
        </body></html>
        """),
        ("OPS/text/second.xhtml", """
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
          <section id="target"><p>Second shared fixture section.</p></section>
        </body></html>
        """),
    ]
    let archive = try ZipArchiveWriter.storedArchive(entries: entries.map {
        ZipArchiveWriterEntry(name: $0.0, data: Data($0.1.utf8))
    })
    try archive.write(to: archiveURL, options: .atomic)
    return archiveURL
}
