import XCTest
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 Integration coverage for Search reference input routed through `BibleReaderController.navigateToRef`.

 The suite uses a temporary KJV SWORD fixture and recording bridge, matching the production callback
 that Search invokes before compiling FTS syntax. Temporary module files are removed by the shared
 fixture base. Failures mean valid ranges, passage lists, or active-module book aliases can fall
 through to unrelated full-text search.
 */
final class SearchReferenceNavigationTests: BibleUISwordFixtureTestCase {
    /**
     Verifies Search submits the complete input to the reader resolver before compiling text search.

     `SearchView.performSearch` and the owning reader callback are private SwiftUI wiring, so this
     focused guard extracts only those function bodies. The callback must receive the trimmed input
     unchanged and delegate to `navigateToRef`, whose range/list behavior is exercised below. A
     failure means valid references can fall through to FTS despite the parser tests remaining green.
     */
    func testSearchSubmissionUsesFullReaderReferenceResolverBeforeTextSearch() throws {
        let searchSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Search/SearchView.swift"
        )
        let searchFunction = try BibleUITestSourceLocator.extractFunction(
            named: "performSearch",
            from: searchSource
        )
        let callbackRange = try XCTUnwrap(
            searchFunction.range(of: "onOpenReference?(trimmedQuery) == true")
        )
        let textSearchRange = try XCTUnwrap(searchFunction.range(of: ".searchMultiple("))
        XCTAssertLessThan(callbackRange.lowerBound, textSearchRange.lowerBound)

        let readerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )
        let readerCallback = try BibleUITestSourceLocator.extractFunction(
            named: "openReferenceFromSearch",
            from: readerSource
        )
        XCTAssertTrue(readerCallback.contains("controller.navigateToRef(query)"))
    }

    /**
     Guards the final Android-visible Search preview against a second UI cleanup pass.

     - Setup: Reads the private Search result-row source after structured ingestion has persisted
       annotation-free `htmlToSpan`-compatible snippets.
     - Expected result: Single and expanded rows render each complete stored snippet directly;
       only a collapsed multi-translation header receives a two-line visual limit. The former regex
       cleanup and character-prefix APIs are absent so exact long previews survive expansion.
     - Failure meaning: Search UI can mutate the final preview, reintroducing backend-specific
       stripping or Foundation whitespace drift after the index parity boundary.
     - Side effects: Reads one checked-out Swift source file.
     */
    func testSearchRowsRenderStoredPreviewWithoutLegacyCleanup() throws {
        let searchSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Search/SearchView.swift"
        )
        let resultGroup = try BibleUITestSourceLocator.extractFunction(
            named: "searchResultGroup",
            from: searchSource
        )

        XCTAssertTrue(resultGroup.contains("Text(firstMatch.snippet)"))
        XCTAssertTrue(resultGroup.contains("Text(hit.snippet)"))
        XCTAssertTrue(resultGroup.contains(".lineLimit(isSingleMatch ? nil : 2)"))
        XCTAssertFalse(resultGroup.contains("SearchIndexService.cleanText"))
        XCTAssertFalse(resultGroup.contains(".prefix("))
    }

    /**
     Verifies a human-readable verse range uses the full parser and retains its complete ordinal span.

     The controller is made bridge-ready so the emitted setup payload proves both endpoints survive
     navigation. A failure means Search recognizes only the first coordinate or reverts to the narrow
     legacy single-reference parser.
     */
    @MainActor
    func testSearchReferenceRangeNavigatesAsOneCompletePassage() throws {
        let (bridge, scripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count

        XCTAssertTrue(controller.navigateToRef("Genesis 1:1-3"))

        let setup = try XCTUnwrap(
            bridgeEmissionPayload(
                from: Array(scripts().dropFirst(baseline)),
                event: "setup_content"
            ) as? [String: Any]
        )
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 1)
        XCTAssertEqual(
            setup["ordinalStart"] as? Int,
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        XCTAssertEqual(
            setup["ordinalEnd"] as? Int,
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 3)
        )
    }

    /**
     Verifies a discontiguous human-readable passage list becomes one current-pane MultiDocument.

     Android's Search reference resolver accepts the complete `Passage` rather than treating the
     comma as FTS syntax. The recording bridge must receive both exact OSIS references in one
     document. A failure means Search drops later passages or routes the input to text search.
     */
    @MainActor
    func testSearchReferenceListOpensEveryPassageInOneDocument() throws {
        let (bridge, scripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let baseline = scripts().count

        XCTAssertTrue(controller.navigateToRef("Genesis 1:1, Exodus 2:1"))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let emittedScripts = Array(scripts().dropFirst(baseline))
        let addDocumentsScript = try XCTUnwrap(
            emittedScripts.first(where: { $0.contains("emit('add_documents'") })
        )
        XCTAssertTrue(addDocumentsScript.contains(#""type":"multi""#))
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Gen.1.1""#))
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Exod.2.1""#))
    }

    /**
     Verifies Search navigation accepts a book alias resolved by the active module parser.

     `III John` is intentionally outside the former narrow controller path but is accepted by the
     SWORD/JSword-compatible parser. A failure means the Search callback bypasses the full resolver
     and can likewise reject module-language book names.
     */
    @MainActor
    func testSearchReferenceUsesActiveModuleBookAliases() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        XCTAssertTrue(controller.navigateToRef("III John 1:2"))
        XCTAssertEqual(controller.currentBook, "III John")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 2)
    }
}
