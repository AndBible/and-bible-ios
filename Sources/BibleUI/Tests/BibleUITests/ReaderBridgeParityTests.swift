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
        let paneOwner = try registerMyNotesPaneOwner(controller)
        defer { withExtendedLifetime(paneOwner) {} }
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
            JSwordKJVAVersification.verseOrdinal(
                osisId: targetReference.osisId,
                chapter: targetReference.chapter,
                verse: 1
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
            JSwordKJVAVersification.verseOrdinal(
                osisId: targetReference.osisId,
                chapter: targetReference.chapter,
                verse: 1
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
        let paneOwner = try registerMyNotesPaneOwner(controller)
        defer { withExtendedLifetime(paneOwner) {} }
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
        let paneOwner = try registerMyNotesPaneOwner(controller)
        defer { withExtendedLifetime(paneOwner) {} }
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
        // Android leaves an already-selected commentary Verse alone; no Bible ordinal belongs in
        // its structural-block DOM. Subsequent genuine row callbacks still persist the anchor.
        XCTAssertEqual(scripts().count, synchronizedScrollBoundary)
        let reverseBroadcast = expectation(description: "commentary sync feedback stays passive")
        reverseBroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _ in reverseBroadcast.fulfill() }

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
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, 6)

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
        // Android invalidates the previous key's local anchor when the new document is accepted.
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, 0)

        let rebuiltAppendBoundary = scripts().count
        controller.bridge(bridge, requestMoreToEnd: 8101)
        let rebuiltAppendResult = try await awaitBridgeScript(
            from: scripts,
            after: rebuiltAppendBoundary,
            description: "client-rebuilt commentary append"
        ) { $0.hasPrefix("bibleView.response(8101,") }
        let rebuiltAppend = try XCTUnwrap(rebuiltAppendResult)
        XCTAssertTrue(rebuiltAppend.contains(#""key":"Gen.1.3""#))

        controller.activeWindow = nil
        controller.bridge(bridge, didScrollToOrdinal: 4, key: "Gen.1.2", atChapterTop: false)
        XCTAssertEqual(controller.currentVerse, 2)
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, 0)
    }

    /**
     Reproduces Calvin's namespaced annotation through real module capture and bridge publication.

     The fixture retains Calvin's actual Genesis 1:22 and 1:24 OSIS, leaves 1:23 empty, and supplies
     bounded neighboring blocks. Android rejects the `Bible:` annotation as a verse reference and
     falls back to the selected key. One append must therefore return 1:24, and its visible callback
     must move the shared scripture position and request anchor persistence once without reloading.
     This observes the controller's persistence request and live PageManager state, not a durable
     store/relaunch. The separate real-Calvin app journey checks viewport restoration.

     Failure means source annotation metadata suppressed a valid edge, an empty verse became a
     document, an accepted appended key could not route its local anchor, or duplicate telemetry
     triggered another persistence request. No prepared payload or navigation route is injected.
     */
    @MainActor
    func testCalvinAnnotationFallbackAppendsAcrossEmptyVerseAndRoutesVisiblePosition() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedCalvinAnnotationCommentary(named: "CALVINSCROLL", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleBibleBook = 0
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 22
        retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 22)
        controller.bridgeDidSetClientReady(bridge)
        let replacementBoundary = scripts().count

        controller.switchCommentaryDocument(to: "CALVINSCROLL")
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: replacementBoundary
        )
        let initial = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(initial["key"] as? String, "Gen.1.22")
        XCTAssertEqual(initial["annotateRef"] as? String, "Gen.1.22")
        XCTAssertEqual(initial["osisRef"] as? String, "Gen.1.22")
        let initialFragment = try XCTUnwrap(initial["osisFragment"] as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(initialFragment["xml"] as? String).contains("Bible:Gen.1.22"))

        let appendBoundary = scripts().count
        controller.bridge(bridge, requestMoreToEnd: 8151)
        let responseResult = try await awaitBridgeScript(
            from: scripts,
            after: appendBoundary,
            description: "Calvin append past the empty verse"
        ) { $0.hasPrefix("bibleView.response(8151,") }
        let response = try XCTUnwrap(responseResult)
        let appended = try bridgeResponseObject(from: response)
        XCTAssertEqual(appended["key"] as? String, "Gen.1.24")
        XCTAssertEqual(appended["annotateRef"] as? String, "Gen.1.24")
        let appendedKey = try XCTUnwrap(appended["osisRef"] as? String)
        XCTAssertEqual(appendedKey, "Gen.1.24")
        let appendedFragment = try XCTUnwrap(appended["osisFragment"] as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(appendedFragment["xml"] as? String).contains("Bible:Gen.1.24"))
        XCTAssertEqual(scripts().dropFirst(appendBoundary).filter {
            $0.hasPrefix("bibleView.response(8151,")
        }.count, 1)

        let localRange = try XCTUnwrap(appended["ordinalRange"] as? [Int])
        let localAnchor = try XCTUnwrap(localRange.first)
        let persisted = expectation(description: "visible appended Calvin block requests persistence")
        persisted.assertForOverFulfill = true
        var persistCount = 0
        controller.onPersistState = {
            persistCount += 1
            persisted.fulfill()
        }
        defer { controller.onPersistState = nil }
        let visibleBoundary = scripts().count
        controller.bridge(
            bridge,
            didScrollToOrdinal: localAnchor,
            key: appendedKey,
            atChapterTop: false
        )
        await fulfillment(of: [persisted], timeout: 2)
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 24)
        XCTAssertEqual(pageManager.bibleVerseNo, 24)
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, localAnchor)
        XCTAssertEqual(persistCount, 1)
        XCTAssertTrue(try bridgeEmissionPayloads(
            from: Array(scripts().dropFirst(visibleBoundary)),
            event: "add_documents"
        ).isEmpty)

        let duplicatePersist = expectation(description: "duplicate Calvin telemetry stays quiet")
        duplicatePersist.isInverted = true
        controller.onPersistState = { duplicatePersist.fulfill() }
        controller.bridge(
            bridge,
            didScrollToOrdinal: localAnchor,
            key: appendedKey,
            atChapterTop: false
        )
        await fulfillment(of: [duplicatePersist], timeout: 0.45)
        XCTAssertEqual(pageManager.bibleVerseNo, 24)
        XCTAssertTrue(try bridgeEmissionPayloads(
            from: Array(scripts().dropFirst(visibleBoundary)),
            event: "add_documents"
        ).isEmpty)

        controller.onPersistState = nil
        let previousBoundary = scripts().count
        controller.navigatePrevious()
        let previousEmissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: previousBoundary
        )
        let previous = try XCTUnwrap(
            bridgeEmissionPayload(from: previousEmissions, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(previous["key"] as? String, "Gen.1.22")
        XCTAssertEqual(controller.currentVerse, 22)
    }

    /**
     Keeps selected-block append ownership separate from annotation-derived visible navigation.

     Genesis 1:24 deliberately annotates the valid range 1:21–22. Android uses that range's start
     after the visible callback, while its append lane still advances past the selected 1:24 block.
     The real module therefore must append 1:25 but navigate the toolbar from 1:21 to 1:22. Either
     result coming from the other coordinate exposes a conflated navigation owner.
     */
    @MainActor
    func testCommentaryAnnotationRangeSeparatesAppendEdgeFromVisibleToolbarPosition() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedCalvinAnnotationCommentary(
            named: "CALVINRANGE",
            in: modulePath,
            annotationForVerse24: "Gen.1.21-Gen.1.22"
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleBibleBook = 0
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 22
        retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 22)
        controller.bridgeDidSetClientReady(bridge)
        let replacementBoundary = scripts().count
        controller.switchCommentaryDocument(to: "CALVINRANGE")
        _ = try await awaitBridgeEmission(
            from: scripts, event: "add_documents", after: replacementBoundary
        )

        let firstBoundary = scripts().count
        controller.bridge(bridge, requestMoreToEnd: 8152)
        let firstResponse = try await awaitBridgeScript(
            from: scripts, after: firstBoundary, description: "append with a different annotation range"
        ) { $0.hasPrefix("bibleView.response(8152,") }
        let appended = try bridgeResponseObject(from: XCTUnwrap(firstResponse))
        XCTAssertEqual(appended["key"] as? String, "Gen.1.24")
        let renderedKey = try XCTUnwrap(appended["osisRef"] as? String)
        XCTAssertEqual(renderedKey, "Gen.1.21-Gen.1.22")
        XCTAssertEqual(appended["annotateRef"] as? String, renderedKey)
        let localRange = try XCTUnwrap(appended["ordinalRange"] as? [Int])
        controller.bridge(
            bridge,
            didScrollToOrdinal: try XCTUnwrap(localRange.first),
            key: renderedKey,
            atChapterTop: false
        )
        XCTAssertEqual(controller.currentVerse, 21)
        XCTAssertEqual(pageManager.bibleVerseNo, 21)

        let secondBoundary = scripts().count
        controller.bridge(bridge, requestMoreToEnd: 8153)
        let secondResponse = try await awaitBridgeScript(
            from: scripts, after: secondBoundary, description: "append keeps the selected outer edge"
        ) { $0.hasPrefix("bibleView.response(8153,") }
        let nextAppended = try bridgeResponseObject(from: XCTUnwrap(secondResponse))
        XCTAssertEqual(nextAppended["key"] as? String, "Gen.1.25")
        XCTAssertEqual(controller.currentVerse, 21)

        let toolbarBoundary = scripts().count
        controller.navigateNext()
        let toolbarEmissions = try await awaitBridgeEmission(
            from: scripts, event: "add_documents", after: toolbarBoundary
        )
        let toolbarDocument = try XCTUnwrap(
            bridgeEmissionPayload(from: toolbarEmissions, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(toolbarDocument["key"] as? String, "Gen.1.22")
        XCTAssertEqual(controller.currentVerse, 22)
    }

    /** Verifies Android's whole-chapter annotation retains its verse-zero introduction position. */
    @MainActor
    func testCommentaryChapterAnnotationRetainsIntroductionPosition() async throws {
        try await assertCommentaryAnnotationIntroduction("Gen.1", chapter: 1, ordinal: 3)
    }

    /** Verifies Android's whole-book annotation retains its chapter/verse-zero introduction. */
    @MainActor
    func testCommentaryBookAnnotationRetainsIntroductionPosition() async throws {
        try await assertCommentaryAnnotationIntroduction("Gen", chapter: 0, ordinal: 2)
    }

    /**
     Verifies toolbar Previous walks backward from a rendered chapter introduction.

     A real Genesis 1:24 commentary row annotates the start of Genesis chapter two. After Vue makes
     that chapter introduction visible, Android asks the commentary walker for the prior non-empty
     block rather than treating the annotation's null intro entry as a terminal boundary. The
     public toolbar action must therefore return the fixture's nearest Genesis 1:26 block. Failure
     means verse-zero navigation was retained but its backward edge was discarded or normalized.
     */
    @MainActor
    func testCommentaryChapterIntroductionToolbarPreviousWalksToPriorBlock() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedCalvinAnnotationCommentary(
            named: "CALVININTROPREVIOUS",
            in: modulePath,
            annotationForVerse24: "Gen.2"
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleBibleBook = 0
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 24
        retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 24)
        controller.bridgeDidSetClientReady(bridge)
        let replacementBoundary = scripts().count

        controller.switchCommentaryDocument(to: "CALVININTROPREVIOUS")

        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: replacementBoundary
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["osisRef"] as? String, "Gen.2")
        let localRange = try XCTUnwrap(document["ordinalRange"] as? [Int])
        controller.bridge(
            bridge,
            didScrollToOrdinal: try XCTUnwrap(localRange.first),
            key: "Gen.2",
            atChapterTop: false
        )
        XCTAssertEqual(controller.currentChapter, 2)
        XCTAssertEqual(controller.currentVerse, 0)
        XCTAssertTrue(controller.hasPrevious)

        let previousBoundary = scripts().count
        controller.navigatePrevious()
        let previousEmissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: previousBoundary
        )
        let previous = try XCTUnwrap(
            bridgeEmissionPayload(
                from: previousEmissions,
                event: "add_documents"
            ) as? [String: Any]
        )
        XCTAssertEqual(previous["key"] as? String, "Gen.1.26")
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 26)
    }

    /**
     Exercises one real annotated document through publication, visible telemetry, and sync lookup.

     Expected chapter/ordinal values come from Android VerseRangeFactory under KJV; introductions
     must not be coerced to scripture verse one or silently rejected. Each caller owns a separate
     temporary module and controller. This helper checks live positions and captured sync metadata;
     it neither injects routes nor claims an on-disk relaunch result.
     */
    @MainActor
    private func assertCommentaryAnnotationIntroduction(
        _ annotation: String,
        chapter: Int,
        ordinal: Int
    ) async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedCalvinAnnotationCommentary(
            named: "CALVININTRO", in: modulePath, annotationForVerse24: annotation
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleBibleBook = 0
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 24
        retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 24)
        controller.bridgeDidSetClientReady(bridge)
        let boundary = scripts().count
        controller.switchCommentaryDocument(to: "CALVININTRO")
        let emissions = try await awaitBridgeEmission(
            from: scripts, event: "add_documents", after: boundary
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["key"] as? String, "Gen.1.24")
        let renderedKey = try XCTUnwrap(document["osisRef"] as? String)
        XCTAssertEqual(renderedKey, annotation)
        XCTAssertEqual(document["annotateRef"] as? String, renderedKey)
        let localRange = try XCTUnwrap(document["ordinalRange"] as? [Int])
        controller.bridge(
            bridge,
            didScrollToOrdinal: try XCTUnwrap(localRange.first),
            key: renderedKey,
            atChapterTop: false
        )
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, chapter)
        XCTAssertEqual(controller.currentVerse, 0)
        XCTAssertEqual(pageManager.bibleChapterNo, chapter)
        XCTAssertEqual(pageManager.bibleVerseNo, 0)
        let synchronized = try XCTUnwrap(controller.synchronizedVerseReference(ordinal: ordinal))
        XCTAssertEqual(synchronized.osisBookId, "Gen")
        XCTAssertEqual(synchronized.chapter, chapter)
        XCTAssertEqual(synchronized.verse, 0)
    }

    /**
     Verifies a visible chapter introduction synchronizes a target already showing that chapter.

     A real annotated commentary document supplies `Gen.1` through the normal bridge callback and
     WindowManager sync route. The target must retain the exact chapter-introduction coordinate,
     emit its own SWORD ordinal through the existing `scroll_to_verse` event, and avoid replacing
     the already-loaded Bible document. Failure means target synchronization still rejects verse
     zero or coerces it to verse one. Only in-memory PageManager state is observed.
     */
    @MainActor
    func testCommentaryChapterIntroductionSynchronizesLoadedTargetAtVerseZero() async throws {
        try await assertCommentaryIntroductionSynchronizesTarget(
            annotation: "Gen.1",
            targetInitialBook: "Genesis",
            expectedChapter: 1,
            expectedOrdinal: 3,
            expectedReplacementRange: nil
        )
    }

    /**
     Verifies a visible book introduction survives synchronized cross-book replacement.

     The source reaches `Gen.0.0` from a real whole-book commentary annotation while the target is
     showing Exodus. Android retains the exact selected introduction, loads the chapter-zero through
     chapter-one Bible document, and anchors setup at the target-local book-introduction ordinal.
     The test observes the public bridge payload plus live controller/PageManager state; it does not
     inject a prepared route or claim durable relaunch coverage. Failure means cross-book sync snaps
     chapter or verse zero to one, omits the introduction from the replacement, or loses its anchor.
     */
    @MainActor
    func testCommentaryBookIntroductionSynchronizesCrossBookWithoutCoordinateCoercion() async throws {
        try await assertCommentaryIntroductionSynchronizesTarget(
            annotation: "Gen",
            targetInitialBook: "Exodus",
            expectedChapter: 0,
            expectedOrdinal: 2,
            expectedReplacementRange: [2, 34]
        )
    }

    /**
     Preserves a chapter introduction when synchronization replaces another chapter of the same book.

     Genesis 2:0 follows chapter one's final KJV ordinal 34; its introduction is 35 and verse 25
     ends at 60. Unlike same-loaded synchronization, this path must include the introduction in a
     newly prepared Bible document and its setup anchor. Failure means the replacement special-case
     covers only a whole-book introduction or still clamps the visible chapter-introduction verse.
     */
    @MainActor
    func testCommentaryChapterIntroductionSynchronizesAcrossChaptersWithoutCoordinateCoercion() async throws {
        try await assertCommentaryIntroductionSynchronizesTarget(
            annotation: "Gen.2",
            targetInitialBook: "Genesis",
            expectedChapter: 2,
            expectedOrdinal: 35,
            expectedReplacementRange: [35, 60]
        )
    }

    /**
     Opens a retained Bible book-introduction reference while the pane is showing commentary.

     Window-menu actions are category independent on Android: the retained Bible endpoint still
     passes through the active installed Bible's exact 0:0 proof, while the pane remains commentary.
     A book introduction absent from that source must fail without changing the accepted position.

     - Side effects: Seeds one commentary module and mutates one in-memory pane/PageManager.
     - Failure modes: Fails when commentary callers bypass the shared verse-zero proof, clamp the
       accepted endpoint, switch categories, or partially mutate state after an unowned endpoint.
     */
    @MainActor
    func testCommentaryWindowMenuUsesCommonBookIntroductionAdmission() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedCalvinAnnotationCommentary(
            named: "CALVININTROMENU",
            in: modulePath,
            annotationForVerse24: "Gen.1.24"
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        retainReaderWindowGraph(window)
        controller.activeWindow = window

        controller.scrollToSynchronizedVerse(osisBookId: "Matt", chapter: 0, verse: 0)
        let retainedReference = try XCTUnwrap(controller.windowMenuReference())
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 24)
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: 0)
        let commentaryBoundary = scripts().count
        XCTAssertEqual(controller.switchCommentaryDocument(to: "CALVININTROMENU"), .switched)
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: commentaryBoundary
        )
        XCTAssertEqual(controller.currentCategory, .commentary)

        try controller.navigateToWindowMenuReference(retainedReference)

        XCTAssertEqual(controller.currentCategory, .commentary)
        XCTAssertEqual(controller.currentBook, "Matthew")
        XCTAssertEqual(controller.currentChapter, 0)
        XCTAssertEqual(controller.currentVerse, 0)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.commentary.pageManagerKey)
        XCTAssertEqual(pageManager.bibleChapterNo, 0)
        XCTAssertEqual(pageManager.bibleVerseNo, 0)

        let acceptedPosition = (
            controller.currentBook,
            controller.currentChapter,
            controller.currentVerse,
            pageManager.bibleBibleBook,
            pageManager.bibleChapterNo,
            pageManager.bibleVerseNo
        )
        XCTAssertFalse(controller.navigateTo(book: "Tobit", chapter: 0, verse: 0))
        XCTAssertEqual(controller.currentBook, acceptedPosition.0)
        XCTAssertEqual(controller.currentChapter, acceptedPosition.1)
        XCTAssertEqual(controller.currentVerse, acceptedPosition.2)
        XCTAssertEqual(pageManager.bibleBibleBook, acceptedPosition.3)
        XCTAssertEqual(pageManager.bibleChapterNo, acceptedPosition.4)
        XCTAssertEqual(pageManager.bibleVerseNo, acceptedPosition.5)
        XCTAssertEqual(controller.currentCategory, .commentary)
    }

    /**
     Drives one real annotation introduction through the production source and target controllers.

     - Parameters:
       - annotation: Whole-chapter or whole-book annotation authored into the real commentary.
       - targetInitialBook: Bible book already accepted in the synchronized target pane.
       - expectedChapter: Exact visible chapter retained from the annotation start.
       - expectedOrdinal: Target-local KJV introduction ordinal.
       - expectedReplacementRange: Expected target document bounds, or nil when already loaded.
     - Side effects: Creates a temporary SWORD module, an in-memory workspace with two synchronized
       panes, and bridge recordings; no durable store or application singleton is changed.
     - Throws: Fixture, model-container, bridge-decoding, and asynchronous publication failures.
     - Failure modes: Fails when source authorization, WindowManager routing, target-local ordinal
       resolution, replacement setup, or exact PageManager coordinates diverge from Android.
     */
    @MainActor
    private func assertCommentaryIntroductionSynchronizesTarget(
        annotation: String,
        targetInitialBook: String,
        expectedChapter: Int,
        expectedOrdinal: Int,
        expectedReplacementRange: [Int]?
    ) async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedCalvinAnnotationCommentary(
            named: expectedReplacementRange != nil ? "CALVINSYNCREPLACE" : "CALVINSYNCCHAPTER",
            in: modulePath,
            annotationForVerse24: annotation
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (sourceBridge, sourceScripts) = makeRecordingBridge()
        let (targetBridge, targetScripts) = makeRecordingBridge()
        let sourceController = BibleReaderController(
            bridge: sourceBridge,
            swordManagerOverride: manager
        )
        let targetController = BibleReaderController(
            bridge: targetBridge,
            swordManagerOverride: manager
        )
        var targetDisplaySettings = TextDisplaySettings.appDefaults
        targetDisplaySettings.showSectionTitles = true
        targetController.displaySettings = targetDisplaySettings

        let container = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: ModelContext(container))
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Commentary introduction sync")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        retainReaderWindowGraph(sourceWindow)
        retainReaderWindowGraph(targetWindow)
        let sourcePageManager = try XCTUnwrap(sourceWindow.pageManager)
        let targetPageManager = try XCTUnwrap(targetWindow.pageManager)
        sourceController.activeWindow = sourceWindow
        sourceController.windowManagerRef = windowManager
        targetController.activeWindow = targetWindow
        targetController.windowManagerRef = windowManager
        XCTAssertTrue(windowManager.registerController(sourceController, for: sourceWindow))
        XCTAssertTrue(windowManager.registerController(targetController, for: targetWindow))
        windowManager.activeWindow = sourceWindow

        let targetInitialBoundary = targetScripts().count
        targetController.navigateTo(book: targetInitialBook, chapter: 1, verse: 5)
        targetController.bridgeDidSetClientReady(targetBridge)
        _ = try await awaitBridgeEmission(
            from: targetScripts,
            event: "add_documents",
            after: targetInitialBoundary
        )

        let sourceInitialBoundary = sourceScripts().count
        sourceController.navigateTo(book: "Genesis", chapter: 1, verse: 24)
        sourceController.bridgeDidSetClientReady(sourceBridge)
        _ = try await awaitBridgeEmission(
            from: sourceScripts,
            event: "add_documents",
            after: sourceInitialBoundary
        )
        let commentaryBoundary = sourceScripts().count
        sourceController.switchCommentaryDocument(
            to: expectedReplacementRange != nil ? "CALVINSYNCREPLACE" : "CALVINSYNCCHAPTER"
        )
        let commentaryEmissions = try await awaitBridgeEmission(
            from: sourceScripts,
            event: "add_documents",
            after: commentaryBoundary
        )
        let commentaryDocument = try XCTUnwrap(
            bridgeEmissionPayload(
                from: commentaryEmissions,
                event: "add_documents"
            ) as? [String: Any]
        )
        XCTAssertEqual(commentaryDocument["osisRef"] as? String, annotation)
        let localRange = try XCTUnwrap(commentaryDocument["ordinalRange"] as? [Int])
        let localAnchor = try XCTUnwrap(localRange.first)

        let synchronized = expectation(description: "introduction reaches synchronized target")
        synchronized.assertForOverFulfill = true
        windowManager.onSyncVerseChanged = { [weak windowManager] eventSource, delivery in
            guard let windowManager else { return }
            XCTAssertEqual(eventSource.id, sourceWindow.id)
            // CALVINSYNC declares KJV; typed delivery must retain the commentary source canon.
            XCTAssertEqual(delivery.position.sourceVersification, "KJV")
            XCTAssertEqual(delivery.position.osisBookId, "Gen")
            XCTAssertEqual(delivery.position.chapter, expectedChapter)
            XCTAssertEqual(delivery.position.verse, 0)
            XCTAssertEqual(delivery.position.sourceOrdinal, expectedOrdinal)
            XCTAssertEqual(delivery.position.sourceKey, "Gen.\(expectedChapter).0")
            for window in delivery.targets {
                (windowManager.controllers[window.id] as? BibleReaderController)?
                    .applyWindowSynchronizationPosition(delivery.position)
            }
            synchronized.fulfill()
        }

        let targetActionBoundary = targetScripts().count
        sourceController.bridge(
            sourceBridge,
            didScrollToOrdinal: localAnchor,
            key: annotation,
            atChapterTop: false
        )
        await fulfillment(of: [synchronized], timeout: 2)

        XCTAssertEqual(sourceController.currentBook, "Genesis")
        XCTAssertEqual(sourceController.currentChapter, expectedChapter)
        XCTAssertEqual(sourceController.currentVerse, 0)
        XCTAssertEqual(sourcePageManager.bibleChapterNo, expectedChapter)
        XCTAssertEqual(sourcePageManager.bibleVerseNo, 0)
        XCTAssertEqual(targetController.currentBook, "Genesis")
        XCTAssertEqual(targetController.currentChapter, expectedChapter)
        XCTAssertEqual(targetController.currentVerse, 0)
        XCTAssertEqual(targetPageManager.bibleBibleBook, 0)
        XCTAssertEqual(targetPageManager.bibleChapterNo, expectedChapter)
        XCTAssertEqual(targetPageManager.bibleVerseNo, 0)

        if let expectedReplacementRange {
            let emissions = try await awaitBridgeEmission(
                from: targetScripts,
                event: "add_documents",
                after: targetActionBoundary
            )
            let document = try XCTUnwrap(
                bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
            )
            let fragment = try XCTUnwrap(document["osisFragment"] as? [String: Any])
            let expectedRenderedReference = expectedChapter == 0
                ? "Gen.0-Gen.1"
                : "Gen.\(expectedChapter)"
            XCTAssertEqual(document["bookCategory"] as? String, "BIBLE")
            XCTAssertEqual(document["key"] as? String, expectedRenderedReference)
            XCTAssertEqual(document["osisRef"] as? String, expectedRenderedReference)
            XCTAssertEqual(document["annotateRef"] as? String, expectedRenderedReference)
            XCTAssertEqual(document["ordinalRange"] as? [Int], expectedReplacementRange)
            XCTAssertEqual(fragment["key"] as? String, "KJV--\(expectedRenderedReference)")
            XCTAssertEqual(fragment["osisRef"] as? String, expectedRenderedReference)
            XCTAssertEqual(fragment["ordinalRange"] as? [Int], expectedReplacementRange)
            let setup = try XCTUnwrap(
                bridgeEmissionPayload(from: emissions, event: "setup_content") as? [String: Any]
            )
            XCTAssertEqual(setup["jumpToAnchor"] as? Int, expectedOrdinal)
            XCTAssertEqual(setup["ordinalStart"] as? Int, expectedOrdinal)
            XCTAssertEqual(setup["ordinalEnd"] as? Int, expectedOrdinal)
            XCTAssertEqual(setup["osisRef"] as? String, expectedRenderedReference)

            let visibleChapter = max(1, expectedChapter)
            let visibleVerseOrdinal = try XCTUnwrap(
                manager.module(named: "KJV")?.verseOrdinal(
                    osisBookId: "Gen",
                    chapter: visibleChapter,
                    verse: 5
                )
            )
            targetController.bridge(
                targetBridge,
                didScrollToOrdinal: visibleVerseOrdinal,
                key: expectedRenderedReference,
                atChapterTop: false
            )
            XCTAssertEqual(targetController.currentChapter, visibleChapter)
            XCTAssertEqual(targetController.currentVerse, 5)
            targetController.bridge(
                targetBridge,
                didScrollToOrdinal: expectedOrdinal,
                key: expectedRenderedReference,
                atChapterTop: false
            )
            XCTAssertEqual(targetController.currentChapter, expectedChapter)
            XCTAssertEqual(targetController.currentVerse, 0)
            XCTAssertEqual(targetPageManager.bibleChapterNo, expectedChapter)
            XCTAssertEqual(targetPageManager.bibleVerseNo, 0)
        } else {
            let emissions = Array(targetScripts().dropFirst(targetActionBoundary))
            let scroll = try XCTUnwrap(
                bridgeEmissionPayload(from: emissions, event: "scroll_to_verse") as? [String: Any]
            )
            XCTAssertEqual(scroll["ordinal"] as? Int, expectedOrdinal)
            XCTAssertTrue(try bridgeEmissionPayloads(
                from: emissions, event: "add_documents"
            ).isEmpty)
        }
    }

    /**
     Verifies real SWORD commentary blocks append once and authorize their visible source route.

     - Setup: Opens Genesis 1:2 from the compressed structural commentary, then submits two
       concurrent append requests for its exact next linked block.
     - Expected result: One request receives Genesis 1:3 and commits the edge; the coalesced loser
       receives null. Visible callbacks for accepted append and prepend blocks persist local anchors,
       move shared Bible state, and promote each block's toolbar neighbors.
     - Failure meaning: Commentary infinite scroll advances before bridge acceptance, publishes a
       duplicate edge, treats local BVA as a Bible ordinal, or authorizes an unaccepted neighbor.
     */
    @MainActor
    func testSwordCommentaryInfiniteScrollAppendsAcceptedBlockAndRoutesVisiblePosition() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedCompressedCommentaryAlias(named: "SCROLLCOMM", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleBibleBook = 0
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 2
        window.pageManager = pageManager
        retainReaderWindowGraph(window)
        controller.activeWindow = window
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 2)
        controller.bridgeDidSetClientReady(bridge)
        let replacementBoundary = scripts().count
        controller.switchCommentaryDocument(to: "SCROLLCOMM")
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: replacementBoundary
        )

        let responseBoundary = scripts().count
        controller.bridge(bridge, requestMoreToEnd: 8111)
        controller.bridge(bridge, requestMoreToEnd: 8112)
        let firstResponseResult = try await awaitBridgeScript(
            from: scripts,
            after: responseBoundary,
            description: "first coalesced commentary append response"
        ) { $0.hasPrefix("bibleView.response(8111,") }
        let secondResponseResult = try await awaitBridgeScript(
            from: scripts,
            after: responseBoundary,
            description: "second coalesced commentary append response"
        ) { $0.hasPrefix("bibleView.response(8112,") }
        _ = try XCTUnwrap(firstResponseResult)
        _ = try XCTUnwrap(secondResponseResult)
        let responses = Array(scripts().dropFirst(responseBoundary)).filter {
            $0.hasPrefix("bibleView.response(8111,")
                || $0.hasPrefix("bibleView.response(8112,")
        }
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(responses.filter { $0.hasPrefix("bibleView.response(8111,") }.count, 1)
        XCTAssertEqual(responses.filter { $0.hasPrefix("bibleView.response(8112,") }.count, 1)
        XCTAssertEqual(responses.filter { $0.hasSuffix("null);") }.count, 1)
        let accepted = try XCTUnwrap(responses.first { $0.contains(#""key":"Gen.1.3""#) })
        let payload = try bridgeResponseObject(from: accepted)
        let localRange = try XCTUnwrap(payload["ordinalRange"] as? [Int])
        let localAnchor = try XCTUnwrap(localRange.last)

        let appendedPersisted = expectation(description: "accepted appended commentary persists")
        var appendedPersistCount = 0
        controller.onPersistState = {
            appendedPersistCount += 1
            appendedPersisted.fulfill()
        }
        let appendedScriptBoundary = scripts().count
        controller.bridge(
            bridge,
            didScrollToOrdinal: localAnchor,
            key: "Gen.1.3",
            atChapterTop: false
        )
        await fulfillment(of: [appendedPersisted], timeout: 2)
        XCTAssertEqual(controller.currentVerse, 3)
        XCTAssertEqual(pageManager.bibleVerseNo, 3)
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, localAnchor)
        XCTAssertTrue(controller.hasPrevious)
        XCTAssertEqual(appendedPersistCount, 1)
        XCTAssertEqual(scripts().count, appendedScriptBoundary)

        let duplicateAppendPersist = expectation(
            description: "duplicate appended commentary callback stays quiet"
        )
        duplicateAppendPersist.isInverted = true
        controller.onPersistState = { duplicateAppendPersist.fulfill() }
        controller.bridge(
            bridge,
            didScrollToOrdinal: localAnchor,
            key: "Gen.1.3",
            atChapterTop: false
        )
        await fulfillment(of: [duplicateAppendPersist], timeout: 0.4)
        XCTAssertEqual(scripts().count, appendedScriptBoundary)
        controller.onPersistState = nil

        let prependBoundary = scripts().count
        controller.bridge(bridge, requestMoreToBeginning: 8113)
        let prependResponseResult = try await awaitBridgeScript(
            from: scripts,
            after: prependBoundary,
            description: "commentary accepted prepend"
        ) { $0.hasPrefix("bibleView.response(8113,") }
        let prependResponse = try XCTUnwrap(prependResponseResult)
        let prependPayload = try bridgeResponseObject(from: prependResponse)
        XCTAssertEqual(prependPayload["key"] as? String, "Gen.1.1")
        let prependRange = try XCTUnwrap(prependPayload["ordinalRange"] as? [Int])
        let prependAnchor = try XCTUnwrap(prependRange.last)
        controller.bridge(
            bridge,
            didScrollToOrdinal: prependAnchor,
            key: "Gen.1.1",
            atChapterTop: false
        )
        XCTAssertEqual(controller.currentVerse, 1)
        XCTAssertEqual(pageManager.bibleVerseNo, 1)
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, prependAnchor)

        let boundaryResponse = scripts().count
        controller.bridge(bridge, requestMoreToBeginning: 8115)
        let boundary = try await awaitBridgeScript(
            from: scripts,
            after: boundaryResponse,
            description: "commentary lower boundary response"
        ) { $0.hasPrefix("bibleView.response(8115,") }
        XCTAssertEqual(boundary, "bibleView.response(8115, null);")

        let staleBoundary = scripts().count
        controller.bridge(bridge, requestMoreToEnd: 8114)
        let staleResponseResult = try await awaitBridgeScript(
            from: scripts,
            after: staleBoundary,
            description: "commentary block later invalidated by manager refresh"
        ) { $0.hasPrefix("bibleView.response(8114,") }
        let staleResponse = try XCTUnwrap(staleResponseResult)
        let stalePayload = try bridgeResponseObject(from: staleResponse)
        XCTAssertEqual(stalePayload["key"] as? String, "Gen.1.4")
        let staleRange = try XCTUnwrap(stalePayload["ordinalRange"] as? [Int])
        let staleAnchor = try XCTUnwrap(staleRange.last)
        manager.refresh()
        controller.bridge(
            bridge,
            didScrollToOrdinal: staleAnchor,
            key: "Gen.1.4",
            atChapterTop: false
        )
        XCTAssertEqual(controller.currentVerse, 1)
        XCTAssertEqual(pageManager.bibleVerseNo, 1)
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, prependAnchor)
    }

    /**
     Verifies replacement cancellation settles a queued commentary append and releases its lane.

     - Setup: Suspends the real preparation worker after accepting Genesis 1:1, queues an append,
       then navigates the selected commentary to verse two before releasing the worker.
     - Expected result: The obsolete Promise settles with null, the replacement publishes verse
       two at local ordinal zero, and a later append succeeds with verse three through the same
       lane.
     - Failure meaning: Cancelled adjacent work can advance the range, leave Vue waiting, overwrite
       a newer replacement, or retain the serialized worker lane.
     */
    @MainActor
    func testSwordCommentaryReplacementCancelsQueuedAppendAndLaneRecovers() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedCompressedCommentaryAlias(named: "CANCELCOMM", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let worker = DispatchQueue(label: "org.andbible.tests.commentary-adjacent-cancel")
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: worker)
        let (bridge, scripts) = makeRecordingBridge()
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
        let initialBoundary = scripts().count
        controller.switchCommentaryDocument(to: "CANCELCOMM")
        let initialEmissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: initialBoundary
        )
        let initialDocument = try XCTUnwrap(
            bridgeEmissionPayload(
                from: initialEmissions,
                event: "add_documents"
            ) as? [String: Any]
        )
        let initialRange = try XCTUnwrap(initialDocument["ordinalRange"] as? [Int])
        let initialAnchor = try XCTUnwrap(initialRange.last)
        controller.bridge(
            bridge,
            didScrollToOrdinal: initialAnchor,
            key: try XCTUnwrap(initialDocument["osisRef"] as? String),
            atChapterTop: false
        )

        worker.suspend()
        let cancellationBoundary = scripts().count
        controller.bridge(bridge, requestMoreToEnd: 8121)
        controller.navigateNext()
        worker.resume()
        let cancelled = try await awaitBridgeScript(
            from: scripts,
            after: cancellationBoundary,
            description: "cancelled commentary append"
        ) { $0.hasPrefix("bibleView.response(8121,") }
        XCTAssertEqual(cancelled, "bibleView.response(8121, null);")
        let replacement = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: cancellationBoundary
        )
        let replacementDocument = try XCTUnwrap(
            bridgeEmissionPayload(from: replacement, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(replacementDocument["key"] as? String, "Gen.1.2")
        let replacementSetup = try XCTUnwrap(
            bridgeEmissionPayload(from: replacement, event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(replacementSetup["jumpToOrdinal"] as? Int, 0)
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, 0)

        let recoveredBoundary = scripts().count
        controller.bridge(bridge, requestMoreToEnd: 8122)
        let recoveredResult = try await awaitBridgeScript(
            from: scripts,
            after: recoveredBoundary,
            description: "recovered commentary append lane"
        ) { $0.hasPrefix("bibleView.response(8122,") }
        let recovered = try XCTUnwrap(recoveredResult)
        XCTAssertTrue(recovered.contains(#""key":"Gen.1.3""#))
    }

    /** A bridge-rejected commentary response cannot advance the accepted outer edge. */
    @MainActor
    func testSwordCommentaryRejectedAppendDoesNotAdvanceAcceptedEdge() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedCompressedCommentaryAlias(named: "REJECTCOMM", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let rejectedPublication = expectation(description: "rejected append reaches publication")
        let rejectedPublicationSettled = expectation(
            description: "rejected append returns from publication"
        )
        let rejectNextPublication = CommentaryPublicationGate()
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            phaseObserver: { phase, _, key in
                guard phase == .publication,
                      key.family.rawValue == "sword-commentary",
                      rejectNextPublication.consumeIfOpen() else { return }
                rejectedPublication.fulfill()
                DispatchQueue.main.async {
                    rejectedPublicationSettled.fulfill()
                }
            }
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        let window = Window()
        window.pageManager = PageManager(id: window.id)
        retainReaderWindowGraph(window)
        controller.activeWindow = window
        controller.bridgeDidSetClientReady(bridge)
        let initialBoundary = scripts().count
        controller.switchCommentaryDocument(to: "REJECTCOMM")
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: initialBoundary
        )

        let acceptedEvaluator = bridge.javaScriptEvaluationObserver
        bridge.javaScriptEvaluationObserver = nil
        rejectNextPublication.open()
        controller.bridge(bridge, requestMoreToEnd: 8131)
        await fulfillment(
            of: [rejectedPublication, rejectedPublicationSettled],
            timeout: 3,
            enforceOrder: true
        )
        bridge.javaScriptEvaluationObserver = acceptedEvaluator

        let retryBoundary = scripts().count
        controller.bridge(bridge, requestMoreToEnd: 8132)
        let retryResult = try await awaitBridgeScript(
            from: scripts,
            after: retryBoundary,
            description: "retry after bridge-rejected commentary append"
        ) { $0.hasPrefix("bibleView.response(8132,") }
        let retry = try XCTUnwrap(retryResult)
        XCTAssertTrue(retry.contains(#""key":"Gen.1.2""#))

        controller.windowControllerWillUnregister()
        let (retiredProbeBridge, retiredProbeScripts) = makeRecordingBridge()
        controller.bridge(retiredProbeBridge, requestMoreToEnd: 8133)
        XCTAssertEqual(
            retiredProbeScripts().last,
            "bibleView.response(8133, null);"
        )
    }

    /**
     Verifies a source-Bible relock retires both pending adjacency and the earlier local viewport.

     The test accepts a real commentary anchor, relocks KJV during append capture, and proves the
     Promise settles null. After unlocking, a fresh append succeeds, but a full commentary reload
     must start at ordinal zero because the manager authorization generation changed.

     - Side effects: Mutates a temporary SWORD descriptor/cache and records bridge emissions.
     - Failure modes: Fixture I/O, source capture, and asynchronous publication can throw or time
       out; deferred cleanup always releases the capture gate.
     */
    @MainActor
    func testSwordSourceBibleRelockDuringCommentaryAppendSettlesWithoutAdvancing() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedCompressedCommentaryAlias(named: "RELOCKCOMM", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let captureEntered = expectation(description: "commentary append capture entered")
        let releaseCapture = DispatchSemaphore(value: 0)
        let blockNextCapture = CommentaryPublicationGate()
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            phaseObserver: { phase, _, key in
                guard phase == .sourceCapture,
                      key.family.rawValue == "sword-commentary",
                      blockNextCapture.consumeIfOpen() else { return }
                captureEntered.fulfill()
                _ = releaseCapture.wait(timeout: .now() + 3)
            }
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        let window = Window()
        window.pageManager = PageManager(id: window.id)
        retainReaderWindowGraph(window)
        controller.activeWindow = window
        controller.bridgeDidSetClientReady(bridge)
        let initialBoundary = scripts().count
        controller.switchCommentaryDocument(to: "RELOCKCOMM")
        let initialEmissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: initialBoundary
        )
        let initialDocument = try XCTUnwrap(
            bridgeEmissionPayload(
                from: initialEmissions,
                event: "add_documents"
            ) as? [String: Any]
        )
        let initialRange = try XCTUnwrap(initialDocument["ordinalRange"] as? [Int])
        let initialAnchor = try XCTUnwrap(initialRange.last)
        let initialKey = try XCTUnwrap(initialDocument["osisRef"] as? String)
        controller.bridge(
            bridge,
            didScrollToOrdinal: initialAnchor,
            key: initialKey,
            atChapterTop: false
        )
        XCTAssertEqual(window.pageManager?.commentaryAnchorOrdinal, initialAnchor)

        blockNextCapture.open()
        let appendBoundary = scripts().count
        controller.bridge(bridge, requestMoreToEnd: 8141)
        await fulfillment(of: [captureEntered], timeout: 3)
        var released = false
        defer {
            if !released { releaseCapture.signal() }
        }
        let configURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/kjv.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(config.contains("\nCipherKey="))
        config += "\nCipherKey=\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        let cacheURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/modules-conf.cache")
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            try FileManager.default.removeItem(at: cacheURL)
        }
        manager.refresh()
        XCTAssertEqual(manager.moduleAccessState(named: "KJV"), .locked)
        released = true
        releaseCapture.signal()

        let response = try await awaitBridgeScript(
            from: scripts,
            after: appendBoundary,
            description: "relocked commentary append response"
        ) { $0.hasPrefix("bibleView.response(8141,") }
        XCTAssertEqual(response, "bibleView.response(8141, null);")

        try config.replacingOccurrences(of: "\nCipherKey=\n", with: "\n").write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            try FileManager.default.removeItem(at: cacheURL)
        }
        manager.refresh()
        XCTAssertEqual(manager.moduleAccessState(named: "KJV"), .readable)
        let retryBoundary = scripts().count
        controller.bridge(bridge, requestMoreToEnd: 8142)
        let retryResult = try await awaitBridgeScript(
            from: scripts,
            after: retryBoundary,
            description: "commentary append after source-Bible authorization returns"
        ) { $0.hasPrefix("bibleView.response(8142,") }
        let retry = try XCTUnwrap(retryResult)
        XCTAssertTrue(retry.contains(#""key":"Gen.1.2""#))

        let roundTripBoundary = scripts().count
        XCTAssertEqual(controller.switchCommentaryDocument(to: "RELOCKCOMM"), .switched)
        let roundTrip = try await awaitBridgeEmission(
            from: scripts,
            event: "setup_content",
            after: roundTripBoundary
        )
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: roundTrip, event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(setup["jumpToOrdinal"] as? Int, 0)
        XCTAssertEqual(window.pageManager?.commentaryAnchorOrdinal, 0)
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
        let container = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: ModelContext(container))
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Commentary Typed Sync")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let pageManager = try XCTUnwrap(window.pageManager)
        windowManager.setActiveWorkspace(workspace)
        let target = try XCTUnwrap(windowManager.addWindow(from: window))
        window.pageManager?.bibleBibleBook = 0
        window.pageManager?.bibleChapterNo = 1
        window.pageManager?.bibleVerseNo = 2
        window.isSynchronized = true
        window.syncGroup = 0
        target.isSynchronized = true
        target.syncGroup = 0
        retainReaderWindowGraph(window)
        retainReaderWindowGraph(target)
        controller.activeWindow = window
        windowManager.activeWindow = window
        controller.windowManagerRef = windowManager
        XCTAssertTrue(windowManager.registerController(controller, for: window))
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
        windowManager.onSyncVerseChanged = { sourceWindow, delivery in
            let sourceOrdinal = delivery.position.sourceOrdinal
            let key = delivery.position.sourceKey
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

    /**
     Verifies Calvin's accepted sentence BVA survives a Bible/commentary category round trip only
     while the exact commentary key still owns it.

     The real Calvin fixture yields document-local ordinal 11 inside Genesis 1:24. The test accepts
     that visible callback, visits the same KJV position, and returns through the public document
     switches. Vue must receive ordinal 11 in `setup_content`. A later visit to Genesis 1:22 must
     receive zero, proving an old local ordinal cannot attach to a different commentary block. A
     recreated controller also receives zero because the raw persisted ordinal lacks a source-key
     receipt.

     - Side effects: Installs temporary SWORD fixtures and records bridge replacement emissions.
     - Failure modes: Fixture capture and asynchronous bridge publication can throw or time out.
     */
    @MainActor
    func testCalvinCommentaryRoundTripRestoresOnlyExactAcceptedLocalAnchor() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedCalvinAnnotationCommentary(named: "CALVINRESTORE", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleBibleBook = 0
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 22
        retainReaderWindowGraph(window, attaching: pageManager)
        let modelContext = try XCTUnwrap(window.modelContext)
        try modelContext.save()
        controller.activeWindow = window
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 22)
        controller.bridgeDidSetClientReady(bridge)

        var boundary = scripts().count
        controller.switchCommentaryDocument(to: "CALVINRESTORE")
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        boundary = scripts().count
        controller.bridge(bridge, requestMoreToEnd: 8191)
        let awaitedResponse = try await awaitBridgeScript(
            from: scripts,
            after: boundary,
            description: "Calvin 1:24 viewport source"
        ) { $0.hasPrefix("bibleView.response(8191,") }
        let response = try XCTUnwrap(awaitedResponse)
        let appended = try bridgeResponseObject(from: response)
        XCTAssertEqual(appended["osisRef"] as? String, "Gen.1.24")
        let range = try XCTUnwrap(appended["ordinalRange"] as? [Int])
        XCTAssertEqual(range.count, 2)
        XCTAssertTrue((range[0]...range[1]).contains(11))

        controller.bridge(
            bridge,
            didScrollToOrdinal: 11,
            key: "Gen.1.24",
            atChapterTop: false
        )
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, 11)
        XCTAssertEqual(pageManager.bibleVerseNo, 24)

        // A relationship replacement may preserve the mutable domain UUID while changing the
        // backing row. Old DOM telemetry must not mutate or authorize that new PageManager.
        let replacementPageManager = PageManager(id: window.id)
        replacementPageManager.currentCategoryName = DocumentCategory.commentary.pageManagerKey
        replacementPageManager.commentaryDocument = "CALVINRESTORE"
        replacementPageManager.commentaryAnchorOrdinal = 3
        window.modelContext?.insert(replacementPageManager)
        window.pageManager = replacementPageManager
        controller.bridge(
            bridge,
            didScrollToOrdinal: 12,
            key: "Gen.1.24",
            atChapterTop: false
        )
        XCTAssertEqual(replacementPageManager.commentaryAnchorOrdinal, 3)
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, 11)
        window.pageManager = pageManager

        boundary = scripts().count
        XCTAssertEqual(controller.switchBibleDocument(to: "KJV"), .switched)
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        boundary = scripts().count
        XCTAssertEqual(controller.switchCommentaryDocument(to: "CALVINRESTORE"), .switched)
        let restored = try await awaitBridgeEmission(
            from: scripts,
            event: "setup_content",
            after: boundary
        )
        let restoredSetup = try XCTUnwrap(
            bridgeEmissionPayload(from: restored, event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(restoredSetup["jumpToOrdinal"] as? Int, 11)

        boundary = scripts().count
        XCTAssertEqual(controller.switchBibleDocument(to: "KJV"), .switched)
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 22)
        boundary = scripts().count
        XCTAssertEqual(controller.switchCommentaryDocument(to: "CALVINRESTORE"), .switched)
        let reset = try await awaitBridgeEmission(
            from: scripts,
            event: "setup_content",
            after: boundary
        )
        let resetSetup = try XCTUnwrap(
            bridgeEmissionPayload(from: reset, event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(resetSetup["jumpToOrdinal"] as? Int, 0)
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, 0)

        // Simulate legacy/imported state that has a raw ordinal but no authoritative source receipt.
        pageManager.commentaryAnchorOrdinal = 11
        let (restoredBridge, restoredScripts) = makeRecordingBridge()
        let restoredController = BibleReaderController(
            bridge: restoredBridge,
            swordManagerOverride: manager
        )
        restoredController.activeWindow = window
        restoredController.restoreSavedPosition()
        restoredController.bridgeDidSetClientReady(restoredBridge)
        let relaunched = try await awaitBridgeEmission(
            from: restoredScripts,
            event: "setup_content",
            after: 0
        )
        let relaunchedSetup = try XCTUnwrap(
            bridgeEmissionPayload(from: relaunched, event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(relaunchedSetup["jumpToOrdinal"] as? Int, 0)
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, 0)

        controller.bridge(
            bridge,
            didScrollToOrdinal: 4,
            key: "Gen.1.22",
            atChapterTop: false
        )
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, 4)
        let deletedBook = controller.currentBook
        let deletedChapter = controller.currentChapter
        let deletedVerse = controller.currentVerse
        modelContext.delete(window)
        XCTAssertTrue(window.isDeleted)
        controller.bridge(
            bridge,
            didScrollToOrdinal: 5,
            key: "Gen.1.22",
            atChapterTop: false
        )
        XCTAssertEqual(pageManager.commentaryAnchorOrdinal, 4)
        XCTAssertEqual(controller.currentBook, deletedBook)
        XCTAssertEqual(controller.currentChapter, deletedChapter)
        XCTAssertEqual(controller.currentVerse, deletedVerse)
    }


    /** Commentary no-ops require the visible accepted route and never scroll a pending old DOM. */
    @MainActor
    func testCommentaryTypedSyncNoOpAndPendingReplacementOwnership() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedCalvinAnnotationCommentary(named: "CALVINSYNCNOOP", in: modulePath)
        let sword = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let worker = DispatchQueue(label: "org.andbible.tests.commentary-sync-noop")
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: worker)
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: container.mainContext)
        let workspace = store.createWorkspace(name: "Commentary typed sync no-op")
        let window = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let manager = WindowManager(workspaceStore: store)
        manager.setActiveWorkspace(workspace)
        manager.activeWindow = window
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: sword,
            documentPreparationCoordinator: coordinator
        )
        controller.activeWindow = window
        controller.workspaceStore = store
        controller.windowManagerRef = manager
        XCTAssertTrue(manager.registerController(controller, for: window))
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: 0)
        let commentaryBoundary = scripts().count
        XCTAssertEqual(controller.switchCommentaryDocument(to: "CALVINSYNCNOOP"), .switched)
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: commentaryBoundary
        )

        let unexpectedSettledPersistence = expectation(
            description: "settled commentary no-op does not persist"
        )
        unexpectedSettledPersistence.isInverted = true
        controller.onPersistState = { unexpectedSettledPersistence.fulfill() }
        var boundary = scripts().count
        let genesisOne = WindowSynchronizationPosition(
            sourceVersification: "KJV",
            osisBookId: "Gen",
            chapter: 1,
            verse: 1
        )
        controller.applyWindowSynchronizationPosition(genesisOne)
        XCTAssertEqual(scripts().count, boundary)
        await fulfillment(of: [unexpectedSettledPersistence], timeout: 0.6)

        let settledChangePersistence = expectation(
            description: "changed settled commentary persists shared position once"
        )
        var settledChangePersistCount = 0
        controller.onPersistState = {
            settledChangePersistCount += 1
            if settledChangePersistCount == 1 { settledChangePersistence.fulfill() }
        }
        let settledChangeBoundary = scripts().count
        controller.applyWindowSynchronizationPosition(WindowSynchronizationPosition(
            sourceVersification: "KJV",
            osisBookId: "Gen",
            chapter: 1,
            verse: 22
        ))
        XCTAssertEqual(
            scripts().dropFirst(settledChangeBoundary)
                .filter { $0.contains("emit('scroll_to_verse'") }.count,
            0
        )
        let settledChangeEmissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: settledChangeBoundary
        )
        let settledChangeDocument = try XCTUnwrap(
            bridgeEmissionPayload(
                from: settledChangeEmissions,
                event: "add_documents"
            ) as? [String: Any]
        )
        XCTAssertEqual(settledChangeDocument["key"] as? String, "Gen.1.22")
        XCTAssertEqual(settledChangeDocument["osisRef"] as? String, "Gen.1.22")
        let settledChangeFragment = try XCTUnwrap(
            settledChangeDocument["osisFragment"] as? [String: Any]
        )
        XCTAssertTrue(
            try XCTUnwrap(settledChangeFragment["xml"] as? String)
                .contains("What is the force of this benediction")
        )
        await fulfillment(of: [settledChangePersistence], timeout: 1)
        XCTAssertEqual(settledChangePersistCount, 1)

        let resetPersistence = expectation(
            description: "commentary reset shared position persists"
        )
        controller.onPersistState = { resetPersistence.fulfill() }
        let resetBoundary = scripts().count
        controller.applyWindowSynchronizationPosition(genesisOne)
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: resetBoundary
        )
        await fulfillment(of: [resetPersistence], timeout: 1)
        let unexpectedPendingPersistence = expectation(
            description: "equal pending commentary does not persist"
        )
        unexpectedPendingPersistence.isInverted = true
        controller.onPersistState = { unexpectedPendingPersistence.fulfill() }

        worker.suspend()
        boundary = scripts().count
        controller.loadCurrentContent()
        controller.applyWindowSynchronizationPosition(genesisOne)
        XCTAssertEqual(scripts().count, boundary)
        await fulfillment(of: [unexpectedPendingPersistence], timeout: 0.6)
        controller.onPersistState = nil
        worker.resume()
        _ = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: boundary)
        XCTAssertEqual(
            scripts().dropFirst(boundary).filter { $0.contains("emit('add_documents'") }.count,
            1
        )

        worker.suspend()
        boundary = scripts().count
        controller.loadCurrentContent()
        let changedPendingPersistence = expectation(
            description: "changed pending commentary persists shared position once"
        )
        var changedPendingPersistCount = 0
        controller.onPersistState = {
            changedPendingPersistCount += 1
            if changedPendingPersistCount == 1 { changedPendingPersistence.fulfill() }
        }
        controller.applyWindowSynchronizationPosition(WindowSynchronizationPosition(
            sourceVersification: "KJV",
            osisBookId: "Gen",
            chapter: 1,
            verse: 22
        ))
        XCTAssertEqual(
            scripts().dropFirst(boundary).filter { $0.contains("emit('scroll_to_verse'") }.count,
            0
        )
        XCTAssertEqual(controller.currentVerse, 22)
        worker.resume()
        let changedEmissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        let changedDocument = try XCTUnwrap(
            bridgeEmissionPayload(
                from: changedEmissions,
                event: "add_documents"
            ) as? [String: Any]
        )
        XCTAssertEqual(changedDocument["key"] as? String, "Gen.1.22")
        XCTAssertEqual(changedDocument["osisRef"] as? String, "Gen.1.22")
        let changedFragment = try XCTUnwrap(
            changedDocument["osisFragment"] as? [String: Any]
        )
        XCTAssertTrue(
            try XCTUnwrap(changedFragment["xml"] as? String)
                .contains("What is the force of this benediction")
        )
        XCTAssertEqual(
            scripts().dropFirst(boundary).filter { $0.contains("emit('add_documents'") }.count,
            1
        )
        XCTAssertEqual(controller.committedRenderState.identity?.category, .commentary)
        await fulfillment(of: [changedPendingPersistence], timeout: 1)
        XCTAssertEqual(changedPendingPersistCount, 1)
        coordinator.cancelAll()
        withExtendedLifetime((container, store, manager)) {}
    }

    /** Non-verse panes adopt the shared Bible coordinate without replacing or scrolling their DOM. */
    @MainActor
    func testDictionaryTypedSyncUpdatesSharedBiblePositionWithoutDOMMutation() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try writeRawLDModule(
            named: "SYNCDICT",
            category: "Lexicons / Dictionaries",
            description: "Synchronization dictionary",
            entries: [("G0001", "<entryFree n=\"G0001\"><p>Retained dictionary page.</p></entryFree>")],
            in: modulePath
        )
        let sword = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: container.mainContext)
        let workspace = store.createWorkspace(name: "Dictionary passive synchronization")
        let window = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let manager = WindowManager(workspaceStore: store)
        manager.setActiveWorkspace(workspace)
        manager.activeWindow = window
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: sword)
        controller.activeWindow = window
        controller.workspaceStore = store
        controller.windowManagerRef = manager
        XCTAssertTrue(manager.registerController(controller, for: window))
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: 0)
        XCTAssertEqual(
            controller.switchDictionaryDocument(to: "SYNCDICT"),
            .switchedRequiringKeySelection
        )
        let dictionaryBoundary = scripts().count
        controller.loadDictionaryEntry(key: "G0001")
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: dictionaryBoundary
        )
        let committedDictionary = controller.committedRenderState
        let pageManager = try XCTUnwrap(window.pageManager)
        XCTAssertEqual(pageManager.dictionaryDocument, "SYNCDICT")
        XCTAssertEqual(pageManager.dictionaryKey, "G0001")

        let syncBoundary = scripts().count
        let persisted = expectation(description: "dictionary shared Bible position persists once")
        var persistCount = 0
        controller.onPersistState = {
            persistCount += 1
            if persistCount == 1 { persisted.fulfill() }
        }
        controller.applyWindowSynchronizationPosition(WindowSynchronizationPosition(
            sourceVersification: "KJV",
            osisBookId: "Gen",
            chapter: 1,
            verse: 1
        ))
        controller.applyWindowSynchronizationPosition(WindowSynchronizationPosition(
            sourceVersification: "KJV",
            osisBookId: "Gen",
            chapter: 2,
            verse: 1
        ))

        XCTAssertEqual(scripts().count, syncBoundary)
        XCTAssertEqual(controller.committedRenderState, committedDictionary)
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 2)
        XCTAssertEqual(controller.currentVerse, 1)
        XCTAssertEqual(pageManager.dictionaryDocument, "SYNCDICT")
        XCTAssertEqual(pageManager.dictionaryKey, "G0001")
        await fulfillment(of: [persisted], timeout: 1)
        XCTAssertEqual(persistCount, 1)
        withExtendedLifetime((container, store, manager)) {}
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

/** Decodes the object argument from one exact `bibleView.response` test script. */
private func bridgeResponseObject(from script: String) throws -> [String: Any] {
    guard let comma = script.firstIndex(of: ","), script.hasSuffix(");") else {
        throw ReaderBridgeFixtureError.malformedBridgeResponse
    }
    let jsonStart = script.index(after: comma)
    let jsonEnd = script.index(script.endIndex, offsetBy: -2)
    let json = script[jsonStart..<jsonEnd].trimmingCharacters(in: .whitespaces)
    let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
    guard let object = value as? [String: Any] else {
        throw ReaderBridgeFixtureError.malformedBridgeResponse
    }
    return object
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
 Installs actual Calvin OSIS records in a small, real RawFiles commentary for controller testing.

 The JSON retains the public-domain CalvinCommentaries Genesis 1:22 and 1:24 source bytes, including
 milestone divs and their `Bible:` annotation references. The wrapper gives RawFiles the direct
 verse element expected by its source reader. A synthetic 1:1 entry admits Genesis through the
 Android DocumentBibleBooks opening-verse probe; without it, the walker correctly has no book to
 traverse. Synthetic 1:21/1:25/1:26 neighbors bound lookahead, while 1:23 deliberately has no index
 entry. The full compressed Calvin module is exercised by the app test.

 - Parameters:
   - moduleName: Unique descriptor name in this test's copied SWORD tree.
   - modulePath: Temporary module root owned and removed by BibleUISwordFixtureTestCase.
   - annotationForVerse24: Optional controlled replacement for its annotation attributes, used to
     contrast valid annotation ranges with the original rejected namespace. Other XML is retained.
 - Side effects: Reads the retained fixture and writes only that temporary module's files/config.
 - Failure modes: Throws for a missing/malformed fixture or filesystem error; never downloads data.
 */
private func seedCalvinAnnotationCommentary(
    named moduleName: String,
    in modulePath: String,
    annotationForVerse24: String? = nil
) throws {
    let fixturePath = "Sources/BibleUI/Tests/BibleUITests/Fixtures/calvin-commentary-genesis.json"
    let repositoryRoot = try BibleUITestSourceLocator.repositoryRoot(containing: fixturePath)
    let records = try JSONDecoder().decode(
        [String: String].self,
        from: Data(contentsOf: repositoryRoot.appendingPathComponent(fixturePath))
    )
    let preceding = "<p>Preceding bounded commentary block.</p>"
    let following = "<p>Following bounded commentary block.</p>"
    var verse24 = try XCTUnwrap(records["Gen.1.24"])
    if let annotationForVerse24 {
        verse24 = verse24.replacingOccurrences(
            of: "Bible:Gen.1.24",
            with: annotationForVerse24
        )
    }
    let entries: [(verse: Int, xml: String)] = [
        (1, "<p>Opening entry for the Android book inventory probe.</p>"),
        (21, preceding),
        (22, try XCTUnwrap(records["Gen.1.22"])),
        (24, verse24),
        (25, following),
        (26, "<p>Second following bounded commentary block.</p>"),
    ]
    let root = URL(fileURLWithPath: modulePath, isDirectory: true)
    let moduleKey = moduleName.lowercased()
    let dataDirectory = root.appendingPathComponent(
        "modules/comments/rawfiles/\(moduleKey)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    var contents = Data()
    var index = Data(repeating: 0, count: 24_115 * 6)
    for (number, entry) in entries.enumerated() {
        let fileName = String(format: "%07d", number)
        let fileNameBytes = Data(fileName.utf8)
        var row = Data()
        row.appendLittleEndianFixture(UInt32(contents.count))
        row.appendLittleEndianFixture(UInt16(fileNameBytes.count))
        // KJV RawFiles reserves four records before Genesis 1:1 (record 4).
        let rowOffset = (entry.verse + 3) * 6
        index.replaceSubrange(rowOffset..<(rowOffset + 6), with: row)
        contents.append(fileNameBytes)
        let source = "<verse osisID=\"Gen.1.\(entry.verse)\">\(entry.xml)</verse>"
        try Data(source.utf8).write(to: dataDirectory.appendingPathComponent(fileName))
    }
    try contents.write(to: dataDirectory.appendingPathComponent("ot"))
    try index.write(to: dataDirectory.appendingPathComponent("ot.vss"))
    try Data().write(to: dataDirectory.appendingPathComponent("nt"))
    try Data().write(to: dataDirectory.appendingPathComponent("nt.vss"))
    try Data(repeating: 0, count: 4).write(to: dataDirectory.appendingPathComponent("incfile"))
    try """
    [\(moduleName)]
    Description=Calvin annotation regression
    Category=Commentaries
    DataPath=./modules/comments/rawfiles/\(moduleKey)/
    ModDrv=RawFiles
    SourceType=OSIS
    Encoding=UTF-8
    Lang=en
    Versification=KJV
    """.write(
        to: root.appendingPathComponent("mods.d/\(moduleKey).conf"),
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
    /// A recorded Promise response did not contain one JSON object.
    case malformedBridgeResponse
}

private extension Data {
    /** Appends one RawLD index integer in little-endian order. */
    mutating func appendLittleEndianFixture<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
