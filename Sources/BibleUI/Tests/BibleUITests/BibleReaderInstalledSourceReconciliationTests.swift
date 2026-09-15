import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
import SwordKit

/** End-to-end visible-source transition coverage for installed registry reconciliation. */
@MainActor
final class BibleReaderInstalledSourceReconciliationTests: BibleUISwordFixtureTestCase {
    /** One lifecycle action restores and publishes exactly one real My Notes preparation. */
    func testReconcilePersistedMyNotesPreparesOnceAndPublishesNotesPayload() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let worker = DispatchQueue(label: "BibleReaderInstalledSourceReconciliationTests-my-notes")
        let sourceCaptureCount = InstalledSourceReconciliationLockedCounter()
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            workerQueue: worker,
            phaseObserver: { phase, _, key in
                guard phase == .sourceCapture, key.family.rawValue == "my-notes" else { return }
                sourceCaptureCount.increment()
            }
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(
            id: window.id,
            currentCategoryName: BibleReaderController.myNotesPageManagerCategoryName
        )
        pageManager.bibleDocument = "KJV"
        retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
        controller.restoreSavedPosition()
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: 0)

        let baselineCaptureCount = sourceCaptureCount.value
        let boundary = scripts().count
        controller.reconcileInstalledSources()
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        let quiesced = expectation(description: "My Notes reconciliation worker quiesced")
        worker.async { quiesced.fulfill() }
        await fulfillment(of: [quiesced], timeout: 2)

        XCTAssertEqual(sourceCaptureCount.value - baselineCaptureCount, 1)
        XCTAssertEqual(
            scripts().dropFirst(boundary).filter { $0.contains("emit('add_documents'") }.count,
            1
        )
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "notes")
    }

    /** A removed real Bible follows Android's first-readable category fallback. */
    func testRemovedSelectedBibleFallsBackToFreshFirstReadableSource() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "FallbackBible",
            description: "Fallback Bible",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = makeBibleWindow(savedDocument: "KJV")
        controller.activeWindow = window
        controller.restoreSavedPosition()
        XCTAssertEqual(controller.activeModuleName, "KJV")
        controller.bridgeDidSetClientReady(bridge)

        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: modulePath).appendingPathComponent("mods.d/kjv.conf")
        )
        try removeModuleCache(in: modulePath)
        let boundary = scripts().count
        controller.reconcileInstalledSources()
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )

        XCTAssertEqual(controller.activeModuleName, "FallbackBible")
        XCTAssertEqual(
            controller.installedModules(for: .bible).map(\.name),
            ["FallbackBible"]
        )
        XCTAssertTrue(emissions.joined().contains("FallbackBible"))
        XCTAssertTrue(emissions.joined().contains("In the beginning"))
    }

    /**
     A removed Bible selects its registered locked global default before a readable alternate.

     This is Android's observable distinction between removal and relock: the setting lookup uses
     the inclusive installed registry, while only the later fallback filters locked books.
     */
    func testRemovedBibleRetainsLockedSavedDefaultBeforeReadableFallback() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEncryptedBible(named: "LOCKEDDEFAULT", in: modulePath)
        try seedBibleAliasModule(
            named: "ReadableAlternate",
            description: "Readable alternate",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let context = ModelContext(try makeWorkspaceModelContainer())
        let settingsStore = SettingsStore(modelContext: context)
        settingsStore.setString("default-BIBLE", value: "LOCKEDDEFAULT")
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = settingsStore
        let window = makeBibleWindow(savedDocument: "KJV")
        controller.activeWindow = window
        controller.restoreSavedPosition()
        controller.bridgeDidSetClientReady(bridge)

        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: modulePath).appendingPathComponent("mods.d/kjv.conf")
        )
        try removeModuleCache(in: modulePath)
        let boundary = scripts().count
        controller.reconcileInstalledSources()
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )

        XCTAssertEqual(controller.activeModuleName, "LOCKEDDEFAULT")
        XCTAssertEqual(window.pageManager?.bibleDocument, "LOCKEDDEFAULT")
        XCTAssertNil(controller.activeModule)
        XCTAssertTrue(
            controller.installedModules(for: .bible).contains {
                $0.name == "ReadableAlternate" && $0.isUnlocked
            }
        )
        XCTAssertTrue(emissions.joined().contains("No content for selected verse"))
    }

    /** A readable saved default wins before the first readable BookSet fallback after removal. */
    func testRemovedBibleUsesReadableSavedDefaultBeforeBookSetFallback() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "AFirstReadable",
            description: "A first readable",
            in: modulePath
        )
        try seedBibleAliasModule(
            named: "ZSavedDefault",
            description: "Z saved default",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let context = ModelContext(try makeWorkspaceModelContainer())
        let settingsStore = SettingsStore(modelContext: context)
        settingsStore.setString("default-BIBLE", value: "ZSavedDefault")
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = settingsStore
        let window = makeBibleWindow(savedDocument: "KJV")
        controller.activeWindow = window
        controller.restoreSavedPosition()
        controller.bridgeDidSetClientReady(bridge)

        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: modulePath).appendingPathComponent("mods.d/kjv.conf")
        )
        try removeModuleCache(in: modulePath)
        let boundary = scripts().count
        controller.reconcileInstalledSources()
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )

        XCTAssertEqual(controller.activeModuleName, "ZSavedDefault")
        XCTAssertEqual(window.pageManager?.bibleDocument, "ZSavedDefault")
        XCTAssertTrue(emissions.joined().contains("ZSavedDefault"))
        XCTAssertTrue(emissions.joined().contains("In the beginning"))
    }

    /**
     A removed sole Bible never reuses accepted bytes and recovers fresh content when restored.

     The unrelated middle refresh protects the repeated no-backend state: it must remain an
     R2-published no-content document rather than being reinterpreted as the startup placeholder.
     */
    func testRemovedSoleBibleStaysNoContentAcrossRefreshThenRestoresFreshBody() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let configURL = URL(fileURLWithPath: modulePath)
            .appendingPathComponent("mods.d/kjv.conf")
        let originalConfig = try Data(contentsOf: configURL)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = makeBibleWindow(savedDocument: "KJV")
        controller.activeWindow = window
        controller.restoreSavedPosition()
        controller.bridgeDidSetClientReady(bridge)
        let initialBoundary = scripts().count
        controller.loadCurrentContent()
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: initialBoundary
        )

        try FileManager.default.removeItem(at: configURL)
        try removeModuleCache(in: modulePath)
        var boundary = scripts().count
        controller.reconcileInstalledSources()
        var emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        XCTAssertTrue(emissions.joined().contains("No content for selected verse"))
        XCTAssertTrue(controller.installedModules(for: .bible).isEmpty)

        try seedEmptyRawCommentaryModule(named: "Unrelated", in: modulePath)
        try removeModuleCache(in: modulePath)
        boundary = scripts().count
        controller.reconcileInstalledSources()
        emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        XCTAssertTrue(emissions.joined().contains("No content for selected verse"))

        try originalConfig.write(to: configURL, options: .atomic)
        try removeModuleCache(in: modulePath)
        boundary = scripts().count
        controller.reconcileInstalledSources()
        emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        XCTAssertEqual(controller.activeModuleName, "KJV")
        XCTAssertTrue(emissions.joined().contains("In the beginning"))
    }

    /** A registered Bible that relocks remains selected and publishes no content repeatedly. */
    func testRelockedSelectedBibleRemainsSelectedUntilFreshUnlock() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEncryptedBible(named: "LOCKEDA", in: modulePath)
        let configURL = URL(fileURLWithPath: modulePath)
            .appendingPathComponent("mods.d/lockeda.conf")
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertTrue(
            manager.unlockModule(named: "LOCKEDA", withCipherKey: "rawtextcipherkey")
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = makeBibleWindow(savedDocument: "LOCKEDA")
        controller.activeWindow = window
        controller.restoreSavedPosition()
        XCTAssertEqual(controller.activeModuleName, "LOCKEDA")
        controller.bridgeDidSetClientReady(bridge)
        var boundary = scripts().count
        controller.loadCurrentContent()
        var emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        XCTAssertTrue(emissions.joined().contains("Synthetic encrypted first verse"))

        let unlockedConfig = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(unlockedConfig.contains("CipherKey=rawtextcipherkey"))
        try unlockedConfig.replacingOccurrences(
            of: "CipherKey=rawtextcipherkey",
            with: "CipherKey="
        ).write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        try removeModuleCache(in: modulePath)
        boundary = scripts().count
        controller.reconcileInstalledSources()
        emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        XCTAssertEqual(controller.activeModuleName, "LOCKEDA")
        XCTAssertEqual(
            controller.installedModules(for: .bible).first { $0.name == "LOCKEDA" }?.isUnlocked,
            false
        )
        XCTAssertTrue(controller.installedModules(for: .bible).contains { $0.name == "KJV" })
        XCTAssertTrue(emissions.joined().contains("No content for selected verse"))

        try removeModuleCache(in: modulePath)
        boundary = scripts().count
        controller.reconcileInstalledSources()
        emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        XCTAssertEqual(controller.activeModuleName, "LOCKEDA")
        XCTAssertTrue(emissions.joined().contains("No content for selected verse"))

        XCTAssertTrue(
            controller.swordManager?.unlockModule(
                named: "LOCKEDA",
                withCipherKey: "rawtextcipherkey"
            ) == true
        )
        try removeModuleCache(in: modulePath)
        boundary = scripts().count
        controller.reconcileInstalledSources()
        emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        XCTAssertEqual(controller.activeModuleName, "LOCKEDA")
        XCTAssertTrue(emissions.joined().contains("Synthetic encrypted first verse"))
    }

    /** A rejected no-content bridge replacement never commits accepted render identity. */
    func testNoContentBridgeRejectionLeavesAcceptedRenderEmpty() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: modulePath).appendingPathComponent("mods.d/kjv.conf")
        )
        try removeModuleCache(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.activeWindow = makeBibleWindow(savedDocument: "KJV")
        controller.restoreSavedPosition()

        controller.bridgeDidSetClientReady(bridge)
        XCTAssertTrue(scripts().contains { $0.contains("emit('add_documents'") })
        XCTAssertEqual(controller.committedRenderState.identity?.category, .bible)

        // The same no-content path now targets an intentionally unbound bridge. Reconciliation
        // clears the earlier accepted identity before the replacement transport rejects it.
        bridge.javaScriptEvaluationObserver = nil
        controller.reconcileInstalledSources()

        XCTAssertNil(controller.committedRenderState.identity)
    }

    /** Creates a context-owned Bible window with one Java-exact persisted selection. */
    private func makeBibleWindow(savedDocument: String) -> Window {
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleDocument = savedDocument
        retainReaderWindowGraph(window, attaching: pageManager)
        return window
    }

    /** Copies the real encrypted RawText fixture behind one distinct installed Bible identity. */
    private func seedEncryptedBible(named name: String, in modulePath: String) throws {
        let fileManager = FileManager.default
        let moduleRoot = URL(fileURLWithPath: modulePath, isDirectory: true)
        let source = moduleRoot.appendingPathComponent(
            "ui-test-encrypted-rawtext",
            isDirectory: true
        )
        let moduleKey = name.lowercased()
        let destination = moduleRoot.appendingPathComponent(
            "modules/texts/rawtext/\(moduleKey)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: source, to: destination)
        try """
        [\(name)]
        Description=Encrypted refresh fixture \(name)
        Abbreviation=\(name)
        DataPath=./modules/texts/rawtext/\(moduleKey)/
        ModDrv=RawText
        SourceType=OSIS
        Encoding=UTF-8
        Lang=en
        Versification=KJV
        CipherKey=
        """.write(
            to: moduleRoot.appendingPathComponent("mods.d/\(moduleKey).conf"),
            atomically: true,
            encoding: .utf8
        )
    }

    /** Removes libsword's derived inventory cache when present. */
    private func removeModuleCache(in modulePath: String) throws {
        let cacheURL = URL(fileURLWithPath: modulePath)
            .appendingPathComponent("mods.d/modules-conf.cache")
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            try FileManager.default.removeItem(at: cacheURL)
        }
    }
}

/** Thread-safe preparation counter accepted by the coordinator's sendable observer. */
private final class InstalledSourceReconciliationLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
