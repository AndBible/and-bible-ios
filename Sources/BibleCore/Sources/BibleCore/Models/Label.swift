// Label.swift -- Label and bookmark style models

import Foundation
import SwiftData

/**
 Enumerates persisted label type identifiers mirrored from the Android data model.

 The raw values are stored in SwiftData and passed through to other layers without
 translation, so callers should treat them as persistence contract values.
 */
public enum LabelType: String, Codable, Sendable {
    case highlight = "HIGHLIGHT"
    case example = "EXAMPLE"
}

/**
 Stores a bookmark label and its visual styling metadata.

 Labels are used for user-visible tagging, highlighting rules, quick actions, and as the
 container entity for StudyPad notes. Deleting a label cascades to its StudyPad entries
 and bookmark junction rows, matching the existing behavior where label deletion detaches
 bookmark relationships instead of deleting the bookmarked content.
 */
@Model
public final class Label {
    /// Stable identifier used for persistence, bookmark linking, and sync reconciliation.
    public var id: UUID = UUID()

    /// User-visible label name or one of the reserved system label identifiers.
    public var name: String = ""

    /// Signed ARGB color integer consumed by native and web rendering layers.
    public var color: Int = 0xFF91A7FF

    /// Enables marker-style rendering instead of the default highlight treatment.
    public var markerStyle: Bool = false

    /// Applies the marker style to the whole verse instead of only the selected text span.
    public var markerStyleWholeVerse: Bool = false

    /// Enables underline-style rendering for bookmarks using this label.
    public var underlineStyle: Bool = false

    /// Applies underline styling to the whole verse instead of only the selected text span.
    public var underlineStyleWholeVerse: Bool = true

    /// Hides the visible highlight while keeping the label and bookmark metadata intact.
    public var hideStyle: Bool = false

    /// Applies the hidden style to the whole verse instead of only the selected text span.
    public var hideStyleWholeVerse: Bool = false

    /// Flags the label for quick-access surfaces such as bookmark and label pickers.
    public var favourite: Bool = false

    /// Optional raw label type string mirrored from Android parity state.
    public var type: String?

    /// Optional Android canonical icon name or previously stored SF Symbol identifier.
    public var customIcon: String?

    /// StudyPad text rows owned by this label and cascade-deleted with it.
    @Relationship(deleteRule: .cascade, inverse: \StudyPadTextEntry.label)
    public var studyPadEntries: [StudyPadTextEntry]?

    /// Bible bookmark junction rows that reference this label.
    @Relationship(deleteRule: .cascade, inverse: \BibleBookmarkToLabel.label)
    public var bibleBookmarkToLabels: [BibleBookmarkToLabel]?

    /// Generic bookmark junction rows that reference this label.
    @Relationship(deleteRule: .cascade, inverse: \GenericBookmarkToLabel.label)
    public var genericBookmarkToLabels: [GenericBookmarkToLabel]?

    /**
     Creates a label with styling metadata.

     - Parameters:
       - id: Stable identifier for persistence and sync.
       - name: User-visible or reserved system label name.
       - color: Signed ARGB integer shared with the web renderer.
       - markerStyle: Whether marker-style rendering is enabled.
       - markerStyleWholeVerse: Whether marker-style rendering applies to an entire verse.
       - underlineStyle: Whether underline rendering is enabled.
       - underlineStyleWholeVerse: Whether underlines apply to an entire verse.
       - hideStyle: Whether the visual highlight is suppressed.
       - hideStyleWholeVerse: Whether the hidden style applies to an entire verse.
       - favourite: Whether the label is surfaced in quick-access UI.
     */
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

    /// Default highlight color encoded as a signed ARGB integer (`0xFF91A7FF`).
    public static let defaultColor: Int = 0xFF91A7FF

    /// Reserved system label name used by speak/highlight playback features.
    public static let speakLabelName = "__SPEAK_LABEL__"

    /// Reserved system label name for unlabeled bookmark grouping.
    public static let unlabeledName = "__UNLABELED__"

    /// Reserved system label name used to mark paragraph breaks.
    public static let paragraphBreakLabelName = "__PARAGRAPH_BREAK_LABEL__"

    /// Reserved system label name used for AI-generated bookmark content.
    public static let aiLabelName = "__AI_LABEL__"

    /// Android's fixed identifier for the speak system label.
    public static let speakLabelId = UUID(uuidString: "00000000-0000-ab1e-0000-5bea400001a1")!

    /// Android's fixed identifier for the unlabeled system label.
    public static let unlabeledId = UUID(uuidString: "00000000-0000-ab1e-0000-001abe1ed001")!

    /// Android's fixed identifier for the paragraph-break system label.
    public static let paragraphBreakLabelId = UUID(uuidString: "00000000-0000-ab1e-0000-ba4a64a30001")!

    /// Android's fixed identifier for the AI system label.
    public static let aiLabelId = UUID(uuidString: "00000000-0000-ab1e-0000-a100000001a1")!

    /// Speak-label identifier used by pre-parity iOS builds and migrated during bootstrap.
    static let legacySpeakLabelId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Unlabeled identifier used by pre-parity iOS builds and migrated during bootstrap.
    static let legacyUnlabeledId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    /// Paragraph-label identifier used by pre-parity iOS builds and migrated during bootstrap.
    static let legacyParagraphBreakLabelId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    /// Returns true when this label matches one of the reserved system label names.
    public var isSystemLabel: Bool {
        name == Label.speakLabelName ||
        name == Label.unlabeledName ||
        name == Label.paragraphBreakLabelName ||
        name == Label.aiLabelName
    }

    /// Returns true when the label is user-created and safe to expose in normal label UI.
    public var isRealLabel: Bool {
        !isSystemLabel
    }

    // MARK: - Icon Mapping (Android canonical name <-> SF Symbol)

    /**
     Android `customIconMap` keys in the exact category and picker order used by Label Edit.

     This ordered owner is shared by app UI and tests; callers must not reconstruct icon lists from
     `iconToSFSymbol`, whose dictionary order is not a persistence or presentation contract.
     */
    public static let customIconNames: [String] = [
        "book", "book-bible", "cross", "church", "star-of-david", "person-praying",
        "info", "question", "exclamation", "lightbulb", "bell", "flag", "star", "tag",
        "envelope", "comment", "share-nodes", "link", "handshake", "clock", "map-marker",
        "globe", "landmark", "calendar", "user", "music", "microphone", "key", "crown",
        "heart", "heart-crack", "robot",
    ]

    /**
     Maps Android canonical bookmark icon names to SF Symbols used by iOS surfaces.

     The mapping keeps persisted Android-compatible names stable while allowing iOS to render
     native symbols. Unknown keys fall back to the raw string in `sfSymbol(for:)`.
     */
    public static let iconToSFSymbol: [String: String] = [
        "book": "book.fill",
        "book-bible": "book.closed.fill",
        "cross": "cross.fill",
        "church": "building.columns.fill",
        "star-of-david": "starofdavid.fill",
        "person-praying": "figure.mind.and.body",
        "info": "info.circle.fill",
        "question": "questionmark.circle.fill",
        "exclamation": "exclamationmark.circle.fill",
        "lightbulb": "lightbulb.fill",
        "bell": "bell.fill",
        "flag": "flag.fill",
        "star": "star.fill",
        "tag": "tag.fill",
        "envelope": "envelope.fill",
        "comment": "text.bubble.fill",
        "share-nodes": "square.and.arrow.up",
        "link": "link",
        "handshake": "hands.clap.fill",
        "clock": "clock.fill",
        "map-marker": "mappin.and.ellipse",
        "globe": "globe",
        "landmark": "building.columns",
        "calendar": "calendar",
        "user": "person.fill",
        "music": "music.note",
        "microphone": "mic.fill",
        "key": "key.fill",
        "crown": "crown.fill",
        "heart": "heart.fill",
        "heart-crack": "heart.slash.fill",
        "robot": "cpu.fill",
    ]

    /**
     Resolves a persisted custom icon name into an SF Symbol usable on iOS.

     - Parameter iconName: Android canonical icon name or an older persisted SF Symbol name.
     - Returns: The SF Symbol to render, or `nil` when the caller has no custom icon.
     - Note: Unknown names are returned unchanged for backward compatibility with older iOS
       builds that persisted SF Symbol names directly.
     */
    public static func sfSymbol(for iconName: String?) -> String? {
        guard let name = iconName, !name.isEmpty else { return nil }
        return iconToSFSymbol[name] ?? name
    }
}

/**
 Enumerates the predefined bookmark styles surfaced by the UI.

 The raw values match Android's `BookmarkStyle` enum so preset selections can round-trip
 through shared data and localization tables.
 */
public enum BookmarkStylePreset: String, CaseIterable, Sendable {
    case yellowStar = "YELLOW_STAR"
    case redHighlight = "RED_HIGHLIGHT"
    case yellowHighlight = "YELLOW_HIGHLIGHT"
    case greenHighlight = "GREEN_HIGHLIGHT"
    case blueHighlight = "BLUE_HIGHLIGHT"
    case orangeHighlight = "ORANGE_HIGHLIGHT"
    case purpleHighlight = "PURPLE_HIGHLIGHT"
    case underline = "UNDERLINE"

    /// Returns the signed ARGB color integer paired with this preset.
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
