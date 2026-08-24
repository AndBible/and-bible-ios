import Foundation
import SQLite3
import SwiftData
import XCTest

@testable import BibleCore
@testable import BibleUI
@testable import SwordKit

/**
 Exercises AI source capture against real persisted backend formats.

 The fixtures use native RawLD conversion, read-only MyBible SQLite readers, SwiftData My
 Documents storage, and an installed EPUB generation. They protect source identity, exact keys,
 source-format conversion, generic anchor policy, and partial-content behavior below the resolver.
 */
final class AIReaderSourceBackendTests: XCTestCase {
  /**
   Verifies a real SQLite Bible performs one passage-level canonical projection across a boundary.

   - Setup: Builds a MyBible database with Genesis 1:31 and 2:1 containing whitespace and markup.
   - Expected result: Source ordinals/OSIS cross the chapter boundary, canonical text is projected
     once for the passage, structured Bible XML has no generic `BVA`, and `Int.max` is rejected.
   - Failure meaning: SQLite AI context can trim/join verses differently, inject generic anchors,
     lose source identity, or perform unbounded bridge work.
   - Side effects: Creates and removes one temporary SQLite database.
   */
  func testSQLiteBibleCapturesCrossChapterSourceWithoutGenericAnchors() throws {
    let fixture = try makeSQLiteModule(
      fileName: "source-context-bible.SQLite3",
      statements: [
        "CREATE TABLE info (name TEXT, value TEXT)",
        "INSERT INTO info VALUES ('description', 'Source context Bible')",
        "CREATE TABLE verses (book_number INTEGER, chapter INTEGER, verse INTEGER, text TEXT)",
        "INSERT INTO verses VALUES (10, 1, 31, 'Last   words ')",
        "INSERT INTO verses VALUES (10, 2, 1, '<hi type=\"bold\">Next</hi> words')",
      ]
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let start = try XCTUnwrap(
      JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 31)
    )
    let end = try XCTUnwrap(
      JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 2, verse: 1)
    )

    let context = try XCTUnwrap(AIReaderSourceContextExtractor.sqliteBible(
      module: fixture.module,
      request: .selection(
        sourceBookKey: "Gen.1",
        startOrdinal: start,
        endOrdinal: end
      )
    ))

    XCTAssertEqual(context.sourceDocumentInitials, fixture.module.info.name)
    XCTAssertEqual(context.sourceBookKey, "Gen.1")
    XCTAssertEqual(context.sourceOSISRange, "Gen.1.31-Gen.2.1")
    XCTAssertEqual(context.sourceOrdinalRange, start...end)
    XCTAssertEqual(context.selectedText, "Last   words  **Next** words")
    XCTAssertTrue(context.selectedContent?.contains("osisID=\"Gen.1.31\"") == true)
    XCTAssertTrue(context.selectedContent?.contains("osisID=\"Gen.2.1\"") == true)
    XCTAssertFalse(context.selectedContent?.contains("<BVA") == true)
    XCTAssertNil(AIReaderSourceContextExtractor.sqliteBible(
      module: fixture.module,
      request: .selection(
        sourceBookKey: "Gen.1",
        startOrdinal: Int.max,
        endOrdinal: Int.max
      )
    ))
  }

  /**
   Verifies malformed SQLite generic content does not erase a proven exact source key.

   - Setup: Stores one whitespace-sensitive MyBible dictionary key with malformed XML content.
   - Expected result: The exact identity survives with absent structured content and Android's
     strict-cache empty selected text; the trimmed key is rejected.
   - Failure meaning: Generic cache identity can normalize keys or conflate content parse failure
     with source lookup failure.
   - Side effects: Creates and removes one temporary SQLite database.
   */
  func testSQLiteDictionaryRetainsExactIdentityWhenContentIsMalformed() throws {
    let fixture = try makeSQLiteModule(
      fileName: "source-context-dictionary.SQLite3",
      statements: [
        "CREATE TABLE info (name TEXT, value TEXT)",
        "INSERT INTO info VALUES ('description', 'Source context Dictionary')",
        "CREATE TABLE dictionary (topic TEXT, definition TEXT)",
        "INSERT INTO dictionary VALUES (' key ', '<entryFree><p>broken')",
      ]
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let context = try XCTUnwrap(AIReaderSourceContextExtractor.sqliteDictionary(
      module: fixture.module,
      key: " key "
    ))

    XCTAssertEqual(context.sourceDocumentInitials, fixture.module.info.name)
    XCTAssertEqual(context.sourceBookKey, " key ")
    XCTAssertEqual(context.selectedText, "")
    XCTAssertNil(context.selectedContent)
    XCTAssertNil(AIReaderSourceContextExtractor.sqliteDictionary(
      module: fixture.module,
      key: "key"
    ))
  }

  /**
   Verifies My Documents capture uses parent-scoped exact keys and generic anchor semantics.

   - Setup: Persists one Markdown page whose key has meaningful leading/trailing whitespace.
   - Expected result: Exact lookup produces anchored generic content and empty selected text;
     trimming the key cannot resolve the page.
   - Failure meaning: AI strict-cache identity can alias a different generated-book page.
   - Side effects: Allocates an in-memory SwiftData store for the test.
   */
  @MainActor
  func testMyDocumentCapturePreservesWhitespaceSensitivePageKey() throws {
    let container = try makeMyDocumentModelContainer()
    let modelContext = ModelContext(container)
    let document = MyDocument(name: "Journal", initials: "MYDOC")
    let page = MyDocumentPage(title: "Exact page", pageKey: " page ")
    let content = MyDocumentPageContent(
      pageId: page.id,
      content: "First sentence. Second sentence."
    )
    page.document = document
    page.pageContent = content
    content.page = page
    document.pages = [page]
    modelContext.insert(document)
    modelContext.insert(page)
    modelContext.insert(content)
    try modelContext.save()
    let store = MyDocumentStore(modelContext: modelContext)

    let context = try XCTUnwrap(AIReaderSourceContextExtractor.myDocument(
      store: store,
      bookInitials: "MYDOC",
      pageKey: " page "
    ))

    XCTAssertEqual(context.sourceDocumentInitials, "MYDOC")
    XCTAssertEqual(context.sourceBookKey, " page ")
    XCTAssertEqual(context.selectedText, "")
    XCTAssertTrue(context.selectedContent?.contains("<BVA") == true)
    XCTAssertNil(AIReaderSourceContextExtractor.myDocument(
      store: store,
      bookInitials: "MYDOC",
      pageKey: "page"
    ))
  }

  /**
   Verifies an installed EPUB generation supplies exact generic source content.

   - Setup: Installs a one-page EPUB into an isolated library and opens its retained generation.
   - Expected result: Canonical numeric key `1` produces native anchored HTML and empty selected
     text, while a whitespace-altered key is rejected.
   - Failure meaning: EPUB actions can inherit aliases or lose Android generic-cache semantics.
   - Side effects: Creates and removes an isolated EPUB archive and installed library.
   */
  func testEpubCaptureUsesExactPersistedKeyAndEmptySelectedText() throws {
    let root = try makeTemporaryDirectory(named: "source-context-epub")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("library", isDirectory: true)
    let archive = try makeEpubArchive(in: root)
    let identifier = try EpubReader.install(epubURL: archive, libraryRootURL: library)
    let reader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))

    let context = try XCTUnwrap(AIReaderSourceContextExtractor.epub(reader: reader, key: "1"))

    XCTAssertEqual(context.sourceDocumentInitials, reader.initials)
    XCTAssertEqual(context.sourceBookKey, "1")
    XCTAssertEqual(context.selectedText, "")
    XCTAssertTrue(context.selectedContent?.contains("EPUB source sentence") == true)
    XCTAssertTrue(context.selectedContent?.contains("<BVA") == true)
    XCTAssertNil(AIReaderSourceContextExtractor.epub(reader: reader, key: " 1 "))
  }

  /**
   Verifies generic SWORD capture always consumes source-neutral converted OSIS.

   - Setup: Writes real RawLD modules declared as OSIS, ThML, GBF, and undeclared plain text, plus
     malformed OSIS, then reads each through the production extractor.
   - Expected result: Every source type yields anchored content and empty selected text; the plain
     entry's markup-looking bytes stay escaped, and malformed OSIS is repaired through JSword's
     reclose ladder instead of being discarded.
   - Failure meaning: AI context bypasses the shared source filter or drops Android-repairable OSIS.
   - Side effects: Creates and removes one temporary native SWORD module root.
   */
  func testGenericSwordCaptureConvertsNonOSISSourcesAndSurvivesMalformedOSIS() throws {
    let root = try makeTemporaryDirectory(named: "source-context-sword")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixtures: [(name: String, sourceType: String?, body: String, text: String)] = [
      ("CTXOSIS", "OSIS", "<entryFree><p>OSIS source</p></entryFree>", "OSIS source"),
      ("CTXTHML", "ThML", "<p>ThML source</p>", "ThML source"),
      ("CTXGBF", "GBF", "GBF source", "GBF source"),
      ("CTXPLAIN", nil, "<orth>plain source</orth>", "plain source"),
    ]
    for fixture in fixtures {
      try writeRawLDModule(
        named: fixture.name,
        sourceType: fixture.sourceType,
        entries: [("EXACT", fixture.body)],
        root: root
      )
    }
    try writeRawLDModule(
      named: "CTXBROKEN",
      sourceType: "OSIS",
      entries: [("EXACT", "<entryFree><p>broken")],
      root: root
    )
    let manager = try XCTUnwrap(SwordManager(modulePath: root.path))

    for fixture in fixtures {
      let module = try XCTUnwrap(manager.module(named: fixture.name))
      let context = try XCTUnwrap(
        AIReaderSourceContextExtractor.swordDocument(module: module, key: "EXACT")
      )
      XCTAssertEqual(context.sourceDocumentInitials, fixture.name)
      XCTAssertEqual(context.sourceBookKey, "EXACT")
      XCTAssertEqual(context.selectedText, "")
      XCTAssertTrue(context.selectedContent?.contains(fixture.text) == true)
      XCTAssertTrue(context.selectedContent?.contains("<BVA") == true)
      if fixture.name == "CTXPLAIN" {
        XCTAssertTrue(context.selectedContent?.contains("&lt;orth&gt;") == true)
        XCTAssertFalse(context.selectedContent?.contains("<orth>") == true)
      }
    }

    let malformed = try XCTUnwrap(AIReaderSourceContextExtractor.swordDocument(
      module: try XCTUnwrap(manager.module(named: "CTXBROKEN")),
      key: "EXACT"
    ))
    XCTAssertEqual(malformed.sourceDocumentInitials, "CTXBROKEN")
    XCTAssertEqual(malformed.sourceBookKey, "EXACT")
    XCTAssertEqual(malformed.selectedText, "")
    XCTAssertTrue(malformed.selectedContent?.contains("broken") == true)
    XCTAssertTrue(malformed.selectedContent?.contains("<BVA") == true)
  }

  /** Creates one isolated directory for a real backend fixture. */
  private func makeTemporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(name)-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /**
   Builds one MyBible module around an operation-owned real SQLite database.

   - Parameters:
     - fileName: `.SQLite3` filename controlling Android synthetic initials.
     - statements: Ordered schema and fixture-data statements.
   - Returns: Temporary root and production reader handle.
   - Side effects: Creates a SQLite file and opens it through `MyBibleReader` validation.
   - Throws: Filesystem, SQLite, or source-reader validation failures.
   */
  private func makeSQLiteModule(
    fileName: String,
    statements: [String]
  ) throws -> (root: URL, module: BibleReaderSQLiteModuleHandle) {
    let root = try makeTemporaryDirectory(named: "source-context-sqlite")
    let fileURL = root.appendingPathComponent(fileName)
    try writeSQLiteDatabase(at: fileURL, statements: statements)
    let reader = try MyBibleReader(fileURL: fileURL)
    return (
      root,
      BibleReaderSQLiteModuleHandle(
        module: SQLiteDocumentModule(reader: reader, origin: .manual)
      )
    )
  }

  /**
   Writes a minimal stored EPUB fixture with one indexed XHTML spine document.

   - Parameter root: Existing isolated fixture directory.
   - Returns: URL of the complete `.epub` archive.
   - Side effects: Writes one ZIP archive below `root`.
   - Throws: ZIP construction or filesystem failures.
   */
  private func makeEpubArchive(in root: URL) throws -> URL {
    let archiveURL = root.appendingPathComponent("Source Context.epub")
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
          <dc:title>Source Context</dc:title><dc:language>en</dc:language>
        </metadata>
        <manifest>
          <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine><itemref idref="chapter"/></spine>
      </package>
      """),
      ("OPS/chapter.xhtml", """
      <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <p>EPUB source sentence. Another sentence.</p>
      </body></html>
      """),
    ]
    let archive = try ZipArchiveWriter.storedArchive(entries: entries.map {
      ZipArchiveWriterEntry(name: $0.0, data: Data($0.1.utf8))
    })
    try archive.write(to: archiveURL, options: .atomic)
    return archiveURL
  }

  /**
   Writes one real RawLD dictionary using SWORD's six-byte little-endian index records.

   - Parameters:
     - name: Exact installed module initials.
     - sourceType: Optional SWORD source filter declaration.
     - entries: Lexically ordered exact key and native source records.
     - root: Existing SWORD root shared by this fixture generation.
   - Side effects: Writes module config, data, and index files.
   - Throws: Filesystem failures or `recordTooLarge` for unsupported RawLD record widths.
   */
  private func writeRawLDModule(
    named name: String,
    sourceType: String?,
    entries: [(String, String)],
    root: URL
  ) throws {
    let stem = name.lowercased()
    let modsDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
    let dataDirectory = root.appendingPathComponent(
      "modules/lexdict/rawld/\(stem)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: modsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

    var data = Data()
    var index = Data()
    for (key, body) in entries {
      let record = Data("\(key)\r\n\(body)".utf8)
      guard record.count <= Int(UInt16.max), data.count <= Int(UInt32.max) else {
        throw SourceContextBackendFixtureError.recordTooLarge
      }
      index.appendSourceContextLittleEndian(UInt32(data.count))
      index.appendSourceContextLittleEndian(UInt16(record.count))
      data.append(record)
      data.append(0x0A)
    }
    let prefix = dataDirectory.appendingPathComponent(stem)
    try data.write(to: prefix.appendingPathExtension("dat"))
    try index.write(to: prefix.appendingPathExtension("idx"))
    let sourceTypeLine = sourceType.map { "SourceType=\($0)\n" } ?? ""
    try """
    [\(name)]
    Description=\(name) source context fixture
    Abbreviation=\(name)
    Category=Lexicons / Dictionaries
    DataPath=./modules/lexdict/rawld/\(stem)/\(stem)
    ModDrv=RawLD
    \(sourceTypeLine)Encoding=UTF-8
    Lang=en
    """.write(
      to: modsDirectory.appendingPathComponent("\(stem).conf"),
      atomically: true,
      encoding: .utf8
    )
  }

  /**
   Executes ordered schema/data statements into one SQLite fixture.

   - Parameters:
     - url: Destination database URL.
     - statements: SQL statements executed in caller order.
   - Side effects: Creates and mutates one SQLite file, closing it before return.
   - Throws: `sqliteFailure` with the first failing statement's diagnostic.
   */
  private func writeSQLiteDatabase(at url: URL, statements: [String]) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else {
      defer { sqlite3_close(database) }
      throw SourceContextBackendFixtureError.sqliteFailure("open")
    }
    defer { sqlite3_close(database) }
    for statement in statements {
      var message: UnsafeMutablePointer<CChar>?
      guard sqlite3_exec(database, statement, nil, nil, &message) == SQLITE_OK else {
        let diagnostic = message.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(message)
        throw SourceContextBackendFixtureError.sqliteFailure(diagnostic)
      }
    }
  }
}

/** Typed construction failures for real source-context backend fixtures. */
private enum SourceContextBackendFixtureError: Error {
  /// A native RawLD offset or record exceeds its fixed-width index representation.
  case recordTooLarge

  /// SQLite rejected fixture creation with the associated native diagnostic.
  case sqliteFailure(String)
}

private extension Data {
  /** Appends one RawLD integer in SWORD's little-endian index representation. */
  mutating func appendSourceContextLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}
