import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/**
 Behavioral contracts for the value-captured bookmark snapshot projector.

 These cases assert complete Android-shaped values at the public snapshot boundary. They do not
 inspect implementation helpers, and they retain the existing strict/quarantine tests in
 `RemoteSyncBookmarkTests` as the error-publication contract.
 */
final class RemoteSyncBookmarkSnapshotProjectionAlgorithmTests: XCTestCase {
    /**
     Verifies fresh-context point reads and the complete snapshot retain exact namespace/key
     semantics without depending on unrelated large settings stored in the same SQLite database.
     */
    func testDiskBackedSnapshotScopesFidelityNamespacesAndPreservesPointReadSemantics() throws {
        let directory = try makeProcessLifetimePersistentStoreDirectory(
            label: "bookmark-snapshot-namespace"
        )

        try autoreleasepool {
            let cloudModels = BibleCoreBaseModelRegistration.cloudModels
            let localModels = BibleCoreBaseModelRegistration.localModels
            let schema = Schema(cloudModels + localModels)
            let cloudConfiguration = ModelConfiguration(
                "BookmarkSnapshotNamespaceGraph",
                schema: Schema(cloudModels),
                url: directory.appendingPathComponent("BookmarkSnapshotNamespaceGraph.store"),
                cloudKitDatabase: .none
            )
            let localConfiguration = ModelConfiguration(
                "BookmarkSnapshotNamespaceSettings",
                schema: Schema(localModels),
                url: directory.appendingPathComponent("BookmarkSnapshotNamespaceSettings.store"),
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(
                for: schema,
                configurations: [cloudConfiguration, localConfiguration]
            )
            let writer = ModelContext(container)
            writer.autosaveEnabled = false

            let canonicalID = UUID(uuidString: "11abcdef-0000-0000-0000-000000000001")!
            let uppercaseOnlyID = UUID(uuidString: "22abcdef-0000-0000-0000-000000000002")!
            let nullID = UUID(uuidString: "33abcdef-0000-0000-0000-000000000003")!
            let emptyID = UUID(uuidString: "44abcdef-0000-0000-0000-000000000004")!
            let missingID = UUID(uuidString: "55abcdef-0000-0000-0000-000000000005")!
            let localBooks: [(UUID, String)] = [
                (canonicalID, "LOCAL-CANONICAL"),
                (uppercaseOnlyID, "LOCAL-UPPERCASE"),
                (nullID, "LOCAL-NULL"),
                (emptyID, "LOCAL-EMPTY"),
                (missingID, "LOCAL-MISSING"),
            ]
            for (index, value) in localBooks.enumerated() {
                let ordinal = index + 4
                writer.insert(BibleBookmark(
                    id: value.0,
                    kjvOrdinalStart: ordinal,
                    kjvOrdinalEnd: ordinal,
                    ordinalStart: ordinal,
                    ordinalEnd: ordinal,
                    v11n: "KJVA",
                    bookInitials: value.1,
                    ordinalTrustMetadata: PersistedOrdinalTrustPolicy.androidImportMetadata(
                        sourceVersification: "KJVA",
                        sourceOrdinalStart: ordinal,
                        sourceOrdinalEnd: ordinal,
                        kjvaOrdinalStart: ordinal,
                        kjvaOrdinalEnd: ordinal
                    )
                ))
            }

            let largePayload = String(repeating: "x", count: 8_192)
            for index in 0..<64 {
                writer.insert(Setting(
                    key: "remote_sync.pending_mutations.ai.large.\(index)",
                    value: largePayload
                ))
                writer.insert(Setting(
                    key: "ai.runtime.history.large.\(index)",
                    value: largePayload
                ))
            }

            let canonicalBookKey = "remote_sync.bookmarks.android_book.\(canonicalID.uuidString.lowercased())"
            let canonicalBookUppercaseAlias =
                "remote_sync.bookmarks.android_book.\(canonicalID.uuidString.uppercased())"
            let uppercaseOnlyBookKey =
                "remote_sync.bookmarks.android_book.\(uppercaseOnlyID.uuidString.uppercased())"
            let emptyBookKey = "remote_sync.bookmarks.android_book.\(emptyID.uuidString.lowercased())"
            let adjacentBookKey =
                "remote_sync.bookmarks.android_bookkeeping.\(canonicalID.uuidString.lowercased())"
            writer.insert(Setting(key: canonicalBookKey, value: "CANONICAL"))
            writer.insert(Setting(key: canonicalBookUppercaseAlias, value: "UPPERCASE-CONFLICT"))
            writer.insert(Setting(key: uppercaseOnlyBookKey, value: "UPPERCASE-ONLY"))
            writer.insert(Setting(key: emptyBookKey, value: ""))
            writer.insert(Setting(key: "remote_sync.bookmarks.android_book.not-a-uuid", value: "MALFORMED"))
            writer.insert(Setting(key: adjacentBookKey, value: "ADJACENT"))

            let canonicalPlaybackKey =
                "remote_sync.bookmarks.android_playback_settings.bible.\(canonicalID.uuidString.lowercased())"
            let canonicalPlaybackUppercaseAlias =
                "remote_sync.bookmarks.android_playback_settings.bible.\(canonicalID.uuidString.uppercased())"
            let uppercaseOnlyPlaybackKey =
                "remote_sync.bookmarks.android_playback_settings.bible.\(uppercaseOnlyID.uuidString.uppercased())"
            let emptyPlaybackKey =
                "remote_sync.bookmarks.android_playback_settings.bible.\(emptyID.uuidString.lowercased())"
            let adjacentPlaybackKey =
                "remote_sync.bookmarks.android_playback_settings_extra.bible.\(canonicalID.uuidString.lowercased())"
            let canonicalPlayback = #"{"bookId":"CANONICAL","speed":120}"#
            writer.insert(Setting(key: canonicalPlaybackKey, value: canonicalPlayback))
            writer.insert(Setting(
                key: canonicalPlaybackUppercaseAlias,
                value: #"{"bookId":"UPPERCASE-CONFLICT","speed":121}"#
            ))
            writer.insert(Setting(
                key: uppercaseOnlyPlaybackKey,
                value: #"{"bookId":"UPPERCASE-ONLY","speed":122}"#
            ))
            writer.insert(Setting(key: emptyPlaybackKey, value: ""))
            writer.insert(Setting(
                key: "remote_sync.bookmarks.android_playback_settings.bible.not-a-uuid",
                value: #"{"bookId":"MALFORMED"}"#
            ))
            writer.insert(Setting(key: adjacentPlaybackKey, value: "ADJACENT"))
            try writer.save()

            RemoteSyncBookmarkAndroidBookStore(
                settingsStore: SettingsStore(modelContext: writer)
            ).setRawBook(nil, for: nullID)

            let reader = ModelContext(container)
            reader.autosaveEnabled = false
            let settingsStore = SettingsStore(modelContext: reader)
            let bookStore = RemoteSyncBookmarkAndroidBookStore(settingsStore: settingsStore)
            let playbackStore = RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore)

            XCTAssertEqual(settingsStore.getString(adjacentBookKey), "ADJACENT")
            XCTAssertEqual(settingsStore.getString(adjacentPlaybackKey), "ADJACENT")
            XCTAssertEqual(settingsStore.getString("remote_sync.pending_mutations.ai.large.63"), largePayload)
            XCTAssertEqual(bookStore.rawBook(for: canonicalID), Optional<String?>.some("CANONICAL"))
            XCTAssertEqual(bookStore.rawBook(for: uppercaseOnlyID), Optional<String?>.none)
            XCTAssertEqual(bookStore.rawBook(for: nullID), Optional<String?>.some(nil))
            XCTAssertEqual(bookStore.rawBook(for: emptyID), Optional<String?>.none)
            XCTAssertEqual(bookStore.rawBook(for: missingID), Optional<String?>.none)
            XCTAssertEqual(
                playbackStore.playbackSettingsJSON(for: canonicalID, kind: .bible),
                canonicalPlayback
            )
            XCTAssertNil(playbackStore.playbackSettingsJSON(for: uppercaseOnlyID, kind: .bible))
            XCTAssertNil(playbackStore.playbackSettingsJSON(for: emptyID, kind: .bible))
            XCTAssertNil(playbackStore.playbackSettingsJSON(for: missingID, kind: .bible))

            let snapshot = try RemoteSyncBookmarkSnapshotService().snapshotCurrentStateThrowing(
                modelContext: reader,
                settingsStore: settingsStore
            )
            let rowsByID = Dictionary(
                uniqueKeysWithValues: snapshot.bibleBookmarkRowsByKey.values.map { ($0.id, $0) }
            )
            XCTAssertEqual(rowsByID.count, localBooks.count)
            XCTAssertEqual(rowsByID[canonicalID]?.book, "CANONICAL")
            XCTAssertEqual(rowsByID[canonicalID]?.playbackSettingsJSON, canonicalPlayback)
            XCTAssertEqual(rowsByID[uppercaseOnlyID]?.book, "LOCAL-UPPERCASE")
            XCTAssertNil(rowsByID[uppercaseOnlyID]?.playbackSettingsJSON)
            XCTAssertNil(rowsByID[nullID]?.book)
            XCTAssertNil(rowsByID[nullID]?.playbackSettingsJSON)
            XCTAssertEqual(rowsByID[emptyID]?.book, "LOCAL-EMPTY")
            XCTAssertNil(rowsByID[emptyID]?.playbackSettingsJSON)
            XCTAssertEqual(rowsByID[missingID]?.book, "LOCAL-MISSING")
            XCTAssertNil(rowsByID[missingID]?.playbackSettingsJSON)
        }
    }

    /**
     Verifies grouped projection keeps aliases, ordering, fidelity fallback, orphan omission, and
     quarantined child suppression byte-for-byte compatible with Android-shaped snapshot rows.
     */
    func testSnapshotProjectionPreservesCompleteAndroidRowsAndQuarantineSemantics() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let userLabelID = UUID(uuidString: "12000000-0000-0000-0000-000000000001")!
        let localSpeakID = UUID(uuidString: "12000000-0000-0000-0000-000000000002")!
        let tiedSpeakID = UUID(uuidString: "F2000000-0000-0000-0000-000000000002")!
        let bibleID = UUID(uuidString: "12abcdef-0000-0000-0000-000000000010")!
        let quarantinedID = UUID(uuidString: "12000000-0000-0000-0000-000000000011")!
        let genericID = UUID(uuidString: "12abcdef-0000-0000-0000-000000000020")!
        let studyPadID = UUID(uuidString: "12000000-0000-0000-0000-000000000030")!
        let biblePromptID = UUID(uuidString: "12000000-0000-0000-0000-000000000040")!
        let notePromptID = UUID(uuidString: "12000000-0000-0000-0000-000000000041")!
        let createdAt = Date(timeIntervalSince1970: 1_700_100_000)
        let updatedAt = Date(timeIntervalSince1970: 1_700_100_100)
        let trust = PersistedOrdinalTrustMetadata(
            state: .verifiedAndroid,
            mappingVersion: 1,
            provenance: .androidImport,
            sourceBookInitials: "LOCAL",
            sourceVersification: "KJV",
            sourceOrdinalStart: 7,
            sourceOrdinalEnd: 8
        )

        let userLabel = Label(id: userLabelID, name: "Prayer", color: 0x10203040)
        userLabel.favourite = true
        userLabel.type = "HIGHLIGHT"
        userLabel.customIcon = "heart"
        let speakLabel = Label(id: localSpeakID, name: Label.speakLabelName, color: 0x50607080)
        let tiedSpeakLabel = Label(
            id: tiedSpeakID,
            name: Label.speakLabelName,
            color: 0x50607081
        )
        let bible = BibleBookmark(
            id: bibleID,
            kjvOrdinalStart: 5,
            kjvOrdinalEnd: 6,
            ordinalStart: 7,
            ordinalEnd: 8,
            v11n: "KJV",
            bookInitials: "LOCAL",
            createdAt: createdAt,
            lastUpdatedOn: updatedAt,
            wholeVerse: false,
            ordinalTrustMetadata: trust
        )
        bible.startOffset = 2
        bible.endOffset = 9
        bible.primaryLabelId = localSpeakID
        bible.type = "EXAMPLE"
        bible.customIcon = "star"
        bible.sourcePromptId = biblePromptID
        bible.editAction = EditAction(mode: .append, content: "Amen")
        let bibleNote = BibleBookmarkNotes(bookmarkId: bibleID, notes: "Bible note", contentType: "MARKDOWN")
        bibleNote.sourcePromptId = notePromptID
        let bibleUserLink = BibleBookmarkToLabel(orderNumber: 8, indentLevel: 2, expandContent: false)
        let bibleSpeakLink = BibleBookmarkToLabel(orderNumber: 2, indentLevel: 1, expandContent: true)
        let orphanBibleLink = BibleBookmarkToLabel(orderNumber: 0)

        let quarantined = BibleBookmark(
            id: quarantinedID,
            kjvOrdinalStart: 90,
            kjvOrdinalEnd: 90,
            ordinalStart: 90,
            ordinalEnd: 90,
            v11n: "Unknown",
            bookInitials: "BROKEN"
        )
        let quarantinedNote = BibleBookmarkNotes(bookmarkId: quarantinedID, notes: "Keep locally")
        let quarantinedLink = BibleBookmarkToLabel(orderNumber: 1)

        let generic = GenericBookmark(
            id: genericID,
            key: "Entry.1",
            bookInitials: "MHC",
            createdAt: createdAt,
            ordinalStart: 12,
            ordinalEnd: 13,
            lastUpdatedOn: updatedAt,
            wholeVerse: true
        )
        generic.primaryLabelId = userLabelID
        let nativeGenericPlayback = PlaybackSettings(speed: 135, bookId: "NATIVE")
        generic.playbackSettings = nativeGenericPlayback
        let genericNote = GenericBookmarkNotes(bookmarkId: genericID, notes: "Generic note", contentType: "HTML")
        let genericLink = GenericBookmarkToLabel(orderNumber: 4, indentLevel: 3, expandContent: false)

        let studyPad = StudyPadTextEntry(id: studyPadID, orderNumber: 6, indentLevel: 2, contentType: "MARKDOWN")
        studyPad.sourcePromptId = biblePromptID
        let studyText = StudyPadTextEntryText(studyPadTextEntryId: studyPadID, text: "Study body")

        // Insert the lexically later equal-name alias first so the emitted winner proves the stable
        // name/UUID sort contract rather than insertion or fetch order.
        for model in [userLabel, tiedSpeakLabel, speakLabel] { modelContext.insert(model) }
        for model in [bible, quarantined] { modelContext.insert(model) }
        for model in [bibleNote, quarantinedNote] { modelContext.insert(model) }
        for model in [bibleUserLink, bibleSpeakLink, orphanBibleLink, quarantinedLink] {
            modelContext.insert(model)
        }
        modelContext.insert(generic)
        modelContext.insert(genericNote)
        modelContext.insert(genericLink)
        modelContext.insert(studyPad)
        modelContext.insert(studyText)

        bibleNote.bookmark = bible
        quarantinedNote.bookmark = quarantined
        bibleUserLink.bookmark = bible
        bibleUserLink.label = userLabel
        bibleSpeakLink.bookmark = bible
        bibleSpeakLink.label = speakLabel
        quarantinedLink.bookmark = quarantined
        quarantinedLink.label = userLabel
        genericNote.bookmark = generic
        genericLink.bookmark = generic
        genericLink.label = speakLabel
        studyPad.label = userLabel
        studyText.entry = studyPad
        try modelContext.save()

        RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore).setPlaybackSettingsJSON(
            #"{"bookId":"PRESERVED","speed":122}"#,
            for: bibleID,
            kind: .bible
        )
        RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore).setPlaybackSettingsJSON(
            #"{"bookId":"STALE","speed":99}"#,
            for: genericID,
            kind: .generic
        )
        RemoteSyncBookmarkAndroidBookStore(settingsStore: settingsStore).setRawBook(nil, for: bibleID)

        let snapshot = try RemoteSyncBookmarkSnapshotService().snapshotCurrentStateThrowing(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let labelsByID = Dictionary(uniqueKeysWithValues: snapshot.labelRowsByKey.values.map { ($0.id, $0) })
        XCTAssertEqual(labelsByID, [
            userLabelID: RemoteSyncAndroidLabel(
                id: userLabelID,
                name: "Prayer",
                color: 0x10203040,
                markerStyle: false,
                markerStyleWholeVerse: false,
                underlineStyle: false,
                underlineStyleWholeVerse: true,
                hideStyle: false,
                hideStyleWholeVerse: false,
                favourite: true,
                type: "HIGHLIGHT",
                customIcon: "heart"
            ),
            Label.speakLabelId: RemoteSyncAndroidLabel(
                id: Label.speakLabelId,
                name: Label.speakLabelName,
                color: 0x50607081,
                markerStyle: false,
                markerStyleWholeVerse: false,
                underlineStyle: false,
                underlineStyleWholeVerse: true,
                hideStyle: false,
                hideStyleWholeVerse: false,
                favourite: false,
                type: nil,
                customIcon: nil
            ),
        ])

        let bibleRow = try XCTUnwrap(snapshot.bibleBookmarkRowsByKey.values.first)
        XCTAssertEqual(
            bibleRow,
            RemoteSyncAndroidBibleBookmark(
                id: bibleID,
                kjvOrdinalStart: 5,
                kjvOrdinalEnd: 6,
                ordinalStart: 7,
                ordinalEnd: 8,
                v11n: "KJV",
                playbackSettingsJSON: #"{"bookId":"PRESERVED","speed":122}"#,
                createdAt: createdAt,
                book: nil,
                startOffset: 2,
                endOffset: 9,
                primaryLabelID: Label.speakLabelId,
                notes: "Bible note",
                notesContentType: "MARKDOWN",
                lastUpdatedOn: updatedAt,
                wholeVerse: false,
                type: "EXAMPLE",
                customIcon: "star",
                sourcePromptId: biblePromptID,
                notesSourcePromptId: notePromptID,
                editAction: EditAction(mode: .append, content: "Amen"),
                labelLinks: [
                    .init(labelID: Label.speakLabelId, orderNumber: 2, indentLevel: 1, expandContent: true),
                    .init(labelID: userLabelID, orderNumber: 8, indentLevel: 2, expandContent: false),
                ],
                ordinalTrustMetadata: trust
            )
        )

        let genericRow = try XCTUnwrap(snapshot.genericBookmarkRowsByKey.values.first)
        XCTAssertEqual(
            genericRow,
            RemoteSyncAndroidGenericBookmark(
                id: genericID,
                key: "Entry.1",
                createdAt: createdAt,
                bookInitials: "MHC",
                ordinalStart: 12,
                ordinalEnd: 13,
                startOffset: nil,
                endOffset: nil,
                primaryLabelID: userLabelID,
                notes: "Generic note",
                notesContentType: "HTML",
                lastUpdatedOn: updatedAt,
                wholeVerse: true,
                playbackSettingsJSON: try nativeGenericPlayback.androidJSON(),
                customIcon: nil,
                editAction: nil,
                labelLinks: [
                    .init(
                        labelID: Label.speakLabelId,
                        orderNumber: 4,
                        indentLevel: 3,
                        expandContent: false
                    ),
                ]
            )
        )

        XCTAssertEqual(
            snapshot.studyPadEntryRowsByKey.values.first,
            RemoteSyncAndroidStudyPadEntry(
                id: studyPadID,
                labelID: userLabelID,
                orderNumber: 6,
                indentLevel: 2,
                contentType: "MARKDOWN",
                sourcePromptId: biblePromptID,
                text: "Study body"
            )
        )
        XCTAssertEqual(
            snapshot.studyPadTextRowsByKey.values.first,
            RemoteSyncCurrentStudyPadTextRow(entryID: studyPadID, text: "Study body")
        )

        let logStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let suppressedBookmarkKey = logStore.key(
            for: .bookmarks,
            tableName: "BibleBookmark",
            entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(quarantinedID)),
            entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
        )
        let suppressedNoteKey = logStore.key(
            for: .bookmarks,
            tableName: "BibleBookmarkNotes",
            entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(quarantinedID)),
            entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
        )
        let suppressedLinkKey = logStore.key(
            for: .bookmarks,
            tableName: "BibleBookmarkToLabel",
            entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(quarantinedID)),
            entityID2: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(userLabelID))
        )
        XCTAssertEqual(snapshot.suppressedKeys, Set([
            suppressedBookmarkKey,
            suppressedNoteKey,
            suppressedLinkKey,
        ]))
        XCTAssertEqual(snapshot.bibleBookmarkRowsByKey.count, 1)
        XCTAssertEqual(snapshot.bibleLinkRowsByKey.count, 2)
        XCTAssertEqual(snapshot.genericLinkRowsByKey.count, 1)
        XCTAssertEqual(snapshot.fingerprintsByKey.count, 11)
    }
}
