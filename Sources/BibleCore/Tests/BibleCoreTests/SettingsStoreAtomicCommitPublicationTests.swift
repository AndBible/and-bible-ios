import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/** Transaction-owned success-publication boundaries for `SettingsStore` atomic batches. */
@MainActor
final class SettingsStoreAtomicCommitPublicationTests: XCTestCase {
    /** A success publication observes durable rows and may safely begin another outer batch. */
    func testSuccessfulCommitActionRunsAfterDurabilityAndOwnerReset() throws {
        let storeDirectory = try makeProcessLifetimePersistentStoreDirectory(
            label: "settings-atomic-success-publication"
        )
        let container = try makePersistentContainer(in: storeDirectory)
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        var callbackCount = 0
        var observedCommittedValue: String?
        var reentrantError: Error?

        try settingsStore.performAtomicBatch(
            in: modelContext,
            afterSuccessfulCommit: {
                callbackCount += 1
                observedCommittedValue = SettingsStore(
                    modelContext: ModelContext(container)
                ).getString("atomic.primary")
                do {
                    try settingsStore.performAtomicBatch(in: modelContext) {
                        settingsStore.setString("atomic.reentrant", value: "published")
                    }
                } catch {
                    reentrantError = error
                }
            }
        ) {
            settingsStore.setString("atomic.primary", value: "committed")
            XCTAssertEqual(callbackCount, 0)
        }

        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(observedCommittedValue, "committed")
        XCTAssertNil(reentrantError)
        XCTAssertEqual(
            SettingsStore(modelContext: ModelContext(container)).getString("atomic.reentrant"),
            "published"
        )
    }

    /** Nested actions remain deferred and publish exactly once in registration order. */
    func testNestedSuccessfulCommitActionsJoinOutermostOwner() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        var publications: [String] = []

        try settingsStore.performAtomicBatch(
            in: modelContext,
            afterSuccessfulCommit: { publications.append("outer") }
        ) {
            settingsStore.setString("atomic.outer", value: "one")
            try settingsStore.performAtomicBatch(
                in: modelContext,
                afterSuccessfulCommit: { publications.append("inner") }
            ) {
                settingsStore.setString("atomic.inner", value: "two")
            }
            XCTAssertTrue(publications.isEmpty)
        }

        XCTAssertEqual(publications, ["outer", "inner"])
        let reopenedStore = SettingsStore(modelContext: ModelContext(container))
        XCTAssertEqual(reopenedStore.getString("atomic.outer"), "one")
        XCTAssertEqual(reopenedStore.getString("atomic.inner"), "two")
    }

    /** A caught nested error invalidates the outer batch and discards every success action. */
    func testCaughtNestedFailureDiscardsSuccessfulCommitActions() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        var publications: [String] = []

        XCTAssertThrowsError(
            try settingsStore.performAtomicBatch(
                in: modelContext,
                afterSuccessfulCommit: { publications.append("outer") }
            ) {
                settingsStore.setString("atomic.outer", value: "uncommitted")
                do {
                    try settingsStore.performAtomicBatch(
                        in: modelContext,
                        afterSuccessfulCommit: { publications.append("inner") }
                    ) {
                        settingsStore.setString("atomic.inner", value: "uncommitted")
                        throw PublicationFailure.expected
                    }
                } catch PublicationFailure.expected {
                    // The nested boundary records this failure even though this caller handles it.
                }
            }
        ) { error in
            XCTAssertEqual(error as? PublicationFailure, .expected)
        }

        XCTAssertTrue(publications.isEmpty)
        XCTAssertFalse(modelContext.hasChanges)
        let reopenedStore = SettingsStore(modelContext: ModelContext(container))
        XCTAssertNil(reopenedStore.getString("atomic.outer"))
        XCTAssertNil(reopenedStore.getString("atomic.inner"))
    }

    /** An atomic child publishes only after its journaled-save owner commits and resets. */
    func testAtomicActionNestedInJournaledSaveUsesJournalOwnerBoundary() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        modelContext.insert(Setting(key: "journal.graph", value: "pending"))
        var publications = 0
        var observedGraphValue: String?
        var reentrantError: Error?

        try settingsStore.performJournaledSave(in: modelContext) {
            try settingsStore.performAtomicBatch(
                in: modelContext,
                afterSuccessfulCommit: {
                    publications += 1
                    observedGraphValue = SettingsStore(
                        modelContext: ModelContext(container)
                    ).getString("journal.graph")
                    do {
                        try settingsStore.performAtomicBatch(in: modelContext) {
                            settingsStore.setString("journal.reentrant", value: "published")
                        }
                    } catch {
                        reentrantError = error
                    }
                }
            ) {
                settingsStore.setString("journal.child", value: "committed")
            }
            XCTAssertEqual(publications, 0)
        }

        XCTAssertEqual(publications, 1)
        XCTAssertEqual(observedGraphValue, "pending")
        XCTAssertNil(reentrantError)
        let reopenedStore = SettingsStore(modelContext: ModelContext(container))
        XCTAssertEqual(reopenedStore.getString("journal.child"), "committed")
        XCTAssertEqual(reopenedStore.getString("journal.reentrant"), "published")
    }

    /** A caught atomic-child error rolls back its journal owner and emits no success action. */
    func testAtomicFailureNestedInJournaledSaveDiscardsAction() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        modelContext.insert(Setting(key: "journal.graph", value: "uncommitted"))
        var publications = 0

        XCTAssertThrowsError(
            try settingsStore.performJournaledSave(in: modelContext) {
                do {
                    try settingsStore.performAtomicBatch(
                        in: modelContext,
                        afterSuccessfulCommit: { publications += 1 }
                    ) {
                        settingsStore.setString("journal.child", value: "uncommitted")
                        throw PublicationFailure.expected
                    }
                } catch PublicationFailure.expected {
                    // The journal owner still observes the recorded nested transaction failure.
                }
            }
        ) { error in
            XCTAssertEqual(error as? PublicationFailure, .expected)
        }

        XCTAssertEqual(publications, 0)
        XCTAssertFalse(modelContext.hasChanges)
        let reopenedStore = SettingsStore(modelContext: ModelContext(container))
        XCTAssertNil(reopenedStore.getString("journal.graph"))
        XCTAssertNil(reopenedStore.getString("journal.child"))
    }
}

private enum PublicationFailure: Error, Equatable {
    case expected
}

/** Builds the production base-model split over process-lifetime persistent test stores. */
private func makePersistentContainer(in directory: URL) throws -> ModelContainer {
    let cloudModels = BibleCoreBaseModelRegistration.cloudModels
    let localModels = BibleCoreBaseModelRegistration.localModels
    let schema = Schema(cloudModels + localModels)
    return try ModelContainer(
        for: schema,
        configurations: [
            ModelConfiguration(
                "AtomicCommitPublicationCloud",
                schema: Schema(cloudModels),
                url: directory.appendingPathComponent("AtomicCommitPublicationCloud.store"),
                cloudKitDatabase: .none
            ),
            ModelConfiguration(
                "AtomicCommitPublicationLocal",
                schema: Schema(localModels),
                url: directory.appendingPathComponent("AtomicCommitPublicationLocal.store"),
                cloudKitDatabase: .none
            ),
        ]
    )
}
