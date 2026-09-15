import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/**
 Behavioral coverage for context-owned staged setting values.

 These tests exercise only public or package-visible `SettingsStore` reads and mutations. They use
 the complete production cloud/local model split on process-lifetime disk stores, disable autosave
 explicitly, and observe caller-context plus fresh-context outcomes. They do not inspect the atomic
 owner, its overlay, materialization counts, or private transaction state.
 */
@MainActor
final class SettingsStoreStagedValueTests: XCTestCase {
    /** A large replacement preserves unrelated values and previously retained read snapshots. */
    func testLargeReplacementPublishesEveryFinalValueAndKeepsReadSnapshotsDetached() throws {
        let fixture = try makeStagedValueFixture(label: "settings-staged-large-replacement")
        let context = ModelContext(fixture.container)
        context.autosaveEnabled = false
        let store = SettingsStore(modelContext: context)
        let original = Dictionary(uniqueKeysWithValues: (0..<1200).map {
            ("large.\($0)", "old-\($0)")
        })
        try store.performAtomicBatch(in: context) {
            for (key, value) in original { store.setString(key, value: value) }
            store.setString("unrelated.keep", value: "unchanged")
        }
        let retained = store.entries(withPrefix: "large.")
        var expected: [String: String] = [:]
        for index in 0..<1400 where index >= 1200 || index % 4 != 0 {
            expected["large.\(index)"] = "new-\(index)"
        }

        try store.performAtomicBatch(in: context) {
            for index in 0..<1400 {
                let key = "large.\(index)"
                if let value = expected[key] { store.setString(key, value: value) }
                else { store.remove(key) }
            }
            XCTAssertEqual(entryValues(store.entries(withPrefix: "large.")), expected)
            XCTAssertEqual(entryValues(retained), original)
        }

        let reopened = SettingsStore(modelContext: ModelContext(fixture.container))
        XCTAssertEqual(entryValues(reopened.entries(withPrefix: "large.")), expected)
        XCTAssertEqual(reopened.getString("unrelated.keep"), "unchanged")
        XCTAssertEqual(entryValues(retained), original)
    }

    /** A late facade reads outer writes through scalar, prefix, and exact-namespace APIs. */
    func testLateFacadeReadsStagedValuesAcrossEverySettingsReadShape() throws {
        let fixture = try makeStagedValueFixture(label: "settings-staged-read-shapes")
        let context = ModelContext(fixture.container)
        context.autosaveEnabled = false
        let outer = SettingsStore(modelContext: context)
        outer.setString("readshape.namespace.old", value: "durable-old")
        outer.setString("readshape.outside", value: "outside")

        try outer.performAtomicBatch(in: context) {
            outer.setString("readshape.namespace.old", value: "staged-update")
            outer.setString("readshape.namespace.new", value: "staged-insert")
            let late = SettingsStore(modelContext: context)

            XCTAssertEqual(late.getString("readshape.namespace.old"), "staged-update")
            XCTAssertEqual(
                entryValues(late.entries(withPrefix: "readshape.namespace.")),
                [
                    "readshape.namespace.new": "staged-insert",
                    "readshape.namespace.old": "staged-update",
                ]
            )
            XCTAssertEqual(
                entryValues(late.entries(inExactNamespace: "readshape.namespace")),
                [
                    "readshape.namespace.new": "staged-insert",
                    "readshape.namespace.old": "staged-update",
                ]
            )
            XCTAssertEqual(late.getString("readshape.outside"), "outside")
        }

        let reopened = SettingsStore(modelContext: ModelContext(fixture.container))
        XCTAssertEqual(reopened.getString("readshape.namespace.old"), "staged-update")
        XCTAssertEqual(reopened.getString("readshape.namespace.new"), "staged-insert")
        XCTAssertEqual(reopened.getString("readshape.outside"), "outside")
        withExtendedLifetime(fixture.container) {}
    }

    /** Prefix replacement composes tombstones and later writes into one final generation. */
    func testPrefixClearThenReinsertExposesOnlyTheFinalGeneration() throws {
        let fixture = try makeStagedValueFixture(label: "settings-staged-prefix-replace")
        let context = ModelContext(fixture.container)
        context.autosaveEnabled = false
        let store = SettingsStore(modelContext: context)
        store.setString("replace.alpha", value: "old-alpha")
        store.setString("replace.beta", value: "old-beta")
        store.setString("replacement.neighbor", value: "keep")

        try store.performAtomicBatch(in: context) {
            for entry in store.entries(withPrefix: "replace.") {
                store.remove(entry.key)
            }
            XCTAssertTrue(store.entries(withPrefix: "replace.").isEmpty)

            store.setString("replace.alpha", value: "new-alpha")
            store.remove("replace.alpha")
            store.setString("replace.alpha", value: "final-alpha")
            store.setString("replace.gamma", value: "new-gamma")

            XCTAssertEqual(
                entryValues(store.entries(withPrefix: "replace.")),
                [
                    "replace.alpha": "final-alpha",
                    "replace.gamma": "new-gamma",
                ]
            )
            XCTAssertEqual(store.getString("replacement.neighbor"), "keep")
        }

        let reopened = SettingsStore(modelContext: ModelContext(fixture.container))
        XCTAssertEqual(
            entryValues(reopened.entries(withPrefix: "replace.")),
            [
                "replace.alpha": "final-alpha",
                "replace.gamma": "new-gamma",
            ]
        )
        XCTAssertEqual(reopened.getString("replacement.neighbor"), "keep")
        withExtendedLifetime(fixture.container) {}
    }

    /** Rejection leaves old caller and disk values intact, and the exact mutation can retry. */
    func testRejectedSettingsOnlyGenerationPreservesOldValuesAndExactRetryCommits() throws {
        let fixture = try makeStagedValueFixture(label: "settings-staged-reject-retry")
        let context = ModelContext(fixture.container)
        context.autosaveEnabled = false
        let store = SettingsStore(modelContext: context)
        store.setString("retry.update", value: "old-update")
        store.setString("retry.remove", value: "old-remove")

        XCTAssertThrowsError(
            try store.performAtomicBatch(in: context) {
                applyRetryGeneration(to: SettingsStore(modelContext: context))
                XCTAssertEqual(
                    entryValues(store.entries(withPrefix: "retry.")),
                    [
                        "retry.insert": "new-insert",
                        "retry.update": "new-update",
                    ]
                )
                throw StagedValueFailure.expected
            }
        ) { error in
            XCTAssertEqual(error as? StagedValueFailure, .expected)
        }

        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(
            entryValues(store.entries(withPrefix: "retry.")),
            [
                "retry.remove": "old-remove",
                "retry.update": "old-update",
            ]
        )
        let rejectedDisk = SettingsStore(modelContext: ModelContext(fixture.container))
        XCTAssertEqual(
            entryValues(rejectedDisk.entries(withPrefix: "retry.")),
            [
                "retry.remove": "old-remove",
                "retry.update": "old-update",
            ]
        )

        try store.performAtomicBatch(in: context) {
            applyRetryGeneration(to: SettingsStore(modelContext: context))
        }

        let retriedDisk = SettingsStore(modelContext: ModelContext(fixture.container))
        let expectedRetry = [
            "retry.insert": "new-insert",
            "retry.update": "new-update",
        ]
        XCTAssertEqual(entryValues(store.entries(withPrefix: "retry.")), expectedRetry)
        XCTAssertEqual(entryValues(retriedDisk.entries(withPrefix: "retry.")), expectedRetry)
        withExtendedLifetime(fixture.container) {}
    }

    /** Staged prefix filtering retains Swift canonical-equivalence semantics. */
    func testStagedPrefixReadsPreserveCanonicalEquivalentUnicodeMatches() throws {
        let fixture = try makeStagedValueFixture(label: "settings-staged-unicode-prefix")
        let context = ModelContext(fixture.container)
        context.autosaveEnabled = false
        let store = SettingsStore(modelContext: context)
        let staged = [
            "Cafe\u{0301}.decomposed": "accent",
            "\u{212A}.kelvin": "kelvin",
            "\u{037E}.greek-question": "semicolon",
            "\u{1FEF}.greek-varia": "grave",
        ]

        try store.performAtomicBatch(in: context) {
            for (key, value) in staged {
                SettingsStore(modelContext: context).setString(key, value: value)
            }

            XCTAssertEqual(
                entryValues(store.entries(withPrefix: "Caf\u{00E9}")),
                ["Cafe\u{0301}.decomposed": "accent"]
            )
            XCTAssertEqual(
                entryValues(store.entries(withPrefix: "K")),
                ["\u{212A}.kelvin": "kelvin"]
            )
            XCTAssertEqual(
                entryValues(store.entries(withPrefix: ";")),
                ["\u{037E}.greek-question": "semicolon"]
            )
            XCTAssertEqual(
                entryValues(store.entries(withPrefix: "`")),
                ["\u{1FEF}.greek-varia": "grave"]
            )
        }

        let reopened = SettingsStore(modelContext: ModelContext(fixture.container))
        XCTAssertEqual(
            entryValues(reopened.entries(withPrefix: "Caf\u{00E9}")),
            ["Cafe\u{0301}.decomposed": "accent"]
        )
        XCTAssertEqual(Set(reopened.entries(withPrefix: "").map(\.key)), Set(staged.keys))
        withExtendedLifetime(fixture.container) {}
    }

    /** Nested owners for different contexts do not expose or discard each other's staged values. */
    func testNestedIndependentContextsKeepTheirStagedGenerationsIsolated() throws {
        let fixtureA = try makeStagedValueFixture(label: "settings-staged-isolation-a")
        let fixtureB = try makeStagedValueFixture(label: "settings-staged-isolation-b")
        let contextA = ModelContext(fixtureA.container)
        let contextB = ModelContext(fixtureB.container)
        contextA.autosaveEnabled = false
        contextB.autosaveEnabled = false
        let storeA = SettingsStore(modelContext: contextA)
        let storeB = SettingsStore(modelContext: contextB)

        XCTAssertThrowsError(
            try storeA.performAtomicBatch(in: contextA) {
                storeA.setString("isolation.shared", value: "context-a")
                XCTAssertNil(storeB.getString("isolation.shared"))

                try storeB.performAtomicBatch(in: contextB) {
                    SettingsStore(modelContext: contextB)
                        .setString("isolation.shared", value: "context-b")
                    XCTAssertEqual(storeB.getString("isolation.shared"), "context-b")
                    XCTAssertEqual(
                        SettingsStore(modelContext: contextA).getString("isolation.shared"),
                        "context-a"
                    )
                }
                XCTAssertEqual(storeB.getString("isolation.shared"), "context-b")
                throw StagedValueFailure.expected
            }
        ) { error in
            XCTAssertEqual(error as? StagedValueFailure, .expected)
        }

        XCTAssertNil(SettingsStore(modelContext: ModelContext(fixtureA.container))
            .getString("isolation.shared"))
        XCTAssertEqual(
            SettingsStore(modelContext: ModelContext(fixtureB.container))
                .getString("isolation.shared"),
            "context-b"
        )
        withExtendedLifetime((fixtureA.container, fixtureB.container)) {}
    }

    /** A journal owner merges pending graph/direct rows with staged facade values. */
    func testJournalOwnerReadsPreStagedGraphAndDirectSettingWithOverlayValues() throws {
        let fixture = try makeStagedValueFixture(label: "settings-staged-journal-mixed")
        let context = ModelContext(fixture.container)
        context.autosaveEnabled = false
        let store = SettingsStore(modelContext: context)
        let workspaceID = UUID()
        context.insert(Workspace(id: workspaceID, name: "Pending graph", orderNumber: 0))
        context.insert(Setting(key: "journal.direct", value: "direct-before-owner"))

        try store.performJournaledSave(in: context) {
            SettingsStore(modelContext: context)
                .setString("journal.direct", value: "overlay-wins")
            SettingsStore(modelContext: context)
                .setString("journal.insert", value: "overlay-insert")

            XCTAssertEqual(store.getString("journal.direct"), "overlay-wins")
            XCTAssertEqual(
                entryValues(store.entries(withPrefix: "journal.")),
                [
                    "journal.direct": "overlay-wins",
                    "journal.insert": "overlay-insert",
                ]
            )
        }

        let reopenedContext = ModelContext(fixture.container)
        reopenedContext.autosaveEnabled = false
        let reopened = SettingsStore(modelContext: reopenedContext)
        XCTAssertEqual(
            entryValues(reopened.entries(withPrefix: "journal.")),
            [
                "journal.direct": "overlay-wins",
                "journal.insert": "overlay-insert",
            ]
        )
        let workspaces = try reopenedContext.fetch(FetchDescriptor<Workspace>())
        XCTAssertEqual(workspaces.map(\.id), [workspaceID])
        XCTAssertEqual(workspaces.map(\.name), ["Pending graph"])
        withExtendedLifetime(fixture.container) {}
    }
}

/** Applies the same final settings generation to a rejected attempt and its retry. */
private func applyRetryGeneration(to store: SettingsStore) {
    store.setString("retry.update", value: "new-update")
    store.remove("retry.remove")
    store.setString("retry.insert", value: "new-insert")
}

/** Projects immutable setting entries into an order-independent exact key/value oracle. */
private func entryValues(_ entries: [SettingEntry]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
}

/** Expected failure used to reject an otherwise valid staged settings generation. */
private enum StagedValueFailure: Error, Equatable {
    case expected
}

/** Complete app-model disk fixture retained for the lifetime of one staged-value test. */
private struct StagedValueFixture {
    let directory: URL
    let container: ModelContainer
}

/** Builds the complete app cloud/local model split on process-lifetime persistent stores. */
private func makeStagedValueFixture(label: String) throws -> StagedValueFixture {
    let directory = try makeProcessLifetimePersistentStoreDirectory(label: label)
    let cloudModels = BibleCoreBaseModelRegistration.cloudModels
        + AIModelRegistration.cloudSyncableModels
    let localModels = BibleCoreBaseModelRegistration.localModels
        + AIModelRegistration.localOnlyModels
    let schema = Schema(cloudModels + localModels)
    let container = try ModelContainer(
        for: schema,
        configurations: [
            ModelConfiguration(
                "\(label)-cloud",
                schema: Schema(cloudModels),
                url: directory.appendingPathComponent("Cloud.store"),
                cloudKitDatabase: .none
            ),
            ModelConfiguration(
                "\(label)-local",
                schema: Schema(localModels),
                url: directory.appendingPathComponent("Local.store"),
                cloudKitDatabase: .none
            ),
        ]
    )
    return StagedValueFixture(directory: directory, container: container)
}
