// Label.swift — Label and bookmark style models

import Foundation
import SwiftData

/// Type of label for special categorization.
public enum LabelType: String, Codable, Sendable {
    case highlight = "HIGHLIGHT"
    case example = "EXAMPLE"
}

/// A label (tag) that can be applied to bookmarks for organization.
/// Also serves as the container for StudyPad entries.
@Model
public final class Label {
    /// UUID primary key.
    @Attribute(.unique) public var id: UUID

    /// Label display name. Special system labels use reserved names.
    public var name: String

    /// ARGB color integer for the label.
    public var color: Int

    /// Whether to show a marker/star icon style.
    public var markerStyle: Bool

    /// Whether marker style applies to the whole verse.
    public var markerStyleWholeVerse: Bool

    /// Whether to show underline style.
    public var underlineStyle: Bool

    /// Whether underline style applies to the whole verse.
    public var underlineStyleWholeVerse: Bool

    /// Whether to hide the highlight (invisible label).
    public var hideStyle: Bool

    /// Whether hide style applies to the whole verse.
    public var hideStyleWholeVerse: Bool

    /// Whether this label is marked as favourite for quick access.
    public var favourite: Bool

    /// Label type for categorization.
    public var type: String?

    /// Custom icon identifier.
    public var customIcon: String?

    /// StudyPad text entries associated with this label.
    @Relationship(deleteRule: .cascade, inverse: \StudyPadTextEntry.label)
    public var studyPadEntries: [StudyPadTextEntry]?

    public init(
        id: UUID = UUID(),
        name: String = "",
        color: Int = Label.defaultColor,
        markerStyle: Bool = false,
        markerStyleWholeVerse: Bool = false,
        underlineStyle: Bool = false,
        underlineStyleWholeVerse: Bool = true,
        hideStyle: Bool = false,
        hideStyleWholeVerse: Bool = false,
        favourite: Bool = false
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
    }

    // MARK: - Constants

    /// Default highlight color (blue): 0xFF91A7FF
    public static let defaultColor: Int = 0xFF91A7FF

    /// System label names (reserved, not user-visible).
    public static let speakLabelName = "__SPEAK_LABEL__"
    public static let unlabeledName = "__UNLABELED__"
    public static let paragraphBreakLabelName = "__PARAGRAPH_BREAK_LABEL__"

    /// Whether this is a system-reserved label.
    public var isSystemLabel: Bool {
        name == Label.speakLabelName ||
        name == Label.unlabeledName ||
        name == Label.paragraphBreakLabelName
    }

    /// Whether this is a real user-created label (not a system label).
    public var isRealLabel: Bool {
        !isSystemLabel
    }
}

/// Predefined bookmark highlight styles matching Android's BookmarkStyle enum.
public enum BookmarkStylePreset: String, CaseIterable, Sendable {
    case yellowStar = "YELLOW_STAR"
    case redHighlight = "RED_HIGHLIGHT"
    case yellowHighlight = "YELLOW_HIGHLIGHT"
    case greenHighlight = "GREEN_HIGHLIGHT"
    case blueHighlight = "BLUE_HIGHLIGHT"
    case orangeHighlight = "ORANGE_HIGHLIGHT"
    case purpleHighlight = "PURPLE_HIGHLIGHT"
    case underline = "UNDERLINE"

    /// The ARGB color for this preset.
    public var color: Int {
        switch self {
        case .yellowStar: return 0xFFFFFF00
        case .redHighlight: return 0xFFFF9999
        case .yellowHighlight: return 0xFFFFFF99
        case .greenHighlight: return 0xFF99FF99
        case .blueHighlight: return 0xFF91A7FF
        case .orangeHighlight: return 0xFFFFCC99
        case .purpleHighlight: return 0xFFCC99FF
        case .underline: return 0xFF99CCFF
        }
    }
}
