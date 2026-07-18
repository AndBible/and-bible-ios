// RemoteSyncBookmarkRestoreService.swift — Bookmark-category initial-backup restore from Android sync databases

import Foundation
import SQLite3
import SwiftData

private let remoteSyncSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while reading or restoring Android bookmark sync databases.
 */
public enum RemoteSyncBookmarkRestoreError: Error, Equatable {
    /// The staged file could not be opened as a readable SQLite database.
    case invalidSQLiteDatabase

    /// The staged database does not contain one of the required Android bookmark tables.
    case missingTable(String)

    /// One Android UUID-like blob could not be converted into an iOS `UUID`.
    case invalidIdentifierBlob(table: String, column: String)

    /// One staged scalar value is not valid for Android's declared column type.
    case invalidColumnValue(table: String, column: String)

    /// One or more staged rows referenced missing parent records or required companion rows.
    case orphanReferences([String])

    /// The staged database contained multiple rows for the same reserved system-label name.
    case duplicateSystemLabels([String])
}

/**
 One Android bookmark-to-label junction row from a staged sync backup.
 */
public struct RemoteSyncAndroidBookmarkLabelLink: Sendable, Equatable {
    /// Android label identifier referenced by the bookmark row.
    public let labelID: UUID

    /// Display order used by label-focused lists and StudyPad views.
    public let orderNumber: Int

    /// Nesting depth used by label/StudyPad outline rendering.
    public let indentLevel: Int

    /// Whether child content was expanded in Android's StudyPad-like views.
    public let expandContent: Bool

    /**
     Creates one staged Android bookmark-to-label junction row.

     - Parameters:
       - labelID: Android label identifier referenced by the bookmark row.
       - orderNumber: Display order used by label-focused lists and StudyPad views.
       - indentLevel: Nesting depth used by label/StudyPad outline rendering.
       - expandContent: Whether child content was expanded in Android's StudyPad-like views.
     - Side effects: none.
     - Failure modes: This initializer cannot fail; staged SQLite readers validate non-null values
       before constructing these value types.
     */
    public init(labelID: UUID, orderNumber: Int, indentLevel: Int, expandContent: Bool) {
        self.labelID = labelID
        self.orderNumber = orderNumber
        self.indentLevel = indentLevel
        self.expandContent = expandContent
    }
}

/**
 One Android `Label` row from a staged bookmark sync backup.
 */
public struct RemoteSyncAndroidLabel: Sendable, Equatable {
    /// Android identifier blob converted into iOS UUID form.
    public let id: UUID

    /// User-visible label name or reserved system-label marker.
    public let name: String

    /// Android signed ARGB label color.
    public let color: Int

    /// Whether marker-style rendering is enabled.
    public let markerStyle: Bool

    /// Whether marker-style rendering applies to an entire verse.
    public let markerStyleWholeVerse: Bool

    /// Whether underline-style rendering is enabled.
    public let underlineStyle: Bool

    /// Whether underline rendering applies to an entire verse.
    public let underlineStyleWholeVerse: Bool

    /// Whether the visible highlight is suppressed.
    public let hideStyle: Bool

    /// Whether the hidden style applies to an entire verse.
    public let hideStyleWholeVerse: Bool

    /// Whether Android marked the label as a favourite.
    public let favourite: Bool

    /// Optional Android raw label-type string.
    public let type: String?

    /// Optional Android canonical custom-icon name.
    public let customIcon: String?

    /**
     Creates one staged Android label row.

     - Parameters:
       - id: Android identifier blob converted into iOS UUID form.
       - name: User-visible label name or reserved system-label marker.
       - color: Android signed ARGB label color.
       - markerStyle: Whether marker-style rendering is enabled.
       - markerStyleWholeVerse: Whether marker-style rendering applies to an entire verse.
       - underlineStyle: Whether underline-style rendering is enabled.
       - underlineStyleWholeVerse: Whether underline rendering applies to an entire verse.
       - hideStyle: Whether the visible highlight is suppressed.
       - hideStyleWholeVerse: Whether the hidden style applies to an entire verse.
       - favourite: Whether Android marked the label as a favourite.
       - type: Optional Android raw label-type string.
       - customIcon: Optional Android canonical custom-icon name.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        id: UUID,
        name: String,
        color: Int,
        markerStyle: Bool,
        markerStyleWholeVerse: Bool,
        underlineStyle: Bool,
        underlineStyleWholeVerse: Bool,
        hideStyle: Bool,
        hideStyleWholeVerse: Bool,
        favourite: Bool,
        type: String?,
        customIcon: String?
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.markerStyle = markerStyle
        self.markerStyleWholeVerse = markerStyleWholeVerse
        self.underlineStyle = underlineStyle
        self.underlineStyleWholeVerse = underlineStyleWholeVerse
        self.hideStyle = hideStyle
        self.hideStyleWholeVerse = hideStyleWholeVerse
        self.favourite = favourite
        self.type = type
        self.customIcon = customIcon
    }
}

/**
 One Android `BibleBookmark` row plus its associated note and label rows.
 */
public struct RemoteSyncAndroidBibleBookmark: Sendable, Equatable {
    /// Android identifier blob converted into iOS UUID form.
    public let id: UUID

    /// Start ordinal normalized into KJVA versification on Android.
    public let kjvOrdinalStart: Int

    /// End ordinal normalized into KJVA versification on Android.
    public let kjvOrdinalEnd: Int

    /// Start ordinal in the source versification.
    public let ordinalStart: Int

    /// End ordinal in the source versification.
    public let ordinalEnd: Int

    /// Raw Android versification identifier.
    public let v11n: String

    /// Raw Android `playbackSettings` JSON payload, when present.
    public let playbackSettingsJSON: String?

    /// Bookmark creation timestamp.
    public let createdAt: Date

    /// Optional Android book snapshot stored with the bookmark.
    public let book: String?

    /// Optional start character offset for a sub-verse selection.
    public let startOffset: Int?

    /// Optional end character offset for a sub-verse selection.
    public let endOffset: Int?

    /// Optional Android primary-label identifier.
    public let primaryLabelID: UUID?

    /// Optional detached note text.
    public let notes: String?

    /// Optional Android `TextContentType` raw value for the detached note text.
    public let notesContentType: String?

    /// Last bookmark mutation timestamp.
    public let lastUpdatedOn: Date

    /// Whether the bookmark covers the whole verse instead of a text span.
    public let wholeVerse: Bool

    /// Optional Android raw bookmark-type string.
    public let type: String?

    /// Optional Android canonical custom-icon name.
    public let customIcon: String?

    /// Optional bookmark note-edit automation descriptor.
    public let editAction: EditAction?

    /// Label rows linked to this bookmark via `BibleBookmarkToLabel`.
    public let labelLinks: [RemoteSyncAndroidBookmarkLabelLink]

    /**
     Creates one staged Android Bible bookmark row.

     - Parameters:
       - id: Android identifier blob converted into iOS UUID form.
       - kjvOrdinalStart: Start ordinal normalized into KJVA versification on Android.
       - kjvOrdinalEnd: End ordinal normalized into KJVA versification on Android.
       - ordinalStart: Start ordinal in the source versification.
       - ordinalEnd: End ordinal in the source versification.
       - v11n: Raw Android versification identifier.
       - playbackSettingsJSON: Raw Android `playbackSettings` JSON payload, when present.
       - createdAt: Bookmark creation timestamp.
       - book: Optional Android book snapshot stored with the bookmark.
       - startOffset: Optional start character offset for a sub-verse selection.
       - endOffset: Optional end character offset for a sub-verse selection.
       - primaryLabelID: Optional Android primary-label identifier.
       - notes: Optional detached note text.
       - notesContentType: Optional Android `TextContentType` raw value for the detached note text.
       - lastUpdatedOn: Last bookmark mutation timestamp.
       - wholeVerse: Whether the bookmark covers the whole verse instead of a text span.
       - type: Optional Android raw bookmark-type string.
       - customIcon: Optional Android canonical custom-icon name.
       - editAction: Optional bookmark note-edit automation descriptor.
       - labelLinks: Label rows linked to this bookmark via `BibleBookmarkToLabel`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        id: UUID,
        kjvOrdinalStart: Int,
        kjvOrdinalEnd: Int,
        ordinalStart: Int,
        ordinalEnd: Int,
        v11n: String,
        playbackSettingsJSON: String?,
        createdAt: Date,
        book: String?,
        startOffset: Int?,
        endOffset: Int?,
        primaryLabelID: UUID?,
        notes: String?,
        notesContentType: String? = nil,
        lastUpdatedOn: Date,
        wholeVerse: Bool,
        type: String?,
        customIcon: String?,
        editAction: EditAction?,
        labelLinks: [RemoteSyncAndroidBookmarkLabelLink]
    ) {
        self.id = id
        self.kjvOrdinalStart = kjvOrdinalStart
        self.kjvOrdinalEnd = kjvOrdinalEnd
        self.ordinalStart = ordinalStart
        self.ordinalEnd = ordinalEnd
        self.v11n = v11n
        self.playbackSettingsJSON = playbackSettingsJSON
        self.createdAt = createdAt
        self.book = book
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.primaryLabelID = primaryLabelID
        self.notes = notes
        self.notesContentType = AppPreferenceValueNormalizer.notesContentTypeRow(notesContentType)
        self.lastUpdatedOn = lastUpdatedOn
        self.wholeVerse = wholeVerse
        self.type = type
        self.customIcon = customIcon
        self.editAction = editAction
        self.labelLinks = labelLinks
    }
}

/**
 One Android `GenericBookmark` row plus its associated note and label rows.
 */
public struct RemoteSyncAndroidGenericBookmark: Sendable, Equatable {
    /// Android identifier blob converted into iOS UUID form.
    public let id: UUID

    /// Canonical document key or OSIS-like reference stored by Android.
    public let key: String

    /// Bookmark creation timestamp.
    public let createdAt: Date

    /// Android module initials for the bookmarked document.
    public let bookInitials: String

    /// Start ordinal within the target document.
    public let ordinalStart: Int

    /// End ordinal within the target document.
    public let ordinalEnd: Int

    /// Optional start character offset for a partial selection.
    public let startOffset: Int?

    /// Optional end character offset for a partial selection.
    public let endOffset: Int?

    /// Optional Android primary-label identifier.
    public let primaryLabelID: UUID?

    /// Optional detached note text.
    public let notes: String?

    /// Optional Android `TextContentType` raw value for the detached note text.
    public let notesContentType: String?

    /// Last bookmark mutation timestamp.
    public let lastUpdatedOn: Date

    /// Whether the bookmark covers the whole keyed entry.
    public let wholeVerse: Bool

    /// Raw Android `playbackSettings` JSON payload, when present.
    public let playbackSettingsJSON: String?

    /// Optional Android canonical custom-icon name.
    public let customIcon: String?

    /// Optional bookmark note-edit automation descriptor.
    public let editAction: EditAction?

    /// Label rows linked to this bookmark via `GenericBookmarkToLabel`.
    public let labelLinks: [RemoteSyncAndroidBookmarkLabelLink]

    /**
     Creates one staged Android generic bookmark row.

     - Parameters:
       - id: Android identifier blob converted into iOS UUID form.
       - key: Canonical document key or OSIS-like reference stored by Android.
       - createdAt: Bookmark creation timestamp.
       - bookInitials: Android module initials for the bookmarked document.
       - ordinalStart: Start ordinal within the target document.
       - ordinalEnd: End ordinal within the target document.
       - startOffset: Optional start character offset for a partial selection.
       - endOffset: Optional end character offset for a partial selection.
       - primaryLabelID: Optional Android primary-label identifier.
       - notes: Optional detached note text.
       - notesContentType: Optional Android `TextContentType` raw value for the detached note text.
       - lastUpdatedOn: Last bookmark mutation timestamp.
       - wholeVerse: Whether the bookmark covers the whole keyed entry.
       - playbackSettingsJSON: Raw Android `playbackSettings` JSON payload, when present.
       - customIcon: Optional Android canonical custom-icon name.
       - editAction: Optional bookmark note-edit automation descriptor.
       - labelLinks: Label rows linked to this bookmark via `GenericBookmarkToLabel`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail; staged SQLite readers validate non-null values
       before constructing these value types.
     */
    public init(
        id: UUID,
        key: String,
        createdAt: Date,
        bookInitials: String,
        ordinalStart: Int,
        ordinalEnd: Int,
        startOffset: Int?,
        endOffset: Int?,
        primaryLabelID: UUID?,
        notes: String?,
        notesContentType: String? = nil,
        lastUpdatedOn: Date,
        wholeVerse: Bool,
        playbackSettingsJSON: String?,
        customIcon: String?,
        editAction: EditAction?,
        labelLinks: [RemoteSyncAndroidBookmarkLabelLink]
    ) {
        self.id = id
        self.key = key
        self.createdAt = createdAt
        self.bookInitials = bookInitials
        self.ordinalStart = ordinalStart
        self.ordinalEnd = ordinalEnd
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.primaryLabelID = primaryLabelID
        self.notes = notes
        self.notesContentType = AppPreferenceValueNormalizer.notesContentTypeRow(notesContentType)
        self.lastUpdatedOn = lastUpdatedOn
        self.wholeVerse = wholeVerse
        self.playbackSettingsJSON = playbackSettingsJSON
        self.customIcon = customIcon
        self.editAction = editAction
        self.labelLinks = labelLinks
    }
}

/**
 One Android `StudyPadTextEntryWithText` row reconstructed from staged sync tables.
 */
public struct RemoteSyncAndroidStudyPadEntry: Sendable, Equatable {
    /// Android identifier blob converted into iOS UUID form.
    public let id: UUID

    /// Android label identifier that owns the StudyPad entry.
    public let labelID: UUID

    /// Display order within the label-backed StudyPad outline.
    public let orderNumber: Int

    /// Nesting depth within the StudyPad outline.
    public let indentLevel: Int

    /// Optional Android `TextContentType` raw value for the detached StudyPad text payload.
    public let contentType: String?

    /// Detached StudyPad text payload.
    public let text: String

    /**
     Creates one staged Android StudyPad entry row.

     - Parameters:
       - id: Android identifier blob converted into iOS UUID form.
       - labelID: Android label identifier that owns the StudyPad entry.
       - orderNumber: Display order within the label-backed StudyPad outline.
       - indentLevel: Nesting depth within the StudyPad outline.
       - contentType: Optional Android `TextContentType` raw value for the detached text payload.
       - text: Detached StudyPad text payload.
     - Side effects: none.
     - Failure modes: This initializer cannot fail; staged SQLite readers validate non-null values
       before constructing these value types.
     */
    public init(
        id: UUID,
        labelID: UUID,
        orderNumber: Int,
        indentLevel: Int,
        contentType: String? = nil,
        text: String
    ) {
        self.id = id
        self.labelID = labelID
        self.orderNumber = orderNumber
        self.indentLevel = indentLevel
        self.contentType = AppPreferenceValueNormalizer.notesContentTypeRow(contentType)
        self.text = text
    }
}

/**
 Read-only snapshot of one staged Android bookmark sync database.

 The snapshot materializes Android labels, Bible bookmarks, generic bookmarks, and StudyPad rows
 into iOS-native value types while preserving Android identifiers and raw payloads. Reserved
 system-label identifier remapping happens later during restore so the snapshot remains a direct
 representation of what the staged SQLite database contained.
 */
public struct RemoteSyncAndroidBookmarkSnapshot: Sendable, Equatable {
    /// Android label rows read from the staged database.
    public let labels: [RemoteSyncAndroidLabel]

    /// Android Bible bookmark rows with aggregated notes and label links.
    public let bibleBookmarks: [RemoteSyncAndroidBibleBookmark]

    /// Android generic bookmark rows with aggregated notes and label links.
    public let genericBookmarks: [RemoteSyncAndroidGenericBookmark]

    /// Android StudyPad rows reconstructed from entry and text tables.
    public let studyPadEntries: [RemoteSyncAndroidStudyPadEntry]

    /**
     Creates a staged Android bookmark snapshot.

     - Parameters:
       - labels: Android label rows read from the staged database.
       - bibleBookmarks: Android Bible bookmark rows with aggregated notes and label links.
       - genericBookmarks: Android generic bookmark rows with aggregated notes and label links.
       - studyPadEntries: Android StudyPad rows reconstructed from entry and text tables.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        labels: [RemoteSyncAndroidLabel],
        bibleBookmarks: [RemoteSyncAndroidBibleBookmark],
        genericBookmarks: [RemoteSyncAndroidGenericBookmark],
        studyPadEntries: [RemoteSyncAndroidStudyPadEntry]
    ) {
        self.labels = labels
        self.bibleBookmarks = bibleBookmarks
        self.genericBookmarks = genericBookmarks
        self.studyPadEntries = studyPadEntries
    }
}

/**
 Summary of one successful Android bookmark restore.
 */
public struct RemoteSyncBookmarkRestoreReport: Sendable, Equatable {
    /// Number of label rows present after restore, including any ensured system labels.
    public let restoredLabelCount: Int

    /// Number of Bible bookmarks restored from the staged Android snapshot.
    public let restoredBibleBookmarkCount: Int

    /// Number of generic bookmarks restored from the staged Android snapshot.
    public let restoredGenericBookmarkCount: Int

    /// Number of StudyPad entries restored from the staged Android snapshot.
    public let restoredStudyPadEntryCount: Int

    /// Number of raw Android bookmark `playbackSettings` payloads preserved locally.
    public let preservedPlaybackSettingsCount: Int

    /// Number of Android system-label identifier aliases preserved locally.
    public let preservedSystemLabelAliasCount: Int

    /**
     Creates a bookmark restore summary.

     - Parameters:
       - restoredLabelCount: Number of label rows present after restore, including any ensured system labels.
       - restoredBibleBookmarkCount: Number of Bible bookmarks restored from the staged Android snapshot.
       - restoredGenericBookmarkCount: Number of generic bookmarks restored from the staged Android snapshot.
       - restoredStudyPadEntryCount: Number of StudyPad entries restored from the staged Android snapshot.
       - preservedPlaybackSettingsCount: Number of raw Android bookmark `playbackSettings` payloads preserved locally.
       - preservedSystemLabelAliasCount: Number of Android system-label identifier aliases preserved locally.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        restoredLabelCount: Int,
        restoredBibleBookmarkCount: Int,
        restoredGenericBookmarkCount: Int,
        restoredStudyPadEntryCount: Int,
        preservedPlaybackSettingsCount: Int,
        preservedSystemLabelAliasCount: Int
    ) {
        self.restoredLabelCount = restoredLabelCount
        self.restoredBibleBookmarkCount = restoredBibleBookmarkCount
        self.restoredGenericBookmarkCount = restoredGenericBookmarkCount
        self.restoredStudyPadEntryCount = restoredStudyPadEntryCount
        self.preservedPlaybackSettingsCount = preservedPlaybackSettingsCount
        self.preservedSystemLabelAliasCount = preservedSystemLabelAliasCount
    }
}

/**
 Reads staged Android bookmark databases and restores them into iOS SwiftData.

 The bookmark sync category is broader than Bible highlights alone. Android stores labels, Bible
 bookmarks, generic bookmarks, detached notes, bookmark-to-label junction rows, and StudyPad text
 in the same database. This restore service preserves that category boundary and replaces the whole
 local bookmark graph from a staged Android backup instead of attempting piecemeal translation.

 Mapping notes:
 - Android's three reserved system labels use random `IdType` values, while iOS canonicalizes
   them onto deterministic UUIDs; restore remaps those labels and preserves alias rows locally for
   future patch translation
 - Android bookmark `playbackSettings` JSON is richer than the current iOS bookmark model; restore
   projects the `bookId` subset into `PlaybackSettings` while preserving the raw Android JSON
   locally through `RemoteSyncBookmarkPlaybackSettingsStore`
 - missing system labels are recreated with canonical iOS identifiers after restore so runtime
   bookmark flows retain their expected invariants even when the remote Android snapshot omitted
   unused system rows

 Data dependencies:
 - staged SQLite backups are read directly from Android's bookmark-category tables
 - `SettingsStore` is used indirectly through fidelity side stores for playback JSON and
   system-label identifier aliases

 Side effects:
 - `replaceLocalBookmarks(from:modelContext:settingsStore:)` deletes and recreates the local
   bookmark-category SwiftData graph
 - successful restores clear and repopulate local-only fidelity stores for Android playback JSON
   and system-label aliases

 Failure modes:
 - staged snapshot parsing fails explicitly when required tables are missing or foreign-key-like
   references are inconsistent
 - restore rethrows `ModelContext.save()` failures after mutating the in-memory SwiftData graph
 - local-only fidelity stores are best-effort and inherit `SettingsStore`'s soft-fail semantics

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement of the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncBookmarkRestoreService {
    private struct RawBibleBookmarkRow {
        let id: UUID
        let kjvOrdinalStart: Int
        let kjvOrdinalEnd: Int
        let ordinalStart: Int
        let ordinalEnd: Int
        let v11n: String
        let playbackSettingsJSON: String?
        let createdAt: Date
        let book: String?
        let startOffset: Int?
        let endOffset: Int?
        let primaryLabelID: UUID?
        let lastUpdatedOn: Date
        let wholeVerse: Bool
        let type: String?
        let customIcon: String?
        let editAction: EditAction?
    }

    private struct RawGenericBookmarkRow {
        let id: UUID
        let key: String
        let createdAt: Date
        let bookInitials: String
        let ordinalStart: Int
        let ordinalEnd: Int
        let startOffset: Int?
        let endOffset: Int?
        let primaryLabelID: UUID?
        let lastUpdatedOn: Date
        let wholeVerse: Bool
        let playbackSettingsJSON: String?
        let customIcon: String?
        let editAction: EditAction?
    }

    private struct RawStudyPadEntryRow {
        let id: UUID
        let labelID: UUID
        let orderNumber: Int
        let indentLevel: Int
        let contentType: String?
    }

    private struct PreparedLabel {
        let label: RemoteSyncAndroidLabel
        let localID: UUID
        let remoteID: UUID
    }

    private struct PreparedBibleBookmark {
        let bookmark: RemoteSyncAndroidBibleBookmark
        let localPrimaryLabelID: UUID?
        let localLabelLinks: [PreparedLabelLink]
        let playbackSettings: PlaybackSettings?
    }

    private struct PreparedGenericBookmark {
        let bookmark: RemoteSyncAndroidGenericBookmark
        let localPrimaryLabelID: UUID?
        let localLabelLinks: [PreparedLabelLink]
        let playbackSettings: PlaybackSettings?
    }

    private struct PreparedLabelLink {
        let localLabelID: UUID
        let orderNumber: Int
        let indentLevel: Int
        let expandContent: Bool
    }

    private struct PreparedStudyPadEntry {
        let entry: RemoteSyncAndroidStudyPadEntry
        let localLabelID: UUID
    }

    private struct PreparedRestore {
        let labels: [PreparedLabel]
        let bibleBookmarks: [PreparedBibleBookmark]
        let genericBookmarks: [PreparedGenericBookmark]
        let studyPadEntries: [PreparedStudyPadEntry]
        let systemLabelAliases: [RemoteSyncBookmarkLabelAliasStore.Alias]
    }

    private struct AndroidPlaybackSettingsProjection: Decodable {
        let bookId: String?
    }

    /// Resolver that translates Android `book` column semantics into iOS display book names.
    private let bookNameResolver: AndroidBookmarkBookNameResolving?

    /**
     Creates a bookmark restore service.

     - Parameter bookNameResolver: Boundary that normalizes Android's module-initials `book`
       column into the iOS display book name during restore. The default SWORD-backed resolver
       derives names from each bookmark's own versification and ordinals; passing `nil` disables
       normalization and preserves raw Android values verbatim.
     - Side effects: none; the default resolver creates SWORD state lazily on first restore.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        bookNameResolver: AndroidBookmarkBookNameResolving? = AndroidBookmarkSwordBookNameResolver()
    ) {
        self.bookNameResolver = bookNameResolver
    }

    /**
     Normalizes one restored bookmark's `book` value into iOS display-name semantics.

     Android stores SWORD module initials (or NULL) in the `book` column because Android renders
     references from `v11n` + ordinals; iOS uses the same field as the display book name that
     keys list rendering, chapter-highlight queries, and navigation (issue #356). Only the two
     shapes Android actually produces are rewritten — NULL and installed-module initials — so
     locally created display names and localized names survive merge round-trips unchanged.

     - Parameter bookmark: Staged Android bookmark row being materialized into SwiftData.
     - Returns: The derived display book name, or the raw Android value when derivation is
       unavailable or the raw value is not an Android module-initials shape.
     - Side effects: may lazily create SWORD state through the injected resolver.
     - Failure modes: falls back to the raw value whenever resolution fails.
     */
    private func normalizedDisplayBookName(for bookmark: RemoteSyncAndroidBibleBookmark) -> String? {
        guard let bookNameResolver else { return bookmark.book }

        let shouldDerive: Bool
        if let raw = bookmark.book {
            shouldDerive = bookNameResolver.isInstalledBibleInitials(raw)
        } else {
            shouldDerive = true
        }
        guard shouldDerive else { return bookmark.book }

        let derived = bookNameResolver.displayBookName(
            v11nName: bookmark.v11n,
            ordinal: bookmark.ordinalStart,
            kjvOrdinal: bookmark.kjvOrdinalStart
        )
        return derived ?? bookmark.book
    }

    /**
     Reads one staged Android bookmark SQLite database into a typed snapshot.

     - Parameter databaseURL: Local URL of the extracted Android bookmark backup database.
     - Returns: Typed snapshot of staged labels, bookmarks, and StudyPad rows.
     - Side effects:
       - opens the staged SQLite database in read-only mode
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the file cannot be
         opened as SQLite
       - throws `RemoteSyncBookmarkRestoreError.missingTable` when required Android tables are
         absent
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when Android UUID-like BLOB
         columns cannot be converted into `UUID`
       - throws `RemoteSyncBookmarkRestoreError.orphanReferences` when staged rows reference
         missing parent records or missing required StudyPad text rows
     */
    public func readSnapshot(from databaseURL: URL) throws -> RemoteSyncAndroidBookmarkSnapshot {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(db) }

        for tableName in [
            "Label",
            "BibleBookmark",
            "BibleBookmarkNotes",
            "BibleBookmarkToLabel",
            "GenericBookmark",
            "GenericBookmarkNotes",
            "GenericBookmarkToLabel",
            "StudyPadTextEntry",
            "StudyPadTextEntryText",
        ] {
            try requireTable(named: tableName, in: db)
        }

        let labels = try fetchLabels(from: db)
        let bibleBookmarks = try fetchBibleBookmarks(from: db)
        let genericBookmarks = try fetchGenericBookmarks(from: db)
        let bibleNotes = try fetchNoteRows(from: db, tableName: "BibleBookmarkNotes")
        let genericNotes = try fetchNoteRows(from: db, tableName: "GenericBookmarkNotes")
        let bibleLinks = try fetchLabelLinks(from: db, tableName: "BibleBookmarkToLabel")
        let genericLinks = try fetchLabelLinks(from: db, tableName: "GenericBookmarkToLabel")
        let studyPadEntries = try fetchStudyPadEntries(from: db)
        let studyPadTexts = try fetchStudyPadTexts(from: db)

        try validateSnapshotReferences(
            labels: labels,
            bibleBookmarks: bibleBookmarks,
            genericBookmarks: genericBookmarks,
            bibleNotes: bibleNotes,
            genericNotes: genericNotes,
            bibleLinks: bibleLinks,
            genericLinks: genericLinks,
            studyPadEntries: studyPadEntries,
            studyPadTexts: studyPadTexts
        )

        let bibleNotesByID = Dictionary(uniqueKeysWithValues: bibleNotes.map { ($0.bookmarkID, $0) })
        let genericNotesByID = Dictionary(uniqueKeysWithValues: genericNotes.map { ($0.bookmarkID, $0) })
        let bibleLinksByBookmarkID = Dictionary(grouping: bibleLinks, by: \.bookmarkID)
        let genericLinksByBookmarkID = Dictionary(grouping: genericLinks, by: \.bookmarkID)
        let studyPadTextsByID = Dictionary(uniqueKeysWithValues: studyPadTexts.map { ($0.entryID, $0.text) })

        let snapshot = RemoteSyncAndroidBookmarkSnapshot(
            labels: labels.sorted { lhs, rhs in
                if lhs.name == rhs.name {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.name < rhs.name
            },
            bibleBookmarks: bibleBookmarks.map { bookmark in
                RemoteSyncAndroidBibleBookmark(
                    id: bookmark.id,
                    kjvOrdinalStart: bookmark.kjvOrdinalStart,
                    kjvOrdinalEnd: bookmark.kjvOrdinalEnd,
                    ordinalStart: bookmark.ordinalStart,
                    ordinalEnd: bookmark.ordinalEnd,
                    v11n: bookmark.v11n,
                    playbackSettingsJSON: bookmark.playbackSettingsJSON,
                    createdAt: bookmark.createdAt,
                    book: bookmark.book,
                    startOffset: bookmark.startOffset,
                    endOffset: bookmark.endOffset,
                    primaryLabelID: bookmark.primaryLabelID,
                    notes: bibleNotesByID[bookmark.id]?.notes,
                    notesContentType: bibleNotesByID[bookmark.id]?.contentType,
                    lastUpdatedOn: bookmark.lastUpdatedOn,
                    wholeVerse: bookmark.wholeVerse,
                    type: bookmark.type,
                    customIcon: bookmark.customIcon,
                    editAction: bookmark.editAction,
                    labelLinks: (bibleLinksByBookmarkID[bookmark.id] ?? []).map {
                        RemoteSyncAndroidBookmarkLabelLink(
                            labelID: $0.labelID,
                            orderNumber: $0.orderNumber,
                            indentLevel: $0.indentLevel,
                            expandContent: $0.expandContent
                        )
                    }
                    .sorted(by: Self.sortLabelLinks)
                )
            }
            .sorted { $0.id.uuidString < $1.id.uuidString },
            genericBookmarks: genericBookmarks.map { bookmark in
                RemoteSyncAndroidGenericBookmark(
                    id: bookmark.id,
                    key: bookmark.key,
                    createdAt: bookmark.createdAt,
                    bookInitials: bookmark.bookInitials,
                    ordinalStart: bookmark.ordinalStart,
                    ordinalEnd: bookmark.ordinalEnd,
                    startOffset: bookmark.startOffset,
                    endOffset: bookmark.endOffset,
                    primaryLabelID: bookmark.primaryLabelID,
                    notes: genericNotesByID[bookmark.id]?.notes,
                    notesContentType: genericNotesByID[bookmark.id]?.contentType,
                    lastUpdatedOn: bookmark.lastUpdatedOn,
                    wholeVerse: bookmark.wholeVerse,
                    playbackSettingsJSON: bookmark.playbackSettingsJSON,
                    customIcon: bookmark.customIcon,
                    editAction: bookmark.editAction,
                    labelLinks: (genericLinksByBookmarkID[bookmark.id] ?? []).map {
                        RemoteSyncAndroidBookmarkLabelLink(
                            labelID: $0.labelID,
                            orderNumber: $0.orderNumber,
                            indentLevel: $0.indentLevel,
                            expandContent: $0.expandContent
                        )
                    }
                    .sorted(by: Self.sortLabelLinks)
                )
            }
            .sorted { $0.id.uuidString < $1.id.uuidString },
            studyPadEntries: studyPadEntries.map { entry in
                RemoteSyncAndroidStudyPadEntry(
                    id: entry.id,
                    labelID: entry.labelID,
                    orderNumber: entry.orderNumber,
                    indentLevel: entry.indentLevel,
                    contentType: entry.contentType,
                    text: studyPadTextsByID[entry.id] ?? ""
                )
            }
            .sorted {
                if $0.orderNumber == $1.orderNumber {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.orderNumber < $1.orderNumber
            }
        )

        return snapshot
    }

    /**
     Replaces local iOS bookmark-category data with the supplied staged Android snapshot.

     The restore is conservative and category-scoped. It validates label remapping, special-label
     aliasing, and all bookmark/category references before mutating local data. Once validation
     succeeds, it clears the local bookmark graph, recreates labels/bookmarks/StudyPad entries,
     saves the SwiftData graph, and then refreshes the local-only Android fidelity stores.

     - Parameters:
       - snapshot: Staged Android bookmark snapshot previously read from `readSnapshot(from:)`.
       - modelContext: SwiftData context whose bookmark-category rows should be replaced.
       - settingsStore: Local-only settings store used by Android fidelity side stores.
     - Returns: Summary of restored bookmark-category rows and preserved Android-only fidelity data.
     - Side effects:
       - deletes existing local bookmark-category SwiftData rows
       - inserts replacement labels, Bible bookmarks, generic bookmarks, notes, junction rows, and StudyPad rows
       - saves `modelContext`
       - clears and repopulates the local-only playback-settings and label-alias side stores
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.duplicateSystemLabels` when multiple staged labels
         claim the same reserved system-label name
       - throws `RemoteSyncBookmarkRestoreError.orphanReferences` when staged bookmarks or StudyPad
         rows reference label identifiers that cannot be resolved after remapping
       - rethrows SwiftData save errors from `modelContext.save()`
     */
    public func replaceLocalBookmarks(
        from snapshot: RemoteSyncAndroidBookmarkSnapshot,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncBookmarkRestoreReport {
        let prepared = try prepareRestore(from: snapshot)

        try deleteExistingBookmarkGraph(from: modelContext)

        var labelsByID: [UUID: Label] = [:]
        for preparedLabel in prepared.labels {
            let restoredLabel = Label(
                id: preparedLabel.localID,
                name: preparedLabel.label.name,
                color: preparedLabel.label.color,
                markerStyle: preparedLabel.label.markerStyle,
                markerStyleWholeVerse: preparedLabel.label.markerStyleWholeVerse,
                underlineStyle: preparedLabel.label.underlineStyle,
                underlineStyleWholeVerse: preparedLabel.label.underlineStyleWholeVerse,
                hideStyle: preparedLabel.label.hideStyle,
                hideStyleWholeVerse: preparedLabel.label.hideStyleWholeVerse,
                favourite: preparedLabel.label.favourite
            )
            restoredLabel.type = preparedLabel.label.type
            restoredLabel.customIcon = preparedLabel.label.customIcon
            modelContext.insert(restoredLabel)
            labelsByID[restoredLabel.id] = restoredLabel
        }

        ensureMissingSystemLabels(in: modelContext, labelsByID: &labelsByID)

        var bibleBookmarksByID: [UUID: BibleBookmark] = [:]
        var normalizedBookRewrites: [(bookmarkID: UUID, rawBook: String?)] = []
        for preparedBookmark in prepared.bibleBookmarks {
            let bookmark = BibleBookmark(
                id: preparedBookmark.bookmark.id,
                kjvOrdinalStart: preparedBookmark.bookmark.kjvOrdinalStart,
                kjvOrdinalEnd: preparedBookmark.bookmark.kjvOrdinalEnd,
                ordinalStart: preparedBookmark.bookmark.ordinalStart,
                ordinalEnd: preparedBookmark.bookmark.ordinalEnd,
                v11n: preparedBookmark.bookmark.v11n,
                createdAt: preparedBookmark.bookmark.createdAt,
                lastUpdatedOn: preparedBookmark.bookmark.lastUpdatedOn,
                wholeVerse: preparedBookmark.bookmark.wholeVerse
            )
            let rawBook = preparedBookmark.bookmark.book
            let displayBook = normalizedDisplayBookName(for: preparedBookmark.bookmark)
            bookmark.book = displayBook
            if displayBook != rawBook {
                normalizedBookRewrites.append((bookmarkID: bookmark.id, rawBook: rawBook))
            }
            bookmark.startOffset = preparedBookmark.bookmark.startOffset
            bookmark.endOffset = preparedBookmark.bookmark.endOffset
            bookmark.primaryLabelId = preparedBookmark.localPrimaryLabelID
            bookmark.playbackSettings = preparedBookmark.playbackSettings
            bookmark.type = preparedBookmark.bookmark.type
            bookmark.customIcon = preparedBookmark.bookmark.customIcon
            bookmark.editAction = preparedBookmark.bookmark.editAction
            if let notes = preparedBookmark.bookmark.notes {
                let noteEntity = BibleBookmarkNotes(
                    bookmarkId: bookmark.id,
                    notes: notes,
                    contentType: preparedBookmark.bookmark.notesContentType
                )
                noteEntity.bookmark = bookmark
                bookmark.notes = noteEntity
                modelContext.insert(noteEntity)
            }
            modelContext.insert(bookmark)
            bibleBookmarksByID[bookmark.id] = bookmark
        }

        var genericBookmarksByID: [UUID: GenericBookmark] = [:]
        for preparedBookmark in prepared.genericBookmarks {
            let bookmark = GenericBookmark(
                id: preparedBookmark.bookmark.id,
                key: preparedBookmark.bookmark.key,
                bookInitials: preparedBookmark.bookmark.bookInitials,
                createdAt: preparedBookmark.bookmark.createdAt,
                ordinalStart: preparedBookmark.bookmark.ordinalStart,
                ordinalEnd: preparedBookmark.bookmark.ordinalEnd,
                lastUpdatedOn: preparedBookmark.bookmark.lastUpdatedOn,
                wholeVerse: preparedBookmark.bookmark.wholeVerse
            )
            bookmark.startOffset = preparedBookmark.bookmark.startOffset
            bookmark.endOffset = preparedBookmark.bookmark.endOffset
            bookmark.primaryLabelId = preparedBookmark.localPrimaryLabelID
            bookmark.playbackSettings = preparedBookmark.playbackSettings
            bookmark.customIcon = preparedBookmark.bookmark.customIcon
            bookmark.editAction = preparedBookmark.bookmark.editAction
            if let notes = preparedBookmark.bookmark.notes {
                let noteEntity = GenericBookmarkNotes(
                    bookmarkId: bookmark.id,
                    notes: notes,
                    contentType: preparedBookmark.bookmark.notesContentType
                )
                noteEntity.bookmark = bookmark
                bookmark.notes = noteEntity
                modelContext.insert(noteEntity)
            }
            modelContext.insert(bookmark)
            genericBookmarksByID[bookmark.id] = bookmark
        }

        for preparedBookmark in prepared.bibleBookmarks {
            guard let bookmark = bibleBookmarksByID[preparedBookmark.bookmark.id] else { continue }
            for link in preparedBookmark.localLabelLinks {
                guard let label = labelsByID[link.localLabelID] else { continue }
                let junction = BibleBookmarkToLabel(
                    orderNumber: link.orderNumber,
                    indentLevel: link.indentLevel,
                    expandContent: link.expandContent
                )
                junction.bookmark = bookmark
                junction.label = label
                modelContext.insert(junction)
            }
        }

        for preparedBookmark in prepared.genericBookmarks {
            guard let bookmark = genericBookmarksByID[preparedBookmark.bookmark.id] else { continue }
            for link in preparedBookmark.localLabelLinks {
                guard let label = labelsByID[link.localLabelID] else { continue }
                let junction = GenericBookmarkToLabel(
                    orderNumber: link.orderNumber,
                    indentLevel: link.indentLevel,
                    expandContent: link.expandContent
                )
                junction.bookmark = bookmark
                junction.label = label
                modelContext.insert(junction)
            }
        }

        for preparedEntry in prepared.studyPadEntries {
            guard let label = labelsByID[preparedEntry.localLabelID] else { continue }
            let entry = StudyPadTextEntry(
                id: preparedEntry.entry.id,
                orderNumber: preparedEntry.entry.orderNumber,
                indentLevel: preparedEntry.entry.indentLevel,
                contentType: preparedEntry.entry.contentType
            )
            entry.label = label
            modelContext.insert(entry)

            let textEntity = StudyPadTextEntryText(studyPadTextEntryId: preparedEntry.entry.id, text: preparedEntry.entry.text)
            textEntity.entry = entry
            entry.textEntry = textEntity
            modelContext.insert(textEntity)
        }

        try modelContext.save()

        let playbackSettingsStore = RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore)
        let labelAliasStore = RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore)
        let androidBookStore = RemoteSyncBookmarkAndroidBookStore(settingsStore: settingsStore)
        playbackSettingsStore.clearAll()
        labelAliasStore.clearAll()
        androidBookStore.clearAll()

        for rewrite in normalizedBookRewrites {
            androidBookStore.setRawBook(rewrite.rawBook, for: rewrite.bookmarkID)
        }

        var preservedPlaybackSettingsCount = 0
        for preparedBookmark in prepared.bibleBookmarks {
            guard let playbackSettingsJSON = preparedBookmark.bookmark.playbackSettingsJSON,
                  !playbackSettingsJSON.isEmpty else {
                continue
            }
            playbackSettingsStore.setPlaybackSettingsJSON(playbackSettingsJSON, for: preparedBookmark.bookmark.id, kind: .bible)
            preservedPlaybackSettingsCount += 1
        }
        for preparedBookmark in prepared.genericBookmarks {
            guard let playbackSettingsJSON = preparedBookmark.bookmark.playbackSettingsJSON,
                  !playbackSettingsJSON.isEmpty else {
                continue
            }
            playbackSettingsStore.setPlaybackSettingsJSON(playbackSettingsJSON, for: preparedBookmark.bookmark.id, kind: .generic)
            preservedPlaybackSettingsCount += 1
        }

        for alias in prepared.systemLabelAliases {
            labelAliasStore.setAlias(remoteLabelID: alias.remoteLabelID, localLabelID: alias.localLabelID)
        }

        return RemoteSyncBookmarkRestoreReport(
            restoredLabelCount: labelsByID.count,
            restoredBibleBookmarkCount: prepared.bibleBookmarks.count,
            restoredGenericBookmarkCount: prepared.genericBookmarks.count,
            restoredStudyPadEntryCount: prepared.studyPadEntries.count,
            preservedPlaybackSettingsCount: preservedPlaybackSettingsCount,
            preservedSystemLabelAliasCount: prepared.systemLabelAliases.count
        )
    }

    /**
     Validates snapshot references and remaps Android system-label identifiers onto canonical iOS identifiers.

     This preparation step keeps the raw snapshot immutable while deriving the normalized label IDs
     that the local SwiftData graph must use. It also projects bookmark playback metadata into the
     current iOS `PlaybackSettings` subset and produces the alias rows needed for later patch work.

     - Parameter snapshot: Raw snapshot read directly from the staged Android bookmark database.
     - Returns: Normalized restore payload ready for local SwiftData insertion.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.duplicateSystemLabels` when multiple staged labels
         claim the same reserved system-label name
       - throws `RemoteSyncBookmarkRestoreError.orphanReferences` when bookmark or StudyPad label
         references cannot be resolved after label remapping
     */
    private func prepareRestore(from snapshot: RemoteSyncAndroidBookmarkSnapshot) throws -> PreparedRestore {
        let duplicateSystemLabels = Self.systemLabelNames.filter { systemName in
            snapshot.labels.filter { $0.name == systemName }.count > 1
        }.sorted()
        if !duplicateSystemLabels.isEmpty {
            throw RemoteSyncBookmarkRestoreError.duplicateSystemLabels(duplicateSystemLabels)
        }

        var labelIDMap: [UUID: UUID] = [:]
        var preparedLabels: [PreparedLabel] = []
        var aliases: [RemoteSyncBookmarkLabelAliasStore.Alias] = []

        for label in snapshot.labels {
            let localID = Self.canonicalSystemLabelID(for: label.name) ?? label.id
            let isSystemLabel = Self.isSystemLabelName(label.name)
            labelIDMap[label.id] = localID
            preparedLabels.append(
                PreparedLabel(label: label, localID: localID, remoteID: label.id)
            )
            if isSystemLabel {
                aliases.append(.init(remoteLabelID: label.id, localLabelID: localID))
            }
        }

        var unresolvedReferences: [String] = []

        let preparedBibleBookmarks = snapshot.bibleBookmarks.map { bookmark in
            let localPrimaryLabelID = bookmark.primaryLabelID.flatMap { remoteID in
                if let localID = labelIDMap[remoteID] {
                    return localID
                }
                unresolvedReferences.append("BibleBookmark.primaryLabelId=\(remoteID.uuidString) missing label for bookmark \(bookmark.id.uuidString)")
                return nil
            }

            let localLabelLinks = bookmark.labelLinks.compactMap { link -> PreparedLabelLink? in
                guard let localLabelID = labelIDMap[link.labelID] else {
                    unresolvedReferences.append("BibleBookmarkToLabel.labelId=\(link.labelID.uuidString) missing label for bookmark \(bookmark.id.uuidString)")
                    return nil
                }
                return PreparedLabelLink(
                    localLabelID: localLabelID,
                    orderNumber: link.orderNumber,
                    indentLevel: link.indentLevel,
                    expandContent: link.expandContent
                )
            }

            return PreparedBibleBookmark(
                bookmark: bookmark,
                localPrimaryLabelID: localPrimaryLabelID,
                localLabelLinks: localLabelLinks,
                playbackSettings: projectPlaybackSettings(from: bookmark.playbackSettingsJSON)
            )
        }

        let preparedGenericBookmarks = snapshot.genericBookmarks.map { bookmark in
            let localPrimaryLabelID = bookmark.primaryLabelID.flatMap { remoteID in
                if let localID = labelIDMap[remoteID] {
                    return localID
                }
                unresolvedReferences.append("GenericBookmark.primaryLabelId=\(remoteID.uuidString) missing label for bookmark \(bookmark.id.uuidString)")
                return nil
            }

            let localLabelLinks = bookmark.labelLinks.compactMap { link -> PreparedLabelLink? in
                guard let localLabelID = labelIDMap[link.labelID] else {
                    unresolvedReferences.append("GenericBookmarkToLabel.labelId=\(link.labelID.uuidString) missing label for bookmark \(bookmark.id.uuidString)")
                    return nil
                }
                return PreparedLabelLink(
                    localLabelID: localLabelID,
                    orderNumber: link.orderNumber,
                    indentLevel: link.indentLevel,
                    expandContent: link.expandContent
                )
            }

            return PreparedGenericBookmark(
                bookmark: bookmark,
                localPrimaryLabelID: localPrimaryLabelID,
                localLabelLinks: localLabelLinks,
                playbackSettings: projectPlaybackSettings(from: bookmark.playbackSettingsJSON)
            )
        }

        let preparedStudyPadEntries = snapshot.studyPadEntries.compactMap { entry -> PreparedStudyPadEntry? in
            guard let localLabelID = labelIDMap[entry.labelID] else {
                unresolvedReferences.append("StudyPadTextEntry.labelId=\(entry.labelID.uuidString) missing label for entry \(entry.id.uuidString)")
                return nil
            }
            return PreparedStudyPadEntry(entry: entry, localLabelID: localLabelID)
        }

        if !unresolvedReferences.isEmpty {
            throw RemoteSyncBookmarkRestoreError.orphanReferences(Array(Set(unresolvedReferences)).sorted())
        }

        return PreparedRestore(
            labels: preparedLabels.sorted { lhs, rhs in
                if lhs.localID == rhs.localID {
                    return lhs.remoteID.uuidString < rhs.remoteID.uuidString
                }
                return lhs.localID.uuidString < rhs.localID.uuidString
            },
            bibleBookmarks: preparedBibleBookmarks.sorted { $0.bookmark.id.uuidString < $1.bookmark.id.uuidString },
            genericBookmarks: preparedGenericBookmarks.sorted { $0.bookmark.id.uuidString < $1.bookmark.id.uuidString },
            studyPadEntries: preparedStudyPadEntries.sorted {
                if $0.entry.orderNumber == $1.entry.orderNumber {
                    return $0.entry.id.uuidString < $1.entry.id.uuidString
                }
                return $0.entry.orderNumber < $1.entry.orderNumber
            },
            systemLabelAliases: aliases.sorted { $0.remoteLabelID.uuidString < $1.remoteLabelID.uuidString }
        )
    }

    /**
     Deletes the entire local bookmark-category graph before restore insertion begins.

     The delete order removes child rows before parent rows so the implementation does not depend
     on SwiftData delete-rule behavior for complete cleanup during destructive replace.

     - Parameter modelContext: SwiftData context whose bookmark-category graph should be cleared.
     - Side effects:
       - deletes bookmark-category models from the supplied `ModelContext`
     - Failure modes:
       - rethrows fetch errors when a model type cannot be read for deletion
     */
    private func deleteExistingBookmarkGraph(from modelContext: ModelContext) throws {
        try deleteAll(BibleBookmarkToLabel.self, from: modelContext)
        try deleteAll(GenericBookmarkToLabel.self, from: modelContext)
        try deleteAll(BibleBookmarkNotes.self, from: modelContext)
        try deleteAll(GenericBookmarkNotes.self, from: modelContext)
        try deleteAll(StudyPadTextEntryText.self, from: modelContext)
        try deleteAll(StudyPadTextEntry.self, from: modelContext)
        try deleteAll(BibleBookmark.self, from: modelContext)
        try deleteAll(GenericBookmark.self, from: modelContext)
        try deleteAll(Label.self, from: modelContext)
    }

    /**
     Fetches and deletes every row for one SwiftData model type.

     - Parameters:
       - type: SwiftData model type to delete.
       - modelContext: SwiftData context that owns the rows.
     - Side effects:
       - deletes all fetched rows of the supplied type from `modelContext`
     - Failure modes:
       - rethrows fetch errors when the model rows cannot be read
     */
    private func deleteAll<T: PersistentModel>(_ type: T.Type, from modelContext: ModelContext) throws {
        let rows = try modelContext.fetch(FetchDescriptor<T>())
        for row in rows {
            modelContext.delete(row)
        }
    }

    /**
     Ensures the three canonical iOS system labels exist after restore.

     Some Android datasets may omit unused system-label rows. iOS runtime bookmark flows assume the
     reserved labels can be resolved by deterministic UUID, so restore recreates any missing ones
     after inserting the staged snapshot labels.

     - Parameters:
       - modelContext: SwiftData context receiving any missing labels.
       - labelsByID: Mutable lookup table of already inserted labels keyed by local UUID.
     - Side effects:
       - inserts missing canonical system labels into `modelContext`
       - updates `labelsByID` with the inserted labels
     - Failure modes:
       - this helper does not throw; any later persistence failure is surfaced by `modelContext.save()`
     */
    private func ensureMissingSystemLabels(in modelContext: ModelContext, labelsByID: inout [UUID: Label]) {
        for (name, id) in Self.systemLabels {
            guard labelsByID[id] == nil else {
                continue
            }
            let label = Label(id: id, name: name)
            modelContext.insert(label)
            labelsByID[id] = label
        }
    }

    /**
     Verifies that the staged bookmark tables form a coherent snapshot before higher-level aggregation.

     The staged initial backup is read directly from SQLite rather than through Room or SwiftData,
     so this helper reconstructs the foreign-key expectations that the restore depends on. Notes may
     be absent because they are optional, but note rows, junction rows, primary-label references,
     and StudyPad text rows must always point at existing parents.

     - Parameters:
       - labels: Raw Android label rows.
       - bibleBookmarks: Raw Android Bible bookmark rows.
       - genericBookmarks: Raw Android generic bookmark rows.
       - bibleNotes: Raw Android Bible note rows.
       - genericNotes: Raw Android generic note rows.
       - bibleLinks: Raw Android Bible bookmark-to-label rows.
       - genericLinks: Raw Android generic bookmark-to-label rows.
       - studyPadEntries: Raw Android StudyPad entry rows.
       - studyPadTexts: Raw Android StudyPad text rows.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.orphanReferences` when any required reference is missing
     */
    private func validateSnapshotReferences(
        labels: [RemoteSyncAndroidLabel],
        bibleBookmarks: [RawBibleBookmarkRow],
        genericBookmarks: [RawGenericBookmarkRow],
        bibleNotes: [RemoteSyncCurrentBookmarkNoteRow],
        genericNotes: [RemoteSyncCurrentBookmarkNoteRow],
        bibleLinks: [(bookmarkID: UUID, labelID: UUID, orderNumber: Int, indentLevel: Int, expandContent: Bool)],
        genericLinks: [(bookmarkID: UUID, labelID: UUID, orderNumber: Int, indentLevel: Int, expandContent: Bool)],
        studyPadEntries: [RawStudyPadEntryRow],
        studyPadTexts: [(entryID: UUID, text: String)]
    ) throws {
        let labelIDs = Set(labels.map(\.id))
        let bibleBookmarkIDs = Set(bibleBookmarks.map(\.id))
        let genericBookmarkIDs = Set(genericBookmarks.map(\.id))
        let studyPadEntryIDs = Set(studyPadEntries.map(\.id))
        let studyPadTextIDs = Set(studyPadTexts.map(\.entryID))

        var issues: [String] = []

        for bookmark in bibleBookmarks {
            if let primaryLabelID = bookmark.primaryLabelID, !labelIDs.contains(primaryLabelID) {
                issues.append("BibleBookmark.primaryLabelId=\(primaryLabelID.uuidString) missing label for bookmark \(bookmark.id.uuidString)")
            }
        }
        for bookmark in genericBookmarks {
            if let primaryLabelID = bookmark.primaryLabelID, !labelIDs.contains(primaryLabelID) {
                issues.append("GenericBookmark.primaryLabelId=\(primaryLabelID.uuidString) missing label for bookmark \(bookmark.id.uuidString)")
            }
        }
        for note in bibleNotes where !bibleBookmarkIDs.contains(note.bookmarkID) {
            issues.append("BibleBookmarkNotes.bookmarkId=\(note.bookmarkID.uuidString) missing bookmark")
        }
        for note in genericNotes where !genericBookmarkIDs.contains(note.bookmarkID) {
            issues.append("GenericBookmarkNotes.bookmarkId=\(note.bookmarkID.uuidString) missing bookmark")
        }
        for link in bibleLinks {
            if !bibleBookmarkIDs.contains(link.bookmarkID) {
                issues.append("BibleBookmarkToLabel.bookmarkId=\(link.bookmarkID.uuidString) missing bookmark")
            }
            if !labelIDs.contains(link.labelID) {
                issues.append("BibleBookmarkToLabel.labelId=\(link.labelID.uuidString) missing label")
            }
        }
        for link in genericLinks {
            if !genericBookmarkIDs.contains(link.bookmarkID) {
                issues.append("GenericBookmarkToLabel.bookmarkId=\(link.bookmarkID.uuidString) missing bookmark")
            }
            if !labelIDs.contains(link.labelID) {
                issues.append("GenericBookmarkToLabel.labelId=\(link.labelID.uuidString) missing label")
            }
        }
        for entry in studyPadEntries where !labelIDs.contains(entry.labelID) {
            issues.append("StudyPadTextEntry.labelId=\(entry.labelID.uuidString) missing label for entry \(entry.id.uuidString)")
        }
        for text in studyPadTexts where !studyPadEntryIDs.contains(text.entryID) {
            issues.append("StudyPadTextEntryText.studyPadTextEntryId=\(text.entryID.uuidString) missing StudyPadTextEntry")
        }
        for entry in studyPadEntries where !studyPadTextIDs.contains(entry.id) {
            issues.append("StudyPadTextEntry.id=\(entry.id.uuidString) missing StudyPadTextEntryText")
        }

        if !issues.isEmpty {
            throw RemoteSyncBookmarkRestoreError.orphanReferences(Array(Set(issues)).sorted())
        }
    }

    /**
     Verifies that one required Android bookmark table exists in the staged SQLite database.

     - Parameters:
       - tableName: Required Android table name.
       - db: Open staged SQLite database handle.
     - Side effects:
       - executes one `sqlite_master` lookup against the staged database
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the lookup cannot be prepared
       - throws `RemoteSyncBookmarkRestoreError.missingTable` when the named table does not exist
     */
    private func requireTable(named tableName: String, in db: OpaquePointer) throws {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }

        sqlite3_bind_text(statement, 1, tableName, -1, remoteSyncSQLiteTransient)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            throw RemoteSyncBookmarkRestoreError.missingTable(tableName)
        }
    }

    /**
     Checks whether an optional Android column is present before selecting it from a staged backup.

     Android backup schemas evolve with Room migrations. Restores must accept older staged databases
     that do not yet have nullable metadata columns while preserving the column when it is present.

     - Parameters:
       - columnName: SQLite column name to look up.
       - tableName: SQLite table name whose schema should be inspected.
       - db: Open staged SQLite database handle.
     - Returns: `true` when `PRAGMA table_info` reports the column; otherwise `false`.
     - Side effects:
       - executes one SQLite schema query against the staged database
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the schema query cannot be prepared
     */
    private func tableHasColumn(
        _ columnName: String,
        in tableName: String,
        database db: OpaquePointer
    ) throws -> Bool {
        let sql = "PRAGMA table_info(\(tableName))"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            if stringColumn(statement: statement, index: 1) == columnName {
                return true
            }
        }
        return false
    }

    /**
     Reads all staged Android label rows from the `Label` table.

     - Parameter db: Open staged SQLite database handle.
     - Returns: Decoded Android label rows.
     - Side effects:
       - executes one SQLite query against the staged database
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when one label ID BLOB is malformed
     */
    private func fetchLabels(from db: OpaquePointer) throws -> [RemoteSyncAndroidLabel] {
        let sql = """
        SELECT id, name, color, markerStyle, markerStyleWholeVerse, underlineStyle,
               underlineStyleWholeVerse, hideStyle, hideStyleWholeVerse, favourite, type, customIcon
        FROM Label
        ORDER BY name, id
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }

        var rows: [RemoteSyncAndroidLabel] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                RemoteSyncAndroidLabel(
                    id: try uuidFromBlob(statement: statement, column: 0, table: "Label", name: "id"),
                    name: stringColumn(statement: statement, index: 1),
                    color: Int(sqlite3_column_int(statement, 2)),
                    markerStyle: boolColumn(statement: statement, index: 3),
                    markerStyleWholeVerse: boolColumn(statement: statement, index: 4),
                    underlineStyle: boolColumn(statement: statement, index: 5),
                    underlineStyleWholeVerse: boolColumn(statement: statement, index: 6),
                    hideStyle: boolColumn(statement: statement, index: 7),
                    hideStyleWholeVerse: boolColumn(statement: statement, index: 8),
                    favourite: boolColumn(statement: statement, index: 9),
                    type: optionalStringColumn(statement: statement, index: 10),
                    customIcon: optionalStringColumn(statement: statement, index: 11)
                )
            )
        }
        return rows
    }

    /**
     Reads all staged Android Bible bookmark rows from the `BibleBookmark` table.

     - Parameter db: Open staged SQLite database handle.
     - Returns: Raw Android Bible bookmark rows before note/link aggregation.
     - Side effects:
       - executes one SQLite query against the staged database
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when one bookmark or label ID BLOB is malformed
     */
    private func fetchBibleBookmarks(from db: OpaquePointer) throws -> [RawBibleBookmarkRow] {
        let sql = """
        SELECT id, kjvOrdinalStart, kjvOrdinalEnd, ordinalStart, ordinalEnd, v11n, playbackSettings,
               createdAt, book, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse,
               type, customIcon, editAction_mode, editAction_content
        FROM BibleBookmark
        ORDER BY createdAt, id
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }

        var rows: [RawBibleBookmarkRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                RawBibleBookmarkRow(
                    id: try uuidFromBlob(statement: statement, column: 0, table: "BibleBookmark", name: "id"),
                    kjvOrdinalStart: Int(sqlite3_column_int(statement, 1)),
                    kjvOrdinalEnd: Int(sqlite3_column_int(statement, 2)),
                    ordinalStart: Int(sqlite3_column_int(statement, 3)),
                    ordinalEnd: Int(sqlite3_column_int(statement, 4)),
                    v11n: stringColumn(statement: statement, index: 5),
                    playbackSettingsJSON: optionalStringColumn(statement: statement, index: 6),
                    createdAt: dateFromMillisecondsColumn(statement: statement, index: 7),
                    book: optionalStringColumn(statement: statement, index: 8),
                    startOffset: optionalIntColumn(statement: statement, index: 9),
                    endOffset: optionalIntColumn(statement: statement, index: 10),
                    primaryLabelID: try optionalUUIDFromBlob(statement: statement, column: 11, table: "BibleBookmark", name: "primaryLabelId"),
                    lastUpdatedOn: dateFromMillisecondsColumn(statement: statement, index: 12),
                    wholeVerse: boolColumn(statement: statement, index: 13),
                    type: optionalStringColumn(statement: statement, index: 14),
                    customIcon: optionalStringColumn(statement: statement, index: 15),
                    editAction: editAction(
                        mode: optionalStringColumn(statement: statement, index: 16),
                        content: optionalStringColumn(statement: statement, index: 17)
                    )
                )
            )
        }
        return rows
    }

    /**
     Reads all staged Android generic bookmark rows from the `GenericBookmark` table.

     - Parameter db: Open staged SQLite database handle.
     - Returns: Raw Android generic bookmark rows before note/link aggregation.
     - Side effects:
       - executes one SQLite query against the staged database
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when one bookmark or label ID BLOB is malformed
     */
    private func fetchGenericBookmarks(from db: OpaquePointer) throws -> [RawGenericBookmarkRow] {
        let sql = """
        SELECT id, `key`, createdAt, bookInitials, ordinalStart, ordinalEnd, startOffset, endOffset,
               primaryLabelId, lastUpdatedOn, wholeVerse, playbackSettings, customIcon,
               editAction_mode, editAction_content
        FROM GenericBookmark
        ORDER BY createdAt, id
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }

        var rows: [RawGenericBookmarkRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                RawGenericBookmarkRow(
                    id: try uuidFromBlob(statement: statement, column: 0, table: "GenericBookmark", name: "id"),
                    key: stringColumn(statement: statement, index: 1),
                    createdAt: dateFromMillisecondsColumn(statement: statement, index: 2),
                    bookInitials: stringColumn(statement: statement, index: 3),
                    ordinalStart: Int(sqlite3_column_int(statement, 4)),
                    ordinalEnd: Int(sqlite3_column_int(statement, 5)),
                    startOffset: optionalIntColumn(statement: statement, index: 6),
                    endOffset: optionalIntColumn(statement: statement, index: 7),
                    primaryLabelID: try optionalUUIDFromBlob(statement: statement, column: 8, table: "GenericBookmark", name: "primaryLabelId"),
                    lastUpdatedOn: dateFromMillisecondsColumn(statement: statement, index: 9),
                    wholeVerse: boolColumn(statement: statement, index: 10),
                    playbackSettingsJSON: optionalStringColumn(statement: statement, index: 11),
                    customIcon: optionalStringColumn(statement: statement, index: 12),
                    editAction: editAction(
                        mode: optionalStringColumn(statement: statement, index: 13),
                        content: optionalStringColumn(statement: statement, index: 14)
                    )
                )
            )
        }
        return rows
    }

    /**
     Reads detached bookmark-note rows from one Android note table.

     - Parameters:
       - db: Open staged SQLite database handle.
       - tableName: Either `BibleBookmarkNotes` or `GenericBookmarkNotes`.
     - Returns: Bookmark identifier and note-text pairs.
     - Side effects:
       - executes one SQLite query against the staged database
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when one bookmark ID BLOB is malformed
       - throws `RemoteSyncBookmarkRestoreError.invalidColumnValue` when one non-null
         `contentType` value is not an Android `TextContentType`
     */
    private func fetchNoteRows(
        from db: OpaquePointer,
        tableName: String
    ) throws -> [RemoteSyncCurrentBookmarkNoteRow] {
        let hasContentType = try tableHasColumn("contentType", in: tableName, database: db)
        let sql = hasContentType
            ? "SELECT bookmarkId, notes, contentType FROM \(tableName) ORDER BY bookmarkId"
            : "SELECT bookmarkId, notes FROM \(tableName) ORDER BY bookmarkId"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }

        var rows: [RemoteSyncCurrentBookmarkNoteRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                RemoteSyncCurrentBookmarkNoteRow(
                    bookmarkID: try uuidFromBlob(statement: statement, column: 0, table: tableName, name: "bookmarkId"),
                    notes: stringColumn(statement: statement, index: 1),
                    contentType: hasContentType
                        ? try optionalNotesContentTypeColumn(statement: statement, index: 2, table: tableName, name: "contentType")
                        : nil
                )
            )
        }
        return rows
    }

    /**
     Reads bookmark-to-label junction rows from one Android label-link table.

     - Parameters:
       - db: Open staged SQLite database handle.
       - tableName: Either `BibleBookmarkToLabel` or `GenericBookmarkToLabel`.
     - Returns: Raw junction rows with ordering metadata preserved.
     - Side effects:
       - executes one SQLite query against the staged database
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when one bookmark or label ID BLOB is malformed
     */
    private func fetchLabelLinks(
        from db: OpaquePointer,
        tableName: String
    ) throws -> [(bookmarkID: UUID, labelID: UUID, orderNumber: Int, indentLevel: Int, expandContent: Bool)] {
        let sql = "SELECT bookmarkId, labelId, orderNumber, indentLevel, expandContent FROM \(tableName) ORDER BY bookmarkId, orderNumber, labelId"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }

        var rows: [(bookmarkID: UUID, labelID: UUID, orderNumber: Int, indentLevel: Int, expandContent: Bool)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                (
                    bookmarkID: try uuidFromBlob(statement: statement, column: 0, table: tableName, name: "bookmarkId"),
                    labelID: try uuidFromBlob(statement: statement, column: 1, table: tableName, name: "labelId"),
                    orderNumber: Int(sqlite3_column_int(statement, 2)),
                    indentLevel: Int(sqlite3_column_int(statement, 3)),
                    expandContent: boolColumn(statement: statement, index: 4)
                )
            )
        }
        return rows
    }

    /**
     Reads staged Android StudyPad entry rows from the `StudyPadTextEntry` table.

     - Parameter db: Open staged SQLite database handle.
     - Returns: Raw StudyPad entry rows before text aggregation.
     - Side effects:
       - executes one SQLite query against the staged database
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when one entry or label ID BLOB is malformed
       - throws `RemoteSyncBookmarkRestoreError.invalidColumnValue` when one non-null
         `contentType` value is not an Android `TextContentType`
     */
    private func fetchStudyPadEntries(from db: OpaquePointer) throws -> [RawStudyPadEntryRow] {
        let hasContentType = try tableHasColumn("contentType", in: "StudyPadTextEntry", database: db)
        let sql = hasContentType
            ? "SELECT id, labelId, orderNumber, indentLevel, contentType FROM StudyPadTextEntry ORDER BY orderNumber, id"
            : "SELECT id, labelId, orderNumber, indentLevel FROM StudyPadTextEntry ORDER BY orderNumber, id"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }

        var rows: [RawStudyPadEntryRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                RawStudyPadEntryRow(
                    id: try uuidFromBlob(statement: statement, column: 0, table: "StudyPadTextEntry", name: "id"),
                    labelID: try uuidFromBlob(statement: statement, column: 1, table: "StudyPadTextEntry", name: "labelId"),
                    orderNumber: Int(sqlite3_column_int(statement, 2)),
                    indentLevel: Int(sqlite3_column_int(statement, 3)),
                    contentType: hasContentType
                        ? try optionalNotesContentTypeColumn(statement: statement, index: 4, table: "StudyPadTextEntry", name: "contentType")
                        : nil
                )
            )
        }
        return rows
    }

    /**
     Reads staged Android StudyPad text rows from the `StudyPadTextEntryText` table.

     - Parameter db: Open staged SQLite database handle.
     - Returns: StudyPad entry identifier and text payload pairs.
     - Side effects:
       - executes one SQLite query against the staged database
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when one entry ID BLOB is malformed
     */
    private func fetchStudyPadTexts(from db: OpaquePointer) throws -> [(entryID: UUID, text: String)] {
        let sql = "SELECT studyPadTextEntryId, text FROM StudyPadTextEntryText ORDER BY studyPadTextEntryId"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }

        var rows: [(entryID: UUID, text: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                (
                    entryID: try uuidFromBlob(statement: statement, column: 0, table: "StudyPadTextEntryText", name: "studyPadTextEntryId"),
                    text: stringColumn(statement: statement, index: 1)
                )
            )
        }
        return rows
    }

    /**
     Converts one required Android 16-byte identifier BLOB into an iOS `UUID`.

     Android's `IdType` persists the raw 128-bit payload as a SQLite BLOB without textual UUID
     formatting. This helper reconstructs the canonical UUID string layout from the 16-byte payload
     so higher layers can use Foundation `UUID` values consistently.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - column: Zero-based column index containing the required 16-byte BLOB.
       - table: Android table name used for error reporting.
       - name: Column name used for error reporting.
     - Returns: Converted Foundation `UUID` value.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when the BLOB is absent,
         not 16 bytes long, or cannot be converted into a valid UUID string
     */
    private func uuidFromBlob(statement: OpaquePointer?, column: Int32, table: String, name: String) throws -> UUID {
        guard let bytes = sqlite3_column_blob(statement, column), sqlite3_column_bytes(statement, column) == 16 else {
            throw RemoteSyncBookmarkRestoreError.invalidIdentifierBlob(table: table, column: name)
        }

        let data = Data(bytes: bytes, count: 16)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let part1 = String(hex.prefix(8))
        let part2 = String(hex.dropFirst(8).prefix(4))
        let part3 = String(hex.dropFirst(12).prefix(4))
        let part4 = String(hex.dropFirst(16).prefix(4))
        let part5 = String(hex.dropFirst(20).prefix(12))
        let uuidString = "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)"

        guard let uuid = UUID(uuidString: uuidString) else {
            throw RemoteSyncBookmarkRestoreError.invalidIdentifierBlob(table: table, column: name)
        }
        return uuid
    }

    /**
     Converts one optional Android identifier BLOB into an iOS `UUID`.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - column: Zero-based column index containing the optional BLOB.
       - table: Android table name used for error reporting.
       - name: Column name used for error reporting.
     - Returns: Converted `UUID`, or `nil` when the SQLite column is `NULL`.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidIdentifierBlob` when a non-null BLOB is not a valid 16-byte Android identifier
     */
    private func optionalUUIDFromBlob(statement: OpaquePointer?, column: Int32, table: String, name: String) throws -> UUID? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return try uuidFromBlob(statement: statement, column: column, table: table, name: name)
    }

    /**
     Reads one required SQLite text column as a Swift `String`.

     Android sync tables represent several required columns as `TEXT NOT NULL`. This helper treats
     an unexpected SQLite `NULL` as an empty string so snapshot parsing remains total and the later
     validation layer can decide whether the resulting value is acceptable.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - index: Zero-based text column index.
     - Returns: Decoded UTF-8 string, or an empty string when SQLite returned `NULL`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func stringColumn(statement: OpaquePointer?, index: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: raw)
    }

    /**
     Reads one optional SQLite text column as a Swift `String`.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - index: Zero-based text column index.
     - Returns: Decoded UTF-8 string, or `nil` when SQLite returned `NULL`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func optionalStringColumn(statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: raw)
    }

    /**
     Reads and validates one optional Android note `TextContentType` column.

     Android Room maps non-null note content-type values through `TextContentType.valueOf`, so a
     staged sync database containing any string other than `HTML` or `MARKDOWN` is not a valid
     Android bookmark database. `nil` is still valid and means the row inherits the global setting.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - index: Zero-based text column index.
       - table: Android table name used for error reporting.
       - name: Android column name used for error reporting.
     - Returns: `nil`, `HTML`, or `MARKDOWN`.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncBookmarkRestoreError.invalidColumnValue` when a non-null value is not
         one of Android's `TextContentType` enum cases.
     */
    private func optionalNotesContentTypeColumn(
        statement: OpaquePointer?,
        index: Int32,
        table: String,
        name: String
    ) throws -> String? {
        let rawValue = optionalStringColumn(statement: statement, index: index)
        guard AppPreferenceValueNormalizer.isValidNotesContentTypeRow(rawValue) else {
            throw RemoteSyncBookmarkRestoreError.invalidColumnValue(table: table, column: name)
        }
        return AppPreferenceValueNormalizer.notesContentTypeRow(rawValue)
    }

    /**
     Reads one optional SQLite integer column as a Swift `Int`.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - index: Zero-based integer column index.
     - Returns: Integer value, or `nil` when SQLite returned `NULL`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func optionalIntColumn(statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int(statement, index))
    }

    /**
     Reads one SQLite integer column as a `Bool` using Android's `0`/`1` convention.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - index: Zero-based integer column index.
     - Returns: `true` when the integer value is non-zero; otherwise `false`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func boolColumn(statement: OpaquePointer?, index: Int32) -> Bool {
        sqlite3_column_int(statement, index) != 0
    }

    /**
     Reads one SQLite millisecond-since-epoch column as a Foundation `Date`.

     Android bookmark tables persist timestamps as Unix milliseconds. This helper applies the
     correct `/ 1000` conversion so restore preserves the original chronology rather than treating
     the raw integers as seconds.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - index: Zero-based integer column index.
     - Returns: Foundation `Date` converted from Unix milliseconds.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func dateFromMillisecondsColumn(statement: OpaquePointer?, index: Int32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, index)) / 1000.0)
    }

    /**
     Reconstructs an optional bookmark edit-action descriptor from Android's embedded columns.

     Android stores `EditAction` as two flattened columns via Room's `@Embedded(prefix = "editAction_")`.
     This helper restores the equivalent iOS `EditAction` shape while tolerating unknown enum raw
     values by degrading only the mode field instead of failing the entire bookmark import.

     - Parameters:
       - mode: Optional Android raw `EditActionMode` string.
       - content: Optional Android edit-action content payload.
     - Returns: Restored `EditAction`, or `nil` when both embedded columns were null.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func editAction(mode: String?, content: String?) -> EditAction? {
        guard mode != nil || content != nil else {
            return nil
        }
        return EditAction(mode: mode.flatMap(EditActionMode.init(rawValue:)), content: content)
    }

    /**
     Projects Android bookmark playback JSON onto the subset currently modeled by iOS.

     The current iOS bookmark model only persists `PlaybackSettings.bookId`. Android stores a much
     richer JSON object containing speech preferences and optional repeat ranges. This helper pulls
     out the `bookId` field when it can decode it and otherwise returns `nil`; the caller preserves
     the full raw JSON separately so no Android fidelity is silently lost.

     - Parameter playbackSettingsJSON: Raw Android `playbackSettings` JSON payload.
     - Returns: Projected iOS `PlaybackSettings`, or `nil` when the payload is absent or does not expose a usable `bookId`.
     - Side effects: none.
     - Failure modes: Malformed JSON degrades to `nil` instead of throwing because the raw payload is preserved separately.
     */
    private func projectPlaybackSettings(from playbackSettingsJSON: String?) -> PlaybackSettings? {
        guard let playbackSettingsJSON, !playbackSettingsJSON.isEmpty,
              let data = playbackSettingsJSON.data(using: .utf8),
              let projection = try? JSONDecoder().decode(AndroidPlaybackSettingsProjection.self, from: data),
              let bookID = projection.bookId,
              !bookID.isEmpty else {
            return nil
        }
        return PlaybackSettings(bookId: bookID)
    }

    /**
     Sorts bookmark-to-label links deterministically for snapshot stability.

     Android stores explicit ordering metadata on junction rows. The snapshot keeps those values,
     and this helper ensures unit tests and later restore logic see a stable ordering when multiple
     links share the same order number.

     - Parameters:
       - lhs: Left-hand label link.
       - rhs: Right-hand label link.
     - Returns: `true` when `lhs` should sort before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func sortLabelLinks(
        _ lhs: RemoteSyncAndroidBookmarkLabelLink,
        _ rhs: RemoteSyncAndroidBookmarkLabelLink
    ) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            return lhs.labelID.uuidString < rhs.labelID.uuidString
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    /**
     Returns whether the supplied label name is one of the reserved system-label markers.

     - Parameter name: Label name from the staged Android snapshot.
     - Returns: `true` for speak, unlabeled, or paragraph-break labels.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func isSystemLabelName(_ name: String) -> Bool {
        systemLabelNames.contains(name)
    }

    /**
     Returns the canonical iOS UUID for one reserved system-label name.

     - Parameter name: Label name from the staged Android snapshot.
     - Returns: Deterministic canonical UUID for reserved labels, or `nil` for normal user labels.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func canonicalSystemLabelID(for name: String) -> UUID? {
        systemLabels.first(where: { $0.name == name })?.id
    }

    private static let systemLabels: [(name: String, id: UUID)] = [
        (Label.speakLabelName, Label.speakLabelId),
        (Label.unlabeledName, Label.unlabeledId),
        (Label.paragraphBreakLabelName, Label.paragraphBreakLabelId),
    ]

    private static let systemLabelNames = Set(systemLabels.map(\.name))
}
