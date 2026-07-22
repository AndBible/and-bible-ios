import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import SwordKit

/** Tests exact Android installed-book behavior across the backend-neutral scripture boundary. */
final class InstalledScriptureSourceTests: XCTestCase {
    /**
     Verifies a SQLite passage crosses KJVA's chapter-introduction slot without losing real verses.

     - Setup: A sparse MyBible source contains only Genesis 1:31 and Genesis 2:1.
     - Expected result: Both rows are returned in canonical order and adjacency ignores only the
       chapter-introduction ordinal between them.
     - Failure meaning: Copy, Compare, links, or speech would truncate a cross-chapter selection or
       treat a KJVA introduction slot as missing scripture.
     */
    func testSQLitePassageCrossesChapterIntroductionWithoutInventingRows() throws {
        let source = makeSource(rows: [
            (.verse(book: 10, chapter: 1, verse: 31), "End of chapter"),
            (.verse(book: 10, chapter: 2, verse: 1), "Start of chapter"),
        ])
        let startOrdinal = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(
            osisId: "Gen",
            chapter: 1,
            verse: 31
        ))
        let endOrdinal = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(
            osisId: "Gen",
            chapter: 2,
            verse: 1
        ))

        let passage = try source.passage(
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )

        XCTAssertEqual(passage.verses.map(\.reference.ordinal), [startOrdinal, endOrdinal])
        XCTAssertEqual(passage.plainText, "End of chapter Start of chapter")
        XCTAssertEqual(passage.sourceOSISRange, "Gen.1.31-Gen.2.1")
        XCTAssertTrue(try XCTUnwrap(passage.verses.last).reference == source.verseReference(ordinal: endOrdinal))
        XCTAssertTrue(source.isCanonicallyAdjacent(
            try XCTUnwrap(passage.verses.last).reference,
            after: try XCTUnwrap(passage.verses.first).reference
        ))
    }

    /**
     Verifies passage reads are bounded by source chapters rather than verse count.

     - Setup: Three sparse verses span two Genesis chapters.
     - Expected result: The source receives exactly one batch read for each chapter and no
       single-verse lookup.
     - Failure meaning: Long copy, Compare, or speech passages could reopen SQLite for every verse.
     */
    func testSQLitePassageBatchesReadsByChapter() throws {
        let reader = InstalledScriptureSQLiteReader(rows: [
            (.verse(book: 10, chapter: 1, verse: 30), "Thirty"),
            (.verse(book: 10, chapter: 1, verse: 31), "Thirty-one"),
            (.verse(book: 10, chapter: 2, verse: 1), "One"),
        ])
        let source = makeSource(reader: reader)
        let startOrdinal = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(
            osisId: "Gen",
            chapter: 1,
            verse: 30
        ))
        let endOrdinal = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(
            osisId: "Gen",
            chapter: 2,
            verse: 1
        ))

        let passage = try source.passage(
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )

        XCTAssertEqual(passage.verses.map(\.plainText), ["Thirty", "Thirty-one", "One"])
        XCTAssertEqual(reader.chapterRequests, ["10:1", "10:2"])
        XCTAssertEqual(reader.singleContentReadCount, 0)
    }

    /**
     Verifies SQLite source markup and visible text come from the selected custom module.

     - Setup: One MyBible verse contains OSIS lexical markup and XML-sensitive visible text.
     - Expected result: Structural source XML is retained while canonical text strips markup.
     - Failure meaning: Backend-neutral callers would relabel raw database text or expose tags in
       native copy/share output.
     */
    func testSQLiteVerseKeepsSourceMarkupAndProjectsCanonicalText() throws {
        let source = makeSource(rows: [
            (
                .verse(book: 10, chapter: 1, verse: 1),
                #"<w lemma="strong:H07225">Beginning</w> &amp; creation"#
            ),
        ])
        let ordinal = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(
            osisId: "Gen",
            chapter: 1,
            verse: 1
        ))
        let reference = try XCTUnwrap(source.verseReference(ordinal: ordinal))

        let verse = try XCTUnwrap(source.verse(reference))

        XCTAssertEqual(
            verse.sourceXML,
            #"<w lemma="strong:H07225">Beginning</w> &amp; creation"#
        )
        XCTAssertEqual(verse.plainText, "Beginning & creation")
        XCTAssertEqual(verse.reference, reference)
    }

    /**
     Verifies range validation rejects introduction endpoints and excessive work before source I/O.

     - Setup: A valid Genesis 1:1 source plus its immediately preceding chapter-introduction slot.
     - Expected result: The introduction fails as a non-verse endpoint and a zero work bound fails
       as an invalid range.
     - Failure meaning: Bridge callers could reinterpret introduction ordinals or trigger an
       unbounded SQLite walk.
     */
    func testSQLitePassageRejectsIntroductionEndpointAndInvalidWorkBound() throws {
        let source = makeSource(rows: [
            (.verse(book: 10, chapter: 1, verse: 1), "Beginning"),
        ])
        let verseOrdinal = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(
            osisId: "Gen",
            chapter: 1,
            verse: 1
        ))
        let introductionOrdinal = verseOrdinal - 1

        XCTAssertThrowsError(try source.passage(
            startOrdinal: introductionOrdinal,
            endOrdinal: verseOrdinal
        )) { error in
            XCTAssertEqual(
                error as? BibleReaderInstalledScriptureSourceError,
                .nonAddressableEndpoint(introductionOrdinal)
            )
        }
        XCTAssertThrowsError(try source.passage(
            startOrdinal: verseOrdinal,
            endOrdinal: verseOrdinal,
            maximumVerseCount: 0
        )) { error in
            XCTAssertEqual(
                error as? BibleReaderInstalledScriptureSourceError,
                .invalidRange
            )
        }
    }

    /** Creates one immutable MyBible source from exact ordered fixture rows. */
    private func makeSource(
        rows: [(SQLiteDocumentKey, String)]
    ) -> BibleReaderInstalledScriptureSource {
        makeSource(reader: InstalledScriptureSQLiteReader(rows: rows))
    }

    /** Wraps one retained fixture reader so tests can inspect its source-access count. */
    private func makeSource(
        reader: InstalledScriptureSQLiteReader
    ) -> BibleReaderInstalledScriptureSource {
        let module = SQLiteDocumentModule(reader: reader, origin: .manual)
        return .sqlite(BibleReaderSQLiteModuleHandle(module: module))
    }
}

/** Deterministic in-memory MyBible reader used by installed-source behavior tests. */
private final class InstalledScriptureSQLiteReader: SQLiteDocumentReading {
    /// Immutable MyBible Bible metadata projected into the installed-book registry.
    let metadata = SQLiteDocumentMetadata(
        sourceURL: URL(fileURLWithPath: "/tmp/installed-scripture-source.SQLite3"),
        format: .myBible,
        initials: "MyBible-installed-source",
        abbreviation: "Fixture",
        title: "Installed source fixture",
        description: "Installed source fixture",
        language: "en",
        version: "1",
        category: .bible,
        direction: .ltr,
        hasStrongs: true,
        isStrongsDictionary: false,
        hasWordsOfChrist: false
    )

    /// Exact fixture category.
    var category: DocumentCategory { .bible }

    /// Ordered source rows, including sparse coordinates when requested by a test.
    private let rows: [(key: SQLiteDocumentKey, text: String)]

    /// Source chapter requests retained for bounded-I/O assertions.
    private(set) var chapterRequests: [String] = []

    /// Exact content lookups retained to catch accidental per-verse passage access.
    private(set) var singleContentReadCount = 0

    /** Captures exact fixture rows without normalization. */
    init(rows: [(SQLiteDocumentKey, String)]) {
        self.rows = rows.map { (key: $0.0, text: $0.1) }
    }

    /** Returns fixture keys in source order. */
    func keys() throws -> [SQLiteDocumentKey] {
        rows.map(\.key)
    }

    /** Returns the first exact source row for one typed key. */
    func content(for key: SQLiteDocumentKey) throws -> SQLiteDocumentContent? {
        singleContentReadCount += 1
        return rows.first(where: { $0.key == key }).map {
            SQLiteDocumentContent(key: key, text: $0.text)
        }
    }

    /** Returns one exact source chapter and records the single batch operation. */
    func chapterContent(book: Int, chapter: Int) throws -> [(verse: Int, text: String)] {
        chapterRequests.append("\(book):\(chapter)")
        return rows.compactMap { row in
            guard case .verse(let rowBook, let rowChapter, let verse) = row.key,
                  rowBook == book,
                  rowChapter == chapter else {
                return nil
            }
            return (verse, row.text)
        }
    }
}
