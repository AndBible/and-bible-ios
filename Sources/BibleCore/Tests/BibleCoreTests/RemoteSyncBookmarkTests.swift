import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/**
 Package-level remote-sync bookmark restore, patch, and upload contract tests.

 These tests protect Android-compatible bookmark backup databases and sparse patch semantics without
 launching the iOS app target or depending on the app-host test bundle.
 */
final class RemoteSyncBookmarkTests: XCTestCase {
    func testRemoteSyncBookmarkPlaybackSettingsStorePersistsAndClearsEntries() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let store = RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore)
        let bibleBookmarkID = UUID(uuidString: "b1000000-0000-0000-0000-000000000001")!
        let genericBookmarkID = UUID(uuidString: "b1000000-0000-0000-0000-000000000002")!

        store.setPlaybackSettingsJSON(#"{"bookId":"KJV","speed":120}"#, for: bibleBookmarkID, kind: .bible)
        store.setPlaybackSettingsJSON(#"{"bookId":"MHC","queue":true}"#, for: genericBookmarkID, kind: .generic)

        XCTAssertEqual(
            store.playbackSettingsJSON(for: bibleBookmarkID, kind: .bible),
            #"{"bookId":"KJV","speed":120}"#
        )
        XCTAssertEqual(
            store.playbackSettingsJSON(for: genericBookmarkID, kind: .generic),
            #"{"bookId":"MHC","queue":true}"#
        )
        XCTAssertEqual(
            store.allEntries(),
            [
                .init(
                    bookmarkKind: .bible,
                    bookmarkID: bibleBookmarkID,
                    playbackSettingsJSON: #"{"bookId":"KJV","speed":120}"#
                ),
                .init(
                    bookmarkKind: .generic,
                    bookmarkID: genericBookmarkID,
                    playbackSettingsJSON: #"{"bookId":"MHC","queue":true}"#
                ),
            ]
        )

        store.clearAll()
        XCTAssertTrue(store.allEntries().isEmpty)
    }

    func testRemoteSyncBookmarkLabelAliasStorePersistsAndClearsAliases() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let store = RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore)
        let remoteSpeakID = UUID(uuidString: "c1000000-0000-0000-0000-000000000001")!
        let remoteUnlabeledID = UUID(uuidString: "c1000000-0000-0000-0000-000000000002")!

        store.setAlias(remoteLabelID: remoteSpeakID, localLabelID: Label.speakLabelId)
        store.setAlias(remoteLabelID: remoteUnlabeledID, localLabelID: Label.unlabeledId)

        XCTAssertEqual(store.localLabelID(forRemoteLabelID: remoteSpeakID), Label.speakLabelId)
        XCTAssertEqual(store.localLabelID(forRemoteLabelID: remoteUnlabeledID), Label.unlabeledId)
        XCTAssertEqual(
            store.allAliases(),
            [
                .init(remoteLabelID: remoteSpeakID, localLabelID: Label.speakLabelId),
                .init(remoteLabelID: remoteUnlabeledID, localLabelID: Label.unlabeledId),
            ]
        )

        store.clearAll()
        XCTAssertTrue(store.allAliases().isEmpty)
    }

    /**
     Verifies remote-sync reset clears the local-only Android bookmark book side store.

     Issue #356 stores Android's raw `BibleBookmark.book` values outside the SwiftData display
     field so outbound snapshots can preserve Android module initials and NULLs. Resetting remote
     sync must clear that fidelity state with the other bookmark side stores, otherwise a later
     account or bootstrap could inherit stale source-module mappings.
     */
    func testRemoteSyncResetServiceClearsBookmarkAndroidBookStore() async throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let store = RemoteSyncBookmarkAndroidBookStore(settingsStore: settingsStore)
        let bookmarkID = UUID(uuidString: "c2000000-0000-0000-0000-000000000001")!
        store.setRawBook("KJV", for: bookmarkID)

        await RemoteSyncResetService(settingsStore: settingsStore).resetAllCategories()

        XCTAssertEqual(store.rawBook(for: bookmarkID), Optional<String?>.none)
    }

    func testRemoteSyncBookmarkRestoreReadsAndroidSnapshot() throws {
        let service = RemoteSyncBookmarkRestoreService()
        let speakLabelID = UUID(uuidString: "d1000000-0000-0000-0000-000000000001")!
        let userLabelID = UUID(uuidString: "d1000000-0000-0000-0000-000000000010")!
        let bibleBookmarkID = UUID(uuidString: "d1000000-0000-0000-0000-000000000020")!
        let genericBookmarkID = UUID(uuidString: "d1000000-0000-0000-0000-000000000021")!
        let studyPadEntryID = UUID(uuidString: "d1000000-0000-0000-0000-000000000030")!

        let databaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: speakLabelID, name: Label.speakLabelName, colour: Int(Int32(bitPattern: 0xFFFF0000))),
                .init(id: userLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF00FF00)), favourite: true, type: "HIGHLIGHT")
            ],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 10,
                    kjvOrdinalEnd: 12,
                    ordinalStart: 10,
                    ordinalEnd: 12,
                    playbackSettingsJSON: #"{"bookId":"KJV","speed":110}"#,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    book: "Genesis",
                    startOffset: 3,
                    endOffset: 8,
                    primaryLabelID: speakLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_000_100),
                    wholeVerse: false,
                    type: "EXAMPLE",
                    customIcon: "star",
                    editActionMode: "APPEND",
                    editActionContent: "Amen"
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Bible note", contentType: "MARKDOWN")
            ],
            bibleLinks: [
                .init(bookmarkID: bibleBookmarkID, labelID: userLabelID, orderNumber: 2, indentLevel: 1, expandContent: false)
            ],
            genericBookmarks: [
                .init(
                    id: genericBookmarkID,
                    key: "Entry.1",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_200),
                    bookInitials: "MHC",
                    ordinalStart: 5,
                    ordinalEnd: 5,
                    primaryLabelID: userLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_000_300),
                    wholeVerse: true,
                    playbackSettingsJSON: #"{"bookId":"MHC","queue":true}"#
                )
            ],
            genericNotes: [
                .init(bookmarkID: genericBookmarkID, notes: "Generic note", contentType: "HTML")
            ],
            genericLinks: [
                .init(bookmarkID: genericBookmarkID, labelID: userLabelID, orderNumber: 1, indentLevel: 0, expandContent: true)
            ],
            studyPadEntries: [
                .init(id: studyPadEntryID, labelID: userLabelID, orderNumber: 4, indentLevel: 2, contentType: "MARKDOWN")
            ],
            studyPadTexts: [
                .init(entryID: studyPadEntryID, text: "Study text")
            ]
        )

        let snapshot = try service.readSnapshot(from: databaseURL)

        XCTAssertEqual(snapshot.labels.count, 2)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: snapshot.labels.map { ($0.name, $0.id) }),
            [
                Label.speakLabelName: speakLabelID,
                "Prayer": userLabelID,
            ]
        )
        XCTAssertEqual(snapshot.bibleBookmarks.count, 1)
        XCTAssertEqual(snapshot.bibleBookmarks[0].id, bibleBookmarkID)
        XCTAssertEqual(snapshot.bibleBookmarks[0].notes, "Bible note")
        XCTAssertEqual(snapshot.bibleBookmarks[0].notesContentType, "MARKDOWN")
        XCTAssertEqual(snapshot.bibleBookmarks[0].primaryLabelID, speakLabelID)
        XCTAssertEqual(snapshot.bibleBookmarks[0].labelLinks, [
            .init(labelID: userLabelID, orderNumber: 2, indentLevel: 1, expandContent: false)
        ])
        XCTAssertEqual(snapshot.genericBookmarks.count, 1)
        XCTAssertEqual(snapshot.genericBookmarks[0].notes, "Generic note")
        XCTAssertEqual(snapshot.genericBookmarks[0].notesContentType, "HTML")
        XCTAssertEqual(snapshot.studyPadEntries, [
            .init(id: studyPadEntryID, labelID: userLabelID, orderNumber: 4, indentLevel: 2, contentType: "MARKDOWN", text: "Study text")
        ])
    }

    /**
     Verifies restore normalizes Android's module-initials `book` column into display book names.

     Android stores SWORD module initials (or NULL) in `BibleBookmark.book` and renders references
     from `v11n` + ordinals, while iOS keys bookmark display, chapter-highlight queries, and
     navigation on the same field as a display book name (issue #356). Restore must rewrite the
     two Android-produced shapes — NULL and installed-module initials — through the resolver while
     preserving every other value verbatim so locally created and localized names survive merges.
     A failure here means restored Android bookmarks render as `Unknown`/initials plus garbage
     chapter math again.
     */
    func testRemoteSyncBookmarkRestoreNormalizesAndroidBookColumnSemantics() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let resolver = FakeAndroidBookmarkBookNameResolver(
            installedBibleInitials: ["KJV", "NASB"],
            namesByOrdinal: [4: "Genesis", 1533: "Exodus"]
        )
        let service = RemoteSyncBookmarkRestoreService(bookNameResolver: resolver)

        let initialsID = UUID(uuidString: "f3000000-0000-0000-0000-000000000001")!
        let nullBookID = UUID(uuidString: "f3000000-0000-0000-0000-000000000002")!
        let localizedID = UUID(uuidString: "f3000000-0000-0000-0000-000000000003")!
        let uninstalledID = UUID(uuidString: "f3000000-0000-0000-0000-000000000004")!
        let unresolvableID = UUID(uuidString: "f3000000-0000-0000-0000-000000000005")!

        let snapshot = RemoteSyncAndroidBookmarkSnapshot(
            labels: [],
            bibleBookmarks: [
                makeNormalizationBookmark(id: initialsID, ordinalStart: 4, book: "KJV", v11n: "KJV", kjvOrdinal: 40),
                makeNormalizationBookmark(id: nullBookID, ordinalStart: 1533, book: nil, v11n: "KJVA", kjvOrdinal: 1533),
                makeNormalizationBookmark(id: localizedID, ordinalStart: 4, book: "1. Mose"),
                makeNormalizationBookmark(id: uninstalledID, ordinalStart: 4, book: "ESV2011"),
                makeNormalizationBookmark(id: unresolvableID, ordinalStart: 999_999, book: "NASB", v11n: "Luther", kjvOrdinal: 40),
            ],
            genericBookmarks: [],
            studyPadEntries: []
        )

        _ = try service.replaceLocalBookmarks(
            from: snapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let restored = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        let booksByID = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0.book) })
        let sourceInitialsByID = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0.bookInitials) })
        XCTAssertEqual(
            booksByID[initialsID],
            "Genesis",
            "Installed-module initials must be rewritten to the derived display book name."
        )
        XCTAssertEqual(
            sourceInitialsByID[initialsID],
            "KJV",
            "Installed-module initials must also be retained on the bookmark as source metadata."
        )
        XCTAssertEqual(
            booksByID[nullBookID],
            "Exodus",
            "NULL Android book values must be derived from the bookmark's own ordinals."
        )
        XCTAssertEqual(sourceInitialsByID[nullBookID], "")
        XCTAssertEqual(
            booksByID[localizedID],
            "1. Mose",
            "Values that are not installed-module initials must survive unchanged."
        )
        XCTAssertEqual(sourceInitialsByID[localizedID], "")
        XCTAssertEqual(
            booksByID[uninstalledID],
            "ESV2011",
            "Initials of modules that are not installed cannot be classified and must be preserved."
        )
        XCTAssertEqual(sourceInitialsByID[uninstalledID], "ESV2011")
        XCTAssertEqual(
            booksByID[unresolvableID],
            "NASB",
            "When derivation fails the raw Android value must be preserved rather than dropped."
        )
        XCTAssertEqual(sourceInitialsByID[unresolvableID], "NASB")
        XCTAssertEqual(
            resolver.recordedRequests,
            [
                .init(v11nName: "KJV", ordinal: 4, kjvOrdinal: 40),
                .init(v11nName: "KJVA", ordinal: 1533, kjvOrdinal: 1533),
                .init(v11nName: "Luther", ordinal: 999_999, kjvOrdinal: 40),
            ],
            "Derivation must pass each bookmark's own versification, source ordinal, and KJVA ordinal."
        )

        let bookStore = RemoteSyncBookmarkAndroidBookStore(settingsStore: settingsStore)
        XCTAssertEqual(
            bookStore.rawBook(for: initialsID),
            .some("KJV"),
            "Rewritten initials must be preserved for Android round-trip export."
        )
        XCTAssertEqual(
            bookStore.rawBook(for: nullBookID),
            .some(nil),
            "Rewritten NULL book values must be preserved as NULL for Android round-trip export."
        )
        XCTAssertEqual(
            bookStore.rawBook(for: localizedID),
            Optional<String?>.none,
            "Untouched values must not create fidelity entries."
        )
        XCTAssertEqual(
            bookStore.rawBook(for: unresolvableID),
            Optional<String?>.none,
            "Failed derivations keep the raw value on the model and need no fidelity entry."
        )
    }

    /**
     Verifies restore preserves raw Android `book` values verbatim when normalization is disabled.

     Passing a nil resolver keeps the pre-#356 pass-through contract so callers that need
     Android-fidelity round-trips can opt out. A failure here means normalization can no longer
     be disabled and fidelity-sensitive flows would silently rewrite Android data.
     */
    func testRemoteSyncBookmarkRestoreWithoutResolverPreservesRawBookValues() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let service = RemoteSyncBookmarkRestoreService(bookNameResolver: nil)
        let bookmarkID = UUID(uuidString: "f4000000-0000-0000-0000-000000000001")!

        let snapshot = RemoteSyncAndroidBookmarkSnapshot(
            labels: [],
            bibleBookmarks: [
                makeNormalizationBookmark(id: bookmarkID, ordinalStart: 4, book: "KJV")
            ],
            genericBookmarks: [],
            studyPadEntries: []
        )

        _ = try service.replaceLocalBookmarks(
            from: snapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let restored = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(
            restored[0].book,
            "KJV",
            "A nil resolver must preserve the raw Android book value verbatim."
        )
        XCTAssertEqual(
            restored[0].bookInitials,
            "KJV",
            "A nil resolver still treats Android's non-empty book column as source module initials."
        )
    }

    /**
     Verifies the full SQLite restore path normalizes Android module-initials book values.

     The fixture writes an Android-shaped bookmarks database whose `book` column carries module
     initials, exactly as real Android backups do, then restores it through `readSnapshot` plus
     `replaceLocalBookmarks`. The expected result is a display book name on the SwiftData row and
     a preserved raw value for round-trip export. A failure means the SQLite read path and the
     normalization boundary have drifted apart while the snapshot-level tests stay green.
     */
    func testRemoteSyncBookmarkRestoreNormalizesBookColumnFromAndroidDatabase() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let resolver = FakeAndroidBookmarkBookNameResolver(
            installedBibleInitials: ["KJV"],
            namesByOrdinal: [10: "Genesis", 20: "Exodus"]
        )
        let service = RemoteSyncBookmarkRestoreService(bookNameResolver: resolver)
        let bookmarkID = UUID(uuidString: "f5000000-0000-0000-0000-000000000001")!
        let nullBookBookmarkID = UUID(uuidString: "f5000000-0000-0000-0000-000000000002")!

        let databaseURL = try makeAndroidBookmarksDatabase(
            labels: [],
            bibleBookmarks: [
                .init(
                    id: bookmarkID,
                    kjvOrdinalStart: 10,
                    kjvOrdinalEnd: 10,
                    ordinalStart: 10,
                    ordinalEnd: 10,
                    playbackSettingsJSON: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_300_000),
                    book: "KJV",
                    startOffset: nil,
                    endOffset: nil,
                    primaryLabelID: nil,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_300_100),
                    wholeVerse: true,
                    type: nil,
                    customIcon: nil,
                    editActionMode: nil,
                    editActionContent: nil
                ),
                .init(
                    id: nullBookBookmarkID,
                    kjvOrdinalStart: 20,
                    kjvOrdinalEnd: 20,
                    ordinalStart: 20,
                    ordinalEnd: 20,
                    playbackSettingsJSON: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_300_200),
                    book: nil,
                    startOffset: nil,
                    endOffset: nil,
                    primaryLabelID: nil,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_300_300),
                    wholeVerse: true,
                    type: nil,
                    customIcon: nil,
                    editActionMode: nil,
                    editActionContent: nil
                ),
            ],
            bibleNotes: [],
            bibleLinks: [],
            genericBookmarks: [],
            genericNotes: [],
            genericLinks: [],
            studyPadEntries: [],
            studyPadTexts: []
        )

        let snapshot = try service.readSnapshot(from: databaseURL)
        _ = try service.replaceLocalBookmarks(
            from: snapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let restored = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        let booksByID = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0.book) })
        let sourceInitialsByID = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0.bookInitials) })
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(
            booksByID[bookmarkID],
            "Genesis",
            "The SQLite restore path must rewrite Android module initials into display book names."
        )
        XCTAssertEqual(
            booksByID[nullBookBookmarkID],
            "Exodus",
            "The SQLite restore path must derive display names for NULL Android book columns."
        )
        XCTAssertEqual(sourceInitialsByID[bookmarkID], "KJV")
        XCTAssertEqual(sourceInitialsByID[nullBookBookmarkID], "")
        let bookStore = RemoteSyncBookmarkAndroidBookStore(settingsStore: settingsStore)
        XCTAssertEqual(
            bookStore.rawBook(for: bookmarkID),
            .some("KJV"),
            "The SQLite restore path must preserve the raw Android value for round-trip export."
        )
        XCTAssertEqual(
            bookStore.rawBook(for: nullBookBookmarkID),
            .some(nil),
            "The SQLite restore path must preserve NULL Android book values for round-trip export."
        )

        let outbound = RemoteSyncBookmarkSnapshotService().snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let outboundBooks = Dictionary(
            uniqueKeysWithValues: outbound.bibleBookmarkRowsByKey.values.map { ($0.id, $0.book) }
        )
        XCTAssertEqual(
            outboundBooks[bookmarkID],
            "KJV",
            "Outbound Android snapshots must project the preserved module initials, not display names."
        )
        XCTAssertEqual(
            outboundBooks[nullBookBookmarkID],
            String??.some(nil),
            "Outbound Android snapshots must project preserved NULL book values as NULL."
        )
    }

    /**
     Verifies previously healed display names survive re-materialization when derivation fails.

     Sync patch apply and merge imports rebuild the local graph from Android-shaped snapshots that
     carry preserved raw values. When the module that enabled the original derivation is no longer
     installed, the expected result keeps the earlier healed display name for the same bookmark ID
     instead of regressing to `Unknown`/initials. A failure means an unrelated incoming sync patch
     would visibly break bookmarks that were already displaying correctly.
     */
    func testRemoteSyncBookmarkRestoreRetainsHealedNamesWhenDerivationFails() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let bookmarkID = UUID(uuidString: "f6000000-0000-0000-0000-000000000001")!

        let healingResolver = FakeAndroidBookmarkBookNameResolver(
            installedBibleInitials: ["KJV"],
            namesByOrdinal: [4: "Genesis"]
        )
        let snapshot = RemoteSyncAndroidBookmarkSnapshot(
            labels: [],
            bibleBookmarks: [
                makeNormalizationBookmark(id: bookmarkID, ordinalStart: 4, book: "KJV")
            ],
            genericBookmarks: [],
            studyPadEntries: []
        )
        _ = try RemoteSyncBookmarkRestoreService(bookNameResolver: healingResolver).replaceLocalBookmarks(
            from: snapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let failingResolver = FakeAndroidBookmarkBookNameResolver(
            installedBibleInitials: ["KJV"],
            namesByOrdinal: [:]
        )
        _ = try RemoteSyncBookmarkRestoreService(bookNameResolver: failingResolver).replaceLocalBookmarks(
            from: snapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let restored = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(
            restored[0].book,
            "Genesis",
            "Re-materialization with failing derivation must keep the previously healed display name."
        )
        XCTAssertEqual(
            RemoteSyncBookmarkAndroidBookStore(settingsStore: settingsStore).rawBook(for: bookmarkID),
            .some("KJV"),
            "The preserved raw Android value must survive re-materialization."
        )
    }

    /**
     Verifies outbound Android snapshots use Bible bookmark source initials, not display book names.

     Native iOS bookmark creation stores `book` as the display Bible book and `bookInitials` as the
     source module. Android's `BibleBookmark.book` column expects module initials or NULL, so
     snapshot export must read `bookInitials` and quarantine legacy rows without source metadata.
     */
    func testRemoteSyncBookmarkSnapshotExportsSourceInitialsInsteadOfDisplayBook() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let sourceBackedID = UUID(uuidString: "f7000000-0000-0000-0000-000000000001")!
        let legacyDisplayOnlyID = UUID(uuidString: "f7000000-0000-0000-0000-000000000002")!
        let sourceBacked = BibleBookmark(
            id: sourceBackedID,
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            ordinalStart: 10,
            ordinalEnd: 10,
            v11n: "KJV",
            bookInitials: "KJV",
            ordinalTrustMetadata: PersistedOrdinalTrustPolicy.androidImportMetadata(
                sourceVersification: "KJV",
                sourceOrdinalStart: 10,
                sourceOrdinalEnd: 10,
                kjvaOrdinalStart: 4,
                kjvaOrdinalEnd: 4
            )
        )
        sourceBacked.book = "Genesis"
        let legacyDisplayOnly = BibleBookmark(
            id: legacyDisplayOnlyID,
            kjvOrdinalStart: 5,
            kjvOrdinalEnd: 5,
            ordinalStart: 11,
            ordinalEnd: 11,
            v11n: "KJV"
        )
        legacyDisplayOnly.book = "Genesis"
        modelContext.insert(sourceBacked)
        modelContext.insert(legacyDisplayOnly)
        try modelContext.save()

        let snapshot = RemoteSyncBookmarkSnapshotService().snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let outboundBooks = Dictionary(
            uniqueKeysWithValues: snapshot.bibleBookmarkRowsByKey.values.map { ($0.id, $0.book) }
        )

        XCTAssertEqual(outboundBooks[sourceBackedID], "KJV")
        XCTAssertFalse(outboundBooks.keys.contains(legacyDisplayOnlyID))
        let legacyKey = RemoteSyncLogEntryStore(settingsStore: settingsStore).key(
            for: .bookmarks,
            tableName: "BibleBookmark",
            entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(legacyDisplayOnlyID)),
            entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
        )
        XCTAssertTrue(snapshot.suppressedKeys.contains(legacyKey))
    }

    /**
     Verifies authoritative restore aborts when quarantined local bookmarks cannot be projected.

     The fixture persists one unresolved local bookmark and its accepted fingerprint, then injects a
     strict snapshot failure while restore is preserving omitted quarantine rows. The checkpoint also
     stages a setting write, proving preservation runs inside the atomic batch. The old graph and
     fingerprint must remain durable, the probe setting must roll back, and the incoming empty snapshot
     must never authorize deletion. A failure means a transient read error can destroy local-only
     bookmarks or publish partial fidelity state before a later retry.
     */
    func testBookmarkRestoreSnapshotFailurePreservesQuarantinedGraphAndFingerprint() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let bookmarkID = UUID(uuidString: "f7100000-0000-0000-0000-000000000001")!
        let bookmark = BibleBookmark(
            id: bookmarkID,
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            ordinalStart: 4,
            ordinalEnd: 4,
            v11n: "Unknown",
            bookInitials: "MISSING"
        )
        bookmark.book = "Genesis"
        modelContext.insert(bookmark)
        try modelContext.save()

        let entityID = RemoteSyncSQLiteValue.blob(RemoteSyncBookmarkSnapshotService.uuidBlob(bookmarkID))
        let entityID2 = AndroidBookmarkDatabaseContract.emptySecondaryEntityID
        RemoteSyncRowFingerprintStore(settingsStore: settingsStore).setFingerprint(
            "quarantined-fingerprint",
            for: .bookmarks,
            tableName: "BibleBookmark",
            entityID1: entityID,
            entityID2: entityID2
        )

        let snapshotService = RemoteSyncBookmarkSnapshotService(
            strictSnapshotCheckpoint: {
                settingsStore.setString(
                    "test.bookmark.strictSnapshotStaging",
                    value: "must-roll-back"
                )
                throw NSError(domain: "BookmarkStrictSnapshot", code: 41)
            }
        )
        let restoreService = RemoteSyncBookmarkRestoreService(
            bookNameResolver: nil,
            snapshotService: snapshotService
        )

        XCTAssertThrowsError(
            try restoreService.replaceLocalBookmarks(
                from: RemoteSyncAndroidBookmarkSnapshot(
                    labels: [],
                    bibleBookmarks: [],
                    genericBookmarks: [],
                    studyPadEntries: []
                ),
                modelContext: modelContext,
                settingsStore: settingsStore,
                preserveUnverifiedLocalBookmarks: true
            )
        ) { error in
            XCTAssertEqual((error as NSError).domain, "BookmarkStrictSnapshot")
            XCTAssertEqual((error as NSError).code, 41)
        }

        let verificationContext = ModelContext(container)
        let preserved = try verificationContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(preserved.map(\.id), [bookmarkID])
        XCTAssertEqual(preserved.first?.ordinalTrustState, .legacyPendingModule)
        let verificationSettings = SettingsStore(modelContext: verificationContext)
        XCTAssertNil(verificationSettings.getString("test.bookmark.strictSnapshotStaging"))
        XCTAssertEqual(
            RemoteSyncRowFingerprintStore(
                settingsStore: verificationSettings
            ).fingerprint(
                for: .bookmarks,
                tableName: "BibleBookmark",
                entityID1: entityID,
                entityID2: entityID2
            ),
            "quarantined-fingerprint"
        )
    }

    /**
     Builds one staged Android Bible bookmark row for book-name normalization tests.

     - Parameters:
       - id: Stable bookmark identifier.
       - ordinalStart: Source-versification start ordinal driving derivation.
       - book: Raw Android `book` column value under test.
     - Returns: A label-free staged bookmark row with KJV versification.
     - Side effects: none.
     - Failure modes: none.
     */
    private func makeNormalizationBookmark(
        id: UUID,
        ordinalStart: Int,
        book: String?,
        v11n: String = "KJV",
        kjvOrdinal: Int? = nil
    ) -> RemoteSyncAndroidBibleBookmark {
        RemoteSyncAndroidBibleBookmark(
            id: id,
            kjvOrdinalStart: kjvOrdinal ?? ordinalStart,
            kjvOrdinalEnd: kjvOrdinal ?? ordinalStart,
            ordinalStart: ordinalStart,
            ordinalEnd: ordinalStart,
            v11n: v11n,
            playbackSettingsJSON: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_200_000),
            book: book,
            startOffset: nil,
            endOffset: nil,
            primaryLabelID: nil,
            notes: nil,
            lastUpdatedOn: Date(timeIntervalSince1970: 1_700_200_100),
            wholeVerse: true,
            type: nil,
            customIcon: nil,
            editAction: nil,
            labelLinks: []
        )
    }

    /**
     Verifies that bookmark restore remains backward-compatible with Android bookmark databases
     created before note rows and StudyPad entries gained nullable content-type metadata.

     The fixture emits the legacy schema without `contentType` columns. The expected result is that
     restore succeeds, preserves note text, and exposes nil content types so callers can apply the
     global notes-content-type fallback. A failure here means older Android backups or patch
     databases would be rejected or misread after adding Markdown-note parity.
     */
    func testRemoteSyncBookmarkRestoreReadsLegacyAndroidSnapshotWithoutContentTypeColumns() throws {
        let service = RemoteSyncBookmarkRestoreService()
        let labelID = UUID(uuidString: "d2000000-0000-0000-0000-000000000010")!
        let bookmarkID = UUID(uuidString: "d2000000-0000-0000-0000-000000000020")!
        let studyPadEntryID = UUID(uuidString: "d2000000-0000-0000-0000-000000000030")!

        let databaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: labelID, name: "Legacy", colour: Int(Int32(bitPattern: 0xFF00FF00)))
            ],
            bibleBookmarks: [
                .init(
                    id: bookmarkID,
                    kjvOrdinalStart: 10,
                    kjvOrdinalEnd: 10,
                    ordinalStart: 10,
                    ordinalEnd: 10,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    primaryLabelID: labelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_000_100)
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bookmarkID, notes: "Legacy note")
            ],
            studyPadEntries: [
                .init(id: studyPadEntryID, labelID: labelID, orderNumber: 4, indentLevel: 2)
            ],
            studyPadTexts: [
                .init(entryID: studyPadEntryID, text: "Legacy StudyPad")
            ],
            includeContentTypeColumns: false
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let snapshot = try service.readSnapshot(from: databaseURL)

        XCTAssertEqual(snapshot.bibleBookmarks.count, 1)
        XCTAssertEqual(snapshot.bibleBookmarks[0].notes, "Legacy note")
        XCTAssertNil(snapshot.bibleBookmarks[0].notesContentType)
        XCTAssertEqual(snapshot.studyPadEntries.count, 1)
        XCTAssertEqual(snapshot.studyPadEntries[0].text, "Legacy StudyPad")
        XCTAssertNil(snapshot.studyPadEntries[0].contentType)
    }

    /**
     Verifies that Android bookmark restore treats invalid note content-type row values as invalid
     database data rather than falling back to the global preference default.

     Android Room reads `TextContentType` columns through `TextContentType.valueOf`, so only `HTML`,
     `MARKDOWN`, and `NULL` are valid row values. The settings fallback helper is intentionally not
     the row-validation contract; otherwise corrupted or future Android values would be silently
     rendered as HTML on iOS.
     */
    func testRemoteSyncBookmarkRestoreRejectsInvalidTextContentTypeRows() throws {
        let service = RemoteSyncBookmarkRestoreService()
        let labelID = UUID(uuidString: "d2100000-0000-0000-0000-000000000010")!
        let bookmarkID = UUID(uuidString: "d2100000-0000-0000-0000-000000000020")!
        let studyPadEntryID = UUID(uuidString: "d2100000-0000-0000-0000-000000000030")!

        let invalidNoteDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [.init(id: labelID, name: "Invalid", colour: Int(Int32(bitPattern: 0xFF00FF00)))],
            bibleBookmarks: [
                .init(
                    id: bookmarkID,
                    kjvOrdinalStart: 10,
                    kjvOrdinalEnd: 10,
                    ordinalStart: 10,
                    ordinalEnd: 10,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    primaryLabelID: labelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_000_100)
                )
            ],
            bibleNotes: [.init(bookmarkID: bookmarkID, notes: "Bad note", contentType: "PLAINTEXT")]
        )
        defer { try? FileManager.default.removeItem(at: invalidNoteDatabaseURL) }

        XCTAssertThrowsError(try service.readSnapshot(from: invalidNoteDatabaseURL)) { error in
            XCTAssertEqual(
                String(describing: error),
                #"invalidColumnValue(table: "BibleBookmarkNotes", column: "contentType")"#
            )
        }

        let invalidStudyPadDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [.init(id: labelID, name: "Invalid", colour: Int(Int32(bitPattern: 0xFF00FF00)))],
            studyPadEntries: [
                .init(id: studyPadEntryID, labelID: labelID, orderNumber: 1, indentLevel: 0, contentType: "PLAINTEXT")
            ],
            studyPadTexts: [.init(entryID: studyPadEntryID, text: "Bad StudyPad")]
        )
        defer { try? FileManager.default.removeItem(at: invalidStudyPadDatabaseURL) }

        XCTAssertThrowsError(try service.readSnapshot(from: invalidStudyPadDatabaseURL)) { error in
            XCTAssertEqual(
                String(describing: error),
                #"invalidColumnValue(table: "StudyPadTextEntry", column: "contentType")"#
            )
        }
    }

    func testRemoteSyncBookmarkRestoreReplacesLocalDataAndPreservesAndroidFidelity() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let service = RemoteSyncBookmarkRestoreService()

        let legacyLabel = Label(name: "Legacy")
        modelContext.insert(legacyLabel)
        let legacyBookmark = BibleBookmark(kjvOrdinalStart: 1, kjvOrdinalEnd: 1)
        legacyBookmark.book = "Genesis"
        modelContext.insert(legacyBookmark)
        try modelContext.save()

        let remoteSpeakID = UUID(uuidString: "e1000000-0000-0000-0000-000000000001")!
        let remoteUnlabeledID = UUID(uuidString: "e1000000-0000-0000-0000-000000000002")!
        let remoteParagraphID = UUID(uuidString: "e1000000-0000-0000-0000-000000000003")!
        let userLabelID = UUID(uuidString: "e1000000-0000-0000-0000-000000000010")!
        let bibleBookmarkID = UUID(uuidString: "e1000000-0000-0000-0000-000000000020")!
        let genericBookmarkID = UUID(uuidString: "e1000000-0000-0000-0000-000000000021")!
        let studyPadEntryID = UUID(uuidString: "e1000000-0000-0000-0000-000000000030")!

        let databaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteSpeakID, name: Label.speakLabelName, colour: Int(Int32(bitPattern: 0xFFFF9999)), customIcon: "microphone"),
                .init(id: remoteUnlabeledID, name: Label.unlabeledName, colour: Int(Int32(bitPattern: 0xFFFFFF99))),
                .init(id: remoteParagraphID, name: Label.paragraphBreakLabelName, colour: Int(Int32(bitPattern: 0xFF99CCFF))),
                .init(id: userLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF00FF00)), favourite: true, type: "HIGHLIGHT", customIcon: "heart")
            ],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 15,
                    kjvOrdinalEnd: 16,
                    ordinalStart: 15,
                    ordinalEnd: 16,
                    playbackSettingsJSON: #"{"bookId":"KJV","speed":125,"speakFootnotes":true}"#,
                    createdAt: Date(timeIntervalSince1970: 1_700_100_000),
                    book: "Exodus",
                    startOffset: 2,
                    endOffset: 9,
                    primaryLabelID: remoteSpeakID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_100_100),
                    wholeVerse: false,
                    type: "EXAMPLE",
                    customIcon: "star",
                    editActionMode: "APPEND",
                    editActionContent: "Amen"
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Bible note", contentType: "MARKDOWN")
            ],
            bibleLinks: [
                .init(bookmarkID: bibleBookmarkID, labelID: userLabelID, orderNumber: 3, indentLevel: 1, expandContent: false),
                .init(bookmarkID: bibleBookmarkID, labelID: remoteParagraphID, orderNumber: 4, indentLevel: 0, expandContent: true)
            ],
            genericBookmarks: [
                .init(
                    id: genericBookmarkID,
                    key: "Entry.1",
                    createdAt: Date(timeIntervalSince1970: 1_700_100_200),
                    bookInitials: "MHC",
                    ordinalStart: 4,
                    ordinalEnd: 4,
                    primaryLabelID: remoteUnlabeledID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_100_300),
                    wholeVerse: true,
                    playbackSettingsJSON: #"{"bookId":"MHC","queue":true}"#,
                    customIcon: "link",
                    editActionMode: "PREPEND",
                    editActionContent: "Intro"
                )
            ],
            genericNotes: [
                .init(bookmarkID: genericBookmarkID, notes: "Generic note", contentType: "HTML")
            ],
            genericLinks: [
                .init(bookmarkID: genericBookmarkID, labelID: userLabelID, orderNumber: 1, indentLevel: 0, expandContent: true)
            ],
            studyPadEntries: [
                .init(id: studyPadEntryID, labelID: userLabelID, orderNumber: 7, indentLevel: 2, contentType: "MARKDOWN")
            ],
            studyPadTexts: [
                .init(entryID: studyPadEntryID, text: "Study text")
            ]
        )

        let snapshot = try service.readSnapshot(from: databaseURL)
        let report = try service.replaceLocalBookmarks(
            from: snapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(
            report,
            RemoteSyncBookmarkRestoreReport(
                restoredLabelCount: 4,
                restoredBibleBookmarkCount: 1,
                restoredGenericBookmarkCount: 1,
                restoredStudyPadEntryCount: 1,
                preservedPlaybackSettingsCount: 2,
                preservedSystemLabelAliasCount: 3
            )
        )

        let labels = try modelContext.fetch(FetchDescriptor<Label>())
        XCTAssertEqual(labels.count, 4)
        XCTAssertNil(labels.first(where: { $0.name == "Legacy" }))
        XCTAssertEqual(labels.first(where: { $0.name == Label.speakLabelName })?.id, Label.speakLabelId)
        XCTAssertEqual(labels.first(where: { $0.name == Label.unlabeledName })?.id, Label.unlabeledId)
        XCTAssertEqual(labels.first(where: { $0.name == Label.paragraphBreakLabelName })?.id, Label.paragraphBreakLabelId)
        XCTAssertEqual(labels.first(where: { $0.name == "Prayer" })?.id, userLabelID)

        let bibleBookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(bibleBookmarks.count, 1)
        XCTAssertEqual(bibleBookmarks[0].id, bibleBookmarkID)
        XCTAssertEqual(bibleBookmarks[0].book, "Exodus")
        XCTAssertEqual(bibleBookmarks[0].primaryLabelId, Label.speakLabelId)
        XCTAssertEqual(bibleBookmarks[0].notes?.notes, "Bible note")
        XCTAssertEqual(bibleBookmarks[0].notes?.contentType, "MARKDOWN")
        XCTAssertEqual(bibleBookmarks[0].playbackSettings?.bookId, "KJV")
        XCTAssertEqual(bibleBookmarks[0].type, "EXAMPLE")
        XCTAssertEqual(bibleBookmarks[0].customIcon, "star")
        XCTAssertEqual(bibleBookmarks[0].editAction, EditAction(mode: .append, content: "Amen"))

        let genericBookmarks = try modelContext.fetch(FetchDescriptor<GenericBookmark>())
        XCTAssertEqual(genericBookmarks.count, 1)
        XCTAssertEqual(genericBookmarks[0].id, genericBookmarkID)
        XCTAssertEqual(genericBookmarks[0].primaryLabelId, Label.unlabeledId)
        XCTAssertEqual(genericBookmarks[0].notes?.notes, "Generic note")
        XCTAssertEqual(genericBookmarks[0].notes?.contentType, "HTML")
        XCTAssertEqual(genericBookmarks[0].playbackSettings?.bookId, "MHC")
        XCTAssertEqual(genericBookmarks[0].customIcon, "link")
        XCTAssertEqual(genericBookmarks[0].editAction, EditAction(mode: .prepend, content: "Intro"))

        let bibleLinks = try modelContext.fetch(FetchDescriptor<BibleBookmarkToLabel>())
        XCTAssertEqual(bibleLinks.count, 2)
        XCTAssertEqual(
            Set(bibleLinks.compactMap { $0.label?.id }),
            Set([userLabelID, Label.paragraphBreakLabelId])
        )
        XCTAssertEqual(
            bibleLinks.first(where: { $0.label?.id == userLabelID })?.orderNumber,
            3
        )

        let genericLinks = try modelContext.fetch(FetchDescriptor<GenericBookmarkToLabel>())
        XCTAssertEqual(genericLinks.count, 1)
        XCTAssertEqual(genericLinks[0].label?.id, userLabelID)

        let studyPadEntries = try modelContext.fetch(FetchDescriptor<StudyPadTextEntry>())
        XCTAssertEqual(studyPadEntries.count, 1)
        XCTAssertEqual(studyPadEntries[0].id, studyPadEntryID)
        XCTAssertEqual(studyPadEntries[0].label?.id, userLabelID)
        XCTAssertEqual(studyPadEntries[0].contentType, "MARKDOWN")
        XCTAssertEqual(studyPadEntries[0].textEntry?.text, "Study text")

        let playbackStore = RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore)
        XCTAssertEqual(
            playbackStore.allEntries(),
            [
                .init(
                    bookmarkKind: .bible,
                    bookmarkID: bibleBookmarkID,
                    playbackSettingsJSON: #"{"bookId":"KJV","speed":125,"speakFootnotes":true}"#
                ),
                .init(
                    bookmarkKind: .generic,
                    bookmarkID: genericBookmarkID,
                    playbackSettingsJSON: #"{"bookId":"MHC","queue":true}"#
                ),
            ]
        )

        let aliasStore = RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore)
        XCTAssertEqual(
            aliasStore.allAliases(),
            [
                .init(remoteLabelID: remoteSpeakID, localLabelID: Label.speakLabelId),
                .init(remoteLabelID: remoteUnlabeledID, localLabelID: Label.unlabeledId),
                .init(remoteLabelID: remoteParagraphID, localLabelID: Label.paragraphBreakLabelId),
            ]
        )
    }

    /**
     Verifies bookmark replacement rolls graph and Android-only fidelity rows back together.

     The fixture starts with one durable local bookmark plus playback, label-alias, and raw-book
     metadata. The incoming Android snapshot stages replacements for every category, then a
     deterministic checkpoint throws after all mutations. A fresh context must still observe only
     the original graph and metadata. Failure means restore can publish a semantically split state.
     */
    func testRemoteSyncBookmarkRestoreRollsBackGraphAndFidelityAfterStaging() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let service = RemoteSyncBookmarkRestoreService()
        let oldLabelID = UUID(uuidString: "e2000000-0000-0000-0000-000000000001")!
        let oldBookmarkID = UUID(uuidString: "e2000000-0000-0000-0000-000000000002")!
        let oldRemoteAliasID = UUID(uuidString: "e2000000-0000-0000-0000-000000000003")!

        let oldLabel = Label(id: oldLabelID, name: "Old label")
        let oldBookmark = BibleBookmark(
            id: oldBookmarkID,
            kjvOrdinalStart: 10,
            kjvOrdinalEnd: 10,
            ordinalStart: 10,
            ordinalEnd: 10,
            v11n: "KJVA",
            bookInitials: "KJV"
        )
        oldBookmark.book = "Genesis"
        oldBookmark.primaryLabelId = oldLabelID
        modelContext.insert(oldLabel)
        modelContext.insert(oldBookmark)
        try modelContext.save()

        RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore).setPlaybackSettingsJSON(
            #"{"bookId":"OLD","speed":90}"#,
            for: oldBookmarkID,
            kind: .bible
        )
        RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore).setAlias(
            remoteLabelID: oldRemoteAliasID,
            localLabelID: oldLabelID
        )
        RemoteSyncBookmarkAndroidBookStore(settingsStore: settingsStore).setRawBook("OLD", for: oldBookmarkID)

        let incomingSpeakID = UUID(uuidString: "e2000000-0000-0000-0000-000000000010")!
        let incomingBookmarkID = UUID(uuidString: "e2000000-0000-0000-0000-000000000011")!
        let databaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(
                    id: incomingSpeakID,
                    name: Label.speakLabelName,
                    colour: Int(Int32(bitPattern: 0xFFFF9999))
                )
            ],
            bibleBookmarks: [
                .init(
                    id: incomingBookmarkID,
                    kjvOrdinalStart: 20,
                    kjvOrdinalEnd: 20,
                    ordinalStart: 20,
                    ordinalEnd: 20,
                    playbackSettingsJSON: #"{"bookId":"KJV","speed":120}"#,
                    createdAt: Date(timeIntervalSince1970: 1_735_800_000),
                    book: "KJV",
                    primaryLabelID: incomingSpeakID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_800_100)
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let snapshot = try service.readSnapshot(from: databaseURL)
        var checkpointCount = 0

        XCTAssertThrowsError(
            try service.replaceLocalBookmarks(
                from: snapshot,
                modelContext: modelContext,
                settingsStore: settingsStore,
                mutationCheckpoint: {
                    checkpointCount += 1
                    if checkpointCount == 3 {
                        throw NSError(domain: "BookmarkRestoreAtomicity", code: 73)
                    }
                }
            )
        ) { error in
            XCTAssertEqual((error as NSError).domain, "BookmarkRestoreAtomicity")
            XCTAssertEqual((error as NSError).code, 73)
        }
        XCTAssertEqual(checkpointCount, 3)

        let verificationContext = ModelContext(container)
        let labels = try verificationContext.fetch(FetchDescriptor<Label>())
        let bookmarks = try verificationContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(labels.map(\.id), [oldLabelID])
        XCTAssertEqual(bookmarks.map(\.id), [oldBookmarkID])
        XCTAssertEqual(bookmarks.first?.book, "Genesis")

        let verificationSettings = SettingsStore(modelContext: verificationContext)
        XCTAssertEqual(
            RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: verificationSettings)
                .playbackSettingsJSON(for: oldBookmarkID, kind: .bible),
            #"{"bookId":"OLD","speed":90}"#
        )
        XCTAssertEqual(
            RemoteSyncBookmarkLabelAliasStore(settingsStore: verificationSettings)
                .localLabelID(forRemoteLabelID: oldRemoteAliasID),
            oldLabelID
        )
        XCTAssertEqual(
            RemoteSyncBookmarkAndroidBookStore(settingsStore: verificationSettings).rawBook(for: oldBookmarkID),
            .some("OLD")
        )
        XCTAssertNil(
            RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: verificationSettings)
                .playbackSettingsJSON(for: incomingBookmarkID, kind: .bible)
        )
    }

    func testRemoteSyncBookmarkRestoreRejectsOrphanReferencesWithoutMutation() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let service = RemoteSyncBookmarkRestoreService()
        let missingLabelID = UUID(uuidString: "f1000000-0000-0000-0000-000000000001")!
        let bibleBookmarkID = UUID(uuidString: "f1000000-0000-0000-0000-000000000002")!
        let studyPadEntryID = UUID(uuidString: "f1000000-0000-0000-0000-000000000003")!

        let legacyLabel = Label(name: "Legacy")
        modelContext.insert(legacyLabel)
        try modelContext.save()

        let databaseURL = try makeAndroidBookmarksDatabase(
            labels: [],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 1,
                    kjvOrdinalEnd: 1,
                    ordinalStart: 1,
                    ordinalEnd: 1,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_200_100)
                )
            ],
            bibleLinks: [
                .init(bookmarkID: bibleBookmarkID, labelID: missingLabelID, orderNumber: 1, indentLevel: 0, expandContent: true)
            ],
            studyPadEntries: [
                .init(id: studyPadEntryID, labelID: missingLabelID, orderNumber: 1, indentLevel: 0)
            ],
            studyPadTexts: []
        )

        XCTAssertThrowsError(try service.readSnapshot(from: databaseURL)) { error in
            XCTAssertEqual(
                error as? RemoteSyncBookmarkRestoreError,
                .orphanReferences([
                    "BibleBookmarkToLabel.labelId=\(missingLabelID.uuidString) missing label",
                    "StudyPadTextEntry.labelId=\(missingLabelID.uuidString) missing label for entry \(studyPadEntryID.uuidString)",
                ])
            )
        }

        let labels = try modelContext.fetch(FetchDescriptor<Label>())
        XCTAssertEqual(labels.map(\.name), ["Legacy"])
    }

    func testRemoteSyncInitialBackupRestoreDispatchesBookmarkBackups() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let service = RemoteSyncInitialBackupRestoreService()
        let remoteSpeakID = UUID(uuidString: "ab000000-0000-0000-0000-000000000001")!
        let bibleBookmarkID = UUID(uuidString: "ab000000-0000-0000-0000-000000000010")!

        let databaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteSpeakID, name: Label.speakLabelName, colour: Int(Int32(bitPattern: 0xFFFF9999)))
            ],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 20,
                    kjvOrdinalEnd: 20,
                    ordinalStart: 20,
                    ordinalEnd: 20,
                    playbackSettingsJSON: #"{"bookId":"KJV"}"#,
                    createdAt: Date(timeIntervalSince1970: 1_735_689_600),
                    primaryLabelID: remoteSpeakID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_689_700)
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let stagedBackup = RemoteSyncStagedInitialBackup(
            remoteFile: RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 2_048,
                timestamp: 1_735_689_600_000,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: "application/gzip"
            ),
            databaseFileURL: databaseURL,
            schemaVersion: 1
        )

        let report = try service.restoreInitialBackup(
            stagedBackup,
            category: .bookmarks,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(
            report,
            .bookmarks(
                RemoteSyncBookmarkRestoreReport(
                    restoredLabelCount: 3,
                    restoredBibleBookmarkCount: 1,
                    restoredGenericBookmarkCount: 0,
                    restoredStudyPadEntryCount: 0,
                    preservedPlaybackSettingsCount: 1,
                    preservedSystemLabelAliasCount: 1
                )
            )
        )

        let labels = try modelContext.fetch(FetchDescriptor<Label>())
        XCTAssertEqual(labels.count, 3)
        XCTAssertEqual(labels.first(where: { $0.name == Label.speakLabelName })?.id, Label.speakLabelId)

        let bibleBookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(bibleBookmarks.map(\.id), [bibleBookmarkID])

        let aliasStore = RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore)
        XCTAssertEqual(aliasStore.localLabelID(forRemoteLabelID: remoteSpeakID), Label.speakLabelId)
    }

    /**
     Verifies a current Room-v12 patch converges a historical restored Speak-label alias onto
     Android's fixed identifier while replaying newer bookmark rows and preserving local links.
     */
    func testRemoteSyncBookmarkPatchApplyReplaysNewerRowsAndPreservesSystemLabelAliases() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreService = RemoteSyncBookmarkRestoreService()
        let patchService = RemoteSyncBookmarkPatchApplyService()
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let playbackStore = RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore)
        let aliasStore = RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore)

        let legacyRemoteSpeakID = UUID(uuidString: "bb100000-0000-0000-0000-000000000001")!
        let currentAndroidSpeakID = AndroidBookmarkDatabaseContract.speakLabelID
        let remoteUserLabelID = UUID(uuidString: "bb100000-0000-0000-0000-000000000010")!
        let bibleBookmarkID = UUID(uuidString: "bb100000-0000-0000-0000-000000000020")!
        let genericBookmarkID = UUID(uuidString: "bb100000-0000-0000-0000-000000000021")!
        let studyPadEntryID = UUID(uuidString: "bb100000-0000-0000-0000-000000000030")!

        let initialDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: legacyRemoteSpeakID, name: Label.speakLabelName, colour: Int(Int32(bitPattern: 0xFFFF9999))),
                .init(id: remoteUserLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF00FF00)))
            ],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 40,
                    kjvOrdinalEnd: 41,
                    ordinalStart: 40,
                    ordinalEnd: 41,
                    playbackSettingsJSON: #"{"bookId":"KJV","speed":120}"#,
                    createdAt: Date(timeIntervalSince1970: 1_735_700_000),
                    book: "Leviticus",
                    primaryLabelID: remoteUserLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_700_100)
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Old bible note", contentType: "HTML")
            ],
            bibleLinks: [
                .init(bookmarkID: bibleBookmarkID, labelID: remoteUserLabelID, orderNumber: 1, indentLevel: 0, expandContent: true)
            ],
            genericBookmarks: [
                .init(
                    id: genericBookmarkID,
                    key: "Entry.1",
                    createdAt: Date(timeIntervalSince1970: 1_735_700_200),
                    bookInitials: "MHC",
                    ordinalStart: 2,
                    ordinalEnd: 2,
                    primaryLabelID: remoteUserLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_700_300),
                    wholeVerse: true,
                    playbackSettingsJSON: #"{"bookId":"MHC","queue":true}"#,
                    customIcon: "book"
                )
            ],
            genericNotes: [
                .init(bookmarkID: genericBookmarkID, notes: "Old generic note", contentType: "HTML")
            ],
            genericLinks: [
                .init(bookmarkID: genericBookmarkID, labelID: remoteUserLabelID, orderNumber: 2, indentLevel: 0, expandContent: true)
            ],
            studyPadEntries: [
                .init(id: studyPadEntryID, labelID: remoteUserLabelID, orderNumber: 5, indentLevel: 1, contentType: "HTML")
            ],
            studyPadTexts: [
                .init(entryID: studyPadEntryID, text: "Old study text")
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalBookmarks(
            from: initialSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        logEntryStore.replaceEntries([
            RemoteSyncLogEntry(
                tableName: "Label",
                entityID1: .blob(bookmarkUUIDBlob(remoteUserLabelID)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "seed-device"
            ),
            RemoteSyncLogEntry(
                tableName: "BibleBookmark",
                entityID1: .blob(bookmarkUUIDBlob(bibleBookmarkID)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "seed-device"
            ),
            RemoteSyncLogEntry(
                tableName: "BibleBookmarkNotes",
                entityID1: .blob(bookmarkUUIDBlob(bibleBookmarkID)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "seed-device"
            ),
            RemoteSyncLogEntry(
                tableName: "GenericBookmark",
                entityID1: .blob(bookmarkUUIDBlob(genericBookmarkID)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "seed-device"
            ),
            RemoteSyncLogEntry(
                tableName: "StudyPadTextEntryText",
                entityID1: .blob(bookmarkUUIDBlob(studyPadEntryID)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "seed-device"
            ),
        ], for: .bookmarks)

        let patchDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteUserLabelID, name: "Prayer updated", colour: Int(Int32(bitPattern: 0xFF33AA33)), favourite: true)
            ],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 40,
                    kjvOrdinalEnd: 42,
                    ordinalStart: 40,
                    ordinalEnd: 42,
                    playbackSettingsJSON: #"{"bookId":"KJV","speed":140}"#,
                    createdAt: Date(timeIntervalSince1970: 1_735_700_000),
                    book: "Leviticus",
                    primaryLabelID: currentAndroidSpeakID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_701_100),
                    customIcon: "star"
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Patched bible note", contentType: "MARKDOWN")
            ],
            bibleLinks: [
                .init(bookmarkID: bibleBookmarkID, labelID: currentAndroidSpeakID, orderNumber: 3, indentLevel: 0, expandContent: true)
            ],
            genericBookmarks: [
                .init(
                    id: genericBookmarkID,
                    key: "Entry.1",
                    createdAt: Date(timeIntervalSince1970: 1_735_700_200),
                    bookInitials: "MHC",
                    ordinalStart: 2,
                    ordinalEnd: 2,
                    primaryLabelID: currentAndroidSpeakID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_701_300),
                    wholeVerse: true,
                    playbackSettingsJSON: #"{"bookId":"MHC","queue":false}"#,
                    customIcon: "comment"
                )
            ],
            studyPadEntries: [
                .init(id: studyPadEntryID, labelID: remoteUserLabelID, orderNumber: 6, indentLevel: 2, contentType: "MARKDOWN")
            ],
            studyPadTexts: [
                .init(entryID: studyPadEntryID, text: "Patched study text")
            ],
            logEntries: [
                .init(tableName: "Label", entityID1: .blob(bookmarkUUIDBlob(remoteUserLabelID)), entityID2: .null(), type: .upsert, lastUpdated: 2_000, sourceDevice: "android-a"),
                .init(tableName: "BibleBookmark", entityID1: .blob(bookmarkUUIDBlob(bibleBookmarkID)), entityID2: .null(), type: .upsert, lastUpdated: 2_100, sourceDevice: "android-a"),
                .init(tableName: "BibleBookmarkNotes", entityID1: .blob(bookmarkUUIDBlob(bibleBookmarkID)), entityID2: .null(), type: .upsert, lastUpdated: 2_200, sourceDevice: "android-a"),
                .init(tableName: "BibleBookmarkToLabel", entityID1: .blob(bookmarkUUIDBlob(bibleBookmarkID)), entityID2: .blob(bookmarkUUIDBlob(currentAndroidSpeakID)), type: .upsert, lastUpdated: 2_300, sourceDevice: "android-a"),
                .init(tableName: "GenericBookmark", entityID1: .blob(bookmarkUUIDBlob(genericBookmarkID)), entityID2: .null(), type: .upsert, lastUpdated: 2_400, sourceDevice: "android-a"),
                .init(tableName: "StudyPadTextEntry", entityID1: .blob(bookmarkUUIDBlob(studyPadEntryID)), entityID2: .null(), type: .upsert, lastUpdated: 2_450, sourceDevice: "android-a"),
                .init(tableName: "StudyPadTextEntryText", entityID1: .blob(bookmarkUUIDBlob(studyPadEntryID)), entityID2: .null(), type: .upsert, lastUpdated: 2_500, sourceDevice: "android-a"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeBookmarkPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android-a",
            patchNumber: 1,
            fileTimestamp: 3_000
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 7)
        XCTAssertEqual(report.skippedLogEntryCount, 0)
        XCTAssertEqual(
            report.restoreReport,
            RemoteSyncBookmarkRestoreReport(
                restoredLabelCount: 4,
                restoredBibleBookmarkCount: 1,
                restoredGenericBookmarkCount: 1,
                restoredStudyPadEntryCount: 1,
                preservedPlaybackSettingsCount: 2,
                preservedSystemLabelAliasCount: 3
            )
        )

        let labels = try modelContext.fetch(FetchDescriptor<Label>())
        XCTAssertEqual(labels.first(where: { $0.id == remoteUserLabelID })?.name, "Prayer updated")

        let bibleBookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(bibleBookmarks.count, 1)
        XCTAssertEqual(bibleBookmarks[0].primaryLabelId, Label.speakLabelId)
        XCTAssertEqual(bibleBookmarks[0].notes?.notes, "Patched bible note")
        XCTAssertEqual(bibleBookmarks[0].notes?.contentType, "MARKDOWN")
        XCTAssertEqual(
            Set(bibleBookmarks[0].bookmarkToLabels?.compactMap { $0.label?.id } ?? []),
            Set([remoteUserLabelID, Label.speakLabelId])
        )

        let genericBookmarks = try modelContext.fetch(FetchDescriptor<GenericBookmark>())
        XCTAssertEqual(genericBookmarks.count, 1)
        XCTAssertEqual(genericBookmarks[0].primaryLabelId, Label.speakLabelId)
        XCTAssertEqual(genericBookmarks[0].customIcon, "comment")
        XCTAssertEqual(genericBookmarks[0].notes?.notes, "Old generic note")
        XCTAssertEqual(genericBookmarks[0].notes?.contentType, "HTML")

        let studyPadEntries = try modelContext.fetch(FetchDescriptor<StudyPadTextEntry>())
        XCTAssertEqual(studyPadEntries.count, 1)
        XCTAssertEqual(studyPadEntries[0].orderNumber, 6)
        XCTAssertEqual(studyPadEntries[0].indentLevel, 2)
        XCTAssertEqual(studyPadEntries[0].contentType, "MARKDOWN")
        XCTAssertEqual(studyPadEntries[0].textEntry?.text, "Patched study text")

        XCTAssertEqual(
            playbackStore.playbackSettingsJSON(for: bibleBookmarkID, kind: .bible),
            #"{"bookId":"KJV","speed":140}"#
        )
        XCTAssertEqual(
            playbackStore.playbackSettingsJSON(for: genericBookmarkID, kind: .generic),
            #"{"bookId":"MHC","queue":false}"#
        )
        XCTAssertEqual(aliasStore.localLabelID(forRemoteLabelID: currentAndroidSpeakID), Label.speakLabelId)
        XCTAssertNil(aliasStore.localLabelID(forRemoteLabelID: legacyRemoteSpeakID))
        XCTAssertEqual(patchStatusStore.lastPatchNumber(for: .bookmarks, sourceDevice: "android-a"), 1)
        XCTAssertEqual(
            logEntryStore.entry(
                for: .bookmarks,
                tableName: "Label",
                entityID1: .blob(bookmarkUUIDBlob(remoteUserLabelID)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )?.lastUpdated,
            2_000
        )
    }

    /**
     Verifies patch replay publishes the graph and every sync bookkeeping category atomically.

     A newer Android label patch stages a graph rewrite, replacement `LogEntry`, patch status, and
     refreshed fingerprint. The final publish checkpoint then fails. A fresh context must retain
     the old label, log timestamp, and fingerprint and must not record the patch as applied. Failure
     means a retry could skip a patch whose graph or bookkeeping only partially committed.
     */
    func testRemoteSyncBookmarkPatchApplyRollsBackGraphAndBookkeepingTogether() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreService = RemoteSyncBookmarkRestoreService()
        let patchService = RemoteSyncBookmarkPatchApplyService()
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let labelID = UUID(uuidString: "bb150000-0000-0000-0000-000000000001")!
        let entityID = RemoteSyncSQLiteValue.blob(bookmarkUUIDBlob(labelID))
        let entityID2 = AndroidBookmarkDatabaseContract.emptySecondaryEntityID

        let initialDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: labelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF00FF00)))
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }
        _ = try restoreService.replaceLocalBookmarks(
            from: restoreService.readSnapshot(from: initialDatabaseURL),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        logEntryStore.replaceEntries(
            [
                .init(
                    tableName: "Label",
                    entityID1: entityID,
                    entityID2: entityID2,
                    type: .upsert,
                    lastUpdated: 1_000,
                    sourceDevice: "seed-device"
                )
            ],
            for: .bookmarks
        )
        fingerprintStore.setFingerprint(
            "old-fingerprint",
            for: .bookmarks,
            tableName: "Label",
            entityID1: entityID,
            entityID2: entityID2
        )

        let patchDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: labelID, name: "Prayer updated", colour: Int(Int32(bitPattern: 0xFF33AA33)))
            ],
            logEntries: [
                .init(
                    tableName: "Label",
                    entityID1: entityID,
                    entityID2: .null(),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "android-atomic"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }
        let stagedArchive = try makeBookmarkPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android-atomic",
            patchNumber: 7,
            fileTimestamp: 3_000
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }
        var checkpointCount = 0

        XCTAssertThrowsError(
            try patchService.applyPatchArchives(
                [stagedArchive],
                modelContext: modelContext,
                settingsStore: settingsStore,
                publishCheckpoint: {
                    checkpointCount += 1
                    if checkpointCount == 2 {
                        throw NSError(domain: "BookmarkPatchAtomicity", code: 79)
                    }
                }
            )
        ) { error in
            XCTAssertEqual((error as NSError).domain, "BookmarkPatchAtomicity")
            XCTAssertEqual((error as NSError).code, 79)
        }
        XCTAssertEqual(checkpointCount, 2)

        let verificationContext = ModelContext(container)
        let restoredLabel = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<Label>()).first(where: { $0.id == labelID })
        )
        XCTAssertEqual(restoredLabel.name, "Prayer")

        let verificationSettings = SettingsStore(modelContext: verificationContext)
        XCTAssertEqual(
            RemoteSyncLogEntryStore(settingsStore: verificationSettings).entry(
                for: .bookmarks,
                tableName: "Label",
                entityID1: entityID,
                entityID2: entityID2
            )?.lastUpdated,
            1_000
        )
        XCTAssertNil(
            RemoteSyncPatchStatusStore(settingsStore: verificationSettings).status(
                for: .bookmarks,
                sourceDevice: "android-atomic",
                patchNumber: 7
            )
        )
        XCTAssertEqual(
            RemoteSyncRowFingerprintStore(settingsStore: verificationSettings).fingerprint(
                for: .bookmarks,
                tableName: "Label",
                entityID1: entityID,
                entityID2: entityID2
            ),
            "old-fingerprint"
        )
    }

    /**
     Verifies a strict bookmark baseline projection failure rolls back a staged patch publication.

     A real Android label patch changes the graph, log watermark, patch status, and expected baseline.
     The injected strict snapshot checkpoint fails only when final baseline refresh begins. The old
     label and fingerprint metadata must remain durable in a fresh context. A failure means snapshot
     read errors can commit remote content with missing or authoritative-empty delete baselines.
     */
    func testBookmarkPatchBaselineSnapshotFailureRollsBackGraphAndMetadata() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let labelID = UUID(uuidString: "bb160000-0000-0000-0000-000000000001")!
        let entityID = RemoteSyncSQLiteValue.blob(bookmarkUUIDBlob(labelID))
        let entityID2 = AndroidBookmarkDatabaseContract.emptySecondaryEntityID
        modelContext.insert(Label(id: labelID, name: "Local label"))
        try modelContext.save()

        RemoteSyncLogEntryStore(settingsStore: settingsStore).replaceEntries(
            [
                .init(
                    tableName: "Label",
                    entityID1: entityID,
                    entityID2: entityID2,
                    type: .upsert,
                    lastUpdated: 1_000,
                    sourceDevice: "ios-seed"
                )
            ],
            for: .bookmarks
        )
        RemoteSyncRowFingerprintStore(settingsStore: settingsStore).setFingerprint(
            "old-fingerprint",
            for: .bookmarks,
            tableName: "Label",
            entityID1: entityID,
            entityID2: entityID2
        )

        let patchDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: labelID, name: "Remote label", colour: Int(Int32(bitPattern: 0xFF33AA33)))
            ],
            logEntries: [
                .init(
                    tableName: "Label",
                    entityID1: entityID,
                    entityID2: .null(),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "android-strict"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }
        let stagedArchive = try makeBookmarkPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android-strict",
            patchNumber: 8,
            fileTimestamp: 3_000
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let snapshotService = RemoteSyncBookmarkSnapshotService(
            strictSnapshotCheckpoint: {
                throw NSError(domain: "BookmarkBaselineSnapshot", code: 42)
            }
        )
        let patchService = RemoteSyncBookmarkPatchApplyService(snapshotService: snapshotService)

        XCTAssertThrowsError(
            try patchService.applyPatchArchives(
                [stagedArchive],
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual((error as NSError).domain, "BookmarkBaselineSnapshot")
            XCTAssertEqual((error as NSError).code, 42)
        }

        let verificationContext = ModelContext(container)
        XCTAssertEqual(
            try verificationContext.fetch(FetchDescriptor<Label>()).first(where: { $0.id == labelID })?.name,
            "Local label"
        )
        let verificationSettings = SettingsStore(modelContext: verificationContext)
        XCTAssertEqual(
            RemoteSyncLogEntryStore(settingsStore: verificationSettings).entry(
                for: .bookmarks,
                tableName: "Label",
                entityID1: entityID,
                entityID2: entityID2
            )?.lastUpdated,
            1_000
        )
        XCTAssertNil(
            RemoteSyncPatchStatusStore(settingsStore: verificationSettings).status(
                for: .bookmarks,
                sourceDevice: "android-strict",
                patchNumber: 8
            )
        )
        XCTAssertEqual(
            RemoteSyncRowFingerprintStore(settingsStore: verificationSettings).fingerprint(
                for: .bookmarks,
                tableName: "Label",
                entityID1: entityID,
                entityID2: entityID2
            ),
            "old-fingerprint"
        )
    }

    func testRemoteSyncBookmarkPatchApplyDeletesBookmarkChildrenByCompositeIdentifiers() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreService = RemoteSyncBookmarkRestoreService()
        let patchService = RemoteSyncBookmarkPatchApplyService()

        let remoteUserLabelID = UUID(uuidString: "bb200000-0000-0000-0000-000000000010")!
        let bibleBookmarkID = UUID(uuidString: "bb200000-0000-0000-0000-000000000020")!
        let genericBookmarkID = UUID(uuidString: "bb200000-0000-0000-0000-000000000021")!

        let initialDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteUserLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF00FF00)))
            ],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 50,
                    kjvOrdinalEnd: 50,
                    ordinalStart: 50,
                    ordinalEnd: 50,
                    createdAt: Date(timeIntervalSince1970: 1_735_710_000),
                    primaryLabelID: remoteUserLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_710_100)
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Delete me")
            ],
            bibleLinks: [
                .init(bookmarkID: bibleBookmarkID, labelID: remoteUserLabelID, orderNumber: 1, indentLevel: 0, expandContent: true)
            ],
            genericBookmarks: [
                .init(
                    id: genericBookmarkID,
                    key: "Entry.2",
                    createdAt: Date(timeIntervalSince1970: 1_735_710_200),
                    bookInitials: "MHC",
                    ordinalStart: 8,
                    ordinalEnd: 8,
                    primaryLabelID: remoteUserLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_710_300)
                )
            ],
            genericNotes: [
                .init(bookmarkID: genericBookmarkID, notes: "Delete generic")
            ],
            genericLinks: [
                .init(bookmarkID: genericBookmarkID, labelID: remoteUserLabelID, orderNumber: 2, indentLevel: 0, expandContent: true)
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalBookmarks(
            from: initialSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let patchDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [],
            logEntries: [
                .init(tableName: "BibleBookmarkNotes", entityID1: .blob(bookmarkUUIDBlob(bibleBookmarkID)), entityID2: .null(), type: .delete, lastUpdated: 2_000, sourceDevice: "android-b"),
                .init(tableName: "BibleBookmarkToLabel", entityID1: .blob(bookmarkUUIDBlob(bibleBookmarkID)), entityID2: .blob(bookmarkUUIDBlob(remoteUserLabelID)), type: .delete, lastUpdated: 2_100, sourceDevice: "android-b"),
                .init(tableName: "GenericBookmarkNotes", entityID1: .blob(bookmarkUUIDBlob(genericBookmarkID)), entityID2: .null(), type: .delete, lastUpdated: 2_200, sourceDevice: "android-b"),
                .init(tableName: "GenericBookmarkToLabel", entityID1: .blob(bookmarkUUIDBlob(genericBookmarkID)), entityID2: .blob(bookmarkUUIDBlob(remoteUserLabelID)), type: .delete, lastUpdated: 2_300, sourceDevice: "android-b"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeBookmarkPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android-b",
            patchNumber: 2,
            fileTimestamp: 4_000
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 4)
        XCTAssertEqual(report.skippedLogEntryCount, 0)

        let bibleBookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(bibleBookmarks.count, 1)
        XCTAssertNil(bibleBookmarks[0].notes)
        XCTAssertTrue(bibleBookmarks[0].bookmarkToLabels?.isEmpty ?? true)

        let genericBookmarks = try modelContext.fetch(FetchDescriptor<GenericBookmark>())
        XCTAssertEqual(genericBookmarks.count, 1)
        XCTAssertNil(genericBookmarks[0].notes)
        XCTAssertTrue(genericBookmarks[0].bookmarkToLabels?.isEmpty ?? true)
    }

    func testRemoteSyncBookmarkPatchApplySkipsOlderRows() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreService = RemoteSyncBookmarkRestoreService()
        let patchService = RemoteSyncBookmarkPatchApplyService()
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

        let remoteUserLabelID = UUID(uuidString: "bb300000-0000-0000-0000-000000000010")!
        let bibleBookmarkID = UUID(uuidString: "bb300000-0000-0000-0000-000000000020")!

        let initialDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteUserLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF00FF00)))
            ],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 60,
                    kjvOrdinalEnd: 60,
                    ordinalStart: 60,
                    ordinalEnd: 60,
                    createdAt: Date(timeIntervalSince1970: 1_735_720_000),
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_720_100)
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Local newer note")
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalBookmarks(
            from: initialSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        logEntryStore.replaceEntries([
            .init(
                tableName: "BibleBookmarkNotes",
                entityID1: .blob(bookmarkUUIDBlob(bibleBookmarkID)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: 5_000,
                sourceDevice: "ios-local"
            )
        ], for: .bookmarks)

        let patchDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Older remote note")
            ],
            logEntries: [
                .init(tableName: "BibleBookmarkNotes", entityID1: .blob(bookmarkUUIDBlob(bibleBookmarkID)), entityID2: .null(), type: .upsert, lastUpdated: 4_000, sourceDevice: "android-c")
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeBookmarkPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android-c",
            patchNumber: 3,
            fileTimestamp: 5_500
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 0)
        XCTAssertEqual(report.skippedLogEntryCount, 1)

        let bibleBookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(bibleBookmarks.count, 1)
        XCTAssertEqual(bibleBookmarks[0].notes?.notes, "Local newer note")
        XCTAssertEqual(
            patchStatusStore.status(
                for: .bookmarks,
                sourceDevice: "android-c",
                patchNumber: 3
            )?.appliedDate,
            5_500
        )
        XCTAssertEqual(
            logEntryStore.entry(
                for: .bookmarks,
                tableName: "BibleBookmarkNotes",
                entityID1: .blob(bookmarkUUIDBlob(bibleBookmarkID)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )?.lastUpdated,
            5_000
        )
    }

    func testRemoteSyncBookmarkPatchApplyRunsForeignKeyCleanupForLaterTablesWithoutPatchRows() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreService = RemoteSyncBookmarkRestoreService()
        let patchService = RemoteSyncBookmarkPatchApplyService()

        let remoteUserLabelID = UUID(uuidString: "bb400000-0000-0000-0000-000000000010")!
        let genericBookmarkID = UUID(uuidString: "bb400000-0000-0000-0000-000000000021")!
        let studyPadEntryID = UUID(uuidString: "bb400000-0000-0000-0000-000000000030")!

        let initialDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteUserLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF00FF00)))
            ],
            genericBookmarks: [
                .init(
                    id: genericBookmarkID,
                    key: "Entry.3",
                    createdAt: Date(timeIntervalSince1970: 1_735_730_000),
                    bookInitials: "MHC",
                    ordinalStart: 3,
                    ordinalEnd: 3,
                    primaryLabelID: remoteUserLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_730_100)
                )
            ],
            genericLinks: [
                .init(bookmarkID: genericBookmarkID, labelID: remoteUserLabelID, orderNumber: 1, indentLevel: 0, expandContent: true)
            ],
            studyPadEntries: [
                .init(id: studyPadEntryID, labelID: remoteUserLabelID, orderNumber: 1, indentLevel: 0)
            ],
            studyPadTexts: [
                .init(entryID: studyPadEntryID, text: "Study text")
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalBookmarks(
            from: initialSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let patchDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [],
            logEntries: [
                .init(tableName: "Label", entityID1: .blob(bookmarkUUIDBlob(remoteUserLabelID)), entityID2: .null(), type: .delete, lastUpdated: 2_000, sourceDevice: "android-d")
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeBookmarkPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android-d",
            patchNumber: 4,
            fileTimestamp: 6_000
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 1)
        XCTAssertEqual(report.skippedLogEntryCount, 0)
        XCTAssertEqual(
            report.restoreReport,
            RemoteSyncBookmarkRestoreReport(
                restoredLabelCount: 3,
                restoredBibleBookmarkCount: 0,
                restoredGenericBookmarkCount: 0,
                restoredStudyPadEntryCount: 0,
                preservedPlaybackSettingsCount: 0,
                preservedSystemLabelAliasCount: 3
            )
        )

        let labels = try modelContext.fetch(FetchDescriptor<Label>())
        XCTAssertNil(labels.first(where: { $0.name == "Prayer" }))
        XCTAssertEqual(labels.count, 3)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<GenericBookmark>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<StudyPadTextEntry>()).isEmpty)
    }

    /**
     Verifies that initial-backup upload writes a full Android bookmark database and records the
     accepted patch-zero baseline locally.
     */
    func testRemoteSyncInitialBackupUploadWritesBookmarkDatabaseAndResetsBaseline() async throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let metadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService()
        let restoreDispatcher = RemoteSyncInitialBackupRestoreService()
        let restoreService = RemoteSyncBookmarkRestoreService()

        let speakLabelID = Label.speakLabelId
        let userLabelID = UUID(uuidString: "be100000-0000-0000-0000-000000000001")!
        let bibleBookmarkID = UUID(uuidString: "be100000-0000-0000-0000-000000000010")!
        let genericBookmarkID = UUID(uuidString: "be100000-0000-0000-0000-000000000020")!
        let studyPadEntryID = UUID(uuidString: "be100000-0000-0000-0000-000000000030")!

        let initialDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: speakLabelID, name: Label.speakLabelName, colour: Int(Int32(bitPattern: 0xFFCCAA33))),
                .init(id: userLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF008800)))
            ],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 40,
                    kjvOrdinalEnd: 41,
                    ordinalStart: 40,
                    ordinalEnd: 41,
                    playbackSettingsJSON: #"{"bookId":"KJV","speed":120}"#,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    book: "Leviticus",
                    primaryLabelID: userLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_000_100),
                    wholeVerse: false,
                    type: "EXAMPLE",
                    customIcon: "star",
                    editActionMode: "APPEND",
                    editActionContent: "Amen"
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Bible note", contentType: "MARKDOWN")
            ],
            bibleLinks: [
                .init(bookmarkID: bibleBookmarkID, labelID: userLabelID, orderNumber: 2, indentLevel: 1, expandContent: false)
            ],
            genericBookmarks: [
                .init(
                    id: genericBookmarkID,
                    key: "Entry.1",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_200),
                    bookInitials: "MHC",
                    ordinalStart: 5,
                    ordinalEnd: 5,
                    primaryLabelID: userLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_000_300),
                    wholeVerse: true,
                    playbackSettingsJSON: #"{"bookId":"MHC","queue":true}"#
                )
            ],
            genericNotes: [
                .init(bookmarkID: genericBookmarkID, notes: "Generic note", contentType: "HTML")
            ],
            genericLinks: [
                .init(bookmarkID: genericBookmarkID, labelID: userLabelID, orderNumber: 1, indentLevel: 0, expandContent: true)
            ],
            studyPadEntries: [
                .init(id: studyPadEntryID, labelID: userLabelID, orderNumber: 4, indentLevel: 2, contentType: "MARKDOWN")
            ],
            studyPadTexts: [
                .init(entryID: studyPadEntryID, text: "Study text")
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let stagedBackup = RemoteSyncStagedInitialBackup(
            remoteFile: RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/seed/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 1,
                timestamp: 1_500,
                parentID: "/org.andbible.ios-sync-bookmarks/seed",
                mimeType: "application/gzip"
            ),
            databaseFileURL: initialDatabaseURL,
            schemaVersion: 1
        )
        _ = try restoreDispatcher.restoreInitialBackup(
            stagedBackup,
            category: .bookmarks,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let localLabelNames = Set(try modelContext.fetch(FetchDescriptor<Label>()).map(\.name))

        let syncFolderID = "/org.andbible.ios-sync-bookmarks"
        let adapter = RemoteSyncMockAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(syncFolderID)/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 0,
                timestamp: 2_500,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let service = RemoteSyncInitialBackupUploadService(
            adapter: adapter,
            deviceIdentifier: "ios-device",
            nowProvider: { 2_400 }
        )

        let report = try await service.uploadInitialBackup(
            for: .bookmarks,
            bootstrapState: RemoteSyncBootstrapState(syncFolderID: syncFolderID),
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: 12
        )

        XCTAssertEqual(report.category, .bookmarks)
        XCTAssertEqual(
            patchStatusStore.statuses(for: .bookmarks),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 0,
                    sizeBytes: report.uploadedFile.size,
                    appliedDate: 2_500
                )
            ]
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(stateStore.progressState(for: .bookmarks).lastPatchWritten),
            2_400
        )
        XCTAssertNil(stateStore.progressState(for: .bookmarks).lastSynchronized)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .listFiles(
                parentIDs: [syncFolderID],
                name: "initial.sqlite3.gz",
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .upload(
                name: "initial.sqlite3.gz",
                parentID: syncFolderID,
                contentType: NextCloudSyncAdapter.gzipMimeType
            )
        ])

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedArchive = try XCTUnwrap(uploadedFiles.first)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploaded-bookmark-initial-\(UUID().uuidString).sqlite3.gz")
        let databaseURL = archiveURL.deletingPathExtension()
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: databaseURL)
        }
        try uploadedArchive.data.write(to: archiveURL, options: .atomic)
        let initialDatabaseData = try gunzipTestData(uploadedArchive.data)
        try initialDatabaseData.write(to: databaseURL, options: .atomic)

        let metadataSnapshot = try metadataRestoreService.readSnapshot(from: databaseURL)
        XCTAssertTrue(metadataSnapshot.logEntries.isEmpty)
        XCTAssertTrue(metadataSnapshot.patchStatuses.isEmpty)

        let snapshot = try restoreService.readSnapshot(from: databaseURL)
        XCTAssertEqual(snapshot.labels.count, localLabelNames.count)
        XCTAssertEqual(Set(snapshot.labels.map(\.name)), localLabelNames)
        XCTAssertEqual(snapshot.bibleBookmarks.count, 1)
        XCTAssertEqual(snapshot.bibleBookmarks[0].notes, "Bible note")
        XCTAssertEqual(snapshot.bibleBookmarks[0].notesContentType, "MARKDOWN")
        XCTAssertEqual(snapshot.bibleBookmarks[0].labelLinks.count, 1)
        XCTAssertEqual(snapshot.genericBookmarks.count, 1)
        XCTAssertEqual(snapshot.genericBookmarks[0].notes, "Generic note")
        XCTAssertEqual(snapshot.genericBookmarks[0].notesContentType, "HTML")
        XCTAssertEqual(snapshot.genericBookmarks[0].labelLinks.count, 1)
        XCTAssertEqual(snapshot.studyPadEntries.count, 1)
        XCTAssertEqual(snapshot.studyPadEntries[0].text, "Study text")
        XCTAssertEqual(snapshot.studyPadEntries[0].contentType, "MARKDOWN")
    }

    /// Verifies that bookmark initial restore refreshes the outbound fingerprint baseline so later local deletes emit delete patches.
    func testRemoteSyncBookmarkPatchUploadDetectsDeleteAfterInitialRestoreRefresh() async throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let metadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService()
        let restoreDispatcher = RemoteSyncInitialBackupRestoreService()

        let remoteLabelID = UUID(uuidString: "bc100000-0000-0000-0000-000000000001")!
        let bookmarkID = UUID(uuidString: "bc100000-0000-0000-0000-000000000010")!
        let databaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF00AA00)))
            ],
            bibleBookmarks: [
                .init(
                    id: bookmarkID,
                    kjvOrdinalStart: 50,
                    kjvOrdinalEnd: 50,
                    ordinalStart: 50,
                    ordinalEnd: 50,
                    createdAt: Date(timeIntervalSince1970: 1_735_689_600),
                    primaryLabelID: remoteLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_689_650)
                )
            ],
            logEntries: [
                .init(
                    tableName: "Label",
                    entityID1: .blob(bookmarkUUIDBlob(remoteLabelID)),
                    entityID2: .null(),
                    type: .upsert,
                    lastUpdated: 1_500,
                    sourceDevice: "pixel"
                ),
                .init(
                    tableName: "BibleBookmark",
                    entityID1: .blob(bookmarkUUIDBlob(bookmarkID)),
                    entityID2: .null(),
                    type: .upsert,
                    lastUpdated: 1_500,
                    sourceDevice: "pixel"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let stagedBackup = RemoteSyncStagedInitialBackup(
            remoteFile: RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 1,
                timestamp: 1_500,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: "application/gzip"
            ),
            databaseFileURL: databaseURL,
            schemaVersion: 1
        )

        _ = try restoreDispatcher.restoreInitialBackup(
            stagedBackup,
            category: .bookmarks,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let bookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(bookmarks.count, 1)
        modelContext.delete(bookmarks[0])
        try modelContext.save()

        let adapter = RemoteSyncMockAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/ios-device/1.12.sqlite3.gz",
                name: "1.12.sqlite3.gz",
                size: 0,
                timestamp: 2_500,
                parentID: "/org.andbible.ios-sync-bookmarks/ios-device",
                mimeType: "application/gzip"
            )
        )
        let uploadService = RemoteSyncBookmarkPatchUploadService(
            adapter: adapter,
            nowProvider: { 2_500 }
        )

        let report = try await uploadService.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let unwrappedReport = try XCTUnwrap(report)
        XCTAssertEqual(unwrappedReport.upsertedLabelCount, 0)
        XCTAssertEqual(unwrappedReport.upsertedBibleBookmarkCount, 0)
        XCTAssertEqual(unwrappedReport.upsertedGenericBookmarkCount, 0)
        XCTAssertEqual(unwrappedReport.upsertedStudyPadEntryCount, 0)
        XCTAssertEqual(unwrappedReport.upsertedAuxiliaryRowCount, 0)
        XCTAssertEqual(unwrappedReport.deletedRowCount, 1)
        XCTAssertEqual(unwrappedReport.logEntryCount, 1)

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedArchive = try XCTUnwrap(uploadedFiles.first)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploaded-bookmark-delete-\(UUID().uuidString).sqlite3.gz")
        let databaseURL2 = archiveURL.deletingPathExtension()
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: databaseURL2)
        }
        try uploadedArchive.data.write(to: archiveURL, options: .atomic)
        let patchDatabaseData = try gunzipTestData(uploadedArchive.data)
        try patchDatabaseData.write(to: databaseURL2, options: .atomic)

        let metadataSnapshot = try metadataRestoreService.readSnapshot(from: databaseURL2)
        XCTAssertEqual(metadataSnapshot.logEntries.count, 1)
        XCTAssertEqual(metadataSnapshot.logEntries[0].type, .delete)
        XCTAssertEqual(metadataSnapshot.logEntries[0].tableName, "BibleBookmark")
    }

    /// Verifies that bookmark upload emits a replayable sparse patch and refreshes the local baseline after success.
    func testRemoteSyncBookmarkPatchUploadWritesAndUploadsSparsePatch() async throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreDispatcher = RemoteSyncInitialBackupRestoreService()
        let patchApplyService = RemoteSyncBookmarkPatchApplyService()
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)

        let remoteLabelID = UUID(uuidString: "bc200000-0000-0000-0000-000000000001")!
        let bookmarkID = UUID(uuidString: "bc200000-0000-0000-0000-000000000010")!
        let initialDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF008800)))
            ],
            bibleBookmarks: [
                .init(
                    id: bookmarkID,
                    kjvOrdinalStart: 70,
                    kjvOrdinalEnd: 71,
                    ordinalStart: 70,
                    ordinalEnd: 71,
                    playbackSettingsJSON: #"{"bookId":"KJV","speed":120}"#,
                    createdAt: Date(timeIntervalSince1970: 1_735_689_700),
                    book: "Numbers",
                    primaryLabelID: remoteLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_689_750)
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bookmarkID, notes: "Initial note", contentType: "MARKDOWN")
            ],
            logEntries: [
                .init(
                    tableName: "Label",
                    entityID1: .blob(bookmarkUUIDBlob(remoteLabelID)),
                    entityID2: .null(),
                    type: .upsert,
                    lastUpdated: 1_000,
                    sourceDevice: "pixel"
                ),
                .init(
                    tableName: "BibleBookmark",
                    entityID1: .blob(bookmarkUUIDBlob(bookmarkID)),
                    entityID2: .null(),
                    type: .upsert,
                    lastUpdated: 1_000,
                    sourceDevice: "pixel"
                ),
                .init(
                    tableName: "BibleBookmarkNotes",
                    entityID1: .blob(bookmarkUUIDBlob(bookmarkID)),
                    entityID2: .null(),
                    type: .upsert,
                    lastUpdated: 1_000,
                    sourceDevice: "pixel"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let stagedBackup = RemoteSyncStagedInitialBackup(
            remoteFile: RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 1,
                timestamp: 1_000,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: "application/gzip"
            ),
            databaseFileURL: initialDatabaseURL,
            schemaVersion: 1
        )

        _ = try restoreDispatcher.restoreInitialBackup(
            stagedBackup,
            category: .bookmarks,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let label = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<Label>()).first(where: { $0.name == "Prayer" }))
        label.name = "Prayer renamed"
        let bookmark = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<BibleBookmark>()).first)
        bookmark.notes?.notes = "Updated note"
        try modelContext.save()

        let adapter = RemoteSyncMockAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/ios-device/1.12.sqlite3.gz",
                name: "1.12.sqlite3.gz",
                size: 0,
                timestamp: 2_000,
                parentID: "/org.andbible.ios-sync-bookmarks/ios-device",
                mimeType: "application/gzip"
            )
        )
        let uploadService = RemoteSyncBookmarkPatchUploadService(
            adapter: adapter,
            nowProvider: { 2_000 }
        )

        let report = try await uploadService.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let unwrappedReport = try XCTUnwrap(report)
        XCTAssertEqual(unwrappedReport.patchNumber, 1)
        XCTAssertEqual(unwrappedReport.upsertedLabelCount, 1)
        XCTAssertEqual(unwrappedReport.upsertedBibleBookmarkCount, 0)
        XCTAssertEqual(unwrappedReport.upsertedGenericBookmarkCount, 0)
        XCTAssertEqual(unwrappedReport.upsertedStudyPadEntryCount, 0)
        XCTAssertEqual(unwrappedReport.upsertedAuxiliaryRowCount, 1)
        XCTAssertEqual(unwrappedReport.deletedRowCount, 0)
        XCTAssertEqual(unwrappedReport.logEntryCount, 2)

        XCTAssertEqual(
            patchStatusStore.statuses(for: .bookmarks),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 1,
                    sizeBytes: unwrappedReport.uploadedFile.size,
                    appliedDate: 2_000
                )
            ]
        )
        XCTAssertGreaterThan(unwrappedReport.lastUpdated, 2_000)
        XCTAssertEqual(
            stateStore.progressState(for: .bookmarks).lastPatchWritten,
            unwrappedReport.lastUpdated
        )

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedArchive = try XCTUnwrap(uploadedFiles.first)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploaded-bookmark-\(UUID().uuidString).sqlite3.gz")
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        try uploadedArchive.data.write(to: archiveURL, options: .atomic)

        let replayContainer = try makeBookmarkRestoreModelContainer()
        let replayContext = ModelContext(replayContainer)
        let replaySettingsStore = SettingsStore(modelContext: replayContext)
        _ = try restoreDispatcher.restoreInitialBackup(
            stagedBackup,
            category: .bookmarks,
            modelContext: replayContext,
            settingsStore: replaySettingsStore
        )

        let stagedArchive = RemoteSyncStagedPatchArchive(
            patch: RemoteSyncDiscoveredPatch(
                sourceDevice: "ios-device",
                patchNumber: 1,
                schemaVersion: 12,
                file: unwrappedReport.uploadedFile
            ),
            archiveFileURL: archiveURL
        )
        let replayReport = try patchApplyService.applyPatchArchives(
            [stagedArchive],
            modelContext: replayContext,
            settingsStore: replaySettingsStore
        )

        XCTAssertEqual(replayReport.appliedPatchCount, 1)
        XCTAssertEqual(replayReport.appliedLogEntryCount, 2)
        XCTAssertEqual(replayReport.skippedLogEntryCount, 0)

        let replayLabel = try XCTUnwrap(try replayContext.fetch(FetchDescriptor<Label>()).first(where: { $0.id == remoteLabelID }))
        XCTAssertEqual(replayLabel.name, "Prayer renamed")
        let replayBookmark = try XCTUnwrap(try replayContext.fetch(FetchDescriptor<BibleBookmark>()).first(where: { $0.id == bookmarkID }))
        XCTAssertEqual(replayBookmark.notes?.notes, "Updated note")
        XCTAssertEqual(replayBookmark.notes?.contentType, "MARKDOWN")

        let secondReport = try await uploadService.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertNil(secondReport)
        let uploadedFilesAfterSecondPass = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(uploadedFilesAfterSecondPass.count, 1)
    }

    /// Verifies that a ready bookmark category uploads one sparse local patch when no newer remote patches exist.
    func testRemoteSyncSynchronizationServiceUploadsLocalBookmarkChangesWhenNoRemotePatchesExist() async throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreDispatcher = RemoteSyncInitialBackupRestoreService()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

        let syncFolderID = "/org.andbible.ios-sync-bookmarks"
        let deviceFolderID = "/org.andbible.ios-sync-bookmarks/ios-device"
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: deviceFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .bookmarks
        )

        let remoteLabelID = UUID(uuidString: "bc300000-0000-0000-0000-000000000001")!
        let initialDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF006600)))
            ],
            logEntries: [
                .init(
                    tableName: "Label",
                    entityID1: .blob(bookmarkUUIDBlob(remoteLabelID)),
                    entityID2: .null(),
                    type: .upsert,
                    lastUpdated: 1_000,
                    sourceDevice: "pixel"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let stagedBackup = RemoteSyncStagedInitialBackup(
            remoteFile: RemoteSyncFile(
                id: "\(syncFolderID)/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 1,
                timestamp: 1_000,
                parentID: syncFolderID,
                mimeType: "application/gzip"
            ),
            databaseFileURL: initialDatabaseURL,
            schemaVersion: 1
        )
        _ = try restoreDispatcher.restoreInitialBackup(
            stagedBackup,
            category: .bookmarks,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let label = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<Label>()).first(where: { $0.id == remoteLabelID }))
        label.name = "Prayer synced"
        try modelContext.save()

        let adapter = RemoteSyncMockAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: "device-known-ios-device-secret"
        )
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: deviceFolderID,
                name: "ios-device",
                size: 0,
                timestamp: 1_735_689_700_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([])
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(deviceFolderID)/1.12.sqlite3.gz",
                name: "1.12.sqlite3.gz",
                size: 0,
                timestamp: 4_500_000,
                parentID: deviceFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 4_500_000 }
        )

        let outcome = try await service.synchronize(
            .bookmarks,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        guard case .synchronized(let report) = outcome else {
            return XCTFail("Expected synchronized outcome")
        }

        XCTAssertEqual(report.category, .bookmarks)
        XCTAssertNil(report.initialRestoreReport)
        XCTAssertNil(report.patchReplayReport)
        XCTAssertEqual(report.discoveredPatchCount, 0)
        XCTAssertGreaterThan(try XCTUnwrap(report.lastPatchWritten), 4_500_000)
        XCTAssertEqual(report.lastSynchronized, 4_500_000)

        guard case .bookmarks(let uploadReport)? = report.patchUploadReport else {
            return XCTFail("Expected bookmark patch upload report")
        }

        XCTAssertEqual(uploadReport.patchNumber, 1)
        XCTAssertEqual(uploadReport.upsertedLabelCount, 1)
        XCTAssertEqual(uploadReport.upsertedBibleBookmarkCount, 0)
        XCTAssertEqual(uploadReport.upsertedGenericBookmarkCount, 0)
        XCTAssertEqual(uploadReport.upsertedStudyPadEntryCount, 0)
        XCTAssertEqual(uploadReport.upsertedAuxiliaryRowCount, 0)
        XCTAssertEqual(uploadReport.deletedRowCount, 0)
        XCTAssertEqual(uploadReport.logEntryCount, 1)
        XCTAssertEqual(uploadReport.lastUpdated, report.lastPatchWritten)
        XCTAssertEqual(uploadReport.uploadedFile.name, "1.12.sqlite3.gz")
        XCTAssertEqual(uploadReport.uploadedFile.parentID, deviceFolderID)

        XCTAssertEqual(
            patchStatusStore.statuses(for: .bookmarks),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 1,
                    sizeBytes: uploadReport.uploadedFile.size,
                    appliedDate: 4_500_000
                )
            ]
        )
        XCTAssertEqual(
            stateStore.progressState(for: .bookmarks).lastPatchWritten,
            uploadReport.lastUpdated
        )
        XCTAssertEqual(stateStore.progressState(for: .bookmarks).lastSynchronized, 4_500_000)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .isSyncFolderKnown(
                syncFolderID: syncFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            .listFiles(
                parentIDs: [deviceFolderID],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: [deviceFolderID],
                name: "1.12.sqlite3.gz",
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .upload(
                name: "1.12.sqlite3.gz",
                parentID: deviceFolderID,
                contentType: NextCloudSyncAdapter.gzipMimeType
            ),
            .listFiles(
                parentIDs: [syncFolderID],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
        ])
    }

    /**
     Verifies outbound bookmark preflight propagates a strict projection failure before deriving deletes.

     The snapshot checkpoint stages a settings mutation and throws inside the shared atomic read batch.
     No remote request or bookkeeping change may survive. A failure means a transient graph read could
     still be interpreted as an empty bookmark database.
     */
    func testBookmarkUploadStrictPreflightFailureDoesNotPublishOrMutateBookkeeping() async throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let labelID = UUID(uuidString: "bd100000-0000-0000-0000-000000000001")!
        let label = Label(id: labelID, name: "Accepted")
        modelContext.insert(label)
        try modelContext.save()

        let baselineService = RemoteSyncBookmarkSnapshotService()
        baselineService.refreshBaselineFingerprints(modelContext: modelContext, settingsStore: settingsStore)
        let acceptedSnapshot = try baselineService.snapshotCurrentStateThrowing(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let labelKey = try XCTUnwrap(acceptedSnapshot.labelRowsByKey.first { $0.value.id == labelID }?.key)
        let acceptedFingerprint = acceptedSnapshot.fingerprintsByKey[labelKey]
        label.name = "Dirty"
        try modelContext.save()

        let adapter = BookmarkOutboxTestAdapter(uploadTimestamps: [7_000])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-strict-preflight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotService = RemoteSyncBookmarkSnapshotService(
            strictSnapshotCheckpoint: {
                settingsStore.setString("test.bookmark.upload.preflight", value: "rollback")
                throw NSError(domain: "BookmarkUploadPreflight", code: 51)
            }
        )
        let service = RemoteSyncBookmarkPatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: directory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 6_000 }
        )

        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/bookmarks/ios-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected strict bookmark preflight failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, "BookmarkUploadPreflight")
        }

        let uploadCount = await adapter.uploads().count
        XCTAssertEqual(uploadCount, 0)
        XCTAssertNil(settingsStore.getString("test.bookmark.upload.preflight"))
        XCTAssertNil(settingsStore.getString("remote_sync.pending_upload.bookmarks"))
        XCTAssertEqual(
            RemoteSyncRowFingerprintStore(settingsStore: settingsStore).fingerprint(
                forLogKey: labelKey,
                category: .bookmarks
            ),
            acceptedFingerprint
        )
        XCTAssertTrue(RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .bookmarks).isEmpty)
    }

    /**
     Verifies a bookmark and playback edit made while upload is suspended remains dirty after acceptance.

     The first archive contains the intermediate label and raw playback values. While the adapter is
     suspended, both values change and are saved. Acceptance must publish only the first projection's
     fingerprints, must not overwrite the newer playback JSON, and the next call must emit patch two.
     */
    func testBookmarkUploadKeepsInFlightGraphAndPlaybackEditsDirtyForNextPatch() async throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let labelID = UUID(uuidString: "bd200000-0000-0000-0000-000000000001")!
        let bookmarkID = UUID(uuidString: "bd200000-0000-0000-0000-000000000010")!
        let label = Label(id: labelID, name: "Initial")
        let bookmark = BibleBookmark(
            id: bookmarkID,
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            ordinalStart: 4,
            ordinalEnd: 4,
            v11n: "KJV",
            bookInitials: "KJV",
            ordinalTrustMetadata: PersistedOrdinalTrustPolicy.androidImportMetadata(
                sourceVersification: "KJV",
                sourceOrdinalStart: 4,
                sourceOrdinalEnd: 4,
                kjvaOrdinalStart: 4,
                kjvaOrdinalEnd: 4
            )
        )
        bookmark.book = "Genesis"
        modelContext.insert(label)
        modelContext.insert(bookmark)
        try modelContext.save()

        let playbackStore = RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore)
        playbackStore.setPlaybackSettingsJSON(#"{"bookId":"KJV","speed":100}"#, for: bookmarkID, kind: .bible)
        let snapshotService = RemoteSyncBookmarkSnapshotService()
        snapshotService.refreshBaselineFingerprints(modelContext: modelContext, settingsStore: settingsStore)

        label.name = "Uploaded generation"
        playbackStore.setPlaybackSettingsJSON(#"{"bookId":"KJV","speed":120}"#, for: bookmarkID, kind: .bible)
        try modelContext.save()
        let uploadedSnapshot = try snapshotService.snapshotCurrentStateThrowing(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let labelKey = try XCTUnwrap(uploadedSnapshot.labelRowsByKey.first { $0.value.id == labelID }?.key)
        let bookmarkKey = try XCTUnwrap(
            uploadedSnapshot.bibleBookmarkRowsByKey.first { $0.value.id == bookmarkID }?.key
        )

        let adapter = BookmarkOutboxTestAdapter(uploadTimestamps: [8_000, 9_000])
        await adapter.suspendNextUpload()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-inflight-edit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RemoteSyncBookmarkPatchUploadService(
            adapter: adapter,
            temporaryDirectory: directory,
            outboxDirectory: directory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 7_000 }
        )

        let uploadTask = Task {
            try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/bookmarks/ios-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        }
        await adapter.waitUntilUploadStarts()
        label.name = "Newer local generation"
        playbackStore.setPlaybackSettingsJSON(#"{"bookId":"KJV","speed":145}"#, for: bookmarkID, kind: .bible)
        try modelContext.save()
        await adapter.resumeUpload()

        let firstResult = try await uploadTask.value
        let firstReport = try XCTUnwrap(firstResult)
        XCTAssertEqual(firstReport.patchNumber, 1)
        XCTAssertEqual(
            playbackStore.playbackSettingsJSON(for: bookmarkID, kind: .bible),
            #"{"bookId":"KJV","speed":145}"#
        )
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        XCTAssertEqual(
            fingerprintStore.fingerprint(forLogKey: labelKey, category: .bookmarks),
            uploadedSnapshot.fingerprintsByKey[labelKey]
        )
        XCTAssertEqual(
            fingerprintStore.fingerprint(forLogKey: bookmarkKey, category: .bookmarks),
            uploadedSnapshot.fingerprintsByKey[bookmarkKey]
        )

        let currentSnapshot = try snapshotService.snapshotCurrentStateThrowing(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertNotEqual(currentSnapshot.fingerprintsByKey[labelKey], uploadedSnapshot.fingerprintsByKey[labelKey])
        XCTAssertNotEqual(currentSnapshot.fingerprintsByKey[bookmarkKey], uploadedSnapshot.fingerprintsByKey[bookmarkKey])

        let secondResult = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/bookmarks/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let secondReport = try XCTUnwrap(secondResult)
        XCTAssertEqual(secondReport.patchNumber, 2)
        let uploadedNames = await adapter.uploads().map(\.name)
        XCTAssertEqual(uploadedNames, ["1.12.sqlite3.gz", "2.12.sqlite3.gz"])
    }

    /**
     Verifies remote success followed by local acceptance failure retains a restart-safe bookmark outbox.

     The first acceptance checkpoint throws after every bookkeeping mutation. The remote copy is then
     removed to force a second service instance to re-upload. Both attempts must use identical bytes and
     patch number, while `SyncStatus` uses the second adapter result and `lastPatchWritten` keeps the
     original generation watermark.
     */
    func testBookmarkUploadAcceptanceFailureRetriesExactOutboxGeneration() async throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let labelID = UUID(uuidString: "bd300000-0000-0000-0000-000000000001")!
        let label = Label(id: labelID, name: "Initial")
        modelContext.insert(label)
        try modelContext.save()
        let snapshotService = RemoteSyncBookmarkSnapshotService()
        snapshotService.refreshBaselineFingerprints(modelContext: modelContext, settingsStore: settingsStore)
        let oldSnapshot = try snapshotService.snapshotCurrentStateThrowing(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let labelKey = try XCTUnwrap(oldSnapshot.labelRowsByKey.first { $0.value.id == labelID }?.key)
        label.name = "Pending upload"
        try modelContext.save()

        let adapter = BookmarkOutboxTestAdapter(uploadTimestamps: [11_000, 12_000])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-acceptance-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outboxDirectory = directory.appendingPathComponent("outbox", isDirectory: true)
        let failingService = RemoteSyncBookmarkPatchUploadService(
            adapter: adapter,
            temporaryDirectory: directory,
            outboxDirectory: outboxDirectory,
            nowProvider: { 10_000 }
        )

        do {
            _ = try await failingService.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/bookmarks/ios-device"),
                modelContext: modelContext,
                settingsStore: settingsStore,
                acceptanceCheckpoint: {
                    throw NSError(domain: "BookmarkUploadAcceptance", code: 61)
                }
            )
            XCTFail("Expected bookmark acceptance failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, "BookmarkUploadAcceptance")
        }

        XCTAssertNotNil(settingsStore.getString("remote_sync.pending_upload.bookmarks"))
        XCTAssertEqual(
            RemoteSyncRowFingerprintStore(settingsStore: settingsStore).fingerprint(
                forLogKey: labelKey,
                category: .bookmarks
            ),
            oldSnapshot.fingerprintsByKey[labelKey]
        )
        XCTAssertTrue(RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .bookmarks).isEmpty)
        XCTAssertNil(RemoteSyncStateStore(settingsStore: settingsStore).progressState(for: .bookmarks).lastPatchWritten)

        await adapter.removeRemoteFiles()
        let retryService = RemoteSyncBookmarkPatchUploadService(
            adapter: adapter,
            temporaryDirectory: directory,
            outboxDirectory: outboxDirectory,
            nowProvider: { 99_000 }
        )
        let retryResult = try await retryService.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/bookmarks/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let report = try XCTUnwrap(retryResult)

        let uploads = await adapter.uploads()
        XCTAssertEqual(uploads.count, 2)
        XCTAssertEqual(uploads[0].name, "1.12.sqlite3.gz")
        XCTAssertEqual(uploads[1].name, "1.12.sqlite3.gz")
        XCTAssertEqual(uploads[0].data, uploads[1].data)
        XCTAssertEqual(report.patchNumber, 1)
        XCTAssertNil(settingsStore.getString("remote_sync.pending_upload.bookmarks"))
        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .bookmarks).first?.appliedDate,
            12_000
        )
        XCTAssertGreaterThan(report.lastUpdated, 10_000)
        XCTAssertEqual(
            RemoteSyncStateStore(settingsStore: settingsStore).progressState(for: .bookmarks).lastPatchWritten,
            report.lastUpdated
        )
    }

    /**
     Verifies the accepted-key manifest emits a bookmark delete without relying on a current log row.

     Initial baselines commonly contain rows but no `LogEntry` records. Refreshing that baseline and
     deleting the row must still produce a sparse `DELETE`; otherwise initial-backup deletions vanish.
     */
    func testBookmarkUploadDetectsDeletionFromAcceptedKeyManifestWithoutLogEntry() async throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let label = Label(
            id: UUID(uuidString: "bd400000-0000-0000-0000-000000000001")!,
            name: "Delete after baseline"
        )
        modelContext.insert(label)
        try modelContext.save()
        RemoteSyncBookmarkSnapshotService().refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertTrue(RemoteSyncLogEntryStore(settingsStore: settingsStore).entries(for: .bookmarks).isEmpty)
        modelContext.delete(label)
        try modelContext.save()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-manifest-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploadResult = try await RemoteSyncBookmarkPatchUploadService(
            adapter: BookmarkOutboxTestAdapter(uploadTimestamps: [14_000]),
            temporaryDirectory: directory,
            outboxDirectory: directory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 13_000 }
        ).uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/bookmarks/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let report = try XCTUnwrap(uploadResult)

        XCTAssertEqual(report.deletedRowCount, 1)
        XCTAssertEqual(report.logEntryCount, 1)
        XCTAssertEqual(RemoteSyncLogEntryStore(settingsStore: settingsStore).entries(for: .bookmarks).first?.type, .delete)
    }

    /**
     Verifies missing local patch status allocates after the highest existing remote bookmark patch.

     A remote patch seven with no local `SyncStatus` must produce patch eight. Reusing patch one would
     collide with accepted remote history and permanently wedge exact-name reconciliation.
     */
    func testBookmarkUploadAllocatesAfterRemoteHistoryWhenLocalStatusIsMissing() async throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let label = Label(name: "Accepted")
        modelContext.insert(label)
        try modelContext.save()
        RemoteSyncBookmarkSnapshotService().refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        label.name = "Dirty"
        try modelContext.save()

        let deviceFolderID = "/bookmarks/ios-device"
        let adapter = BookmarkOutboxTestAdapter(uploadTimestamps: [16_000])
        await adapter.seedRemoteFile(
            name: "7.12.sqlite3.gz",
            parentID: deviceFolderID,
            data: Data("accepted remote patch".utf8),
            timestamp: 15_000
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-remote-numbering-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let uploadResult = try await RemoteSyncBookmarkPatchUploadService(
            adapter: adapter,
            temporaryDirectory: directory,
            outboxDirectory: directory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 15_500 }
        ).uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: deviceFolderID),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let report = try XCTUnwrap(uploadResult)

        XCTAssertEqual(report.patchNumber, 8)
        let uploads = await adapter.uploads()
        XCTAssertEqual(uploads.map(\.name), ["8.12.sqlite3.gz"])
    }

    /**
     Verifies malformed bookmark patch status is not interpreted as an absent accepted sequence.

     Strict status decoding runs in the same preflight transaction as graph projection. Corrupt JSON
     must abort before an outbox or remote patch is created.
     */
    func testBookmarkUploadRejectsMalformedAcceptedPatchStatus() async throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let label = Label(name: "Accepted")
        modelContext.insert(label)
        try modelContext.save()
        RemoteSyncBookmarkSnapshotService().refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        label.name = "Dirty"
        try modelContext.save()
        let statusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let corruptKey = statusStore.key(for: .bookmarks, sourceDevice: "ios-device", patchNumber: 4)
        settingsStore.setString(corruptKey, value: "{not-json")

        let adapter = BookmarkOutboxTestAdapter(uploadTimestamps: [18_000])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-corrupt-status-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await RemoteSyncBookmarkPatchUploadService(
                adapter: adapter,
                temporaryDirectory: directory,
                outboxDirectory: directory.appendingPathComponent("outbox", isDirectory: true)
            ).uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/bookmarks/ios-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected malformed bookmark patch status to fail closed")
        } catch let error as RemoteSyncPatchStatusStoreError {
            XCTAssertEqual(error, .invalidStoredStatus(corruptKey))
        }

        let uploads = await adapter.uploads()
        XCTAssertTrue(uploads.isEmpty)
        XCTAssertNil(settingsStore.getString("remote_sync.pending_upload.bookmarks"))
    }

    /**
     Verifies acceptance rejects an outbox projected from a superseded bookmark baseline revision.

     The remote create succeeds after a concurrent baseline publication. Local acceptance must fail
     before replacing logs, status, progress, or fingerprints, and the durable outbox must remain.
     */
    func testBookmarkUploadRejectsStaleAcceptedBaselineAfterRemoteSuccess() async throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let label = Label(name: "Accepted")
        modelContext.insert(label)
        try modelContext.save()
        let snapshotService = RemoteSyncBookmarkSnapshotService()
        snapshotService.refreshBaselineFingerprints(modelContext: modelContext, settingsStore: settingsStore)
        label.name = "Pending"
        try modelContext.save()

        let adapter = BookmarkOutboxTestAdapter(uploadTimestamps: [20_000])
        await adapter.suspendNextUpload()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-baseline-cas-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RemoteSyncBookmarkPatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: directory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 19_000 }
        )
        let uploadTask = Task {
            try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/bookmarks/ios-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        }
        await adapter.waitUntilUploadStarts()
        try snapshotService.refreshBaselineFingerprintsThrowing(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        await adapter.resumeUpload()

        do {
            _ = try await uploadTask.value
            XCTFail("Expected stale bookmark baseline acceptance to fail")
        } catch let error as RemoteSyncBookmarkAcceptedBaselineError {
            XCTAssertEqual(error, .staleAcceptedBaseline)
        }
        XCTAssertNotNil(settingsStore.getString("remote_sync.pending_upload.bookmarks"))
        XCTAssertTrue(RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .bookmarks).isEmpty)
    }

    /**
     Verifies a destination mismatch fails closed until lifecycle explicitly discards the bookmark outbox.

     An ambiguous old-destination upload must not be silently republished elsewhere. Explicit cleanup
     removes only pending state, after which the unchanged accepted baseline rebuilds dirty live rows.
     */
    func testBookmarkDestinationReplacementRequiresExplicitPendingCleanup() async throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let label = Label(name: "Accepted")
        modelContext.insert(label)
        try modelContext.save()
        RemoteSyncBookmarkSnapshotService().refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        label.name = "Dirty"
        try modelContext.save()

        let adapter = BookmarkOutboxTestAdapter(uploadTimestamps: [22_000, 23_000])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-destination-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RemoteSyncBookmarkPatchUploadService(
            adapter: adapter,
            temporaryDirectory: directory,
            outboxDirectory: directory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 21_000 }
        )
        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/bookmarks/old-device"),
                modelContext: modelContext,
                settingsStore: settingsStore,
                acceptanceCheckpoint: { throw NSError(domain: "BookmarkDestination", code: 71) }
            )
            XCTFail("Expected local acceptance failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, "BookmarkDestination")
        }

        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/bookmarks/new-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected mismatched bookmark outbox to fail closed")
        } catch let error as RemoteSyncBookmarkPatchUploadError {
            XCTAssertEqual(error, .invalidPendingUpload)
        }

        try service.discardPendingUploadForDestinationReplacement(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let replacementResult = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/bookmarks/new-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let report = try XCTUnwrap(replacementResult)
        XCTAssertEqual(report.patchNumber, 1)
        let uploads = await adapter.uploads()
        XCTAssertEqual(uploads.map(\.parentID), ["/bookmarks/old-device", "/bookmarks/new-device"])
    }

    /** Verifies every exportable bookmark row requires a computed fingerprint. */
    func testBookmarkAcceptedGenerationRejectsExportableRowWithoutFingerprint() async throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        modelContext.insert(Label(name: "Fingerprint required"))
        try modelContext.save()
        let service = RemoteSyncBookmarkSnapshotService()
        let snapshot = try service.snapshotCurrentStateThrowing(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let key = try XCTUnwrap(snapshot.labelRowsByKey.first?.key)
        let missingFingerprintSnapshot = RemoteSyncBookmarkCurrentSnapshot(
            labelRowsByKey: snapshot.labelRowsByKey,
            bibleBookmarkRowsByKey: snapshot.bibleBookmarkRowsByKey,
            bibleNoteRowsByKey: snapshot.bibleNoteRowsByKey,
            bibleLinkRowsByKey: snapshot.bibleLinkRowsByKey,
            genericBookmarkRowsByKey: snapshot.genericBookmarkRowsByKey,
            genericNoteRowsByKey: snapshot.genericNoteRowsByKey,
            genericLinkRowsByKey: snapshot.genericLinkRowsByKey,
            studyPadEntryRowsByKey: snapshot.studyPadEntryRowsByKey,
            studyPadTextRowsByKey: snapshot.studyPadTextRowsByKey,
            fingerprintsByKey: [:]
        )

        XCTAssertThrowsError(
            try service.acceptedBaselineThrowing(from: missingFingerprintSnapshot, preserving: nil)
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncBookmarkAcceptedBaselineError,
                .missingProjectedFingerprint(key)
            )
        }
    }

    /** Verifies quarantined bookmark keys preserve accepted identity and fingerprint metadata. */
    func testBookmarkAcceptedGenerationPreservesSuppressedPriorRowMetadata() async throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        modelContext.insert(Label(name: "Quarantine baseline"))
        try modelContext.save()
        let service = RemoteSyncBookmarkSnapshotService()
        let snapshot = try service.snapshotCurrentStateThrowing(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let key = try XCTUnwrap(snapshot.labelRowsByKey.first?.key)
        let previousBaseline = try service.acceptedBaselineThrowing(from: snapshot, preserving: nil)
        let suppressedSnapshot = RemoteSyncBookmarkCurrentSnapshot(
            labelRowsByKey: [:],
            bibleBookmarkRowsByKey: [:],
            bibleNoteRowsByKey: [:],
            bibleLinkRowsByKey: [:],
            genericBookmarkRowsByKey: [:],
            genericNoteRowsByKey: [:],
            genericLinkRowsByKey: [:],
            studyPadEntryRowsByKey: [:],
            studyPadTextRowsByKey: [:],
            fingerprintsByKey: [:],
            suppressedKeys: [key]
        )

        let replacement = try service.acceptedBaselineThrowing(
            from: suppressedSnapshot,
            preserving: previousBaseline
        )
        XCTAssertEqual(replacement.fingerprintsByKey[key], previousBaseline.fingerprintsByKey[key])
        XCTAssertEqual(replacement.rowIdentities.map(\.key), [key])
    }

}

/**
 Deterministic remote adapter for bookmark outbox, suspension, and reconciliation tests.

 Upload suspension is continuation-driven rather than timer-driven. Uploaded bytes are retained by
 destination/name so retries can list and download the exact remote object. Tests may remove remote
 files while preserving attempt history to force a durable local re-upload.
 */
private actor BookmarkOutboxTestAdapter: RemoteSyncAdapting, RemoteSyncConditionalFileUploading {
    /// One completed upload attempt captured for byte-level assertions.
    struct Upload: Sendable, Equatable {
        let name: String
        let parentID: String
        let data: Data
        let timestamp: Int64
    }

    private var uploadTimestamps: [Int64]
    private var uploadAttempts: [Upload] = []
    private var remoteFilesByID: [String: (file: RemoteSyncFile, data: Data)] = [:]
    private var shouldSuspendNextUpload = false
    private var uploadDidStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    /** Creates an adapter that assigns supplied timestamps to upload results in order. */
    init(uploadTimestamps: [Int64]) {
        self.uploadTimestamps = uploadTimestamps
    }

    /** Configures the next upload to pause after reading local bytes and before remote publication. */
    func suspendNextUpload() {
        shouldSuspendNextUpload = true
        uploadDidStart = false
    }

    /** Waits deterministically until the suspended upload has captured its immutable archive bytes. */
    func waitUntilUploadStarts() async {
        if uploadDidStart { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    /** Releases a suspended upload. */
    func resumeUpload() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    /** Removes remote files while preserving completed upload-attempt history. */
    func removeRemoteFiles() {
        remoteFilesByID.removeAll()
    }

    /** Seeds one remote object for numbering and exact-byte reconciliation tests. */
    func seedRemoteFile(name: String, parentID: String, data: Data, timestamp: Int64) {
        let id = "\(parentID)/\(name)"
        remoteFilesByID[id] = (
            RemoteSyncFile(
                id: id,
                name: name,
                size: Int64(data.count),
                timestamp: timestamp,
                parentID: parentID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            ),
            data
        )
    }

    /** Returns completed upload attempts in call order. */
    func uploads() -> [Upload] {
        uploadAttempts
    }

    func listFiles(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        modifiedAtLeast: Date?
    ) async throws -> [RemoteSyncFile] {
        remoteFilesByID.values.map(\.file).filter { file in
            (parentIDs == nil || parentIDs!.contains(file.parentID))
                && (name == nil || file.name == name)
                && (mimeType == nil || file.mimeType == mimeType)
                && (modifiedAtLeast == nil
                    || Date(timeIntervalSince1970: TimeInterval(file.timestamp) / 1_000) >= modifiedAtLeast!)
        }
    }

    func createNewFolder(name: String, parentID: String?) async throws -> RemoteSyncFile {
        RemoteSyncFile(
            id: "\(parentID ?? "/")/\(name)",
            name: name,
            size: 0,
            timestamp: 0,
            parentID: parentID ?? "/",
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
    }

    func download(id: String) async throws -> Data {
        remoteFilesByID[id]?.data ?? Data()
    }

    func upload(name: String, fileURL: URL, parentID: String, contentType: String) async throws -> RemoteSyncFile {
        let data = try Data(contentsOf: fileURL)
        if shouldSuspendNextUpload {
            shouldSuspendNextUpload = false
            uploadDidStart = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        let timestamp = uploadTimestamps.isEmpty ? 0 : uploadTimestamps.removeFirst()
        let id = "\(parentID)/\(name)"
        let file = RemoteSyncFile(
            id: id,
            name: name,
            size: Int64(data.count),
            timestamp: timestamp,
            parentID: parentID,
            mimeType: contentType
        )
        uploadAttempts.append(Upload(name: name, parentID: parentID, data: data, timestamp: timestamp))
        remoteFilesByID[id] = (file, data)
        return file
    }

    /** Atomically creates one test remote object without replacing an occupied name. */
    func uploadIfAbsent(
        name: String,
        fileURL: URL,
        maximumByteCount: Int,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncConditionalUploadResult {
        let data = try RemoteSyncBoundedFileIO.readRegularFile(
            at: fileURL,
            maximumByteCount: maximumByteCount
        )
        let id = "\(parentID)/\(name)"
        guard remoteFilesByID[id] == nil else {
            return .alreadyExists
        }
        if shouldSuspendNextUpload {
            shouldSuspendNextUpload = false
            uploadDidStart = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { releaseContinuation = $0 }
            guard remoteFilesByID[id] == nil else {
                return .alreadyExists
            }
        }
        let timestamp = uploadTimestamps.isEmpty ? 0 : uploadTimestamps.removeFirst()
        let file = RemoteSyncFile(
            id: id,
            name: name,
            size: Int64(data.count),
            timestamp: timestamp,
            parentID: parentID,
            mimeType: contentType
        )
        uploadAttempts.append(Upload(name: name, parentID: parentID, data: data, timestamp: timestamp))
        remoteFilesByID[id] = (file, data)
        return .created(file)
    }

    func delete(id: String) async throws {
        remoteFilesByID.removeValue(forKey: id)
    }

    func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool { true }

    func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        "device-known-\(deviceIdentifier)-secret"
    }
}

/** Gives the shared queued remote-sync fake an explicit create-only test capability. */
extension RemoteSyncMockAdapter: RemoteSyncConditionalFileUploading {
    /** Records a bounded conditional-create file through the fake's queued upload behavior. */
    func uploadIfAbsent(
        name: String,
        fileURL: URL,
        maximumByteCount: Int,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncConditionalUploadResult {
        _ = try RemoteSyncBoundedFileIO.fingerprintRegularFile(
            at: fileURL,
            maximumByteCount: maximumByteCount
        )
        return .created(try await upload(
            name: name,
            fileURL: fileURL,
            parentID: parentID,
            contentType: contentType
        ))
    }
}

/**
 Deterministic in-memory resolver double for Android book-name normalization tests.

 The fake answers initials membership from a fixed set and derives display names from a fixed
 ordinal map while recording every derivation request, so tests can assert both the normalization
 rule and the versification plumbing without SWORD modules.

 Side effects:
 - records derivation requests in `recordedRequests`

 Failure modes:
 - returns `nil` for ordinals missing from `namesByOrdinal`, matching real resolver misses
 */
private final class FakeAndroidBookmarkBookNameResolver: AndroidBookmarkBookNameResolving {
    /// One recorded derivation request in call order.
    struct Request: Equatable {
        /// Versification name the service passed for this bookmark.
        let v11nName: String

        /// Source-versification ordinal the service passed.
        let ordinal: Int

        /// KJVA fallback ordinal the service passed.
        let kjvOrdinal: Int
    }

    private let installedBibleInitials: Set<String>
    private let namesByOrdinal: [Int: String]

    /// Derivation requests observed by the fake, in call order.
    private(set) var recordedRequests: [Request] = []

    /**
     Creates the fake resolver.

     - Parameters:
       - installedBibleInitials: Module initials treated as installed Bibles.
       - namesByOrdinal: Display book names keyed by source ordinal.
     - Side effects: none.
     - Failure modes: none.
     */
    init(installedBibleInitials: Set<String>, namesByOrdinal: [Int: String]) {
        self.installedBibleInitials = installedBibleInitials
        self.namesByOrdinal = namesByOrdinal
    }

    /**
     Reports whether a raw value matches the configured installed-Bible initials.

     - Parameter rawValue: Raw Android `book` column value.
     - Returns: `true` when the fixture set contains the value.
     - Side effects: none.
     - Failure modes: none.
     */
    func isInstalledBibleInitials(_ rawValue: String) -> Bool {
        installedBibleInitials.contains(rawValue)
    }

    /**
     Derives a display book name from the fixture ordinal map.

     - Parameters:
       - v11nName: Versification name passed by the service.
       - ordinal: Source-versification ordinal passed by the service.
       - kjvOrdinal: KJVA fallback ordinal passed by the service.
     - Returns: The fixture name for `ordinal`, or `nil` when unmapped.
     - Side effects: appends the request to `recordedRequests`.
     - Failure modes: none.
     */
    func displayBookName(v11nName: String, ordinal: Int, kjvOrdinal: Int) -> String? {
        recordedRequests.append(Request(v11nName: v11nName, ordinal: ordinal, kjvOrdinal: kjvOrdinal))
        return namesByOrdinal[ordinal]
    }
}
