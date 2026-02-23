// Bookmark.swift — Bookmark domain models

import Foundation
import SwiftData

/// Type of bookmark.
public enum BookmarkType: String, Codable, Sendable {
    case example = "EXAMPLE"
}

/// Edit action mode for bookmark note editing.
public enum EditActionMode: String, Codable, Sendable {
    case append = "APPEND"
    case prepend = "PREPEND"
}

/// An edit action configuration for bookmarks.
public struct EditAction: Codable, Sendable {
    public var mode: EditActionMode?
    public var content: String?

    public init(mode: EditActionMode? = nil, content: String? = nil) {
        self.mode = mode
        self.content = content
    }
}

/// Playback settings for TTS on a bookmark.
public struct PlaybackSettings: Codable, Sendable {
    public var bookId: String?

    public init(bookId: String? = nil) {
        self.bookId = bookId
    }
}

/// Sort order for bookmark lists.
public enum BookmarkSortOrder: String, Codable, Sendable {
    case bibleOrder = "BIBLE_ORDER"
    case bibleOrderDesc = "BIBLE_ORDER_DESC"
    case createdAt = "CREATED_AT"
    case createdAtDesc = "CREATED_AT_DESC"
    case lastUpdated = "LAST_UPDATED"
    case orderNumber = "ORDER_NUMBER"
}

/// A bookmark on a Bible passage (verse-ordinal based).
@Model
public final class BibleBookmark {
    /// UUID primary key.
    @Attribute(.unique) public var id: UUID

    /// Start ordinal in KJVA versification (for cross-module consistency).
    public var kjvOrdinalStart: Int

    /// End ordinal in KJVA versification.
    public var kjvOrdinalEnd: Int

    /// Start ordinal in the original module's versification.
    public var ordinalStart: Int

    /// End ordinal in the original module's versification.
    public var ordinalEnd: Int

    /// Versification system of the original module.
    public var v11n: String

    /// The book name at the time of bookmark creation (e.g. "Genesis").
    public var book: String?

    /// TTS playback settings.
    public var playbackSettings: PlaybackSettings?

    /// When this bookmark was created.
    public var createdAt: Date

    /// Character offset start within the verse text (for sub-verse selections).
    public var startOffset: Int?

    /// Character offset end within the verse text.
    public var endOffset: Int?

    /// Primary label ID for display.
    public var primaryLabelId: UUID?

    /// When this bookmark was last modified.
    public var lastUpdatedOn: Date

    /// Whether this bookmark covers the whole verse (vs. a text selection).
    public var wholeVerse: Bool

    /// Bookmark type for special categorization.
    public var type: String?

    /// Custom icon identifier.
    public var customIcon: String?

    /// Edit action configuration.
    public var editAction: EditAction?

    /// The bookmark note text (stored separately for performance).
    @Relationship(deleteRule: .cascade, inverse: \BibleBookmarkNotes.bookmark)
    public var notes: BibleBookmarkNotes?

    /// Labels associated with this bookmark.
    @Relationship(deleteRule: .cascade, inverse: \BibleBookmarkToLabel.bookmark)
    public var bookmarkToLabels: [BibleBookmarkToLabel]?

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

/// Separate entity for bookmark notes (kept separate for query performance).
@Model
public final class BibleBookmarkNotes {
    @Attribute(.unique) public var bookmarkId: UUID
    public var bookmark: BibleBookmark?
    public var notes: String

    public init(bookmarkId: UUID, notes: String = "") {
        self.bookmarkId = bookmarkId
        self.notes = notes
    }
}

/// Junction table linking Bible bookmarks to labels (many-to-many).
@Model
public final class BibleBookmarkToLabel {
    public var bookmark: BibleBookmark?
    public var label: Label?

    /// Order number for StudyPad display.
    public var orderNumber: Int

    /// Indent level in StudyPad.
    public var indentLevel: Int

    /// Whether content is expanded in StudyPad.
    public var expandContent: Bool

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

/// A bookmark on a non-Bible document (key-based rather than ordinal-based).
@Model
public final class GenericBookmark {
    /// UUID primary key.
    @Attribute(.unique) public var id: UUID

    /// Document key (OSIS reference for the entry).
    public var key: String

    /// Document initials (module abbreviation).
    public var bookInitials: String

    /// When this bookmark was created.
    public var createdAt: Date

    /// Start ordinal within the document.
    public var ordinalStart: Int

    /// End ordinal within the document.
    public var ordinalEnd: Int

    /// Character offset start.
    public var startOffset: Int?

    /// Character offset end.
    public var endOffset: Int?

    /// Primary label ID.
    public var primaryLabelId: UUID?

    /// When last modified.
    public var lastUpdatedOn: Date

    /// Whether this covers the whole entry.
    public var wholeVerse: Bool

    /// TTS playback settings.
    public var playbackSettings: PlaybackSettings?

    /// Custom icon identifier.
    public var customIcon: String?

    /// Edit action configuration.
    public var editAction: EditAction?

    /// Notes for this bookmark.
    @Relationship(deleteRule: .cascade, inverse: \GenericBookmarkNotes.bookmark)
    public var notes: GenericBookmarkNotes?

    /// Labels associated with this bookmark.
    @Relationship(deleteRule: .cascade, inverse: \GenericBookmarkToLabel.bookmark)
    public var bookmarkToLabels: [GenericBookmarkToLabel]?

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

/// Notes for a generic bookmark.
@Model
public final class GenericBookmarkNotes {
    @Attribute(.unique) public var bookmarkId: UUID
    public var bookmark: GenericBookmark?
    public var notes: String

    public init(bookmarkId: UUID, notes: String = "") {
        self.bookmarkId = bookmarkId
        self.notes = notes
    }
}

/// Junction table linking generic bookmarks to labels.
@Model
public final class GenericBookmarkToLabel {
    public var bookmark: GenericBookmark?
    public var label: Label?

    public var orderNumber: Int
    public var indentLevel: Int
    public var expandContent: Bool

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
