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
     Verifies a human-readable verse range uses the full parser and retains its complete ordinal span.

     The controller is made bridge-ready so the emitted setup payload proves both endpoints survive
     navigation. A failure means Search recognizes only the first coordinate or reverts to the narrow
     legacy single-reference parser.
     */
    @MainActor
    func testSearchReferenceRangeNavigatesAsOneCompletePassage() async throws {
        let (bridge, scripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count

        XCTAssertTrue(controller.navigateToRef("Genesis 1:1-3"))
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "setup_content",
            after: baseline
        )
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(
                from: emissions,
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
    func testSearchReferenceListOpensEveryPassageInOneDocument() async throws {
        let (bridge, scripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count

        XCTAssertTrue(controller.navigateToRef("Genesis 1:1, Exodus 2:1"))
        _ = try await awaitBridgeEmission(
            from: scripts, event: "add_documents", after: baseline
        )

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
