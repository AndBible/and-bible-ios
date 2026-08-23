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

     The fixture reuses deterministic KJV bytes under a Vulgate canon descriptor, selects Vulgate
     Psalm 10:1, and dispatches the same bridge mutation as Vue. JSword maps that source verse to
     the KJVA Psalm 11 superscription. Android then converts the stored KJVA event ordinal back to
     Vulgate before notifying the document.

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
        try seedBibleAliasModule(
            named: "VulgTest",
            description: "Vulgate projection fixture",
            versification: "Vulg",
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
     open document's versification. A Vulgate-configured SWORD module rejects the intermediate
     Genesis 2:0 content lookup, but the Vulgate canon still owns that intro-inclusive ordinal. This
     fixture crosses Genesis 1:31 through 2:2 and proves iOS round-trips the verse-zero reference
     through Vulgate's canonical index instead of emitting sentinel `0` or dropping the entry.

     Failure means divergent modules no longer receive Android-equivalent memorization deltas for
     cross-chapter target ranges.
     */
    @MainActor
    func testBridgeMemorizationEmitsCanonicalIntroOrdinalForDivergentTargetCanon() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "VulgTest",
            description: "Vulgate intro projection fixture",
            versification: "Vulg",
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
    func testReaderMemorizeBridgeEmitsAndroidStyleDocumentPayload() throws {
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

        let memorizeScripts = Array(recordedScripts().dropFirst(initialScriptCount))
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
    func testReaderMemorizeBridgeUsesAndroidCommentaryFakeDocumentIdentity() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let settingsStore = try makeInMemorySettingsStore()
        controller.settingsStore = settingsStore
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))

        controller.bridgeDidSetClientReady(bridge)
        controller.bridge(
            bridge,
            memorize: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
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
    func testReaderMemorizeBridgeUsesLinksWindowRoutingCallbackWhenAvailable() throws {
        let (sourceBridge, sourceScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let sourceController = BibleReaderController(bridge: sourceBridge, swordManagerOverride: manager)
        sourceController.settingsStore = try makeInMemorySettingsStore()
        var routedEmission: MemorizeDocumentEmission?
        sourceController.onOpenMemorizeDocumentInLinksWindow = { emission in
            routedEmission = emission
        }
        let module = try XCTUnwrap(manager.module(named: sourceController.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))

        sourceController.bridgeDidSetClientReady(sourceBridge)
        let initialSourceScriptCount = sourceScripts().count
        let initialSourceRenderedState = sourceController.renderedContentState

        sourceController.bridge(
            sourceBridge,
            memorize: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        )

        let sourceMemorizeScripts = Array(sourceScripts().dropFirst(initialSourceScriptCount))
        XCTAssertFalse(sourceMemorizeScripts.contains { $0.contains("add_documents") })
        XCTAssertEqual(sourceController.currentCategory, .bible)
        XCTAssertEqual(sourceController.renderedContentState, initialSourceRenderedState)

        let emission = try XCTUnwrap(routedEmission)
        XCTAssertEqual(emission.bookInitials, "KJV")
        XCTAssertEqual(emission.startOrdinal, ordinal)
        XCTAssertEqual(emission.endOrdinal, ordinal)

        let (targetBridge, targetScripts) = makeRecordingBridge()
        let targetController = BibleReaderController(bridge: targetBridge, swordManagerOverride: manager)
        let targetSettingsStore = try makeInMemorySettingsStore()
        targetController.settingsStore = targetSettingsStore
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        targetController.activeWindow = window
        targetController.bridgeDidSetClientReady(targetBridge)
        let initialTargetScriptCount = targetScripts().count

        targetController.renderMemorizeDocument(emission)

        let targetMemorizeScripts = Array(targetScripts().dropFirst(initialTargetScriptCount))
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
     complete KJVA span, including its addressable chapter introduction. The iOS loader must not
     collapse Memorize practice to the current chapter, but its Vue payload may contain only positive
     ordinals for verses rendered by the SWORD document. This setup selects Genesis 1:31 through
     Genesis 2:2, which crosses exactly one non-renderable iOS chapter-introduction ordinal.

     Failure means iOS has preserved an artificial same-chapter document structure instead of
     matching Android's Memorize range behavior.
     */
    @MainActor
    func testReaderMemorizeBridgeEmitsCrossChapterAndroidRangePayload() throws {
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

        let memorizeScripts = Array(recordedScripts().dropFirst(initialScriptCount))
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
        XCTAssertEqual(texts.map { $0["key"] }, ["Gen.1.31", "Gen.2.1", "Gen.2.2"])
        XCTAssertTrue(texts[0]["text"]?.contains("saw every thing") == true)
        XCTAssertTrue(texts[1]["text"]?.contains("heavens and the earth") == true)
        XCTAssertTrue(texts[2]["text"]?.contains("seventh day") == true)
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
    func testReaderMemorizeBridgeEmitsCanonicalGreekStrongText() throws {
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

        let memorizeScripts = Array(recordedScripts().dropFirst(initialScriptCount))
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
