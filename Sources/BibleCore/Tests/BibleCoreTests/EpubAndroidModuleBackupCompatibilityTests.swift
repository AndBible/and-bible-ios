import Foundation
import XCTest
@testable import BibleCore

/**
 End-to-end compatibility tests for EPUB directories restored from Android MODULE_BACKUP archives.

 Each test installs a real OCF/OPF tree into an isolated native library. Optimized fixtures use
 Android's Room v1 schema, gzip filenames, noncontiguous persisted fragment keys, native link tags,
 BVA ordinals, and optional FTS database so the suite protects data identity as well as readability.
 */
final class EpubAndroidModuleBackupCompatibilityTests: XCTestCase {
    /// Caller-owned temporary roots removed after every test.
    private var temporaryURLs: [URL] = []

    /**
     Removes every Android fixture and native library created by the current test.

     - Side effects: Recursively deletes recorded temporary paths.
     - Failure modes: Cleanup errors are ignored so they cannot hide the behavior assertion that
       originally failed.
     */
    override func tearDown() {
        for url in temporaryURLs.reversed() {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    /**
     Verifies an unoptimized Android EPUB directory uses the ordinary native package pipeline.

     Setup writes original spine XHTML, navigation, CSS, and an image beneath an exact display-name
     directory. Successful import must derive Android initials from that directory, browse both
     pages, rewrite its internal link/resource, and build searchable BVA text. A failure means
     MODULE_BACKUP routing cannot restore EPUBs captured before Android first opens/optimizes them.
     */
    func testRawAndroidEpubTreeRestoresBrowseableStableIdentity() throws {
        let root = try makeTemporaryDirectory(named: "raw-android-epub")
        let androidTree = root.appendingPathComponent("epub/Raw Book.epub", isDirectory: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try EpubAndroidModuleBackupTestFixture.writeRawTree(at: androidTree, label: "Raw")

        let identifier = try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: androidTree,
            libraryRootURL: library
        )
        let reader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))
        XCTAssertEqual(reader.initials, "Epub-Raw_Book_epub")
        XCTAssertEqual(reader.sourceFileName, "Raw Book.epub")
        XCTAssertEqual(reader.title, "Raw Android Book")
        XCTAssertEqual(reader.tableOfContents().map(\.title), ["Opening", "Target"])

        let first = try XCTUnwrap(reader.content(forKey: "chapter-1"))
        XCTAssertEqual(first.persistedKey, "1")
        XCTAssertTrue(first.html.contains("Raw raw opening."))
        XCTAssertTrue(first.html.contains("<epubRef"))
        let resourceString = EpubResourceLocator.resourceURLString(
            identity: reader.resourceIdentity,
            canonicalPath: "OPS/images/cover.png"
        )
        XCTAssertTrue(first.html.contains(resourceString))
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(reader.resourceURL(for: "OPS/images/cover.png"))),
            Data("Raw-image".utf8)
        )
        XCTAssertEqual(
            try reader.searchResults(query: "Raw", epubMode: .allWords).first?.key,
            "1"
        )
    }

    /**
     Verifies package metadata ignores same-local-name elements outside Dublin Core.

     The OPF places a foreign `title` before the canonical Dublin Core title and supplies all three
     Android registration fields. Metadata discovery must preserve the canonical values instead of
     accepting the first matching local name from an unrelated namespace.

     - Side effects: Creates and removes one raw EPUB fixture directory.
     - Failure modes: Fixture I/O is thrown; namespace or fallback regressions fail exact assertions.
     */
    func testAndroidModuleMetadataUsesExactDublinCoreElements() throws {
        let root = try makeTemporaryDirectory(named: "android-epub-metadata")
        let androidTree = root.appendingPathComponent("epub/Metadata.epub", isDirectory: true)
        try EpubAndroidModuleBackupTestFixture.writeRawTree(at: androidTree, label: "Metadata")
        let packageURL = androidTree.appendingPathComponent("OPS/package.opf")
        let package = try String(contentsOf: packageURL, encoding: .utf8)
            .replacingOccurrences(
                of: "<dc:title>Metadata Android Book</dc:title>",
                with: "<wrong:title xmlns:wrong=\"urn:not-dublin-core\">Wrong Title</wrong:title>\n    <dc:title>Metadata Android Book</dc:title>\n    <dc:description>Canonical description</dc:description>"
            )
            .replacingOccurrences(
                of: "<dc:language>en</dc:language>",
                with: "<dc:language>pt-BR</dc:language>"
        )
        try Data(package.utf8).write(to: packageURL, options: .atomic)

        let packageDocument = try EpubPackageDocumentParser.parse(packageRootURL: androidTree)
        let metadata = try EpubReader.androidModuleMetadata(epubDirectoryURL: androidTree)

        XCTAssertEqual(packageDocument.title, "Metadata Android Book")
        XCTAssertEqual(packageDocument.description, "Canonical description")
        XCTAssertEqual(packageDocument.language, "pt-BR")
        XCTAssertEqual(metadata.title, "Metadata Android Book")
        XCTAssertEqual(metadata.description, "Canonical description")
        XCTAssertEqual(metadata.language, "pt-BR")
    }

    /**
     Verifies SQLite-looking package resources survive unless their name belongs to this book.

     Android excludes only optimizer artifacts whose exact root filename embeds the current EPUB
     initials. A manifest-owned resource with another identity-like name remains ordinary content
     and must be copied into the immutable generation byte-for-byte.

     - Side effects: Creates one raw EPUB fixture and one isolated native library, then removes both.
     - Failure modes: Fixture or install errors are thrown; over-broad optimizer filtering leaves the
       manifest resource missing and fails the byte assertion.
     */
    func testAndroidEpubPreservesSQLiteLookingPackageResourceForAnotherIdentity() throws {
        let root = try makeTemporaryDirectory(named: "android-epub-sqlite-resource")
        let androidTree = root.appendingPathComponent(
            "epub/Artifact Names.epub",
            isDirectory: true
        )
        let library = root.appendingPathComponent("library", isDirectory: true)
        try EpubAndroidModuleBackupTestFixture.writeRawTree(at: androidTree, label: "Artifact")
        let resourceName = "epub-Epub-Another_Book_epub.sqlite3"
        let resourceData = Data("manifest-owned sqlite-looking bytes".utf8)
        try resourceData.write(to: androidTree.appendingPathComponent(resourceName))
        let packageURL = androidTree.appendingPathComponent("OPS/package.opf")
        let package = try String(contentsOf: packageURL, encoding: .utf8)
            .replacingOccurrences(
                of: "</manifest>",
                with: "  <item id=\"sqlite-resource\" href=\"../\(resourceName)\" media-type=\"application/octet-stream\"/>\n  </manifest>"
            )
        try Data(package.utf8).write(to: packageURL, options: .atomic)

        let identifier = try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: androidTree,
            libraryRootURL: library
        )
        let reader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))

        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(reader.resourceURL(for: resourceName))),
            resourceData
        )
    }

    /**
     Verifies Android's identity-named Room archive restores deleted spine files without renumbering.

     The fixture omits both original XHTML documents, stores fragments as keys 7 and 12, and includes
     Android's optional search database. Import must preserve those exact persisted keys, TOC mapping,
     adjacency, BVA search, and source filename. A failure breaks restored generic bookmarks or leaves
     an Android-optimized backup visible but unreadable on iOS.
     */
    func testOptimizedAndroidEpubWithoutOriginalSpinePreservesPersistedKeysAndSearch() throws {
        let root = try makeTemporaryDirectory(named: "optimized-android-epub")
        let displayName = "Optimized Book.epub"
        let androidTree = root.appendingPathComponent("epub/\(displayName)", isDirectory: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        let initials = EpubReader.initials(forDisplayFileName: displayName)
        try EpubAndroidModuleBackupTestFixture.writeOptimizedTree(
            at: androidTree,
            label: "Optimized",
            databaseArchiveName: "epub-\(initials).sqlite3.gz",
            includeSearchDatabase: true
        )

        let identifier = try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: androidTree,
            libraryRootURL: library
        )
        let reader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))
        XCTAssertEqual(reader.initials, initials)
        XCTAssertEqual(reader.sourceFileName, displayName)
        XCTAssertEqual(reader.tableOfContents().map(\.key), ["7#start", "12#target"])
        XCTAssertEqual(reader.firstKey(), "7#start")
        XCTAssertEqual(reader.nextKey(after: "7"), "12")
        XCTAssertEqual(reader.previousKey(before: "12"), "7")
        XCTAssertEqual(reader.content(forKey: "chapter-1#start")?.persistedKey, "7")
        XCTAssertEqual(reader.content(forKey: "chapter-2#target")?.persistedKey, "12")
        let results = try reader.searchResults(query: "Optimized", epubMode: .allWords)
        XCTAssertEqual(results.map(\.key), ["7", "12"])
        XCTAssertEqual(results.map(\.ordinal), [0, 0])
    }

    /**
     Verifies optimized links/media remain exact and generation-contained, while escapes fail closed.

     The valid fixture carries Android `epubRef`, `epubA`, `/epub/...` image paths, and Room stylesheet
     rows. Native HTML/CSS must use this reader's immutable route identity and internal links must
     resolve to key 12. A sibling fixture then replaces the image with traversal markup; publication
     must fail before any manifest appears. Failure permits cross-book resources or fallback links.
     */
    func testOptimizedAndroidLinksAndResourcesStayGenerationScopedAndRejectEscapes() throws {
        let root = try makeTemporaryDirectory(named: "optimized-links-resources")
        let validTree = root.appendingPathComponent("epub/Linked.epub", isDirectory: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try EpubAndroidModuleBackupTestFixture.writeOptimizedTree(at: validTree, label: "Linked")

        let identifier = try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: validTree,
            libraryRootURL: library
        )
        let reader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))
        let first = try XCTUnwrap(reader.content(forKey: "7"))
        let imageURL = EpubResourceLocator.resourceURLString(
            identity: reader.resourceIdentity,
            canonicalPath: "OPS/images/cover.png"
        )
        let fontURL = EpubResourceLocator.resourceURLString(
            identity: reader.resourceIdentity,
            canonicalPath: "OPS/fonts/reader.woff2"
        )
        XCTAssertTrue(first.html.contains(#"to-key="chapter-2""#))
        XCTAssertTrue(first.html.contains(#"to-id="target""#))
        XCTAssertTrue(first.html.contains("https://example.org/reader"))
        XCTAssertTrue(first.html.contains(imageURL))
        XCTAssertTrue(first.html.contains("font-weight: bold"))
        XCTAssertFalse(first.html.contains("color: red"))
        XCTAssertFalse(first.html.contains("background-image"))
        XCTAssertEqual(reader.content(originalKey: "chapter-2", htmlID: "target")?.key, "12")
        let style = try XCTUnwrap(String(data: reader.styleSheetData(forKey: "7"), encoding: .utf8))
        XCTAssertTrue(style.contains(fontURL))
        XCTAssertFalse(style.contains("color: blue"))

        let escapingTree = root.appendingPathComponent("epub/Escaping.epub", isDirectory: true)
        try EpubAndroidModuleBackupTestFixture.writeOptimizedTree(at: escapingTree, label: "Escaping")
        let escapingFragment = """
        <div xmlns="http://www.w3.org/1999/xhtml">
          <BVA ordinal="0">Escaping optimized opening.</BVA>
          <BVA ordinal="1"><img src="/epub/../../outside.png"/></BVA>
          <epubRef to-key="chapter-2" to-id="target">Target</epubRef>
          <span id="start">Start</span>
        </div>
        """
        try RemoteSyncArchiveStagingService.gzip(Data(escapingFragment.utf8)).write(
            to: escapingTree.appendingPathComponent("optimized/007.xhtml.gz")
        )
        XCTAssertThrowsError(try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: escapingTree,
            libraryRootURL: library
        ))
        XCTAssertFalse(EpubReader.installedEpubs(libraryRootURL: library).contains {
            $0.sourceFileName == "Escaping.epub"
        })
    }

    /**
     Verifies corrupt Android Room and XHTML gzip members never publish a partial generation.

     Separate optimized fixtures corrupt the database archive and one mapped fragment after all OPF
     resources are valid. Both imports must report decompression failure and leave the library empty.
     A failure means a damaged MODULE_BACKUP can replace a readable generation or surface as a book
     whose pages fail only after the user opens it.
     */
    func testCorruptAndroidOptimizedGzipFailsBeforePublication() throws {
        let root = try makeTemporaryDirectory(named: "optimized-gzip-corruption")
        let library = root.appendingPathComponent("library", isDirectory: true)

        let corruptDatabaseTree = root.appendingPathComponent("epub/Corrupt Database.epub", isDirectory: true)
        try EpubAndroidModuleBackupTestFixture.writeOptimizedTree(
            at: corruptDatabaseTree,
            label: "Database"
        )
        try Data("not-gzip".utf8).write(
            to: corruptDatabaseTree.appendingPathComponent("optimized.sqlite3.gz")
        )
        XCTAssertThrowsError(try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: corruptDatabaseTree,
            libraryRootURL: library
        )) { error in
            XCTAssertEqual(error as? EpubError, .decompressionFailed)
        }

        let corruptFragmentTree = root.appendingPathComponent("epub/Corrupt Fragment.epub", isDirectory: true)
        try EpubAndroidModuleBackupTestFixture.writeOptimizedTree(
            at: corruptFragmentTree,
            label: "Fragment"
        )
        let corruptFragmentURL = corruptFragmentTree.appendingPathComponent("optimized/012.xhtml.gz")
        var corruptFragmentData = try Data(contentsOf: corruptFragmentURL)
        let checksumIndex = corruptFragmentData.index(corruptFragmentData.endIndex, offsetBy: -8)
        corruptFragmentData[checksumIndex] ^= 0xff
        try corruptFragmentData.write(to: corruptFragmentURL)
        XCTAssertThrowsError(try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: corruptFragmentTree,
            libraryRootURL: library
        )) { error in
            XCTAssertEqual(error as? EpubError, .decompressionFailed)
        }
        XCTAssertTrue(EpubReader.installedEpubs(libraryRootURL: library).isEmpty)
    }

    /**
     Verifies database identity and fragment paths must exactly match the Android display-name tree.

     One fixture uses an `epub-<initials>.sqlite3.gz` name belonging to another module; another moves
     key 12's gzip bytes to key 13 while leaving Room unchanged. Both must fail without publication.
     A failure could restore another book's database or bind persisted Android keys to the wrong HTML.
     */
    func testAndroidOptimizedDatabaseAndFragmentPathMismatchesFailClosed() throws {
        let root = try makeTemporaryDirectory(named: "optimized-path-mismatch")
        let library = root.appendingPathComponent("library", isDirectory: true)
        let wrongDatabaseTree = root.appendingPathComponent("epub/Expected.epub", isDirectory: true)
        try EpubAndroidModuleBackupTestFixture.writeOptimizedTree(
            at: wrongDatabaseTree,
            label: "Wrong Database",
            databaseArchiveName: "epub-Epub-Another_epub.sqlite3.gz"
        )
        XCTAssertThrowsError(try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: wrongDatabaseTree,
            libraryRootURL: library
        )) { error in
            guard let epubError = error as? EpubError,
                  case .invalidEpub(let message) = epubError else {
                return XCTFail("Expected an invalid EPUB identity mismatch")
            }
            XCTAssertTrue(message.contains("filename does not match"))
        }

        let wrongFragmentTree = root.appendingPathComponent("epub/Fragment Paths.epub", isDirectory: true)
        try EpubAndroidModuleBackupTestFixture.writeOptimizedTree(
            at: wrongFragmentTree,
            label: "Wrong Fragment"
        )
        try FileManager.default.moveItem(
            at: wrongFragmentTree.appendingPathComponent("optimized/012.xhtml.gz"),
            to: wrongFragmentTree.appendingPathComponent("optimized/013.xhtml.gz")
        )
        XCTAssertThrowsError(try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: wrongFragmentTree,
            libraryRootURL: library
        ))
        XCTAssertTrue(EpubReader.installedEpubs(libraryRootURL: library).isEmpty)
    }

    /**
     Characterizes Android-parity reader identity across immutable replacement generations.

     A source reader opens the first generation, then the exact same display-name tree is reinstalled
     with replacement content. A fresh clone-by-identity must select the current generation while the
     source remains on its leased generation; generation-bearing resource routes must serve matching
     bytes. After both close, two reopened readers must converge on the replacement generation. A
     failure breaks pane cloning, controller resource routing, or same-document backup replacement.
     */
    func testOpenSourceReaderRetainsItsGenerationWhileCloneAndReopenedReadersUseReplacement() throws {
        let root = try makeTemporaryDirectory(named: "optimized-replacement-isolation")
        let androidTree = root.appendingPathComponent("epub/Replace Me.epub", isDirectory: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try EpubAndroidModuleBackupTestFixture.writeOptimizedTree(at: androidTree, label: "First")
        let identifier = try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: androidTree,
            libraryRootURL: library
        )

        var sourceReader: EpubReader? = try XCTUnwrap(EpubReader(
            identifier: identifier,
            libraryRootURL: library
        ))
        let firstGeneration = try XCTUnwrap(sourceReader?.generationIdentifier)
        let firstResourceURL = EpubResourceLocator.resourceURLString(
            identity: try XCTUnwrap(sourceReader?.resourceIdentity),
            canonicalPath: "OPS/images/cover.png"
        )
        XCTAssertTrue(sourceReader?.content(forKey: "7")?.html.contains(firstResourceURL) == true)

        try EpubAndroidModuleBackupTestFixture.writeOptimizedTree(at: androidTree, label: "Second")
        let replacementIdentifier = try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: androidTree,
            libraryRootURL: library
        )
        XCTAssertEqual(replacementIdentifier, identifier)

        var cloneReader: EpubReader? = try XCTUnwrap(EpubReader(
            identifier: identifier,
            libraryRootURL: library
        ))
        let secondGeneration = try XCTUnwrap(cloneReader?.generationIdentifier)
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertTrue(sourceReader?.content(forKey: "7")?.html.contains("First optimized") == true)
        XCTAssertTrue(cloneReader?.content(forKey: "7")?.html.contains("Second optimized") == true)

        let secondResourceURL = EpubResourceLocator.resourceURLString(
            identity: try XCTUnwrap(cloneReader?.resourceIdentity),
            canonicalPath: "OPS/images/cover.png"
        )
        XCTAssertNotEqual(firstResourceURL, secondResourceURL)
        XCTAssertTrue(cloneReader?.content(forKey: "7")?.html.contains(secondResourceURL) == true)
        var sourceRouteReader: EpubReader? = try XCTUnwrap(EpubReader(
            initials: try XCTUnwrap(sourceReader?.initials),
            generationIdentifier: firstGeneration,
            libraryRootURL: library
        ))
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(sourceRouteReader?.resourceURL(for: "OPS/images/cover.png"))),
            Data("First-image".utf8)
        )
        let cloneRouteReader = try XCTUnwrap(EpubReader(
            initials: try XCTUnwrap(cloneReader?.initials),
            generationIdentifier: secondGeneration,
            libraryRootURL: library
        ))
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(cloneRouteReader.resourceURL(for: "OPS/images/cover.png"))),
            Data("Second-image".utf8)
        )

        sourceRouteReader = nil
        sourceReader = nil
        cloneReader = nil
        let reopenedSource = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))
        let reopenedClone = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))
        XCTAssertEqual(reopenedSource.generationIdentifier, secondGeneration)
        XCTAssertEqual(reopenedClone.generationIdentifier, secondGeneration)
        XCTAssertTrue(reopenedSource.content(forKey: "7")?.html.contains("Second optimized") == true)
        XCTAssertTrue(reopenedClone.content(forKey: "7")?.html.contains(secondResourceURL) == true)
    }

    /**
     Creates and records one isolated temporary directory.

     - Parameter name: Readable test prefix used only in the temporary path.
     - Returns: Empty directory unique to this test process.
     - Side effects: Creates the directory and records it for teardown.
     - Throws: File-system failures.
     */
    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }
}
