import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import SwordKit

/** Behavior coverage for transient commentary viewport ownership. */
final class BibleReaderCommentaryAnchorOwnerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try makeWorkspaceModelContainer()
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }
    /**
     Verifies an accepted local anchor follows only the same rendered route and is retired by an
     accepted replacement for a different source key.

     - Side effects: Mutates one value-type owner.
     - Failure modes: Fails if a new key revives an old document-local ordinal or if accepting the
       zero-position replacement does not make a later return start at the beginning.
     */
    func testAcceptedRouteRestoresUntilDifferentKeyReplacementCommits() {
        let graph = detachedPaneGraph()
        let first = identity(window: graph.window, pageManager: graph.pageManager, key: "Gen.1.24")
        let second = identity(window: graph.window, pageManager: graph.pageManager, key: "Gen.2.1")
        var owner = BibleReaderCommentaryAnchorOwner()

        owner.acceptVisibleOrdinal(11, identity: first)
        XCTAssertEqual(
            owner.replacementOrdinal(
                for: first,
                contentOrdinalRange: 0...47,
                persistedOrdinal: 11
            ),
            11
        )
        XCTAssertEqual(
            owner.replacementOrdinal(
                for: second,
                contentOrdinalRange: 0...8,
                persistedOrdinal: 11
            ),
            0
        )

        owner.commitReplacement(ordinal: 0, identity: second)
        XCTAssertEqual(
            owner.replacementOrdinal(
                for: first,
                contentOrdinalRange: 0...47,
                persistedOrdinal: 11
            ),
            0
        )
    }

    /**
     Verifies one local BVA cannot cross a pane, source-generation, or fragment-range boundary.

     - Side effects: Mutates one value-type owner.
     - Failure modes: Fails if source replacement/relock or pane reassignment can reuse stale local
       geometry, or if an ordinal absent from the new fragment is emitted to Vue.
     */
    func testStaleSourcePaneAndRangeFallBackToBeginning() {
        let graph = detachedPaneGraph()
        let accepted = identity(window: graph.window, pageManager: graph.pageManager, key: "Gen.1.24")
        var owner = BibleReaderCommentaryAnchorOwner()
        owner.acceptVisibleOrdinal(11, identity: accepted)

        let changedSource = identity(
            window: graph.window,
            pageManager: graph.pageManager,
            key: "Gen.1.24",
            dependencies: [.persisted(kind: "commentary", identity: "CALVIN", revision: "2")]
        )
        XCTAssertEqual(
            owner.replacementOrdinal(
                for: changedSource,
                contentOrdinalRange: 0...47,
                persistedOrdinal: 11
            ),
            0
        )

        let otherGraph = detachedPaneGraph()
        let otherPageManager = identity(
            window: otherGraph.window,
            pageManager: otherGraph.pageManager,
            key: "Gen.1.24"
        )
        XCTAssertEqual(
            owner.replacementOrdinal(
                for: otherPageManager,
                contentOrdinalRange: 0...47,
                persistedOrdinal: 11
            ),
            0
        )
        XCTAssertEqual(
            owner.replacementOrdinal(
                for: accepted,
                contentOrdinalRange: 0...10,
                persistedOrdinal: 11
            ),
            0
        )
        XCTAssertEqual(
            owner.replacementOrdinal(
                for: accepted,
                contentOrdinalRange: 0...47,
                persistedOrdinal: 7
            ),
            0
        )
    }

    /**
     Verifies an accepted ownerless full replacement cannot revive the preceding viewport.

     - Side effects: Records and clears one value-type receipt.
     - Failure modes: Fails if clearing an accepted targetless or pane-less replacement preserves
       an older exact identity for a later reload.
     */
    func testAcceptedOwnerlessReplacementRetiresPriorReceipt() {
        let graph = detachedPaneGraph()
        let identity = identity(window: graph.window, pageManager: graph.pageManager, key: "Gen.1.24")
        var owner = BibleReaderCommentaryAnchorOwner()
        owner.acceptVisibleOrdinal(11, identity: identity)

        owner.clear()

        XCTAssertEqual(
            owner.replacementOrdinal(
                for: identity,
                contentOrdinalRange: 0...47,
                persistedOrdinal: 11
            ),
            0
        )
    }

    /**
     Verifies SwiftData wrappers for one durable pane retain ownership while another row with the
     same domain UUID is rejected.

     - Side effects: Creates one disk-backed workspace store and opens independent model contexts.
     - Failure modes: Throws if the persistent fixture cannot save or refetch its graph; fails if
       owner equality follows transient wrapper identity or the mutable UUID field.
     */
    func testDiskBackedRematerializedPageManagerRetainsExactOwner() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("commentary-owner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistentContainer = try makePersistentContainer(
            at: directory.appendingPathComponent("Workspace.store")
        )
        let domainID = UUID()

        let writer = ModelContext(persistentContainer)
        let storedWindow = Window(id: domainID)
        let storedPageManager = PageManager(id: domainID)
        writer.insert(storedWindow)
        writer.insert(storedPageManager)
        storedWindow.pageManager = storedPageManager
        let insertedIdentity = identity(
            window: storedWindow,
            pageManager: storedPageManager,
            key: "Gen.1.24"
        )
        var insertionOwner = BibleReaderCommentaryAnchorOwner()
        insertionOwner.acceptVisibleOrdinal(7, identity: insertedIdentity)
        try writer.save()
        let savedIdentity = identity(
            window: storedWindow,
            pageManager: storedPageManager,
            key: "Gen.1.24"
        )
        XCTAssertEqual(
            insertionOwner.replacementOrdinal(
                for: savedIdentity,
                contentOrdinalRange: 0...47,
                persistedOrdinal: 7
            ),
            insertedIdentity == savedIdentity ? 7 : 0
        )
        insertionOwner.commitReplacement(ordinal: 7, identity: savedIdentity)
        XCTAssertEqual(
            insertionOwner.replacementOrdinal(
                for: savedIdentity,
                contentOrdinalRange: 0...47,
                persistedOrdinal: 7
            ),
            7
        )

        let firstContext = ModelContext(persistentContainer)
        let firstWindow = try XCTUnwrap(try firstContext.fetch(FetchDescriptor<Window>()).first)
        let firstPageManager = try XCTUnwrap(firstWindow.pageManager)
        let accepted = identity(
            window: firstWindow,
            pageManager: firstPageManager,
            key: "Gen.1.24"
        )
        var owner = BibleReaderCommentaryAnchorOwner()
        owner.acceptVisibleOrdinal(11, identity: accepted)

        let secondContext = ModelContext(persistentContainer)
        let secondWindow = try XCTUnwrap(try secondContext.fetch(FetchDescriptor<Window>()).first)
        let secondPageManager = try XCTUnwrap(secondWindow.pageManager)
        XCTAssertNotEqual(ObjectIdentifier(firstPageManager), ObjectIdentifier(secondPageManager))
        XCTAssertEqual(firstPageManager.persistentModelID, secondPageManager.persistentModelID)
        XCTAssertEqual(
            owner.replacementOrdinal(
                for: identity(
                    window: secondWindow,
                    pageManager: secondPageManager,
                    key: "Gen.1.24"
                ),
                contentOrdinalRange: 0...47,
                persistedOrdinal: 11
            ),
            11
        )

        let replacementWindow = Window(id: domainID)
        let replacementPageManager = PageManager(id: domainID)
        writer.insert(replacementWindow)
        writer.insert(replacementPageManager)
        replacementWindow.pageManager = replacementPageManager
        try writer.save()
        XCTAssertNotEqual(firstPageManager.persistentModelID, replacementPageManager.persistentModelID)
        XCTAssertEqual(
            owner.replacementOrdinal(
                for: identity(
                    window: replacementWindow,
                    pageManager: replacementPageManager,
                    key: "Gen.1.24"
                ),
                contentOrdinalRange: 0...47,
                persistedOrdinal: 11
            ),
            0
        )
    }

    private func identity(
        window: Window,
        pageManager: PageManager,
        key: String,
        dependencies: [BibleReaderPreparationSourceDependency] = [.independent]
    ) -> BibleReaderCommentaryAnchorIdentity {
        BibleReaderCommentaryAnchorIdentity(
            paneOwner: BibleReaderCommentaryAnchorPaneOwner(
                pageManager: pageManager.persistentModelID,
                window: window.persistentModelID,
                paneID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
                workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")
            ),
            moduleInitials: "CALVIN",
            target: BibleReaderCommentaryNavigationTarget(
                key: key,
                sourceReference: SwordVersification.Reference(
                    osisBookId: "Gen",
                    chapter: Int(key.split(separator: ".")[1]) ?? 1,
                    verse: Int(key.split(separator: ".")[2]) ?? 1
                ),
                sourceOrdinal: 24
            ),
            sourceDependencies: dependencies
        )
    }

    private func detachedPaneGraph() -> (window: Window, pageManager: PageManager) {
        let window = Window()
        let pageManager = PageManager(id: window.id)
        context.insert(window)
        context.insert(pageManager)
        window.pageManager = pageManager
        return (window, pageManager)
    }

    private func makePersistentContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([
            Setting.self,
            Workspace.self,
            Window.self,
            PageManager.self,
            HistoryItem.self,
        ])
        let configuration = ModelConfiguration(
            "CommentaryAnchorOwner",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
