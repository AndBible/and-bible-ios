import Foundation
import SQLite3
@testable import BibleCore

/**
 Builds real Android installed-EPUB directory fixtures for MODULE_BACKUP compatibility tests.

 The fixture mirrors Android's `EpubBackendState` and Room v1 contracts: the display-name directory
 contains OCF/OPF/navigation/resources, optimized XHTML is gzip-compressed under `optimized/`, and
 fragment/mapping/style rows live in either supported gzip database filename. Fixture creation writes
 only beneath caller-owned temporary directories and never touches the app library.
 */
enum EpubAndroidModuleBackupTestFixture {
    /**
     Writes a raw Android EPUB install whose original spine documents are still present.

     - Parameters:
       - rootURL: Exact `epub/<displayName>/` destination, replaced if already present.
       - label: Human-readable marker embedded in metadata, content, and resource bytes.
     - Side effects: Recreates `rootURL` and writes container, OPF, nav, XHTML, CSS, and image files.
     - Throws: File-system failures from directory or file creation.
     */
    static func writeRawTree(at rootURL: URL, label: String) throws {
        try recreateDirectory(rootURL)
        try writePackageScaffold(at: rootURL, label: label, includeOriginalSpine: true)
    }

    /**
     Writes Android's post-optimization shape with both original spine XHTML files deleted.

     - Parameters:
       - rootURL: Exact `epub/<displayName>/` destination, replaced if already present.
       - label: Marker embedded in optimized text and resource bytes.
       - databaseArchiveName: `optimized.sqlite3.gz` or the caller-supplied identity filename.
       - includeSearchDatabase: Whether to include Android's optional exact-name FTS database.
     - Side effects: Recreates `rootURL`, writes package scaffolding/resources, creates temporary
       SQLite databases, gzip-compresses Room and XHTML payloads, and removes temporary Room input.
     - Throws: File-system, SQLite, or gzip failures.
     */
    static func writeOptimizedTree(
        at rootURL: URL,
        label: String,
        databaseArchiveName: String = "optimized.sqlite3.gz",
        includeSearchDatabase: Bool = false
    ) throws {
        try recreateDirectory(rootURL)
        try writePackageScaffold(at: rootURL, label: label, includeOriginalSpine: false)
        let optimizedURL = rootURL.appendingPathComponent("optimized", isDirectory: true)
        try FileManager.default.createDirectory(at: optimizedURL, withIntermediateDirectories: true)
        try Data("2".utf8).write(to: optimizedURL.appendingPathComponent("version.txt"))

        let firstFragment = """
        <div xmlns="http://www.w3.org/1999/xhtml" class="reader">
          <h1 id="start"><BVA ordinal="0">\(label) optimized opening.</BVA></h1>
          <p><BVA ordinal="1">Continue to </BVA><epubRef to-key="chapter-2" to-id="target" style="color: red; font-weight: bold; background-image: url('/epub/images/cover.png')">the target</epubRef>.</p>
          <img src="/epub/images/cover.png" alt="cover"/>
          <epubA href="https://example.org/reader">External</epubA>
        </div>
        """
        let secondFragment = """
        <div xmlns="http://www.w3.org/1999/xhtml">
          <h2 id="target"><BVA ordinal="0">\(label) optimized target.</BVA></h2>
          <p><epubRef to-key="chapter-1" to-id="start">Return</epubRef></p>
        </div>
        """
        try gzip(Data(firstFragment.utf8)).write(
            to: optimizedURL.appendingPathComponent("007.xhtml.gz")
        )
        try gzip(Data(secondFragment.utf8)).write(
            to: optimizedURL.appendingPathComponent("012.xhtml.gz")
        )

        let databaseURL = rootURL.appendingPathComponent("room-source.sqlite3")
        try createRoomDatabase(at: databaseURL)
        let databaseData = try Data(contentsOf: databaseURL)
        try gzip(databaseData).write(to: rootURL.appendingPathComponent(databaseArchiveName))
        try FileManager.default.removeItem(at: databaseURL)

        if includeSearchDatabase {
            let initials = EpubReader.initials(forDisplayFileName: rootURL.lastPathComponent)
            try createSearchDatabase(
                at: rootURL.appendingPathComponent("epub-\(initials)-search.sqlite3"),
                label: label
            )
        }
    }

    /**
     Recreates an empty fixture directory at one caller-owned URL.

     - Parameter url: Directory to replace.
     - Side effects: Recursively removes an existing fixture and creates an empty directory.
     - Throws: File-system failures.
     */
    private static func recreateDirectory(_ url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /**
     Writes package files Android retains before and after optimization.

     - Parameters:
       - rootURL: Android display-name directory.
       - label: Fixture marker used in metadata/content/resources.
       - includeOriginalSpine: Whether raw chapter XHTML files should be written.
     - Side effects: Writes deterministic OCF, OPF, navigation, CSS, image, and optional XHTML files.
     - Throws: File-system failures.
     */
    private static func writePackageScaffold(
        at rootURL: URL,
        label: String,
        includeOriginalSpine: Bool
    ) throws {
        try write("application/epub+zip", relativePath: "mimetype", rootURL: rootURL)
        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles>
                <rootfile media-type="application/oebps-package+xml" full-path="OPS/package.opf"/>
              </rootfiles>
            </container>
            """,
            relativePath: "META-INF/container.xml",
            rootURL: rootURL
        )
        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="book-id">urn:android-fixture</dc:identifier>
                <dc:title>\(label) Android Book</dc:title>
                <dc:creator>Android Fixture</dc:creator>
                <dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="chapter-1" href="text/chapter1.xhtml" media-type="application/xhtml+xml"/>
                <item id="chapter-2" href="text/chapter2.xhtml" media-type="application/xhtml+xml"/>
                <item id="style" href="styles/book.css" media-type="text/css"/>
                <item id="cover" href="images/cover.png" media-type="image/png"/>
                <item id="font" href="fonts/reader.woff2" media-type="font/woff2"/>
              </manifest>
              <spine>
                <itemref idref="chapter-1"/>
                <itemref idref="chapter-2"/>
              </spine>
            </package>
            """,
            relativePath: "OPS/package.opf",
            rootURL: rootURL
        )
        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
              <body><nav epub:type="toc"><ol>
                <li><a href="text/chapter1.xhtml#start">Opening</a></li>
                <li><a href="text/chapter2.xhtml#target">Target</a></li>
              </ol></nav></body>
            </html>
            """,
            relativePath: "OPS/nav.xhtml",
            rootURL: rootURL
        )
        try write(
            """
            @font-face { font-family: Reader; src: url('../fonts/reader.woff2'); }
            .reader { color: blue; font-weight: bold; background-image: url('../images/cover.png'); }
            """,
            relativePath: "OPS/styles/book.css",
            rootURL: rootURL
        )
        try write(
            Data("\(label)-image".utf8),
            relativePath: "OPS/images/cover.png",
            rootURL: rootURL
        )
        try write(
            Data("\(label)-font".utf8),
            relativePath: "OPS/fonts/reader.woff2",
            rootURL: rootURL
        )
        guard includeOriginalSpine else { return }
        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><link rel="stylesheet" href="../styles/book.css"/></head>
              <body class="reader"><h1 id="start">\(label) raw opening.</h1>
                <p><a href="chapter2.xhtml#target">Read the target</a></p>
                <img src="../images/cover.png" alt="cover"/>
              </body>
            </html>
            """,
            relativePath: "OPS/text/chapter1.xhtml",
            rootURL: rootURL
        )
        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <body><h2 id="target">\(label) raw target.</h2></body>
            </html>
            """,
            relativePath: "OPS/text/chapter2.xhtml",
            rootURL: rootURL
        )
    }

    /**
     Creates Android Room v1 fragment, anchor-map, and stylesheet tables with noncontiguous keys.

     - Parameter url: Temporary uncompressed SQLite destination.
     - Side effects: Creates and fills a SQLite database and closes it before returning.
     - Throws: `EpubError.indexingFailed` when SQLite cannot create any required schema or row.
     */
    private static func createRoomDatabase(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK else {
            sqlite3_close(database)
            throw EpubError.indexingFailed("Unable to create Android EPUB Room fixture")
        }
        defer { sqlite3_close(database) }
        try execute(
            """
            PRAGMA user_version=1;
            CREATE TABLE EpubFragment (
                originalId TEXT NOT NULL,
                ordinalStart INTEGER NOT NULL,
                ordinalEnd INTEGER NOT NULL,
                id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT
            );
            CREATE TABLE EpubHtmlToFrag (
                htmlId TEXT NOT NULL PRIMARY KEY,
                fragId INTEGER NOT NULL
            );
            CREATE TABLE StyleSheet (
                origId TEXT NOT NULL,
                styleSheetFile TEXT NOT NULL,
                id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT
            );
            INSERT INTO EpubFragment (id, originalId, ordinalStart, ordinalEnd)
                VALUES (7, 'chapter-1', 0, 1);
            INSERT INTO EpubFragment (id, originalId, ordinalStart, ordinalEnd)
                VALUES (12, 'chapter-2', 0, 0);
            INSERT INTO EpubHtmlToFrag (htmlId, fragId) VALUES ('chapter-1', 7);
            INSERT INTO EpubHtmlToFrag (htmlId, fragId) VALUES ('chapter-1#start', 7);
            INSERT INTO EpubHtmlToFrag (htmlId, fragId) VALUES ('chapter-2', 12);
            INSERT INTO EpubHtmlToFrag (htmlId, fragId) VALUES ('chapter-2#target', 12);
            INSERT INTO StyleSheet (origId, styleSheetFile)
                VALUES ('chapter-1', '../styles/book.css');
            """,
            database: database
        )
    }

    /**
     Creates Android's optional FTS5 search database with valid fragment/ordinal targets.

     - Parameters:
       - url: Exact `epub-<initials>-search.sqlite3` destination.
       - label: Search text marker.
     - Side effects: Creates and fills one SQLite database and closes it before returning.
     - Throws: `EpubError.indexingFailed` for SQLite creation or mutation failures.
     */
    private static func createSearchDatabase(at url: URL, label: String) throws {
        try? FileManager.default.removeItem(at: url)
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK else {
            sqlite3_close(database)
            throw EpubError.indexingFailed("Unable to create Android EPUB search fixture")
        }
        defer { sqlite3_close(database) }
        try execute(
            """
            CREATE VIRTUAL TABLE SearchIndex USING fts5(
                contentText,
                frag_id UNINDEXED,
                ordinal UNINDEXED
            );
            INSERT INTO SearchIndex (contentText, frag_id, ordinal)
                VALUES ('\(label) optimized opening.', 7, 0);
            INSERT INTO SearchIndex (contentText, frag_id, ordinal)
                VALUES ('\(label) optimized target.', 12, 0);
            """,
            database: database
        )
    }

    /**
     Executes deterministic fixture SQL and surfaces SQLite's diagnostic on failure.

     - Parameters:
       - sql: Trusted test-only schema and row statements.
       - database: Open writable fixture database.
     - Side effects: Mutates the fixture database.
     - Throws: `EpubError.indexingFailed` when SQLite rejects the statements.
     */
    private static func execute(_ sql: String, database: OpaquePointer?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw EpubError.indexingFailed(EpubReader.sqliteMessage(database))
        }
    }

    /**
     Gzip-compresses fixture bytes through the production Android-compatible codec.

     - Parameter data: Uncompressed Room or XHTML bytes.
     - Returns: Complete gzip payload.
     - Side effects: Allocates and frees the production codec buffer.
     - Throws: `RemoteSyncArchiveStagingError.compressionFailed` if compression fails.
     */
    private static func gzip(_ data: Data) throws -> Data {
        try RemoteSyncArchiveStagingService.gzip(data)
    }

    /**
     Writes UTF-8 fixture text at one package-relative path.

     - Parameters:
       - value: UTF-8 text to write.
       - relativePath: Forward-slash path beneath `rootURL`.
       - rootURL: Android display-name directory.
     - Side effects: Creates parent directories and writes one file atomically.
     - Throws: File-system failures.
     */
    private static func write(_ value: String, relativePath: String, rootURL: URL) throws {
        try write(Data(value.utf8), relativePath: relativePath, rootURL: rootURL)
    }

    /**
     Writes exact binary fixture bytes at one package-relative path.

     - Parameters:
       - data: Exact bytes to persist.
       - relativePath: Forward-slash path beneath `rootURL`.
       - rootURL: Android display-name directory.
     - Side effects: Creates parent directories and writes one file atomically.
     - Throws: File-system failures.
     */
    private static func write(_ data: Data, relativePath: String, rootURL: URL) throws {
        let url = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
