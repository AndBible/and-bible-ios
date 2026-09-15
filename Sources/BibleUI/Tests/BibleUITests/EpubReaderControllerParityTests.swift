import AVFoundation
import Foundation
import SwiftData
import SwordKit
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView

/**
 End-to-end controller tests for EPUBs presented through Android's general-book contract.

 Each test installs a real EPUB ZIP into the app library, restores or navigates a reader controller,
 and inspects both durable `PageManager` state and the emitted Vue payload. This catches regressions
 that adapter-only tests cannot see, including reintroduction of iOS-only EPUB identity fields.
 */
@MainActor
final class EpubReaderControllerParityTests: BibleUISwordFixtureTestCase {
    /**
     Preserves Android startup admission when an EPUB and My Documents row share one initials token.

     - Setup: Installs a real EPUB, inserts a local My Documents page with the same initials/key,
       and asks the bookmark planner for that persisted generic destination. Android registers EPUB
       books before `MyDocumentBookManager.registerAllDocuments` in `CommonUtils.initializeApp`.
     - Expected result: The combined registry exposes only the EPUB candidate and the detached plan
       contains authored EPUB content rather than the colliding local Markdown body.
     - Failure meaning: Bookmark navigation has replaced global registration ownership with parallel
       exact lookups, making backend selection ambiguous or registration-order-dependent.
     - Side effects: Installs and deletes one default-library EPUB and uses an in-memory SwiftData
       graph; no reader pane or WebView state is mutated.
     */
    func testBookmarkInventoryAdmitsEpubBeforeCollidingMyDocument() throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let epubContent = try XCTUnwrap(reader.content(forKey: "1"))

        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let document = MyDocument(name: "Colliding local document", initials: reader.initials)
        let page = MyDocumentPage(title: "Local page", pageKey: "1", contentType: .markdown)
        let content = MyDocumentPageContent(pageId: page.id, content: "Private local collision")
        context.insert(document)
        context.insert(page)
        context.insert(content)
        page.pageContent = content
        page.document = document
        try context.save()

        let controller = BibleReaderController(bridge: BibleBridge(), initializesSword: false)
        controller.myDocumentStore = MyDocumentStore(modelContext: context)
        let target = BookmarkNavigationTarget.generic(.init(
            moduleInitials: reader.initials,
            key: "1",
            ordinalRange: nil
        ))

        let inventory = try controller.bookmarkNavigationInventory(for: target)
        XCTAssertTrue(inventory.myDocumentCandidates.isEmpty)
        XCTAssertEqual(inventory.epubCandidates.count, 1)
        let plan = try BibleReaderBookmarkNavigationCoordinator().plan(
            target: target,
            inventory: inventory
        )
        guard case .epub(let epubPlan) = plan else {
            return XCTFail("Expected EPUB to own the colliding local bookmark identity")
        }
        XCTAssertEqual(epubPlan.identifier, identifier)
        XCTAssertEqual(epubPlan.moduleInitials, reader.initials)
        XCTAssertEqual(epubPlan.content.html, epubContent.html)
        XCTAssertFalse(epubPlan.content.html.contains("Private local collision"))
    }

    /**
     Preserves EPUB-before-My Documents ownership in the generic speech entry point.

     - Setup: Installs one EPUB and persists a My Documents page with the same initials/key, then
       activates the EPUB and requests the default generic speech session.
     - Expected: The materialized unit contains EPUB text and never the shadowed local page body.
     - Failure meaning: Speech reconstructs parallel local candidates or resolves exact My Documents
       initials before replaying Android's EPUB-first registration admission.
     - Side effects: Installs/deletes one temporary EPUB and writes an in-memory SwiftData graph;
       no speech utterance is submitted to the platform.
     */
    func testGenericSpeechAdmitsEpubBeforeCollidingMyDocument() async throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))

        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let document = MyDocument(name: "Shadowed speech document", initials: reader.initials)
        let page = MyDocumentPage(title: "Local page", pageKey: "1", contentType: .markdown)
        let content = MyDocumentPageContent(pageId: page.id, content: "Private local collision")
        context.insert(document)
        context.insert(page)
        context.insert(content)
        page.pageContent = content
        page.document = document
        try context.save()

        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        controller.myDocumentStore = MyDocumentStore(modelContext: context)
        controller.switchEpub(identifier: identifier)
        let boundary = scripts().count
        controller.loadEpubEntry(key: "1")
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        let service = SpeakService()
        let session = try XCTUnwrap(controller.defaultSpeechSession(service: service))
        let unit = try XCTUnwrap(session.provider.currentUnit(settings: service.settings))
        let spokenText = unit.commands.compactMap(\.spokenText).joined(separator: " ")

        XCTAssertEqual(unit.position.bookInitials, reader.initials)
        XCTAssertTrue(spokenText.contains("First section"))
        XCTAssertFalse(spokenText.contains("Private local collision"))
    }

    /**
     Rejects a deferred EPUB speech callback when a native owner appears after session creation.

     - Setup: Builds and starts an EPUB page session, publishes a colliding locked native book,
       refreshes the controller registry, and moves the pane back to its Bible baseline.
     - Expected result: The fresh speech-owner gate invokes no downstream content operation; the
       queued second-page callback leaves reader, PageManager, persistence, and bridge state exact.
     - Failure meaning: A stale speech closure can read or reactivate a locally shadowed EPUB after
       Android's global registry has transferred ownership to an installed document.
     - Side effects: Installs/deletes one temporary EPUB, mutates one temporary SWORD fixture, and
       records synthetic speech/bridge operations without platform audio.
     */
    func testDeferredEpubSpeechSynchronizationRejectsNewOwnerWithoutReadOrMutation() async throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = makeWindow(category: DocumentCategory.bible.pageManagerKey)
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        controller.switchEpub(identifier: identifier)
        let epubBoundary = recordedScripts().count
        controller.loadEpubEntry(key: "1")
        _ = try await awaitBridgeEmission(
            from: recordedScripts,
            event: "add_documents",
            after: epubBoundary
        )

        let service = SpeakService(synthesizer: EpubParitySpeechSynthesizer())
        let session = try XCTUnwrap(controller.defaultSpeechSession(service: service))
        XCTAssertTrue(service.start(provider: session.provider, callbacks: session.callbacks).succeeded)
        await Task.yield()
        await Task.yield()

        let lateOwnerInitials = "LateEpubSpeechOwner"
        try seedBibleAliasModule(
            named: lateOwnerInitials,
            description: reader.initials,
            in: modulePath
        )
        let moduleCacheURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/modules-conf.cache")
        if FileManager.default.fileExists(atPath: moduleCacheURL.path) {
            try FileManager.default.removeItem(at: moduleCacheURL)
        }
        controller.refreshInstalledSourceInventoryForAuthoritativeSelection()
        XCTAssertEqual(
            controller.registeredInstalledModuleInfo(named: reader.initials)?.name,
            lateOwnerInitials
        )
        XCTAssertNil(controller.localGeneralBookDocument(named: reader.initials))
        XCTAssertEqual(controller.switchBibleDocument(to: "KJV"), .switched)

        let baselineCategory = controller.currentCategory
        let baselineBible = controller.activeModuleName
        let baselineEpubIdentifier = controller.activeEpubIdentifier
        let baselineGeneralBook = controller.activeGeneralBookModuleName
        let baselineGeneralBookKey = controller.currentGeneralBookKey
        let baselinePageCategory = window.pageManager?.currentCategoryName
        let baselinePageBible = window.pageManager?.bibleDocument
        let baselinePageGeneralBook = window.pageManager?.generalBookDocument
        let baselinePageGeneralKey = window.pageManager?.generalBookKey
        let baselineScriptCount = recordedScripts().count
        var downstreamReadOrMutationCount = 0

        XCTAssertFalse(controller.withFreshAuthorizedEpubSpeechReader(reader) { admittedReader in
            downstreamReadOrMutationCount += 1
            _ = admittedReader.content(forKey: "2")
        })
        XCTAssertEqual(downstreamReadOrMutationCount, 0)

        service.nextUnit()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertEqual(controller.activeModuleName, baselineBible)
        XCTAssertEqual(controller.activeEpubIdentifier, baselineEpubIdentifier)
        XCTAssertEqual(controller.activeGeneralBookModuleName, baselineGeneralBook)
        XCTAssertEqual(controller.currentGeneralBookKey, baselineGeneralBookKey)
        XCTAssertEqual(window.pageManager?.currentCategoryName, baselinePageCategory)
        XCTAssertEqual(window.pageManager?.bibleDocument, baselinePageBible)
        XCTAssertEqual(window.pageManager?.generalBookDocument, baselinePageGeneralBook)
        XCTAssertEqual(window.pageManager?.generalBookKey, baselinePageGeneralKey)
        XCTAssertEqual(recordedScripts().count, baselineScriptCount)
    }

    /**
     Preserves deferred EPUB speech navigation while the captured generation remains globally owned.

     - Setup: Positions a two-page EPUB speech session at the first page's final addressable ordinal,
       switches the pane to KJV, then advances speech once without adding any competing installed or
       local registration. Android's `ONE_VERSE` transport advances one BVA ordinal, so the fixture
       starts at the page boundary to exercise deferred cross-page synchronization with one action.
     - Expected result: Fresh authorization admits one downstream content read and the real callback
       reactivates the same EPUB generation at its second numeric key.
     - Failure meaning: The stale-owner guard suppresses valid Android EPUB speech synchronization.
     - Side effects: Installs/deletes one temporary EPUB and records synthetic speech/bridge output.
     */
    func testDeferredEpubSpeechSynchronizationKeepsUnownedLocalSuccess() async throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = makeWindow(category: DocumentCategory.bible.pageManagerKey)
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        controller.switchEpub(identifier: identifier)
        let initialBoundary = recordedScripts().count
        controller.loadEpubEntry(key: "1")
        _ = try await awaitBridgeEmission(
            from: recordedScripts,
            event: "add_documents",
            after: initialBoundary
        )

        let service = SpeakService(synthesizer: EpubParitySpeechSynthesizer())
        let session = try XCTUnwrap(controller.defaultSpeechSession(service: service))
        let firstContent = try XCTUnwrap(reader.content(forKey: "1"))
        let maximumSetupSteps = firstContent.ordinalRange.count
        for _ in 0..<maximumSetupSteps
            where session.provider.currentPosition?.ordinalStart
                != firstContent.ordinalRange.upperBound {
            XCTAssertTrue(session.provider.forward(.oneUnit))
        }
        XCTAssertEqual(
            session.provider.currentPosition?.ordinalStart,
            firstContent.ordinalRange.upperBound
        )
        XCTAssertTrue(service.start(provider: session.provider, callbacks: session.callbacks).succeeded)
        try await awaitReaderCondition("EPUB speech starts on numeric key 1") {
            service.currentPosition?.key == "1"
                && service.currentPosition?.ordinalStart == firstContent.ordinalRange.upperBound
        }
        XCTAssertEqual(controller.switchBibleDocument(to: "KJV"), .switched)
        let baselineScriptCount = recordedScripts().count
        var authorizedReadCount = 0

        XCTAssertTrue(controller.withFreshAuthorizedEpubSpeechReader(reader) { admittedReader in
            authorizedReadCount += 1
            XCTAssertNotNil(admittedReader.content(forKey: "2"))
        })
        XCTAssertEqual(authorizedReadCount, 1)

        service.nextUnit()
        _ = try await awaitBridgeEmission(
            from: recordedScripts,
            event: "add_documents",
            after: baselineScriptCount
        )

        XCTAssertEqual(service.currentPosition?.key, "2")
        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.activeEpubIdentifier, identifier)
        XCTAssertEqual(
            controller.activeEpubReader?.generationIdentifier,
            reader.generationIdentifier
        )
        XCTAssertEqual(controller.activeGeneralBookModuleName, reader.initials)
        XCTAssertEqual(controller.currentGeneralBookKey, "2")
        XCTAssertEqual(window.pageManager?.generalBookDocument, reader.initials)
        XCTAssertEqual(window.pageManager?.generalBookKey, "2")
        XCTAssertGreaterThan(recordedScripts().count, baselineScriptCount)
    }

    /**
     Restores an EPUB from Android-compatible general-book state and renders its exact numeric key.

     Setup installs a two-spine EPUB, persists the second numeric fragment key under the EPUB's
     module initials, and creates a controller without SWORD initialization. The expected result is
     a `GENERAL_BOOK` native-HTML payload whose key, initials, and ordinal range come from that exact
     indexed fragment. A failure means cold-start restore can select the wrong section or leak the
     former iOS-only EPUB identity into the reader contract.
     */
    func testRestoreUsesGeneralBookIdentityAndRendersPersistedNumericKey() async throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let expected = try XCTUnwrap(reader.content(forKey: "2"))
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        let window = makeWindow(
            category: DocumentCategory.generalBook.pageManagerKey,
            generalBookDocument: reader.initials,
            generalBookKey: expected.persistedKey
        )
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window

        controller.restoreSavedPosition()
        let boundary = recordedScripts().count
        controller.loadCurrentContent()
        let emissions = try await awaitBridgeEmission(
            from: recordedScripts,
            event: "add_documents",
            after: boundary
        )

        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.activeGeneralBookModuleName, reader.initials)
        XCTAssertEqual(controller.activeEpubIdentifier, identifier)
        XCTAssertEqual(controller.currentGeneralBookKey, expected.persistedKey)
        XCTAssertNil(window.pageManager?.epubIdentifier)
        XCTAssertNil(window.pageManager?.epubHref)

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["bookInitials"] as? String, reader.initials)
        XCTAssertEqual(payload["bookCategory"] as? String, DocumentCategory.generalBook.rawValue)
        XCTAssertEqual(payload["bookName"] as? String, reader.title)
        XCTAssertEqual(payload["key"] as? String, expected.persistedKey)
        XCTAssertEqual(payload["isNativeHtml"] as? Bool, true)
        XCTAssertEqual(
            payload["ordinalRange"] as? [Int],
            [expected.ordinalRange.lowerBound, expected.ordinalRange.upperBound]
        )
        let fragment = try XCTUnwrap(payload["osisFragment"] as? [String: Any])
        XCTAssertEqual(fragment["key"] as? String, "\(reader.initials)--\(expected.persistedKey)")
        XCTAssertEqual(fragment["keyName"] as? String, expected.title)
        XCTAssertEqual(fragment["bookInitials"] as? String, reader.initials)
    }

    /**
     Adopts an explicitly rebuilt EPUB generation without losing Android general-book position.

     The controller opens the second numeric key, BibleCore atomically publishes a replacement
     index generation, and the controller adopts it through the same activation contract used by
     ordinary EPUB switching. The current key and PageManager identity must remain exact. A reader
     from a separately installed EPUB must be rejected without changing the adopted generation.
     Failure means Rebuild index can jump content, leave resource URLs on a pruned generation, or
     replace the active pane after a stale cross-document callback.
     */
    func testRebuiltEpubGenerationAdoptionPreservesKeyAndRejectsDifferentDocument() async throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        let window = makeWindow(category: DocumentCategory.bible.pageManagerKey)
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        controller.switchEpub(identifier: identifier)
        let boundary = scripts().count
        controller.loadEpubEntry(key: "2")
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        let originalGeneration = try XCTUnwrap(controller.activeEpubReader).generationIdentifier

        let rebuiltReader = try EpubReader.rebuildSearchIndex(identifier: identifier)

        XCTAssertTrue(controller.adoptRebuiltEpubReader(rebuiltReader))
        XCTAssertNotEqual(rebuiltReader.generationIdentifier, originalGeneration)
        XCTAssertEqual(
            controller.activeEpubReader?.generationIdentifier,
            rebuiltReader.generationIdentifier
        )
        XCTAssertEqual(controller.currentGeneralBookKey, "2")
        XCTAssertEqual(window.pageManager?.generalBookDocument, rebuiltReader.initials)
        XCTAssertEqual(window.pageManager?.generalBookKey, "2")

        let foreignArchiveURL = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: foreignArchiveURL.deletingLastPathComponent())
        }
        let foreignIdentifier = try installDefaultLibraryEpubFixture(epubURL: foreignArchiveURL)
        defer { try? EpubReader.delete(identifier: foreignIdentifier) }
        let foreignReader = try XCTUnwrap(EpubReader(identifier: foreignIdentifier))

        XCTAssertFalse(controller.adoptRebuiltEpubReader(foreignReader))
        XCTAssertEqual(
            controller.activeEpubReader?.generationIdentifier,
            rebuiltReader.generationIdentifier
        )
        XCTAssertEqual(controller.currentGeneralBookKey, "2")
    }

    /**
    Migrates legacy EPUB fields into Android's durable general-book identity and canonical key.

    Setup persists the legacy package identifier and an XHTML href with an anchor while the reader
    client is not ready. Restore first persists that unresolved selection without reading the EPUB
    index on the main actor. The ordinary async content load then resolves and publishes numeric key
    `2`, persists the canonical key, and leaves the legacy fields cleared. A failure means existing
    local tabs can lose their delayed-ready destination or keep an href outside Android's durable
    general-book model.
     */
    func testRestoreMigratesLegacyEpubHrefIntoGeneralBookState() async throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        let window = makeWindow(category: DocumentCategory.epub.pageManagerKey)
        window.pageManager?.epubIdentifier = identifier
        window.pageManager?.epubHref = "OPS/text/second.xhtml#target"
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.restoreSavedPosition()

        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.activeEpubIdentifier, identifier)
        XCTAssertEqual(controller.currentGeneralBookKey, "OPS/text/second.xhtml#target")
        XCTAssertEqual(window.pageManager?.currentCategoryName, DocumentCategory.generalBook.pageManagerKey)
        XCTAssertEqual(window.pageManager?.generalBookDocument, reader.initials)
        XCTAssertEqual(window.pageManager?.generalBookKey, "OPS/text/second.xhtml#target")
        XCTAssertNil(window.pageManager?.epubIdentifier)
        XCTAssertNil(window.pageManager?.epubHref)
        XCTAssertEqual(persistCount, 1)

        let boundary = recordedScripts().count
        controller.loadCurrentContent()
        let emissions = try await awaitBridgeEmission(
            from: recordedScripts,
            event: "add_documents",
            after: boundary
        )
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )

        XCTAssertEqual(payload["bookInitials"] as? String, reader.initials)
        XCTAssertEqual(payload["key"] as? String, "2")
        XCTAssertEqual(controller.currentGeneralBookKey, "2")
        XCTAssertEqual(window.pageManager?.generalBookKey, "2")
        XCTAssertEqual(persistCount, 2)
    }

    /**
     Preserves a worker-resolved EPUB selection when its first bridge replacement is rejected.

     - Setup: Activates a real EPUB through a bridge with no evaluator, requests its second entry,
       waits for prepared publication to settle, then attaches the ordinary bridge observer and
       sends client-ready.
     - Expected result: The exact canonical key is persisted before the rejected dispatch while
       committed render state stays empty; client-ready replays the selected entry and only then
       advances rendered identity.
     - Failure meaning: EPUB retains a separate post-bridge selection lifecycle and loses Android's
       selected general-book destination whenever Vue is still bootstrapping.
     - Side effects: Installs/deletes one temporary EPUB and records only the accepted replay.
     */
    func testEpubSelectionSurvivesRejectedReplacementAndReplaysOnClientReady() async throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        let window = makeWindow(category: DocumentCategory.bible.pageManagerKey)
        controller.activeWindow = window
        controller.switchEpub(identifier: identifier)

        controller.loadEpubEntry(key: "2")
        try await awaitReaderCondition("worker-resolved EPUB selection intent") {
            controller.currentGeneralBookKey == "2"
                && window.pageManager?.generalBookKey == "2"
        }

        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.activeGeneralBookModuleName, reader.initials)
        XCTAssertEqual(window.pageManager?.generalBookDocument, reader.initials)
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
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )

        XCTAssertEqual(payload["bookInitials"] as? String, reader.initials)
        XCTAssertEqual(payload["key"] as? String, "2")
        XCTAssertEqual(controller.committedRenderState.identity?.category, .generalBook)
        XCTAssertEqual(controller.committedRenderState.identity?.moduleName, reader.initials)
        XCTAssertEqual(controller.committedRenderState.identity?.key, "2")
    }

    /** A cancelled older key cannot retry over a newer key in the same EPUB generation. */
    func testDelayedEpubKeyASettlementCannotReselectOverNewerKeyB() async throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let worker = DispatchQueue(label: "org.andbible.tests.epub-key-supersession")
        worker.suspend()
        var workerIsSuspended = true
        defer { if workerIsSuspended { worker.resume() } }
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: worker)
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        let window = makeWindow(category: DocumentCategory.bible.pageManagerKey)
        controller.activeWindow = window
        controller.switchEpub(identifier: identifier)

        controller.loadEpubEntry(key: "1")
        let boundary = scripts().count
        controller.loadEpubEntry(key: "2")
        worker.resume()
        workerIsSuspended = false
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )

        XCTAssertEqual(document["key"] as? String, "2")
        XCTAssertEqual(controller.currentGeneralBookKey, "2")
        XCTAssertEqual(window.pageManager?.generalBookKey, "2")
        XCTAssertEqual(controller.activeEpubIdentifier, identifier)
    }

    /** A cancelled request from EPUB A cannot retry after the pane selects a different EPUB B. */
    func testDelayedEpubASettlementCannotReselectOverNewerEpubB() async throws {
        let firstArchiveURL = try makeArchive()
        let secondArchiveURL = try makeArchive()
        defer {
            try? FileManager.default.removeItem(at: firstArchiveURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondArchiveURL.deletingLastPathComponent())
        }
        let firstIdentifier = try installDefaultLibraryEpubFixture(epubURL: firstArchiveURL)
        let secondIdentifier = try installDefaultLibraryEpubFixture(epubURL: secondArchiveURL)
        defer {
            try? EpubReader.delete(identifier: firstIdentifier)
            try? EpubReader.delete(identifier: secondIdentifier)
        }
        let secondReader = try XCTUnwrap(EpubReader(identifier: secondIdentifier))
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let worker = DispatchQueue(label: "org.andbible.tests.epub-document-supersession")
        worker.suspend()
        var workerIsSuspended = true
        defer { if workerIsSuspended { worker.resume() } }
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: worker)
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        let window = makeWindow(category: DocumentCategory.bible.pageManagerKey)
        controller.activeWindow = window
        controller.switchEpub(identifier: firstIdentifier)
        controller.loadEpubEntry(key: "1")

        controller.switchEpub(identifier: secondIdentifier)
        let boundary = scripts().count
        controller.loadEpubEntry(key: "2")
        worker.resume()
        workerIsSuspended = false
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )

        XCTAssertEqual(document["bookInitials"] as? String, secondReader.initials)
        XCTAssertEqual(document["key"] as? String, "2")
        XCTAssertEqual(controller.activeEpubIdentifier, secondIdentifier)
        XCTAssertEqual(controller.activeGeneralBookModuleName, secondReader.initials)
        XCTAssertEqual(controller.currentGeneralBookKey, "2")
        XCTAssertEqual(window.pageManager?.generalBookDocument, secondReader.initials)
        XCTAssertEqual(window.pageManager?.generalBookKey, "2")
    }

    /** A current EPUB request retries once when only its captured source authorization expires. */
    func testCurrentEpubRequestRefreshesAfterManagerGenerationChanges() async throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let worker = DispatchQueue(label: "org.andbible.tests.epub-source-authorization")
        worker.suspend()
        var workerIsSuspended = true
        defer { if workerIsSuspended { worker.resume() } }
        let sourceCaptureCount = EpubParityLockedValue(0)
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            workerQueue: worker,
            phaseObserver: { phase, _, _ in
                guard phase == .sourceCapture else { return }
                sourceCaptureCount.withValue { $0 += 1 }
            }
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        let window = makeWindow(category: DocumentCategory.bible.pageManagerKey)
        controller.activeWindow = window
        controller.switchEpub(identifier: identifier)

        let boundary = scripts().count
        controller.loadEpubEntry(key: "2")
        manager.refresh()
        worker.resume()
        workerIsSuspended = false
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )

        XCTAssertEqual(sourceCaptureCount.value, 2)
        XCTAssertEqual(document["bookInitials"] as? String, reader.initials)
        XCTAssertEqual(document["key"] as? String, "2")
        XCTAssertEqual(controller.currentGeneralBookKey, "2")
        XCTAssertEqual(window.pageManager?.generalBookKey, "2")
        XCTAssertEqual(controller.committedRenderState.identity?.key, "2")
    }

    /** Cancelling a current EPUB preparation settles without publishing an error or selection. */
    func testCurrentEpubCancellationHasNoPublicationEffects() async throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let worker = DispatchQueue(label: "org.andbible.tests.epub-current-cancellation")
        worker.suspend()
        var workerIsSuspended = true
        defer { if workerIsSuspended { worker.resume() } }
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: worker)
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        let window = makeWindow(category: DocumentCategory.bible.pageManagerKey)
        controller.activeWindow = window
        controller.switchEpub(identifier: identifier)

        let boundary = scripts().count
        controller.loadEpubEntry(key: "2")
        coordinator.cancelAll()
        worker.resume()
        workerIsSuspended = false
        let drained = expectation(description: "cancelled EPUB worker drained")
        worker.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)

        XCTAssertEqual(scripts().count, boundary)
        XCTAssertEqual(controller.activeEpubIdentifier, identifier)
        XCTAssertEqual(controller.activeGeneralBookModuleName, reader.initials)
        XCTAssertNil(controller.currentGeneralBookKey)
        XCTAssertNil(window.pageManager?.generalBookKey)
        XCTAssertEqual(controller.committedRenderState, .empty)
    }

    /** Reentrant persistence navigation cannot let the older EPUB selection dispatch afterward. */
    func testEpubPersistenceCallbackNavigationSupersedesOlderDispatch() async throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager
        )
        let window = makeWindow(category: DocumentCategory.bible.pageManagerKey)
        controller.activeWindow = window
        controller.switchEpub(identifier: identifier)
        var didNavigateFromPersistence = false
        controller.onPersistState = {
            guard !didNavigateFromPersistence else { return }
            didNavigateFromPersistence = true
            controller.loadEpubEntry(key: "2")
        }

        let boundary = scripts().count
        controller.loadEpubEntry(key: "1")
        try await awaitReaderCondition("reentrant EPUB selection accepted") {
            controller.currentGeneralBookKey == "2"
                && controller.committedRenderState.identity?.key == "2"
        }
        let emittedScripts = Array(scripts().dropFirst(boundary))
        let documentEmissions = emittedScripts.filter { $0.contains("add_documents") }
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: documentEmissions, event: "add_documents") as? [String: Any]
        )

        XCTAssertTrue(didNavigateFromPersistence)
        XCTAssertEqual(documentEmissions.count, 1)
        XCTAssertEqual(document["bookInitials"] as? String, reader.initials)
        XCTAssertEqual(document["key"] as? String, "2")
        XCTAssertEqual(window.pageManager?.generalBookKey, "2")
    }

    /** Source invalidation from persistence retries the still-current EPUB exactly once. */
    func testEpubPersistenceCallbackSourceInvalidationRevalidatesBeforeDispatch() async throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let captures = EpubParityLockedValue(0)
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            workerQueue: DispatchQueue(label: "org.andbible.tests.epub-persist-source"),
            phaseObserver: { phase, _, key in
                guard phase == .sourceCapture, key.family.rawValue == "epub" else { return }
                captures.withValue { $0 += 1 }
            }
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        let window = makeWindow(category: DocumentCategory.bible.pageManagerKey)
        controller.activeWindow = window
        controller.switchEpub(identifier: identifier)
        var invalidatedSource = false
        controller.onPersistState = {
            guard !invalidatedSource else { return }
            invalidatedSource = true
            manager.refresh()
        }

        let boundary = scripts().count
        controller.loadEpubEntry(key: "2")
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )

        XCTAssertTrue(invalidatedSource)
        XCTAssertEqual(captures.value, 2)
        XCTAssertEqual(
            emissions.filter { $0.contains("emit('add_documents'") }.count,
            1
        )
        XCTAssertEqual(document["bookInitials"] as? String, reader.initials)
        XCTAssertEqual(document["key"] as? String, "2")
        XCTAssertEqual(controller.committedRenderState.identity?.key, "2")
    }

    /**
     Routes transformed EPUB references only within their originating general-book document.

     Setup restores the first numeric fragment, sends links carrying foreign and case-only impostor
     initials, then the equivalent link carrying the active EPUB initials and manifest id. Both
     impostors must be inert; the valid request must persist key `2`, emit that fragment, and
     preserve its `target` jump id. A failure means overlapping hrefs from distinct EPUB identities
     can cross-navigate or internal anchors can lose their exact destination at the bridge boundary.
     */
    func testInternalLinkRequiresMatchingInitialsAndNavigatesToIndexedAnchor() async throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        let window = makeWindow(
            category: DocumentCategory.generalBook.pageManagerKey,
            generalBookDocument: reader.initials,
            generalBookKey: "1"
        )
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        controller.restoreSavedPosition()

        let foreignBoundary = recordedScripts().count
        controller.bridge(bridge, openEpubLink: "Epub-Foreign", toKey: "second", toId: "target")
        XCTAssertEqual(controller.currentGeneralBookKey, "1")
        XCTAssertEqual(recordedScripts().count, foreignBoundary)

        let caseOnlyImpostor = reader.initials.uppercased()
        XCTAssertNotEqual(caseOnlyImpostor, reader.initials)
        let impostorBoundary = recordedScripts().count
        controller.bridge(bridge, openEpubLink: caseOnlyImpostor, toKey: "second", toId: "target")
        XCTAssertEqual(controller.currentGeneralBookKey, "1")
        XCTAssertEqual(recordedScripts().count, impostorBoundary)

        let navigationBoundary = recordedScripts().count
        controller.bridge(bridge, openEpubLink: reader.initials, toKey: "second", toId: "target")
        let emissions = try await awaitBridgeEmission(
            from: recordedScripts,
            event: "add_documents",
            after: navigationBoundary
        )

        XCTAssertEqual(controller.currentGeneralBookKey, "2")
        XCTAssertEqual(window.pageManager?.generalBookDocument, reader.initials)
        XCTAssertEqual(window.pageManager?.generalBookKey, "2")
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["key"] as? String, "2")
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(setup["jumpToId"] as? String, "target")
    }

    /**
     Rejects stale internal EPUB links before local lookup when a native owner appears.

     - Setup: Activates a real EPUB, then publishes a readable native Bible whose full name owns the
       EPUB initials through JSword's case tier and refreshes the controller registry.
     - Expected result: Same-page and cross-page links emit nothing and preserve all pane state; the
       installed owner is observed before any manifest/content lookup can use the stale generation.
     - Failure meaning: A retained EPUB bridge callback can disclose or navigate shadowed local
       content even though all ordinary load/switch routes now honor Android's combined registry.
     - Side effects: Installs/deletes one temporary EPUB, writes one inherited SWORD descriptor, and
       records bridge/persistence operations without changing shared libraries.
     */
    func testInternalLinkRejectsStaleEpubAfterNativeOwnerAppearsBeforeReadOrMutation() throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = makeWindow(
            category: DocumentCategory.generalBook.pageManagerKey,
            generalBookDocument: reader.initials,
            generalBookKey: "1"
        )
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        controller.restoreSavedPosition()
        XCTAssertEqual(controller.activeEpubIdentifier, identifier)

        try seedBibleAliasModule(
            named: "LateEpubLinkOwner",
            description: reader.initials.lowercased(),
            in: modulePath
        )
        let moduleCacheURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/modules-conf.cache")
        if FileManager.default.fileExists(atPath: moduleCacheURL.path) {
            try FileManager.default.removeItem(at: moduleCacheURL)
        }
        controller.refreshInstalledSourceInventoryForAuthoritativeSelection()
        XCTAssertEqual(
            controller.registeredInstalledModuleInfo(named: reader.initials)?.name,
            "LateEpubLinkOwner"
        )
        let baselineCategory = controller.currentCategory
        let baselineIdentifier = controller.activeEpubIdentifier
        let baselineGeneralBook = controller.activeGeneralBookModuleName
        let baselineKey = controller.currentGeneralBookKey
        let baselinePageCategory = window.pageManager?.currentCategoryName
        let baselinePageDocument = window.pageManager?.generalBookDocument
        let baselinePageKey = window.pageManager?.generalBookKey
        let baselineScripts = recordedScripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.bridge(bridge, openEpubLink: reader.initials, toKey: "", toId: "target")
        controller.bridge(bridge, openEpubLink: reader.initials, toKey: "second", toId: "target")

        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertEqual(controller.activeEpubIdentifier, baselineIdentifier)
        XCTAssertEqual(controller.activeGeneralBookModuleName, baselineGeneralBook)
        XCTAssertEqual(controller.currentGeneralBookKey, baselineKey)
        XCTAssertEqual(window.pageManager?.currentCategoryName, baselinePageCategory)
        XCTAssertEqual(window.pageManager?.generalBookDocument, baselinePageDocument)
        XCTAssertEqual(window.pageManager?.generalBookKey, baselinePageKey)
        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(recordedScripts().count, baselineScripts)
    }

    /**
     Releases an active deleted EPUB and clears its persisted general-book identity.

     The fixture opens a real EPUB without a SWORD Bible, commits storage deletion, and reconciles
     the owning controller. The reader must release its immutable generation, enter the Bible
     category, and clear every EPUB/general-book page-manager field. A failure leaves deleted local
     content active indefinitely or allows a later restore to resurrect its stale identity.
     */
    func testCommittedEpubDeletionReturnsActivePaneToBibleState() throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let controller = BibleReaderController(bridge: BibleBridge(), initializesSword: false)
        let window = makeWindow(category: DocumentCategory.bible.pageManagerKey)
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window

        controller.switchEpub(identifier: identifier)
        XCTAssertEqual(controller.activeEpubIdentifier, identifier)
        XCTAssertNotNil(window.pageManager?.generalBookDocument)

        try EpubReader.delete(identifier: identifier)
        controller.reconcileDeletedEpub(identifier: identifier)

        XCTAssertNil(controller.activeEpubReader)
        XCTAssertNil(controller.activeEpubIdentifier)
        XCTAssertNil(controller.activeGeneralBookModuleName)
        XCTAssertNil(controller.currentGeneralBookKey)
        XCTAssertEqual(controller.currentCategory, .bible)
        XCTAssertEqual(window.pageManager?.currentCategoryName, DocumentCategory.bible.pageManagerKey)
        XCTAssertNil(window.pageManager?.generalBookDocument)
        XCTAssertNil(window.pageManager?.generalBookKey)
        XCTAssertNil(window.pageManager?.epubIdentifier)
        XCTAssertNil(window.pageManager?.epubHref)
    }

    /**
     Reauthorizes a planned EPUB bookmark against the currently published immutable generation.

     - Setup: Plans an exact first-fragment bookmark, rebuilds the same installed EPUB into a new
       generation, and delays commit while the reader remains on its Bible baseline.
     - Expected: Commit reports `destinationChanged` before fragment rendering and leaves reader,
       PageManager, persistence, and bridge state unchanged.
     - Failure meaning: A detached EPUB plan retains content authority across atomic generation
       replacement or opens stale fragment content before fresh combined-owner authorization.
     - Side effects: Installs, rebuilds, and deletes one temporary EPUB generation.
     */
    func testEpubBookmarkCommitRejectsGenerationReplacementAfterPlanWithoutMutation() throws {
        let archiveURL = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let target = BookmarkNavigationTarget.generic(.init(
            moduleInitials: reader.initials,
            key: "1",
            ordinalRange: nil
        ))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        let window = makeWindow(category: DocumentCategory.bible.pageManagerKey)
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        controller.bridgeDidSetClientReady(bridge)
        let inventory = try controller.bookmarkNavigationInventory(for: target)
        let planned = try BibleReaderBookmarkNavigationCoordinator().plan(
            target: target,
            inventory: inventory
        )
        guard case .epub(let plan) = planned else {
            return XCTFail("Expected an EPUB bookmark plan")
        }

        let replacement = try EpubReader.rebuildSearchIndex(identifier: identifier)
        XCTAssertNotEqual(replacement.generationIdentifier, plan.generationIdentifier)
        let baselineCategory = controller.currentCategory
        let baselineGeneralBook = controller.activeGeneralBookModuleName
        let baselineGeneralBookKey = controller.currentGeneralBookKey
        let baselineEpubIdentifier = controller.activeEpubIdentifier
        let baselinePageCategory = window.pageManager?.currentCategoryName
        let baselinePageGeneralBook = window.pageManager?.generalBookDocument
        let baselinePageGeneralBookKey = window.pageManager?.generalBookKey
        let baselineScripts = scripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        XCTAssertThrowsError(try controller.commitEpubBookmarkNavigation(plan)) { error in
            XCTAssertEqual(
                error as? BibleReaderBookmarkNavigationCommitFailure,
                .destinationChanged
            )
        }
        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertEqual(controller.activeGeneralBookModuleName, baselineGeneralBook)
        XCTAssertEqual(controller.currentGeneralBookKey, baselineGeneralBookKey)
        XCTAssertEqual(controller.activeEpubIdentifier, baselineEpubIdentifier)
        XCTAssertEqual(window.pageManager?.currentCategoryName, baselinePageCategory)
        XCTAssertEqual(window.pageManager?.generalBookDocument, baselinePageGeneralBook)
        XCTAssertEqual(window.pageManager?.generalBookKey, baselinePageGeneralBookKey)
        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(scripts().count, baselineScripts)
    }

    /**
     Creates an unpersisted window with one explicit page-manager document state.

     - Parameters:
       - category: Persisted Android page-manager category key.
       - generalBookDocument: Optional general-book module initials.
       - generalBookKey: Optional durable numeric/general-book key.
     - Returns: Context-owned window whose page manager is ready for controller restore.
     - Side effects: Inserts both nodes before wiring their relationship for iOS 17 SwiftData.
     - Failure modes: None.
     */
    private func makeWindow(
        category: String,
        generalBookDocument: String? = nil,
        generalBookKey: String? = nil
    ) -> Window {
        let window = Window()
        let pageManager = PageManager(id: window.id, currentCategoryName: category)
        pageManager.generalBookDocument = generalBookDocument
        pageManager.generalBookKey = generalBookKey
        self.retainReaderWindowGraph(window, attaching: pageManager)
        return window
    }

    /**
     Writes a real two-spine EPUB 3 archive with one cross-spine anchor target.

     - Returns: Temporary `.epub` URL whose parent directory is owned by the caller.
     - Side effects: Creates one temporary directory and stored ZIP archive.
     - Throws: File-system or ZIP-writer errors.
     */
    private func makeArchive() throws -> URL {
        let title = "EPUB Controller Fixture \(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-controller-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent("\(title).epub")
        let entries: [(String, String)] = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles>
                <rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """),
            ("OPS/package.opf", """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(title)</dc:title><dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="first" href="text/first.xhtml" media-type="application/xhtml+xml"/>
                <item id="second" href="text/second.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="first"/><itemref idref="second"/></spine>
            </package>
            """),
            ("OPS/nav.xhtml", """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
              <body><nav epub:type="toc"><ol>
                <li><a href="text/first.xhtml#start">First</a></li>
                <li><a href="text/second.xhtml#target">Second</a></li>
              </ol></nav></body>
            </html>
            """),
            ("OPS/text/first.xhtml", """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
              <section id="start"><p>First section.</p><a href="second.xhtml#target">Next</a></section>
            </body></html>
            """),
            ("OPS/text/second.xhtml", """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
              <section id="target"><p>Second section. Exact restore target.</p></section>
            </body></html>
            """)
        ]
        let archive = try ZipArchiveWriter.storedArchive(entries: entries.map {
            ZipArchiveWriterEntry(name: $0.0, data: Data($0.1.utf8))
        })
        try archive.write(to: archiveURL, options: .atomic)
        return archiveURL
    }
}

/** Minimal thread-safe value used by EPUB worker-phase assertions. */
private final class EpubParityLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ operation: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        operation(&storage)
    }
}

/** Deterministic EPUB parity speech-engine double that accepts utterances without platform audio. */
private final class EpubParitySpeechSynthesizer: SpeechSynthesizing {
    weak var delegate: AVSpeechSynthesizerDelegate?

    /** Accepts one utterance synchronously; tests drive provider advancement explicitly. */
    func speak(_ utterance: AVSpeechUtterance) {}

    /** Reports a successful immediate stop. */
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }

    /** Reports a successful pause. */
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }

    /** Reports a successful resume. */
    func continueSpeaking() -> Bool { true }
}
