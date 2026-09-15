import Foundation
import SwiftData
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
     - Determinism: The test observes the production coordinator's accepted bridge emission instead
       of assuming that source capture completes synchronously.
     */
    @MainActor
    func testCompareEventUsesSelectedVulgateFragmentWhileActivePaneIsKJV() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedSyntheticRawTextBibleModule(
            named: "VulgTest",
            description: "Vulgate compare fixture",
            versification: "Vulg",
            entries: [
                (
                    "Gen", 1, 1,
                    #"<verse osisID="Gen.1.1">Synthetic Vulgate Genesis one.</verse>"#
                ),
                (
                    "Gen", 1, 2,
                    #"<verse osisID="Gen.1.2">Synthetic Vulgate Genesis two.</verse>"#
                ),
            ],
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
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager
        )
        XCTAssertEqual(controller.activeModuleName, "KJV")

        controller.bridge(bridge, compareVerses: "VulgTest", startOrdinal: start, endOrdinal: end)

        XCTAssertTrue(
            waitUntil(timeout: 10) {
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
        XCTAssertTrue(
            (sourceFragment["xml"] as? String)?.contains("Synthetic Vulgate Genesis one.") == true
        )
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
    func testMyNotesRouteConvertsDeclaredVulgateOrdinalToKJVA() async throws {
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

        let newScripts = try await awaitBridgeEmission(
            from: scripts,
            event: "setup_content",
            after: initialScriptCount
        )
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
    func testMyNotesRouteUsesDeclaredCanonWhenSourceModuleIsNotInstalled() async throws {
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

        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: baseline
        )
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
     Verifies a single Android OSIS range remains the loaded Bible document's complete anchor range.

     Android routes a one-range `Passage` as a Bible document and carries its full source range into
     the scoped scroll highlight. When the same source chapter is already loaded, iOS must convert
     every endpoint into the active module and scroll without replacing the document generation.

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
        XCTAssertTrue(waitUntil {
            scripts().contains { $0.contains("emit('add_documents'") }
        })
        let baseline = scripts().count

        controller.bridge(
            bridge,
            openExternalLink: "osis://?osis=Gen.1.1-Gen.1.3&v11n=KJV"
        )

        let emissions = Array(scripts().dropFirst(baseline))
        let scroll = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "scroll_to_verse") as? [String: Any]
        )

        XCTAssertEqual(scroll["ordinal"] as? Int, start)
        XCTAssertEqual(scroll["ordinalStart"] as? Int, start)
        XCTAssertEqual(scroll["ordinalEnd"] as? Int, end)
        XCTAssertEqual(scroll["highlight"] as? Bool, true)
        XCTAssertEqual(scroll["bookInitials"] as? String, "KJV")
        XCTAssertEqual(scroll["osisRef"] as? String, "Gen.1")
        XCTAssertFalse(emissions.contains { $0.contains("emit('clear_document'") })
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

     The fixture stores licensed-safe synthetic verses in a Vulgate-sized RawText index. The
     builder receives an ordered Vulgate Psalm range targeted back to that source module; the active
     KJV pane must not rename, reinterpret, collapse, reorder, or substitute its source content.

     - Side effects: Creates one temporary source-valid SWORD module and reads two exact entries.
     - Failure modes: Active-pane inference changes the key/v11n/ordinals, while single-verse
       shortcuts lose the range or its XML order.
     */
    func testLiveMultiPreservesVulgateRangeIdentityAndOrderWithActiveKJV() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedSyntheticRawTextBibleModule(
            named: "VulgTest",
            description: "Vulgate live Multi fixture",
            versification: "Vulg",
            entries: [
                (
                    "Ps", 10, 1,
                    #"<verse osisID="Ps.10.1">Synthetic Vulgate Psalm ten one.</verse>"#
                ),
                (
                    "Ps", 10, 2,
                    #"<verse osisID="Ps.10.2">Synthetic Vulgate Psalm ten two.</verse>"#
                ),
            ],
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
        XCTAssertTrue(xml.contains("Synthetic Vulgate Psalm ten one."))
        XCTAssertTrue(xml.contains("Synthetic Vulgate Psalm ten two."))
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

     - Side effects: Creates two source-valid temporary modules and reads both synthetic ranges.
     - Failure modes: A shared v11n, active-module fallback, or aggregate reorder changes fragment
       identity, ordinals, or order.
     */
    func testLiveMultiPreservesMixedSourceModulesRangesAndOrder() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedSyntheticRawTextBibleModule(
            named: "VulgTest",
            description: "Vulgate mixed Multi fixture",
            versification: "Vulg",
            entries: [
                (
                    "Tob", 1, 1,
                    #"<verse osisID="Tob.1.1">Synthetic Vulgate Tobit one.</verse>"#
                ),
                (
                    "Tob", 1, 2,
                    #"<verse osisID="Tob.1.2">Synthetic Vulgate Tobit two.</verse>"#
                ),
            ],
            in: modulePath
        )
        try seedSyntheticRawTextBibleModule(
            named: "LXXTest",
            description: "LXX mixed Multi fixture",
            versification: "LXX",
            entries: [
                (
                    "1Esd", 1, 1,
                    #"<verse osisID="1Esd.1.1">Synthetic LXX Esdras one.</verse>"#
                ),
                (
                    "1Esd", 1, 2,
                    #"<verse osisID="1Esd.1.2">Synthetic LXX Esdras two.</verse>"#
                ),
            ],
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
        XCTAssertTrue(
            (fragments[0]["xml"] as? String)?.contains("Synthetic Vulgate Tobit one.") == true
        )
        XCTAssertTrue(
            (fragments[1]["xml"] as? String)?.contains("Synthetic LXX Esdras one.") == true
        )
    }

    /**
     Verifies restored Multi children retain Vulgate/LXX source-only books, ranges, and order.

     Android restores each persisted `BookAndKey` through the child module's own
     `PassageKeyFactory`. The active KJV pane is intentionally unable to name Tobit or 1 Esdras, so
     any active-catalog inference drops these children and fails the test.

     - Side effects: Creates source-valid Vulgate/LXX modules and reads their synthetic source-only
       ranges.
     - Failure modes: Single-verse parsing, KJV book lookup, source-module loss, or child reordering
       changes the parsed fragment list or produces no restored payload.
     */
    func testRestoredMultiPreservesVulgateAndLXXSourceOnlyRangesWithActiveKJV() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedSyntheticRawTextBibleModule(
            named: "VulgTest",
            description: "Vulgate restored Multi fixture",
            versification: "Vulg",
            entries: [
                (
                    "Tob", 1, 1,
                    #"<verse osisID="Tob.1.1">Synthetic restored Vulgate Tobit one.</verse>"#
                ),
                (
                    "Tob", 1, 2,
                    #"<verse osisID="Tob.1.2">Synthetic restored Vulgate Tobit two.</verse>"#
                ),
            ],
            in: modulePath
        )
        try seedSyntheticRawTextBibleModule(
            named: "LXXTest",
            description: "LXX restored Multi fixture",
            versification: "LXX",
            entries: [
                (
                    "1Esd", 1, 1,
                    #"<verse osisID="1Esd.1.1">Synthetic restored LXX Esdras one.</verse>"#
                ),
                (
                    "1Esd", 1, 2,
                    #"<verse osisID="1Esd.1.2">Synthetic restored LXX Esdras two.</verse>"#
                ),
            ],
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
        XCTAssertTrue(
            (fragments[0]["xml"] as? String)?.contains("Synthetic restored Vulgate Tobit one.")
                == true
        )
        XCTAssertTrue(
            (fragments[1]["xml"] as? String)?.contains("Synthetic restored LXX Esdras one.") == true
        )
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
     Verifies section-title changes preserve Compare because it has no conditional introductions.

     After the first production Compare request is accepted, changing section-title visibility must
     update config without another document replacement because Compare payloads contain only
     explicitly selected verses. A failure means invalidation is based on a global SWORD flag
     instead of the committed document family's native extraction dependency.
     */
    @MainActor
    func testExtractionSettingsRebuildCompareFromCapturedRequest() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager
        )
        var settings = TextDisplaySettings.appDefaults
        settings.showSectionTitles = false
        controller.displaySettings = settings
        controller.bridgeDidSetClientReady(bridge)

        controller.loadCompareDocument(
            bookInitials: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        )
        XCTAssertTrue(waitUntil {
            (try? bridgeEmissionPayloads(from: scripts(), event: "add_documents"))?
                .contains(where: { ($0 as? [String: Any])?["compare"] as? Bool == true }) == true
        })
        let replacementCount = try bridgeEmissionPayloads(
            from: scripts(),
            event: "add_documents"
        ).count

        settings.showSectionTitles = true
        controller.updateDisplaySettings(settings, nightMode: false)

        XCTAssertEqual(
            try bridgeEmissionPayloads(from: scripts(), event: "add_documents").count,
            replacementCount
        )
        XCTAssertEqual(controller.committedRenderState.identity?.book, "Compare")
        XCTAssertEqual(controller.committedRenderState.sourceProvenance, .compositeMayUseSword)
    }

    /**
     Verifies ordinary Bible navigation invalidates a delayed Compare result.

     - Setup: The production preparation queue is suspended until Genesis 2 replaces the reader
       content.
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
        let workerQueue = DispatchQueue(label: "ReaderBridgeParityTests-delayed-compare-bible")
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: workerQueue)
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        controller.bridgeDidSetClientReady(bridge)
        XCTAssertTrue(waitUntil { scripts().contains { $0.contains("emit('add_documents'") } })
        let baseline = scripts().count
        workerQueue.suspend()

        controller.loadCompareDocument(
            bookInitials: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        )
        controller.navigateTo(book: "Genesis", chapter: 2, verse: 1)
        workerQueue.resume()
        XCTAssertTrue(waitUntil { scripts().dropFirst(baseline).contains {
            $0.contains("emit('add_documents'")
        } })

        let laterDocuments = try bridgeEmissionPayloads(
            from: Array(scripts().dropFirst(baseline)),
            event: "add_documents"
        )
        XCTAssertFalse(laterDocuments.contains {
            ($0 as? [String: Any])?["compare"] as? Bool == true
        })
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
        let workerQueue = DispatchQueue(label: "ReaderBridgeParityTests-delayed-compare-notes")
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: workerQueue)
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        controller.bridgeDidSetClientReady(bridge)
        XCTAssertTrue(waitUntil { scripts().contains { $0.contains("emit('add_documents'") } })
        let baseline = scripts().count
        workerQueue.suspend()

        controller.loadCompareDocument(
            bookInitials: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        )
        controller.bridge(bridge, openMyNotes: "KJV", ordinal: ordinal)
        workerQueue.resume()
        XCTAssertTrue(waitUntil {
            (try? bridgeEmissionPayloads(
                from: Array(scripts().dropFirst(baseline)),
                event: "add_documents"
            ))?.contains { ($0 as? [String: Any])?["type"] as? String == "notes" } == true
        })

        let laterPayloads = try bridgeEmissionPayloads(
            from: Array(scripts().dropFirst(baseline)),
            event: "add_documents"
        )
        XCTAssertFalse(laterPayloads.contains {
            ($0 as? [String: Any])?["compare"] as? Bool == true
        })
        XCTAssertTrue(controller.showingMyNotes)
        XCTAssertTrue(laterPayloads.contains {
            ($0 as? [String: Any])?["type"] as? String == "notes"
        })
    }

    /**
     Verifies a second Compare request owns completion when the first build finishes later.

     - Setup: Two requests are queued before the production preparation queue resumes.
     - Expected result: Only the newer payload reaches Vue after the queue finishes.
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
        let workerQueue = DispatchQueue(label: "ReaderBridgeParityTests-newest-compare")
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: workerQueue)
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        controller.bridgeDidSetClientReady(bridge)
        XCTAssertTrue(waitUntil { scripts().contains { $0.contains("emit('add_documents'") } })
        let baseline = scripts().count
        workerQueue.suspend()

        controller.loadCompareDocument(
            bookInitials: "KJV",
            startOrdinal: firstOrdinal,
            endOrdinal: firstOrdinal
        )
        controller.loadCompareDocument(
            bookInitials: "KJV",
            startOrdinal: secondOrdinal,
            endOrdinal: secondOrdinal
        )
        workerQueue.resume()
        XCTAssertTrue(waitUntil {
            (try? bridgeEmissionPayloads(
                from: Array(scripts().dropFirst(baseline)),
                event: "add_documents"
            ))?.contains { ($0 as? [String: Any])?["compare"] as? Bool == true } == true
        })

        let compareDocuments = try bridgeEmissionPayloads(
            from: Array(scripts().dropFirst(baseline)),
            event: "add_documents"
        ).compactMap { $0 as? [String: Any] }.filter { $0["compare"] as? Bool == true }
        XCTAssertEqual(compareDocuments.count, 1)
        let fragments = try XCTUnwrap(compareDocuments.first?["osisFragments"] as? [[String: Any]])
        XCTAssertTrue(fragments.allSatisfy { $0["osisRef"] as? String == "Gen.1.2" })
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

        XCTAssertTrue(waitUntil {
            scripts().dropFirst(baseline).contains { $0.contains("emit('add_documents'") }
        })

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
     Preserves an authorized SWORD auxiliary key across a rejected initial bridge replacement.

     - Setup: Selects a real RawLD dictionary and loads its exact key through a bridge without an
       evaluator, then attaches the ordinary observer and sends client-ready.
     - Expected result: Native selected key survives the rejected dispatch while rendered state is
       empty; client-ready replays the exact structural entry and then commits rendered identity.
     - Failure meaning: The shared auxiliary adapter persists selection after bridge acceptance and
       therefore loses dictionary/general-book/map navigation while Vue is bootstrapping.
     - Side effects: Writes one isolated dictionary fixture and records the accepted replay only.
     */
    @MainActor
    func testSwordAuxiliarySelectionSurvivesRejectedReplacementAndReplaysOnClientReady() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try writeRawLDModule(
            named: "DEFERREDDICT",
            category: "Lexicons / Dictionaries",
            description: "Deferred Dictionary",
            entries: [("G0001", "<entryFree n=\"G0001\"><p>Deferred definition.</p></entryFree>")],
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        XCTAssertEqual(
            controller.switchDictionaryDocument(to: "DEFERREDDICT"),
            .switchedRequiringKeySelection
        )

        controller.loadDictionaryEntry(key: "G0001")
        try await awaitReaderCondition("authorized deferred dictionary selection") {
            controller.currentDictionaryKey == "G0001"
        }
        XCTAssertEqual(controller.currentCategory, .dictionary)
        XCTAssertEqual(controller.committedRenderState, .empty)

        var replayScripts: [String] = []
        bridge.javaScriptEvaluationObserver = { replayScripts.append($0) }
        let boundary = replayScripts.count
        controller.bridgeDidSetClientReady(bridge)
        let emissions = try await awaitBridgeEmission(
            from: { replayScripts },
            event: "add_documents",
            after: boundary
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        let fragment = try XCTUnwrap(document["osisFragment"] as? [String: Any])
        let xml = try XCTUnwrap(fragment["xml"] as? String)

        XCTAssertEqual(document["bookInitials"] as? String, "DEFERREDDICT")
        XCTAssertEqual(document["key"] as? String, "G0001")
        XCTAssertTrue(xml.contains("Deferred definition."))
        XCTAssertEqual(controller.committedRenderState.identity?.category, .dictionary)
        XCTAssertEqual(controller.committedRenderState.identity?.moduleName, "DEFERREDDICT")
        XCTAssertEqual(controller.committedRenderState.identity?.key, "G0001")
    }

    /**
     Verifies commentary content, range metadata, and next navigation use linked SWORD blocks.

     - Setup: Reuses the compressed KJV bytes through a commentary driver so each verse supplies real
       structural content and deterministic neighboring blocks.
     - Expected result: The selected document carries non-null `commentaryRange`, structural OSIS,
       separate local-BVA and source-versification ranges, and next uses its captured adjacent
       target. A rejected replacement clears that accepted availability, while client-ready replay
       publishes the intended adjacent block.
     - Failure meaning: Reader commentary has fallen back to synthetic text, lost block metadata, or
       navigates by Bible chapter instead of commentary blocks.
     */
    @MainActor
    func testCommentaryReaderEmitsStructuralBlockRangeAndNavigatesByBlock() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedCompressedCommentaryAlias(named: "STRUCTCOMM", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let rejectedPublication = expectation(description: "rejected commentary publication")
        let observeRejectedPublication = CommentaryPublicationGate()
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            phaseObserver: { phase, _, key in
                guard phase == .publication,
                      key.family.rawValue == "sword-commentary",
                      observeRejectedPublication.consumeIfOpen() else { return }
                rejectedPublication.fulfill()
            }
        )
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleBibleBook = 0
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 1
        window.pageManager = pageManager
        window.isSynchronized = true
        retainReaderWindowGraph(window)
        controller.activeWindow = window
        let container = try makeWorkspaceModelContainer()
        let windowManager = WindowManager(
            workspaceStore: WorkspaceStore(modelContext: ModelContext(container))
        )
        windowManager.activeWindow = window
        controller.windowManagerRef = windowManager
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count

        controller.switchCommentaryDocument(to: "STRUCTCOMM")

        let commentaryEmissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: baseline
        )
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
        XCTAssertEqual(controller.committedRenderState.identity?.category, .commentary)
        XCTAssertEqual(controller.committedRenderState.sourceProvenance, .swordModules(["STRUCTCOMM"]))
        let synchronizedReference = try XCTUnwrap(
            controller.synchronizedVerseReference(ordinal: 4)
        )
        XCTAssertEqual(synchronizedReference.osisBookId, "Gen")
        XCTAssertEqual(synchronizedReference.chapter, 1)
        XCTAssertEqual(synchronizedReference.verse, 1)
        XCTAssertTrue(xml.contains("<BVA"))
        XCTAssertFalse(xml.contains("No content for selected verse"))
        assertAndroidSetupPayload(setup)
        XCTAssertTrue(controller.hasNext)

        controller.bridge(bridge, didScrollToOrdinal: 6, key: "Gen.1.2", atChapterTop: false)
        XCTAssertEqual(controller.currentVerse, 1)
        XCTAssertEqual(pageManager.bibleVerseNo, 1)
        XCTAssertNil(pageManager.commentaryAnchorOrdinal)

        let synchronizedScrollBoundary = scripts().count
        controller.scrollToSynchronizedVerse(
            osisBookId: synchronizedReference.osisBookId,
            chapter: synchronizedReference.chapter,
            verse: synchronizedReference.verse
        )
        let synchronizedScrollPayload = try XCTUnwrap(
            bridgeEmissionPayload(
                from: Array(scripts().dropFirst(synchronizedScrollBoundary)),
                event: "scroll_to_verse"
            ) as? [String: Any]
        )
        XCTAssertEqual(synchronizedScrollPayload["ordinal"] as? Int, 4)
        let reverseBroadcast = expectation(description: "commentary sync feedback stays passive")
        reverseBroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in reverseBroadcast.fulfill() }

        var persistCount = 0
        let anchorPersisted = expectation(description: "commentary anchor persisted once")
        controller.onPersistState = {
            persistCount += 1
            anchorPersisted.fulfill()
        }
        controller.bridge(bridge, didScrollToOrdinal: 6, key: "Gen.1.1", atChapterTop: false)
        controller.bridge(bridge, didScrollToOrdinal: 6, key: "Gen.1.1", atChapterTop: false)
        XCTAssertEqual(controller.currentVerse, 1)
        XCTAssertEqual(pageManager.bibleVerseNo, 1)
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, 6)
        await fulfillment(of: [anchorPersisted], timeout: 2)
        await fulfillment(of: [reverseBroadcast], timeout: 0.35)
        XCTAssertEqual(persistCount, 1)

        let duplicatePersist = expectation(description: "unchanged commentary anchor stays quiet")
        duplicatePersist.isInverted = true
        controller.onPersistState = { duplicatePersist.fulfill() }
        controller.bridge(bridge, didScrollToOrdinal: 6, key: "Gen.1.1", atChapterTop: false)
        await fulfillment(of: [duplicatePersist], timeout: 0.45)
        controller.onPersistState = nil

        let acceptedEvaluator = bridge.javaScriptEvaluationObserver
        bridge.javaScriptEvaluationObserver = nil
        observeRejectedPublication.open()
        controller.navigateNext()
        await fulfillment(of: [rejectedPublication], timeout: 3)

        XCTAssertEqual(controller.currentVerse, 2)
        XCTAssertFalse(controller.hasNext)
        XCTAssertEqual(controller.committedRenderState.identity?.key, "Gen.1.1")

        bridge.javaScriptEvaluationObserver = acceptedEvaluator
        let replayBaseline = scripts().count
        controller.bridgeDidSetClientReady(bridge)
        let navigationEmissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: replayBaseline
        )
        let nextDocument = try XCTUnwrap(
            bridgeEmissionPayload(from: navigationEmissions, event: "add_documents") as? [String: Any]
        )
        let nextRange = try XCTUnwrap(nextDocument["commentaryRange"] as? [String: Any])
        XCTAssertEqual(controller.currentVerse, 2)
        XCTAssertEqual(nextRange["startOsisRef"] as? String, "Gen.1.2")

        controller.activeWindow = nil
        controller.bridge(bridge, didScrollToOrdinal: 4, key: "Gen.1.2", atChapterTop: false)
        XCTAssertEqual(controller.currentVerse, 2)
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, 6)
    }

    /**
     Verifies a real direct commentary annotation moves the shared source position once.

     - Setup: Installs a RawFiles commentary whose Genesis 1:1 and 1:2 indexes point to one source
       file directly annotated as `Gen.1.1`, bookmarks only that rendered owner key, starts the
       Bible at verse two, and accepts that exact commentary payload.
     - Expected result: The accepted payload exposes selected key `Gen.1.2` and document `osisRef`
       `Gen.1.1`; its annotation rows come from that rendered key while the selected key stays
       `Gen.1.2`; one Vue callback persists its local BVA anchor, moves Bible/PageManager state to
       verse one without a reload, and broadcasts the captured source ordinal/key once.
     - Failure meaning: Scroll authorization uses an unrendered neighbor, annotations are
       reauthorized against the selected rather than rendered key, the local BVA is resolved
       through the Bible module, the commentary anchor is dropped, content reloads, or Android's
       changed-key synchronization behavior is lost.
     */
    @MainActor
    func testCommentaryDirectRenderedAnnotationMovesSharedSourceWithoutReload() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedRawFilesCoveringCommentary(named: "RANGECOMM", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let bookmarkContainer = try makeBookmarkListModelContainer()
        let bookmarkContext = ModelContext(bookmarkContainer)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: bookmarkContext))
        let renderedOwnerBookmark = bookmarkService.addGenericBookmark(
            bookInitials: "RANGECOMM",
            key: "Gen.1.1",
            startOrdinal: 4,
            endOrdinal: 4
        )
        try bookmarkContext.save()
        let controller = BibleReaderController(
            bridge: bridge,
            bookmarkService: bookmarkService,
            swordManagerOverride: manager
        )
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleBibleBook = 0
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 2
        window.pageManager = pageManager
        window.isSynchronized = true
        retainReaderWindowGraph(window)
        controller.activeWindow = window
        let container = try makeWorkspaceModelContainer()
        let windowManager = WindowManager(
            workspaceStore: WorkspaceStore(modelContext: ModelContext(container))
        )
        windowManager.activeWindow = window
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 2)
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count

        controller.switchCommentaryDocument(to: "RANGECOMM")
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: baseline
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["bookInitials"] as? String, "RANGECOMM")
        XCTAssertEqual(document["key"] as? String, "Gen.1.2")
        XCTAssertEqual(document["osisRef"] as? String, "Gen.1.1")
        XCTAssertEqual(document["annotateRef"] as? String, "Gen.1.1")
        let genericBookmarks = try XCTUnwrap(
            document["genericBookmarks"] as? [[String: Any]]
        )
        XCTAssertEqual(genericBookmarks.map { $0["id"] as? String }, [
            renderedOwnerBookmark.id.uuidString,
        ])
        XCTAssertEqual(genericBookmarks.first?["key"] as? String, "Gen.1.1")
        let localRange = try XCTUnwrap(document["ordinalRange"] as? [Int])
        XCTAssertEqual(localRange.count, 2)
        let localAnchor = try XCTUnwrap(localRange.last)
        let renderedSourceOrdinal = try XCTUnwrap(
            manager.module(named: controller.activeModuleName)?.verseOrdinal(
                osisBookId: "Gen",
                chapter: 1,
                verse: 1
            )
        )
        XCTAssertNotEqual(localAnchor, renderedSourceOrdinal)
        XCTAssertEqual(controller.currentVerse, 2)
        XCTAssertEqual(pageManager.bibleVerseNo, 2)

        let persisted = expectation(description: "direct commentary source and anchor persist once")
        var persistCount = 0
        controller.onPersistState = {
            persistCount += 1
            persisted.fulfill()
        }
        let broadcast = expectation(description: "direct commentary source broadcasts once")
        var broadcastCount = 0
        windowManager.onSyncVerseChanged = { sourceWindow, sourceOrdinal, key in
            broadcastCount += 1
            XCTAssertEqual(sourceWindow.id, window.id)
            XCTAssertEqual(sourceOrdinal, renderedSourceOrdinal)
            XCTAssertEqual(key, "Gen.1.1")
            broadcast.fulfill()
        }
        let scriptBoundary = scripts().count

        controller.bridge(
            bridge,
            didScrollToOrdinal: localAnchor,
            key: try XCTUnwrap(document["osisRef"] as? String),
            atChapterTop: false
        )

        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 1)
        XCTAssertEqual(pageManager.bibleBibleBook, 0)
        XCTAssertEqual(pageManager.bibleChapterNo, 1)
        XCTAssertEqual(pageManager.bibleVerseNo, 1)
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, localAnchor)
        XCTAssertEqual(scripts().count, scriptBoundary)
        await fulfillment(of: [persisted, broadcast], timeout: 2)
        XCTAssertEqual(persistCount, 1)
        XCTAssertEqual(broadcastCount, 1)
    }

    /**
     Rejects an old visible commentary callback after a newer durable owner is selected.

     Bridge rejection deliberately leaves the old document accepted while the public switch path
     commits the new PageManager commentary module. The old DOM may still report its key, but it
     cannot overwrite the new owner's anchor or source Bible position.
     */
    @MainActor
    func testCommentaryScrollRejectsOldAcceptedDocumentAfterSelectedOwnerChanges() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedCompressedCommentaryAlias(named: "STRUCTA", in: modulePath)
        try seedCompressedCommentaryAlias(named: "STRUCTB", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let rejectedPublication = expectation(description: "new commentary bridge rejected")
        let observeRejectedPublication = CommentaryPublicationGate()
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            phaseObserver: { phase, _, key in
                guard phase == .publication,
                      key.family.rawValue == "sword-commentary",
                      observeRejectedPublication.consumeIfOpen() else { return }
                rejectedPublication.fulfill()
            }
        )
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleBibleBook = 0
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 1
        window.pageManager = pageManager
        retainReaderWindowGraph(window)
        controller.activeWindow = window
        controller.bridgeDidSetClientReady(bridge)
        var baseline = scripts().count
        controller.switchCommentaryDocument(to: "STRUCTA")
        _ = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: baseline)
        let acceptedBeforeSwitch = controller.committedRenderState

        bridge.javaScriptEvaluationObserver = nil
        baseline = scripts().count
        observeRejectedPublication.open()
        controller.switchCommentaryDocument(to: "STRUCTB")
        await fulfillment(of: [rejectedPublication], timeout: 3)
        XCTAssertEqual(scripts().count, baseline)
        XCTAssertEqual(pageManager.commentaryDocument, "STRUCTB")
        XCTAssertEqual(controller.committedRenderState, acceptedBeforeSwitch)

        let persisted = expectation(description: "old commentary callback does not persist")
        persisted.isInverted = true
        controller.onPersistState = { persisted.fulfill() }
        controller.bridge(bridge, didScrollToOrdinal: 6, key: "Gen.1.1", atChapterTop: false)
        XCTAssertNil(pageManager.commentaryAnchorOrdinal)
        XCTAssertEqual(pageManager.bibleVerseNo, 1)
        XCTAssertEqual(controller.currentVerse, 1)
        await fulfillment(of: [persisted], timeout: 0.45)
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
    func testEmptyGeneralBookAndMapChooserLoadOwningFirstGlobalKey() async throws {
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
        let generalEmissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: generalBaseline
        )
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
        let mapEmissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: mapBaseline
        )
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
        self.retainReaderWindowGraph(window)
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

/** Lock-owned switch used by the commentary rejection observer across worker/main test phases. */
private final class CommentaryPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var openState = false

    func consumeIfOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard openState else { return false }
        openState = false
        return true
    }

    func open() {
        lock.lock()
        openState = true
        lock.unlock()
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

/**
 Installs one real KJV RawFiles commentary block spanning Genesis 1:1-2.

 Both physical verse-index rows point to the same standalone OSIS file. Its direct annotation owns
 `Gen.1.1`, so selecting verse two exercises Android's changed-key document identity without
 fabricating a prepared route or exposing a production test hook.
 */
private func seedRawFilesCoveringCommentary(named moduleName: String, in modulePath: String) throws {
    let root = URL(fileURLWithPath: modulePath, isDirectory: true)
    let modsDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
    let moduleKey = moduleName.lowercased()
    let dataDirectory = root.appendingPathComponent(
        "modules/comments/rawfiles/\(moduleKey)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: modsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

    let fileName = "0000000"
    let source = """
    <verse osisID="Gen.1.1"><div annotateRef="Gen.1.1"><p>Shared covering commentary.</p></div></verse>
    """
    try Data(source.utf8).write(
        to: dataDirectory.appendingPathComponent(fileName, isDirectory: false)
    )
    var oldTestamentIndex = [UInt8](repeating: 0, count: 24_115 * 6)
    for row in [4, 5] {
        let rowOffset = row * 6
        oldTestamentIndex[rowOffset + 4] = UInt8(fileName.utf8.count)
    }
    try Data(fileName.utf8).write(
        to: dataDirectory.appendingPathComponent("ot", isDirectory: false)
    )
    try Data(oldTestamentIndex).write(
        to: dataDirectory.appendingPathComponent("ot.vss", isDirectory: false)
    )
    try Data().write(to: dataDirectory.appendingPathComponent("nt", isDirectory: false))
    try Data().write(to: dataDirectory.appendingPathComponent("nt.vss", isDirectory: false))
    try Data(repeating: 0, count: 4).write(
        to: dataDirectory.appendingPathComponent("incfile", isDirectory: false)
    )
    try """
    [\(moduleName)]
    Description=RawFiles Covering Commentary
    Abbreviation=RFC
    Category=Commentaries
    DataPath=./modules/comments/rawfiles/\(moduleKey)/
    ModDrv=RawFiles
    SourceType=OSIS
    Encoding=UTF-8
    Lang=en
    Versification=KJV
    """.write(
        to: modsDirectory.appendingPathComponent("\(moduleKey).conf", isDirectory: false),
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
