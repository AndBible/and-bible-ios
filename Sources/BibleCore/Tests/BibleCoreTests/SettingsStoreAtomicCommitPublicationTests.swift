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
        modelContext.autosaveEnabled = true
        var callbackAutosaveEnabled: Bool?
        var callbackCount = 0
        var observedCommittedValue: String?
        var reentrantError: Error?

        try settingsStore.performAtomicBatch(
            in: modelContext,
            afterSuccessfulCommit: {
                callbackCount += 1
                callbackAutosaveEnabled = modelContext.autosaveEnabled
                observedCommittedValue = SettingsStore(
                    modelContext: ModelContext(container)
                ).getString("atomic.primary")
                do {
                    let reentrantStore = SettingsStore(modelContext: modelContext)
                    try reentrantStore.performAtomicBatch(in: modelContext) {
                        reentrantStore.setString("atomic.reentrant", value: "published")
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
        XCTAssertEqual(callbackAutosaveEnabled, true)
        XCTAssertTrue(modelContext.autosaveEnabled)
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
        modelContext.autosaveEnabled = true
        modelContext.insert(Setting(key: "journal.graph", value: "pending"))
        var publications = 0
        var observedGraphValue: String?
        var reentrantError: Error?

        try settingsStore.performJournaledSave(in: modelContext) {
            try settingsStore.performAtomicBatch(
                in: modelContext,
                afterSuccessfulCommit: {
                    publications += 1
                    XCTAssertTrue(modelContext.autosaveEnabled)
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

    /**
     A second facade cannot make an outer batch's rejected settings durable.

     Both stores use the same context, matching services that construct a facade inside a callback.
     A fresh context must observe neither write after rejection, even if the second facade normally
     saves immediately. The production model partitions live on process-owned disk fixtures.
     */
    func testSecondFacadeWriteRemainsInsideRejectedOuterBatch() throws {
        let directory = try makeProcessLifetimePersistentStoreDirectory(
            label: "settings-second-facade-rejection"
        )
        let container = try makePersistentContainer(in: directory)
        let context = ModelContext(container)
        let outer = SettingsStore(modelContext: context)
        var publications = 0

        XCTAssertThrowsError(
            try outer.performAtomicBatch(
                in: context,
                afterSuccessfulCommit: { publications += 1 }
            ) {
                outer.setString("facade.outer", value: "rejected")
                let other = SettingsStore(modelContext: context)
                other.setString("facade.other", value: "rejected")
                throw PublicationFailure.expected
            }
        ) { error in
            XCTAssertEqual(error as? PublicationFailure, .expected)
        }

        let reopened = SettingsStore(modelContext: ModelContext(container))
        XCTAssertNil(reopened.getString("facade.outer"))
        XCTAssertNil(reopened.getString("facade.other"))
        XCTAssertEqual(publications, 0)
    }

    /**
     A handled child failure still invalidates an outer batch across store facades.

     The child starts before any pending write so this tests failure ownership independently of
     clean-context admission. Handling its error must not permit a later outer write or success
     callback to escape. Fresh-context reads check the durable result in the production partitions.
     */
    func testCaughtSecondFacadeFailureInvalidatesOuterBatch() throws {
        let directory = try makeProcessLifetimePersistentStoreDirectory(
            label: "settings-second-facade-caught-failure"
        )
        let container = try makePersistentContainer(in: directory)
        let context = ModelContext(container)
        let outer = SettingsStore(modelContext: context)
        var childFailure: PublicationFailure?
        var publications: [String] = []

        XCTAssertThrowsError(
            try outer.performAtomicBatch(
                in: context,
                afterSuccessfulCommit: { publications.append("outer") }
            ) {
                let other = SettingsStore(modelContext: context)
                do {
                    try other.performAtomicBatch(
                        in: context,
                        afterSuccessfulCommit: { publications.append("child") }
                    ) {
                        other.setString("facade.child", value: "rejected")
                        throw PublicationFailure.expected
                    }
                } catch let error as PublicationFailure {
                    childFailure = error
                }
                outer.setString("facade.after-child", value: "rejected")
            }
        ) { error in
            XCTAssertEqual(error as? PublicationFailure, .expected)
        }

        XCTAssertEqual(childFailure, .expected)
        XCTAssertTrue(publications.isEmpty)
        let reopened = SettingsStore(modelContext: ModelContext(container))
        XCTAssertNil(reopened.getString("facade.child"))
        XCTAssertNil(reopened.getString("facade.after-child"))
    }

    /** A nested context owner does not hide an ancestor owner for a late facade. */
    func testDifferentContextChildCommitsWhileAncestorWriteRollsBack() throws {
        let directoryA = try makeProcessLifetimePersistentStoreDirectory(
            label: "settings-context-owner-ancestor-a"
        )
        let directoryB = try makeProcessLifetimePersistentStoreDirectory(
            label: "settings-context-owner-ancestor-b"
        )
        let containerA = try makePersistentContainer(in: directoryA)
        let containerB = try makePersistentContainer(in: directoryB)
        let contextA = ModelContext(containerA)
        let contextB = ModelContext(containerB)
        let outerA = SettingsStore(modelContext: contextA)
        let outerB = SettingsStore(modelContext: contextB)

        XCTAssertThrowsError(
            try outerA.performAtomicBatch(in: contextA) {
                try outerB.performAtomicBatch(in: contextB) {
                    let lateA = SettingsStore(modelContext: contextA)
                    let lateB = SettingsStore(modelContext: contextB)
                    lateA.setString("owner.ancestor.a", value: "rejected")
                    lateB.setString("owner.independent.b", value: "committed")
                }
                throw PublicationFailure.expected
            }
        ) { error in
            XCTAssertEqual(error as? PublicationFailure, .expected)
        }

        let reopenedA = SettingsStore(modelContext: ModelContext(containerA))
        let reopenedB = SettingsStore(modelContext: ModelContext(containerB))
        XCTAssertNil(reopenedA.getString("owner.ancestor.a"))
        XCTAssertEqual(reopenedB.getString("owner.independent.b"), "committed")
    }

    /** A handled failure owned by context B does not poison context A's outer batch. */
    func testCaughtDifferentContextFailureAllowsOuterContextCommit() throws {
        let directoryA = try makeProcessLifetimePersistentStoreDirectory(
            label: "settings-context-owner-independent-failure-a"
        )
        let directoryB = try makeProcessLifetimePersistentStoreDirectory(
            label: "settings-context-owner-independent-failure-b"
        )
        let containerA = try makePersistentContainer(in: directoryA)
        let containerB = try makePersistentContainer(in: directoryB)
        let contextA = ModelContext(containerA)
        let contextB = ModelContext(containerB)
        let outerA = SettingsStore(modelContext: contextA)
        let outerB = SettingsStore(modelContext: contextB)
        var childFailure: PublicationFailure?

        try outerA.performAtomicBatch(in: contextA) {
            do {
                try outerB.performAtomicBatch(in: contextB) {
                    SettingsStore(modelContext: contextB)
                        .setString("owner.failed.b", value: "rejected")
                    throw PublicationFailure.expected
                }
            } catch let error as PublicationFailure {
                childFailure = error
            }
            SettingsStore(modelContext: contextA)
                .setString("owner.committed.a", value: "committed")
        }

        XCTAssertEqual(childFailure, .expected)
        let reopenedA = SettingsStore(modelContext: ModelContext(containerA))
        let reopenedB = SettingsStore(modelContext: ModelContext(containerB))
        XCTAssertEqual(reopenedA.getString("owner.committed.a"), "committed")
        XCTAssertNil(reopenedB.getString("owner.failed.b"))
    }

    /** A journal owner rejects an atomic child's recovery contract before child mutation. */
    func testCaughtAtomicRecoveryUnderJournalOwnerRejectsOuterBoundary() throws {
        let directory = try makeProcessLifetimePersistentStoreDirectory(
            label: "settings-journal-owner-recovery-rejection"
        )
        let container = try makePersistentContainer(in: directory)
        let context = ModelContext(container)
        let journalFacade = SettingsStore(modelContext: context)
        context.insert(Setting(key: "journal.pending", value: "rejected"))
        var childMutationRan = false
        var publications = 0
        var childError: SettingsStoreAtomicBatchError?

        XCTAssertThrowsError(
            try journalFacade.performJournaledSave(
                in: context,
                afterSuccessfulCommit: { publications += 1 }
            ) {
                let atomicFacade = SettingsStore(modelContext: context)
                do {
                    try atomicFacade.performAtomicBatch(
                        in: context,
                        durableRecovery: { _ in },
                        afterSuccessfulCommit: { publications += 1 }
                    ) {
                        childMutationRan = true
                        atomicFacade.setString("journal.child", value: "must-not-run")
                    }
                } catch let error as SettingsStoreAtomicBatchError {
                    childError = error
                }
            }
        ) { error in
            XCTAssertEqual(
                error as? SettingsStoreAtomicBatchError,
                .nestedDurableRecoveryRequiresAtomicOwner
            )
        }

        XCTAssertEqual(childError, .nestedDurableRecoveryRequiresAtomicOwner)
        XCTAssertFalse(childMutationRan)
        XCTAssertEqual(publications, 0)
        XCTAssertFalse(context.hasChanges)
        let reopened = SettingsStore(modelContext: ModelContext(container))
        XCTAssertNil(reopened.getString("journal.pending"))
        XCTAssertNil(reopened.getString("journal.child"))
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
