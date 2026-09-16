// BibleBookIntroductionConsumerRegressionTests.swift -- Android book-introduction consumer parity

import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 Exercises public reader consumers after intro-inclusive versification lookup made book `0:0`
 addressable.

 The tests use Android's selected `Verse` endpoint identity (`Matt.0.0`), which is distinct from a
 `VerseRange`'s compact `osisRef` (`Matt.0`). They preserve exact source, persistence, and destination
 domains at public reader boundaries while keeping unverified speech provenance fail-closed.
 */
@MainActor
final class BibleBookIntroductionConsumerRegressionTests: BibleUISwordFixtureTestCase {
    /**
     Requires Copy/Open reference to preserve the selected book-introduction Verse.

     Android stores `CurrentPage.singleKey` directly in `BookAndKey` and copies that key's `osisRef`;
     it does not clamp chapter or verse before opening the reference. A synthetic Bible speech
     cursor without verified source-to-KJVA provenance remains fail-closed independently.

     - Side effects: Loads one isolated KJV reader state without a ready WebView client.
     - Failure modes: Fails when the menu rejects chapter zero, substitutes verse one, loses either
       ordinal domain, or turns an unverified speech cursor into a navigation reference.
     */
    func testWindowMenuPreservesSelectedBookIntroductionAndUnverifiedSpeechFailsClosed() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let sourceIntroduction = try XCTUnwrap(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Matt", chapter: 0, verse: 0),
                versification: "KJV"
            )
        )
        let kjvaIntroduction = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Matt", chapter: 0, verse: 0),
                versification: "KJVA"
            )
        )
        XCTAssertNotEqual(sourceIntroduction, kjvaIntroduction)
        let unverifiedSpeech = SpeakStreamPosition(
            id: "book-introduction",
            category: .bible,
            bookInitials: "KJV",
            key: "Matt.0.0",
            osisRef: "Matt.0.0",
            keyName: "Matthew introduction",
            bookName: "Matthew",
            ordinalStart: sourceIntroduction,
            ordinalEnd: sourceIntroduction,
            chapter: 0,
            verse: 0,
            groupIdentifier: "Matt.0.0",
            language: "en",
            versification: "KJV",
            verifiedBibleRange: nil
        )
        XCTAssertNil(BibleWindowMenuReference.speechPosition(unverifiedSpeech))

        let controller = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: manager
        )
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        retainReaderWindowGraph(window)
        controller.activeWindow = window

        controller.scrollToSynchronizedVerse(osisBookId: "Matt", chapter: 0, verse: 0)

        XCTAssertEqual(controller.currentBook, "Matthew")
        XCTAssertEqual(controller.currentChapter, 0)
        XCTAssertEqual(controller.currentVerse, 0)
        let reference = try XCTUnwrap(
            controller.windowMenuReference(),
            "Android keeps the selected book-introduction Verse as the shared BookAndKey"
        )
        XCTAssertEqual(reference.bibleReference?.chapter, 0)
        XCTAssertEqual(reference.bibleReference?.verse, 0)
        XCTAssertEqual(reference.bibleReference?.sourceOsisRef, "Matt.0.0")
        guard case .bible(let target) = reference.navigationTarget else {
            return XCTFail("Expected an exact Bible navigation target")
        }
        XCTAssertEqual(target.sourceOrdinalRange, sourceIntroduction...sourceIntroduction)
        XCTAssertEqual(target.sourceOSISReference, "Matt.0.0")
        XCTAssertEqual(target.kjvaOrdinalRange, kjvaIntroduction...kjvaIntroduction)
        XCTAssertEqual(target.kjvaOSISReference, "Matt.0.0")
    }

    /**
     Requires a trusted Android bookmark at a book introduction to remain navigable.

     Android reconstructs both persisted ordinals as `Verse` values and publishes
     `bookmark.verseRange.start.osisID`; `MainBibleActivity` then parses that exact `Matt.0.0` key.

     - Side effects: Reads an isolated KJV module while resolving and planning one detached target.
     - Failure modes: Fails when the list resolver or planner treats a valid structural endpoint as
       corrupt, rewrites it to Matthew 1:1, or drops source/KJVA/destination identity.
     */
    func testTrustedAndroidBookmarkNavigatesExactBookIntroduction() async throws {
        let container = try makeBookmarkListModelContainer()
        let modelContext = ModelContext(container)
        defer { withExtendedLifetime(modelContext) {} }
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let sourceIntroduction = try XCTUnwrap(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Matt", chapter: 0, verse: 0),
                versification: "KJV"
            )
        )
        let kjvaIntroduction = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Matt", chapter: 0, verse: 0),
                versification: "KJVA"
            )
        )
        XCTAssertNotEqual(sourceIntroduction, kjvaIntroduction)
        let bookmark = BibleBookmark(
            kjvOrdinalStart: kjvaIntroduction,
            kjvOrdinalEnd: kjvaIntroduction,
            ordinalStart: sourceIntroduction,
            ordinalEnd: sourceIntroduction,
            v11n: "KJV",
            bookInitials: "KJV",
            ordinalTrustMetadata: PersistedOrdinalTrustPolicy.androidImportMetadata(
                sourceVersification: "KJV",
                sourceOrdinalStart: sourceIntroduction,
                sourceOrdinalEnd: sourceIntroduction,
                kjvaOrdinalStart: kjvaIntroduction,
                kjvaOrdinalEnd: kjvaIntroduction
            )
        )

        modelContext.insert(bookmark)
        let target = try BookmarkNavigationTargetResolver.resolve(bookmark)
        guard case .bible(let resolved) = target else {
            return XCTFail("Expected a Bible bookmark target")
        }
        XCTAssertEqual(resolved.sourceOrdinalRange, sourceIntroduction...sourceIntroduction)
        XCTAssertEqual(resolved.sourceOSISReference, "Matt.0.0")
        XCTAssertEqual(resolved.kjvaOrdinalRange, kjvaIntroduction...kjvaIntroduction)
        XCTAssertEqual(resolved.kjvaOSISReference, "Matt.0.0")

        let inventory = BibleReaderBookmarkNavigationInventory(
            destinationBible: module,
            swordModules: [module],
            myDocuments: [],
            myDocumentStore: nil,
            epubReaders: []
        )
        let commit = try BibleReaderBookmarkNavigationCoordinator().plan(
            target: target,
            inventory: inventory
        )
        guard case .bible(let plan) = commit else {
            return XCTFail("Expected a Bible commit plan")
        }
        let expected = BibleReaderBookmarkNavigationVerseAddress(
            osisBookID: "Matt",
            chapter: 0,
            verse: 0
        )
        XCTAssertEqual(plan.sourceVerses.map(\.reference), [expected])
        XCTAssertEqual(plan.kjvaVerses.map(\.reference), [expected])
        XCTAssertEqual(plan.destinationVerses.map(\.reference), [expected])
        XCTAssertEqual(plan.destinationOrdinalRange, sourceIntroduction...sourceIntroduction)
        XCTAssertEqual(plan.destinationOSISReference, "Matt.0.0")

        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager
        )
        var displaySettings = TextDisplaySettings.appDefaults
        displaySettings.showSectionTitles = true
        controller.displaySettings = displaySettings
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count

        try controller.navigate(toBookmarkTarget: target)

        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "setup_content",
            after: baseline
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(controller.activeModuleName, "KJV")
        XCTAssertEqual(controller.currentBook, "Matthew")
        XCTAssertEqual(controller.currentChapter, 0)
        XCTAssertEqual(controller.currentVerse, 0)
        XCTAssertEqual(document["bookInitials"] as? String, "KJV")
        XCTAssertEqual(setup["bookInitials"] as? String, "KJV")
        XCTAssertEqual(setup["osisRef"] as? String, "Matt.0-Matt.1")
        XCTAssertEqual(setup["ordinalStart"] as? Int, sourceIntroduction)
        XCTAssertEqual(setup["ordinalEnd"] as? Int, sourceIntroduction)
    }

    /**
     Opens the window-menu reference captured at a book introduction without clamping its Verse.

     Android stores the exact `CurrentPage.singleKey` endpoint in `BookAndKey`, while the loaded
     Bible document remains the intro-inclusive first-chapter range. Moving away before opening the
     retained menu value proves the action uses that endpoint rather than the later pane position.

     - Side effects: Mutates one isolated reader and publishes one bridge replacement after the
       exact menu action is accepted.
     - Failure modes: Fails when menu routing clamps Matthew 0:0 to verse one, loses its ordinal
       selection, or conflates the selected endpoint with the rendered whole-chapter range.
     */
    func testWindowMenuOpenReturnsToExactBookIntroduction() async throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let sourceIntroduction = try XCTUnwrap(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Matt", chapter: 0, verse: 0),
                versification: "KJV"
            )
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        var displaySettings = TextDisplaySettings.appDefaults
        displaySettings.showSectionTitles = true
        controller.displaySettings = displaySettings
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        retainReaderWindowGraph(window)
        controller.activeWindow = window

        controller.scrollToSynchronizedVerse(osisBookId: "Matt", chapter: 0, verse: 0)
        let reference = try XCTUnwrap(controller.windowMenuReference())
        XCTAssertEqual(reference.bibleReference?.sourceOsisRef, "Matt.0.0")
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        XCTAssertEqual(controller.currentVerse, 1)

        try controller.navigateToWindowMenuReference(reference)

        XCTAssertEqual(controller.currentBook, "Matthew")
        XCTAssertEqual(controller.currentChapter, 0)
        XCTAssertEqual(controller.currentVerse, 0)
        XCTAssertEqual(pageManager.bibleChapterNo, 0)
        XCTAssertEqual(pageManager.bibleVerseNo, 0)
        controller.bridgeDidSetClientReady(bridge)
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "setup_content",
            after: 0
        )
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(setup["osisRef"] as? String, "Matt.0-Matt.1")
        XCTAssertEqual(setup["ordinalStart"] as? Int, sourceIntroduction)
        XCTAssertEqual(setup["ordinalEnd"] as? Int, sourceIntroduction)
    }

    /**
     Renders only the selected book introduction when section titles are disabled.

     Android's `getWholeChapter` keeps `Matt.0` as an intro-only range when `showIntros` is false;
     it must not expand the document into chapter one merely because the selected endpoint is 0:0.

     - Side effects: Publishes one real KJV replacement through a recording bridge.
     - Failure modes: Fails when the rendered key expands to Matthew 1, its ordinal range includes
       positive verses, or the setup/highlight no longer owns the exact selected introduction.
     */
    func testBookIntroductionWithoutSectionTitlesRendersIntroOnlyDocument() async throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let introduction = try XCTUnwrap(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Matt", chapter: 0, verse: 0),
                versification: "KJV"
            )
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        var displaySettings = TextDisplaySettings.appDefaults
        displaySettings.showSectionTitles = false
        controller.displaySettings = displaySettings
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        retainReaderWindowGraph(window)
        controller.activeWindow = window
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(from: scripts, event: "setup_content", after: 0)
        let boundary = scripts().count

        XCTAssertTrue(controller.navigateTo(book: "Matthew", chapter: 0, verse: 0))

        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "setup_content",
            after: boundary
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        let fragment = try XCTUnwrap(document["osisFragment"] as? [String: Any])
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "setup_content") as? [String: Any]
        )
        let xml = try XCTUnwrap(fragment["xml"] as? String)

        XCTAssertEqual(controller.currentBook, "Matthew")
        XCTAssertEqual(controller.currentChapter, 0)
        XCTAssertEqual(controller.currentVerse, 0)
        XCTAssertEqual(pageManager.bibleChapterNo, 0)
        XCTAssertEqual(pageManager.bibleVerseNo, 0)
        XCTAssertEqual(document["key"] as? String, "Matt.0")
        XCTAssertEqual(document["osisRef"] as? String, "Matt.0")
        XCTAssertEqual(document["annotateRef"] as? String, "Matt.0")
        XCTAssertEqual(document["ordinalRange"] as? [Int], [introduction, introduction])
        XCTAssertEqual(fragment["key"] as? String, "KJV--Matt.0")
        XCTAssertEqual(fragment["osisRef"] as? String, "Matt.0")
        XCTAssertEqual(fragment["ordinalRange"] as? [Int], [introduction, introduction])
        XCTAssertFalse(xml.contains("osisID=\"Matt.1.1\""))
        XCTAssertEqual(setup["osisRef"] as? String, "Matt.0")
        XCTAssertEqual(setup["jumpToAnchor"] as? Int, introduction)
        XCTAssertEqual(setup["ordinalStart"] as? Int, introduction)
        XCTAssertEqual(setup["ordinalEnd"] as? Int, introduction)
        XCTAssertEqual(setup["highlight"] as? Bool, true)
    }

    /**
     Restores a durable book-introduction selection and its exact viewport after controller launch.

     Android persists the selected `Verse` separately from the whole-chapter document key. A saved
     Matthew 0:0 must therefore restore native PageManager state at zero and emit its exact intro
     ordinal when the rebuilt first-chapter document becomes ready.

     - Side effects: Restores one in-memory PageManager and publishes one bridge replacement.
     - Failure modes: Fails when durable zero is treated as absent, clamped to verse one, or rebuilt
       at the chapter top instead of the saved book-introduction ordinal.
     */
    func testDurableBookIntroductionRestoresExactViewport() async throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let matthewIndex = try XCTUnwrap(
            module.getBookList().firstIndex(where: { $0.osisId == "Matt" })
        )
        let sourceIntroduction = try XCTUnwrap(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Matt", chapter: 0, verse: 0),
                versification: "KJV"
            )
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        var displaySettings = TextDisplaySettings.appDefaults
        displaySettings.showSectionTitles = true
        controller.displaySettings = displaySettings
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleDocument = "KJV"
        pageManager.currentCategoryName = DocumentCategory.bible.pageManagerKey
        pageManager.bibleBibleBook = matthewIndex
        pageManager.bibleChapterNo = 0
        pageManager.bibleVerseNo = 0
        window.pageManager = pageManager
        retainReaderWindowGraph(window)
        controller.activeWindow = window

        controller.restoreSavedPosition()

        XCTAssertEqual(controller.currentBook, "Matthew")
        XCTAssertEqual(controller.currentChapter, 0)
        XCTAssertEqual(controller.currentVerse, 0)
        XCTAssertEqual(pageManager.bibleChapterNo, 0)
        XCTAssertEqual(pageManager.bibleVerseNo, 0)
        controller.bridgeDidSetClientReady(bridge)
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "setup_content",
            after: 0
        )
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(setup["jumpToOrdinal"] as? Int, sourceIntroduction)
    }

    /**
     Preserves JSword's interior chapter-introduction element in a normal cross-chapter bookmark.

     Android `VerseRange.iterator()` advances with `Versification.next`, so Genesis 2:0 remains
     addressable between Genesis 1:31 and Genesis 2:1. Exact book-introduction endpoint support must
     not remove that established structural element or duplicate it at the range boundaries.

     - Side effects: Reads an isolated KJV module and plans one real cross-chapter target.
     - Failure modes: Fails when planning drops Genesis 2:0, invents another structural verse,
       changes ordering, or maps any source/KJVA/destination table inconsistently.
     */
    func testCrossChapterBookmarkPlanRetainsInteriorChapterIntroduction() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let sourceStart = try XCTUnwrap(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 1, verse: 31),
                versification: "KJV"
            )
        )
        let sourceEnd = try XCTUnwrap(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 2, verse: 1),
                versification: "KJV"
            )
        )
        let kjvaStart = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 1, verse: 31),
                versification: "KJVA"
            )
        )
        let kjvaEnd = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 2, verse: 1),
                versification: "KJVA"
            )
        )
        let target = BookmarkNavigationTarget.bible(.init(
            sourceModuleInitials: "KJV",
            sourceVersification: "KJV",
            sourceOrdinalRange: sourceStart...sourceEnd,
            sourceOSISReference: "Gen.1.31-Gen.2.1",
            kjvaOrdinalRange: kjvaStart...kjvaEnd,
            kjvaOSISReference: "Gen.1.31-Gen.2.1"
        ))
        let inventory = BibleReaderBookmarkNavigationInventory(
            destinationBible: module,
            swordModules: [module],
            myDocuments: [],
            myDocumentStore: nil,
            epubReaders: []
        )

        let result = try BibleReaderBookmarkNavigationCoordinator().plan(
            target: target,
            inventory: inventory
        )

        guard case .bible(let plan) = result else {
            return XCTFail("Expected a Bible commit plan")
        }
        let expected = [
            BibleReaderBookmarkNavigationVerseAddress(
                osisBookID: "Gen", chapter: 1, verse: 31
            ),
            BibleReaderBookmarkNavigationVerseAddress(
                osisBookID: "Gen", chapter: 2, verse: 0
            ),
            BibleReaderBookmarkNavigationVerseAddress(
                osisBookID: "Gen", chapter: 2, verse: 1
            ),
        ]
        XCTAssertEqual(plan.sourceVerses.map(\.reference), expected)
        XCTAssertEqual(plan.kjvaVerses.map(\.reference), expected)
        XCTAssertEqual(plan.destinationVerses.map(\.reference), expected)
    }

    /**
     Preserves Android `ClientAiDocMarker` projection at an exact target book introduction.

     - Side effects: Reads pinned KJVA and KJV versification data only.
     - Failure modes: Fails when the marker publishes fallback ordinal zero, retains the KJVA
       number in the target domain, or loses the structural reference during the round trip.
     */
    func testMyDocumentMarkerPublishesExactTargetBookIntroductionOrdinal() throws {
        let kjvaIntroduction = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Matt", chapter: 0, verse: 0),
                versification: "KJVA"
            )
        )
        let targetIntroduction = try XCTUnwrap(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Matt", chapter: 0, verse: 0),
                versification: "KJV"
            )
        )
        XCTAssertNotEqual(kjvaIntroduction, targetIntroduction)
        let marker = MyDocumentAIDocMarker(
            pageId: UUID(),
            documentId: UUID(),
            documentInitials: "AIDocuments",
            pageTitle: "Generated page",
            pageKey: "Generated page",
            kjvOrdinalStart: kjvaIntroduction,
            kjvOrdinalEnd: kjvaIntroduction,
            sourcePromptId: nil,
            sourceBookInitials: "KJV",
            sourceBookKey: "Matt.0.0"
        )

        let payload = BibleReaderMyDocumentCoordinator.markerJSON(
            marker,
            targetVersification: "KJV"
        )

        XCTAssertGreaterThan(targetIntroduction, 0)
        XCTAssertEqual(payload["ordinalRange"] as? [Int], [targetIntroduction, targetIntroduction])
        XCTAssertEqual(
            SwordVersification.reference(forIndex: targetIntroduction, versification: "KJV"),
            .init(osisBookId: "Matt", chapter: 0, verse: 0)
        )
    }

    /**
     Normalizes a non-KJVA source book introduction to Android's visible My Notes first verse.

     Android accepts the source `Verse`, expands its chapter with introductions disabled, then
     `VerseRange.toV11n(KJVA)` clamps the structural endpoint to Genesis 1:1 for the fake My Notes
     document and jump target.

     - Side effects: Loads one isolated reader, publishes a My Notes document, and records bridge
       output after an explicit causal boundary.
     - Failure modes: Fails when the route rejects the valid source ordinal, emits source-domain
       ordinal 0/2, opens a different chapter, or loses the accepted My Notes state.
     */
    func testNonKJVAMyNotesBookIntroductionNormalizesToFirstVerse() async throws {
        let sourceIntroduction = try XCTUnwrap(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 0, verse: 0),
                versification: "Vulg"
            )
        )
        let expectedKJVA = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1)
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let paneOwner = try registerMyNotesPaneOwner(controller)
        defer { withExtendedLifetime(paneOwner) {} }
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: 0)
        let boundary = scripts().count

        controller.loadMyNotesDocument(v11nName: "Vulg", sourceOrdinal: sourceIntroduction)

        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "setup_content",
            after: boundary
        )
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "setup_content") as? [String: Any]
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        let ordinalRange = try XCTUnwrap(document["ordinalRange"] as? [Int])

        XCTAssertTrue(controller.showingMyNotes)
        XCTAssertEqual(setup["jumpToOrdinal"] as? Int, expectedKJVA)
        XCTAssertEqual(document["type"] as? String, "notes")
        XCTAssertTrue(ordinalRange.contains(expectedKJVA))
        XCTAssertEqual(
            JSwordKJVAVersification.referenceIncludingIntroductions(ordinal: expectedKJVA)?.chapter,
            1
        )
        XCTAssertEqual(
            JSwordKJVAVersification.referenceIncludingIntroductions(ordinal: expectedKJVA)?.verse,
            1
        )
    }
}
