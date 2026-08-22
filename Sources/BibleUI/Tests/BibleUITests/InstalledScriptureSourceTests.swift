import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/** Tests exact Android installed-book behavior across the backend-neutral scripture boundary. */
final class InstalledScriptureSourceTests: BibleUISwordFixtureTestCase {
    /**
     Keeps inclusive native ownership separate from authorization across shared content readers.

     - Setup: Registers readable KJV, a locked native Bible whose initials collide with a readable
       SQLite Bible, and builds the production installed-module resolver from that fresh manager.
     - Expected result: KJV remains readable, the locked native owns the collision without exposing
       either backend, Compare contains only KJV, and copy/share cannot read the locked identity.
     - Failure meaning: A non-activation content path can inspect a locked Bible or fall through to
       a SQLite namesake that Android's native registration shadows.
     - Side effects: Writes only an inherited temporary SWORD fixture and removes it in teardown.
     */
    @MainActor
    func testLockedNativeOwnershipFailsClosedAcrossContentSearchAIAndAnnotationBoundaries() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let lockedName = "MyBible-installed-source"
        try seedBibleAliasModule(
            named: lockedName,
            description: "Locked native collision owner",
            in: modulePath
        )
        let lockedConfigURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/\(lockedName.lowercased()).conf")
        var lockedConfiguration = try String(contentsOf: lockedConfigURL, encoding: .utf8)
        lockedConfiguration.append("\nCipherKey=\n")
        try lockedConfiguration.write(to: lockedConfigURL, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let sqliteModule = makeSQLiteModuleHandle(rows: [
            (.verse(book: 10, chapter: 1, verse: 1), "SQLite collision content"),
        ])
        let resolver = BibleReaderInstalledModuleResolver(
            swordManager: manager,
            sqliteModules: [sqliteModule]
        )
        let lockedNativeHandle = try XCTUnwrap(manager.module(named: lockedName))
        let kjvSource = try XCTUnwrap(resolver.scripture(named: "KJV"))
        let ordinal = try XCTUnwrap(kjvSource.verseOrdinal(
            osisBookId: "Gen",
            chapter: 1,
            verse: 1
        ))

        XCTAssertEqual(manager.moduleAccessState(named: lockedName), .locked)
        XCTAssertNil(manager.readableModule(named: lockedName))
        XCTAssertNil(resolver.module(named: lockedName))
        XCTAssertNil(resolver.scripture(named: lockedName))
        XCTAssertNil(resolver.searchIndexSource(named: lockedName))
        XCTAssertNil(resolver.module(named: sqliteModule.info.description))
        XCTAssertEqual(
            resolver.modules(categories: [.bible]).map(\.info.name),
            ["KJV"]
        )
        let staleIndexedNames = Set([lockedName, "KJV"])
        XCTAssertEqual(
            resolver.modules(categories: [.bible])
                .map(\.info.name)
                .filter(staleIndexedNames.contains),
            ["KJV"],
            "A stale index cannot make a relocked Bible eligible for text or Strong's search."
        )
        XCTAssertNil(SearchView.resolveStandaloneSearchIndexSource(
            named: lockedName,
            primaryModule: lockedNativeHandle,
            manager: manager
        ))
        XCTAssertNil(SearchView.resolveStandaloneSearchIndexSource(
            named: lockedName,
            primaryModule: lockedNativeHandle,
            manager: nil
        ))
        XCTAssertEqual(
            SearchView.resolveStandaloneSearchIndexSource(
                named: "KJV",
                primaryModule: nil,
                manager: manager
            )?.searchIndexModuleInfo.name,
            "KJV"
        )

        let installedMetadata = manager.installedModules() + [sqliteModule.info]
        let compareRequest = try XCTUnwrap(
            BibleReaderCompareDocumentBuilder(
                moduleResolver: resolver,
                installedBibleModules: installedMetadata
            ).makeRequest(
                bookInitials: "KJV",
                startOrdinal: ordinal,
                endOrdinal: ordinal
            )
        )
        XCTAssertEqual(compareRequest.sources.map(\.info.name), ["KJV"])

        let copyShareBuilder = BibleReaderVerseActionTextBuilder(moduleResolver: resolver)
        XCTAssertNil(copyShareBuilder.build(
            bookInitials: lockedName,
            startOrdinal: ordinal,
            endOrdinal: ordinal
        ))
        XCTAssertNotNil(copyShareBuilder.build(
            bookInitials: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        ))

        let controller = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: manager
        )
        XCTAssertNil(controller.aiBibleSourceContext(
            bookInitials: lockedName,
            startOrdinal: ordinal,
            endOrdinal: ordinal
        ))
        XCTAssertNotNil(controller.aiBibleSourceContext(
            bookInitials: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        ))
        let lockedBookmark = BibleBookmark(
            kjvOrdinalStart: ordinal,
            kjvOrdinalEnd: ordinal,
            ordinalStart: ordinal,
            ordinalEnd: ordinal,
            v11n: "KJV",
            bookInitials: lockedName
        )
        lockedBookmark.book = "Genesis"
        XCTAssertEqual(controller.bookmarkListTextProjection(for: lockedBookmark), .empty)
        let readableBookmark = BibleBookmark(
            kjvOrdinalStart: ordinal,
            kjvOrdinalEnd: ordinal,
            ordinalStart: ordinal,
            ordinalEnd: ordinal,
            v11n: "KJV",
            bookInitials: "KJV"
        )
        readableBookmark.book = "Genesis"
        XCTAssertFalse(
            controller.bookmarkListTextProjection(for: readableBookmark).fullText.isEmpty
        )
    }

    /**
     Rebuilds authorization from fresh persisted access state after a successful unlock.

     - Setup: Captures one resolver while an encrypted Bible has an empty key, persists the
       post-verification non-empty key shape, then constructs a new manager and resolver.
     - Expected result: The locked snapshot exposes no content; the fresh post-unlock snapshot
       classifies and exposes the same native owner as readable.
     - Failure meaning: Resolver authorization is cached independently from manager access state,
       leaving successful startup/picker unlocks unusable until another unrelated refresh.
     - Side effects: Rewrites one descriptor in the inherited temporary SWORD fixture and removes it
       in teardown; no shared module store is touched.
     */
    func testFreshResolverExposesNativeContentAfterPersistedUnlockState() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let moduleName = "POSTLOCK"
        try seedBibleAliasModule(
            named: moduleName,
            description: "Post-unlock resolver Bible",
            in: modulePath
        )
        let configURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/\(moduleName.lowercased()).conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)

        let lockedManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let lockedResolver = BibleReaderInstalledModuleResolver(
            swordManager: lockedManager,
            sqliteModules: []
        )
        XCTAssertEqual(lockedManager.moduleAccessState(named: moduleName), .locked)
        XCTAssertNil(lockedResolver.scripture(named: moduleName))

        configuration = configuration.replacingOccurrences(
            of: "CipherKey=\n",
            with: "CipherKey=verified-test-key\n"
        )
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)
        let unlockedManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let unlockedResolver = BibleReaderInstalledModuleResolver(
            swordManager: unlockedManager,
            sqliteModules: []
        )

        XCTAssertEqual(unlockedManager.moduleAccessState(named: moduleName), .readable)
        XCTAssertEqual(unlockedManager.readableModule(named: moduleName)?.info.name, moduleName)
        XCTAssertEqual(unlockedResolver.scripture(named: moduleName)?.info.name, moduleName)
        XCTAssertEqual(
            unlockedResolver.searchIndexSource(named: moduleName)?.searchIndexModuleInfo.name,
            moduleName
        )
        XCTAssertEqual(
            SearchView.resolveStandaloneSearchIndexSource(
                named: moduleName,
                primaryModule: nil,
                manager: unlockedManager
            )?.searchIndexModuleInfo.name,
            moduleName
        )
        XCTAssertTrue(
            unlockedResolver.modules(categories: [.bible]).contains {
                $0.info.name == moduleName
            }
        )
    }

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
        .sqlite(BibleReaderSQLiteModuleHandle(
            module: SQLiteDocumentModule(reader: reader, origin: .manual)
        ))
    }

    /** Creates one readable SQLite runtime handle from exact ordered fixture rows. */
    private func makeSQLiteModuleHandle(
        rows: [(SQLiteDocumentKey, String)]
    ) -> BibleReaderSQLiteModuleHandle {
        BibleReaderSQLiteModuleHandle(
            module: SQLiteDocumentModule(
                reader: InstalledScriptureSQLiteReader(rows: rows),
                origin: .manual
            )
        )
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
