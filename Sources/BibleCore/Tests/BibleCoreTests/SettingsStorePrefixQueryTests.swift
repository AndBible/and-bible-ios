import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/** Behavioral coverage for semantic prefix reads over the production split settings store. */
@MainActor
final class SettingsStorePrefixQueryTests: XCTestCase {
    /**
     Verifies SQL-bounded and complete-fetch paths both remain supersets of Swift prefix matching.

     The fixture includes exact and adjacent ASCII keys, the maximum Unicode scalar as a suffix,
     canonical-equivalent spellings that binary ordering separates, and unrelated bulk rows. The
     expected set comes from `String.hasPrefix` over the independently declared fixture keys, so a
     persistence bound that drops any semantic match fails at the public store boundary.
     */
    func testEntriesWithPrefixPreserveSwiftSemanticsAcrossBinaryRangeBoundaries() throws {
        let directory = try makeProcessLifetimePersistentStoreDirectory(
            label: "settings-prefix-query-semantics"
        )
        let container = try makeSettingsPrefixPersistentContainer(
            in: directory,
            label: "SettingsPrefixQuerySemantics"
        )
        let writer = ModelContext(container)
        writer.autosaveEnabled = false

        var fixtureKeys = [
            "remote_sync.log",
            "remote_sync.log.alpha",
            "remote_sync.log.\u{10FFFF}tail",
            "remote_sync.lof",
            "remote_sync.logg",
            "remote_sync.lph",
            "K.literal",
            "\u{212A}.kelvin",
            ";.literal",
            "\u{037E}.greek-question",
            "`.literal",
            "\u{1FEF}.greek-varia",
            "Caf\u{00E9}.composed",
            "Cafe\u{0301}.decomposed",
            "emoji.\u{1F9ED}.entry",
            "range.\u{007F}.inside",
            "range.\u{0080}.outside",
            "control.\r\n",
            "control.\r\n.child",
            "control.\r\u{0009}.below",
            "control.\r\u{000B}.outside",
        ]
        fixtureKeys.append(contentsOf: (0..<256).map { "unrelated.namespace.\($0)" })
        for key in fixtureKeys {
            writer.insert(Setting(key: key, value: "value::\(key)"))
        }
        try writer.save()

        XCTAssertTrue("\u{212A}.kelvin".hasPrefix("K"))
        XCTAssertTrue("\u{037E}.greek-question".hasPrefix(";"))
        XCTAssertTrue("\u{1FEF}.greek-varia".hasPrefix("`"))
        XCTAssertTrue("Cafe\u{0301}.decomposed".hasPrefix("Caf\u{00E9}"))

        let reader = ModelContext(container)
        reader.autosaveEnabled = false
        let settingsStore = SettingsStore(modelContext: reader)
        let prefixes = [
            "remote_sync.log",
            "remote_sync.log.",
            "range.\u{007F}",
            "control.\r\n",
            "emoji.\u{1F9ED}",
            "Caf\u{00E9}",
            "Cafe\u{0301}",
            "K",
            ";",
            "`",
            "",
        ]

        for prefix in prefixes {
            let expected = Set(fixtureKeys.filter { $0.hasPrefix(prefix) })
            let actual = Set(settingsStore.entries(withPrefix: prefix).map(\.key))
            XCTAssertEqual(actual, expected, "prefix=\(prefix.debugDescription)")
        }
    }

    /**
     Verifies a journal-owned prefix read observes the current context generation.

     Direct inserts, deletes, and key changes model the graph/journal callers that query settings
     before their outer `performJournaledSave` commits. The reopened context then proves the same
     exact generation reached the persistent local store.
     */
    func testEntriesWithPrefixObservePendingChangesInsideJournaledSave() throws {
        let directory = try makeProcessLifetimePersistentStoreDirectory(
            label: "settings-prefix-query-journal"
        )
        let container = try makeSettingsPrefixPersistentContainer(
            in: directory,
            label: "SettingsPrefixQueryJournal"
        )
        let modelContext = ModelContext(container)
        modelContext.autosaveEnabled = false
        let settingsStore = SettingsStore(modelContext: modelContext)
        let deleted = Setting(key: "remote_sync.pending.deleted", value: "deleted")
        let movedOutside = Setting(key: "remote_sync.pending.moved-out", value: "moved-out")
        let movedInside = Setting(key: "outside.pending.moved-in", value: "moved-in")
        modelContext.insert(deleted)
        modelContext.insert(movedOutside)
        modelContext.insert(movedInside)
        try modelContext.save()

        let expectedKeys: Set<String> = [
            "remote_sync.pending.direct",
            "remote_sync.pending.store",
            "remote_sync.pending.moved-in",
        ]
        try settingsStore.performJournaledSave(in: modelContext) {
            modelContext.insert(Setting(key: "remote_sync.pending.direct", value: "direct"))
            settingsStore.setString("remote_sync.pending.store", value: "store")
            modelContext.delete(deleted)
            movedOutside.key = "outside.pending.moved-out"
            movedInside.key = "remote_sync.pending.moved-in"

            XCTAssertEqual(
                Set(settingsStore.entries(withPrefix: "remote_sync.pending.").map(\.key)),
                expectedKeys
            )
        }

        let reopenedStore = SettingsStore(modelContext: ModelContext(container))
        XCTAssertEqual(
            Set(reopenedStore.entries(withPrefix: "remote_sync.pending.").map(\.key)),
            expectedKeys
        )
        XCTAssertNil(reopenedStore.getString("remote_sync.pending.deleted"))
        XCTAssertEqual(reopenedStore.getString("outside.pending.moved-out"), "moved-out")
    }
}

/** Builds the complete app model families over separate process-lifetime cloud and local stores. */
private func makeSettingsPrefixPersistentContainer(
    in directory: URL,
    label: String
) throws -> ModelContainer {
    let cloudModels = BibleCoreBaseModelRegistration.cloudModels
        + AIModelRegistration.cloudSyncableModels
    let localModels = BibleCoreBaseModelRegistration.localModels
        + AIModelRegistration.localOnlyModels
    let schema = Schema(cloudModels + localModels)
    return try ModelContainer(
        for: schema,
        configurations: [
            ModelConfiguration(
                "\(label)Cloud",
                schema: Schema(cloudModels),
                url: directory.appendingPathComponent("\(label)Cloud.store"),
                cloudKitDatabase: .none
            ),
            ModelConfiguration(
                "\(label)Local",
                schema: Schema(localModels),
                url: directory.appendingPathComponent("\(label)Local.store"),
                cloudKitDatabase: .none
            ),
        ]
    )
}
