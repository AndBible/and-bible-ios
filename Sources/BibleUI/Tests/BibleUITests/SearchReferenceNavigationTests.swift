import XCTest
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 Integration coverage for Search submission precedence and reader reference navigation.

 The suite exercises the typed Strong/reference/text routing policy and uses a temporary KJV SWORD
 fixture with a recording bridge for accepted references. Temporary module files are removed by
 the shared fixture base. Failures mean Strong's identifiers can be coerced into Bible navigation,
 or valid ranges, passage lists, and active-module aliases can fall through to full-text search.
 */
final class SearchReferenceNavigationTests: BibleUISwordFixtureTestCase {
    /**
     Verifies production Search uses typed submission routing before asynchronous indexed search.

     The behavior-level policy tests below prove Strong's precedence. This focused source guard
     connects that policy to private SwiftUI wiring and confirms the owning callback still delegates
     accepted references to `navigateToRef`. A failure means production bypasses the tested router
     or valid references no longer reach the complete reader parser.
     */
    func testSearchSubmissionUsesTypedRouterBeforeIndexedSearch() throws {
        let searchSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Search/SearchView.swift"
        )
        let searchFunction = try BibleUITestSourceLocator.extractFunction(
            named: "performSearch",
            from: searchSource
        )
        let routingRange = try XCTUnwrap(
            searchFunction.range(of: "SearchSubmissionRouter.route(")
        )
        let textSearchRange = try XCTUnwrap(searchFunction.range(of: ".searchMultiple("))
        XCTAssertLessThan(routingRange.lowerBound, textSearchRange.lowerBound)
        XCTAssertTrue(searchFunction.contains("isStrongsFindAll: isStrongsFindAll"))
        XCTAssertTrue(searchFunction.contains("openReference: onOpenReference"))
        XCTAssertTrue(searchFunction.contains("case .invalidStrongsFindAll:"))

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
     Verifies recognized Strong's submissions outrank a permissive Bible reference callback.

     - Setup: Routes manual and explicit Find All variants while a spy resolver would accept every
       input, reproducing SWORD's ability to coerce `G3056` and `H5775` into Revelation 22.
     - Expected result: Every Strong-shaped value remains indexed Strong's work and the resolver is
       never invoked, including an out-of-range shaped value with no canonical tokens.
     - Failure meaning: Search can dismiss itself through Bible navigation before multi-module
       Strong's dispatch begins.
     - Side effects: Mutates only the local resolver-call recording array.
     */
    func testStrongsSubmissionsBypassPermissiveReferenceResolution() {
        let submissions: [(query: String, isFindAll: Bool, expectedTokens: [String])] = [
            ("G3056", false, ["G3056"]),
            ("h5775", true, ["H5775"]),
            ("strong:g3056", false, ["G3056"]),
            ("G10000", false, [])
        ]
        var referenceCalls: [String] = []

        for submission in submissions {
            let route = SearchSubmissionRouter.route(
                query: submission.query,
                isStrongsFindAll: submission.isFindAll,
                openReference: { query in
                    referenceCalls.append(query)
                    return true
                }
            )
            guard case let .indexedSearch(options?) = route else {
                XCTFail("Expected indexed Strong's route for \(submission.query), got \(route)")
                continue
            }
            XCTAssertEqual(options.canonicalStrongTokens, submission.expectedTokens)
        }

        XCTAssertTrue(referenceCalls.isEmpty)
    }

    /**
     Verifies explicit Find All never falls through when its trusted link payload is malformed.

     - Setup: Routes bare, prefix-only, unknown-prefix, and empty values in Find All mode while a
       spy reference callback would accept them.
     - Expected result: Every value fails closed as `invalidStrongsFindAll`, with no callback call.
     - Failure meaning: Malformed bridge input can navigate the Bible or run unrelated text Search.
     - Side effects: Mutates only the local resolver-call counter.
     */
    func testMalformedStrongsFindAllSubmissionsFailClosed() {
        var referenceCallCount = 0
        for query in ["3056", "g", "x3056", ""] {
            let route = SearchSubmissionRouter.route(
                query: query,
                isStrongsFindAll: true,
                openReference: { _ in
                    referenceCallCount += 1
                    return true
                }
            )
            XCTAssertEqual(route, .invalidStrongsFindAll)
        }
        XCTAssertEqual(referenceCallCount, 0)
    }

    /**
     Preserves Android's non-Strong reference-first behavior and ordinary text fallback.

     - Setup: Routes one accepted Bible reference and one declined prose query outside Find All.
     - Expected result: The reference opens after one exact callback, while prose becomes indexed
       text Search with no Strong's options.
     - Failure meaning: Fixing Strong's precedence can break ordinary reference or text submission.
     - Side effects: Records callback inputs in a local array only.
     */
    func testNonStrongsSubmissionsPreserveReferenceThenTextPrecedence() {
        var referenceCalls: [String] = []
        let referenceRoute = SearchSubmissionRouter.route(
            query: "Genesis 1:1",
            isStrongsFindAll: false,
            openReference: { query in
                referenceCalls.append(query)
                return true
            }
        )
        XCTAssertEqual(referenceRoute, .openedReference)

        let textRoute = SearchSubmissionRouter.route(
            query: "faith hope",
            isStrongsFindAll: false,
            openReference: { query in
                referenceCalls.append(query)
                return false
            }
        )
        XCTAssertEqual(textRoute, .indexedSearch(strongsQueryOptions: nil))
        XCTAssertEqual(referenceCalls, ["Genesis 1:1", "faith hope"])
    }

    /**
     Guards the final Android-visible Search preview against a second UI cleanup pass.

     - Setup: Reads the private Search result-row source after structured ingestion has persisted
       annotation-free `htmlToSpan`-compatible snippets.
     - Expected result: Single and expanded rows route the complete stored preview through the
       query-range renderer; only a collapsed multi-translation header receives a two-line visual
       limit, and accessibility labels retain the exact unstyled source.
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

        XCTAssertTrue(resultGroup.contains("highlightedSnippetText(firstMatch)"))
        XCTAssertTrue(resultGroup.contains("highlightedSnippetText(hit, includesModulePrefix: true)"))
        XCTAssertTrue(resultGroup.contains(".accessibilityLabel(firstMatch.snippet)"))
        XCTAssertTrue(resultGroup.contains(".accessibilityLabel(\"\\(hit.moduleName): \\(hit.snippet)\")"))
        XCTAssertTrue(resultGroup.contains(".lineLimit(isSingleMatch ? nil : 2)"))
        XCTAssertFalse(resultGroup.contains("SearchIndexService.cleanText"))
        XCTAssertFalse(resultGroup.contains(".prefix("))
    }

    /**
     Guards production Search against reintroducing dormant strip-text preview APIs.

     - Setup: Reads the SWORD module, Search UI support, and Agent scripture access sources after
       indexed Search became the sole production preview contract.
     - Expected result: SWORD exposes only key-only candidate search; no direct preview search,
       fixed 200-character prefix, or Search UI/Agent fallback to a direct facade remains.
     - Failure meaning: A future call site can bypass structured projection and revive #387/#393.
     - Side effects: Reads checked-out Swift source files.
     */
    func testProductionSearchHasNoLegacyDirectPreviewPath() throws {
        let moduleSource = try BibleUITestSourceLocator.source(
            at: "Sources/SwordKit/Sources/SwordKit/SwordModule.swift"
        )
        let strongsSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Search/StrongsSearchSupport.swift"
        )
        let searchViewSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Search/SearchView.swift"
        )
        let agentSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/AI/AgentScriptureDocumentAccess.swift"
        )

        XCTAssertFalse(moduleSource.contains("public func search(_ options: SearchOptions)"))
        XCTAssertTrue(moduleSource.contains("public func searchKeys(_ options: SearchOptions"))
        XCTAssertFalse(strongsSource.contains(".prefix(200)"))
        XCTAssertFalse(strongsSource.contains(".strippedText"))
        XCTAssertFalse(strongsSource.contains("module.setKeyAndInspect"))
        XCTAssertTrue(strongsSource.contains("inspectVerseKeySearchSourceRestoringPrevious"))
        XCTAssertTrue(strongsSource.contains("inspectVerseKeyOSISSourceRestoringPrevious"))
        XCTAssertTrue(strongsSource.contains("SwordBibleSearchTextProjection.project"))
        XCTAssertFalse(searchViewSource.contains("SearchService"))
        XCTAssertTrue(searchViewSource.contains("SearchIndexService"))
        XCTAssertFalse(agentSource.contains("SearchService"))
        XCTAssertFalse(agentSource.contains("module.search("))
        XCTAssertFalse(agentSource.contains("module.searchKeys("))
        XCTAssertTrue(agentSource.contains("searchIndexService.search("))
        XCTAssertTrue(agentSource.contains("searchIndexService.searchStrongs("))
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
