// Bookmark.swift -- Bookmark domain models

import Foundation
import SwiftData

/**
 Enumerates persisted bookmark type identifiers mirrored from Android parity data.

 The raw values are stored as strings on bookmark entities and interpreted by higher layers.
 This enum currently documents the known cases without adding additional behavior.
 */
public enum BookmarkType: String, Codable, Sendable, Equatable {
    case example = "EXAMPLE"
}

/**
 Enumerates the note-edit merge modes used by bookmark automation features.

 The raw values are stored in `EditAction` and interpreted by UI or import flows when
 appending or prepending generated content.
 */
public enum EditActionMode: String, Codable, Sendable, Equatable {
    case append = "APPEND"
    case prepend = "PREPEND"
}

/**
 Stores an optional bookmark note-edit instruction.

 The struct is embedded inside bookmark entities. It has no side effects on its own; any note
 mutation occurs when a caller interprets the stored configuration and writes bookmark notes.
 */
public struct EditAction: Codable, Sendable, Equatable {
    /// Selected edit mode that determines how new content should be merged into notes.
    public var mode: EditActionMode?

    /// Text payload to append or prepend when the action is executed.
    public var content: String?

    /**
     Creates an edit-action descriptor.

     - Parameters:
       - mode: Merge mode for the future note update.
       - content: Payload that should be written when the action is executed.
     */
    public init(mode: EditActionMode? = nil, content: String? = nil) {
        self.mode = mode
        self.content = content
    }
}

/**
 Stores optional text-to-speech playback metadata for a bookmark.

 The struct is serialized into bookmark records so reading/speak flows can resume from the
 correct module context without additional lookup state.
 */
public struct PlaybackSettings: Codable, Sendable, Equatable {
    /// Optional module/book identifier used by TTS playback and resume logic.
    public var bookId: String?

    /**
     Creates playback metadata for a bookmark.

     - Parameter bookId: Optional module or book identifier tied to the playback state.
     */
    public init(bookId: String? = nil) {
        self.bookId = bookId
    }
}

/**
 Enumerates the sort orders supported by bookmark queries and list UI.

 The raw values mirror Android parity strings so stored preferences and bridge state can be
 shared without translation.
 */
public enum BookmarkSortOrder: String, Codable, Sendable {
    case bibleOrder = "BIBLE_ORDER"
    case bibleOrderDesc = "BIBLE_ORDER_DESC"
    case createdAt = "CREATED_AT"
    case createdAtDesc = "CREATED_AT_DESC"
    case lastUpdated = "LAST_UPDATED"
    case orderNumber = "ORDER_NUMBER"
}

/**
 Persists a bookmark that targets Bible text using verse ordinals.

 Bible bookmarks store both module-local ordinals and KJVA ordinals. The module-local values
 preserve the exact original range in the source versification, while the KJVA values provide
 a stable cross-module comparison key for queries, labels, and sync. Related note and label
 junction rows are cascade-deleted with the bookmark.
 */
@Model
public final class BibleBookmark {
    /// Unique identifier used for persistence, label linking, and sync reconciliation.
    @Attribute(.unique) public var id: UUID

    /// Start ordinal normalized into KJVA versification for cross-module queries.
    public var kjvOrdinalStart: Int

    /// End ordinal normalized into KJVA versification for cross-module queries.
    public var kjvOrdinalEnd: Int

    /// Start ordinal in the originating module's own versification.
    public var ordinalStart: Int

    /// End ordinal in the originating module's own versification.
    public var ordinalEnd: Int

    /// Raw versification identifier for the originating module.
    public var v11n: String

    /// Optional book name captured at creation time for display and legacy lookup paths.
    public var book: String?

    /// Optional text-to-speech playback metadata for this bookmark.
    public var playbackSettings: PlaybackSettings?

    /// Creation timestamp used by sorting and export flows.
    public var createdAt: Date

    /// Character offset recorded for the start of a sub-verse selection, if any.
    public var startOffset: Int?

    /// Character offset recorded for the end of a sub-verse selection, if any.
    public var endOffset: Int?

    /// Cached primary label identifier used by fast list and renderer lookups.
    public var primaryLabelId: UUID?

    /// Timestamp of the last bookmark mutation.
    public var lastUpdatedOn: Date

    /// Indicates whether the bookmark covers a whole verse instead of a text span.
    public var wholeVerse: Bool

    /// Optional raw bookmark type string used by specialized features.
    public var type: String?

    /// Optional Android canonical icon name or older native icon identifier.
    public var customIcon: String?

    /// Optional note-edit automation configuration.
    public var editAction: EditAction?

    /// Separate note payload entity owned by this bookmark and cascade-deleted with it.
    @Relationship(deleteRule: .cascade, inverse: \BibleBookmarkNotes.bookmark)
    public var notes: BibleBookmarkNotes?

    /// Many-to-many label junction rows owned by this bookmark.
    @Relationship(deleteRule: .cascade, inverse: \BibleBookmarkToLabel.bookmark)
    public var bookmarkToLabels: [BibleBookmarkToLabel]?

    /**
     Creates a Bible bookmark persistence record.

     - Parameters:
       - id: Stable identifier for persistence and sync.
       - kjvOrdinalStart: KJVA-normalized start ordinal.
       - kjvOrdinalEnd: KJVA-normalized end ordinal.
       - ordinalStart: Source-versification start ordinal.
       - ordinalEnd: Source-versification end ordinal.
       - v11n: Raw source versification identifier.
       - createdAt: Bookmark creation timestamp.
       - lastUpdatedOn: Timestamp of the latest mutation.
       - wholeVerse: Whether the bookmark covers an entire verse.
     - Note: Optional metadata such as notes, labels, offsets, and playback settings are added
       after insertion by the owning service layer.
     */
    public init(
        id: UUID = UUID(),
        kjvOrdinalStart: Int = 0,
        kjvOrdinalEnd: Int = 0,
        ordinalStart: Int = 0,
        ordinalEnd: Int = 0,
        v11n: String = "KJVA",
        createdAt: Date = Date(),
        lastUpdatedOn: Date = Date(),
        wholeVerse: Bool = true
    ) {
        self.id = id
        self.kjvOrdinalStart = kjvOrdinalStart
        self.kjvOrdinalEnd = kjvOrdinalEnd
        self.ordinalStart = ordinalStart
        self.ordinalEnd = ordinalEnd
        self.v11n = v11n
        self.createdAt = createdAt
        self.lastUpdatedOn = lastUpdatedOn
        self.wholeVerse = wholeVerse
    }
}

/**
 Stores the note body for a `BibleBookmark` in a separate entity.

 The split keeps bookmark list queries lighter because note text does not need to be loaded
 unless the caller explicitly requests it. `contentType` mirrors Android's nullable
 `TextContentType` column so legacy rows can continue inheriting the current app setting while
 newly saved rows preserve whether their note text is HTML or Markdown.
 */
@Model
public final class BibleBookmarkNotes {
    /// Identifier mirroring the owning bookmark for the intended 1:1 relationship.
    @Attribute(.unique) public var bookmarkId: UUID

    /// Back-reference to the owning Bible bookmark.
    public var bookmark: BibleBookmark?

    /// User-authored note text associated with the bookmark.
    public var notes: String

    /// Optional Android `TextContentType` raw value (`HTML` or `MARKDOWN`) for the note body.
    public var contentType: String?

    /**
     Creates a note payload for a Bible bookmark.

     - Parameters:
       - bookmarkId: Identifier of the owning bookmark.
       - notes: Stored note body.
       - contentType: Optional Android `TextContentType` raw value; invalid non-nil values are
         normalized to the app default.
     */
    public init(bookmarkId: UUID, notes: String = "", contentType: String? = nil) {
        self.bookmarkId = bookmarkId
        self.notes = notes
        self.contentType = contentType.map(AppPreferenceValueNormalizer.notesContentType)
    }
}

/**
 Joins a `BibleBookmark` to a `Label` for many-to-many bookmark labeling.

 The row also stores StudyPad ordering metadata so label-based bookmark views can preserve the
 user-defined outline order without mutating the bookmark itself.
 */
@Model
public final class BibleBookmarkToLabel {
    /// Owning bookmark side of the many-to-many label relationship.
    public var bookmark: BibleBookmark?

    /// Label side of the many-to-many bookmark relationship.
    public var label: Label?

    /// Display order within label-focused lists and StudyPad views.
    public var orderNumber: Int

    /// Nesting level used by label/StudyPad outline rendering.
    public var indentLevel: Int

    /// Whether child content for this row is expanded in StudyPad-like views.
    public var expandContent: Bool

    /**
     Creates a Bible bookmark-to-label junction row.

     - Parameters:
       - orderNumber: Display order within the label context.
       - indentLevel: Outline indentation level.
       - expandContent: Whether the row's content starts expanded.
     */
    public init(
        orderNumber: Int = -1,
        indentLevel: Int = 0,
        expandContent: Bool = true
    ) {
        self.orderNumber = orderNumber
        self.indentLevel = indentLevel
        self.expandContent = expandContent
    }
}

/**
 Persists a bookmark that targets non-Bible documents by module key rather than Bible ordinals.

 Generic bookmarks are used for dictionaries, commentaries, maps, EPUB content, and other
 keyed documents. They still keep ordinal and offset metadata when available so list ordering
 and partial-selection behavior can remain consistent across document categories.
 */
@Model
public final class GenericBookmark {
    /// Unique identifier used for persistence, label linking, and sync reconciliation.
    @Attribute(.unique) public var id: UUID

    /// Canonical document key or OSIS-style reference for the bookmarked entry.
    public var key: String

    /// Module initials for the bookmarked document.
    public var bookInitials: String

    /// Creation timestamp used by sorting and export flows.
    public var createdAt: Date

    /// Start ordinal within the target document, or `0` when unavailable.
    public var ordinalStart: Int

    /// End ordinal within the target document, or `0` when unavailable.
    public var ordinalEnd: Int

    /// Inclusive character offset at the start of a partial selection, if any.
    public var startOffset: Int?

    /// Exclusive or terminal character offset at the end of a partial selection, if any.
    public var endOffset: Int?

    /// Cached primary label identifier used by fast list and renderer lookups.
    public var primaryLabelId: UUID?

    /// Timestamp of the last bookmark mutation.
    public var lastUpdatedOn: Date

    /// Indicates whether the bookmark covers the entire keyed entry instead of a text span.
    public var wholeVerse: Bool

    /// Optional text-to-speech playback metadata for this bookmark.
    public var playbackSettings: PlaybackSettings?

    /// Optional Android canonical icon name or older native icon identifier.
    public var customIcon: String?

    /// Optional note-edit automation configuration.
    public var editAction: EditAction?

    /// Separate note payload entity owned by this bookmark and cascade-deleted with it.
    @Relationship(deleteRule: .cascade, inverse: \GenericBookmarkNotes.bookmark)
    public var notes: GenericBookmarkNotes?

    /// Many-to-many label junction rows owned by this bookmark.
    @Relationship(deleteRule: .cascade, inverse: \GenericBookmarkToLabel.bookmark)
    public var bookmarkToLabels: [GenericBookmarkToLabel]?

    /**
     Creates a generic bookmark persistence record.

     - Parameters:
       - id: Stable identifier for persistence and sync.
       - key: Canonical document key or OSIS-style reference.
       - bookInitials: Module initials for the target document.
       - createdAt: Bookmark creation timestamp.
       - ordinalStart: Start ordinal when the document exposes one.
       - ordinalEnd: End ordinal when the document exposes one.
       - lastUpdatedOn: Timestamp of the latest mutation.
       - wholeVerse: Whether the bookmark covers the entire entry.
     - Note: Optional metadata such as notes, labels, offsets, and playback settings are added
       after insertion by the owning service layer.
     */
    public init(
        id: UUID = UUID(),
        key: String = "",
        bookInitials: String = "",
        createdAt: Date = Date(),
        ordinalStart: Int = 0,
        ordinalEnd: Int = 0,
        lastUpdatedOn: Date = Date(),
        wholeVerse: Bool = true
    ) {
        self.id = id
        self.key = key
        self.bookInitials = bookInitials
        self.createdAt = createdAt
        self.ordinalStart = ordinalStart
        self.ordinalEnd = ordinalEnd
        self.lastUpdatedOn = lastUpdatedOn
        self.wholeVerse = wholeVerse
    }
}

/**
 Stores the note body for a `GenericBookmark` in a separate entity.

 Splitting the note payload keeps generic-bookmark list queries lighter until the caller needs
 the note body. The nullable `contentType` field mirrors Android so imported or synced notes
 retain the editor/rendering mode that was active when the note was first created.
 */
@Model
public final class GenericBookmarkNotes {
    /// Identifier mirroring the owning bookmark for the intended 1:1 relationship.
    @Attribute(.unique) public var bookmarkId: UUID

    /// Back-reference to the owning generic bookmark.
    public var bookmark: GenericBookmark?

    /// User-authored note text associated with the bookmark.
    public var notes: String

    /// Optional Android `TextContentType` raw value (`HTML` or `MARKDOWN`) for the note body.
    public var contentType: String?

    /**
     Creates a note payload for a generic bookmark.

     - Parameters:
       - bookmarkId: Identifier of the owning bookmark.
       - notes: Stored note body.
       - contentType: Optional Android `TextContentType` raw value; invalid non-nil values are
         normalized to the app default.
     */
    public init(bookmarkId: UUID, notes: String = "", contentType: String? = nil) {
        self.bookmarkId = bookmarkId
        self.notes = notes
        self.contentType = contentType.map(AppPreferenceValueNormalizer.notesContentType)
    }
}

/**
 Joins a `GenericBookmark` to a `Label` for many-to-many bookmark labeling.

 The row mirrors `BibleBookmarkToLabel` so label-focused screens can sort and nest generic and
 Bible bookmarks using the same outline metadata.
 */
@Model
public final class GenericBookmarkToLabel {
    /// Owning bookmark side of the many-to-many label relationship.
    public var bookmark: GenericBookmark?

    /// Label side of the many-to-many bookmark relationship.
    public var label: Label?

    /// Display order within label-focused lists and StudyPad views.
    public var orderNumber: Int

    /// Nesting level used by label/StudyPad outline rendering.
    public var indentLevel: Int

    /// Whether child content for this row is expanded in StudyPad-like views.
    public var expandContent: Bool

    /**
     Creates a generic bookmark-to-label junction row.

     - Parameters:
       - orderNumber: Display order within the label context.
       - indentLevel: Outline indentation level.
       - expandContent: Whether the row's content starts expanded.
     */
    public init(
        orderNumber: Int = -1,
        indentLevel: Int = 0,
        expandContent: Bool = true
    ) {
        self.orderNumber = orderNumber
        self.indentLevel = indentLevel
        self.expandContent = expandContent
    }
}
