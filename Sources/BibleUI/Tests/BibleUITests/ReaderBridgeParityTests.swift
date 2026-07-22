import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 Adversarial contract tests for reader payload, routing, and source-domain parity.

 The fixtures deliberately separate active-pane and event-source modules so a regression that
 reintroduces active-module inference cannot pass by coincidence.
 */
final class ReaderBridgeParityTests: BibleUISwordFixtureTestCase {
    /**
     Verifies a real non-KJVA Bible payload preserves its source module metadata at both levels.

     - Side effects: Encodes and parses one in-memory bridge document.
     - Failure modes: Fails when v11n, identity, language, direction, or ordinal fields are omitted,
       hard-coded, or assigned different meanings between the document and fragment.
     */
    func testNonKJVABiblePayloadUsesModuleSourceMetadata() throws {
        let factory = BibleReaderDocumentPayloadFactory(
            activeModuleName: "KJV",
            hasStrongs: false,
            bookmarkPayload: { _ in XCTFail("No bookmarks expected"); fatalError() },
            chapterOrdinalRange: { _, _, _ in (start: 900, end: 920, verseCount: 20) },
            kjvBookOrdinal: { _ in nil },
            chapterReadCount: { _, _ in nil },
            memorizedOrdinals: { _, _, _ in [] },
            targetOrdinals: { _, _, _ in [] }
        )
        let json = try XCTUnwrap(factory.documentJSON(
            BibleReaderDocumentPayloadRequest(
                osisBookId: "Ps",
                bookName: "Psalms",
                chapter: 10,
                verseCount: 20,
                isNewTestament: false,
                xml: "<div/>",
                bookInitials: "VulgTest",
                moduleName: "Vulgate fixture",
                moduleAbbreviation: "Vulg",
                versificationName: "Vulg",
                language: "la",
                direction: "ltr",
                sourceHasStrongs: false
            )
        ))
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(document["osisFragment"] as? [String: Any])

        XCTAssertEqual(document["bookInitials"] as? String, "VulgTest")
        XCTAssertEqual(document["bookName"] as? String, "Vulgate fixture")
        XCTAssertEqual(document["bookAbbreviation"] as? String, "Vulg")
        XCTAssertEqual(document["v11n"] as? String, "Vulg")
        XCTAssertEqual(document["ordinalRange"] as? [Int], [900, 920])
        XCTAssertEqual(fragment["key"] as? String, "VulgTest--Ps.10")
        XCTAssertEqual(fragment["bookInitials"] as? String, "VulgTest")
        XCTAssertEqual(fragment["v11n"] as? String, "Vulg")
        XCTAssertEqual(fragment["language"] as? String, "la")
        XCTAssertEqual(fragment["direction"] as? String, "ltr")
        XCTAssertEqual(fragment["ordinalRange"] as? [Int], [900, 920])
    }

    /**
     Verifies generated no-module Bible content is genuinely KJVA rather than merely labeled KJVA.

     The placeholder XML, document range, reverse lookup, and setup anchor must all use the same
     intro-inclusive JSword domain. This prevents a synthetic Genesis verse ordinal such as `1`
     from being relabeled as KJVA even though KJVA Genesis 1:1 is ordinal `4`.

     - Side effects: Loads generated Genesis content through a recording bridge with SWORD disabled.
     - Failure modes: Fails when any payload or navigation surface reintroduces compatibility
       ordinal math under a KJVA `v11n` label.
     */
    @MainActor
    func testNoModuleBiblePayloadUsesOneGenuineKJVADomain() throws {
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        let expectedStart = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1)
        )
        let expectedEnd = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 31)
        )

        controller.bridgeDidSetClientReady(bridge)

        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: scripts(), event: "add_documents") as? [String: Any]
        )
        let fragment = try XCTUnwrap(document["osisFragment"] as? [String: Any])
        let xml = try XCTUnwrap(fragment["xml"] as? String)
        XCTAssertEqual(document["v11n"] as? String, JSwordKJVAVersification.name)
        XCTAssertEqual(document["ordinalRange"] as? [Int], [expectedStart, expectedEnd])
        XCTAssertEqual(fragment["v11n"] as? String, JSwordKJVAVersification.name)
        XCTAssertEqual(fragment["ordinalRange"] as? [Int], [expectedStart, expectedEnd])
        XCTAssertTrue(
            xml.contains(
                "<verse osisID=\"Gen.1.1\" verseOrdinal=\"\(expectedStart)\">"
            )
        )

        XCTAssertEqual(
            controller.synchronizedVerseReference(ordinal: expectedStart),
            VerseKeyReference(
                osisBookId: "Gen",
                chapter: 1,
                verse: 1,
                ordinal: expectedStart
            )
        )

        let baseline = scripts().count
        XCTAssertTrue(controller.navigateToRef("Gen.1.2"))
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(
                from: Array(scripts().dropFirst(baseline)),
                event: "setup_content"
            ) as? [String: Any]
        )
        let verseTwo = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 2)
        )
        XCTAssertEqual(setup["jumpToAnchor"] as? Int, verseTwo)
        XCTAssertEqual(setup["ordinalStart"] as? Int, verseTwo)
        XCTAssertEqual(setup["ordinalEnd"] as? Int, verseTwo)
        XCTAssertEqual(setup["osisRef"] as? String, "Gen.1")
    }

    /**
     Verifies Compare resolves the selected fragment rather than the active KJV pane.

     - Side effects: Builds temporary KJV/Vulgate SWORD modules and waits for the controller's
       real background Compare builder before observing its main-queue payload emission.
     - Failure modes: Fails if the selected Vulgate ordinals are read as KJV, if target conversion
       is skipped, or if either fragment advertises the wrong source versification.
     - Determinism: An injected wrapper fulfills only after the production Compare builder returns,
       so simulator load cannot turn the assertion into a two-second scheduling race.
     */
    @MainActor
    func testCompareEventUsesSelectedVulgateFragmentWhileActivePaneIsKJV() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "VulgTest",
            description: "Vulgate compare fixture",
            versification: "Vulg",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let source = try XCTUnwrap(
            manager.module(named: "VulgTest"),
            "Installed modules: \(manager.installedModules().map(\.name))"
        )
        let target = try XCTUnwrap(manager.module(named: "KJV"))
        let start = try XCTUnwrap(source.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        let end = try XCTUnwrap(source.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 2))
        let (bridge, scripts) = makeRecordingBridge()
        let compareBuildFinished = expectation(description: "Production Compare builder finished")
        let resultLock = NSLock()
        var builtDocumentJSON: String?
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            compareDocumentBuildOperation: { request in
                let documentJSON = BibleReaderCompareDocumentBuilder.buildDocumentJSON(request)
                resultLock.lock()
                builtDocumentJSON = documentJSON
                resultLock.unlock()
                compareBuildFinished.fulfill()
                return documentJSON
            }
        )
        XCTAssertEqual(controller.activeModuleName, "KJV")

        controller.bridge(bridge, compareVerses: "VulgTest", startOrdinal: start, endOrdinal: end)

        wait(for: [compareBuildFinished], timeout: 10)
        resultLock.lock()
        let didBuildDocument = builtDocumentJSON != nil
        resultLock.unlock()
        XCTAssertTrue(didBuildDocument, "Expected the production Compare builder to return a document")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                scripts().contains(where: { $0.contains("emit('add_documents'") })
            },
            "Expected the completed Compare document to reach the bridge"
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: scripts(), event: "add_documents") as? [String: Any]
        )
        let fragments = try XCTUnwrap(document["osisFragments"] as? [[String: Any]])
        let sourceFragment = try XCTUnwrap(fragments.first)
        let targetFragment = try XCTUnwrap(fragments.first { $0["bookInitials"] as? String == "KJV" })
        let targetStart = try XCTUnwrap(target.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        let targetEnd = try XCTUnwrap(target.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 2))
        let sourceBookName = try XCTUnwrap(
            source.getBookList().first(where: { $0.osisId == "Gen" })?.name
        )

        XCTAssertEqual(sourceFragment["bookInitials"] as? String, "VulgTest")
        XCTAssertEqual(sourceFragment["v11n"] as? String, "Vulg")
        XCTAssertEqual(sourceFragment["keyName"] as? String, "\(sourceBookName) 1:1-2")
        XCTAssertEqual(sourceFragment["ordinalRange"] as? [Int], [start, end])
        XCTAssertEqual(targetFragment["v11n"] as? String, "KJV")
        XCTAssertEqual(targetFragment["ordinalRange"] as? [Int], [targetStart, targetEnd])
    }

    /**
     Verifies `my-notes://` preserves its Vulgate domain until conversion to KJVA My Notes rows.

     - Side effects: Loads a temporary reader and emits a My Notes document through the bridge.
     - Failure modes: Fails if the route drops v11n, passes the Vulgate ordinal through unchanged,
       or silently substitutes active KJV ordinal semantics.
     */
    @MainActor
    func testMyNotesRouteConvertsDeclaredVulgateOrdinalToKJVA() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "VulgTest",
            description: "Vulgate My Notes fixture",
            versification: "Vulg",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let vulg = try XCTUnwrap(manager.module(named: "VulgTest"))
        let sourceOrdinal = try XCTUnwrap(
            vulg.verseOrdinal(osisBookId: "Ps", chapter: 10, verse: 1)
        )
        let expectedKJVA = try XCTUnwrap(
            VersificationMapper.kjvaOrdinal(
                osisBookId: "Ps",
                chapter: 10,
                verse: 1,
                sourceVersification: "Vulg"
            )
        )
        XCTAssertNotEqual(sourceOrdinal, expectedKJVA)

        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        controller.navigateTo(book: "Psalms", chapter: 12, verse: 1)
        let initialScriptCount = scripts().count

        controller.bridge(
            bridge,
            openExternalLink: "my-notes://?v11n=Vulg&ordinal=\(sourceOrdinal)"
        )

        let newScripts = Array(scripts().dropFirst(initialScriptCount))
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: newScripts, event: "setup_content") as? [String: Any]
        )
        let targetReference = try XCTUnwrap(
            JSwordKJVAVersification.referenceIncludingIntroductions(ordinal: expectedKJVA)
        )
        let targetBookName = try XCTUnwrap(
            JSwordKJVAVersification.longBookName(osisId: targetReference.osisId)
        )
        let targetVerseCount = try XCTUnwrap(
            JSwordKJVAVersification.verseCount(
                osisId: targetReference.osisId,
                chapter: targetReference.chapter
            )
        )
        let targetRangeStart = try XCTUnwrap(
            JSwordKJVAVersification.chapterIntroOrdinal(
                osisId: targetReference.osisId,
                chapter: targetReference.chapter
            )
        )
        let targetRangeEnd = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(
                osisId: targetReference.osisId,
                chapter: targetReference.chapter,
                verse: targetVerseCount
            )
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: newScripts, event: "add_documents") as? [String: Any]
        )

        XCTAssertEqual(setup["jumpToOrdinal"] as? Int, expectedKJVA)
        assertAndroidSetupPayload(setup)
        XCTAssertEqual(
            document["id"] as? String,
            "ordinal-\(targetRangeStart)-\(targetRangeEnd)"
        )
        XCTAssertEqual(
            document["verseRange"] as? String,
            "\(targetBookName) \(targetReference.chapter)"
        )
        XCTAssertEqual(document["ordinalRange"] as? [Int], [targetRangeStart, targetRangeEnd])
        XCTAssertNotEqual(document["verseRange"] as? String, "Psalms 12")
    }

    /**
     Verifies My Notes resolves a declared canon without requiring a matching installed module.

     Android constructs `Verse(v11n, ordinal)` from the versification registry. Removing the source
     Bible must therefore not make an otherwise valid bookmark link depend on the active KJV pane.

     - Side effects: Loads the package KJV fixture and emits one synthetic My Notes document.
     - Failure modes: Fails when routing searches installed modules, reinterprets the Vulgate index
       as KJV, or silently falls back to the active chapter.
     */
    @MainActor
    func testMyNotesRouteUsesDeclaredCanonWhenSourceModuleIsNotInstalled() throws {
        let sourceReference = SwordVersification.Reference(
            osisBookId: "Ps",
            chapter: 10,
            verse: 1
        )
        let sourceOrdinal = try XCTUnwrap(
            SwordVersification.referenceIndex(for: sourceReference, versification: "Vulg")
        )
        let expectedKJVA = try XCTUnwrap(
            VersificationMapper.kjvaOrdinal(
                osisBookId: sourceReference.osisBookId,
                chapter: sourceReference.chapter,
                verse: sourceReference.verse,
                sourceVersification: "Vulg"
            )
        )
        let targetReference = try XCTUnwrap(
            JSwordKJVAVersification.referenceIncludingIntroductions(ordinal: expectedKJVA)
        )
        let targetRangeStart = try XCTUnwrap(
            JSwordKJVAVersification.chapterIntroOrdinal(
                osisId: targetReference.osisId,
                chapter: targetReference.chapter
            )
        )
        let targetVerseCount = try XCTUnwrap(
            JSwordKJVAVersification.verseCount(
                osisId: targetReference.osisId,
                chapter: targetReference.chapter
            )
        )
        let targetRangeEnd = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(
                osisId: targetReference.osisId,
                chapter: targetReference.chapter,
                verse: targetVerseCount
            )
        )
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertNil(manager.module(named: "VulgTest"))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        controller.navigateTo(book: "Psalms", chapter: 12, verse: 1)
        let baseline = scripts().count

        controller.bridge(
            bridge,
            openExternalLink: "my-notes://?v11n=Vulg&ordinal=\(sourceOrdinal)"
        )

        let emissions = Array(scripts().dropFirst(baseline))
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(document["id"] as? String, "ordinal-\(targetRangeStart)-\(targetRangeEnd)")
        XCTAssertEqual(document["ordinalRange"] as? [Int], [targetRangeStart, targetRangeEnd])
        XCTAssertEqual(setup["jumpToOrdinal"] as? Int, expectedKJVA)
        assertAndroidSetupPayload(setup)
    }

    /**
     Verifies synthetic My Notes range names follow Android's JSword application locale.

     - Setup: Resolves Genesis through the pinned German `BibleNames` resource used by JSword.
     - Expected result: The localized long name is emitted instead of the English table fallback.
     - Failure modes: Fails when synthetic KJVA payloads ignore Android's locale provider contract.
     */
    func testMyNotesKJVARangeUsesLocalizedJSwordBookName() {
        XCTAssertEqual(
            JSwordKJVAVersification.localizedLongBookName(
                osisId: "Gen",
                locale: Locale(identifier: "de")
            ),
            "1. Mose"
        )
    }

    /**
     Verifies typed setup payloads encode every Android highlight field, including explicit nulls.

     - Side effects: Encodes and parses one in-memory setup event value.
     - Failure modes: Fails when optional keys are omitted or anchor-highlight metadata changes type.
     */
    func testSetupContentPayloadEncodesAndroidAnchorHighlightContract() throws {
        let data = try bridgeEncoder.encode(ReaderSetupContentPayload(
            jumpToAnchor: 77,
            ordinalStart: 77,
            ordinalEnd: 79,
            highlight: true,
            bookInitials: "NASB",
            osisRef: "John.3"
        ))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        assertAndroidSetupPayload(payload)
        XCTAssertTrue(payload["jumpToOrdinal"] is NSNull)
        XCTAssertEqual(payload["jumpToAnchor"] as? Int, 77)
        XCTAssertTrue(payload["jumpToId"] is NSNull)
        XCTAssertEqual(payload["ordinalStart"] as? Int, 77)
        XCTAssertEqual(payload["ordinalEnd"] as? Int, 79)
        XCTAssertEqual(payload["highlight"] as? Bool, true)
        XCTAssertEqual(payload["bookInitials"] as? String, "NASB")
        XCTAssertEqual(payload["osisRef"] as? String, "John.3")
    }

    /**
     Verifies a single Android OSIS range remains the next Bible document's complete anchor range.

     Android routes a one-range `Passage` as a Bible document and carries its full source range into
     `setup_content`. iOS must convert every endpoint into the active module before navigating, then
     expose the same range in both document metadata and the scoped setup highlight.

     - Side effects: Navigates a temporary KJV reader through one external range link.
     - Failure modes: First-verse-only navigation collapses the range, while source-ordinal reuse
       reports values outside the active module's domain.
     */
    @MainActor
    func testSingleOsisRangePreservesCompleteSetupAnchor() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let start = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        let end = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 3))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count

        controller.bridge(
            bridge,
            openExternalLink: "osis://?osis=Gen.1.1-Gen.1.3&v11n=KJV"
        )

        let emissions = Array(scripts().dropFirst(baseline))
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "setup_content") as? [String: Any]
        )

        XCTAssertEqual(document["originalOrdinalRange"] as? [Int], [start, end])
        assertAndroidSetupPayload(setup)
        XCTAssertEqual(setup["jumpToAnchor"] as? Int, start)
        XCTAssertEqual(setup["ordinalStart"] as? Int, start)
        XCTAssertEqual(setup["ordinalEnd"] as? Int, end)
        XCTAssertEqual(setup["highlight"] as? Bool, true)
        XCTAssertEqual(setup["bookInitials"] as? String, "KJV")
        XCTAssertEqual(setup["osisRef"] as? String, "Gen.1")
    }

    /**
     Verifies `force-doc` uses Android `Uri.getBooleanQueryParameter` value semantics.

     - Side effects: Classifies seven in-memory OSIS links.
     - Failure modes: Presence-only parsing makes `false` and `0` incorrectly force a document;
       treating bare or non-false values as false diverges in the opposite direction.
     */
    func testForceDocumentQueryMatchesAndroidBooleanParsing() {
        let router = BibleReaderExternalLinkRouter()
        let cases: [(String, Bool)] = [
            ("", false),
            ("&force-doc", true),
            ("&force-doc=true", true),
            ("&force-doc=1", true),
            ("&force-doc=FALSE", false),
            ("&force-doc=false", false),
            ("&force-doc=0", false),
            ("&force-doc=unexpected", true),
        ]

        for (suffix, expected) in cases {
            let route = router.route(
                for: "osis://?osis=Gen.1.1&v11n=KJV&doc=KJV\(suffix)"
            )
            guard case .osisReferences(_, _, _, let forceDocument) = route else {
                XCTFail("Expected OSIS route for suffix \(suffix)")
                continue
            }
            XCTAssertEqual(forceDocument, expected, "Unexpected result for suffix \(suffix)")
        }
    }

    /**
     Verifies ordinary Multi JSON distinguishes explicit null content type from absent state.

     Android always serializes `contentType`, using null for ordinary references, while an undefined
     JavaScript state is omitted. The same parsed field contract must survive both direct encoding and
     the controller's transient setup emission.

     - Side effects: Encodes one in-memory Multi payload and emits it through a reader controller.
     - Failure modes: Optional synthesis can omit both keys or serialize absent state as null.
     */
    @MainActor
    func testOrdinaryMultiEncodesNullContentTypeOmitsStateAndUsesTypedSetup() throws {
        let fragment = OsisFragment(
            xml: "<div/>",
            key: "KJV--Gen.1.1",
            keyName: "Genesis 1:1",
            v11n: "KJV",
            bookInitials: "KJV",
            bookAbbreviation: "KJV",
            osisRef: "Gen.1.1",
            ordinalRange: [4, 4]
        )
        let payload = MultiFragmentDocumentPayload(
            id: "ordinary-multi",
            type: "multi",
            osisFragments: [fragment],
            compare: false,
            contentType: nil,
            state: nil
        )
        let jsonData = try bridgeEncoder.encode(payload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        )

        XCTAssertTrue(object["contentType"] is NSNull)
        XCTAssertFalse(object.keys.contains("state"))

        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge)
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count
        controller.loadMultiReferenceDocument(String(decoding: jsonData, as: UTF8.self))
        let emitted = Array(scripts().dropFirst(baseline))
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: emitted, event: "setup_content") as? [String: Any]
        )
        assertAndroidSetupPayload(setup)
    }

    /**
     Verifies a live Vulgate range remains source-owned while KJV is the active pane.

     The fixture aliases deterministic Bible bytes under Vulgate metadata. The builder receives an
     ordered Vulgate Psalm range targeted back to that source module; the active KJV pane must not
     rename, reinterpret, collapse, or reorder it.

     - Side effects: Creates temporary SWORD aliases and reads two exact verse entries.
     - Failure modes: Active-pane inference changes the key/v11n/ordinals, while single-verse
       shortcuts lose the range or its XML order.
     */
    func testLiveMultiPreservesVulgateRangeIdentityAndOrderWithActiveKJV() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "VulgTest",
            description: "Vulgate live Multi fixture",
            versification: "Vulg",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let kjv = try XCTUnwrap(manager.module(named: "KJV"))
        let vulg = try XCTUnwrap(manager.module(named: "VulgTest"))
        let coordinates = [
            OsisVerseCoordinate(osisBookId: "Ps", chapter: 10, verse: 1),
            OsisVerseCoordinate(osisBookId: "Ps", chapter: 10, verse: 2),
        ]
        let ref = OsisRef(
            book: "Psalms",
            chapter: 10,
            verse: 1,
            osisId: "Ps",
            sourceVersification: "Vulg",
            targetBookInitials: "VulgTest",
            sourceVerses: coordinates
        )
        let builder = BibleReaderMultiReferenceDocumentBuilder(
            swordManager: manager,
            activeModule: kjv,
            activeModuleName: "KJV"
        )

        let document = try parsedJSONObject(try XCTUnwrap(builder.buildDocumentJSON(refs: [ref])))
        let fragments = try XCTUnwrap(document["osisFragments"] as? [[String: Any]])
        let sourceFragment = try XCTUnwrap(fragments.first)
        let start = try XCTUnwrap(vulg.verseOrdinal(osisBookId: "Ps", chapter: 10, verse: 1))
        let end = try XCTUnwrap(vulg.verseOrdinal(osisBookId: "Ps", chapter: 10, verse: 2))
        let xml = try XCTUnwrap(sourceFragment["xml"] as? String)

        XCTAssertEqual(sourceFragment["bookInitials"] as? String, "VulgTest")
        XCTAssertEqual(sourceFragment["v11n"] as? String, "Vulg")
        XCTAssertEqual(sourceFragment["osisRef"] as? String, "Ps.10.1-Ps.10.2")
        XCTAssertEqual(sourceFragment["ordinalRange"] as? [Int], [start, end])
        XCTAssertLessThan(
            try XCTUnwrap(xml.range(of: "osisID=\"Ps.10.1\"")?.lowerBound),
            try XCTUnwrap(xml.range(of: "osisID=\"Ps.10.2\"")?.lowerBound)
        )
    }

    /**
     Verifies one live Multi payload preserves independently owned Vulgate and LXX passages.

     Each Android `BookAndKey` child carries its own document and key domain. A mixed payload must
     therefore resolve each range against its named source module, retain child order, and avoid
     converting either child through the active KJV pane.

     - Side effects: Creates two temporary source-canon aliases and reads both ranges.
     - Failure modes: A shared v11n, active-module fallback, or aggregate reorder changes fragment
       identity, ordinals, or order.
     */
    func testLiveMultiPreservesMixedSourceModulesRangesAndOrder() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "VulgTest",
            description: "Vulgate mixed Multi fixture",
            versification: "Vulg",
            in: modulePath
        )
        try seedBibleAliasModule(
            named: "LXXTest",
            description: "LXX mixed Multi fixture",
            versification: "LXX",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let activeKJV = try XCTUnwrap(manager.module(named: "KJV"))
        let vulg = try XCTUnwrap(manager.module(named: "VulgTest"))
        let lxx = try XCTUnwrap(manager.module(named: "LXXTest"))
        let references = [
            OsisRef(
                book: "Tobit",
                chapter: 1,
                verse: 1,
                osisId: "Tob",
                sourceVersification: "Vulg",
                targetBookInitials: "VulgTest",
                sourceVerses: [
                    OsisVerseCoordinate(osisBookId: "Tob", chapter: 1, verse: 1),
                    OsisVerseCoordinate(osisBookId: "Tob", chapter: 1, verse: 2),
                ]
            ),
            OsisRef(
                book: "1 Esdras",
                chapter: 1,
                verse: 1,
                osisId: "1Esd",
                sourceVersification: "LXX",
                targetBookInitials: "LXXTest",
                sourceVerses: [
                    OsisVerseCoordinate(osisBookId: "1Esd", chapter: 1, verse: 1),
                    OsisVerseCoordinate(osisBookId: "1Esd", chapter: 1, verse: 2),
                ]
            ),
        ]
        let builder = BibleReaderMultiReferenceDocumentBuilder(
            swordManager: manager,
            activeModule: activeKJV,
            activeModuleName: "KJV"
        )

        let document = try parsedJSONObject(try XCTUnwrap(builder.buildDocumentJSON(refs: references)))
        let fragments = try XCTUnwrap(document["osisFragments"] as? [[String: Any]])
        let vulgStart = try XCTUnwrap(vulg.verseOrdinal(osisBookId: "Tob", chapter: 1, verse: 1))
        let vulgEnd = try XCTUnwrap(vulg.verseOrdinal(osisBookId: "Tob", chapter: 1, verse: 2))
        let lxxStart = try XCTUnwrap(lxx.verseOrdinal(osisBookId: "1Esd", chapter: 1, verse: 1))
        let lxxEnd = try XCTUnwrap(lxx.verseOrdinal(osisBookId: "1Esd", chapter: 1, verse: 2))

        XCTAssertEqual(fragments.map { $0["bookInitials"] as? String }, ["VulgTest", "LXXTest"])
        XCTAssertEqual(fragments.map { $0["v11n"] as? String }, ["Vulg", "LXX"])
        XCTAssertEqual(
            fragments.map { $0["osisRef"] as? String },
            ["Tob.1.1-Tob.1.2", "1Esd.1.1-1Esd.1.2"]
        )
        XCTAssertEqual(fragments[0]["ordinalRange"] as? [Int], [vulgStart, vulgEnd])
        XCTAssertEqual(fragments[1]["ordinalRange"] as? [Int], [lxxStart, lxxEnd])
    }

    /**
     Verifies restored Multi children retain Vulgate/LXX source-only books, ranges, and order.

     Android restores each persisted `BookAndKey` through the child module's own
     `PassageKeyFactory`. The active KJV pane is intentionally unable to name Tobit or 1 Esdras, so
     any active-catalog inference drops these children and fails the test.

     - Side effects: Creates Vulgate/LXX aliases and reads source-only ranges from temporary SWORD
       modules.
     - Failure modes: Single-verse parsing, KJV book lookup, source-module loss, or child reordering
       changes the parsed fragment list or produces no restored payload.
     */
    func testRestoredMultiPreservesVulgateAndLXXSourceOnlyRangesWithActiveKJV() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "VulgTest",
            description: "Vulgate restored Multi fixture",
            versification: "Vulg",
            in: modulePath
        )
        try seedBibleAliasModule(
            named: "LXXTest",
            description: "LXX restored Multi fixture",
            versification: "LXX",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let activeKJV = try XCTUnwrap(manager.module(named: "KJV"))
        let vulg = try XCTUnwrap(manager.module(named: "VulgTest"))
        let lxx = try XCTUnwrap(manager.module(named: "LXXTest"))
        let vulgReferences = try XCTUnwrap(
            BibleReaderMultiReferenceDocumentBuilder.concreteReferences(
                parsedKeys: vulg.parseKeyList("Tob.1.1-Tob.1.2"),
                module: vulg
            )
        )
        let lxxReferences = try XCTUnwrap(
            BibleReaderMultiReferenceDocumentBuilder.concreteReferences(
                parsedKeys: lxx.parseKeyList("1Esd.1.1-1Esd.1.2"),
                module: lxx
            )
        )

        XCTAssertEqual(vulgReferences.map(\.osisBookId), ["Tob", "Tob"])
        XCTAssertEqual(vulgReferences.map(\.verse), [1, 2])
        XCTAssertEqual(lxxReferences.map(\.osisBookId), ["1Esd", "1Esd"])
        XCTAssertEqual(lxxReferences.map(\.verse), [1, 2])

        let pageKey = "VulgTest:Tob.1.1-Tob.1.2||LXXTest:1Esd.1.1-1Esd.1.2"
        let request = try XCTUnwrap(
            BibleReaderRestoredMultiDocumentBuilder(
                swordManager: manager,
                activeModule: activeKJV
            ).build(pageKey: pageKey)
        )
        let document = try parsedJSONObject(request.documentJSON)
        let fragments = try XCTUnwrap(document["osisFragments"] as? [[String: Any]])

        XCTAssertEqual(request.pageKey, pageKey)
        XCTAssertEqual(fragments.count, 2)
        XCTAssertEqual(fragments.map { $0["bookInitials"] as? String }, ["VulgTest", "LXXTest"])
        XCTAssertEqual(fragments.map { $0["v11n"] as? String }, ["Vulg", "LXX"])
        XCTAssertEqual(
            fragments.map { $0["osisRef"] as? String },
            ["Tob.1.1-Tob.1.2", "1Esd.1.1-1Esd.1.2"]
        )
        XCTAssertTrue(document["contentType"] is NSNull)
        XCTAssertFalse(document.keys.contains("state"))
        for (fragment, expectedRefs) in zip(
            fragments,
            [["Tob.1.1", "Tob.1.2"], ["1Esd.1.1", "1Esd.1.2"]]
        ) {
            let xml = try XCTUnwrap(fragment["xml"] as? String)
            XCTAssertLessThan(
                try XCTUnwrap(xml.range(of: "osisID=\"\(expectedRefs[0])\"")?.lowerBound),
                try XCTUnwrap(xml.range(of: "osisID=\"\(expectedRefs[1])\"")?.lowerBound)
            )
        }
    }

    /**
     Verifies restored Android Multi ranges remain one ordered fragment across chapter boundaries.

     Android restores a persisted `BookAndKey` with `PassageKeyFactory`, so a same-book range does
     not split, truncate at the first chapter, or become separate children during reconstruction.

     - Side effects: Reads four exact verses from the temporary KJV package fixture.
     - Failure modes: Fails when range parsing stops at a chapter edge, fragment order changes, or
       persistence identity is normalized to only one endpoint.
     */
    func testRestoredMultiPreservesCrossChapterPassageAsOneOrderedFragment() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let activeKJV = try XCTUnwrap(manager.module(named: "KJV"))
        let pageKey = "KJV:Gen.1.31-Gen.2.3"
        let request = try XCTUnwrap(
            BibleReaderRestoredMultiDocumentBuilder(
                swordManager: manager,
                activeModule: activeKJV
            ).build(pageKey: pageKey)
        )
        let document = try parsedJSONObject(request.documentJSON)
        let fragment = try XCTUnwrap(
            (document["osisFragments"] as? [[String: Any]])?.first
        )
        let xml = try XCTUnwrap(fragment["xml"] as? String)
        let expectedRefs = ["Gen.1.31", "Gen.2.1", "Gen.2.2", "Gen.2.3"]

        XCTAssertEqual(request.pageKey, pageKey)
        XCTAssertEqual(fragment["osisRef"] as? String, "Gen.1.31-Gen.2.3")
        XCTAssertEqual(fragment["bookInitials"] as? String, "KJV")
        XCTAssertEqual(fragment["v11n"] as? String, "KJV")
        let positions = try expectedRefs.map { reference in
            try XCTUnwrap(xml.range(of: "osisID=\"\(reference)\"")?.lowerBound)
        }
        XCTAssertEqual(positions, positions.sorted())
    }

    /**
     Verifies ordinary Bible navigation invalidates a delayed Compare result.

     - Setup: The injected Compare build gate blocks on a background queue until Genesis 2 replaces
       the reader content.
     - Expected result: The released Compare payload never reaches Vue.
     - Failure meaning: A stale asynchronous Compare can overwrite a newer chapter.
     - Determinism: Semaphores synchronize build start/release; no timing sleep decides ownership.
     */
    @MainActor
    func testDelayedCompareCannotOverwriteNewerBibleNavigation() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        let gate = DelayedCompareBuildGate()
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            compareDocumentBuildOperation: gate.build
        )
        controller.bridgeDidSetClientReady(bridge)

        controller.loadCompareDocument(
            bookInitials: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        )
        XCTAssertTrue(gate.waitUntilFirstBuildStarts())
        controller.navigateTo(book: "Genesis", chapter: 2, verse: 1)
        gate.releaseFirstBuild()
        waitForMainQueue()

        XCTAssertFalse(scripts().contains { $0.contains("delayed-compare-1") })
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 2)
    }

    /**
     Verifies a target-owned My Notes route invalidates a delayed Compare result.

     - Setup: A KJV Compare build is blocked while the reader opens Genesis 1 My Notes.
     - Expected result: The notes document remains the newest emitted content and no late Compare is
       added.
     - Failure meaning: Compare completion can replace an annotation document selected afterward.
     - Determinism: The build gate synchronizes the exact midpoint.
     */
    @MainActor
    func testDelayedCompareCannotOverwriteNewerMyNotesDocument() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        let gate = DelayedCompareBuildGate()
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            compareDocumentBuildOperation: gate.build
        )
        controller.bridgeDidSetClientReady(bridge)

        controller.loadCompareDocument(
            bookInitials: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        )
        XCTAssertTrue(gate.waitUntilFirstBuildStarts())
        controller.bridge(bridge, openMyNotes: "KJV", ordinal: ordinal)
        gate.releaseFirstBuild()
        waitForMainQueue()

        XCTAssertFalse(scripts().contains { $0.contains("delayed-compare-1") })
        XCTAssertTrue(controller.showingMyNotes)
        let notesPayloads = try bridgeEmissionPayloads(from: scripts(), event: "add_documents")
        XCTAssertTrue(notesPayloads.contains { ($0 as? [String: Any])?["type"] as? String == "notes" })
    }

    /**
     Verifies a second Compare request owns completion when the first build finishes later.

     - Setup: The first build blocks; the second returns immediately and emits its distinct id.
     - Expected result: Only the second payload reaches Vue after both builds finish.
     - Failure meaning: Compare requests are ordered by completion instead of content intent.
     - Determinism: A condition-backed gate records invocation order and controls only the first.
     */
    @MainActor
    func testNewestCompareWinsWhenEarlierBuildCompletesLast() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let firstOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        let secondOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 2))
        let gate = DelayedCompareBuildGate()
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            compareDocumentBuildOperation: gate.build
        )
        controller.bridgeDidSetClientReady(bridge)

        controller.loadCompareDocument(
            bookInitials: "KJV",
            startOrdinal: firstOrdinal,
            endOrdinal: firstOrdinal
        )
        XCTAssertTrue(gate.waitUntilFirstBuildStarts())
        controller.loadCompareDocument(
            bookInitials: "KJV",
            startOrdinal: secondOrdinal,
            endOrdinal: secondOrdinal
        )
        XCTAssertTrue(waitUntil { scripts().contains { $0.contains("delayed-compare-2") } })
        gate.releaseFirstBuild()
        waitForMainQueue()

        XCTAssertFalse(scripts().contains { $0.contains("delayed-compare-1") })
        XCTAssertEqual(scripts().filter { $0.contains("delayed-compare-2") }.count, 1)
    }

    /**
     Verifies reader auxiliary content uses exact structural OSIS rather than rendered-text XML.

     - Setup: Writes a real RawLD dictionary entry containing orthography, a reference, and a note,
       then opens it through the controller's dictionary path.
     - Expected result: Source metadata and structural nodes reach the emitted OSIS fragment, BVA
       anchors are present, and setup uses the complete Android field set.
     - Failure meaning: Auxiliary rendering has regressed to lossy rendered text, synthetic XML, or
       active-Bible metadata.
     */
    @MainActor
    func testDictionaryReaderEmitsExactStructuralOSISAndTypedSetup() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try writeRawLDModule(
            named: "STRUCTDICT",
            category: "Lexicons / Dictionaries",
            description: "Structural Dictionary",
            entries: [
                (
                    "G0001",
                    "<entryFree n=\"G0001\"><orth>logos</orth><p id=\"definition\">Word <reference osisRef=\"John.1.1\">John</reference>.</p><note>note</note></entryFree>"
                ),
            ],
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        controller.switchDictionaryDocument(to: "STRUCTDICT")
        let baseline = scripts().count

        controller.loadDictionaryEntry(key: "G0001")

        let emissions = Array(scripts().dropFirst(baseline))
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        let fragment = try XCTUnwrap(document["osisFragment"] as? [String: Any])
        let xml = try XCTUnwrap(fragment["xml"] as? String)
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "setup_content") as? [String: Any]
        )

        XCTAssertEqual(document["bookInitials"] as? String, "STRUCTDICT")
        XCTAssertEqual(document["bookName"] as? String, "Structural Dictionary")
        XCTAssertEqual(document["bookCategory"] as? String, "DICTIONARY")
        XCTAssertEqual(document["key"] as? String, "G0001")
        XCTAssertEqual(fragment["bookInitials"] as? String, "STRUCTDICT")
        XCTAssertEqual(fragment["v11n"] as? String, "KJV")
        XCTAssertTrue(xml.contains("<orth>"))
        XCTAssertTrue(xml.contains("logos"))
        XCTAssertTrue(xml.contains("<reference osisRef=\"John.1.1\""))
        XCTAssertTrue(xml.contains("<note>note</note>"))
        XCTAssertTrue(xml.contains("<BVA"))
        assertAndroidSetupPayload(setup)
    }

    /**
     Verifies commentary content, range metadata, and next navigation use linked SWORD blocks.

     - Setup: Reuses the compressed KJV bytes through a commentary driver so each verse supplies real
       structural content and deterministic neighboring blocks.
     - Expected result: The selected document carries non-null `commentaryRange`, structural OSIS,
       separate local-BVA and source-versification ranges, and next moves to the next commentary
       block start.
     - Failure meaning: Reader commentary has fallen back to synthetic text, lost block metadata, or
       navigates by Bible chapter instead of commentary blocks.
     */
    @MainActor
    func testCommentaryReaderEmitsStructuralBlockRangeAndNavigatesByBlock() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedCompressedCommentaryAlias(named: "STRUCTCOMM", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count

        controller.switchCommentaryDocument(to: "STRUCTCOMM")

        let commentaryEmissions = Array(scripts().dropFirst(baseline))
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: commentaryEmissions, event: "add_documents") as? [String: Any]
        )
        let fragment = try XCTUnwrap(document["osisFragment"] as? [String: Any])
        let range = try XCTUnwrap(document["commentaryRange"] as? [String: Any])
        let xml = try XCTUnwrap(fragment["xml"] as? String)
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: commentaryEmissions, event: "setup_content") as? [String: Any]
        )

        XCTAssertEqual(document["bookInitials"] as? String, "STRUCTCOMM")
        XCTAssertEqual(document["bookCategory"] as? String, "COMMENTARY")
        XCTAssertEqual(document["v11n"] as? String, "KJV")
        XCTAssertEqual(range["startOsisRef"] as? String, "Gen.1.1")
        XCTAssertEqual(range["endOsisRef"] as? String, "Gen.1.1")
        XCTAssertFalse((range["name"] as? String)?.isEmpty ?? true)
        XCTAssertEqual(document["ordinalRange"] as? [Int], [0, 6])
        XCTAssertEqual(fragment["ordinalRange"] as? [Int], [4, 4])
        XCTAssertTrue(xml.contains("<BVA"))
        XCTAssertFalse(xml.contains("No content for selected verse"))
        assertAndroidSetupPayload(setup)
        XCTAssertTrue(controller.hasNext)

        let navigationBaseline = scripts().count
        controller.navigateNext()
        let navigationEmissions = Array(scripts().dropFirst(navigationBaseline))
        let nextDocument = try XCTUnwrap(
            bridgeEmissionPayload(from: navigationEmissions, event: "add_documents") as? [String: Any]
        )
        let nextRange = try XCTUnwrap(nextDocument["commentaryRange"] as? [String: Any])
        XCTAssertEqual(controller.currentVerse, 2)
        XCTAssertEqual(nextRange["startOsisRef"] as? String, "Gen.1.2")
    }

    /**
     Verifies an empty-key chooser callback follows Android's first-global-key result contract.

     - Setup: Writes two real RawLD-backed auxiliary modules categorized as a general book and map,
       activates each, then invokes the callback with no selected row.
     - Expected result: Each path loads its owning module's unfiltered first global key and emits the
       complete typed setup payload.
     - Failure meaning: Empty selection becomes a no-op, uses stale active module state, or chooses a
       filtered/neighboring key.
     */
    @MainActor
    func testEmptyGeneralBookAndMapChooserLoadOwningFirstGlobalKey() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try writeRawLDModule(
            named: "STRUCTBOOK",
            category: "Generic Books",
            description: "Structural General Book",
            entries: [
                ("first-entry", "<div><p>First book entry.</p></div>"),
                ("second-entry", "<div><p>Second book entry.</p></div>"),
            ],
            in: modulePath
        )
        try writeRawLDModule(
            named: "STRUCTMAP",
            category: "Maps",
            description: "Structural Map",
            entries: [
                ("first-map", "<div><p>First map entry.</p></div>"),
                ("second-map", "<div><p>Second map entry.</p></div>"),
            ],
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)

        let generalBook = try XCTUnwrap(manager.module(named: "STRUCTBOOK"))
        controller.switchGeneralBookDocument(to: "STRUCTBOOK")
        let generalBaseline = scripts().count
        let firstGeneralBookKey = try XCTUnwrap(generalBook.loadAllKeys().first)
        controller.handleEmptyGenericKeyChooser(
            module: generalBook,
            category: .generalBook,
            firstGlobalKey: firstGeneralBookKey
        )
        let generalEmissions = Array(scripts().dropFirst(generalBaseline))
        let generalDocument = try XCTUnwrap(
            bridgeEmissionPayload(from: generalEmissions, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(generalDocument["key"] as? String, firstGeneralBookKey)
        assertAndroidSetupPayload(try XCTUnwrap(
            bridgeEmissionPayload(from: generalEmissions, event: "setup_content") as? [String: Any]
        ))

        let map = try XCTUnwrap(manager.module(named: "STRUCTMAP"))
        controller.switchMapDocument(to: "STRUCTMAP")
        let mapBaseline = scripts().count
        let firstMapKey = try XCTUnwrap(map.loadAllKeys().first)
        controller.handleEmptyGenericKeyChooser(
            module: map,
            category: .map,
            firstGlobalKey: firstMapKey
        )
        let mapEmissions = Array(scripts().dropFirst(mapBaseline))
        let mapDocument = try XCTUnwrap(
            bridgeEmissionPayload(from: mapEmissions, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(mapDocument["key"] as? String, firstMapKey)
        assertAndroidSetupPayload(try XCTUnwrap(
            bridgeEmissionPayload(from: mapEmissions, event: "setup_content") as? [String: Any]
        ))
    }

    /**
     Verifies real generic module switches preserve an exact key shared by the target module.

     - Setup: Restores source dictionary, general-book, and map modules at `SHARED-KEY`, then switches
       each category to a distinct real RawLD-backed target containing that exact key.
     - Expected result: Every switch reports key preservation and keeps controller/PageManager keys
       while updating module initials and visible category.
     - Failure meaning: iOS diverges from Android by clearing valid generic keys or opening a chooser
       during an exact-key module transition.
     - Side effects: Creates one temporary SWORD module root and mutates an in-memory reader window.
     */
    @MainActor
    func testGenericDocumentSwitchesPreserveExactTargetKeysAcrossCategories() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let exactKey = "SHARED-KEY"
        for (name, category, description) in [
            ("SourceDict", "Lexicons / Dictionaries", "Source Dictionary"),
            ("TargetDict", "Lexicons / Dictionaries", "Target Dictionary"),
            ("SourceBook", "Generic Books", "Source General Book"),
            ("TargetBook", "Generic Books", "Target General Book"),
            ("SourceMap", "Maps", "Source Map"),
            ("TargetMap", "Maps", "Target Map"),
        ] {
            try writeRawLDModule(
                named: name,
                category: category,
                description: description,
                entries: [(exactKey, "<div><p>Shared entry.</p></div>")],
                in: modulePath
            )
        }

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, _) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.dictionaryDocument = "SourceDict"
        pageManager.dictionaryKey = exactKey
        pageManager.generalBookDocument = "SourceBook"
        pageManager.generalBookKey = exactKey
        pageManager.mapDocument = "SourceMap"
        pageManager.mapKey = exactKey
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.restoreSavedPosition()

        XCTAssertEqual(controller.currentDictionaryKey, exactKey)
        XCTAssertEqual(controller.currentGeneralBookKey, exactKey)
        XCTAssertEqual(controller.currentMapKey, exactKey)
        for moduleName in ["TargetDict", "TargetBook", "TargetMap"] {
            let module = try XCTUnwrap(manager.module(named: moduleName))
            XCTAssertEqual(try module.loadAllKeys(), [exactKey])
            XCTAssertTrue(try module.containsExactKey(exactKey))
        }

        let dictionaryOutcome = controller.switchDictionaryDocument(to: "TargetDict")
        let generalBookOutcome = controller.switchGeneralBookDocument(to: "TargetBook")
        let mapOutcome = controller.switchMapDocument(to: "TargetMap")

        XCTAssertEqual(dictionaryOutcome, .switchedPreservingKey)
        XCTAssertEqual(controller.currentDictionaryKey, exactKey)
        XCTAssertEqual(pageManager.dictionaryDocument, "TargetDict")
        XCTAssertEqual(pageManager.dictionaryKey, exactKey)
        XCTAssertEqual(generalBookOutcome, .switchedPreservingKey)
        XCTAssertEqual(controller.currentGeneralBookKey, exactKey)
        XCTAssertEqual(pageManager.generalBookDocument, "TargetBook")
        XCTAssertEqual(pageManager.generalBookKey, exactKey)
        XCTAssertEqual(mapOutcome, .switchedPreservingKey)
        XCTAssertEqual(controller.currentMapKey, exactKey)
        XCTAssertEqual(pageManager.mapDocument, "TargetMap")
        XCTAssertEqual(pageManager.mapKey, exactKey)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.map.pageManagerKey)
    }
}

/**
 Thread-safe Compare builder gate used to reproduce completion-order races deterministically.

 The first invocation blocks until the test releases it; later invocations complete immediately.
 Each response carries a distinct valid Multi-document id so bridge assertions can identify the
 winning request without relying on timestamps.
 */
private final class DelayedCompareBuildGate: @unchecked Sendable {
    /// Condition protecting invocation order and first-build release state.
    private let condition = NSCondition()
    /// Number of builds that entered the gate.
    private var buildCount = 0
    /// Whether the first build reached its controlled midpoint.
    private var firstBuildStarted = false
    /// Whether the first build may return its payload.
    private var firstBuildReleased = false

    /**
     Builds a distinct synthetic Compare payload and blocks only the first invocation.

     - Parameter request: Captured production request; its validity is established before this
       injected background boundary and no fields are mutated by the gate.
     - Returns: Valid serialized Multi JSON tagged by invocation order.
     - Side effects: Mutates condition-protected test state and may block a background queue.
     - Failure modes: None; tests must call `releaseFirstBuild()` during cleanup paths.
     */
    func build(_ request: BibleReaderCompareDocumentBuilder.Request) -> String? {
        _ = request
        condition.lock()
        buildCount += 1
        let invocation = buildCount
        if invocation == 1 {
            firstBuildStarted = true
            condition.broadcast()
            while !firstBuildReleased {
                condition.wait()
            }
        }
        condition.unlock()
        return "{\"id\":\"delayed-compare-\(invocation)\",\"type\":\"multi\",\"osisFragments\":[],\"compare\":true,\"contentType\":null}"
    }

    /** Waits for the first background build to reach the controlled midpoint. */
    func waitUntilFirstBuildStarts(timeout: TimeInterval = 2) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !firstBuildStarted {
            if !condition.wait(until: deadline) {
                return firstBuildStarted
            }
        }
        return true
    }

    /** Releases the first blocked build exactly once. */
    func releaseFirstBuild() {
        condition.lock()
        firstBuildReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

/** Parses one serialized bridge document into a dictionary. */
private func parsedJSONObject(_ json: String) throws -> [String: Any] {
    try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    )
}

/**
 Decodes every recorded payload for one bridge event in emission order.

 - Parameters:
   - scripts: Recorded JavaScript bridge calls.
   - event: Event name to select.
 - Returns: Parsed payloads in the same order Vue received them.
 - Side effects: None.
 - Failure modes: Throws if any selected bridge wrapper or payload is malformed.
 */
private func bridgeEmissionPayloads(from scripts: [String], event: String) throws -> [Any] {
    let prefix = "bibleView.emit('\(event)', "
    return try scripts
        .filter { $0.contains(prefix) }
        .map { try bridgeEmissionPayload(from: [$0], event: event) }
}

/**
 Asserts the exact ten-field Android `setup_content` schema.

 The helper checks key presence and primitive types while allowing nullable navigation/highlight
 values. A failure means one native setup emitter can no longer drive the shared Vue consumer.
 */
private func assertAndroidSetupPayload(
    _ payload: [String: Any],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    assertJSONKeys(
        payload,
        [
            "jumpToOrdinal", "jumpToAnchor", "jumpToId", "topOffset", "bottomOffset",
            "ordinalStart", "ordinalEnd", "highlight", "bookInitials", "osisRef",
        ],
        file: file,
        line: line
    )
    XCTAssertNotNil(payload["topOffset"] as? Int, file: file, line: line)
    XCTAssertNotNil(payload["bottomOffset"] as? Int, file: file, line: line)
    XCTAssertNotNil(payload["highlight"] as? Bool, file: file, line: line)
}

/** Pumps the main run loop until a condition succeeds or its deterministic timeout expires. */
@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    return condition()
}

/** Drains main-queue completion work after a semaphore-controlled background operation returns. */
@MainActor
private func waitForMainQueue() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
}

/**
 Writes a real RawLD module into an existing temporary SWORD root.

 The explicit category lets the same exact-key driver exercise dictionary, general-book, and map
 reader orchestration without fabricating a `SwordModule` double.

 - Parameters:
   - moduleName: Stable module initials.
   - category: SWORD category string exposed to reader discovery.
   - description: Module display name.
   - entries: Exact key/structural OSIS records in lexical order.
   - modulePath: Existing temporary SWORD root.
 - Side effects: Writes `.conf`, `.dat`, and `.idx` files.
 - Failure modes: Propagates filesystem failures and rejects records too large for RawLD indexes.
 */
private func writeRawLDModule(
    named moduleName: String,
    category: String,
    description: String,
    entries: [(String, String)],
    in modulePath: String
) throws {
    let key = moduleName.lowercased()
    let root = URL(fileURLWithPath: modulePath, isDirectory: true)
    let modsDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
    let dataDirectory = root.appendingPathComponent(
        "modules/lexdict/rawld/\(key)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

    var data = Data()
    var index = Data()
    for (entryKey, xml) in entries {
        let record = Data("\(entryKey)\r\n\(xml)".utf8)
        guard record.count <= Int(UInt16.max), data.count <= Int(UInt32.max) else {
            throw ReaderBridgeFixtureError.recordTooLarge
        }
        index.appendLittleEndianFixture(UInt32(data.count))
        index.appendLittleEndianFixture(UInt16(record.count))
        data.append(record)
        data.append(0x0A)
    }

    let prefix = dataDirectory.appendingPathComponent(key, isDirectory: false)
    try data.write(to: prefix.appendingPathExtension("dat"))
    try index.write(to: prefix.appendingPathExtension("idx"))
    try """
    [\(moduleName)]
    Description=\(description)
    Abbreviation=\(moduleName)
    Category=\(category)
    DataPath=./modules/lexdict/rawld/\(key)/\(key)
    ModDrv=RawLD
    SourceType=OSIS
    Encoding=UTF-8
    Lang=en
    Versification=KJV
    """.write(
        to: modsDirectory.appendingPathComponent("\(key).conf", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )
}

/**
 Publishes the deterministic compressed Bible bytes through SWORD's commentary driver.

 The fixture is intentionally read-only and test-local: it changes only module metadata, allowing
 controller integration to exercise real structural commentary reads and adjacent block navigation.
 */
private func seedCompressedCommentaryAlias(named moduleName: String, in modulePath: String) throws {
    let modsDirectory = URL(fileURLWithPath: modulePath, isDirectory: true)
        .appendingPathComponent("mods.d", isDirectory: true)
    let sourceURL = modsDirectory.appendingPathComponent("kjv.conf", isDirectory: false)
    var config = try String(contentsOf: sourceURL, encoding: .utf8)
    config = config.replacingOccurrences(of: "[KJV]", with: "[\(moduleName)]")
    config = config.replacingOccurrences(
        of: "Description=King James Version (1769) with Strongs Numbers and Morphology  and CatchWords",
        with: "Description=Structural Commentary"
    )
    config = config.replacingOccurrences(of: "ModDrv=zText", with: "ModDrv=zCom")
    config += "\nCategory=Commentaries\n"
    try config.write(
        to: modsDirectory.appendingPathComponent("\(moduleName.lowercased()).conf", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )
}

/** Test fixture construction errors. */
private enum ReaderBridgeFixtureError: Error {
    /// RawLD uses a 16-bit record length and 32-bit offset.
    case recordTooLarge
}

private extension Data {
    /** Appends one RawLD index integer in little-endian order. */
    mutating func appendLittleEndianFixture<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
