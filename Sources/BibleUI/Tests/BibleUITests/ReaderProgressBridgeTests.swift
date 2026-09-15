import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 BibleUI reader bridge coverage for native memorization and reading progress integration.

 These tests belong in `BibleUITests` because they validate how `BibleReaderController` wires raw
 `BibleBridge` messages to native progress stores and emitted Vue payloads. Pure bridge parsing is
 covered in `BibleViewTests`, while pure store persistence is covered in `BibleCoreTests`.
 */
final class ReaderProgressBridgeTests: BibleUISwordFixtureTestCase {
    /**
     Verifies memorization bridge messages mutate the controller-owned native store.

     Setup uses a deterministic KJV SWORD module plus an in-memory `SettingsStore` and derives the
     same source ordinals Vue sends for Genesis 1:1-3. The expected result is that target and
     memorized sets match the requested operations in Android's KJVA-global domain, while a
     non-positive start ordinal leaves a fresh store untouched. A failure means the bridge accepted
     invalid source data, preserved module-scoped state, or lost Android's `endOrdinal <= 0`
     single-verse behavior.
     */
    func testBridgeMemorizationMessagesMutateNativeStore() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        let store = try XCTUnwrap(controller.memorizationProgressStore)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let verseOneOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        let verseTwoOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 2)
        )
        let verseThreeOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 3)
        )

        XCTAssertTrue(store.snapshot().targetRows.isEmpty)
        XCTAssertTrue(store.snapshot().memorizedVerses.isEmpty)
        XCTAssertEqual(
            bridge.dispatchMessage(method: "addMemorizationTarget", args: ["KJV", 0, 0]),
            .handled
        )
        XCTAssertTrue(store.snapshot().targetRows.isEmpty)
        XCTAssertTrue(store.snapshot().memorizedVerses.isEmpty)

        XCTAssertEqual(
            bridge.dispatchMessage(method: "memorize", args: ["KJV", verseOneOrdinal, -1]),
            .handled
        )
        XCTAssertEqual(store.targetOrdinals(bookInitials: "", startOrdinal: 4, endOrdinal: 6), [4])

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "addMemorizationTarget",
                args: ["KJV", verseTwoOrdinal, verseThreeOrdinal]
            ),
            .handled
        )
        XCTAssertEqual(store.targetOrdinals(bookInitials: "", startOrdinal: 4, endOrdinal: 6), [4, 5, 6])

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "markAsMemorized",
                args: ["KJV", verseOneOrdinal, verseThreeOrdinal]
            ),
            .handled
        )
        XCTAssertEqual(store.memorizedOrdinals(bookInitials: "", startOrdinal: 4, endOrdinal: 6), [4, 5, 6])

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "removeMemorizationTarget",
                args: ["KJV", verseTwoOrdinal, verseTwoOrdinal]
            ),
            .handled
        )
        XCTAssertEqual(store.targetOrdinals(bookInitials: "", startOrdinal: 4, endOrdinal: 6), [4, 6])

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "unmarkMemorized",
                args: ["KJV", verseTwoOrdinal, verseThreeOrdinal]
            ),
            .handled
        )
        XCTAssertEqual(store.memorizedOrdinals(bookInitials: "", startOrdinal: 4, endOrdinal: 6), [4])
    }

    /**
     Verifies progress mutations use Android-37 Java identity instead of Foundation normalization.

     - Setup: Activates a readable Bible whose initials contain precomposed `é`, navigates Genesis
       1, and dispatches memorization plus chapter-progress messages first with the canonically
       equivalent decomposed spelling and then with a Java-compatible uppercase spelling.
     - Expected result: The decomposed identity mutates neither store, while the uppercase spelling
       is accepted by Java `equalsIgnoreCase` and proves the bridge setup is live.
     - Failure meaning: A stale or colliding Unicode source can write memorization/progress data for
       the active Bible even though Android treats the two document identities as distinct.
     - Side effects: Writes one inherited temporary SWORD alias and mutates in-memory settings only
       for the final valid control messages.
     - Failure modes: Fixture discovery, versification lookup, and in-memory store setup can throw.
     */
    @MainActor
    func testProgressAndMemorizationRejectJavaDistinctCanonicalEquivalentInitials() throws {
        let composedInitials = "Caf\u{00E9}"
        let decomposedInitials = "Cafe\u{0301}"
        XCTAssertEqual(composedInitials.caseInsensitiveCompare(decomposedInitials), .orderedSame)
        XCTAssertFalse(
            SwordJavaStringIdentity.equalsIgnoreCase(composedInitials, decomposedInitials)
        )

        let bridge = BibleBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: composedInitials,
            description: "Java identity progress fixture",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.readableModule(named: composedInitials))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        XCTAssertEqual(controller.switchBibleDocument(to: composedInitials), .switched)
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        let ordinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        let memorizationStore = try XCTUnwrap(controller.memorizationProgressStore)
        let readingProgressStore = try XCTUnwrap(controller.readingProgressStore)

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "addMemorizationTarget",
                args: [decomposedInitials, ordinal, ordinal]
            ),
            .handled
        )
        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "recordChapterRead",
                args: [decomposedInitials, ordinal, 1, "AUTO_SCROLL"]
            ),
            .handled
        )
        XCTAssertTrue(memorizationStore.snapshot().targetRows.isEmpty)
        XCTAssertTrue(readingProgressStore.snapshot().history.isEmpty)

        let javaCompatibleCaseVariant = composedInitials.uppercased()
        XCTAssertTrue(
            SwordJavaStringIdentity.equalsIgnoreCase(composedInitials, javaCompatibleCaseVariant)
        )
        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "addMemorizationTarget",
                args: [javaCompatibleCaseVariant, ordinal, ordinal]
            ),
            .handled
        )
        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "recordChapterRead",
                args: [javaCompatibleCaseVariant, ordinal, 1, "AUTO_SCROLL"]
            ),
            .handled
        )
        XCTAssertFalse(memorizationStore.snapshot().targetRows.isEmpty)
        XCTAssertEqual(readingProgressStore.snapshot().history.count, 1)
    }

    /**
     Verifies memorization deltas convert from KJVA back into a divergent active module.

     The fixture stores a sparse synthetic Psalm 10:1 row at the Vulgate canon's physical index and
     dispatches the same bridge mutation as Vue. JSword maps that source verse to the KJVA Psalm 11
     superscription. Android then converts the stored KJVA event ordinal back to Vulgate before
     notifying the document.

     Expected result:
     - persistence contains the KJVA chapter-introduction ordinal
     - the emitted Vue delta contains the original Vulgate rendered ordinal

     Failure means the bridge is converting rendered ordinals toward KJVA twice, dropping verse-0
     mappings, or leaking a KJVA ordinal into the active-module document.
     */
    @MainActor
    func testBridgeMemorizationProjectsKJVAEventsBackIntoDivergentModule() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedSyntheticRawTextBibleModule(
            named: "VulgTest",
            description: "Vulgate projection fixture",
            versification: "Vulg",
            entries: [
                (
                    "Ps", 10, 1,
                    #"<verse osisID="Ps.10.1">Synthetic Vulgate memorization source.</verse>"#
                ),
            ],
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        controller.switchModule(to: "VulgTest")
        controller.navigateTo(book: "Psalms", chapter: 10)
        controller.bridgeDidSetClientReady(bridge)

        let module = try XCTUnwrap(manager.module(named: "VulgTest"))
        let renderedOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Ps", chapter: 10, verse: 1)
        )
        let source = try module.inspectVerseSourceRangeRestoringPrevious(
            startOrdinal: renderedOrdinal,
            endOrdinal: renderedOrdinal
        )
        XCTAssertTrue(
            source.entries.compactMap(\.osisFragment).joined()
                .contains("Synthetic Vulgate memorization source.")
        )
        let kjvaOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.chapterIntroOrdinal(osisId: "Ps", chapter: 11)
        )
        let baselineScriptCount = recordedScripts().count

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "addMemorizationTarget",
                args: ["VulgTest", renderedOrdinal, renderedOrdinal]
            ),
            .handled
        )

        let store = try XCTUnwrap(controller.memorizationProgressStore)
        XCTAssertEqual(
            store.targetOrdinals(
                bookInitials: "",
                startOrdinal: kjvaOrdinal,
                endOrdinal: kjvaOrdinal
            ),
            [kjvaOrdinal]
        )
        let trust = try XCTUnwrap(store.snapshot().targetRows.first?.ordinalTrust)
        XCTAssertEqual(trust.state, .verifiedMappingV1)
        XCTAssertEqual(trust.provenance, .nativeMapping)
        XCTAssertEqual(trust.sourceBookInitials, "VulgTest")
        XCTAssertEqual(trust.sourceVersification, "Vulg")
        XCTAssertEqual(trust.sourceOrdinalStart, renderedOrdinal)
        XCTAssertEqual(trust.sourceOrdinalEnd, renderedOrdinal)
        XCTAssertEqual(trust.mappingVersion, PersistedOrdinalTrustPolicy.currentMappingVersion)
        let delta = try XCTUnwrap(
            bridgeEmissionPayload(
                from: Array(recordedScripts().dropFirst(baselineScriptCount)),
                event: "update_memorization_data"
            ) as? [String: Any]
        )
        XCTAssertEqual(delta["addedTargets"] as? [Int], [renderedOrdinal])
    }

    /**
     Verifies a divergent target canon emits JSword's canonical chapter-introduction ordinal.

     Android expands every ordinal in the persisted KJVA range and converts each `Verse` into the
     open document's versification. The source-valid sparse Vulgate fixture has no Genesis 2:0 text
     row, but the Vulgate canon still owns that intro-inclusive ordinal. This fixture crosses
     Genesis 1:31 through 2:2 and proves iOS round-trips the verse-zero reference through Vulgate's
     canonical index instead of emitting sentinel `0` or dropping the entry.

     Failure means divergent modules no longer receive Android-equivalent memorization deltas for
     cross-chapter target ranges.
     */
    @MainActor
    func testBridgeMemorizationEmitsCanonicalIntroOrdinalForDivergentTargetCanon() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedSyntheticRawTextBibleModule(
            named: "VulgTest",
            description: "Vulgate intro projection fixture",
            versification: "Vulg",
            entries: [
                (
                    "Gen", 1, 31,
                    #"<verse osisID="Gen.1.31">Synthetic Vulgate Genesis one end.</verse>"#
                ),
                (
                    "Gen", 2, 1,
                    #"<verse osisID="Gen.2.1">Synthetic Vulgate Genesis two one.</verse>"#
                ),
                (
                    "Gen", 2, 2,
                    #"<verse osisID="Gen.2.2">Synthetic Vulgate Genesis two two.</verse>"#
                ),
            ],
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        controller.switchModule(to: "VulgTest")
        controller.navigateTo(book: "Genesis", chapter: 1)
        controller.bridgeDidSetClientReady(bridge)

        let module = try XCTUnwrap(manager.module(named: "VulgTest"))
        let startOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 31)
        )
        let middleOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 1)
        )
        let endOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 2)
        )
        let source = try module.inspectVerseSourceRangeRestoringPrevious(
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
        let sourceXML = source.entries.compactMap(\.osisFragment).joined()
        XCTAssertTrue(sourceXML.contains("Synthetic Vulgate Genesis one end."))
        XCTAssertTrue(sourceXML.contains("Synthetic Vulgate Genesis two one."))
        XCTAssertTrue(sourceXML.contains("Synthetic Vulgate Genesis two two."))
        let kjvaIntroOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.chapterIntroOrdinal(osisId: "Gen", chapter: 2)
        )
        let targetIntroReference = SwordVersification.Reference(
            osisBookId: "Gen",
            chapter: 2,
            verse: 0
        )
        let targetIntroOrdinal = try XCTUnwrap(
            SwordVersification.referenceIndex(for: targetIntroReference, versification: "Vulg")
        )
        let sentinelProjection = try XCTUnwrap(
            VersificationMapper.moduleProjection(
                forKJVAOrdinal: kjvaIntroOrdinal,
                targetModule: module
            )
        )
        XCTAssertEqual(sentinelProjection.reference, targetIntroReference)
        XCTAssertEqual(sentinelProjection.ordinal, 0)
        XCTAssertEqual(
            SwordVersification.reference(forIndex: targetIntroOrdinal, versification: "Vulg"),
            targetIntroReference
        )

        let baselineScriptCount = recordedScripts().count
        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "addMemorizationTarget",
                args: ["VulgTest", startOrdinal, endOrdinal]
            ),
            .handled
        )

        let delta = try XCTUnwrap(
            bridgeEmissionPayload(
                from: Array(recordedScripts().dropFirst(baselineScriptCount)),
                event: "update_memorization_data"
            ) as? [String: Any]
        )
        XCTAssertEqual(
            delta["addedTargets"] as? [Int],
            [startOrdinal, targetIntroOrdinal, middleOrdinal, endOrdinal]
        )
    }

    /**
     Verifies the reader's Memorize bridge action emits Android's fake-document payload.

     Android opens memorization practice as a reader document after adding the selected ordinal
     range as a target. The iOS bridge must preserve that user-visible contract when document
     assembly is tested outside the app-host bundle: the emitted document remains `type=memorize`,
     includes selected verse text, carries target ordinals, and sends a normal `setup_content`
     payload. A failure means the refactor broke Android parity by mutating progress state without
     opening the expected Memorize reader document, or by emitting a malformed document/setup
     payload.
     */
    @MainActor
    func testReaderMemorizeBridgeEmitsAndroidStyleDocumentPayload() async throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let startOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        let endOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 2))

        controller.bridgeDidSetClientReady(bridge)
        let initialScriptCount = recordedScripts().count

        controller.bridge(
            bridge,
            memorize: "KJV",
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )

        let memorizeScripts = try await awaitBridgeEmission(
            from: recordedScripts,
            event: "add_documents",
            after: initialScriptCount
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: memorizeScripts, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["type"] as? String, "memorize")
        XCTAssertEqual(document["bookInitials"] as? String, "KJV")
        XCTAssertEqual(document["title"] as? String, "Genesis 1:1-2")
        XCTAssertEqual(document["osisRef"] as? String, "Gen.1.1-Gen.1.2")
        XCTAssertEqual(document["startOrdinal"] as? Int, startOrdinal)
        XCTAssertEqual(document["endOrdinal"] as? Int, endOrdinal)
        XCTAssertEqual(document["targetOrdinals"] as? [Int], [startOrdinal, endOrdinal])

        let texts = try XCTUnwrap(document["texts"] as? [[String: String]])
        XCTAssertEqual(texts.map { $0["key"] }, ["Gen.1.1", "Gen.1.2"])
        XCTAssertTrue(texts.first?["text"]?.contains("In the beginning") == true)
        XCTAssertFalse(
            texts.contains { ($0["text"] ?? "").contains("<H") },
            "Memorize practice text should match Android canonical text and omit raw Strong's tags."
        )

        let setupPayload = try XCTUnwrap(
            bridgeEmissionPayload(from: memorizeScripts, event: "setup_content") as? [String: Any]
        )
        XCTAssertTrue(setupPayload["jumpToOrdinal"] is NSNull)
        XCTAssertTrue(setupPayload["jumpToAnchor"] is NSNull)
        XCTAssertTrue(setupPayload["jumpToId"] is NSNull)
        XCTAssertEqual(setupPayload["topOffset"] as? Int, 0)
        XCTAssertEqual(setupPayload["bottomOffset"] as? Int, 0)
        XCTAssertFalse(controller.allowsHorizontalDocumentNavigation)
        XCTAssertEqual(
            controller.renderedContentState,
            "category=commentary;module=Memorize;book=Genesis 1:1-2;chapter=none;key=memorize:KJV:\(startOrdinal)-\(endOrdinal)"
        )

        controller.loadCurrentContent()
        XCTAssertFalse(controller.allowsHorizontalDocumentNavigation)
    }

    /**
     Verifies Memorize uses Android's hidden commentary fake-document identity.

     Android routes Memorize through `LinkControl.showLink(FakeBookFactory.memorizeDocument, ...)`,
     so the visible pane becomes a commentary-category fake document rather than ordinary Bible
     content. This setup opens Memorize through the same bridge action without a pane-owner
     links-window callback, matching Android's "open here" fallback. A failure means iOS may render
     the right Vue payload while native chrome, tab identity, sync controls, and restore state still
     treat the pane as a full Bible window.
     */
    @MainActor
    func testReaderMemorizeBridgeUsesAndroidCommentaryFakeDocumentIdentity() async throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let settingsStore = try makeInMemorySettingsStore()
        controller.settingsStore = settingsStore
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleBibleBook = 0
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 1
        window.pageManager = pageManager
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))

        controller.bridgeDidSetClientReady(bridge)
        let initialScriptCount = recordedScripts().count
        controller.bridge(
            bridge,
            memorize: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        )

        _ = try await awaitBridgeEmission(
            from: recordedScripts,
            event: "add_documents",
            after: initialScriptCount
        )
        XCTAssertEqual(controller.currentCategory, .commentary)
        XCTAssertEqual(controller.activeModuleName(for: .commentary), "Memorize")
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.commentary.pageManagerKey)
        XCTAssertEqual(pageManager.commentaryDocument, "Memorize")
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, ordinal)
        let sourceBookAndKey = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
            .pageManagerEntry(for: window.id)?
            .commentarySourceBookAndKey
        let sourceBookAndKeyData = try XCTUnwrap(sourceBookAndKey?.data(using: .utf8))
        let sourceBookAndKeyPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sourceBookAndKeyData) as? [String: Any]
        )
        XCTAssertEqual(sourceBookAndKeyPayload["document"] as? String, "KJV")
        XCTAssertEqual(sourceBookAndKeyPayload["key"] as? String, "Gen.1.1")
        XCTAssertTrue(sourceBookAndKeyPayload["ordinalRange"] is NSNull)
        XCTAssertFalse(controller.canUseBibleReferenceActions)
        XCTAssertFalse(controller.isCurrentPageSearchable)
        XCTAssertFalse(controller.isCurrentPageSpeakable)
        XCTAssertFalse(controller.isCurrentPageSyncable)
        XCTAssertFalse(controller.allowsHorizontalDocumentNavigation)

        let persisted = expectation(description: "memorize scroll does not persist")
        persisted.isInverted = true
        controller.onPersistState = { persisted.fulfill() }
        controller.bridge(
            bridge,
            didScrollToOrdinal: ordinal + 2,
            key: "Gen.1.1",
            atChapterTop: false
        )
        XCTAssertEqual(controller.currentVerse, 1)
        XCTAssertEqual(pageManager.bibleBibleBook, 0)
        XCTAssertEqual(pageManager.bibleChapterNo, 1)
        XCTAssertEqual(pageManager.bibleVerseNo, 1)
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, ordinal)
        await fulfillment(of: [persisted], timeout: 0.45)
    }

    /**
     Verifies Memorize bridge actions hand off to pane-owned links-window routing.

     Android opens `FakeBookFactory.memorizeDocument` through the same links-window machinery used
     by dictionary and commentary links. This setup installs the controller routing callback to
     capture the built Memorize emission, proving the source pane does not render the document
     itself, then renders the emission into a target links-window controller. The expected result is
     that the target, not the source, owns Android's `commentary/Memorize` native identity and emits
     the Vue payload. A failure means iOS can still replace the user's main Bible pane with Memorize
     instead of using the configured multi-window target.
     */
    @MainActor
    func testReaderMemorizeBridgeUsesLinksWindowRoutingCallbackWhenAvailable() async throws {
        let (sourceBridge, sourceScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let worker = DispatchQueue(label: "org.andbible.tests.memorize-links-route")
        let sourceController = BibleReaderController(
            bridge: sourceBridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: BibleReaderDocumentPreparationCoordinator(
                workerQueue: worker
            )
        )
        sourceController.settingsStore = try makeInMemorySettingsStore()
        var routedRequests: [BibleReaderMemorizeRenderRequest] = []
        sourceController.onOpenMemorizeDocumentInLinksWindow = { request in
            routedRequests.append(request)
        }
        let module = try XCTUnwrap(manager.module(named: sourceController.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))

        let sourceReadyBoundary = sourceScripts().count
        sourceController.bridgeDidSetClientReady(sourceBridge)
        let sourceReadyScripts = try await awaitBridgeEmission(
            from: sourceScripts,
            event: "add_documents",
            after: sourceReadyBoundary
        )
        let sourceReadyDocument = try XCTUnwrap(
            bridgeEmissionPayload(from: sourceReadyScripts, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(sourceReadyDocument["type"] as? String, "bible")
        let initialSourceScriptCount = sourceScripts().count
        let initialSourceRenderedState = sourceController.renderedContentState
        worker.suspend()

        sourceController.bridge(
            sourceBridge,
            memorize: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        )
        sourceController.bridge(
            sourceBridge,
            memorize: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        )
        worker.resume()

        try await awaitReaderCondition("Memorize emission routed to the links-window owner") {
            routedRequests.count == 1
        }
        let sourceMemorizeScripts = Array(sourceScripts().dropFirst(initialSourceScriptCount))
        XCTAssertFalse(sourceMemorizeScripts.contains { $0.contains("add_documents") })
        XCTAssertEqual(sourceController.currentCategory, .bible)
        XCTAssertEqual(sourceController.renderedContentState, initialSourceRenderedState)

        XCTAssertEqual(routedRequests.count, 1)
        let routedRequest = try XCTUnwrap(routedRequests.first)
        let emission = routedRequest.emission
        XCTAssertEqual(emission.bookInitials, "KJV")
        XCTAssertEqual(emission.startOrdinal, ordinal)
        XCTAssertEqual(emission.endOrdinal, ordinal)
        XCTAssertEqual(emission.source.bookInitials, "KJV")
        XCTAssertEqual(emission.source.references.count, 1)
        XCTAssertEqual(emission.source.references.first?.osisBookId, "Gen")
        XCTAssertEqual(emission.source.references.first?.chapter, 1)
        XCTAssertEqual(emission.source.references.first?.verse, 1)
        XCTAssertEqual(emission.source.references.first?.ordinal, ordinal)

        let (targetBridge, targetScripts) = makeRecordingBridge()
        let targetController = BibleReaderController(bridge: targetBridge, swordManagerOverride: manager)
        let targetSettingsStore = try makeInMemorySettingsStore()
        targetController.settingsStore = targetSettingsStore
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id)
        self.retainReaderWindowGraph(window, attaching: pageManager)
        targetController.activeWindow = window
        let targetReadyBoundary = targetScripts().count
        targetController.bridgeDidSetClientReady(targetBridge)
        let targetReadyScripts = try await awaitBridgeEmission(
            from: targetScripts,
            event: "add_documents",
            after: targetReadyBoundary
        )
        let targetReadyDocument = try XCTUnwrap(
            bridgeEmissionPayload(from: targetReadyScripts, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(targetReadyDocument["type"] as? String, "bible")
        let initialTargetScriptCount = targetScripts().count

        targetController.renderMemorizeDocument(routedRequest)

        let targetMemorizeScripts = try await awaitBridgeEmission(
            from: targetScripts,
            event: "add_documents",
            after: initialTargetScriptCount
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: targetMemorizeScripts, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["type"] as? String, "memorize")
        XCTAssertEqual(document["title"] as? String, "Genesis 1:1")
        XCTAssertEqual(targetController.currentCategory, .commentary)
        XCTAssertEqual(targetController.activeModuleName(for: .commentary), "Memorize")
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.commentary.pageManagerKey)
        XCTAssertEqual(pageManager.commentaryDocument, "Memorize")
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, ordinal)
        XCTAssertNotNil(
            RemoteSyncWorkspaceFidelityStore(settingsStore: targetSettingsStore)
                .pageManagerEntry(for: window.id)?
                .commentarySourceBookAndKey
        )
        XCTAssertFalse(targetController.canUseBibleReferenceActions)
        XCTAssertFalse(targetController.isCurrentPageSearchable)
        XCTAssertFalse(targetController.isCurrentPageSpeakable)
        XCTAssertFalse(targetController.isCurrentPageSyncable)
        XCTAssertFalse(targetController.allowsHorizontalDocumentNavigation)
    }

    /**
     Verifies Memorize document payloads keep Android's full selected `VerseRange`.

     Android constructs a JSword `VerseRange` from the selected start/end ordinals and persists the
     complete KJVA span, including its addressable chapter introduction. Android emits one text row
     for every element in that span. Its canonical-text handler ignores the OSIS chapter title, so
     the introduction row remains addressable with empty text. This setup selects Genesis 1:31
     through Genesis 2:2 and crosses exactly one chapter-introduction ordinal.

     Failure means iOS has preserved an artificial same-chapter document structure instead of
     matching Android's Memorize range behavior.
     */
    @MainActor
    func testReaderMemorizeBridgeEmitsCrossChapterAndroidRangePayload() async throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let startOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 31))
        let middleOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 1))
        let endOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 2))
        let kjvaStartOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 31)
        )
        let kjvaIntroOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.chapterIntroOrdinal(osisId: "Gen", chapter: 2)
        )
        let targetIntroOrdinal = try XCTUnwrap(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 2, verse: 0),
                versification: VersificationMapper.versificationName(for: module)
            )
        )
        XCTAssertEqual(targetIntroOrdinal, 35)
        let kjvaMiddleOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 2, verse: 1)
        )
        let kjvaEndOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 2, verse: 2)
        )
        let store = try XCTUnwrap(controller.memorizationProgressStore)
        XCTAssertTrue(store.snapshot().targetRows.isEmpty)

        controller.bridgeDidSetClientReady(bridge)
        let initialScriptCount = recordedScripts().count

        controller.bridge(
            bridge,
            memorize: "KJV",
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )

        let memorizeScripts = try await awaitBridgeEmission(
            from: recordedScripts,
            event: "add_documents",
            after: initialScriptCount
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: memorizeScripts, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["type"] as? String, "memorize")
        XCTAssertEqual(document["title"] as? String, "Genesis 1:31-2:2")
        XCTAssertEqual(document["osisRef"] as? String, "Gen.1.31-Gen.2.2")
        XCTAssertEqual(document["startOrdinal"] as? Int, startOrdinal)
        XCTAssertEqual(document["endOrdinal"] as? Int, endOrdinal)
        let targetOrdinals = try XCTUnwrap(document["targetOrdinals"] as? [Int])
        XCTAssertEqual(
            targetOrdinals,
            [startOrdinal, targetIntroOrdinal, middleOrdinal, endOrdinal]
        )
        XCTAssertTrue(targetOrdinals.allSatisfy { $0 > 0 })
        XCTAssertEqual(
            store.targetOrdinals(
                bookInitials: "",
                startOrdinal: kjvaStartOrdinal,
                endOrdinal: kjvaEndOrdinal
            ),
            [kjvaStartOrdinal, kjvaIntroOrdinal, kjvaMiddleOrdinal, kjvaEndOrdinal]
        )

        let texts = try XCTUnwrap(document["texts"] as? [[String: String]])
        XCTAssertEqual(
            texts.map { $0["key"] },
            ["Gen.1.31", "Gen.2.0", "Gen.2.1", "Gen.2.2"]
        )
        let lastChapterVerse = try XCTUnwrap(
            texts.first { $0["key"] == "Gen.1.31" }?["text"]
        )
        let introduction = try XCTUnwrap(
            texts.first { $0["key"] == "Gen.2.0" }?["text"]
        )
        let firstChapterVerse = try XCTUnwrap(
            texts.first { $0["key"] == "Gen.2.1" }?["text"]
        )
        let secondChapterVerse = try XCTUnwrap(
            texts.first { $0["key"] == "Gen.2.2" }?["text"]
        )
        XCTAssertTrue(lastChapterVerse.contains("saw every thing"))
        XCTAssertEqual(introduction, "")
        XCTAssertTrue(firstChapterVerse.contains("heavens and the earth"))
        XCTAssertTrue(secondChapterVerse.contains("seventh day"))
        XCTAssertFalse(
            texts.contains { ($0["text"] ?? "").contains("<H") },
            "Cross-chapter Memorize payloads should not preserve SWORD Strong's markup."
        )
    }

    /**
     Verifies Memorize canonical text extraction suppresses Greek Strong's tokens too.

     Android uses JSword canonical text for Memorize documents across both testaments. This setup
     opens a New Testament range through the same bridge path users trigger from the reader. A
     failure means iOS may have fixed only Hebrew-looking markup while leaving Greek Strong's noise
     visible.
     */
    @MainActor
    func testReaderMemorizeBridgeEmitsCanonicalGreekStrongText() async throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "John", chapter: 1, verse: 1))
        controller.navigateTo(book: "John", chapter: 1)

        controller.bridgeDidSetClientReady(bridge)
        let initialScriptCount = recordedScripts().count

        controller.bridge(
            bridge,
            memorize: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        )

        let memorizeScripts = try await awaitBridgeEmission(
            from: recordedScripts,
            event: "add_documents",
            after: initialScriptCount
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: memorizeScripts, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["type"] as? String, "memorize")
        XCTAssertEqual(document["title"] as? String, "John 1:1")

        let texts = try XCTUnwrap(document["texts"] as? [[String: String]])
        XCTAssertEqual(texts.map { $0["key"] }, ["John.1.1"])
        XCTAssertTrue(texts.first?["text"]?.contains("In the beginning was the Word") == true)
        XCTAssertFalse(
            texts.contains { ($0["text"] ?? "").contains("<G") },
            "New Testament Memorize payloads should not preserve Greek Strong's markup."
        )
    }

    /**
     Verifies reading-progress bridge messages update native history and emit chapter-count changes.

     The setup navigates a deterministic SWORD KJV module to Exodus 2 and derives the bridge ordinal
     from that module, as Android's Bible document does. It dispatches Vue messages for automatic,
     manual, and clear operations and records JavaScript emissions. Invalid chapter identifiers are
     ignored, valid records persist with Android source mapping, and clearing emits the updated count.
     A failure indicates reader progress state and the web reader's status badges can diverge.
     */
    func testBridgeReadingProgressMessagesMutateNativeStoreAndEmitCounts() throws {
        let bridge = BibleBridge()
        var scripts: [String] = []
        bridge.javaScriptEvaluationObserver = { scripts.append($0) }
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        let store = try XCTUnwrap(controller.readingProgressStore)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let startOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Exod", chapter: 2, verse: 1)
        )
        controller.navigateTo(book: "Exodus", chapter: 2)

        XCTAssertEqual(store.chapterReadCount(kjvBookOrdinal: 3, chapter: 2), 0)
        XCTAssertTrue(store.snapshot().history.isEmpty)

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "recordChapterRead",
                args: ["KJV", startOrdinal, 0, "AUTO_SCROLL"]
            ),
            .handled
        )
        XCTAssertEqual(
            bridge.dispatchMessage(method: "unmarkChapterRead", args: ["KJV", startOrdinal, -1]),
            .handled
        )
        XCTAssertTrue(scripts.isEmpty)
        XCTAssertEqual(store.snapshot().history.count, 0)

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "recordChapterRead",
                args: ["KJV", startOrdinal, 2, "AUTO_SCROLL"]
            ),
            .handled
        )
        XCTAssertEqual(store.chapterReadCount(kjvBookOrdinal: 3, chapter: 2), 1)
        XCTAssertTrue(store.snapshot().history.contains { $0.source == .autoScroll })

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "markChapterRead",
                args: ["KJV", startOrdinal, 2, "not-a-source"]
            ),
            .handled
        )
        XCTAssertEqual(store.chapterReadCount(kjvBookOrdinal: 3, chapter: 2), 2)
        XCTAssertTrue(store.snapshot().history.contains { $0.source == .manual })

        XCTAssertEqual(
            bridge.dispatchMessage(method: "unmarkChapterRead", args: ["KJV", startOrdinal, 2]),
            .handled
        )
        XCTAssertEqual(store.chapterReadCount(kjvBookOrdinal: 3, chapter: 2), 0)
        XCTAssertTrue(
            scripts.contains { script in
                script.contains("bibleView.emit('update_chapter_read_status'") &&
                    script.contains(#""chapter":2"#) &&
                    script.contains(#""count":0"#)
            }
        )
    }

    /**
     Verifies reading-progress bridge navigation and settings handoffs stay native-owned.

     The setup records reader-controller callbacks and bridge emissions for progress dialogs,
     chapter history, and memorization display settings. Its valid history request uses the active
     SWORD module's Exodus 2:1 ordinal, matching Android's document-owned bridge data. Only valid
     history targets open native UI, accepted settings update both the native store and Vue config,
     and malformed bundles leave state unchanged. A failure means native routing drifted from the
     Android bridge contract.
     */
    func testBridgeReadingProgressSettingsAndPresentationHandoffs() throws {
        let bridge = BibleBridge()
        var scripts: [String] = []
        bridge.javaScriptEvaluationObserver = { scripts.append($0) }
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let startOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Exod", chapter: 2, verse: 1)
        )
        controller.navigateTo(book: "Exodus", chapter: 2)

        var openedTabs: [Int] = []
        var openedSettingsCount = 0
        var historyTargets: [ChapterReadHistoryTarget] = []
        controller.onShowReadingProgress = { openedTabs.append($0) }
        controller.onShowReadingProgressSettings = { openedSettingsCount += 1 }
        controller.onShowChapterReadHistory = { historyTargets.append($0) }

        XCTAssertEqual(bridge.dispatchMessage(method: "openReadingProgress", args: [1]), .handled)
        XCTAssertEqual(openedTabs, [1])

        XCTAssertEqual(bridge.dispatchMessage(method: "openReadingProgressSettings", args: []), .handled)
        XCTAssertEqual(openedSettingsCount, 1)

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "openChapterReadHistory",
                args: ["KJV", startOrdinal, 2]
            ),
            .handled
        )
        XCTAssertEqual(historyTargets.count, 1)
        XCTAssertEqual(historyTargets.first?.bookInitials, "KJV")
        XCTAssertEqual(historyTargets.first?.startOrdinal, startOrdinal)
        XCTAssertEqual(historyTargets.first?.kjvBookOrdinal, 3)
        XCTAssertEqual(historyTargets.first?.bookName, "Exodus")
        XCTAssertEqual(historyTargets.first?.chapter, 2)

        XCTAssertEqual(bridge.dispatchMessage(method: "openChapterReadHistory", args: ["KJV", 1, 1]), .handled)
        XCTAssertEqual(
            bridge.dispatchMessage(method: "openChapterReadHistory", args: ["NIV", startOrdinal, 2]),
            .handled
        )
        XCTAssertEqual(historyTargets.count, 1)

        XCTAssertEqual(
            bridge.dispatchMessage(method: "setReadingProgressSettings", args: ["""
            {
              "autoMarkMemorized": false,
              "memorizeTypeFullWords": true,
              "memorizeWordVisibility": "hidden",
              "memorizeErrorHeatmap": false,
              "memorizeScrambleHideUsed": true,
              "memorizeIncludeReference": false
            }
            """]),
            .handled
        )

        let settings = try XCTUnwrap(controller.readingProgressStore?.snapshot().settings)
        XCTAssertEqual(settings.autoMarkMemorized, false)
        XCTAssertEqual(settings.memorizeTypeFullWords, true)
        XCTAssertEqual(settings.memorizeWordVisibility, "hidden")
        XCTAssertEqual(settings.memorizeErrorHeatmap, false)
        XCTAssertEqual(settings.memorizeScrambleHideUsed, true)
        XCTAssertEqual(settings.memorizeIncludeReference, false)
        XCTAssertTrue(
            scripts.contains { script in
                script.contains("bibleView.emit('update_reading_progress_settings'") &&
                    script.contains(#""memorizeWordVisibility":"hidden""#)
            }
        )
        XCTAssertTrue(scripts.contains { $0.contains("bibleView.emit('set_config'") })

        let scriptCount = scripts.count
        XCTAssertEqual(
            bridge.dispatchMessage(method: "setReadingProgressSettings", args: [#"{"memorizeWordVisibility":"opaque"}"#]),
            .handled
        )
        XCTAssertEqual(scripts.count, scriptCount)
        XCTAssertEqual(controller.readingProgressStore?.snapshot().settings, settings)
    }

}

/** Returns the latest memorization delta emitted inside a caller-defined action boundary. */
private func latestMemorizationPayload(from scripts: [String]) throws -> [String: Any] {
    try XCTUnwrap(
        bridgeEmissionPayload(
            from: scripts,
            event: "update_memorization_data",
            selection: .last
        ) as? [String: Any]
    )
}

/** Creates one trusted KJVA range for reader progress integration fixtures. */
private func readerProgressVerifiedKJVARange(
    start: Int,
    end: Int
) throws -> VerifiedKJVAOrdinalRange {
    try XCTUnwrap(
        VerifiedKJVAOrdinalRange(
            resolvingSourceBookInitials: "KJVA",
            sourceVersification: "KJVA",
            sourceOrdinalStart: start,
            sourceOrdinalEnd: end
        )
    )
}

// MARK: - KJVA memorization integration contracts

extension ReaderProgressBridgeTests {
    /**
     Verifies bridge memorization mutations use Android's storage and event contracts.

     The shared Vue client expects native `markAsMemorized`, `addMemorizationTarget`,
     `removeMemorizationTarget`, and `unmarkMemorized` calls to emit
     `update_memorization_data` deltas in the current rendered ordinal domain while persistence is
     normalized to Android KJVA ordinals. The real KJV fixture gives the bridge an authoritative
     source module; a no-module placeholder must not reinterpret arbitrary rendered ordinals as
     KJVA merely to make a test mutation succeed.

     Failure means the bridge can persist native state without updating the open Vue document, or
     can continue writing iOS-only module-specific memorization rows.
     */
    func testMemorizationBridgePersistsKJVAGlobalRowsAndEmitsRenderedDeltas() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        let store = try XCTUnwrap(controller.memorizationProgressStore)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let renderedStart = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        let renderedEnd = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 2))
        let kjvaStart = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1)
        )
        let kjvaEnd = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 2)
        )

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "addMemorizationTarget",
                args: ["KJV", renderedStart, renderedEnd]
            ),
            .handled
        )
        XCTAssertEqual(
            store.snapshot().targetRanges,
            [MemorizationProgressRange(bookInitials: "", startOrdinal: kjvaStart, endOrdinal: kjvaEnd)]
        )
        XCTAssertEqual(
            try latestMemorizationPayload(from: recordedScripts())["addedTargets"] as? [Int],
            [renderedStart, renderedEnd]
        )

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "markAsMemorized",
                args: ["KJV", renderedStart, renderedStart]
            ),
            .handled
        )
        XCTAssertEqual(
            store.snapshot().memorizedRanges,
            [MemorizationProgressRange(bookInitials: "", startOrdinal: kjvaStart, endOrdinal: kjvaStart)]
        )
        XCTAssertEqual(
            try latestMemorizationPayload(from: recordedScripts())["addedMemorized"] as? [Int],
            [renderedStart]
        )

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "removeMemorizationTarget",
                args: ["KJV", renderedEnd, renderedEnd]
            ),
            .handled
        )
        XCTAssertEqual(store.snapshot().targetRanges, [
            MemorizationProgressRange(bookInitials: "", startOrdinal: kjvaStart, endOrdinal: kjvaStart),
        ])
        XCTAssertEqual(
            try latestMemorizationPayload(from: recordedScripts())["removedTargets"] as? [Int],
            [renderedEnd]
        )

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "unmarkMemorized",
                args: ["KJV", renderedStart, renderedStart]
            ),
            .handled
        )
        XCTAssertTrue(store.snapshot().memorizedRanges.isEmpty)
        XCTAssertEqual(
            try latestMemorizationPayload(from: recordedScripts())["removedMemorized"] as? [Int],
            [renderedStart]
        )
    }

    /**
     Verifies cross-chapter bridge targets persist Android's complete KJVA ordinal span.

     Android's `ProgressControl.addMemorizationTarget` converts the selected `VerseRange` to KJVA,
     stores one inclusive `kjvOrdinalStart...kjvOrdinalEnd` row, and posts UI updates from that
     same range. The KJVA span between Genesis 1:31 and Genesis 2:2 includes a chapter-intro
     ordinal that is not a concrete verse; Android includes that ordinal in `addedTargets`, so iOS
     must preserve it in both storage and the projected bridge event.

     Failure means iOS is preserving a visible-verse-only storage shape, which changes Android
     target totals, backup rows, duplicate-target detection, and removal behavior.
     */
    func testMemorizationBridgePersistsInclusiveKJVASpanAcrossChapterIntroOrdinals() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        let store = try XCTUnwrap(controller.memorizationProgressStore)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let renderedStart = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 31))
        let renderedEnd = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 2))
        let kjvaStart = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 31))
        let kjvaEnd = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 2, verse: 2))

        XCTAssertGreaterThan(kjvaEnd - kjvaStart, 2)
        XCTAssertEqual(
            bridge.dispatchMessage(method: "addMemorizationTarget", args: ["KJV", renderedStart, renderedEnd]),
            .handled
        )

        XCTAssertEqual(
            store.snapshot().targetRanges,
            [MemorizationProgressRange(bookInitials: "", startOrdinal: kjvaStart, endOrdinal: kjvaEnd)]
        )
        XCTAssertEqual(
            try latestMemorizationPayload(from: recordedScripts())["addedTargets"] as? [Int],
            Array(kjvaStart...kjvaEnd)
        )
    }

    /**
     Verifies normal Bible documents project global KJVA progress back to rendered ordinals.

     The bridge stores Android-compatible global KJVA rows, but Vue's Bible document payload still
     consumes ordinals in the currently rendered document domain. A real KJV fixture keeps the
     integration on Android's module-backed path instead of asking the fail-closed no-module
     placeholder to reinterpret synthetic ordinals as KJVA.

     Failure means a reload can highlight the wrong visible verses even though the bridge mutation
     itself wrote Android-parity persistence rows.
     */
    @MainActor
    func testBibleDocumentPayloadProjectsKJVAGlobalProgressToRenderedOrdinals() async throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let renderedStart = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        let renderedEnd = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 2))

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "addMemorizationTarget",
                args: ["KJV", renderedStart, renderedEnd]
            ),
            .handled
        )
        XCTAssertEqual(
            bridge.dispatchMessage(method: "markAsMemorized", args: ["KJV", renderedStart, renderedStart]),
            .handled
        )

        let publicationBoundary = recordedScripts().count
        controller.bridgeDidSetClientReady(bridge)

        let emissions = try await awaitBridgeEmission(
            from: recordedScripts,
            event: "add_documents",
            after: publicationBoundary
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["type"] as? String, "bible")
        XCTAssertEqual(document["targetOrdinals"] as? [Int], [renderedStart, renderedEnd])
        XCTAssertEqual(document["memorizedOrdinals"] as? [Int], [renderedStart])
    }

    /**
     Verifies Memorize document payloads reuse saved page-manager state.

     Android stores the full Vue state blob on `PageManager.jsState` through `saveState`, then passes
     that same state into the next Memorize fake document. This regression keeps iOS from
     synthesizing a fresh blur-mode-only state that loses the user's selected memorization mode or
     sibling document state keys.

     Failure means opening Memorize on iOS resets the shared Vue document state instead of restoring
     the Android `pageManager.jsState` contract.
     */
    @MainActor
    func testMemorizeDocumentUsesSavedPageManagerState() async throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let renderedOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )

        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.jsState = #"{"memorize":{"mode":"scramble","modeConfig":{"memorizeWordVisibility":"hidden","customLevel":7}},"otherDocument":{"selectedTab":"lexicon"}}"#
        self.retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
        controller.bridgeDidSetClientReady(bridge)

        let baselineScriptCount = recordedScripts().count
        XCTAssertEqual(
            bridge.dispatchMessage(method: "memorize", args: ["KJV", renderedOrdinal, renderedOrdinal]),
            .handled
        )

        let memorizeScripts = try await awaitBridgeEmission(
            from: recordedScripts,
            event: "add_documents",
            after: baselineScriptCount
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: memorizeScripts, event: "add_documents") as? [String: Any]
        )
        let state = try XCTUnwrap(document["state"] as? [String: Any])
        let memorizeState = try XCTUnwrap(state["memorize"] as? [String: Any])
        XCTAssertEqual(memorizeState["mode"] as? String, "scramble")
        XCTAssertEqual(
            (memorizeState["modeConfig"] as? [String: Any])?["memorizeWordVisibility"] as? String,
            "hidden"
        )
        XCTAssertEqual(
            (state["otherDocument"] as? [String: Any])?["selectedTab"] as? String,
            "lexicon"
        )
    }

    /**
     Verifies Memorize document payloads preserve Android's cross-chapter `VerseRange`.

     Android creates the fake Memorize document from the selected JSword `VerseRange`, so a
     selection spanning Genesis 1:31 through Genesis 2:2 yields one row for every range element,
     including the Genesis 2 introduction between the three normal verses, plus a cross-chapter
     title and OSIS range. This package test exercises the same contract through the reader
     controller.

     Failure means iOS is still using a same-chapter Memorize loader shape instead of the selected
     Android range contract.
     */
    @MainActor
    func testMemorizeDocumentPreservesCrossChapterAndroidRange() async throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let startOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 31))
        let endOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 2))

        controller.bridgeDidSetClientReady(bridge)
        let baselineScriptCount = recordedScripts().count
        XCTAssertEqual(
            bridge.dispatchMessage(method: "memorize", args: ["KJV", startOrdinal, endOrdinal]),
            .handled
        )

        let memorizeScripts = try await awaitBridgeEmission(
            from: recordedScripts,
            event: "add_documents",
            after: baselineScriptCount
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: memorizeScripts, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["type"] as? String, "memorize")
        XCTAssertEqual(document["title"] as? String, "Genesis 1:31-2:2")
        XCTAssertEqual(document["osisRef"] as? String, "Gen.1.31-Gen.2.2")
        XCTAssertEqual(document["startOrdinal"] as? Int, startOrdinal)
        XCTAssertEqual(document["endOrdinal"] as? Int, endOrdinal)
        XCTAssertEqual(document["targetOrdinals"] as? [Int], Array(startOrdinal...endOrdinal))

        let texts = try XCTUnwrap(document["texts"] as? [[String: String]])
        XCTAssertEqual(
            texts.map { $0["key"] },
            ["Gen.1.31", "Gen.2.0", "Gen.2.1", "Gen.2.2"]
        )
        let lastChapterVerse = try XCTUnwrap(texts.first { $0["key"] == "Gen.1.31" }?["text"])
        let introduction = try XCTUnwrap(texts.first { $0["key"] == "Gen.2.0" }?["text"])
        let firstChapterVerse = try XCTUnwrap(texts.first { $0["key"] == "Gen.2.1" }?["text"])
        let secondChapterVerse = try XCTUnwrap(texts.first { $0["key"] == "Gen.2.2" }?["text"])
        XCTAssertTrue(lastChapterVerse.contains("saw every thing"))
        XCTAssertEqual(introduction, "")
        XCTAssertTrue(firstChapterVerse.contains("heavens and the earth"))
        XCTAssertTrue(secondChapterVerse.contains("seventh day"))
        XCTAssertFalse(texts.compactMap { $0["text"] }.contains { $0.contains("<H") })
    }

    /**
     Verifies Reading Progress memorization rows open practice from global KJVA ordinals.

     Android's Reading Progress list is not scoped to the currently visible book. A memorized
     passage or target row may point to any KJVA verse range, and tapping it opens Memorize for that
     exact range after converting it to the default Bible module's versification. The native iOS
     sheet therefore must not route row taps through the current reader book/chapter ordinal
     resolver or relabel the rendered module range as KJVA.

     Failure means the Reading Progress memorization list is preserving an iOS-only current-book
     structure instead of using Android's global KJVA progress domain.
     */
    @MainActor
    func testReadingProgressMemorizationRowOpensKJVARangeOutsideCurrentBook() async throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        let window = Window()
        let pageManager = PageManager(id: window.id)
        self.retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window

        let startOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Exod", chapter: 1, verse: 22)
        )
        let endOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Exod", chapter: 2, verse: 1)
        )
        XCTAssertEqual(startOrdinal, 1_609)
        XCTAssertEqual(endOrdinal, 1_611)
        try XCTUnwrap(controller.memorizationProgressStore)
            .addMemorizationTarget(
                try readerProgressVerifiedKJVARange(start: startOrdinal, end: endOrdinal)
            )

        controller.bridgeDidSetClientReady(bridge)
        let baselineScriptCount = recordedScripts().count

        XCTAssertTrue(
            controller.openMemorizeKJVARange(startOrdinal: startOrdinal, endOrdinal: endOrdinal)
        )

        let memorizeScripts = try await awaitBridgeEmission(
            from: recordedScripts,
            event: "add_documents",
            after: baselineScriptCount
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: memorizeScripts, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["type"] as? String, "memorize")
        XCTAssertEqual(document["title"] as? String, "Exodus 1:22-2:1")
        XCTAssertEqual(document["osisRef"] as? String, "Exod.1.22-Exod.2.1")
        XCTAssertEqual(document["v11n"] as? String, "KJV")
        XCTAssertEqual(document["startOrdinal"] as? Int, startOrdinal)
        XCTAssertEqual(document["endOrdinal"] as? Int, endOrdinal)
        // Android expands every ordinal covered by a MemorizationTarget when it builds
        // targetOrdinals. KJVA places the Exodus 2 chapter introduction between Exodus 1:22 and
        // Exodus 2:1, so the independently pinned inclusive integer range contains 1,610 even
        // though the public iOS reference converter does not accept chapter-introduction verse 0.
        XCTAssertEqual(
            document["targetOrdinals"] as? [Int],
            [1_609, 1_610, 1_611]
        )

        let texts = try XCTUnwrap(document["texts"] as? [[String: String]])
        XCTAssertEqual(
            texts.map { $0["key"] },
            ["Exod.1.22", "Exod.2.0", "Exod.2.1"]
        )
    }
}
