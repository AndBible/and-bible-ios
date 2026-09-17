import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/** Protects exact SwiftData Window ownership before a Bible history child is staged. */
@MainActor
final class WorkspaceHistoryOwnerTests: XCTestCase {
    /** Verifies foreign, unregistered same-ID, and pending-deleted windows are rejected. */
    func testHistoryAppendRejectsForeignSameIDAndDeletedWindowOwners() throws {
        let directory = try makeProcessLifetimePersistentStoreDirectory(
            label: "issue421-history-owner-rejection-candidate"
        )
        let container = try makePersistentAppContainer(in: directory)
        let seedContext = ModelContext(container)
        seedContext.autosaveEnabled = false
        let seedStore = WorkspaceStore(modelContext: seedContext)
        let workspace = seedStore.createWorkspace(name: "Issue 421 owner")
        let foreignWindow = try XCTUnwrap(workspace.windows?.first)
        let windowID = foreignWindow.id

        let mutationContext = ModelContext(container)
        mutationContext.autosaveEnabled = false
        let mutationStore = WorkspaceStore(modelContext: mutationContext)
        mutationStore.addHistoryItem(
            to: foreignWindow,
            document: "KJV",
            key: "Foreign.1.1"
        )
        mutationStore.addHistoryItem(
            to: Window(id: windowID),
            document: "KJV",
            key: "Replacement.1.1"
        )

        let deletedWorkspace = mutationStore.createWorkspace(name: "Deleted owner")
        let deletedWindow = try XCTUnwrap(deletedWorkspace.windows?.first)
        mutationContext.delete(deletedWindow)
        XCTAssertTrue(deletedWindow.isDeleted)
        mutationStore.addHistoryItem(
            to: deletedWindow,
            document: "KJV",
            key: "Deleted.1.1"
        )

        let verificationContext = ModelContext(container)
        let history = try verificationContext.fetch(FetchDescriptor<HistoryItem>())
        XCTAssertTrue(history.isEmpty)

        let ownedWorkspace = try XCTUnwrap(mutationStore.workspace(id: workspace.id))
        let ownedWindow = try XCTUnwrap(ownedWorkspace.windows?.first)
        mutationStore.addHistoryItem(
            to: ownedWindow,
            document: "KJV",
            key: "Gen.1.1",
            anchorOrdinal: 17
        )

        let acceptedContext = ModelContext(container)
        let accepted = try XCTUnwrap(
            try acceptedContext.fetch(FetchDescriptor<HistoryItem>()).first
        )
        XCTAssertEqual(accepted.document, "KJV")
        XCTAssertEqual(accepted.key, "Gen.1.1")
        XCTAssertEqual(accepted.anchorOrdinal, 17)
        XCTAssertEqual(accepted.window?.id, ownedWindow.id)
        withExtendedLifetime(container) {}
    }

    /** Opens the canonical production-model cloud/local store split used by this fixture. */
    private func makePersistentAppContainer(in directory: URL) throws -> ModelContainer {
        let cloudModels = BibleCoreBaseModelRegistration.cloudModels
            + AIModelRegistration.cloudSyncableModels
        let localModels = BibleCoreBaseModelRegistration.localModels
            + AIModelRegistration.localOnlyModels
        let schema = Schema(cloudModels + localModels)
        let graphConfiguration = ModelConfiguration(
            "Issue421OwnerCloud",
            schema: Schema(cloudModels),
            url: directory.appendingPathComponent("AndBible.store"),
            cloudKitDatabase: .none
        )
        let localConfiguration = ModelConfiguration(
            "Issue421OwnerLocal",
            schema: Schema(localModels),
            url: directory.appendingPathComponent("LocalStore.store"),
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            configurations: [graphConfiguration, localConfiguration]
        )
    }
}
