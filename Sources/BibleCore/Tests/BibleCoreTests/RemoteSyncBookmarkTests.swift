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
                makeNormalizationBookmark(id: initialsID, ordinalStart: 4, book: "KJV"),
                makeNormalizationBookmark(id: nullBookID, ordinalStart: 1533, book: nil),
                makeNormalizationBookmark(id: localizedID, ordinalStart: 4, book: "1. Mose"),
                makeNormalizationBookmark(id: uninstalledID, ordinalStart: 4, book: "ESV2011"),
                makeNormalizationBookmark(id: unresolvableID, ordinalStart: 999_999, book: "NASB"),
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
        XCTAssertEqual(
            booksByID[initialsID],
            "Genesis",
            "Installed-module initials must be rewritten to the derived display book name."
        )
        XCTAssertEqual(
            booksByID[nullBookID],
            "Exodus",
            "NULL Android book values must be derived from the bookmark's own ordinals."
        )
        XCTAssertEqual(
            booksByID[localizedID],
            "1. Mose",
            "Values that are not installed-module initials must survive unchanged."
        )
        XCTAssertEqual(
            booksByID[uninstalledID],
            "ESV2011",
            "Initials of modules that are not installed cannot be classified and must be preserved."
        )
        XCTAssertEqual(
            booksByID[unresolvableID],
            "NASB",
            "When derivation fails the raw Android value must be preserved rather than dropped."
        )
        XCTAssertEqual(
            resolver.recordedRequests.map(\.v11nName),
            ["KJV", "KJV", "KJV"],
            "Derivation must resolve ordinals in each bookmark's own stored versification."
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
        book: String?
    ) -> RemoteSyncAndroidBibleBookmark {
        RemoteSyncAndroidBibleBookmark(
            id: id,
            kjvOrdinalStart: ordinalStart,
            kjvOrdinalEnd: ordinalStart,
            ordinalStart: ordinalStart,
            ordinalEnd: ordinalStart,
            v11n: "KJV",
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
                    "StudyPadTextEntry.id=\(studyPadEntryID.uuidString) missing StudyPadTextEntryText",
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

        let remoteSpeakID = UUID(uuidString: "bb100000-0000-0000-0000-000000000001")!
        let remoteUserLabelID = UUID(uuidString: "bb100000-0000-0000-0000-000000000010")!
        let bibleBookmarkID = UUID(uuidString: "bb100000-0000-0000-0000-000000000020")!
        let genericBookmarkID = UUID(uuidString: "bb100000-0000-0000-0000-000000000021")!
        let studyPadEntryID = UUID(uuidString: "bb100000-0000-0000-0000-000000000030")!

        let initialDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteSpeakID, name: Label.speakLabelName, colour: Int(Int32(bitPattern: 0xFFFF9999))),
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
                    primaryLabelID: remoteSpeakID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_701_100),
                    customIcon: "star"
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Patched bible note", contentType: "MARKDOWN")
            ],
            bibleLinks: [
                .init(bookmarkID: bibleBookmarkID, labelID: remoteSpeakID, orderNumber: 3, indentLevel: 0, expandContent: true)
            ],
            genericBookmarks: [
                .init(
                    id: genericBookmarkID,
                    key: "Entry.1",
                    createdAt: Date(timeIntervalSince1970: 1_735_700_200),
                    bookInitials: "MHC",
                    ordinalStart: 2,
                    ordinalEnd: 2,
                    primaryLabelID: remoteSpeakID,
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
                .init(tableName: "BibleBookmarkToLabel", entityID1: .blob(bookmarkUUIDBlob(bibleBookmarkID)), entityID2: .blob(bookmarkUUIDBlob(remoteSpeakID)), type: .upsert, lastUpdated: 2_300, sourceDevice: "android-a"),
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
        XCTAssertEqual(aliasStore.localLabelID(forRemoteLabelID: remoteSpeakID), Label.speakLabelId)
        XCTAssertEqual(patchStatusStore.lastPatchNumber(for: .bookmarks, sourceDevice: "android-a"), 1)
        XCTAssertEqual(
            logEntryStore.entry(
                for: .bookmarks,
                tableName: "Label",
                entityID1: .blob(bookmarkUUIDBlob(remoteUserLabelID)),
                entityID2: .null()
            )?.lastUpdated,
            2_000
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

        XCTAssertEqual(report.appliedPatchCount, 0)
        XCTAssertEqual(report.appliedLogEntryCount, 0)
        XCTAssertEqual(report.skippedLogEntryCount, 1)

        let bibleBookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(bibleBookmarks.count, 1)
        XCTAssertEqual(bibleBookmarks[0].notes?.notes, "Local newer note")
        XCTAssertNil(patchStatusStore.status(for: .bookmarks, sourceDevice: "android-c", patchNumber: 3))
        XCTAssertEqual(
            logEntryStore.entry(
                for: .bookmarks,
                tableName: "BibleBookmarkNotes",
                entityID1: .blob(bookmarkUUIDBlob(bibleBookmarkID)),
                entityID2: .null()
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
            settingsStore: settingsStore
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
        XCTAssertEqual(stateStore.progressState(for: .bookmarks).lastPatchWritten, 2_400)
        XCTAssertNil(stateStore.progressState(for: .bookmarks).lastSynchronized)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
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
                id: "/org.andbible.ios-sync-bookmarks/ios-device/1.1.sqlite3.gz",
                name: "1.1.sqlite3.gz",
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
                id: "/org.andbible.ios-sync-bookmarks/ios-device/1.1.sqlite3.gz",
                name: "1.1.sqlite3.gz",
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
        XCTAssertEqual(stateStore.progressState(for: .bookmarks).lastPatchWritten, 2_000)

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
                schemaVersion: 1,
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
        XCTAssertEqual(report.lastPatchWritten, 4_500_000)
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
        XCTAssertEqual(uploadReport.uploadedFile.name, "1.1.sqlite3.gz")
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
        XCTAssertEqual(stateStore.progressState(for: .bookmarks).lastPatchWritten, 4_500_000)
        XCTAssertEqual(stateStore.progressState(for: .bookmarks).lastSynchronized, 4_500_000)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .isSyncFolderKnown(
                syncFolderID: syncFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            .listFiles(
                parentIDs: [syncFolderID],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: [deviceFolderID],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .upload(
                name: "1.1.sqlite3.gz",
                parentID: deviceFolderID,
                contentType: NextCloudSyncAdapter.gzipMimeType
            ),
        ])
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
