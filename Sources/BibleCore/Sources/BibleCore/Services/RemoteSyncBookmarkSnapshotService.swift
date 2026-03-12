// RemoteSyncBookmarkSnapshotService.swift — Android-shaped local bookmark snapshots for outbound sync

import CryptoKit
import Foundation
import SwiftData

/**
 Current local representation of one Android bookmark-note row.
 */
public struct RemoteSyncCurrentBookmarkNoteRow: Sendable, Equatable, Codable {
    /// Android bookmark identifier that owns the detached note row.
    public let bookmarkID: UUID

    /// Raw detached note payload stored in the Android note table.
    public let notes: String

    /**
     Creates one Android-shaped current bookmark-note row.

     - Parameters:
       - bookmarkID: Android bookmark identifier that owns the detached note row.
       - notes: Raw detached note payload stored in the Android note table.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(bookmarkID: UUID, notes: String) {
        self.bookmarkID = bookmarkID
        self.notes = notes
    }
}

/**
 Current local representation of one Android bookmark-to-label junction row.
 */
public struct RemoteSyncCurrentBookmarkLabelLinkRow: Sendable, Equatable, Codable {
    /// Android bookmark identifier that owns the link row.
    public let bookmarkID: UUID

    /// Android label identifier referenced by the link row.
    public let labelID: UUID

    /// Android display order used by label-backed lists.
    public let orderNumber: Int

    /// Android nesting depth used by StudyPad-like rendering.
    public let indentLevel: Int

    /// Android expand/collapse state for the linked content.
    public let expandContent: Bool

    /**
     Creates one Android-shaped current bookmark-to-label junction row.

     - Parameters:
       - bookmarkID: Android bookmark identifier that owns the link row.
       - labelID: Android label identifier referenced by the link row.
       - orderNumber: Android display order used by label-backed lists.
       - indentLevel: Android nesting depth used by StudyPad-like rendering.
       - expandContent: Android expand/collapse state for the linked content.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        bookmarkID: UUID,
        labelID: UUID,
        orderNumber: Int,
        indentLevel: Int,
        expandContent: Bool
    ) {
        self.bookmarkID = bookmarkID
        self.labelID = labelID
        self.orderNumber = orderNumber
        self.indentLevel = indentLevel
        self.expandContent = expandContent
    }
}

/**
 Current local representation of one Android `StudyPadTextEntryText` row.
 */
public struct RemoteSyncCurrentStudyPadTextRow: Sendable, Equatable, Codable {
    /// Android StudyPad-entry identifier that owns the detached text row.
    public let entryID: UUID

    /// Raw detached StudyPad text payload.
    public let text: String

    /**
     Creates one Android-shaped current StudyPad text row.

     - Parameters:
       - entryID: Android StudyPad-entry identifier that owns the detached text row.
       - text: Raw detached StudyPad text payload.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(entryID: UUID, text: String) {
        self.entryID = entryID
        self.text = text
    }
}

/**
 Snapshot of the current local bookmark state expressed in Android row form.

 The snapshot carries per-table row maps keyed by Android's `(tableName, entityId1, entityId2)`
 composite identifier together with precomputed row fingerprints. Outbound patch creation can then
 diff local state without reprojecting SwiftData repeatedly.
 */
public struct RemoteSyncBookmarkCurrentSnapshot: Sendable, Equatable {
    /// Android-shaped current `Label` rows keyed by Android composite key.
    public let labelRowsByKey: [String: RemoteSyncAndroidLabel]

    /// Android-shaped current `BibleBookmark` rows keyed by Android composite key.
    public let bibleBookmarkRowsByKey: [String: RemoteSyncAndroidBibleBookmark]

    /// Android-shaped current `BibleBookmarkNotes` rows keyed by Android composite key.
    public let bibleNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow]

    /// Android-shaped current `BibleBookmarkToLabel` rows keyed by Android composite key.
    public let bibleLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow]

    /// Android-shaped current `GenericBookmark` rows keyed by Android composite key.
    public let genericBookmarkRowsByKey: [String: RemoteSyncAndroidGenericBookmark]

    /// Android-shaped current `GenericBookmarkNotes` rows keyed by Android composite key.
    public let genericNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow]

    /// Android-shaped current `GenericBookmarkToLabel` rows keyed by Android composite key.
    public let genericLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow]

    /// Android-shaped current `StudyPadTextEntry` rows keyed by Android composite key.
    public let studyPadEntryRowsByKey: [String: RemoteSyncAndroidStudyPadEntry]

    /// Android-shaped current `StudyPadTextEntryText` rows keyed by Android composite key.
    public let studyPadTextRowsByKey: [String: RemoteSyncCurrentStudyPadTextRow]

    /// Stable content fingerprints for every current row keyed by Android composite key.
    public let fingerprintsByKey: [String: String]

    /**
     Creates one current-state bookmark snapshot.

     - Parameters:
       - labelRowsByKey: Android-shaped current `Label` rows keyed by Android composite key.
       - bibleBookmarkRowsByKey: Android-shaped current `BibleBookmark` rows keyed by Android composite key.
       - bibleNoteRowsByKey: Android-shaped current `BibleBookmarkNotes` rows keyed by Android composite key.
       - bibleLinkRowsByKey: Android-shaped current `BibleBookmarkToLabel` rows keyed by Android composite key.
       - genericBookmarkRowsByKey: Android-shaped current `GenericBookmark` rows keyed by Android composite key.
       - genericNoteRowsByKey: Android-shaped current `GenericBookmarkNotes` rows keyed by Android composite key.
       - genericLinkRowsByKey: Android-shaped current `GenericBookmarkToLabel` rows keyed by Android composite key.
       - studyPadEntryRowsByKey: Android-shaped current `StudyPadTextEntry` rows keyed by Android composite key.
       - studyPadTextRowsByKey: Android-shaped current `StudyPadTextEntryText` rows keyed by Android composite key.
       - fingerprintsByKey: Stable content fingerprints for every current row keyed by Android composite key.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        labelRowsByKey: [String: RemoteSyncAndroidLabel],
        bibleBookmarkRowsByKey: [String: RemoteSyncAndroidBibleBookmark],
        bibleNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow],
        bibleLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow],
        genericBookmarkRowsByKey: [String: RemoteSyncAndroidGenericBookmark],
        genericNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow],
        genericLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow],
        studyPadEntryRowsByKey: [String: RemoteSyncAndroidStudyPadEntry],
        studyPadTextRowsByKey: [String: RemoteSyncCurrentStudyPadTextRow],
        fingerprintsByKey: [String: String]
    ) {
        self.labelRowsByKey = labelRowsByKey
        self.bibleBookmarkRowsByKey = bibleBookmarkRowsByKey
        self.bibleNoteRowsByKey = bibleNoteRowsByKey
        self.bibleLinkRowsByKey = bibleLinkRowsByKey
        self.genericBookmarkRowsByKey = genericBookmarkRowsByKey
        self.genericNoteRowsByKey = genericNoteRowsByKey
        self.genericLinkRowsByKey = genericLinkRowsByKey
        self.studyPadEntryRowsByKey = studyPadEntryRowsByKey
        self.studyPadTextRowsByKey = studyPadTextRowsByKey
        self.fingerprintsByKey = fingerprintsByKey
    }
}

/**
 Projects current local bookmark state into Android-shaped rows and row fingerprints.

 Outbound bookmark sync needs the inverse of restore and patch replay:
 - convert local labels, Bible bookmarks, generic bookmarks, notes, links, and StudyPad rows back
   into Android table rows
 - preserve reserved system-label aliases so local canonical UUIDs remain comparable with Android
   `LogEntry` identifiers
 - preserve raw Android `playbackSettings` JSON when available and synthesize the current iOS subset
   when no raw payload has been stored yet
 - compute stable row fingerprints keyed by Android's composite identifier so later patch creation
   can detect inserts, updates, and deletes without hidden SQLite triggers

 Data dependencies:
 - `ModelContext` provides live bookmark-category SwiftData rows
 - `RemoteSyncBookmarkPlaybackSettingsStore` provides preserved raw Android playback JSON
 - `RemoteSyncBookmarkLabelAliasStore` provides remote-to-local reserved system-label remaps
 - `RemoteSyncLogEntryStore` provides canonical Android composite-key encoding
 - `RemoteSyncRowFingerprintStore` persists baseline fingerprints after restore, replay, or upload

 Side effects:
 - `snapshotCurrentState` reads bookmark-category SwiftData rows and local-only fidelity settings
 - `refreshBaselineFingerprints` rewrites local fingerprint rows for the bookmark category

 Failure modes:
 - fetch failures from `ModelContext` are swallowed and treated as an empty local bookmark set to
   stay aligned with the repo's existing settings-store behavior

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement rules of the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncBookmarkSnapshotService {
    /**
     Creates a bookmark snapshot service.

     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init() {}

    /**
     Projects the current local bookmark state into Android-shaped rows and row fingerprints.

     - Parameters:
       - modelContext: SwiftData context that owns the current bookmark graph.
       - settingsStore: Local-only settings store that holds preserved Android fidelity payloads.
     - Returns: Android-shaped current rows and their stable fingerprints keyed by Android composite key.
     - Side effects:
       - reads current bookmark-category SwiftData rows from `modelContext`
       - reads preserved Android playback JSON and label-alias rows from `SettingsStore`
     - Failure modes:
       - fetch failures from `ModelContext` are swallowed and treated as an empty snapshot
     */
    public func snapshotCurrentState(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) -> RemoteSyncBookmarkCurrentSnapshot {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let labelAliasStore = RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore)
        let playbackSettingsStore = RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore)
        let reverseAliases = Dictionary(
            uniqueKeysWithValues: labelAliasStore.allAliases().map { ($0.localLabelID, $0.remoteLabelID) }
        )

        let labels = ((try? modelContext.fetch(FetchDescriptor<Label>())) ?? [])
            .sorted(by: sortLabels)
        let bibleBookmarks = ((try? modelContext.fetch(FetchDescriptor<BibleBookmark>())) ?? [])
            .sorted(by: sortBibleBookmarks)
        let bibleNotes = ((try? modelContext.fetch(FetchDescriptor<BibleBookmarkNotes>())) ?? [])
        let bibleLinks = ((try? modelContext.fetch(FetchDescriptor<BibleBookmarkToLabel>())) ?? [])
        let genericBookmarks = ((try? modelContext.fetch(FetchDescriptor<GenericBookmark>())) ?? [])
            .sorted(by: sortGenericBookmarks)
        let genericNotes = ((try? modelContext.fetch(FetchDescriptor<GenericBookmarkNotes>())) ?? [])
        let genericLinks = ((try? modelContext.fetch(FetchDescriptor<GenericBookmarkToLabel>())) ?? [])
        let studyPadEntries = ((try? modelContext.fetch(FetchDescriptor<StudyPadTextEntry>())) ?? [])
            .sorted(by: sortStudyPadEntries)
        let studyPadTexts = ((try? modelContext.fetch(FetchDescriptor<StudyPadTextEntryText>())) ?? [])

        let bibleNotesByBookmarkID = Dictionary(uniqueKeysWithValues: bibleNotes.map { ($0.bookmarkId, $0.notes) })
        let genericNotesByBookmarkID = Dictionary(uniqueKeysWithValues: genericNotes.map { ($0.bookmarkId, $0.notes) })
        let studyPadTextsByEntryID = Dictionary(uniqueKeysWithValues: studyPadTexts.map { ($0.studyPadTextEntryId, $0.text) })

        var labelRowsByKey: [String: RemoteSyncAndroidLabel] = [:]
        var bibleBookmarkRowsByKey: [String: RemoteSyncAndroidBibleBookmark] = [:]
        var bibleNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow] = [:]
        var bibleLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow] = [:]
        var genericBookmarkRowsByKey: [String: RemoteSyncAndroidGenericBookmark] = [:]
        var genericNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow] = [:]
        var genericLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow] = [:]
        var studyPadEntryRowsByKey: [String: RemoteSyncAndroidStudyPadEntry] = [:]
        var studyPadTextRowsByKey: [String: RemoteSyncCurrentStudyPadTextRow] = [:]
        var fingerprintsByKey: [String: String] = [:]

        for label in labels {
            let remoteID = reverseAliases[label.id] ?? label.id
            let row = RemoteSyncAndroidLabel(
                id: remoteID,
                name: label.name,
                color: label.color,
                markerStyle: label.markerStyle,
                markerStyleWholeVerse: label.markerStyleWholeVerse,
                underlineStyle: label.underlineStyle,
                underlineStyleWholeVerse: label.underlineStyleWholeVerse,
                hideStyle: label.hideStyle,
                hideStyleWholeVerse: label.hideStyleWholeVerse,
                favourite: label.favourite,
                type: label.type,
                customIcon: label.customIcon
            )
            let key = logEntryStore.key(
                for: .bookmarks,
                tableName: "Label",
                entityID1: .blob(Self.uuidBlob(remoteID)),
                entityID2: .null()
            )
            labelRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)
        }

        for bookmark in bibleBookmarks {
            let playbackJSON = playbackSettingsStore.playbackSettingsJSON(for: bookmark.id, kind: .bible)
                ?? Self.synthesizedPlaybackSettingsJSON(from: bookmark.playbackSettings)
            let primaryLabelID = bookmark.primaryLabelId.map { reverseAliases[$0] ?? $0 }
            let labelLinks = bibleLinks.compactMap { link -> RemoteSyncAndroidBookmarkLabelLink? in
                guard link.bookmark?.id == bookmark.id,
                      let localLabelID = link.label?.id else {
                    return nil
                }
                let remoteLabelID = reverseAliases[localLabelID] ?? localLabelID
                return RemoteSyncAndroidBookmarkLabelLink(
                    labelID: remoteLabelID,
                    orderNumber: link.orderNumber,
                    indentLevel: link.indentLevel,
                    expandContent: link.expandContent
                )
            }.sorted(by: sortLabelLinks)

            let row = RemoteSyncAndroidBibleBookmark(
                id: bookmark.id,
                kjvOrdinalStart: bookmark.kjvOrdinalStart,
                kjvOrdinalEnd: bookmark.kjvOrdinalEnd,
                ordinalStart: bookmark.ordinalStart,
                ordinalEnd: bookmark.ordinalEnd,
                v11n: bookmark.v11n,
                playbackSettingsJSON: playbackJSON,
                createdAt: bookmark.createdAt,
                book: bookmark.book,
                startOffset: bookmark.startOffset,
                endOffset: bookmark.endOffset,
                primaryLabelID: primaryLabelID,
                notes: bibleNotesByBookmarkID[bookmark.id],
                lastUpdatedOn: bookmark.lastUpdatedOn,
                wholeVerse: bookmark.wholeVerse,
                type: bookmark.type,
                customIcon: bookmark.customIcon,
                editAction: bookmark.editAction,
                labelLinks: labelLinks
            )
            let key = logEntryStore.key(
                for: .bookmarks,
                tableName: "BibleBookmark",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .null()
            )
            bibleBookmarkRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)

            if let notes = row.notes {
                let noteRow = RemoteSyncCurrentBookmarkNoteRow(bookmarkID: row.id, notes: notes)
                let noteKey = logEntryStore.key(
                    for: .bookmarks,
                    tableName: "BibleBookmarkNotes",
                    entityID1: .blob(Self.uuidBlob(row.id)),
                    entityID2: .null()
                )
                bibleNoteRowsByKey[noteKey] = noteRow
                fingerprintsByKey[noteKey] = Self.fingerprintHex(for: noteRow)
            }

            for link in row.labelLinks {
                let linkRow = RemoteSyncCurrentBookmarkLabelLinkRow(
                    bookmarkID: row.id,
                    labelID: link.labelID,
                    orderNumber: link.orderNumber,
                    indentLevel: link.indentLevel,
                    expandContent: link.expandContent
                )
                let linkKey = logEntryStore.key(
                    for: .bookmarks,
                    tableName: "BibleBookmarkToLabel",
                    entityID1: .blob(Self.uuidBlob(row.id)),
                    entityID2: .blob(Self.uuidBlob(link.labelID))
                )
                bibleLinkRowsByKey[linkKey] = linkRow
                fingerprintsByKey[linkKey] = Self.fingerprintHex(for: linkRow)
            }
        }

        for bookmark in genericBookmarks {
            let playbackJSON = playbackSettingsStore.playbackSettingsJSON(for: bookmark.id, kind: .generic)
                ?? Self.synthesizedPlaybackSettingsJSON(from: bookmark.playbackSettings)
            let primaryLabelID = bookmark.primaryLabelId.map { reverseAliases[$0] ?? $0 }
            let labelLinks = genericLinks.compactMap { link -> RemoteSyncAndroidBookmarkLabelLink? in
                guard link.bookmark?.id == bookmark.id,
                      let localLabelID = link.label?.id else {
                    return nil
                }
                let remoteLabelID = reverseAliases[localLabelID] ?? localLabelID
                return RemoteSyncAndroidBookmarkLabelLink(
                    labelID: remoteLabelID,
                    orderNumber: link.orderNumber,
                    indentLevel: link.indentLevel,
                    expandContent: link.expandContent
                )
            }.sorted(by: sortLabelLinks)

            let row = RemoteSyncAndroidGenericBookmark(
                id: bookmark.id,
                key: bookmark.key,
                createdAt: bookmark.createdAt,
                bookInitials: bookmark.bookInitials,
                ordinalStart: bookmark.ordinalStart,
                ordinalEnd: bookmark.ordinalEnd,
                startOffset: bookmark.startOffset,
                endOffset: bookmark.endOffset,
                primaryLabelID: primaryLabelID,
                notes: genericNotesByBookmarkID[bookmark.id],
                lastUpdatedOn: bookmark.lastUpdatedOn,
                wholeVerse: bookmark.wholeVerse,
                playbackSettingsJSON: playbackJSON,
                customIcon: bookmark.customIcon,
                editAction: bookmark.editAction,
                labelLinks: labelLinks
            )
            let key = logEntryStore.key(
                for: .bookmarks,
                tableName: "GenericBookmark",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .null()
            )
            genericBookmarkRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)

            if let notes = row.notes {
                let noteRow = RemoteSyncCurrentBookmarkNoteRow(bookmarkID: row.id, notes: notes)
                let noteKey = logEntryStore.key(
                    for: .bookmarks,
                    tableName: "GenericBookmarkNotes",
                    entityID1: .blob(Self.uuidBlob(row.id)),
                    entityID2: .null()
                )
                genericNoteRowsByKey[noteKey] = noteRow
                fingerprintsByKey[noteKey] = Self.fingerprintHex(for: noteRow)
            }

            for link in row.labelLinks {
                let linkRow = RemoteSyncCurrentBookmarkLabelLinkRow(
                    bookmarkID: row.id,
                    labelID: link.labelID,
                    orderNumber: link.orderNumber,
                    indentLevel: link.indentLevel,
                    expandContent: link.expandContent
                )
                let linkKey = logEntryStore.key(
                    for: .bookmarks,
                    tableName: "GenericBookmarkToLabel",
                    entityID1: .blob(Self.uuidBlob(row.id)),
                    entityID2: .blob(Self.uuidBlob(link.labelID))
                )
                genericLinkRowsByKey[linkKey] = linkRow
                fingerprintsByKey[linkKey] = Self.fingerprintHex(for: linkRow)
            }
        }

        for entry in studyPadEntries {
            guard let localLabelID = entry.label?.id else {
                continue
            }
            let remoteLabelID = reverseAliases[localLabelID] ?? localLabelID
            let row = RemoteSyncAndroidStudyPadEntry(
                id: entry.id,
                labelID: remoteLabelID,
                orderNumber: entry.orderNumber,
                indentLevel: entry.indentLevel,
                text: studyPadTextsByEntryID[entry.id] ?? ""
            )
            let key = logEntryStore.key(
                for: .bookmarks,
                tableName: "StudyPadTextEntry",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .null()
            )
            studyPadEntryRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)
        }

        for textRow in studyPadTexts {
            let row = RemoteSyncCurrentStudyPadTextRow(entryID: textRow.studyPadTextEntryId, text: textRow.text)
            let key = logEntryStore.key(
                for: .bookmarks,
                tableName: "StudyPadTextEntryText",
                entityID1: .blob(Self.uuidBlob(row.entryID)),
                entityID2: .null()
            )
            studyPadTextRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)
        }

        return RemoteSyncBookmarkCurrentSnapshot(
            labelRowsByKey: labelRowsByKey,
            bibleBookmarkRowsByKey: bibleBookmarkRowsByKey,
            bibleNoteRowsByKey: bibleNoteRowsByKey,
            bibleLinkRowsByKey: bibleLinkRowsByKey,
            genericBookmarkRowsByKey: genericBookmarkRowsByKey,
            genericNoteRowsByKey: genericNoteRowsByKey,
            genericLinkRowsByKey: genericLinkRowsByKey,
            studyPadEntryRowsByKey: studyPadEntryRowsByKey,
            studyPadTextRowsByKey: studyPadTextRowsByKey,
            fingerprintsByKey: fingerprintsByKey
        )
    }

    /**
     Replaces the stored fingerprint baseline for bookmark rows with the current local snapshot.

     This method is intended to run after remote initial-backup restores or remote patch replay so
     later outbound patch creation compares local edits against the newly accepted remote baseline
     instead of stale pre-restore content hashes.

     - Parameters:
       - modelContext: SwiftData context that owns the current bookmark graph.
       - settingsStore: Local-only settings store used by the fingerprint store.
     - Side effects:
       - rewrites fingerprint rows for current bookmark-category entries
       - removes stale fingerprint rows whose Android keys are no longer present locally
     - Failure modes:
       - fetch failures while reading the current bookmark graph are swallowed and treated as an empty snapshot
     */
    public func refreshBaselineFingerprints(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) {
        let snapshot = snapshotCurrentState(modelContext: modelContext, settingsStore: settingsStore)
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)

        for entry in logEntryStore.entries(for: .bookmarks) {
            let key = logEntryStore.key(for: .bookmarks, entry: entry)
            if snapshot.fingerprintsByKey[key] == nil {
                fingerprintStore.removeFingerprint(
                    for: .bookmarks,
                    tableName: entry.tableName,
                    entityID1: entry.entityID1,
                    entityID2: entry.entityID2
                )
            }
        }

        for (key, row) in snapshot.labelRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .bookmarks,
                tableName: "Label",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .null()
            )
        }

        for (key, row) in snapshot.bibleBookmarkRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .bookmarks,
                tableName: "BibleBookmark",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .null()
            )
        }

        for (key, row) in snapshot.bibleNoteRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .bookmarks,
                tableName: "BibleBookmarkNotes",
                entityID1: .blob(Self.uuidBlob(row.bookmarkID)),
                entityID2: .null()
            )
        }

        for (key, row) in snapshot.bibleLinkRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .bookmarks,
                tableName: "BibleBookmarkToLabel",
                entityID1: .blob(Self.uuidBlob(row.bookmarkID)),
                entityID2: .blob(Self.uuidBlob(row.labelID))
            )
        }

        for (key, row) in snapshot.genericBookmarkRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .bookmarks,
                tableName: "GenericBookmark",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .null()
            )
        }

        for (key, row) in snapshot.genericNoteRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .bookmarks,
                tableName: "GenericBookmarkNotes",
                entityID1: .blob(Self.uuidBlob(row.bookmarkID)),
                entityID2: .null()
            )
        }

        for (key, row) in snapshot.genericLinkRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .bookmarks,
                tableName: "GenericBookmarkToLabel",
                entityID1: .blob(Self.uuidBlob(row.bookmarkID)),
                entityID2: .blob(Self.uuidBlob(row.labelID))
            )
        }

        for (key, row) in snapshot.studyPadEntryRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .bookmarks,
                tableName: "StudyPadTextEntry",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .null()
            )
        }

        for (key, row) in snapshot.studyPadTextRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .bookmarks,
                tableName: "StudyPadTextEntryText",
                entityID1: .blob(Self.uuidBlob(row.entryID)),
                entityID2: .null()
            )
        }
    }

    /**
     Converts one UUID into Android's raw 16-byte blob representation.

     - Parameter uuid: UUID to serialize.
     - Returns: Raw 16-byte UUID payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public static func uuidBlob(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one `Label` row.

     - Parameter value: Android-shaped current `Label` row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncAndroidLabel) -> String {
        fingerprintHex(
            canonicalValue: [
                value.id.uuidString.lowercased(),
                value.name,
                String(value.color),
                canonicalBool(value.markerStyle),
                canonicalBool(value.markerStyleWholeVerse),
                canonicalBool(value.underlineStyle),
                canonicalBool(value.underlineStyleWholeVerse),
                canonicalBool(value.hideStyle),
                canonicalBool(value.hideStyleWholeVerse),
                canonicalBool(value.favourite),
                value.type ?? "",
                value.customIcon ?? "",
            ].joined(separator: "|")
        )
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one `BibleBookmark` row.

     - Parameter value: Android-shaped current `BibleBookmark` row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncAndroidBibleBookmark) -> String {
        let createdAtMillis = String(Int64(value.createdAt.timeIntervalSince1970 * 1000.0))
        let lastUpdatedMillis = String(Int64(value.lastUpdatedOn.timeIntervalSince1970 * 1000.0))
        let primaryLabelID = value.primaryLabelID?.uuidString.lowercased() ?? ""
        let editMode = value.editAction?.mode?.rawValue ?? ""
        let editContent = value.editAction?.content ?? ""
        let components = [
            value.id.uuidString.lowercased(),
            String(value.kjvOrdinalStart),
            String(value.kjvOrdinalEnd),
            String(value.ordinalStart),
            String(value.ordinalEnd),
            value.v11n,
            value.playbackSettingsJSON ?? "",
            createdAtMillis,
            value.book ?? "",
            canonicalOptionalInt(value.startOffset),
            canonicalOptionalInt(value.endOffset),
            primaryLabelID,
            lastUpdatedMillis,
            canonicalBool(value.wholeVerse),
            value.type ?? "",
            value.customIcon ?? "",
            editMode,
            editContent,
        ]
        return fingerprintHex(canonicalValue: components.joined(separator: "|"))
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one bookmark-note row.

     - Parameter value: Android-shaped current bookmark-note row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncCurrentBookmarkNoteRow) -> String {
        fingerprintHex(
            canonicalValue: [
                value.bookmarkID.uuidString.lowercased(),
                value.notes,
            ].joined(separator: "|")
        )
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one bookmark-to-label row.

     - Parameter value: Android-shaped current bookmark-to-label row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncCurrentBookmarkLabelLinkRow) -> String {
        fingerprintHex(
            canonicalValue: [
                value.bookmarkID.uuidString.lowercased(),
                value.labelID.uuidString.lowercased(),
                String(value.orderNumber),
                String(value.indentLevel),
                canonicalBool(value.expandContent),
            ].joined(separator: "|")
        )
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one `GenericBookmark` row.

     - Parameter value: Android-shaped current `GenericBookmark` row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncAndroidGenericBookmark) -> String {
        let createdAtMillis = String(Int64(value.createdAt.timeIntervalSince1970 * 1000.0))
        let lastUpdatedMillis = String(Int64(value.lastUpdatedOn.timeIntervalSince1970 * 1000.0))
        let primaryLabelID = value.primaryLabelID?.uuidString.lowercased() ?? ""
        let editMode = value.editAction?.mode?.rawValue ?? ""
        let editContent = value.editAction?.content ?? ""
        let components = [
            value.id.uuidString.lowercased(),
            value.key,
            createdAtMillis,
            value.bookInitials,
            String(value.ordinalStart),
            String(value.ordinalEnd),
            canonicalOptionalInt(value.startOffset),
            canonicalOptionalInt(value.endOffset),
            primaryLabelID,
            lastUpdatedMillis,
            canonicalBool(value.wholeVerse),
            value.playbackSettingsJSON ?? "",
            value.customIcon ?? "",
            editMode,
            editContent,
        ]
        return fingerprintHex(canonicalValue: components.joined(separator: "|"))
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one `StudyPadTextEntry` row.

     - Parameter value: Android-shaped current `StudyPadTextEntry` row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncAndroidStudyPadEntry) -> String {
        fingerprintHex(
            canonicalValue: [
                value.id.uuidString.lowercased(),
                value.labelID.uuidString.lowercased(),
                String(value.orderNumber),
                String(value.indentLevel),
            ].joined(separator: "|")
        )
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one `StudyPadTextEntryText` row.

     - Parameter value: Android-shaped current `StudyPadTextEntryText` row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncCurrentStudyPadTextRow) -> String {
        fingerprintHex(
            canonicalValue: [
                value.entryID.uuidString.lowercased(),
                value.text,
            ].joined(separator: "|")
        )
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one canonical row string.

     - Parameter canonicalValue: Canonical text representation of one Android row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the supplied string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func fingerprintHex(canonicalValue: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /**
     Recreates a minimal Android playback-settings JSON payload from the subset currently modeled on iOS.

     - Parameter playbackSettings: Current iOS bookmark playback settings.
     - Returns: Raw JSON payload containing `bookId`, or `nil` when the current bookmark has no playback metadata.
     - Side effects: none.
     - Failure modes:
       - encoding failures return `nil`
     */
    private static func synthesizedPlaybackSettingsJSON(from playbackSettings: PlaybackSettings?) -> String? {
        guard let bookID = playbackSettings?.bookId, !bookID.isEmpty else {
            return nil
        }

        struct PlaybackProjection: Encodable {
            let bookId: String
        }

        guard let data = try? JSONEncoder().encode(PlaybackProjection(bookId: bookID)),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /**
     Sorts labels deterministically for stable snapshot projection.

     - Parameters:
       - lhs: First local label to compare.
       - rhs: Second local label to compare.
     - Returns: `true` when `lhs` should sort before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func sortLabels(_ lhs: Label, _ rhs: Label) -> Bool {
        if lhs.name == rhs.name {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.name < rhs.name
    }

    /**
     Sorts Bible bookmarks deterministically for stable snapshot projection.

     - Parameters:
       - lhs: First local Bible bookmark to compare.
       - rhs: Second local Bible bookmark to compare.
     - Returns: `true` when `lhs` should sort before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func sortBibleBookmarks(_ lhs: BibleBookmark, _ rhs: BibleBookmark) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt < rhs.createdAt
    }

    /**
     Sorts generic bookmarks deterministically for stable snapshot projection.

     - Parameters:
       - lhs: First local generic bookmark to compare.
       - rhs: Second local generic bookmark to compare.
     - Returns: `true` when `lhs` should sort before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func sortGenericBookmarks(_ lhs: GenericBookmark, _ rhs: GenericBookmark) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt < rhs.createdAt
    }

    /**
     Sorts StudyPad entries deterministically for stable snapshot projection.

     - Parameters:
       - lhs: First local StudyPad entry to compare.
       - rhs: Second local StudyPad entry to compare.
     - Returns: `true` when `lhs` should sort before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func sortStudyPadEntries(_ lhs: StudyPadTextEntry, _ rhs: StudyPadTextEntry) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    /**
     Sorts bookmark-to-label links deterministically for stable snapshot projection.

     - Parameters:
       - lhs: First Android bookmark-to-label link to compare.
       - rhs: Second Android bookmark-to-label link to compare.
     - Returns: `true` when `lhs` should sort before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func sortLabelLinks(_ lhs: RemoteSyncAndroidBookmarkLabelLink, _ rhs: RemoteSyncAndroidBookmarkLabelLink) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            return lhs.labelID.uuidString < rhs.labelID.uuidString
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    /**
     Returns the canonical text form for one optional integer field.

     - Parameter value: Optional integer value.
     - Returns: Decimal text when present; otherwise an empty string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func canonicalOptionalInt(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    /**
     Returns the canonical text form for one Boolean field.

     - Parameter value: Boolean value to encode.
     - Returns: `1` for `true` and `0` for `false`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func canonicalBool(_ value: Bool) -> String {
        value ? "1" : "0"
    }
}
