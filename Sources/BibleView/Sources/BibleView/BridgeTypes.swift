// BridgeTypes.swift — Swift Codable types matching client-objects.ts

import Foundation

/// Type alias for UUID-based identifiers matching Android's IdType.
public typealias IdType = String

// MARK: - OSIS Fragment

/// A fragment of Bible text with metadata, matching TypeScript OsisFragment.
public struct OsisFragment: Codable, Sendable {
    public var xml: String
    public var originalXml: String?
    public var key: String
    public var keyName: String
    public var v11n: String
    public var bookCategory: String // "BIBLE", "COMMENTARY", "GENERAL_BOOK"
    public var bookInitials: String
    public var bookAbbreviation: String
    public var osisRef: String
    public var isNewTestament: Bool
    public var features: OsisFeatures?
    public var ordinalRange: [Int]
    public var language: String
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
    public var type: String? // "hebrew-and-greek", "hebrew", "greek"
    public var keyName: String?
}

// MARK: - Bookmark Data (for bridge serialization)

/// Bookmark style matching TypeScript BookmarkStyle.
public struct BookmarkStyleData: Codable, Sendable {
    public var color: Int
    public var isSpeak: Bool
    public var isParagraphBreak: Bool
    public var underline: Bool
    public var underlineWholeVerse: Bool
    public var markerStyle: Bool
    public var markerStyleWholeVerse: Bool
    public var hideStyle: Bool
    public var hideStyleWholeVerse: Bool
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
    public var id: IdType
    public var name: String
    public var style: BookmarkStyleData
    public var isRealLabel: Bool
}

/// Edit action data matching TypeScript editAction.
public struct EditActionData: Codable, Sendable {
    public var mode: String? // "APPEND", "PREPEND", null
    public var content: String?
}

/// Base bookmark-to-label relationship data.
public struct BookmarkToLabelData: Codable, Sendable {
    public var bookmarkId: IdType
    public var labelId: IdType
    public var orderNumber: Int
    public var indentLevel: Int
    public var expandContent: Bool
    public var type: String // "BibleBookmarkToLabel" or "GenericBookmarkToLabel"
}

/// Bible bookmark data for bridge serialization, matching TypeScript BibleBookmark.
public struct BibleBookmarkData: Codable, Sendable {
    public var id: IdType
    public var type: String // "bookmark"
    public var hashCode: Int
    public var ordinalRange: [Int] // [start, end]
    public var offsetRange: [Int?]? // [start, end?]
    public var labels: [IdType]
    public var bookInitials: String
    public var bookName: String
    public var bookAbbreviation: String
    public var createdAt: Double // timestamp
    public var text: String
    public var fullText: String
    public var bookmarkToLabels: [BookmarkToLabelData]
    public var primaryLabelId: IdType
    public var lastUpdatedOn: Double
    public var notes: String?
    public var hasNote: Bool
    public var wholeVerse: Bool
    public var customIcon: String?
    public var editAction: EditActionData?
    // Bible-specific fields
    public var osisRef: String
    public var originalOrdinalRange: [Int]
    public var verseRange: String
    public var verseRangeOnlyNumber: String
    public var verseRangeAbbreviated: String
    public var v11n: String
    public var osisFragment: OsisFragment?
}

/// Generic bookmark data for bridge serialization, matching TypeScript GenericBookmark.
public struct GenericBookmarkData: Codable, Sendable {
    public var id: IdType
    public var type: String // "generic-bookmark"
    public var hashCode: Int
    public var ordinalRange: [Int]
    public var offsetRange: [Int?]?
    public var labels: [IdType]
    public var bookInitials: String
    public var bookName: String
    public var bookAbbreviation: String
    public var createdAt: Double
    public var text: String
    public var fullText: String
    public var bookmarkToLabels: [BookmarkToLabelData]
    public var primaryLabelId: IdType
    public var lastUpdatedOn: Double
    public var notes: String?
    public var hasNote: Bool
    public var wholeVerse: Bool
    public var customIcon: String?
    public var editAction: EditActionData?
    // Generic-specific fields
    public var key: String
    public var keyName: String
    public var highlightedText: String
}

// MARK: - StudyPad Data

/// StudyPad text item data for bridge serialization.
public struct StudyPadTextItemData: Codable, Sendable {
    public var id: IdType
    public var type: String // "journal"
    public var hashCode: Int
    public var labelId: IdType
    public var text: String
    public var orderNumber: Int
    public var indentLevel: Int
}

// MARK: - Selection Query

/// Result of querying the current text selection in the WebView.
public struct SelectionQuery: Codable, Sendable {
    public var bookInitials: String
    public var osisRef: String
    public var startOrdinal: Int
    public var startOffset: Int
    public var endOrdinal: Int
    public var endOffset: Int
    public var bookmarks: [IdType]
    public var text: String
}

// MARK: - JSON Helpers

/// JSON encoder configured for bridge communication.
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
