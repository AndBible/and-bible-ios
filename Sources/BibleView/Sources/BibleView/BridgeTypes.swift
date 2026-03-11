// BridgeTypes.swift — Swift Codable types matching client-objects.ts

import Foundation

/// Type alias for UUID-based identifiers matching Android's IdType.
public typealias IdType = String

// MARK: - OSIS Fragment

/// A fragment of Bible text with metadata, matching TypeScript OsisFragment.
public struct OsisFragment: Codable, Sendable {
    /// Render-ready OSIS/HTML payload consumed by the Vue.js client.
    public var xml: String
    /// Optional unmodified source XML preserved for debugging and reprocessing.
    public var originalXml: String?
    /// The canonical key used to reload this fragment, such as `Gen.1`.
    public var key: String
    /// Human-readable form of `key`, such as `Genesis 1`.
    public var keyName: String
    /// Versification identifier used when resolving ordinals and references.
    public var v11n: String
    /// Document category expected by the client: `BIBLE`, `COMMENTARY`, or `GENERAL_BOOK`.
    public var bookCategory: String // "BIBLE", "COMMENTARY", "GENERAL_BOOK"
    /// Module initials that produced the fragment, such as `KJV`.
    public var bookInitials: String
    /// Short module abbreviation shown in compact UI.
    public var bookAbbreviation: String
    /// OSIS reference string for the fragment's visible range.
    public var osisRef: String
    /// Whether the fragment belongs to the New Testament for UI styling and feature toggles.
    public var isNewTestament: Bool
    /// Optional feature flags describing Strong's and morphology availability.
    public var features: OsisFeatures?
    /// Inclusive ordinal range rendered in this fragment.
    public var ordinalRange: [Int]
    /// BCP-47 language tag used for typography and language-sensitive client behavior.
    public var language: String
    /// Text direction passed to the web client: `ltr` or `rtl`.
    public var direction: String // "ltr" or "rtl"

    public init(
        xml: String,
        key: String,
        keyName: String,
        v11n: String = "KJVA",
        bookCategory: String = "BIBLE",
        bookInitials: String,
        bookAbbreviation: String = "",
        osisRef: String = "",
        isNewTestament: Bool = false,
        features: OsisFeatures? = nil,
        ordinalRange: [Int] = [],
        language: String = "en",
        direction: String = "ltr"
    ) {
        self.xml = xml
        self.key = key
        self.keyName = keyName
        self.v11n = v11n
        self.bookCategory = bookCategory
        self.bookInitials = bookInitials
        self.bookAbbreviation = bookAbbreviation
        self.osisRef = osisRef
        self.isNewTestament = isNewTestament
        self.features = features
        self.ordinalRange = ordinalRange
        self.language = language
        self.direction = direction
    }
}

/// Optional features of an OSIS fragment.
public struct OsisFeatures: Codable, Sendable {
    /// Feature family identifier such as `hebrew-and-greek`, `hebrew`, or `greek`.
    public var type: String? // "hebrew-and-greek", "hebrew", "greek"
    /// Key used by the client when rendering per-word feature affordances.
    public var keyName: String?
}

// MARK: - Bookmark Data (for bridge serialization)

/// Bookmark style matching TypeScript BookmarkStyle.
public struct BookmarkStyleData: Codable, Sendable {
    /// ARGB color integer used for bookmark tinting.
    public var color: Int
    /// Whether this label is the dedicated "speak" system label.
    public var isSpeak: Bool
    /// Whether this label represents a paragraph-break marker.
    public var isParagraphBreak: Bool
    /// Whether underline styling is enabled for partial selections.
    public var underline: Bool
    /// Whether underline styling extends to whole-verse bookmarks.
    public var underlineWholeVerse: Bool
    /// Whether marker/highlighter styling is enabled for partial selections.
    public var markerStyle: Bool
    /// Whether marker/highlighter styling extends to whole-verse bookmarks.
    public var markerStyleWholeVerse: Bool
    /// Whether this style hides bookmarked text for persecution/discreet workflows.
    public var hideStyle: Bool
    /// Whether hidden-text styling applies to whole-verse bookmarks.
    public var hideStyleWholeVerse: Bool
    /// Optional icon name overriding the default label/bookmark icon.
    public var customIcon: String?

    public init(
        color: Int = 0xFF91A7FF,
        isSpeak: Bool = false,
        isParagraphBreak: Bool = false,
        underline: Bool = false,
        underlineWholeVerse: Bool = false,
        markerStyle: Bool = false,
        markerStyleWholeVerse: Bool = false,
        hideStyle: Bool = false,
        hideStyleWholeVerse: Bool = false,
        customIcon: String? = nil
    ) {
        self.color = color
        self.isSpeak = isSpeak
        self.isParagraphBreak = isParagraphBreak
        self.underline = underline
        self.underlineWholeVerse = underlineWholeVerse
        self.markerStyle = markerStyle
        self.markerStyleWholeVerse = markerStyleWholeVerse
        self.hideStyle = hideStyle
        self.hideStyleWholeVerse = hideStyleWholeVerse
        self.customIcon = customIcon
    }
}

/// Label data for bridge serialization, matching TypeScript Label.
public struct LabelData: Codable, Sendable {
    /// Stable UUID string for the label.
    public var id: IdType
    /// Localized or user-defined label name shown in the UI.
    public var name: String
    /// Visual styling applied to bookmarks assigned to this label.
    public var style: BookmarkStyleData
    /// Whether the label is user-visible rather than an internal/system label.
    public var isRealLabel: Bool
}

/// Edit action data matching TypeScript editAction.
public struct EditActionData: Codable, Sendable {
    /// Edit mode requested by StudyPad, such as `APPEND` or `PREPEND`.
    public var mode: String? // "APPEND", "PREPEND", null
    /// Optional text payload used by the selected edit mode.
    public var content: String?
}

/// Base bookmark-to-label relationship data.
public struct BookmarkToLabelData: Codable, Sendable {
    /// Bookmark UUID referenced by this junction row.
    public var bookmarkId: IdType
    /// Label UUID referenced by this junction row.
    public var labelId: IdType
    /// Ordering index within a StudyPad label list.
    public var orderNumber: Int
    /// Nesting level used by StudyPad tree rendering.
    public var indentLevel: Int
    /// Whether the client should auto-expand this row's content.
    public var expandContent: Bool
    /// Concrete junction type name understood by the web client.
    public var type: String // "BibleBookmarkToLabel" or "GenericBookmarkToLabel"
}

/// Bible bookmark data for bridge serialization, matching TypeScript BibleBookmark.
public struct BibleBookmarkData: Codable, Sendable {
    /// Stable UUID string for the bookmark.
    public var id: IdType
    /// Discriminator expected by the client, always `bookmark`.
    public var type: String // "bookmark"
    /// Android-compatible hash code used by legacy client logic.
    public var hashCode: Int
    /// Inclusive ordinal range covered by the bookmark.
    public var ordinalRange: [Int] // [start, end]
    /// Optional start/end text offsets for partial-verse bookmarks.
    public var offsetRange: [Int?]? // [start, end?]
    /// Flat list of label identifiers assigned to this bookmark.
    public var labels: [IdType]
    /// Module initials that produced the bookmarked text.
    public var bookInitials: String
    /// Human-readable module name.
    public var bookName: String
    /// Compact module abbreviation.
    public var bookAbbreviation: String
    /// Creation timestamp in milliseconds since 1970.
    public var createdAt: Double // timestamp
    /// Short text excerpt shown in bookmark lists.
    public var text: String
    /// Full text payload available for notes and sharing.
    public var fullText: String
    /// Expanded junction rows used by StudyPad and label management UIs.
    public var bookmarkToLabels: [BookmarkToLabelData]
    /// Identifier of the primary label controlling styling precedence.
    public var primaryLabelId: IdType
    /// Last modification timestamp in milliseconds since 1970.
    public var lastUpdatedOn: Double
    /// Optional user-authored note.
    public var notes: String?
    /// Precomputed note-presence flag for cheap client rendering.
    public var hasNote: Bool
    /// Whether the bookmark should highlight whole verses rather than offsets.
    public var wholeVerse: Bool
    /// Optional icon override selected by the user.
    public var customIcon: String?
    /// Optional StudyPad edit behavior metadata.
    public var editAction: EditActionData?
    // Bible-specific fields
    /// OSIS reference for the bookmarked verse range.
    public var osisRef: String
    /// Original ordinals before any versification remapping or KJVA adjustments.
    public var originalOrdinalRange: [Int]
    /// Human-readable verse range string.
    public var verseRange: String
    /// Number-only range string used by compact UI.
    public var verseRangeOnlyNumber: String
    /// Abbreviated range string used in list layouts.
    public var verseRangeAbbreviated: String
    /// Versification identifier for the bookmarked text.
    public var v11n: String
    /// Optional rendered fragment attached for inline bookmark display.
    public var osisFragment: OsisFragment?
}

/// Generic bookmark data for bridge serialization, matching TypeScript GenericBookmark.
public struct GenericBookmarkData: Codable, Sendable {
    /// Stable UUID string for the bookmark.
    public var id: IdType
    /// Discriminator expected by the client, always `generic-bookmark`.
    public var type: String // "generic-bookmark"
    /// Android-compatible hash code used by legacy client logic.
    public var hashCode: Int
    /// Inclusive ordinal range if the source content exposes ordinals.
    public var ordinalRange: [Int]
    /// Optional start/end text offsets for partial bookmarks.
    public var offsetRange: [Int?]?
    /// Flat list of label identifiers assigned to this bookmark.
    public var labels: [IdType]
    /// Module initials that produced the bookmarked text.
    public var bookInitials: String
    /// Human-readable module name.
    public var bookName: String
    /// Compact module abbreviation.
    public var bookAbbreviation: String
    /// Creation timestamp in milliseconds since 1970.
    public var createdAt: Double
    /// Short text excerpt shown in bookmark lists.
    public var text: String
    /// Full text payload available for notes and sharing.
    public var fullText: String
    /// Expanded junction rows used by StudyPad and label management UIs.
    public var bookmarkToLabels: [BookmarkToLabelData]
    /// Identifier of the primary label controlling styling precedence.
    public var primaryLabelId: IdType
    /// Last modification timestamp in milliseconds since 1970.
    public var lastUpdatedOn: Double
    /// Optional user-authored note.
    public var notes: String?
    /// Precomputed note-presence flag for cheap client rendering.
    public var hasNote: Bool
    /// Whether the bookmark should highlight the whole range rather than offsets.
    public var wholeVerse: Bool
    /// Optional icon override selected by the user.
    public var customIcon: String?
    /// Optional StudyPad edit behavior metadata.
    public var editAction: EditActionData?
    // Generic-specific fields
    /// Module-specific key used to reopen the bookmarked content.
    public var key: String
    /// Human-readable form of `key`.
    public var keyName: String
    /// HTML/text snippet with the bookmarked segment emphasized.
    public var highlightedText: String
}

// MARK: - StudyPad Data

/// StudyPad text item data for bridge serialization.
public struct StudyPadTextItemData: Codable, Sendable {
    /// Stable UUID string for the StudyPad entry.
    public var id: IdType
    /// Discriminator expected by the client, currently `journal`.
    public var type: String // "journal"
    /// Android-compatible hash code used by legacy client logic.
    public var hashCode: Int
    /// Label UUID that owns this StudyPad entry.
    public var labelId: IdType
    /// Rich-text or HTML payload stored in the entry.
    public var text: String
    /// Ordering index within the parent label.
    public var orderNumber: Int
    /// Nesting depth within the StudyPad tree.
    public var indentLevel: Int
}

// MARK: - Selection Query

/// Result of querying the current text selection in the WebView.
public struct SelectionQuery: Codable, Sendable {
    /// Module initials for the document containing the selection.
    public var bookInitials: String
    /// OSIS reference describing the selection range.
    public var osisRef: String
    /// Ordinal at the start of the selection.
    public var startOrdinal: Int
    /// Character offset within the start verse/node.
    public var startOffset: Int
    /// Ordinal at the end of the selection.
    public var endOrdinal: Int
    /// Character offset within the end verse/node.
    public var endOffset: Int
    /// Identifiers of bookmarks overlapping the selection.
    public var bookmarks: [IdType]
    /// Plain-text representation of the selected content.
    public var text: String
}

// MARK: - JSON Helpers

/// JSON encoder configured for bridge communication.
///
/// The bridge uses millisecond timestamps to stay aligned with Android and the web client's
/// existing expectations.
public let bridgeEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
}()

/// JSON decoder configured for bridge communication.
public let bridgeDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
}()
