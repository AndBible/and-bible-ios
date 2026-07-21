import Foundation
import SQLite3
import SwordKit
import XCTest
@testable import BibleCore

/**
 Contract tests for Android's MyBible, MySword, and e-Sword SQLite document readers.

 The checked-in databases under `Sources/BibleCore/Tests/Fixtures/SQLiteDocumentReaders` use the
 schemas read by Android's `MyBibleBook.kt`, `MySwordBook.kt`, and `ESwordBook.kt`. Tests open those
 real SQLite files read-only, so failures indicate schema, discovery, metadata, key enumeration, or
 content behavior drift rather than a mismatch in an in-test fixture builder.
 */
final class SQLiteDocumentReaderParityTests: XCTestCase {
    /**
     Verifies dictionary snippets mirror JDOM's direct-child lookup and single-title removal.

     - Setup: Supplies nested decoy title, entryFree, and orth elements alongside two direct titles
       but no direct entryFree element.
     - Expected result: Only the first direct title is removed; nested structures and the second
       direct title remain ordinary fallback text and cannot impersonate Android's entry lookup.
     - Failure meaning: Crafted dictionary markup can display a different chooser row on iOS than
       Android or hide visible fallback text through broader descendant matching.
     - Side effects: Parses one in-memory XML wrapper; no files or databases are touched.
     */
    func testDictionarySnippetUsesAndroidDirectChildProjection() throws {
        let fragment = """
        <div><title>N</title><entryFree><orth>O</orth></entryFree></div>
        <title>X</title><title>T</title>V
        """

        let snippet = try XCTUnwrap(
            SQLiteDocumentXMLCompatibility.dictionarySnippet(fragment: fragment, key: "KEY")
        )

        XCTAssertEqual(snippet.filter { !$0.isWhitespace }, "NOTV")
    }

    /**
     Verifies dictionary lookup ignores default-namespace elements like JDOM's no-namespace API.

     - Setup: Supplies namespaced direct title/entry elements before a no-namespace entry whose
       first orthography is also namespaced.
     - Expected result: Only the no-namespace entry and no-namespace orthography participate.
     - Failure meaning: Namespace-decorated decoys can replace the chooser label Android displays.
     - Side effects: Parses one in-memory XML wrapper; no files or databases are touched.
     */
    func testDictionarySnippetRequiresAndroidNoNamespaceChildren() throws {
        let fragment = """
        <title xmlns="urn:decoy">Ignored by Android lookup</title>
        <entryFree xmlns="urn:decoy"><orth>Namespaced entry</orth></entryFree>
        <entryFree><orth xmlns="urn:decoy">Namespaced orth</orth><orth>Exact orth</orth></entryFree>
        """

        XCTAssertEqual(
            SQLiteDocumentXMLCompatibility.dictionarySnippet(fragment: fragment, key: "KEY"),
            "Exact orth"
        )
    }

    /**
     Verifies dictionary key-prefix cleanup uses Java UTF-16 equality without normalization.

     - Setup: Supplies a composed key and canonically equivalent decomposed visible entry prefix.
     - Expected result: The decomposed prefix remains because Android `String.startsWith` compares
       exact UTF-16 code units.
     - Failure meaning: Swift canonical matching can hide source text Android keeps in the chooser.
     - Side effects: Parses one in-memory XML wrapper; no files or databases are touched.
     */
    func testDictionarySnippetDoesNotNormalizeKeyPrefix() throws {
        let decomposedText = "e\u{301} definition"
        let snippet = try XCTUnwrap(
            SQLiteDocumentXMLCompatibility.dictionarySnippet(
                fragment: decomposedText,
                key: "\u{00E9}"
            )
        )

        XCTAssertEqual(Array(snippet.utf16), Array("\(decomposedText) ".utf16))
    }

    /**
     Protects MyBible Bible metadata, keys, book names, Strong's flags, and story-title projection.

     - Setup: Opens the real `.SQLite3` Bible fixture with `info`, `books`, `verses`, and `stories`.
     - Expected result: Typed and legacy APIs expose the same Android category and content.
     - Failure meaning: A downloaded/restored MyBible Bible can be discovered but not cataloged or
       rendered with Android-compatible metadata and headings.
     - Side effects: Opens and closes the fixture database read-only.
     */
    func testMyBibleBibleFixtureExposesTypedMetadataKeysAndStories() throws {
        let reader = try MyBibleReader(fileURL: fixtureURL("mybible-bible.SQLite3"))

        XCTAssertEqual(reader.category, .bible)
        XCTAssertTrue(reader.isBible)
        XCTAssertFalse(reader.isCommentary)
        XCTAssertFalse(reader.isDictionary)
        XCTAssertEqual(reader.metadata.format, .myBible)
        XCTAssertEqual(reader.metadata.initials, "MyBible-mybible_bible")
        XCTAssertEqual(reader.metadata.abbreviation, "mybible-bible")
        XCTAssertEqual(reader.moduleDescription, "MyBible Bible Fixture")
        XCTAssertEqual(reader.language, "en")
        XCTAssertTrue(reader.hasStrongs)
        XCTAssertTrue(reader.hasWordsOfChrist)
        XCTAssertEqual(
            try reader.keys(),
            [
                .verse(book: 10, chapter: 1, verse: 1),
                .verse(book: 10, chapter: 1, verse: 2),
            ]
        )
        XCTAssertEqual(
            try reader.content(for: .verse(book: 10, chapter: 1, verse: 1))?.text,
            "<title canonical=\"false\">Creation</title>In the <J>beginning</J>"
        )
        XCTAssertEqual(reader.getChapter(book: 10, chapter: 1).map(\.verse), [1, 2])
        XCTAssertEqual(reader.books().first?.name, "Genesis")
    }

    /**
     Protects well-formed XML projection for untrusted plain MyBible story titles.

     - Setup: Creates a valid Bible whose plain story title contains ampersand and angle brackets.
     - Expected result: Android's exact raw title-before-verse result is demonstrably malformed XML;
       iOS retains its visible text and ordering through an escaped, valid OSIS projection.
     - Failure meaning: A downloaded title could break the reader document or inject sibling markup.
     - Side effects: Creates and removes one temporary SQLite database and runs an in-memory parser.
     */
    func testMyBiblePlainStoryTitlesProduceWellFormedEscapedXML() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("escaped-story-title.SQLite3")
        try SQLiteDocumentTestDatabase.create(at: url, statements: [
            "CREATE TABLE info (name TEXT, value TEXT)",
            "INSERT INTO info VALUES ('description', 'Escaped story title')",
            "CREATE TABLE verses (book_number INTEGER, chapter INTEGER, verse INTEGER, text TEXT)",
            "INSERT INTO verses VALUES (10, 1, 1, 'Verse text')",
            "CREATE TABLE stories (book_number INTEGER, chapter INTEGER, verse INTEGER, title TEXT)",
            "INSERT INTO stories VALUES (10, 1, 1, 'A & B < C > D')",
        ])
        let reader = try MyBibleReader(fileURL: url)
        let content = try XCTUnwrap(
            try reader.content(for: .verse(book: 10, chapter: 1, verse: 1))?.text
        )
        let androidRawResult =
            "<title canonical=\"false\">A & B < C > D</title>Verse text"

        XCTAssertFalse(XMLParser(data: Data("<root>\(androidRawResult)</root>".utf8)).parse())
        XCTAssertEqual(
            content,
            "<title canonical=\"false\">A &amp; B &lt; C &gt; D</title>Verse text"
        )
        let parser = XMLParser(data: Data("<root>\(content)</root>".utf8))
        XCTAssertTrue(parser.parse(), parser.parserError?.localizedDescription ?? "XML parse failed")
    }

    /**
     Pins Kotlin nullable interpolation and source-order story composition for SQL `NULL` verses.

     - Setup: Creates a nullable verse followed by one raw-markup story and one plain story.
     - Expected result: Android's first interpolation emits literal `null`, raw markup appends, and
       the later plain title prepends. Point and chapter paths return the same valid OSIS fragment.
     - Failure meaning: Early nil coalescing or batch reduction has changed Android-visible output.
     - Side effects: Creates and removes one temporary SQLite database.
     */
    func testMyBibleStoriesPreserveKotlinNullInterpolationAndOrder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("nullable-story.SQLite3")
        try SQLiteDocumentTestDatabase.create(at: url, statements: [
            "CREATE TABLE info (name TEXT, value TEXT)",
            "INSERT INTO info VALUES ('description', 'Nullable story')",
            "CREATE TABLE verses (book_number INTEGER, chapter INTEGER, verse INTEGER, text TEXT)",
            "INSERT INTO verses VALUES (10, 1, 1, NULL)",
            "CREATE TABLE stories (book_number INTEGER, chapter INTEGER, verse INTEGER, title TEXT)",
            "INSERT INTO stories VALUES (10, 1, 1, '<hi>Tail</hi>')",
            "INSERT INTO stories VALUES (10, 1, 1, 'Heading')",
        ])
        let reader = try MyBibleReader(fileURL: url)
        let expected = "<title canonical=\"false\">Heading</title>null<hi>Tail</hi>"

        XCTAssertEqual(reader.getVerse(book: 10, chapter: 1, verse: 1), expected)
        XCTAssertEqual(reader.getChapter(book: 10, chapter: 1).first?.text, expected)
        XCTAssertTrue(XMLParser(data: Data("<root>\(expected)</root>".utf8)).parse())
    }

    /**
     Protects exact MyBible metadata names and raw case-sensitive category-table discovery.

     - Setup: Places an oversized uppercase metadata decoy before valid exact-name rows and creates
       a second database whose only content table is uppercase `VERSES`.
     - Expected result: Exact metadata remains readable without touching the decoy; the uppercase
       table is reported as unsupported instead of being silently reinterpreted as Android data.
     - Failure meaning: Case folding can trigger CursorWindow failures, spoof installed metadata,
       or admit a schema Android's raw table-name checks reject.
     - Side effects: Creates and removes two temporary SQLite databases.
     */
    func testMyBibleQueriesOnlyExactMetadataAndTableNames() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let validURL = root.appendingPathComponent("exact-metadata.SQLite3")
        try SQLiteDocumentTestDatabase.create(at: validURL, statements: [
            "CREATE TABLE info (name TEXT, value TEXT)",
            "INSERT INTO info VALUES ('DESCRIPTION', replace(hex(zeroblob(2096720)), '00', 'x'))",
            "INSERT INTO info VALUES ('description', 'Exact description')",
            "INSERT INTO info VALUES ('LANGUAGE', 'spoofed')",
            "INSERT INTO info VALUES ('language', 'fi')",
            "CREATE TABLE verses (book_number INTEGER, chapter INTEGER, verse INTEGER, text TEXT)",
            "INSERT INTO verses VALUES (10, 1, 1, 'Readable')",
        ])

        let reader = try MyBibleReader(fileURL: validURL)
        XCTAssertEqual(reader.metadata.description, "Exact description")
        XCTAssertEqual(reader.metadata.language, "fi")

        let uppercaseURL = root.appendingPathComponent("uppercase-table.SQLite3")
        try SQLiteDocumentTestDatabase.create(at: uppercaseURL, statements: [
            "CREATE TABLE info (name TEXT, value TEXT)",
            "INSERT INTO info VALUES ('description', 'Wrong table case')",
            "CREATE TABLE VERSES (book_number INTEGER, chapter INTEGER, verse INTEGER, text TEXT)",
        ])
        XCTAssertThrowsError(try MyBibleReader(fileURL: uppercaseURL)) { error in
            guard case .unsupportedSchema(let format, let tables) =
                error as? SQLiteDocumentReaderError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(format, .myBible)
            XCTAssertTrue(tables.contains("VERSES"))
            XCTAssertFalse(tables.contains("verses"))
        }
    }

    /**
     Protects Android's independent MyBible feature flags without category reinterpretation.

     - Setup: Creates a dictionary whose exact metadata rows advertise both Strong's definitions
       and Strong's-number content.
     - Expected result: Both flags survive metadata projection even though only one is conventional
       for a dictionary category.
     - Failure meaning: iOS has inferred feature support from category instead of mirroring the
       values Android writes into generated book metadata.
     - Side effects: Creates and removes one temporary SQLite database.
     */
    func testMyBibleFeatureFlagsRemainIndependentOfCategory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("independent-flags.SQLite3")
        try SQLiteDocumentTestDatabase.create(at: url, statements: [
            "CREATE TABLE info (name TEXT, value TEXT)",
            "INSERT INTO info VALUES ('description', 'Independent flags')",
            "INSERT INTO info VALUES ('is_strong', 'true')",
            "INSERT INTO info VALUES ('strong_numbers', 'true')",
            "CREATE TABLE dictionary (topic TEXT, definition TEXT)",
            "INSERT INTO dictionary VALUES ('G1', 'Definition')",
        ])

        let reader = try MyBibleReader(fileURL: url)
        XCTAssertEqual(reader.category, .dictionary)
        XCTAssertTrue(reader.metadata.hasStrongs)
        XCTAssertTrue(reader.metadata.isStrongsDictionary)
        let module = SQLiteDocumentModule(reader: reader, origin: .manual)
        XCTAssertTrue(module.info.features.contains(.strongsNumbers))
        XCTAssertTrue(module.info.features.contains(.greekDef))
        XCTAssertTrue(module.info.features.contains(.hebrewDef))
    }

    /**
     Protects the shared XML 1.0 sanitizer and malformed raw-story fallback.

     - Setup: Stores a raw story fragment containing forbidden controls and another fragment with
       an unclosed element before a plain verse.
     - Expected result: Forbidden scalars become replacement characters, valid markup survives,
       malformed markup becomes escaped visible text, and the complete projection parses as XML.
     - Failure meaning: One SQLite format can inject malformed XML or silently drop source text.
     - Side effects: Creates and removes one temporary SQLite database and parses projected XML.
     */
    func testMyBibleRawStoriesSanitizeXML10AndEscapeMalformedFragments() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("raw-story-sanitization.SQLite3")
        try SQLiteDocumentTestDatabase.create(at: url, statements: [
            "CREATE TABLE info (name TEXT, value TEXT)",
            "INSERT INTO info VALUES ('description', 'Raw stories')",
            "CREATE TABLE verses (book_number INTEGER, chapter INTEGER, verse INTEGER, text TEXT)",
            "INSERT INTO verses VALUES (10, 1, 1, 'Verse')",
            "CREATE TABLE stories (book_number INTEGER, chapter INTEGER, verse INTEGER, title TEXT)",
            "INSERT INTO stories VALUES (10, 1, 1, CAST(X'3C623E41004201433C2F623E' AS TEXT))",
            "INSERT INTO stories VALUES (10, 1, 1, '<title broken')",
        ])

        let content = try XCTUnwrap(
            try MyBibleReader(fileURL: url).content(
                for: .verse(book: 10, chapter: 1, verse: 1)
            )?.text
        )
        XCTAssertEqual(content, "Verse<b>A\u{FFFD}B\u{FFFD}C</b>&lt;title broken")
        let parser = XMLParser(data: Data("<root>\(content)</root>".utf8))
        XCTAssertTrue(parser.parse(), parser.parserError?.localizedDescription ?? "XML parse failed")
    }

    /**
     Protects row presence for nullable MyBible verses and lazy handling of optional book metadata.

     - Setup: Opens a Bible fixture with a SQL `NULL` verse, duplicate coordinates, and a present
       `books` table that lacks Android's optional display-name columns.
     - Expected result: Initialization succeeds, the NULL row remains a key with empty content,
       duplicate rows remain enumerable, chapter output keeps only their first coordinate, and
       malformed optional book metadata remains isolated from content.
     - Failure meaning: Readable module content could be rejected by unrelated optional metadata,
       or a present blank verse could disappear from lookup and chapter projection.
     - Side effects: Opens and closes the fixture database read-only.
     */
    func testMyBibleNullVerseDuplicatesAndMalformedBooksRemainReadable() throws {
        let reader = try MyBibleReader(fileURL: fixtureURL("mybible-null-content.SQLite3"))

        XCTAssertEqual(
            try reader.keys(),
            [
                .verse(book: 10, chapter: 1, verse: 1),
                .verse(book: 10, chapter: 1, verse: 2),
                .verse(book: 10, chapter: 1, verse: 2),
            ]
        )
        XCTAssertEqual(
            try reader.content(for: .verse(book: 10, chapter: 1, verse: 1)),
            SQLiteDocumentContent(key: .verse(book: 10, chapter: 1, verse: 1), text: "")
        )
        XCTAssertEqual(reader.getVerse(book: 10, chapter: 1, verse: 2), "First duplicate")
        XCTAssertNil(reader.getVerse(book: 10, chapter: 1, verse: 3))
        XCTAssertEqual(reader.getChapter(book: 10, chapter: 1).map(\.verse), [1, 2])
        XCTAssertEqual(
            reader.getChapter(book: 10, chapter: 1).map(\.text),
            ["", "First duplicate"]
        )
        XCTAssertTrue(reader.books().isEmpty)
    }

    /**
     Stress-tests one real SQLite reader under overlapping catalog and content calls.

     - Setup: Shares the duplicate-coordinate MyBible fixture across twelve concurrent workers;
       each repeatedly enumerates keys, resolves a verse, reads a chapter, or reads optional books.
     - Expected result: Every operation returns a complete stable value and no SQLite error occurs.
     - Failure meaning: Statement state or connection diagnostics can still race despite the shared
       operation-owned database connection boundary.
     - Side effects: Opens one checked-in database read-only and runs bounded background work.
     - Note: The test-only handoff wrapper deliberately enables concurrency against a non-Sendable
       reader so this runtime hardening can be exercised without weakening production conformance.
     */
    func testMyBibleReaderRemainsStableDuringConcurrentCatalogAndContentStress() throws {
        let harness = ConcurrentMyBibleReaderHarness(reader: try MyBibleReader(
            fileURL: fixtureURL("mybible-null-content.SQLite3")
        ))
        let failures = SQLiteDocumentConcurrentFailureRecorder()
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "SQLiteDocumentReaderParityTests.concurrentStress",
            attributes: .concurrent
        )

        for worker in 0..<12 {
            group.enter()
            queue.async {
                defer { group.leave() }
                for iteration in 0..<100 {
                    do {
                        switch (worker + iteration) % 4 {
                        case 0:
                            guard try harness.reader.keys().count == 3 else {
                                throw SQLiteDocumentConcurrentAssertionFailure.unexpectedKeys
                            }
                        case 1:
                            guard try harness.reader.content(
                                for: .verse(book: 10, chapter: 1, verse: 2)
                            )?.text == "First duplicate" else {
                                throw SQLiteDocumentConcurrentAssertionFailure.unexpectedContent
                            }
                        case 2:
                            guard try harness.reader.chapterContent(
                                book: 10,
                                chapter: 1
                            ).map(\.verse) == [1, 2] else {
                                throw SQLiteDocumentConcurrentAssertionFailure.unexpectedChapter
                            }
                        default:
                            guard harness.reader.books().isEmpty else {
                                throw SQLiteDocumentConcurrentAssertionFailure.unexpectedBooks
                            }
                        }
                    } catch {
                        failures.record(error)
                        return
                    }
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(failures.messages, [])
    }

    /**
     Protects Android CursorWindow refill behavior beyond iOS' former cumulative row cap.

     - Setup: Uses duplicate fixture rows for ordered first-row lookup, then a recursive CTE that
       emits 100,001 integer rows.
     - Expected result: `firstText` stops at the first duplicate and the complete CTE streams
       through refillable CursorWindows without a cumulative row rejection.
     - Failure meaning: iOS has restored a process-wide row cap that Android's cursor does not have.
     - Side effects: Opens the fixture database read-only; the CTE creates no persistent objects.
     */
    func testSQLiteCursorWindowStreamsPastFormerCumulativeRowLimit() throws {
        let database = try SQLiteDocumentDatabase(
            url: fixtureURL("mybible-null-content.SQLite3")
        )
        XCTAssertEqual(
            try database.firstText(
                "SELECT text FROM verses WHERE verse = 2 ORDER BY _rowid_"
            ),
            "First duplicate"
        )

        let rows = try database.rows(
            """
            WITH RECURSIVE generated(value) AS (
                SELECT 1
                UNION ALL
                SELECT value + 1 FROM generated WHERE value < 100001
            )
            SELECT value FROM generated
            """
        ) { try database.integer($0, column: 0) }
        XCTAssertEqual(rows.count, 100_001)
        XCTAssertEqual(rows.first, 1)
        XCTAssertEqual(rows.last, 100_001)
    }

    /**
     Protects constant transient row lifetime for reducers that do not return every source row.

     - Setup: Streams 25,000 rows as reference-counted leases whose initializer and deinitializer
       record the maximum number alive at once.
     - Expected result: Every row is consumed and at most two transient leases overlap under ARC;
       implementing `consumeRows` through `rows` would retain all 25,000 and fail this contract.
     - Failure meaning: Chapter/commentary reducers can again allocate memory proportional to raw
       result cardinality in addition to their final output.
     - Side effects: Opens one fixture database read-only; the recursive CTE is ephemeral.
     */
    func testSQLiteRowConsumerDoesNotAccumulateTransformedRows() throws {
        let database = try SQLiteDocumentDatabase(
            url: fixtureURL("mybible-null-content.SQLite3")
        )
        let tracker = SQLiteRowLifetimeTracker()
        var consumed = 0

        try database.consumeRows(
            """
            WITH RECURSIVE generated(value) AS (
                SELECT 1
                UNION ALL
                SELECT value + 1 FROM generated WHERE value < 25000
            )
            SELECT value FROM generated
            """,
            transform: { statement in
                SQLiteRowLifetimeLease(
                    tracker: tracker,
                    value: try database.integer(statement, column: 0)
                )
            },
            consume: { lease in
                consumed += 1
                XCTAssertEqual(lease.value, consumed)
            }
        )

        XCTAssertEqual(consumed, 25_000)
        XCTAssertEqual(tracker.liveCount, 0)
        XCTAssertLessThanOrEqual(tracker.maximumLiveCount, 2)
    }

    /**
     Protects Requery's per-window accounting, refill, TEXT terminator, and oversized-row behavior.

     - Setup: Generates three 800 KiB rows, the largest one-column TEXT row that fits an empty
       CursorWindow, a row one byte larger after header/field/NUL accounting, and equivalent BLOB
       boundaries without a terminator.
     - Expected result: All three medium rows stream through refills, the exact row fits, and only
       the one-byte-oversized row throws the typed Android-window error.
     - Failure meaning: iOS is applying a cumulative payload budget or miscounting native window
       headers, field slots, alignment, or the TEXT terminator.
     - Side effects: Creates and removes one temporary SQLite database.
     */
    func testSQLiteCursorWindowRefillsAndRejectsOnlyAnOversizedSingleRow() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("payload-boundaries.SQLite3")
        try SQLiteDocumentTestDatabase.create(at: url, statements: [
            "CREATE TABLE payload (sequence INTEGER PRIMARY KEY, value TEXT)",
            """
            INSERT INTO payload VALUES
                (1, replace(hex(zeroblob(819200)), '00', 'x')),
                (2, replace(hex(zeroblob(819200)), '00', 'y')),
                (3, replace(hex(zeroblob(819200)), '00', 'z')),
                (4, replace(hex(zeroblob(2096719)), '00', 'q')),
                (5, replace(hex(zeroblob(2096720)), '00', 'r')),
                (6, zeroblob(2096720)),
                (7, zeroblob(2096721))
            """,
        ])
        let database = try SQLiteDocumentDatabase(url: url)

        let refillRows = try database.rows(
            "SELECT value FROM payload WHERE sequence <= 3 ORDER BY sequence"
        ) { try database.text($0, column: 0) }
        XCTAssertEqual(refillRows.map { $0.utf8.count }, [819_200, 819_200, 819_200])
        XCTAssertEqual(
            try database.firstText("SELECT value FROM payload WHERE sequence = 4")?.utf8.count,
            2_096_719
        )

        XCTAssertThrowsError(try database.firstText(
            "SELECT value FROM payload WHERE sequence = 5"
        )) { error in
            XCTAssertEqual(
                error as? SQLiteDocumentReaderError,
                .cursorWindowRowTooLarge(
                    fileName: url.lastPathComponent,
                    windowSize: SQLiteDocumentDatabase.androidCursorWindowByteCount
                )
            )
        }
        XCTAssertEqual(
            try database.firstRow(
                "SELECT value FROM payload WHERE sequence = 6",
                transform: { Int(sqlite3_column_bytes($0, 0)) }
            ),
            2_096_720
        )
        XCTAssertThrowsError(try database.firstRow(
            "SELECT value FROM payload WHERE sequence = 7",
            transform: { Int(sqlite3_column_bytes($0, 0)) }
        )) { error in
            XCTAssertEqual(
                error as? SQLiteDocumentReaderError,
                .cursorWindowRowTooLarge(
                    fileName: url.lastPathComponent,
                    windowSize: SQLiteDocumentDatabase.androidCursorWindowByteCount
                )
            )
        }
    }

    /**
     Protects task cancellation while SQLite is computing before its first result row.

     - Setup: Starts a billion-row recursive aggregate in a child task, then cancels after the
       query has entered SQLite's virtual machine.
     - Expected result: The shared progress handler returns `.cancelled` in under one second.
     - Failure meaning: Closing or replacing a module could leave expensive SQLite work running
       without a responsive interruption point.
     - Side effects: Creates and removes an empty temporary SQLite database; no rows are persisted.
     - Note: A 20 ms startup delay makes cancellation exercise the progress callback rather than
       only the pre-query cancellation check.
     */
    func testSQLiteProgressHandlerInterruptsCancelledLongRunningQueryPromptly() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cancellation-latency.SQLite3")
        try SQLiteDocumentTestDatabase.create(at: url, statements: [])

        let query = Task {
            let database = try SQLiteDocumentDatabase(url: url)
            return try database.scalarInteger(
                """
                WITH RECURSIVE generated(value) AS (
                    SELECT 1
                    UNION ALL
                    SELECT value + 1 FROM generated WHERE value < 1000000000
                )
                SELECT count(*) FROM generated
                """
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        let cancellationTime = Date()
        query.cancel()

        do {
            _ = try await query.value
            XCTFail("The recursive query completed after cancellation")
        } catch {
            XCTAssertEqual(
                error as? SQLiteDocumentReaderError,
                .cancelled(fileName: url.lastPathComponent)
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancellationTime), 1.0)
    }

    /**
     Protects cancellation before a queued retry reaches SQLite while another query remains active.

     - Setup: Starts a billion-row query, holds a second task at a test gate, cancels that task, then
       releases it while the first query is still running.
     - Expected result: The cancelled retry fails at the operation-owned connection boundary in
       under 250 ms; it neither waits behind nor interrupts the unrelated query.
     - Failure meaning: A layered blocking lock can occupy an executor thread or let cancellation
       poison shared module state before an uncancelled retry.
     - Side effects: Creates and removes one empty temporary SQLite database and cancels the long
       query during cleanup.
     */
    func testCancelledQueuedSQLiteRetryDoesNotWaitBehindAnotherQuery() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queued-cancellation.SQLite3")
        try SQLiteDocumentTestDatabase.create(at: url, statements: [])
        let database = try SQLiteDocumentDatabase(url: url)

        let blocker = Task {
            try database.scalarInteger(
                """
                WITH RECURSIVE generated(value) AS (
                    SELECT 1
                    UNION ALL
                    SELECT value + 1 FROM generated WHERE value < 1000000000
                )
                SELECT count(*) FROM generated
                """
            )
        }
        defer { blocker.cancel() }
        try await Task.sleep(for: .milliseconds(20))

        let gate = SQLiteDocumentTestGate()
        let queued = Task {
            await gate.wait()
            return try database.scalarInteger("SELECT 1")
        }
        while !(await gate.hasWaiter) {
            await Task.yield()
        }
        queued.cancel()
        let started = Date()
        await gate.release()

        do {
            _ = try await queued.value
            XCTFail("Cancelled retry unexpectedly executed")
        } catch {
            XCTAssertEqual(
                error as? SQLiteDocumentReaderError,
                .cancelled(fileName: url.lastPathComponent)
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)

        blocker.cancel()
        _ = try? await blocker.value
        XCTAssertEqual(try database.scalarInteger("SELECT 1"), 1)
    }

    /**
     Protects MyBible commentary schema detection and Android's covering-range query.

     - Setup: Opens a `commentaries` fixture containing a bounded range and an exact open-ended row.
     - Expected result: The starting coordinate is enumerable and Genesis 1:1 joins both rows using
       Kotlin's default `joinToString` separator.
     - Failure meaning: Commentary ranges would be miscategorized or return only part of Android's
       rendered content.
     - Side effects: Opens and closes the fixture database read-only.
     */
    func testMyBibleCommentaryFixtureUsesAndroidRangeSemantics() throws {
        let reader = try MyBibleReader(fileURL: fixtureURL("mybible-commentary.SQLite3"))

        XCTAssertEqual(reader.category, .commentary)
        XCTAssertTrue(reader.isCommentary)
        XCTAssertEqual(reader.language, "de")
        XCTAssertEqual(try reader.keys(), [.verse(book: 10, chapter: 1, verse: 1)])
        XCTAssertEqual(
            reader.getCommentary(book: 10, chapter: 1, verse: 1),
            "<div>Range commentary</div>, <div>Exact commentary</div>"
        )
        XCTAssertEqual(
            reader.getCommentary(book: 10, chapter: 1, verse: 2),
            "<div>Range commentary</div>"
        )
        XCTAssertEqual(reader.getCommentary(book: 10, chapter: 1, verse: 3), "")
    }

    /**
     Protects Android's observable independent comparisons for cross-chapter commentary ranges.

     - Setup: Opens a range spanning Genesis 1:31 through 2:2, an exact open-ended row at 2:1, and
       a same-chapter range covering 2:2 through 2:3.
     - Expected result: The spanning row is omitted because Android compares endpoint verse numbers
       independently; no-match coordinates return Kotlin's empty `joinToString` result.
     - Failure meaning: iOS output would differ from installed Android commentary at chapter edges.
     - Side effects: Opens and closes the fixture database read-only.
     */
    func testMyBibleCommentaryReproducesAndroidIndependentCrossChapterComparisons() throws {
        let reader = try MyBibleReader(fileURL: fixtureURL("mybible-cross-chapter.SQLite3"))

        XCTAssertEqual(reader.getCommentary(book: 10, chapter: 1, verse: 30), "")
        XCTAssertEqual(reader.getCommentary(book: 10, chapter: 1, verse: 31), "")
        XCTAssertEqual(reader.getCommentary(book: 10, chapter: 1, verse: 32), "")
        XCTAssertEqual(
            reader.getCommentary(book: 10, chapter: 2, verse: 1),
            "<div>Exact at chapter start</div>"
        )
        XCTAssertEqual(
            reader.getCommentary(book: 10, chapter: 2, verse: 2),
            "<div>Second range</div>"
        )
        XCTAssertEqual(
            reader.getCommentary(book: 10, chapter: 2, verse: 3),
            "<div>Second range</div>"
        )
        XCTAssertEqual(reader.getCommentary(book: 10, chapter: 2, verse: 4), "")
    }

    /**
     Protects MyBible dictionary topic enumeration and Strong's-definition metadata.

     - Setup: Opens a real `dictionary(topic, definition, ...)` fixture with `info.is_strong=true`.
     - Expected result: Exact topic keys and definitions are available through typed and legacy APIs.
     - Failure meaning: Android-restored Strong's dictionaries would disappear from later catalogs.
     - Side effects: Opens and closes the fixture database read-only.
     */
    func testMyBibleDictionaryFixtureExposesExactKeysAndDefinitions() throws {
        let reader = try MyBibleReader(fileURL: fixtureURL("mybible-dictionary.SQLite3"))

        XCTAssertEqual(reader.category, .dictionary)
        XCTAssertTrue(reader.isDictionary)
        XCTAssertTrue(reader.hasStrongsDefinitions)
        XCTAssertEqual(reader.dictionaryKeys(), ["G0001", "H0430"])
        XCTAssertEqual(reader.getDictionaryEntry(key: "H0430"), "Hebrew definition")
        XCTAssertNil(reader.getDictionaryEntry(key: "h0430"))
        XCTAssertEqual(
            try reader.content(for: .dictionary("G0001")),
            SQLiteDocumentContent(key: .dictionary("G0001"), text: "Greek definition")
        )
    }

    /**
     Protects Android's unsorted dictionary scan order, duplicate keys, and first-row lookup.

     - Setup: Creates MyBible and MySword dictionaries with `zeta`, `alpha`, `zeta` insertion order
       and distinct definitions for the duplicate rows.
     - Expected result: Both readers enumerate all rows in database order and exact lookup returns
       the first duplicate's content.
     - Failure meaning: Sorting or de-duplicating discovery would change Android dictionary menus,
       while repeated point scans could select a later conflicting definition.
     - Side effects: Creates and removes two temporary SQLite databases.
     */
    func testDictionaryReadersPreserveDatabaseOrderDuplicatesAndFirstLookupResult() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let myBibleURL = root.appendingPathComponent("ordered-dictionary.SQLite3")
        try SQLiteDocumentTestDatabase.create(at: myBibleURL, statements: [
            "CREATE TABLE info (name TEXT, value TEXT)",
            "INSERT INTO info VALUES ('description', 'Ordered MyBible dictionary')",
            "CREATE TABLE dictionary (topic TEXT, definition TEXT)",
            """
            INSERT INTO dictionary VALUES
                ('zeta', 'first zeta'),
                ('alpha', 'alpha definition'),
                ('zeta', 'second zeta')
            """,
        ])
        let mySwordURL = root.appendingPathComponent("ordered.dct.mybible")
        try SQLiteDocumentTestDatabase.create(at: mySwordURL, statements: [
            "CREATE TABLE Details (Description TEXT)",
            "INSERT INTO Details VALUES ('Ordered MySword dictionary')",
            "CREATE TABLE Dictionary (Word TEXT, Data TEXT)",
            """
            INSERT INTO Dictionary VALUES
                ('zeta', 'first zeta'),
                ('alpha', 'alpha definition'),
                ('zeta', 'second zeta')
            """,
        ])

        let myBible = try MyBibleReader(fileURL: myBibleURL)
        XCTAssertEqual(myBible.dictionaryKeys(), ["zeta", "alpha", "zeta"])
        XCTAssertEqual(myBible.getDictionaryEntry(key: "zeta"), "first zeta")

        let mySword = try MySwordReader(fileURL: mySwordURL)
        XCTAssertEqual(mySword.dictionaryKeys(), ["zeta", "alpha", "zeta"])
        XCTAssertEqual(mySword.getDictionaryEntry(key: "zeta"), "first zeta")
    }

    /**
     Protects Android text coercion while retaining complete SQLite TEXT byte sequences.

     - Setup: Stores embedded-NUL dictionary keys/content, a REAL scalar, and a BLOB scalar.
     - Expected result: Explicit text lengths survive enumeration and binding, REAL uses `%g`, and
       BLOB-to-text projection throws the typed storage-class error Android would surface.
     - Failure meaning: C-string truncation could alias dictionary entries, numeric metadata could
       drift, or binary payloads could be silently interpreted as document text.
     - Side effects: Creates and removes one temporary SQLite database.
     */
    func testSQLiteTextCoercionPreservesEmbeddedNULFormatsRealAndRejectsBlob() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("storage-coercion.SQLite3")
        try SQLiteDocumentTestDatabase.create(at: url, statements: [
            "CREATE TABLE info (name TEXT, value TEXT)",
            "INSERT INTO info VALUES ('description', 'Storage coercion dictionary')",
            "CREATE TABLE dictionary (topic TEXT, definition TEXT)",
            """
            INSERT INTO dictionary VALUES
                (CAST(X'610062' AS TEXT), CAST(X'630064' AS TEXT)),
                ('blob', X'6162')
            """,
            "CREATE TABLE values_table (real_value REAL)",
            "INSERT INTO values_table VALUES (1234567.0)",
        ])
        let reader = try MyBibleReader(fileURL: url)
        let key = "a\0b"
        XCTAssertEqual(reader.dictionaryKeys(), [key, "blob"])
        XCTAssertEqual(reader.getDictionaryEntry(key: key), "c\0d")
        XCTAssertThrowsError(try reader.content(for: .dictionary("blob"))) { error in
            XCTAssertEqual(
                error as? SQLiteDocumentReaderError,
                .unsupportedStorageClass(
                    fileName: url.lastPathComponent,
                    column: "definition",
                    expected: "text",
                    actual: "BLOB"
                )
            )
        }

        let database = try SQLiteDocumentDatabase(url: url)
        XCTAssertEqual(
            try database.firstText("SELECT real_value FROM values_table"),
            "1.23457e+06"
        )
    }

    /**
     Protects Android string selection arguments for coordinates in columns without type affinity.

     - Setup: Stores textual book, chapter, and verse values in typeless MyBible columns.
     - Expected result: Point and chapter reads match those rows because coordinates bind as text.
     - Failure meaning: Integer bindings would miss modules whose schema relies on Android
       `rawQuery` string arguments instead of declared numeric affinity.
     - Side effects: Creates and removes one temporary SQLite database.
     */
    func testTypelessCoordinatesMatchAndroidStringSelectionArguments() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("typeless-coordinates.SQLite3")
        try SQLiteDocumentTestDatabase.create(at: url, statements: [
            "CREATE TABLE info (name TEXT, value TEXT)",
            "INSERT INTO info VALUES ('description', 'Typeless coordinates')",
            "CREATE TABLE verses (book_number, chapter, verse, text)",
            "INSERT INTO verses VALUES ('10', '1', '1', 'Text-bound coordinate')",
        ])

        let reader = try MyBibleReader(fileURL: url)
        XCTAssertEqual(reader.getVerse(book: 10, chapter: 1, verse: 1), "Text-bound coordinate")
        XCTAssertEqual(
            try reader.chapterContent(book: 10, chapter: 1).map(\.text),
            ["Text-bound coordinate"]
        )
    }

    /**
     Protects compound MySword Bible filenames, one-row Details metadata, and Android tag conversion.

     - Setup: Opens `sample.bbl.mybible` with real `Details` and `Bible.Scripture` tables.
     - Expected result: Filename/category metadata and Strong's-plus-morphology conversion match
       `MySwordBook.kt`.
     - Failure meaning: Valid Android MySword Bibles would be rejected or expose raw pseudo-tags.
     - Side effects: Opens and closes the fixture database read-only.
     */
    func testMySwordBibleFixtureUsesCompoundSuffixDetailsAndScripture() throws {
        let reader = try MySwordReader(fileURL: fixtureURL("sample.bbl.mybible"))

        XCTAssertEqual(reader.fileType, .bible)
        XCTAssertEqual(reader.category, .bible)
        XCTAssertEqual(reader.metadata.initials, "MySword-sample_bbl")
        XCTAssertEqual(reader.metadata.title, "MySword Bible")
        XCTAssertEqual(reader.metadata.abbreviation, "MSB")
        XCTAssertEqual(reader.metadata.version, "0.0")
        XCTAssertEqual(reader.language, "eng")
        XCTAssertTrue(reader.metadata.hasStrongs)
        XCTAssertEqual(
            reader.getVerse(book: 1, chapter: 1, verse: 1),
            "<w lemma=\"strong:G123\" morph=\"strongMorph:N-NSM\">Word</w>"
        )
        XCTAssertEqual(try reader.keys().count, 2)
    }

    /**
     Protects MySword commentary `Data` content and Android verse-range matching.

     - Setup: Opens `sample.cmt.mybible` with bounded and exact open-ended commentary rows.
     - Expected result: Both matching rows are joined before MySword singleton tags are transformed.
     - Failure meaning: MySword commentary would query obsolete columns or lose covering rows.
     - Side effects: Opens and closes the fixture database read-only.
     */
    func testMySwordCommentaryFixtureReadsDataRanges() throws {
        let reader = try MySwordReader(fileURL: fixtureURL("sample.cmt.mybible"))

        XCTAssertEqual(reader.fileType, .commentary)
        XCTAssertEqual(reader.category, .commentary)
        XCTAssertEqual(try reader.keys(), [.verse(book: 1, chapter: 1, verse: 1)])
        XCTAssertEqual(
            reader.getCommentary(book: 1, chapter: 1, verse: 1),
            "<div>Range<CM/></div>, <div>Exact</div>"
        )
        XCTAssertEqual(
            reader.getCommentary(book: 1, chapter: 1, verse: 2),
            "<div>Range<CM/></div>"
        )
        XCTAssertEqual(reader.getCommentary(book: 1, chapter: 1, verse: 3), "")
    }

    /**
     Protects MySword dictionary `Word`/`Data` columns and installed metadata projection.

     - Setup: Opens `sample.dct.mybible` with a singleton `Details` row and two dictionary entries.
     - Expected result: Exact words are enumerable, pseudo Strong's tags become OSIS lemmas, and
       Android's generated config remains left-to-right despite a source RTL value.
     - Failure meaning: Android MySword dictionaries would be unreadable by a future shared catalog.
     - Side effects: Opens and closes the fixture database read-only.
     */
    func testMySwordDictionaryFixtureReadsWordAndDataColumns() throws {
        let reader = try MySwordReader(fileURL: fixtureURL("sample.dct.mybible"))

        XCTAssertEqual(reader.fileType, .dictionary)
        XCTAssertEqual(reader.category, .dictionary)
        XCTAssertEqual(reader.metadata.direction, .ltr)
        XCTAssertTrue(reader.metadata.isStrongsDictionary)
        XCTAssertEqual(reader.dictionaryKeys(), ["Elohim", "Logos"])
        XCTAssertEqual(
            reader.getDictionaryEntry(key: "Elohim"),
            "<w lemma=\"strong:H430\">term</w>"
        )
    }

    /**
     Protects MySword installed metadata defaults for empty, NULL, generated version, and RTL fields.

     - Setup: Creates one Details row with present empty strings and one with NULL fallback fields;
       both advertise a nonzero `RightToLeft` and source version.
     - Expected result: Empty strings remain empty, NULL abbreviation/language use Android's
       initials/`eng` defaults, generated Version is always `0.0`, and direction remains LTR despite
       the unused mixed-case `RightToLeft` lookup.
     - Failure meaning: Reinstalled MySword books would change identity labels, language grouping,
       version, or display direction relative to Android's generated SWORD configuration.
     - Side effects: Creates and removes two temporary SQLite databases.
     */
    func testMySwordInstalledMetadataPreservesEmptyValuesAndAndroidFallbacks() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let emptyURL = root.appendingPathComponent("empty.bbl.mybible")
        try SQLiteDocumentTestDatabase.create(at: emptyURL, statements: [
            """
            CREATE TABLE Details (
                Title TEXT, Description TEXT, Abbreviation TEXT, Version TEXT,
                RightToLeft INTEGER, Strong INTEGER, Language TEXT
            )
            """,
            "INSERT INTO Details VALUES ('', '', '', '9.9', 1, 0, '')",
            "CREATE TABLE Bible (Book INTEGER, Chapter INTEGER, Verse INTEGER, Scripture TEXT)",
            "INSERT INTO Bible VALUES (1, 1, 1, 'Empty metadata')",
        ])
        let nullURL = root.appendingPathComponent("nulls.bbl.mybible")
        try SQLiteDocumentTestDatabase.create(at: nullURL, statements: [
            """
            CREATE TABLE Details (
                Title TEXT, Description TEXT, Abbreviation TEXT, Version TEXT,
                RightToLeft INTEGER, Strong INTEGER, Language TEXT
            )
            """,
            "INSERT INTO Details VALUES (NULL, 'Null fallback', NULL, NULL, 1, 0, NULL)",
            "CREATE TABLE Bible (Book INTEGER, Chapter INTEGER, Verse INTEGER, Scripture TEXT)",
            "INSERT INTO Bible VALUES (1, 1, 1, 'Null metadata')",
        ])

        let empty = try MySwordReader(fileURL: emptyURL).metadata
        XCTAssertEqual(empty.title, "")
        XCTAssertEqual(empty.description, "")
        XCTAssertEqual(empty.abbreviation, "")
        XCTAssertEqual(empty.language, "")
        XCTAssertEqual(empty.version, "0.0")
        XCTAssertEqual(empty.direction, .ltr)

        let nulls = try MySwordReader(fileURL: nullURL).metadata
        XCTAssertEqual(nulls.title, "")
        XCTAssertEqual(nulls.description, "Null fallback")
        XCTAssertEqual(nulls.abbreviation, "MySword-nulls_bbl")
        XCTAssertEqual(nulls.language, "eng")
        XCTAssertEqual(nulls.version, "0.0")
        XCTAssertEqual(nulls.direction, .ltr)
    }

    /**
     Protects per-format Details projection and Requery `Cursor.getInt` storage coercion.

     - Setup: Gives MySword unused BLOB columns plus base-0 text Strong's metadata, and gives
       e-Sword octal-invalid RTL text plus a 64-bit integer that truncates to signed 32-bit one.
     - Expected result: Unused columns are never coerced, `0x1` and truncation enable Strong's,
       MySword emits generated version `0.0`, and e-Sword `08` parses as zero like `strtoll(base: 0)`.
     - Failure meaning: Generic Details decoding can reject Android-readable books or produce
       different feature/direction flags from Requery's cursor.
     - Side effects: Creates and removes two temporary SQLite databases.
     */
    func testDetailsProjectionUsesAndroidStorageClassAndBaseZeroIntegerSemantics() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mySwordURL = root.appendingPathComponent("details.bbl.mybible")
        try SQLiteDocumentTestDatabase.create(at: mySwordURL, statements: [
            """
            CREATE TABLE Details (
                Description TEXT, Version TEXT, RightToLeft BLOB, Strong TEXT, Unused BLOB
            )
            """,
            "INSERT INTO Details VALUES ('Projected', '7.4', X'AB', '0x1', X'CD')",
            "CREATE TABLE Bible (Book INTEGER, Chapter INTEGER, Verse INTEGER, Scripture TEXT)",
            "INSERT INTO Bible VALUES (1, 1, 1, 'Verse')",
        ])
        let mySword = try MySwordReader(fileURL: mySwordURL)
        XCTAssertEqual(mySword.metadata.version, "0.0")
        XCTAssertEqual(mySword.metadata.direction, .ltr)
        XCTAssertTrue(mySword.metadata.hasStrongs)

        let eSwordURL = root.appendingPathComponent("details.bbli")
        try SQLiteDocumentTestDatabase.create(at: eSwordURL, statements: [
            "CREATE TABLE Details (Description TEXT, RightToLeft TEXT, Strong INTEGER, Unused BLOB)",
            "INSERT INTO Details VALUES ('Projected', '08', 4294967297, X'EF')",
            "CREATE TABLE Bible (Book INTEGER, Chapter INTEGER, Verse INTEGER, Scripture TEXT)",
            "INSERT INTO Bible VALUES (1, 1, 1, 'Verse')",
        ])
        let eSword = try ESwordReader(fileURL: eSwordURL)
        XCTAssertEqual(eSword.metadata.direction, .ltr)
        XCTAssertTrue(eSword.metadata.hasStrongs)
    }

    /**
     Protects Java-regex ASCII boundaries in MySword pseudo-tag conversion.

     - Setup: Stores one ASCII Strong's token, one Greek word, and one token using Arabic-Indic
       digits in otherwise identical Bible rows.
     - Expected result: Only the ASCII `\w`/`\d` case is converted, matching Kotlin's default
       Java Pattern behavior; Unicode edge cases remain byte-for-text unchanged.
     - Failure meaning: ICU's broader character classes would transform module text Android leaves
       literal and could produce unintended OSIS markup.
     - Side effects: Creates and removes one temporary SQLite database.
     */
    func testMySwordPseudoTagsUseAndroidASCIIWordAndDigitClasses() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("unicode-tags.bbl.mybible")
        try SQLiteDocumentTestDatabase.create(at: url, statements: [
            "CREATE TABLE Details (Description TEXT)",
            "INSERT INTO Details VALUES ('Unicode pseudo-tags')",
            "CREATE TABLE Bible (Book INTEGER, Chapter INTEGER, Verse INTEGER, Scripture TEXT)",
            """
            INSERT INTO Bible VALUES
                (1, 1, 1, 'word<WG3056>'),
                (1, 1, 2, 'λόγος<WG3056>'),
                (1, 1, 3, 'word<WG١٢>')
            """,
        ])
        let reader = try MySwordReader(fileURL: url)

        XCTAssertEqual(
            reader.getVerse(book: 1, chapter: 1, verse: 1),
            "<w lemma=\"strong:G3056\">word</w>"
        )
        XCTAssertEqual(reader.getVerse(book: 1, chapter: 1, verse: 2), "λόγος<WG3056>")
        XCTAssertEqual(reader.getVerse(book: 1, chapter: 1, verse: 3), "word<WG١٢>")
    }

    /**
     Protects e-Sword `.bblx` one-row metadata, Bible keys, and RTF-to-OSIS content conversion.

     - Setup: Opens the real `.bblx` fixture containing Android-style RTF control words.
     - Expected result: Metadata aliases are projected and Scripture formatting/XML escaping match
       `ESwordBook.convertRtfToOsis`.
     - Failure meaning: Legacy e-Sword Bibles would expose unreadable RTF or unsafe XML text.
     - Side effects: Opens and closes the fixture database read-only.
     */
    func testESwordBBLXFixtureConvertsRTFContent() throws {
        let reader = try ESwordReader(fileURL: fixtureURL("sample.bblx"))

        XCTAssertEqual(reader.fileType, .bblx)
        XCTAssertEqual(reader.category, .bible)
        XCTAssertEqual(reader.metadata.initials, "ESword-sample")
        XCTAssertEqual(reader.metadata.description, "e-Sword RTF Fixture")
        XCTAssertTrue(reader.metadata.hasStrongs)
        XCTAssertEqual(try reader.keys().count, 2)
        XCTAssertEqual(
            reader.getVerse(book: 1, chapter: 1, verse: 1),
            "In the <hi type=\"bold\">beginning</hi> God created."
        )
        XCTAssertEqual(
            reader.getVerse(book: 1, chapter: 1, verse: 2),
            "a &lt; b &amp; c &gt; d"
        )
    }

    /**
     Protects `.bbli` plain-text passthrough and e-Sword metadata aliases.

     - Setup: Opens the real `.bbli` fixture whose `Details` uses `Title` and `Strongs` aliases.
     - Expected result: Text containing XML-significant characters remains byte-for-text unchanged,
       while title metadata is retained and generated configuration defaults direction to LTR.
     - Failure meaning: Plain e-Sword modules would be incorrectly fed through the RTF/XML parser.
     - Side effects: Opens and closes the fixture database read-only.
     */
    func testESwordBBLIFixturePassesPlainTextThrough() throws {
        let reader = try ESwordReader(fileURL: fixtureURL("sample.bbli"))

        XCTAssertEqual(reader.fileType, .bbli)
        XCTAssertEqual(reader.metadata.title, "e-Sword Plain Fixture")
        XCTAssertEqual(reader.metadata.direction, .ltr)
        XCTAssertEqual(
            reader.getVerse(book: 1, chapter: 1, verse: 1),
            "Plain <text> stays unchanged & readable"
        )
    }

    /**
     Protects SQLite numeric metadata conversion, nullable verses, and decoded RTF XML escaping.

     - Setup: Opens a `.bblx` fixture with REAL `1.0` boolean metadata, a NULL Scripture row, and
       hex- plus Unicode-encoded `<`, `>`, and `&` characters.
     - Expected result: REAL booleans match Android `Cursor.getInt`, the NULL row resolves to empty
       content, both decoded escape forms pass through XML escaping, and unused Version metadata is
       not projected by the e-Sword backend.
     - Failure meaning: Valid metadata could be misclassified, blank verses could vanish, or encoded
       control data could inject malformed XML into rendered content.
     - Side effects: Opens and closes the fixture database read-only.
     */
    func testESwordNumericMetadataNullVerseAndDecodedRTFAreHandled() throws {
        let reader = try ESwordReader(fileURL: fixtureURL("esword-numeric-storage.bblx"))

        XCTAssertEqual(reader.metadata.direction, .ltr)
        XCTAssertTrue(reader.metadata.hasStrongs)
        XCTAssertEqual(
            try reader.keys(),
            [
                .verse(book: 1, chapter: 1, verse: 1),
                .verse(book: 1, chapter: 1, verse: 2),
                .verse(book: 1, chapter: 1, verse: 3),
            ]
        )
        XCTAssertEqual(reader.getVerse(book: 1, chapter: 1, verse: 1), "")
        XCTAssertNil(reader.getVerse(book: 1, chapter: 1, verse: 4))
        XCTAssertEqual(reader.getVerse(book: 1, chapter: 1, verse: 2), "&lt;&gt;&amp;")
        XCTAssertEqual(reader.getVerse(book: 1, chapter: 1, verse: 3), "&lt;&gt;&amp;")
        XCTAssertEqual(reader.getChapter(book: 1, chapter: 1).map(\.verse), [1, 2, 3])
        XCTAssertEqual(reader.getChapter(book: 1, chapter: 1).first?.text, "")

        let details = try SQLiteDocumentDatabase(
            url: fixtureURL("esword-numeric-storage.bblx")
        ).firstDetailsRow(format: .eSword)
        XCTAssertNil(details["version"])
    }

    /**
     Ports safe formatting cases from Android `convertRtfToOsis` independently of SQLite lookup.

     - Setup: Uses formatting, skipped destination, hex, Unicode, line-break, escaped-character,
       valid raw-fragment, and malformed raw-fragment Android oracles.
     - Expected result: Safe output matches Android byte-for-text. Android's exact malformed raw
       result fails XML parsing, while iOS preserves its visible text as escaped valid OSIS.
     - Failure meaning: Parser changes could silently corrupt real `.bblx` text despite schema tests.
     - Side effects: None; conversion is deterministic and in-memory.
     */
    func testESwordRTFConversionMatchesAndroidForSafeFormattingCases() {
        let androidMalformedRawResult = "Hello <world>"
        XCTAssertFalse(
            XMLParser(data: Data("<root>\(androidMalformedRawResult)</root>".utf8)).parse()
        )
        XCTAssertEqual(
            ESwordReader.convertRTFToOSIS(androidMalformedRawResult),
            "Hello &lt;world&gt;"
        )
        XCTAssertEqual(
            ESwordReader.convertRTFToOSIS("Hello <hi>world</hi>"),
            "Hello <hi>world</hi>"
        )
        XCTAssertEqual(
            ESwordReader.convertRTFToOSIS("\\b Bold\\b0  \\i italic\\i0 "),
            "<hi type=\"bold\">Bold</hi> <hi type=\"italic\">italic</hi>"
        )
        XCTAssertEqual(ESwordReader.convertRTFToOSIS("\\line\\par "), "<lb/><lb/>")
        XCTAssertEqual(
            ESwordReader.convertRTFToOSIS("\\super 1\\nosupersub  text"),
            "<hi type=\"super\">1</hi> text"
        )
        XCTAssertEqual(ESwordReader.convertRTFToOSIS("\\'e9"), "\u{00E9}")
        XCTAssertEqual(ESwordReader.convertRTFToOSIS("\\u8212? text"), "\u{2014} text")
        XCTAssertEqual(
            ESwordReader.convertRTFToOSIS("{\\fonttbl{\\f0 Times;}}Hello"),
            "Hello"
        )
        XCTAssertEqual(
            ESwordReader.convertRTFToOSIS("\\cf1 a\\\\b\\{c\\}d"),
            "a\\b{c}d"
        )
    }

    /**
     Protects Unicode control scanning and iOS XML escaping for decoded RTF data.

     - Setup: Uses a non-ASCII control word and decimal parameter accepted by Kotlin `Char`
       classification, plus hex and Unicode escapes that decode XML-significant characters.
     - Expected result: The unknown Unicode control is consumed like Android. Decoded markup retains
       the same visible characters through the safety-preserving valid-OSIS projection.
     - Failure meaning: Unicode controls could leak into verse text or encoded data could inject
       malformed XML into an OSIS fragment.
     - Side effects: None; conversion is deterministic and in-memory.
     */
    func testESwordRTFUnicodeControlsAndDecodedMarkupRemainStructurallySafe() {
        XCTAssertEqual(ESwordReader.convertRTFToOSIS("\\é١ text"), "text")
        XCTAssertEqual(ESwordReader.convertRTFToOSIS("\\'3c\\'3e\\'26"), "&lt;&gt;&amp;")
        XCTAssertEqual(ESwordReader.convertRTFToOSIS("\\u60?\\u62?\\u38?"), "&lt;&gt;&amp;")
        XCTAssertEqual(ESwordReader.convertRTFToOSIS("\\u1?"), "\u{FFFD}")
        XCTAssertEqual(
            XMLParser(data: Data("<root>\(ESwordReader.convertRTFToOSIS("\\b A\\u1?B\\b0 "))</root>".utf8)).parse(),
            true
        )
    }

    /**
     Pins Kotlin `String.toIntOrNull` signed 32-bit bounds for e-Sword RTF parameters.

     - Setup: Uses Unicode controls one above `Int.MAX_VALUE` and one below `Int.MIN_VALUE`.
     - Expected result: Android rejects each parameter, skips its fallback character, and emits no
       decoded code unit; surrounding text remains visible and structurally valid.
     - Failure meaning: Host-width Swift integer parsing can truncate out-of-range controls into
       spurious verse characters that Android never emits.
     - Side effects: None; conversion is deterministic and in-memory.
     */
    func testESwordRTFParametersUseKotlinInt32Bounds() {
        XCTAssertEqual(ESwordReader.convertRTFToOSIS("{A\\u2147483648?B}"), "AB")
        XCTAssertEqual(ESwordReader.convertRTFToOSIS("{A\\u-2147483649?B}"), "AB")
    }

    /**
     Protects JVM `Character.digit(char, 16)` rather than Swift's broader numeric conversion.

     - Setup: Decodes fullwidth hexadecimal letters, every OpenJDK 17 BMP decimal-digit block, and
       superscript numeric characters through e-Sword's two-character hex escape.
     - Expected result: Fullwidth and all Java decimal-digit forms decode exactly; superscript
       numerics are rejected because Java does not classify them as radix-16 digits.
     - Failure meaning: e-Sword content can diverge from Android or convert characters JSword leaves
       as malformed control input.
     - Side effects: None; conversion is deterministic and in-memory.
     */
    func testESwordHexEscapesMatchJVMCharacterDigit() {
        XCTAssertEqual(ESwordReader.convertRTFToOSIS("\\'ＦＦ"), "ÿ")
        XCTAssertEqual(ESwordReader.convertRTFToOSIS("\\'٤١"), "A")
        XCTAssertEqual(ESwordReader.convertRTFToOSIS("\\'²²"), "")

        let decimalBlockStarts: [UInt32] = [
            0x0030, 0x0660, 0x06F0, 0x07C0, 0x0966, 0x09E6, 0x0A66, 0x0AE6,
            0x0B66, 0x0BE6, 0x0C66, 0x0CE6, 0x0D66, 0x0DE6, 0x0E50, 0x0ED0,
            0x0F20, 0x1040, 0x1090, 0x17E0, 0x1810, 0x1946, 0x19D0, 0x1A80,
            0x1A90, 0x1B50, 0x1BB0, 0x1C40, 0x1C50, 0xA620, 0xA8D0, 0xA900,
            0xA9D0, 0xA9F0, 0xAA50, 0xABF0, 0xFF10,
        ]
        for start in decimalBlockStarts {
            let four = String(UnicodeScalar(start + 4)!)
            let one = String(UnicodeScalar(start + 1)!)
            XCTAssertEqual(
                ESwordReader.convertRTFToOSIS("\\'\(four)\(one)"),
                "A",
                "OpenJDK decimal block U+\(String(start, radix: 16, uppercase: true)) diverged"
            )
        }
    }

    /**
     Protects Android's format-specific discovery depth and filename semantics.

     - Setup: Copies real fixtures into temporary direct/nested module directories and adds generic,
       uppercase-category, and obsolete MySword suffixes.
     - Expected result: MyBible/MySword recurse, every outer `.mybible` candidate is discoverable,
       unknown category tokens remain installed as OTHER, and e-Sword scans only direct files.
     - Failure meaning: Restored modules would be omitted or unsupported files misclassified.
     - Side effects: Creates and removes a temporary directory tree and copies fixture databases.
     */
    func testDiscoveryMatchesAndroidDepthAndSuffixRules() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let myBibleRoot = root.appendingPathComponent("mybible", isDirectory: true)
        let myBibleNested = myBibleRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: myBibleNested, withIntermediateDirectories: true)
        try copyFixture("mybible-bible.SQLite3", to: myBibleNested.appendingPathComponent("UPPER.SQLITE3"))
        try Data().write(to: myBibleRoot.appendingPathComponent("ignored.sqlite"))

        let mySwordRoot = root.appendingPathComponent("mysword", isDirectory: true)
        let mySwordNested = mySwordRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: mySwordNested, withIntermediateDirectories: true)
        for name in ["sample.bbl.mybible", "sample.cmt.mybible", "sample.dct.mybible"] {
            try copyFixture(name, to: mySwordNested.appendingPathComponent(name))
        }
        try copyFixture(
            "sample.bbl.mybible",
            to: mySwordRoot.appendingPathComponent("legacy.bbl")
        )
        let uppercaseCategory = mySwordRoot.appendingPathComponent("UPPER.BBL.MYBIBLE")
        let generic = mySwordRoot.appendingPathComponent("generic.mybible")
        try copyFixture("sample.bbl.mybible", to: uppercaseCategory)
        try copyFixture("sample.bbl.mybible", to: generic)

        let eSwordRoot = root.appendingPathComponent("esword", isDirectory: true)
        let eSwordNested = eSwordRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: eSwordNested, withIntermediateDirectories: true)
        try copyFixture("sample.bblx", to: eSwordRoot.appendingPathComponent("DIRECT.BBLX"))
        try copyFixture("sample.bbli", to: eSwordNested.appendingPathComponent("nested.bbli"))

        XCTAssertEqual(MyBibleReader.discover(in: myBibleRoot).map(\.lastPathComponent), ["UPPER.SQLITE3"])
        XCTAssertEqual(
            Set(MySwordReader.discover(in: mySwordRoot).map(\.lastPathComponent)),
            Set([
                "UPPER.BBL.MYBIBLE",
                "generic.mybible",
                "sample.bbl.mybible",
                "sample.cmt.mybible",
                "sample.dct.mybible",
            ])
        )
        XCTAssertEqual(try MySwordReader(fileURL: uppercaseCategory).fileType, .other)
        XCTAssertEqual(try MySwordReader(fileURL: generic).fileType, .other)
        XCTAssertEqual(ESwordReader.discover(in: eSwordRoot).map(\.lastPathComponent), ["DIRECT.BBLX"])
    }

    /**
     Pins Android-visible MySword OTHER registration for an unknown compound suffix.

     - Setup: Copies a valid Details database to `generic.mybible`, whose category token is unknown.
     - Expected result: Discovery installs one OTHER module with JSword's generated `zText` driver,
       version `0.0`, LTR direction, and no category-specific keys.
     - Failure meaning: Android-visible restored modules can disappear merely because their suffix is
       not one of the three content-bearing MySword tokens.
     - Side effects: Creates and removes one temporary module root and fixture copy.
     */
    func testMySwordUnknownSuffixRegistersAsAndroidOtherModule() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mySwordRoot = root.appendingPathComponent("mysword", isDirectory: true)
        try FileManager.default.createDirectory(at: mySwordRoot, withIntermediateDirectories: true)
        try copyFixture(
            "sample.bbl.mybible",
            to: mySwordRoot.appendingPathComponent("generic.mybible")
        )

        let library = SQLiteDocumentModuleLibrary(moduleRootURL: root)
        let module = try XCTUnwrap(library.module(named: "MySword-generic"))

        XCTAssertEqual(library.modules(category: .unknown).map(\.info.name), ["MySword-generic"])
        XCTAssertEqual(module.info.category, .unknown)
        XCTAssertEqual(module.info.moduleDriver, "zText")
        XCTAssertEqual(module.info.version, "0.0")
        XCTAssertFalse(module.info.isRightToLeft)
        XCTAssertEqual((module.reader as? MySwordReader)?.fileType, .other)
        XCTAssertEqual(try module.reader.keys(), [])
    }

    /**
     Protects bounded discovery while retaining readable symlinks whose targets stay inside a root.

     - Setup: Creates internal file and directory symlinks, external file and directory symlinks, and
       a directory cycle in the MyBible family root.
     - Expected result: Safe in-root aliases are traversable like Android. Targets outside the trusted
       root remain excluded, and traversal terminates without revisiting the cycle.
     - Failure meaning: Discovery could omit Android-visible internal modules, escape its assigned
       root, or loop indefinitely on an untrusted restore tree.
     - Side effects: Creates and removes temporary files, directories, and symbolic links.
     */
    func testDiscoveryAllowsInternalFileSymlinksAndBoundsCyclesAndTraversal() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let myBibleRoot = root.appendingPathComponent("mybible", isDirectory: true)
        let inside = myBibleRoot.appendingPathComponent("inside", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let module = inside.appendingPathComponent("module.SQLite3")
        try copyFixture("mybible-bible.SQLite3", to: module)
        try FileManager.default.createSymbolicLink(
            at: myBibleRoot.appendingPathComponent("alias.SQLite3"),
            withDestinationURL: module
        )
        try FileManager.default.createSymbolicLink(
            at: inside.appendingPathComponent("cycle", isDirectory: true),
            withDestinationURL: myBibleRoot
        )
        let directoryAlias = myBibleRoot.appendingPathComponent("inside-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: inside)

        let outside = root.appendingPathComponent("outside.SQLite3")
        try copyFixture("mybible-bible.SQLite3", to: outside)
        try FileManager.default.createSymbolicLink(
            at: myBibleRoot.appendingPathComponent("external.SQLite3"),
            withDestinationURL: outside
        )
        let outsideDirectory = root.appendingPathComponent("outside-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideNested = outsideDirectory.appendingPathComponent("nested.SQLite3")
        try copyFixture("mybible-bible.SQLite3", to: outsideNested)
        try FileManager.default.createSymbolicLink(
            at: myBibleRoot.appendingPathComponent("external-directory", isDirectory: true),
            withDestinationURL: outsideDirectory
        )

        let discovered = MyBibleReader.discover(in: myBibleRoot)
        XCTAssertEqual(
            Set(discovered.map(\.lastPathComponent)),
            Set(["alias.SQLite3", "module.SQLite3"])
        )
        XCTAssertEqual(MyBibleReader.discover(in: directoryAlias).map(\.lastPathComponent), ["module.SQLite3"])
        XCTAssertFalse(discovered.contains {
            $0.resolvingSymlinksInPath().standardizedFileURL == outsideNested.standardizedFileURL
        })
    }

    /**
     Protects Android-visible hidden descendants and traversal beyond prior iOS depth/count guards.

     - Setup: Creates a hidden module, one module beneath seventy nested directories, and 10,050
       direct candidate files.
     - Expected result: Discovery returns every candidate, including the hidden and deep files,
       without imposing an iOS-only depth or entry ceiling.
     - Failure meaning: Restored Android modules can disappear silently based on path shape or
       directory population.
     - Side effects: Creates and removes a large temporary filesystem fixture.
     */
    func testMyBibleDiscoveryIncludesHiddenDeepAndHighEntryCountModules() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let myBibleRoot = root.appendingPathComponent("mybible", isDirectory: true)
        try FileManager.default.createDirectory(at: myBibleRoot, withIntermediateDirectories: true)
        try Data().write(to: myBibleRoot.appendingPathComponent(".hidden.SQLite3"))

        var deepDirectory = myBibleRoot
        for depth in 0..<70 {
            deepDirectory.appendPathComponent("d\(depth)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: deepDirectory, withIntermediateDirectories: true)
        try Data().write(to: deepDirectory.appendingPathComponent("deep.SQLite3"))
        for index in 0..<10_050 {
            try Data().write(
                to: myBibleRoot.appendingPathComponent("candidate-\(index).SQLite3")
            )
        }

        let discovered = MyBibleReader.discover(in: myBibleRoot)
        XCTAssertEqual(discovered.count, 10_052)
        XCTAssertTrue(discovered.contains { $0.lastPathComponent == ".hidden.SQLite3" })
        XCTAssertTrue(discovered.contains { $0.lastPathComponent == "deep.SQLite3" })
    }

    /**
     Protects the deliberate sanitizer difference between e-Sword and the two historical readers.

     - Setup: Copies valid fixtures to filenames containing square brackets, which Java's `A-z`
       range retains but e-Sword's exact `A-Za-z` range rejects.
     - Expected result: MyBible and MySword initials preserve brackets, while e-Sword replaces each
       bracket with an underscore and still opens the module.
     - Failure meaning: Module identity could drift from Android and collide with or orphan an
       installed module after catalog reconstruction.
     - Side effects: Creates and removes temporary fixture copies; source databases stay unchanged.
     */
    func testFilenameSanitizersKeepFormatSpecificAndroidRanges() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let myBibleURL = root.appendingPathComponent("name[part].SQLite3")
        let mySwordURL = root.appendingPathComponent("name[part].bbl.mybible")
        let eSwordURL = root.appendingPathComponent("name[part].bblx")
        try copyFixture("mybible-bible.SQLite3", to: myBibleURL)
        try copyFixture("sample.bbl.mybible", to: mySwordURL)
        try copyFixture("sample.bblx", to: eSwordURL)

        XCTAssertEqual(
            try MyBibleReader(fileURL: myBibleURL).metadata.initials,
            "MyBible-name[part]"
        )
        XCTAssertEqual(
            try MySwordReader(fileURL: mySwordURL).metadata.initials,
            "MySword-name[part]_bbl"
        )
        XCTAssertEqual(
            try ESwordReader(fileURL: eSwordURL).metadata.initials,
            "ESword-name_part_"
        )
    }

    /**
     Protects eager failure only for MyBible metadata Android reads during installation.

     - Setup: Opens a real SQLite fixture with a discoverable `verses` table but no `info` source.
     - Expected result: Initialization fails when its required metadata query reaches SQLite.
     - Failure meaning: The lazy-content contract could accidentally suppress a failure Android
       also encounters while constructing installed metadata.
     - Side effects: Opens and closes the fixture database read-only.
     */
    func testMyBibleMissingRequiredInfoFailsDuringMetadataRead() {
        XCTAssertThrowsError(try MyBibleReader(
            fileURL: fixtureURL("invalid-mybible-missing-info.SQLite3")
        )) { error in
            guard case .queryFailed(let fileName, let message) = error as? SQLiteDocumentReaderError
            else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(fileName, "invalid-mybible-missing-info.SQLite3")
            XCTAssertTrue(message.lowercased().contains("info"))
        }
    }

    /**
     Protects Android's lazy MySword content-schema access.

     - Setup: Opens a real compound-suffix database whose Bible table incorrectly uses `Text`.
     - Expected result: Details metadata and coordinate keys remain readable; only Scripture access
       fails when the malformed optional content column is queried.
     - Failure meaning: Installation could reject a module before Android would touch its content.
     - Side effects: Opens and closes the fixture database read-only.
     */
    func testMySwordMalformedScriptureFailsOnlyWhenContentIsAccessed() throws {
        let reader = try MySwordReader(
            fileURL: fixtureURL("mysword-lazy-missing-scripture.bbl.mybible")
        )

        XCTAssertEqual(reader.metadata.description, "Invalid MySword")
        XCTAssertEqual(try reader.keys(), [.verse(book: 1, chapter: 1, verse: 1)])
        XCTAssertThrowsError(try reader.content(
            for: .verse(book: 1, chapter: 1, verse: 1)
        )) { error in
            guard case .queryFailed = error as? SQLiteDocumentReaderError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    /**
     Protects lazy MyBible content and story schema behavior independently.

     - Setup: Creates one Bible without `verses.text` and another whose `stories` table lacks title.
     - Expected result: Both initialize and enumerate coordinates; each fails only when the affected
       content path is accessed.
     - Failure meaning: Optional malformed data could hide an otherwise installable Android module.
     - Side effects: Creates and removes two temporary SQLite databases.
     */
    func testMyBibleMalformedContentAndStoriesFailOnlyOnAffectedAccess() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contentURL = root.appendingPathComponent("lazy-missing-content.SQLite3")
        try SQLiteDocumentTestDatabase.create(at: contentURL, statements: [
            "CREATE TABLE info (name TEXT, value TEXT)",
            "INSERT INTO info VALUES ('description', 'Lazy malformed content')",
            "CREATE TABLE verses (book_number INTEGER, chapter INTEGER, verse INTEGER)",
            "INSERT INTO verses VALUES (10, 1, 1)",
        ])
        let storiesURL = root.appendingPathComponent("lazy-missing-story-title.SQLite3")
        try SQLiteDocumentTestDatabase.create(at: storiesURL, statements: [
            "CREATE TABLE info (name TEXT, value TEXT)",
            "INSERT INTO info VALUES ('description', 'Lazy malformed stories')",
            "CREATE TABLE verses (book_number INTEGER, chapter INTEGER, verse INTEGER, text TEXT)",
            "INSERT INTO verses VALUES (10, 1, 1, 'Readable verse')",
            "CREATE TABLE stories (book_number INTEGER, chapter INTEGER, verse INTEGER)",
            "INSERT INTO stories VALUES (10, 1, 1)",
        ])

        for reader in [
            try MyBibleReader(fileURL: contentURL),
            try MyBibleReader(fileURL: storiesURL),
        ] {
            XCTAssertEqual(try reader.keys(), [.verse(book: 10, chapter: 1, verse: 1)])
            XCTAssertThrowsError(try reader.content(
                for: .verse(book: 10, chapter: 1, verse: 1)
            )) { error in
                guard case .queryFailed = error as? SQLiteDocumentReaderError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    /**
     Protects Android first-row Details semantics without hidden rowid dependencies.

     - Setup: Creates a case-variant `Details` view with two rows and a case-variant e-Sword Bible
       table declared `WITHOUT ROWID`.
     - Expected result: Initialization uses the view's first row, ignores the second metadata row,
       and key/content reads succeed without `_rowid_`.
     - Failure meaning: SQLite layouts accepted by Android could be rejected by eager cardinality
       checks or implicit rowid ordering.
     - Side effects: Creates and removes one temporary SQLite database.
     */
    func testESwordAcceptsFirstDetailsViewRowAndWithoutRowIDBible() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("details-view-without-rowid.bbli")
        try SQLiteDocumentTestDatabase.create(at: url, statements: [
            "CREATE TABLE metadata_source (Description TEXT, Abbreviation TEXT)",
            "INSERT INTO metadata_source VALUES ('First details row', 'FIRST'), ('Second details row', 'SECOND')",
            "CREATE VIEW dEtAiLs AS SELECT Description, Abbreviation FROM metadata_source",
            """
            CREATE TABLE bIbLe (
                Book INTEGER, Chapter INTEGER, Verse INTEGER, Scripture TEXT,
                PRIMARY KEY (Book, Chapter, Verse)
            ) WITHOUT ROWID
            """,
            "INSERT INTO bIbLe VALUES (1, 1, 1, 'Readable without rowid')",
        ])

        let reader = try ESwordReader(fileURL: url)
        XCTAssertEqual(reader.metadata.description, "First details row")
        XCTAssertEqual(reader.metadata.abbreviation, "FIRST")
        XCTAssertEqual(try reader.keys(), [.verse(book: 1, chapter: 1, verse: 1)])
        XCTAssertEqual(reader.getVerse(book: 1, chapter: 1, verse: 1), "Readable without rowid")
    }

    /** Returns one checked-in real SQLite fixture URL relative to this source file. */
    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("SQLiteDocumentReaders", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    /**
     Creates a unique directory for filesystem discovery assertions.

     - Returns: Existing empty temporary directory URL.
     - Side effects: Creates one directory under `FileManager.default.temporaryDirectory`.
     - Throws: A filesystem error when directory creation fails.
     */
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-reader-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /**
     Copies one checked-in SQLite fixture to a temporary discovery path.

     - Parameters:
       - name: Fixture filename under `SQLiteDocumentReaders`.
       - destinationURL: Exact destination filename used by suffix/depth assertions.
     - Side effects: Copies a database file without changing its SQLite contents.
     - Throws: A filesystem error when the source is absent or copying fails.
     */
    private func copyFixture(_ name: String, to destinationURL: URL) throws {
        try FileManager.default.copyItem(at: fixtureURL(name), to: destinationURL)
    }
}

/** Records reference lifetime across one synchronous SQLite row-consumer invocation. */
private final class SQLiteRowLifetimeTracker {
    /// Number of transformed row leases currently alive.
    private(set) var liveCount = 0

    /// Highest simultaneous transformed row lease count.
    private(set) var maximumLiveCount = 0

    /** Records construction of one transformed row lease. */
    func didCreateLease() {
        liveCount += 1
        maximumLiveCount = max(maximumLiveCount, liveCount)
    }

    /** Records deterministic ARC release of one transformed row lease. */
    func didDestroyLease() {
        liveCount -= 1
    }
}

/** Reference-valued transformed row whose lifetime exposes accidental whole-result retention. */
private final class SQLiteRowLifetimeLease {
    /// Shared lifetime counter retained until this row value is released.
    private let tracker: SQLiteRowLifetimeTracker

    /// Sequential source value used to prove every row reached the consumer.
    let value: Int

    /** Creates and records one live transformed row value. */
    init(tracker: SQLiteRowLifetimeTracker, value: Int) {
        self.tracker = tracker
        self.value = value
        tracker.didCreateLease()
    }

    /** Records release so the test can bound simultaneous transient values. */
    deinit {
        tracker.didDestroyLease()
    }
}

/**
 Transfers one non-Sendable real reader into a controlled concurrency stress test.

 Production intentionally omits `Sendable`; this private test wrapper is the only escape hatch and
 performs no access itself. The enclosed reader's database lock is the behavior under test.
 */
private final class ConcurrentMyBibleReaderHarness: @unchecked Sendable {
    /// Reader accessed only by the bounded workers created in the owning test.
    let reader: MyBibleReader

    /** Retains the reader for a single test's concurrent worker lifetime. */
    init(reader: MyBibleReader) {
        self.reader = reader
    }
}

/** Collects concurrent stress failures without invoking XCTest assertions off the test thread. */
private final class SQLiteDocumentConcurrentFailureRecorder: @unchecked Sendable {
    /// Protects mutation and snapshots of the diagnostic array.
    private let lock = NSLock()

    /// Human-readable failures recorded by workers before they stop.
    private var storedMessages: [String] = []

    /** Records one worker error while excluding concurrent array mutation. */
    func record(_ error: Error) {
        lock.lock()
        storedMessages.append(String(describing: error))
        lock.unlock()
    }

    /** Returns an immutable failure snapshot for assertions on the XCTest thread. */
    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedMessages
    }
}

/** Stable sentinel failures for incorrect values observed during reader stress. */
private enum SQLiteDocumentConcurrentAssertionFailure: Error {
    /// Key enumeration returned a partial or duplicated count different from the fixture.
    case unexpectedKeys

    /// Point lookup returned a non-first duplicate or absent value.
    case unexpectedContent

    /// Chapter projection did not retain one first row per coordinate.
    case unexpectedChapter

    /// Malformed optional book metadata unexpectedly produced a partial catalog row.
    case unexpectedBooks
}

/** One-shot async gate used to cancel a query before it enters the SQLite operation boundary. */
private actor SQLiteDocumentTestGate {
    /// Suspended waiter resumed by `release()`.
    private var continuation: CheckedContinuation<Void, Never>?

    /// Whether a task has reached the gate and installed its continuation.
    var hasWaiter: Bool { continuation != nil }

    /** Suspends one caller until the test releases it. */
    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    /** Resumes the current waiter exactly once. */
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
