import XCTest
import AVFoundation
@testable import BibleCore
import CLibSword
@testable import SwordKit
import SwiftData
import SQLite3
@testable import BibleUI
@testable import BibleView
import struct SwiftUI.Binding
import enum SwiftUI.ColorScheme
import struct SwiftUI.EdgeInsets
import struct SwiftUI.EmptyView
#if os(iOS)
import UIKit
import WebKit
import struct SwiftUI.Color
#endif

/**
 Thread-safe recorder for SWORD concurrency regression failures.

 The stress test below intentionally runs native SWORD reads from multiple Dispatch worker threads.
 XCTest assertions are collected here and asserted after `concurrentPerform` returns so failures are
 deterministic and reported from the test method rather than from racing background closures.

 - Side effects: Stores failure messages in memory behind an `NSLock`.
 - Failure modes: None expected; lock contention only serializes recorder access, not SWORD access.
 */
private final class SwordConcurrencyFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    /**
     Records one validation failure from a concurrent worker.

     - Parameter message: Human-readable failure evidence including the worker index.
     - Side effects: Appends to the protected message list.
     */
    func record(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    /**
     Returns all collected failures in insertion order.

     - Returns: A copied array so XCTest can inspect it after worker execution completes.
     - Side effects: Acquires the recorder lock while copying.
     */
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

extension AndBibleTests {
    func testCSVSetEncodingAndDecodingRoundTrip() {
        let encoded = AppPreferenceRegistry.encodeCSVSet(["  KJV  ", "", "ESV", "KJV", "  "])
        XCTAssertEqual(encoded, "ESV,KJV,KJV")
        XCTAssertEqual(AppPreferenceRegistry.decodeCSVSet(encoded), ["ESV", "KJV", "KJV"])
        XCTAssertEqual(AppPreferenceRegistry.decodeCSVSet(nil), [])
        XCTAssertEqual(AppPreferenceRegistry.decodeCSVSet(""), [])
    }

    func testStrongsQueryNormalizationHandlesLeadingZeroes() {
        let options = StrongsSearchSupport.normalizedQueryOptions(for: "H02022")
        XCTAssertEqual(options?.canonicalStrongTokens, ["H2022"])
        XCTAssertEqual(
            options?.entryAttributeQueries,
            ["Word//Lemma./H02022", "Word//Lemma./H2022"]
        )
    }

    func testStrongsQueryNormalizationAcceptsDecoratedInput() {
        let options = StrongsSearchSupport.normalizedQueryOptions(for: "lemma:strong:g00123")
        XCTAssertEqual(options?.canonicalStrongTokens, ["G0123"])
        XCTAssertEqual(
            options?.entryAttributeQueries,
            ["Word//Lemma./G00123", "Word//Lemma./G0123", "Word//Lemma./G123"]
        )
    }

    func testStrongsQueryNormalizationIncludesIntermediateZeroTrimVariants() {
        let options = StrongsSearchSupport.normalizedQueryOptions(for: "H00430")
        XCTAssertEqual(options?.canonicalStrongTokens, ["H0430"])
        XCTAssertEqual(
            options?.entryAttributeQueries,
            ["Word//Lemma./H00430", "Word//Lemma./H0430", "Word//Lemma./H430"]
        )
    }

    /**
     Verifies iOS tokenizes Strong's OSIS lemma values the same way JSword populates the Lucene
     `strong` field.

     JSword `OSISUtil.getStrongsNumbers` extracts `strong:` lemma values from `<w>` elements, and
     `StrongsNumberFilter` normalizes each number to four digits. Part-suffixed values are indexed
     twice: once as the base number and once as the full part token. A failure means iOS "find all
     occurrences" can disagree with Android even when both apps read the same SWORD verse content.
     */
    func testStrongsRawLemmaExtractionUsesJSwordCanonicalTokens() {
        let rawEntry = """
        <verse osisID="Gen.1.1">
          <w lemma="strong:H00430 strong:H01234!b">God</w>
          <w lemma="lemma:noise strong:g00123a">made</w>
        </verse>
        """

        XCTAssertEqual(
            StrongsSearchSupport.canonicalStrongTokens(
                rawEntry: rawEntry,
                renderedText: "",
                book: "Genesis"
            ),
            ["H0430", "H1234", "H1234b", "G0123", "G0123a"]
        )
    }

    /**
     Verifies Strong's token extraction keeps the JSword raw-OSIS path primary and does not render
     verse text when raw lexical tokens are already present.

     JSword builds its `strong` field from parsed OSIS `<w lemma="strong:...">` values. Rendering a
     verse to recover `showStrong` links is an iOS compatibility fallback for modules that do not
     expose usable raw OSIS, not part of Android's primary search path. A failure means "find all
     occurrences" may pay unnecessary render cost or merge fallback tokens into a verse whose raw
     lexical data is already authoritative.
     */
    func testStrongsCanonicalExtractionSkipsRenderedFallbackWhenRawOSISHasLexicalTokens() {
        var renderCount = 0

        let tokens = StrongsSearchSupport.canonicalStrongTokens(
            rawEntry: #"<w lemma="strong:H00430">God</w>"#,
            renderedTextProvider: {
                renderCount += 1
                return #"<a href="passagestudy.jsp?action=showStrong=01234#cv">unexpected</a>"#
            },
            book: "Genesis"
        )

        XCTAssertEqual(tokens, ["H0430"])
        XCTAssertEqual(renderCount, 0)
    }

    /**
     Verifies the rendered-text fallback remains reachable for modules whose raw entries do not
     expose JSword-style lexical tokens.

     Some SWORD modules only expose Strong's links after rendering. iOS should still recover those
     `showStrong` links when raw OSIS extraction finds no tokens, while keeping the same canonical
     four-digit token shape used by JSword's Strong's index.
     */
    func testStrongsCanonicalExtractionUsesRenderedFallbackWhenRawOSISHasNoLexicalTokens() {
        var renderCount = 0

        let tokens = StrongsSearchSupport.canonicalStrongTokens(
            rawEntry: "<p>God created.</p>",
            renderedTextProvider: {
                renderCount += 1
                return #"<a href="passagestudy.jsp?action=showStrong=0430#cv">God</a>"#
            },
            book: "Genesis"
        )

        XCTAssertEqual(tokens, ["H0430"])
        XCTAssertEqual(renderCount, 1)
    }

    func testParseVerseKeySupportsHumanReadableFormat() {
        let parsed = StrongsSearchSupport.parseVerseKey("I Samuel 2:3")
        XCTAssertEqual(parsed?.book, "I Samuel")
        XCTAssertEqual(parsed?.chapter, 2)
        XCTAssertEqual(parsed?.verse, 3)
    }

    func testParseVerseKeySupportsOsisFormat() {
        let parsed = StrongsSearchSupport.parseVerseKey("Gen.1.1")
        XCTAssertEqual(parsed?.book, "Genesis")
        XCTAssertEqual(parsed?.chapter, 1)
        XCTAssertEqual(parsed?.verse, 1)
    }

    func testParseVerseKeySupportsOsisFormatWithSuffix() {
        let parsed = StrongsSearchSupport.parseVerseKey("Gen.1.1!crossReference.a")
        XCTAssertEqual(parsed?.book, "Genesis")
        XCTAssertEqual(parsed?.chapter, 1)
        XCTAssertEqual(parsed?.verse, 1)
    }

    func testStrongsSearchFindAllOccurrencesReturnsBundledKJVMatches() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary bundled sword module path"
        )
        let installedModules = manager.installedModules()
        XCTAssertTrue(
            installedModules.contains(where: { $0.name == "KJV" && $0.features.contains(.strongsNumbers) }),
            "Expected bundled KJV module with Strong's support to be installed for regression testing"
        )

        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected bundled KJV module to be available for Strong's regression testing"
        )
        let queryOptions = try XCTUnwrap(
            StrongsSearchSupport.normalizedQueryOptions(for: "H02022"),
            "Expected H02022 to normalize into entry-attribute Strong's search queries"
        )

        let hits = StrongsSearchSupport.searchVerseHits(in: module, queryOptions: queryOptions)

        XCTAssertFalse(
            hits.isEmpty,
            "Expected the bundled KJV Strong's search for H02022 to return at least one verse"
        )
        XCTAssertTrue(
            hits.allSatisfy { !$0.reference.isEmpty },
            "Expected Strong's hits to parse into verse references"
        )
    }

    func testStrongsSearchFindAllOccurrencesSupportsIntermediateZeroTrimVariant() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary bundled sword module path"
        )
        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected bundled KJV module to be available for Strong's regression testing"
        )
        let queryOptions = try XCTUnwrap(
            StrongsSearchSupport.normalizedQueryOptions(for: "H00430"),
            "Expected H00430 to normalize into Strong's search queries"
        )

        let hits = StrongsSearchSupport.searchVerseHits(in: module, queryOptions: queryOptions)

        XCTAssertFalse(
            hits.isEmpty,
            "Expected the bundled KJV Strong's search for H00430 to return at least one verse"
        )
        XCTAssertTrue(
            hits.contains { $0.book == "Genesis" && $0.chapter == 1 && $0.verse == 1 },
            "Expected JSword-style Strong's token search for H00430/H0430 to find Genesis 1:1"
        )
    }

    /**
     Verifies the Strong's search path can use SWORD entry-attribute results as a candidate index
     without trusting them as the semantic result source.

     Android's find-all path reads JSword's canonical `strong` field, so iOS must still validate
     candidate verses against parsed Strong's lemma tokens. A failure means the UI search path may
     either fall back to an expensive full-module scan when SWORD already has candidate verses, or
     return entry-attribute hits that do not match JSword token semantics.
     */
    func testStrongsSearchEntryAttributeCandidatesAreCanonicallyValidated() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary bundled sword module path"
        )
        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected bundled KJV module to be available for Strong's candidate regression testing"
        )
        let queryOptions = try XCTUnwrap(
            StrongsSearchSupport.normalizedQueryOptions(for: "H00430"),
            "Expected H00430 to normalize into Strong's search queries"
        )

        let candidateResult = StrongsSearchSupport.searchVerseHitsByEntryAttributeCandidates(
            in: module,
            queryOptions: queryOptions
        )

        XCTAssertTrue(
            candidateResult.sawLexicalTokens,
            "Expected SWORD candidate verses to expose JSword-style lexical Strong's tokens"
        )
        XCTAssertTrue(
            candidateResult.hits.contains { $0.book == "Genesis" && $0.chapter == 1 && $0.verse == 1 },
            "Expected candidate-index search to validate Genesis 1:1 against canonical H0430 tokens"
        )
    }

    /**
     Verifies SWORD Bible book discovery exposes the full Protestant canon for a complete module.

     The bundled KJV fixture contains content for all 66 books and exercises the same
     `SwordModule.getBookList()` path used by restored Android `.abmd.zip` Bible modules such as
     ESV. A failure means the reader's dynamic book picker can hide valid restored content even
     though the module files and verse entries are present. The test copies bundled SWORD resources
     into a temporary directory and relies on the shared test cleanup to remove those files.
     */
    func testBundledKJVBookListIncludesAllCanonicalBooks() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary bundled sword module path"
        )
        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected bundled KJV module to be available for book-list regression testing"
        )

        let discoveredBookIds = module.getBookList().map(\.osisId)

        XCTAssertEqual(discoveredBookIds.count, 66)
        XCTAssertEqual(
            discoveredBookIds,
            [
                "Gen", "Exod", "Lev", "Num", "Deut", "Josh", "Judg", "Ruth",
                "1Sam", "2Sam", "1Kgs", "2Kgs", "1Chr", "2Chr", "Ezra", "Neh",
                "Esth", "Job", "Ps", "Prov", "Eccl", "Song", "Isa", "Jer",
                "Lam", "Ezek", "Dan", "Hos", "Joel", "Amos", "Obad", "Jonah",
                "Mic", "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal", "Matt",
                "Mark", "Luke", "John", "Acts", "Rom", "1Cor", "2Cor", "Gal",
                "Eph", "Phil", "Col", "1Thess", "2Thess", "1Tim", "2Tim", "Titus",
                "Phlm", "Heb", "Jas", "1Pet", "2Pet", "1John", "2John", "3John",
                "Jude", "Rev",
            ]
        )
    }

    /**
     Verifies iOS expands OSIS reference ranges through the same SWORD key parser boundary that
     backs JSword-style passage semantics.

     Android uses JSword `PassageKeyFactory` for OSIS references, so a range such as
     `Gen.1.1-Gen.1.3` resolves to every verse in the range rather than only the textual endpoints.
     The setup loads the bundled KJV fixture and asks the active SWORD module to parse the range;
     a failure means reader cross-reference links can silently omit middle verses.
     */
    func testBundledKJVParseKeyListExpandsOsisRanges() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary bundled sword module path"
        )
        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected bundled KJV module to be available for key-list parsing parity testing"
        )

        XCTAssertEqual(
            module.parseKeyList("Gen.1.1-Gen.1.3"),
            ["Gen.1.1", "Gen.1.2", "Gen.1.3"]
        )
    }

    /**
     Verifies iOS obtains chapter verse counts from the active module's SWORD `VerseKey` metadata.

     Android's passage chooser uses JSword `Versification.getLastVerse(book, chapterNo)`, not a
     partial hard-coded table. The KJV fixture exercises common and uncommon chapter counts; Ruth 4
     is intentionally included because the previous fallback returned `30` for unknown chapters.
     A failure means the native verse picker can offer invalid verses or hide valid verses.
     */
    func testBundledKJVVerseCountUsesModuleVersification() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary bundled sword module path"
        )
        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected bundled KJV module to be available for verse-count parity testing"
        )

        XCTAssertEqual(module.verseCount(osisBookId: "Gen", chapter: 1), 31)
        XCTAssertEqual(module.verseCount(osisBookId: "Ruth", chapter: 4), 22)
        XCTAssertEqual(module.verseCount(osisBookId: "Ps", chapter: 119), 176)
        XCTAssertEqual(module.verseCount(osisBookId: "Rev", chapter: 22), 21)
        XCTAssertNil(module.verseCount(osisBookId: "Bogus", chapter: 1))
    }

    /**
     Verifies iOS uses SWORD/JSword-style verse ordinals instead of per-chapter arithmetic.

     JSword `Versification.getOrdinal(Verse)` includes Bible, testament, book, and chapter intro
     slots before the first normal verse. SWORD's `VerseKey.getIndex()` follows the same convention,
     so `Gen.1.1` is ordinal 4 and `Gen.2.1` is ordinal 36, not ordinals 1 and 41. The reverse
     lookup assertion protects bookmark, memorization, and bridge code that must map persisted
     Android ordinals back to exact verse references.
     */
    func testBundledKJVVerseOrdinalsUseIntroInclusiveVersification() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary bundled sword module path"
        )
        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected bundled KJV module to be available for ordinal parity testing"
        )

        module.setKey("=Gen.1.1")
        XCTAssertEqual(module.currentVerseKeyIndex(), 4)
        XCTAssertEqual(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1), 4)
        XCTAssertEqual(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 31), 34)
        XCTAssertEqual(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 1), 36)
        XCTAssertEqual(
            module.verseReference(ordinal: 4),
            VerseKeyReference(osisBookId: "Gen", chapter: 1, verse: 1, ordinal: 4)
        )
        XCTAssertEqual(
            module.verseReference(osisBookId: "Gen", ordinal: 36),
            VerseKeyReference(osisBookId: "Gen", chapter: 2, verse: 1, ordinal: 36)
        )
        XCTAssertNil(module.verseReference(ordinal: 1))
        XCTAssertNil(module.verseReference(osisBookId: "Exod", ordinal: 36))
        XCTAssertNil(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 99))
        XCTAssertNil(module.verseOrdinal(osisBookId: "Gen", chapter: 99, verse: 1))
        XCTAssertNil(module.verseCount(osisBookId: "Gen", chapter: 99))
    }

    /**
     Verifies concurrent Swift SWORD wrappers cannot interleave native libsword state.

     The app can create fresh `SwordManager` instances after imports, restores, and module-store
     refreshes while other reader/search code is still reading existing modules. The local C bridge
     and libsword hold process-global pointer caches, so per-instance queues leave a race that can
     surface as the CI-only `SIGSEGV` seen in the ordinal test. This regression runs many managers
     against the same bundled KJV fixture in parallel; success means every worker received stable
     JSword-parity verse ordinals, reverse references, verse counts, and parsed ranges.

     - Setup: Copies the bundled SWORD fixture into one temporary module path shared by all workers.
     - Expected result: No worker records a missing manager/module or inconsistent SWORD result.
     - Failure meaning: Native SWORD access is not serialized at the process boundary, risking app
       crashes during restore/import refreshes or parallel reader/search activity.
     - Side effects: Creates temporary SWORD fixture files that shared test cleanup removes.
     */
    func testBundledKJVNativeAccessSerializesAcrossConcurrentManagers() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let failures = SwordConcurrencyFailureRecorder()

        DispatchQueue.concurrentPerform(iterations: 48) { index in
            autoreleasepool {
                guard let manager = SwordManager(modulePath: modulePath) else {
                    failures.record("worker \(index): missing SwordManager")
                    return
                }
                guard let module = manager.module(named: "KJV") else {
                    failures.record("worker \(index): missing KJV module")
                    return
                }

                let target = index.isMultiple(of: 2)
                    ? (osisBookId: "Gen", chapter: 1, verse: 1, ordinal: 4)
                    : (osisBookId: "Gen", chapter: 2, verse: 1, ordinal: 36)
                let ordinal = module.verseOrdinal(
                    osisBookId: target.osisBookId,
                    chapter: target.chapter,
                    verse: target.verse
                )
                let reference = module.verseReference(ordinal: target.ordinal)

                if ordinal != target.ordinal {
                    failures.record("worker \(index): expected ordinal \(target.ordinal), got \(String(describing: ordinal))")
                }
                if reference?.osisRef != "\(target.osisBookId).\(target.chapter).\(target.verse)" {
                    failures.record("worker \(index): expected reference for ordinal \(target.ordinal), got \(String(describing: reference))")
                }
                if module.verseCount(osisBookId: "Gen", chapter: 1) != 31 {
                    failures.record("worker \(index): unexpected Genesis 1 verse count")
                }
                if module.parseKeyList("Gen.1.1-Gen.1.3") != ["Gen.1.1", "Gen.1.2", "Gen.1.3"] {
                    failures.record("worker \(index): OSIS range did not expand deterministically")
                }
            }
        }

        XCTAssertEqual(failures.all, [])
    }

    /**
     Verifies the Swift VerseKey parser preserves SWORD-provided metadata from the native adapter.

     iOS must not collapse all text fields to the OSIS reference, because book discovery, chapter
     rendering, and reference validation consume the copied book name, abbreviation, and OSIS book
     fields. The bundled KJV fixture exercises the same SWORD bridge used by imported Android
     backup modules.
     */
    func testBundledKJVVerseKeyChildrenExposeBookMetadata() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary bundled sword module path"
        )
        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected bundled KJV module to be available for VerseKey metadata parity testing"
        )

        module.setKey("=Gen.1.1")
        let children = try XCTUnwrap(module.currentVerseKeyChildren())

        XCTAssertEqual(children.testament, 1)
        XCTAssertEqual(children.book, 1)
        XCTAssertEqual(children.chapter, 1)
        XCTAssertEqual(children.verse, 1)
        XCTAssertEqual(children.index, 4)
        XCTAssertEqual(children.chapterMax, 50)
        XCTAssertEqual(children.verseMax, 31)
        XCTAssertEqual(children.bookName, "Genesis")
        XCTAssertEqual(children.osisRef, "Gen.1.1")
        XCTAssertFalse(children.shortText.isEmpty)
        XCTAssertEqual(children.bookAbbreviation, "Gen")
        XCTAssertEqual(children.osisBookName, "Gen")
    }

    func testBibleChapterDocumentBuilderPreservesSecondCorinthiansIntroAndChapterMarker() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let builder = BibleChapterDocumentBuilder(module: module, includeHeadings: true)

        let chapter = try XCTUnwrap(builder.loadChapter(osisBookId: "2Cor", chapter: 1))

        XCTAssertFalse(chapter.addChapter)
        XCTAssertGreaterThan(chapter.verseCount, 0)
        XCTAssertTrue(chapter.xml.contains("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS"))
        XCTAssertTrue(chapter.xml.contains("<chapter"))
        XCTAssertTrue(chapter.xml.contains("CHAPTER 1."))
    }

    func testBibleChapterDocumentBuilderStillEmitsChapterMarkerWhenSectionTitlesAreDisabled() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let builder = BibleChapterDocumentBuilder(module: module, includeHeadings: false)

        let chapter = try XCTUnwrap(builder.loadChapter(osisBookId: "2Cor", chapter: 1))

        XCTAssertFalse(chapter.addChapter)
        XCTAssertTrue(chapter.xml.contains("<chapter osisID=\"2Cor.1\""))
        XCTAssertFalse(chapter.xml.contains("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS"))
    }

    func testBibleChapterDocumentBuilderKeepsRenderableChapterStartMarkers() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let builder = BibleChapterDocumentBuilder(module: module, includeHeadings: true)

        let chapter = try XCTUnwrap(builder.loadChapter(osisBookId: "2Cor", chapter: 2))
        let hasOpeningMarker = chapter.xml.range(
            of: #"<chapter\b[^>]*osisID="2Cor\.2"[^>]*sID="#,
            options: .regularExpression
        ) != nil

        XCTAssertFalse(chapter.addChapter)
        XCTAssertTrue(
            hasOpeningMarker || chapter.xml.contains("<chapter n=\"2\""),
            "Expected a visible chapter start marker, not only a closing chapter tag. XML: \(chapter.xml)"
        )
        XCTAssertFalse(
            chapter.xml.contains("<chapter eID=") && !hasOpeningMarker,
            "A closing-only chapter tag suppresses Vue's synthetic chapter number without rendering a visible one. XML: \(chapter.xml)"
        )
    }

    func testSwordModuleRawChapterKeysExposeIntroStructure() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))

        module.setKey("=2Cor.0.0")
        _ = module.currentVerseKeyChildren()
        let bookIntro = module.rawEntry()

        module.setKey("=2Cor.1.0")
        let chapterIntroKey = module.currentVerseKeyChildren()
        let chapterIntro = module.rawEntry()

        module.setKey("=2Cor.2.0")
        let secondChapterIntroKey = module.currentVerseKeyChildren()
        let secondChapterIntro = module.rawEntry()

        module.setKey("2Cor 1")
        let chapterKeyRawEntry = module.rawEntry()

        XCTAssertFalse(bookIntro.isEmpty)
        XCTAssertFalse(chapterIntro.isEmpty)
        XCTAssertFalse(secondChapterIntro.isEmpty)
        XCTAssertEqual(chapterIntroKey?.chapter, 1)
        XCTAssertEqual(chapterIntroKey?.verse, 0)
        XCTAssertEqual(secondChapterIntroKey?.chapter, 2)
        XCTAssertEqual(secondChapterIntroKey?.verse, 0)
        XCTAssertTrue(
            bookIntro.contains("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS")
                || chapterIntro.contains("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS")
        )
        XCTAssertTrue(
            chapterIntro.contains("<chapter")
                || secondChapterIntro.contains("<chapter")
                || chapterKeyRawEntry.contains("<chapter"),
            "Expected libsword to expose a chapter marker somewhere in chapter-intro access paths"
        )
    }

    func testCanonicalStrongsKeyNameUsesResolvedEntryMetadataWhenCurrentKeyIsBlank() {
        let rawEntry = """
        <entryFree n="H6440"><title>H6440</title> <foreign xml:lang="he">פָּנֶה</foreign>, pl. <foreign xml:lang="he">פָּנִים</foreign> <hi rend="italic">face</hi>, also <hi rend="italic">faces</hi></entryFree>
        """

        let keyName = BibleReaderController.canonicalStrongsKeyName(
            requested: "H06440",
            actualKey: "",
            rawEntry: rawEntry
        )

        XCTAssertEqual(keyName, "06440")
    }

    func testDictionaryEntryKeyExtractsEntryFreeAttributeWithFlexibleWhitespace() {
        let rawEntry = #"<entryFree type="x" n = "430"><orth>אֱלֹהִים</orth></entryFree>"#

        XCTAssertEqual(
            BibleReaderController.dictionaryEntryKey(actualKey: "", rawEntry: rawEntry),
            "430"
        )
    }

    func testLinkifyRawDictionaryXMLLinksStructuredAndPlainStrongsReferences() {
        let rawEntry = """
        <entryFree n="6440"><def>From 6437; see HEBREW for 05774 and <ref target="StrongsHebrew/02421">2421</ref>.</def></entryFree>
        """

        let linkified = BibleReaderController.linkifyRawDictionaryXML(rawEntry, defaultPrefix: "H")

        XCTAssertTrue(linkified.contains("<entryFree"))
        XCTAssertTrue(linkified.contains("<a href=\"ab-w://?strong=H6437\">6437</a>"))
        XCTAssertTrue(linkified.contains("see HEBREW for <a href=\"ab-w://?strong=H05774\">05774</a>"))
        XCTAssertTrue(linkified.contains("<a href=\"ab-w://?strong=H02421\">2421</a>"))
    }

    func testStrongsLookupKeyOptionsIncludeIntermediateZeroTrimVariants() {
        XCTAssertEqual(
            BibleReaderController.strongsLookupKeyOptions(for: "H00430"),
            ["H00430", "00430", "00430\r", "0430", "0430\r", "H0430", "430", "430\r", "H430"]
        )
    }

    func testDictionaryLookupCandidateRejectsNearestEntryLeakForIntermediateZeroTrimKey() {
        let rawEntry = """
        <entryFree n="430"><orth>אֱלֹהִים</orth></entryFree>
        """
        let renderedText = """
        <div><p>8674 Tatnay tat-ten-ah'-ee of foreign derivation; Tattenai.</p></div>
        """

        XCTAssertEqual(
            BibleReaderController.dictionaryLookupCandidateRejectionReason(
                requested: "H00430",
                actualKey: "0430",
                rawEntry: rawEntry,
                renderedText: renderedText
            ),
            .renderedEntryMismatch
        )
        XCTAssertNil(
            BibleReaderController.dictionaryLookupCandidateRejectionReason(
                requested: "H00430",
                actualKey: "0430",
                rawEntry: rawEntry,
                renderedText: "<div><p>430 'elohiym gods in the ordinary sense.</p></div>"
            )
        )
    }

    func testRawDictionaryEntryMatchesRequestedKeyRejectsMisboundRawEntries() {
        let mismatchedRawEntry = """
        <entryFree n="8674"><orth>תּתּני</orth></entryFree>
        """
        let matchingRawEntry = """
        <entryFree n="5775"><orth>עוף</orth></entryFree>
        """

        XCTAssertFalse(
            BibleReaderController.rawDictionaryEntryMatchesRequestedKey(
                requested: "H05775",
                rawEntry: mismatchedRawEntry
            )
        )
        XCTAssertTrue(
            BibleReaderController.rawDictionaryEntryMatchesRequestedKey(
                requested: "05775\r",
                rawEntry: matchingRawEntry
            )
        )
    }

    func testRenderedDictionaryEntryKeyExtractsLeadingNumericHeadword() {
        let rendered = """
        <div><p>8674 Tatnay tat-ten-ah'-ee of foreign derivation; Tattenai.</p></div>
        """

        XCTAssertEqual(
            BibleReaderController.renderedDictionaryEntryKey(renderedText: rendered),
            "8674"
        )
    }

    func testRenderedDictionaryEntryMatchesRequestedKeyRejectsMismatchedRenderedHeadword() {
        let rendered = """
        <div><p>8674 Tatnay tat-ten-ah'-ee of foreign derivation; Tattenai.</p></div>
        """

        XCTAssertFalse(
            BibleReaderController.renderedDictionaryEntryMatchesRequestedKey(
                requested: "H00430",
                renderedText: rendered
            )
        )
        XCTAssertTrue(
            BibleReaderController.renderedDictionaryEntryMatchesRequestedKey(
                requested: "H00430",
                renderedText: "<div><p>430 'elohiym gods in the ordinary sense.</p></div>"
            )
        )
    }

    func testRenderedDictionaryEntryMatchesRequestedKeyIgnoresCrossReferenceOnlyNumbers() {
        let rendered = """
        <div><p>From 6437; see HEBREW for 05774 and 02421.</p></div>
        """

        XCTAssertTrue(
            BibleReaderController.renderedDictionaryEntryMatchesRequestedKey(
                requested: "H05774",
                renderedText: rendered
            )
        )
        XCTAssertNil(BibleReaderController.renderedDictionaryEntryKey(renderedText: rendered))
    }

    func testIsSupportedStrongsDictionaryModuleNameMatchesAndroidCuratedPolicy() {
        XCTAssertFalse(BibleReaderController.isSupportedStrongsDictionaryModuleName("BDBGlosses_Strongs"))
        XCTAssertTrue(BibleReaderController.isSupportedStrongsDictionaryModuleName("StrongsHebrew"))
        XCTAssertTrue(BibleReaderController.isSupportedStrongsDictionaryModuleName("InvStrongsRealHebrew"))
    }

    func testRenderedContentStateDefaultsToNeutralToken() {
        let controller = BibleReaderController(bridge: BibleBridge())

        XCTAssertEqual(
            controller.renderedContentState,
            BibleReaderController.emptyRenderedContentState
        )
    }
}
