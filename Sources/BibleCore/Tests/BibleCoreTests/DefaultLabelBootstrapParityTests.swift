import Foundation
import SwiftData
import SwordKit
import XCTest
@testable import BibleCore

/**
 Verifies Android-compatible default-label bootstrap at the journaled BibleCore boundary.

 The fixtures use the app's split graph/settings store shape and reopen fresh containers for every
 durable assertion. They cover only label seeding; Android's example bookmarks and workspaces are
 separate bootstrap behavior.
 */
final class DefaultLabelBootstrapParityTests: XCTestCase {
    /** Android inserts four highlights but no Salvation label when any Bible bookmark exists. */
    func testExistingBibleBookmarkSeedsFourHighlightsInOneJournalGeneration() throws {
        let directory = try makeStoreDirectory("default-label-existing-bookmark")
        var firstLabelIDs: Set<UUID> = []
        var firstMutations: [String: RemoteSyncPendingMutation] = [:]

        try withStore(in: directory) { context, service in
            context.insert(makeBibleBookmark())
            try context.save()

            service.prepareDefaultLabels()

            let labels = try context.fetch(FetchDescriptor<Label>())
            try assertDefaultLabels(labels, includesSalvation: false)
            firstLabelIDs = Set(labels.map(\.id))
            firstMutations = try assertSingleLabelJournalGeneration(
                labels: labels,
                context: context
            )
        }

        try withStore(in: directory) { context, service in
            let labels = try context.fetch(FetchDescriptor<Label>())
            try assertDefaultLabels(labels, includesSalvation: false)
            XCTAssertEqual(Set(labels.map(\.id)), firstLabelIDs)
            let before = try RemoteSyncMutationJournalService().pendingMutations(
                for: .bookmarks,
                settingsStore: SettingsStore(modelContext: context)
            )

            service.prepareDefaultLabels()

            XCTAssertEqual(
                try RemoteSyncMutationJournalService().pendingMutations(
                    for: .bookmarks,
                    settingsStore: SettingsStore(modelContext: context)
                ),
                before
            )
            XCTAssertEqual(before, firstMutations)
            XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Label>()).map(\.id)), firstLabelIDs)
        }
    }

    /** Android adds Salvation with the four highlights only when the Bible table is also empty. */
    func testEmptyBibleLibrarySeedsFiveLabelsInOneJournalGeneration() throws {
        let directory = try makeStoreDirectory("default-label-empty-library")

        try withStore(in: directory) { context, service in
            service.prepareDefaultLabels()

            let labels = try context.fetch(FetchDescriptor<Label>())
            try assertDefaultLabels(labels, includesSalvation: true)
            _ = try assertSingleLabelJournalGeneration(labels: labels, context: context)
        }

        try withStore(in: directory) { context, _ in
            try assertDefaultLabels(
                try context.fetch(FetchDescriptor<Label>()),
                includesSalvation: true
            )
        }
    }

    /** Android's Bible-table guard excludes generic bookmarks, so they still admit Salvation. */
    func testGenericOnlyLibrarySeedsFiveLabelsAndPreservesGenericBookmark() throws {
        let directory = try makeStoreDirectory("default-label-generic-only")
        let bookmarkID = UUID(uuidString: "2B45C67E-0CA3-46D7-A4C7-E4ABDBDF7601")!

        try withStore(in: directory) { context, service in
            context.insert(GenericBookmark(
                id: bookmarkID,
                key: "ENTRY",
                bookInitials: "DICT"
            ))
            try context.save()

            service.prepareDefaultLabels()

            let labels = try context.fetch(FetchDescriptor<Label>())
            try assertDefaultLabels(labels, includesSalvation: true)
            _ = try assertSingleLabelJournalGeneration(labels: labels, context: context)
            XCTAssertEqual(
                try context.fetch(FetchDescriptor<GenericBookmark>()).map(\.id),
                [bookmarkID]
            )
        }

        try withStore(in: directory) { context, _ in
            try assertDefaultLabels(
                try context.fetch(FetchDescriptor<Label>()),
                includesSalvation: true
            )
            XCTAssertEqual(
                try context.fetch(FetchDescriptor<GenericBookmark>()).map(\.id),
                [bookmarkID]
            )
        }
    }

    /** Reserved and exact migrated-note labels do not suppress Android's default highlights. */
    func testReservedAndExactMigratedNoteLabelsDoNotSuppressDefaults() throws {
        let directory = try makeStoreDirectory("default-label-migrated-notes")
        let migratedName = String(
            localized: "migrated_my_notes",
            defaultValue: "Migrated My Notes"
        )

        try withStore(in: directory) { context, service in
            context.insert(Label(name: "__future_system_label"))
            context.insert(Label(name: migratedName))
            try context.save()

            service.prepareDefaultLabels()

            let labels = try context.fetch(FetchDescriptor<Label>())
            XCTAssertEqual(labels.count, 7)
            XCTAssertTrue(labels.contains { SwordJavaStringIdentity.equals($0.name, migratedName) })
            try assertDefaultLabels(
                labels.filter { $0.type == LabelType.highlight.rawValue || $0.type == LabelType.example.rawValue },
                includesSalvation: true
            )
        }
    }

    /** Java-distinct canonical-equivalent text remains a user label and suppresses bootstrap. */
    func testMigratedNoteGuardUsesExactUTF16Identity() {
        let composed = "Migrat\u{00E9}d My Notes"
        let decomposed = "Migrate\u{0301}d My Notes"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf16), Array(decomposed.utf16))

        XCTAssertFalse(BookmarkService.isAndroidBootstrapUserLabelName(
            composed,
            migratedNotesName: composed
        ))
        XCTAssertTrue(BookmarkService.isAndroidBootstrapUserLabelName(
            decomposed,
            migratedNotesName: composed
        ))
        XCTAssertFalse(BookmarkService.isAndroidBootstrapUserLabelName(
            "__reserved",
            migratedNotesName: composed
        ))
    }

    /** A real user label makes the operation a no-op and leaves unrelated pending work unsaved. */
    func testUserLabelNoOpDoesNotCommitCallerPendingChanges() throws {
        let directory = try makeStoreDirectory("default-label-user-no-op")

        try withStore(in: directory) { context, _ in
            context.insert(Label(name: "Reader label"))
            try context.save()
        }

        try withStore(in: directory) { context, service in
            let pending = GenericBookmark(key: "pending", bookInitials: "DICT")
            context.insert(pending)
            XCTAssertTrue(context.hasChanges)

            service.prepareDefaultLabels()

            XCTAssertTrue(context.hasChanges)
            XCTAssertTrue(context.insertedModelsArray.contains { $0 === pending })
            XCTAssertEqual(try context.fetch(FetchDescriptor<Label>()).map(\.name), ["Reader label"])
        }

        try withStore(in: directory) { context, _ in
            XCTAssertTrue(try context.fetch(FetchDescriptor<GenericBookmark>()).isEmpty)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Label>()).map(\.name), ["Reader label"])
        }
    }

    /** A journal validation failure leaves no partial default set in either durable store. */
    func testJournalFailureLeavesNoDurablePartialDefaultSet() throws {
        let directory = try makeStoreDirectory("default-label-journal-failure")
        let corruptKey = "remote_sync.pending_mutations.bookmarks.corrupt"

        try withStore(in: directory) { context, service in
            SettingsStore(modelContext: context).setString(corruptKey, value: "{")
            try context.save()
            XCTAssertEqual(SettingsStore(modelContext: context).getString(corruptKey), "{")

            service.prepareDefaultLabels()

            XCTAssertTrue(try context.fetch(FetchDescriptor<Label>()).isEmpty)
        }

        try withStore(in: directory) { context, _ in
            XCTAssertTrue(try context.fetch(FetchDescriptor<Label>()).isEmpty)
            XCTAssertEqual(SettingsStore(modelContext: context).getString(corruptKey), "{")
            XCTAssertTrue(
                try RemoteSyncLogEntryStore(settingsStore: SettingsStore(modelContext: context))
                    .entriesStrict(for: .bookmarks)
                    .isEmpty
            )
        }
    }

    /** Expected persisted fields for one Android default label. */
    private struct ExpectedLabel {
        let color: Int
        let underlineStyle: Bool
        let underlineStyleWholeVerse: Bool
        let favourite: Bool
        let type: String
    }

    /** Asserts the complete selected default-label set and its output-bearing style fields. */
    private func assertDefaultLabels(
        _ labels: [Label],
        includesSalvation: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var expected: [String: ExpectedLabel] = [
            String(localized: "label_red", defaultValue: "Red"): .init(
                color: Int(Int32(bitPattern: 0xFFFF0000)),
                underlineStyle: false,
                underlineStyleWholeVerse: false,
                favourite: true,
                type: LabelType.highlight.rawValue
            ),
            String(localized: "label_green", defaultValue: "Green"): .init(
                color: Int(Int32(bitPattern: 0xFF00FF00)),
                underlineStyle: false,
                underlineStyleWholeVerse: false,
                favourite: true,
                type: LabelType.highlight.rawValue
            ),
            String(localized: "label_underline", defaultValue: "Underline"): .init(
                color: Int(Int32(bitPattern: 0xFFFF00FF)),
                underlineStyle: true,
                underlineStyleWholeVerse: true,
                favourite: true,
                type: LabelType.highlight.rawValue
            ),
            String(localized: "label_blue", defaultValue: "Blue"): .init(
                color: Int(Int32(bitPattern: 0xFF0000FF)),
                underlineStyle: false,
                underlineStyleWholeVerse: false,
                favourite: true,
                type: LabelType.highlight.rawValue
            ),
        ]
        if includesSalvation {
            expected[String(localized: "label_salvation", defaultValue: "Salvation")] = .init(
                color: Int(Int32(bitPattern: 0xFF640096)),
                underlineStyle: false,
                underlineStyleWholeVerse: true,
                favourite: false,
                type: LabelType.example.rawValue
            )
        }

        XCTAssertEqual(Set(labels.map(\.name)), Set(expected.keys), file: file, line: line)
        XCTAssertEqual(labels.count, expected.count, file: file, line: line)
        for label in labels {
            let value = try XCTUnwrap(expected[label.name], file: file, line: line)
            XCTAssertEqual(label.color, value.color, file: file, line: line)
            XCTAssertEqual(label.markerStyle, false, file: file, line: line)
            XCTAssertEqual(label.markerStyleWholeVerse, false, file: file, line: line)
            XCTAssertEqual(label.underlineStyle, value.underlineStyle, file: file, line: line)
            XCTAssertEqual(
                label.underlineStyleWholeVerse,
                value.underlineStyleWholeVerse,
                file: file,
                line: line
            )
            XCTAssertEqual(label.hideStyle, false, file: file, line: line)
            XCTAssertEqual(label.hideStyleWholeVerse, false, file: file, line: line)
            XCTAssertEqual(label.favourite, value.favourite, file: file, line: line)
            XCTAssertEqual(label.type, value.type, file: file, line: line)
            XCTAssertNil(label.customIcon, file: file, line: line)
        }
    }

    /** Asserts one exact Android journal identity per label at one shared logical timestamp. */
    @discardableResult
    private func assertSingleLabelJournalGeneration(
        labels: [Label],
        context: ModelContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: RemoteSyncPendingMutation] {
        let mutations = try RemoteSyncMutationJournalService().pendingMutations(
            for: .bookmarks,
            settingsStore: SettingsStore(modelContext: context)
        )
        let labelMutations = mutations.values.filter { $0.entry.tableName == "Label" }
        XCTAssertEqual(labelMutations.count, labels.count, file: file, line: line)
        XCTAssertEqual(Set(labelMutations.map(\.entry.lastUpdated)).count, 1, file: file, line: line)
        XCTAssertTrue(labelMutations.allSatisfy { $0.entry.type == .upsert }, file: file, line: line)
        XCTAssertEqual(
            Set(labelMutations.compactMap(\.entry.entityID1.blobBase64Value)),
            Set(labels.map { uuidBlob($0.id).base64EncodedString() }),
            file: file,
            line: line
        )
        XCTAssertTrue(
            labelMutations.allSatisfy { $0.entry.entityID2 == .text("") },
            file: file,
            line: line
        )
        return mutations
    }

    /** Creates a registered, trustworthy Bible row sufficient for Android's nonempty-table guard. */
    private func makeBibleBookmark() -> BibleBookmark {
        BibleBookmark(
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            ordinalStart: 4,
            ordinalEnd: 4,
            v11n: "KJVA",
            bookInitials: "KJVA",
            ordinalTrustMetadata: PersistedOrdinalTrustPolicy.androidImportMetadata(
                sourceVersification: "KJVA",
                sourceOrdinalStart: 4,
                sourceOrdinalEnd: 4,
                kjvaOrdinalStart: 4,
                kjvaOrdinalEnd: 4
            )
        )
    }

    /** Creates a retained test directory for two production-shaped SwiftData store files. */
    private func makeStoreDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /** Opens the split graph/settings stores for one bounded phase and releases them on return. */
    private func withStore(
        in directory: URL,
        _ body: (ModelContext, BookmarkService) throws -> Void
    ) throws {
        let container = try makeContainer(in: directory)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try body(context, BookmarkService(store: BookmarkStore(modelContext: context)))
    }

    /** Builds the app's complete cloud/local model partitions at stable isolated test URLs. */
    private func makeContainer(in directory: URL) throws -> ModelContainer {
        let cloudModels = BibleCoreBaseModelRegistration.cloudModels
            + AIModelRegistration.cloudSyncableModels
        let localModels = BibleCoreBaseModelRegistration.localModels
            + AIModelRegistration.localOnlyModels
        let schema = Schema(cloudModels + localModels)
        let cloudConfiguration = ModelConfiguration(
            "AndBible",
            schema: Schema(cloudModels),
            url: directory.appendingPathComponent("AndBible.store"),
            cloudKitDatabase: .none
        )
        let localConfiguration = ModelConfiguration(
            "LocalStore",
            schema: Schema(localModels),
            url: directory.appendingPathComponent("LocalStore.store"),
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            configurations: [cloudConfiguration, localConfiguration]
        )
    }

    /** Encodes one UUID as Android Room's 16-byte blob without using the production projector. */
    private func uuidBlob(_ value: UUID) -> Data {
        var bytes = value.uuid
        return withUnsafeBytes(of: &bytes) { Data($0) }
    }
}
