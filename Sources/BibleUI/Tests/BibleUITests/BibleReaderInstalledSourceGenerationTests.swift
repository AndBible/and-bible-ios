import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
import SwordKit

/** End-to-end payload coverage for installed-source generation and owner transitions. */
@MainActor
final class BibleReaderInstalledSourceGenerationTests: BibleUISwordFixtureTestCase {
    /**
     A same-path native replacement publishes bytes from the new SWORD generation.

     - Setup: Accepts a synthetic RawText chapter, then overwrites the same initials and data path.
     - Expected: Lifecycle reconciliation emits the replacement body and none of the old body.
     - Failure meaning: Accepted chapter replay or a stale manager survives source replacement.
     - Side effects: Writes only to the base test case's owned temporary SWORD fixture.
     */
    func testReconcileSamePathNativeReplacementPublishesNewChapterBody() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let initials = "GenerationBible"
        try seedBible(initials: initials, body: "NATIVE_GENERATION_ONE", in: modulePath)
        let dataURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("modules/texts/rawtext/generationbible/ot")
        let firstBytes = try Data(contentsOf: dataURL)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = makeWindow(category: .bible, document: initials, key: nil)
        controller.activeWindow = window
        controller.restoreSavedPosition()
        controller.bridgeDidSetClientReady(bridge)
        let first = try await nextDocument(from: scripts, after: 0)
        XCTAssertTrue(payloadText(first).contains("NATIVE_GENERATION_ONE"))

        try seedBible(initials: initials, body: "NATIVE_GENERATION_TWO_DIFFERENT_BYTES", in: modulePath)
        try removeModuleCache(in: modulePath)
        let secondBytes = try Data(contentsOf: dataURL)
        XCTAssertNotEqual(firstBytes, secondBytes)

        let boundary = scripts().count
        controller.reconcileInstalledSources()
        let second = try await nextDocument(from: scripts, after: boundary)

        let text = payloadText(second)
        XCTAssertTrue(text.contains("NATIVE_GENERATION_TWO_DIFFERENT_BYTES"))
        XCTAssertFalse(text.contains("NATIVE_GENERATION_ONE"))
        XCTAssertEqual(controller.activeModuleName, initials)
        XCTAssertEqual(controller.committedRenderState.identity?.moduleName, initials)
    }

    /**
     Native, EPUB, and My Documents ownership is re-resolved with fresh payloads in both directions.

     - Setup: Gives one exact initials token to an empty native general book, a real EPUB, and a
       fully linked in-memory My Documents page, then removes and reinstalls owners in priority order.
     - Expected: Native emits its source error; EPUB and My Documents emit only their authored body.
     - Failure meaning: Reconciliation retains a retired backend or resolves owners out of Android order.
     - Side effects: Mutates only test-owned SWORD, EPUB, and in-memory SwiftData fixtures.
     */
    func testReconcileGeneralBookOwnerTransitionsPublishOnlyCurrentOwnerPayload() async throws {
        let archiveURL = try makeDefaultLibraryEpubArchiveFixture(
            title: "Owner Transition \(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        var installedIdentifier: String? = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer {
            if let installedIdentifier { try? EpubReader.delete(identifier: installedIdentifier) }
        }
        let identifier = try XCTUnwrap(installedIdentifier)
        let epub = try XCTUnwrap(EpubReader(identifier: identifier))
        let initials = epub.initials
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawGeneralBookModule(named: initials, in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let document = MyDocument(name: "Current local owner", initials: initials)
        let page = MyDocumentPage(title: "Local page", pageKey: "1", contentType: .markdown)
        let content = MyDocumentPageContent(pageId: page.id, content: "MYDOCUMENT_CURRENT_BODY")
        context.insert(document)
        context.insert(page)
        context.insert(content)
        page.document = document
        page.pageContent = content
        try context.save()

        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.myDocumentStore = MyDocumentStore(modelContext: context)
        let window = makeWindow(category: .generalBook, document: initials, key: "1")
        controller.activeWindow = window
        controller.restoreSavedPosition()
        controller.bridgeDidSetClientReady(bridge)
        var payload = try await nextDocument(from: scripts, after: 0)
        XCTAssertEqual(payload["type"] as? String, "error")
        XCTAssertFalse(payloadText(payload).contains("First shared fixture section."))
        XCTAssertFalse(payloadText(payload).contains("MYDOCUMENT_CURRENT_BODY"))

        try removeNativeGeneralBook(named: initials, from: modulePath)
        var boundary = scripts().count
        controller.reconcileInstalledSources()
        payload = try await nextDocument(from: scripts, after: boundary)
        XCTAssertTrue(payloadText(payload).contains("First shared fixture section."))
        XCTAssertFalse(payloadText(payload).contains("MYDOCUMENT_CURRENT_BODY"))
        XCTAssertEqual(controller.activeEpubIdentifier, identifier)

        try EpubReader.delete(identifier: identifier)
        installedIdentifier = nil
        boundary = scripts().count
        controller.reconcileInstalledSources()
        payload = try await nextDocument(from: scripts, after: boundary)
        XCTAssertTrue(payloadText(payload).contains("MYDOCUMENT_CURRENT_BODY"))
        XCTAssertFalse(payloadText(payload).contains("First shared fixture section."))
        XCTAssertEqual(controller.activeGeneralBookModuleName, initials)

        let reinstalled = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        installedIdentifier = reinstalled
        XCTAssertEqual(reinstalled, identifier)
        boundary = scripts().count
        controller.reconcileInstalledSources()
        payload = try await nextDocument(from: scripts, after: boundary)
        XCTAssertTrue(payloadText(payload).contains("First shared fixture section."))
        XCTAssertFalse(payloadText(payload).contains("MYDOCUMENT_CURRENT_BODY"))

        try seedEmptyRawGeneralBookModule(named: initials, in: modulePath)
        try removeModuleCache(in: modulePath)
        boundary = scripts().count
        controller.reconcileInstalledSources()
        payload = try await nextDocument(from: scripts, after: boundary)
        XCTAssertEqual(payload["type"] as? String, "error")
        XCTAssertFalse(payloadText(payload).contains("First shared fixture section."))
        XCTAssertFalse(payloadText(payload).contains("MYDOCUMENT_CURRENT_BODY"))
    }

    /**
     A committed Multi request is rebuilt from its source operation after lifecycle reconciliation.

     - Setup: Opens a real controller-prepared Multi, then replaces its selected native module bytes.
     - Expected: One lifecycle emission contains the new body and cannot contain the accepted old body.
     - Failure meaning: The special-document replay cache bypasses its retained source rebuild request.
     - Side effects: Writes only to the base test case's owned temporary SWORD fixture.
     */
    func testReconcileInvalidatesPreparedMultiReplayAndRebuildsFromNewNativeGeneration() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let initials = "CompositeSource"
        try seedBible(initials: initials, body: "COMPOSITE_GENERATION_ONE", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = makeWindow(category: .bible, document: initials, key: nil, links: true)
        controller.activeWindow = window
        controller.restoreSavedPosition()
        controller.bridgeDidSetClientReady(bridge)
        _ = try await nextDocument(from: scripts, after: 0)

        var boundary = scripts().count
        controller.bridge(
            bridge,
            openExternalLink: "multi://?osis=Gen.1.1&v11n=KJV"
        )
        var payload = try await nextDocument(from: scripts, after: boundary)
        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertTrue(payloadText(payload).contains("COMPOSITE_GENERATION_ONE"))

        try seedBible(
            initials: initials,
            body: "COMPOSITE_GENERATION_TWO_DIFFERENT_BYTES",
            in: modulePath
        )
        try removeModuleCache(in: modulePath)
        boundary = scripts().count
        controller.reconcileInstalledSources()
        payload = try await nextDocument(from: scripts, after: boundary)

        let text = payloadText(payload)
        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertTrue(text.contains("COMPOSITE_GENERATION_TWO_DIFFERENT_BYTES"))
        XCTAssertFalse(text.contains("COMPOSITE_GENERATION_ONE"))
        XCTAssertEqual(
            scripts().dropFirst(boundary).filter { $0.contains("emit('add_documents'") }.count,
            1
        )
    }

    private func seedBible(initials: String, body: String, in modulePath: String) throws {
        try seedSyntheticRawTextBibleModule(
            named: initials,
            description: "Installed source generation fixture",
            versification: "KJV",
            entries: [("Gen", 1, 1, #"<verse osisID="Gen.1.1">\#(body)</verse>"#)],
            in: modulePath
        )
    }

    private func makeWindow(
        category: DocumentCategory,
        document: String,
        key: String?,
        links: Bool = false
    ) -> Window {
        let window = Window(isSynchronized: false, isLinksWindow: links)
        let pageManager = PageManager(id: window.id, currentCategoryName: category.pageManagerKey)
        switch category {
        case .bible:
            pageManager.bibleDocument = document
        case .generalBook:
            pageManager.generalBookDocument = document
            pageManager.generalBookKey = key
        default:
            XCTFail("Unsupported source-generation fixture category")
        }
        retainReaderWindowGraph(window, attaching: pageManager)
        return window
    }

    private func nextDocument(
        from scripts: @escaping () -> [String],
        after boundary: Int
    ) async throws -> [String: Any] {
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        return try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
    }

    private func payloadText(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func removeNativeGeneralBook(named name: String, from modulePath: String) throws {
        let root = URL(fileURLWithPath: modulePath, isDirectory: true)
        let key = name.lowercased()
        let urls = [
            root.appendingPathComponent("mods.d/\(key).conf"),
            root.appendingPathComponent("modules/genbook/rawgenbook/\(key)", isDirectory: true),
        ]
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try removeModuleCache(in: modulePath)
    }

    private func removeModuleCache(in modulePath: String) throws {
        let url = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/modules-conf.cache")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
