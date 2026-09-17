import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/** Cross-controller routing and owner reauthorization contracts for prepared reader publication. */
@MainActor
final class BibleReaderPreparationEndToEndAuthorizationTests: BibleUISwordFixtureTestCase {
    /** Replacing a SQLite Bible before async publication rejects the captured handle and retries. */
    func testSQLiteBibleReplacementBeforePublicationRejectsCapturedHandle() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let sqliteURL = try installMyBibleFixture(in: modulePath)
        let replacementURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("replacement-\(UUID().uuidString).SQLite3")
        defer { try? FileManager.default.removeItem(at: replacementURL) }
        try FileManager.default.copyItem(at: sqliteURL, to: replacementURL)
        try executeSQLite(
            "UPDATE verses SET text = 'Authorized replacement verse' "
                + "WHERE book_number = 10 AND chapter = 1 AND verse = 1",
            at: replacementURL
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let registryOwner = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: manager
        )
        attachWindow(to: registryOwner)
        registryOwner.switchBibleDocument(to: "MyBible-bible")
        let managerGeneration = manager.contentAuthorizationGeneration
        let worker = DispatchQueue(label: "org.andbible.tests.sqlite-replacement-authorization")
        var replacementError: Error?
        var controller: BibleReaderController!
        let publicationAction = BibleReaderPublicationBoundaryAction()
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            workerQueue: worker,
            phaseObserver: { phase, _, key in
                guard phase == .publication,
                      key.family.rawValue == "bible" else { return }
                publicationAction.runOnce()
            }
        )
        let (bridge, scripts) = makeRecordingBridge()
        controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        attachWindow(to: controller)
        controller.switchBibleDocument(to: "MyBible-bible")
        publicationAction.install {
                do {
                    try FileManager.default.removeItem(at: sqliteURL)
                    try FileManager.default.moveItem(at: replacementURL, to: sqliteURL)
                    guard controller.copyModuleState(from: registryOwner) else {
                        throw NSError(
                            domain: "BibleReaderPreparationEndToEndAuthorizationTests",
                            code: 3,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Could not reload SQLite module state"
                            ]
                        )
                    }
                } catch {
                    replacementError = error
                }
        }

        let boundary = scripts().count
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        await drain(worker)
        let documents = try documentPayloads(in: Array(scripts().dropFirst(boundary)))

        XCTAssertTrue(publicationAction.didRun)
        XCTAssertNil(replacementError)
        XCTAssertEqual(manager.contentAuthorizationGeneration, managerGeneration)
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents.first?["bookInitials"] as? String, "MyBible-bible")
        let fragment = try XCTUnwrap(documents.first?["osisFragment"] as? [String: Any])
        let xml = try XCTUnwrap(fragment["xml"] as? String)
        XCTAssertTrue(xml.contains("Authorized replacement verse"), xml)
        XCTAssertFalse(xml.contains("In the <J>beginning</J>"), xml)
        XCTAssertEqual(controller.activeModuleName, "MyBible-bible")
        XCTAssertEqual(controller.committedRenderState.identity?.moduleName, "MyBible-bible")
    }

    /** Removing a SQLite Bible before async publication prevents its bytes from reaching Vue. */
    func testSQLiteBibleRemovalBeforePublicationRejectsCapturedDocument() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let sqliteURL = try installMyBibleFixture(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let registryOwner = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: manager
        )
        attachWindow(to: registryOwner)
        registryOwner.switchBibleDocument(to: "MyBible-bible")
        let managerGeneration = manager.contentAuthorizationGeneration
        let worker = DispatchQueue(label: "org.andbible.tests.sqlite-removal-authorization")
        var removalError: Error?
        var controller: BibleReaderController!
        let publicationAction = BibleReaderPublicationBoundaryAction()
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            workerQueue: worker,
            phaseObserver: { phase, _, key in
                guard phase == .publication,
                      key.family.rawValue == "bible" else { return }
                publicationAction.runOnce()
            }
        )
        let (bridge, scripts) = makeRecordingBridge()
        controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        attachWindow(to: controller)
        controller.switchBibleDocument(to: "MyBible-bible")
        publicationAction.install {
                do {
                    try FileManager.default.removeItem(at: sqliteURL)
                    guard controller.copyModuleState(from: registryOwner) else {
                        throw NSError(
                            domain: "BibleReaderPreparationEndToEndAuthorizationTests",
                            code: 4,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Could not reload SQLite module state"
                            ]
                        )
                    }
                } catch {
                    removalError = error
                }
        }

        let boundary = scripts().count
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        await drain(worker)
        let documents = try documentPayloads(in: Array(scripts().dropFirst(boundary)))

        XCTAssertTrue(publicationAction.didRun)
        XCTAssertNil(removalError)
        XCTAssertEqual(manager.contentAuthorizationGeneration, managerGeneration)
        XCTAssertFalse(documents.contains { $0["bookInitials"] as? String == "MyBible-bible" })
        XCTAssertEqual(documents.last?["bookInitials"] as? String, "KJV")
        XCTAssertEqual(controller.activeModuleName, "KJV")
        XCTAssertEqual(controller.committedRenderState.identity?.moduleName, "KJV")
    }

    /** A Java-distinct marker mutation before async publication rejects the older owner snapshot. */
    func testCanonicalEquivalentMarkerMutationBeforePublicationRejectsStaleProjection() async throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let composed = "Caf\u{00E9} marker"
        let decomposed = "Cafe\u{0301} marker"
        let document = MyDocument(name: "AI Documents", initials: "AIDocuments")
        let page = MyDocumentPage(
            title: composed,
            pageKey: "canonical-marker",
            sourcePromptId: UUID()
        )
        let content = MyDocumentPageContent(pageId: page.id, content: "Generated answer")
        let cache = AiPageCacheEntry(
            pageId: page.id,
            sourcePromptId: try XCTUnwrap(page.sourcePromptId),
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            sourceBookInitials: "KJV",
            sourceBookKey: "Gen.1.1"
        )
        context.insert(document)
        context.insert(page)
        context.insert(content)
        context.insert(cache)
        page.document = document
        page.pageContent = content
        cache.page = page
        try context.save()

        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let worker = DispatchQueue(label: "org.andbible.tests.exact-owner-authorization")
        var mutationError: Error?
        let publicationAction = BibleReaderPublicationBoundaryAction()
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            workerQueue: worker,
            phaseObserver: { phase, _, key in
                guard phase == .publication,
                      key.family.rawValue == "bible" else { return }
                publicationAction.runOnce()
            }
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        controller.myDocumentStore = MyDocumentStore(modelContext: context)
        attachWindow(to: controller)
        publicationAction.install {
                page.title = decomposed
                do {
                    try context.save()
                } catch {
                    mutationError = error
                }
        }

        let boundary = scripts().count
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        await drain(worker)
        let documents = try documentPayloads(in: Array(scripts().dropFirst(boundary)))
        let markers = documents.compactMap { $0["aiDocMarkers"] as? [[String: Any]] }.flatMap { $0 }
        let markerTitles = markers.compactMap { $0["title"] as? String }

        XCTAssertTrue(publicationAction.didRun)
        XCTAssertNil(mutationError)
        XCTAssertEqual(documents.count, 1)
        XCTAssertNotEqual(Array(composed.utf16), Array(decomposed.utf16))
        XCTAssertEqual(markerTitles.map { Array($0.utf16) }, [Array(decomposed.utf16)])
        XCTAssertEqual(controller.committedRenderState.identity?.moduleName, "KJV")
        withExtendedLifetime(container) {}
    }

    /** A live Multi route settles once after its outward callback invalidates source ownership. */
    func testSourceRoutedMultiRevalidatesAfterOutwardCallback() async throws {
        let sourceManager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let targetManager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        XCTAssertNotEqual(ObjectIdentifier(sourceManager), ObjectIdentifier(targetManager))
        let worker = DispatchQueue(label: "org.andbible.tests.multi-route-authorization")
        let sourceBridge = BibleBridge()
        let sourceController = BibleReaderController(
            bridge: sourceBridge,
            swordManagerOverride: sourceManager,
            documentPreparationCoordinator: BibleReaderDocumentPreparationCoordinator(
                workerQueue: worker
            )
        )
        attachWindow(to: sourceController)
        let (targetBridge, targetScripts) = makeRecordingBridge()
        let targetController = BibleReaderController(
            bridge: targetBridge,
            swordManagerOverride: targetManager
        )
        attachWindow(to: targetController)
        var invalidated = false
        var callbackOrder: [String] = []
        let routed = expectation(description: "source Multi routed to destination")
        sourceController.onOpenMultiReferenceDocumentInLinksWindow = { request in
            callbackOrder.append("route")
            sourceManager.refresh()
            invalidated = true
            targetController.loadMultiReferenceDocument(request)
            routed.fulfill()
        }

        let boundary = targetScripts().count
        sourceController.bridge(
            sourceBridge,
            openExternalLink: "multi://?osis=Gen.1.1&osis=John.1.1&v11n=KJV"
        )
        await fulfillment(of: [routed], timeout: 3)
        await drain(worker)
        let actionScripts = Array(targetScripts().dropFirst(boundary))

        XCTAssertTrue(invalidated)
        XCTAssertEqual(callbackOrder, ["route"])
        XCTAssertFalse(actionScripts.contains { $0.contains("emit('update_labels'") })
        XCTAssertFalse(actionScripts.contains { $0.contains("emit('add_documents'") })
        XCTAssertEqual(targetController.committedRenderState, .empty)
    }

    /** A live Definition route revalidates after its outward callback without a second route. */
    func testSourceRoutedDefinitionRevalidatesAfterOutwardCallback() async throws {
        let sourceManager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let targetManager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        XCTAssertNotEqual(ObjectIdentifier(sourceManager), ObjectIdentifier(targetManager))
        let worker = DispatchQueue(label: "org.andbible.tests.definition-route-authorization")
        let sourceBridge = BibleBridge()
        let sourceController = BibleReaderController(
            bridge: sourceBridge,
            swordManagerOverride: sourceManager,
            documentPreparationCoordinator: BibleReaderDocumentPreparationCoordinator(
                workerQueue: worker
            )
        )
        attachWindow(to: sourceController)
        let (targetBridge, targetScripts) = makeRecordingBridge()
        let targetController = BibleReaderController(
            bridge: targetBridge,
            swordManagerOverride: targetManager
        )
        attachWindow(to: targetController)
        var invalidated = false
        var callbackOrder: [String] = []
        let routed = expectation(description: "source Definition routed to destination")
        sourceController.onOpenDefinitionDocumentInLinksWindow = { request in
            callbackOrder.append("route")
            sourceManager.refresh()
            invalidated = true
            targetController.loadDefinitionDocument(request)
            routed.fulfill()
        }

        let boundary = targetScripts().count
        sourceController.bridge(sourceBridge, openExternalLink: "ab-w://?strong=H00430")
        await fulfillment(of: [routed], timeout: 3)
        await drain(worker)
        let actionScripts = Array(targetScripts().dropFirst(boundary))

        XCTAssertTrue(invalidated)
        XCTAssertEqual(callbackOrder, ["route"])
        XCTAssertFalse(actionScripts.contains { $0.contains("emit('update_labels'") })
        XCTAssertFalse(actionScripts.contains { $0.contains("emit('add_documents'") })
        XCTAssertEqual(targetController.committedRenderState, .empty)
    }

    /** A live Memorize route revalidates after its outward callback without retrying it. */
    func testSourceRoutedMemorizeRevalidatesAfterOutwardCallback() async throws {
        let sourceManager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let targetManager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        XCTAssertNotEqual(ObjectIdentifier(sourceManager), ObjectIdentifier(targetManager))
        let worker = DispatchQueue(label: "org.andbible.tests.memorize-route-authorization")
        let (sourceBridge, sourceScripts) = makeRecordingBridge()
        let sourceController = BibleReaderController(
            bridge: sourceBridge,
            swordManagerOverride: sourceManager,
            documentPreparationCoordinator: BibleReaderDocumentPreparationCoordinator(
                workerQueue: worker
            )
        )
        sourceController.settingsStore = try makeInMemorySettingsStore()
        attachWindow(to: sourceController)
        let (targetBridge, targetScripts) = makeRecordingBridge()
        let targetController = BibleReaderController(
            bridge: targetBridge,
            swordManagerOverride: targetManager
        )
        targetController.settingsStore = try makeInMemorySettingsStore()
        attachWindow(to: targetController)
        var invalidated = false
        var callbackOrder: [String] = []
        var destinationAccepted: Bool?
        let routed = expectation(description: "source Memorize routed to destination")
        sourceController.onOpenMemorizeDocumentInLinksWindow = { request in
            callbackOrder.append("route")
            sourceManager.refresh()
            invalidated = true
            destinationAccepted = targetController.renderMemorizeDocument(request)
            routed.fulfill()
        }
        let sourceReadyBoundary = sourceScripts().count
        sourceController.bridgeDidSetClientReady(sourceBridge)
        _ = try await awaitBridgeEmission(
            from: sourceScripts,
            event: "add_documents",
            after: sourceReadyBoundary
        )
        let module = try XCTUnwrap(sourceManager.module(named: "KJV"))
        let ordinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )

        let boundary = targetScripts().count
        sourceController.bridge(
            sourceBridge,
            memorize: "KJV",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        )
        await fulfillment(of: [routed], timeout: 3)
        await drain(worker)
        let actionScripts = Array(targetScripts().dropFirst(boundary))

        XCTAssertTrue(invalidated)
        XCTAssertEqual(callbackOrder, ["route"])
        XCTAssertFalse(actionScripts.contains { $0.contains("emit('add_documents'") })
        XCTAssertEqual(destinationAccepted, false)
        XCTAssertEqual(targetController.committedRenderState, .empty)
    }

    /** Routed authorization generations are exact even when owner and dependencies are unchanged. */
    func testRoutedAuthorizationGenerationDistinguishesSameOwnerAndDependencies() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let snapshot = manager.contentAuthorizationSnapshot(for: ["KJV"])
        let dependencies: [BibleReaderPreparationSourceDependency] = [
            .sword(manager: ObjectIdentifier(manager), authorization: snapshot),
        ]
        let first = BibleReaderRoutedSourceAuthorization(
            sourceOwner: manager,
            sourceGeneration: 1,
            dependencies: dependencies,
            validator: { true }
        )
        let second = BibleReaderRoutedSourceAuthorization(
            sourceOwner: manager,
            sourceGeneration: 2,
            dependencies: dependencies,
            validator: { true }
        )

        XCTAssertNotEqual(first, second)
    }

    /** Attaches a persistence-safe reader window to the test-owned SwiftData container. */
    private func attachWindow(to controller: BibleReaderController) {
        let window = Window()
        let pageManager = PageManager(id: window.id)
        retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
    }

    /** Copies one real MyBible payload into the controller's isolated module root. */
    @discardableResult
    private func installMyBibleFixture(in modulePath: String) throws -> URL {
        let repositoryRoot = try BibleUITestSourceLocator.repositoryRoot(
            containing: "Sources/BibleCore/Tests/Fixtures/SQLiteDocumentReaders"
        )
        let source = repositoryRoot
            .appendingPathComponent("Sources/BibleCore/Tests/Fixtures/SQLiteDocumentReaders")
            .appendingPathComponent("mybible-bible.SQLite3")
        let destination = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mybible/bible.SQLite3")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /** Decodes every accepted document replacement in one action-scoped script slice. */
    private func documentPayloads(in scripts: [String]) throws -> [[String: Any]] {
        try scripts
            .filter { $0.contains("emit('add_documents'") }
            .map { script in
                try XCTUnwrap(
                    bridgeEmissionPayload(from: [script], event: "add_documents") as? [String: Any]
                )
            }
    }

    /** Executes one SQL mutation against a test-owned SQLite fixture. */
    private func executeSQLite(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            throw NSError(
                domain: "BibleReaderPreparationEndToEndAuthorizationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not open \(url.lastPathComponent)"]
            )
        }
        defer { sqlite3_close(database) }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? "Unknown SQLite fixture error"
            sqlite3_free(message)
            throw NSError(
                domain: "BibleReaderPreparationEndToEndAuthorizationTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    /** Passively waits until every worker block submitted before this call has completed. */
    private func drain(_ worker: DispatchQueue) async {
        let drained = expectation(description: "reader preparation worker drained")
        worker.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        await Task.yield()
    }
}

/** One test-owned mutation installed on the main actor and fired at one async phase boundary. */
private final class BibleReaderPublicationBoundaryAction: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var hasRun = false

    var didRun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasRun
    }

    func install(_ action: @escaping () -> Void) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func runOnce() {
        lock.lock()
        guard !hasRun, let action else {
            lock.unlock()
            return
        }
        hasRun = true
        self.action = nil
        lock.unlock()
        action()
    }
}
