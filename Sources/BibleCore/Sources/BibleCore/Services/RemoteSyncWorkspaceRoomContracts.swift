// RemoteSyncWorkspaceRoomContracts.swift -- Complete Android workspace Room wire values

import Foundation

/**
 Preserves Android text-display fields that the current iOS reader model does not expose.

 These values remain part of the workspace sync contract even though iOS has no corresponding UI.
 Keeping them beside the native `TextDisplaySettings` projection prevents restore/replay/export from
 erasing another Android device's settings.
 */
public struct RemoteSyncWorkspaceTextDisplaySettingsFidelity: Codable, Sendable, Equatable {
    /// Android automatic reading-progress tracking override.
    public let autoTrackReading: Bool?

    /// Android scroll-helper line visibility override.
    public let scrollHelperLines: Bool?

    /// Android scroll-helper line style integer.
    public let scrollHelperLineStyle: Int?

    /// Android page-button visibility override.
    public let showPageButtons: Bool?

    /// Android reading-progress marker visibility override.
    public let showReadingProgress: Bool?

    /// Android day-theme background image reference.
    public let dayBackgroundImage: String?

    /// Android night-theme background image reference.
    public let nightBackgroundImage: String?

    /// Android day-theme background image opacity.
    public let dayBackgroundImageOpacity: Int?

    /// Android night-theme background image opacity.
    public let nightBackgroundImageOpacity: Int?

    /** Creates one lossless Android-only text-display payload. */
    public init(
        autoTrackReading: Bool? = nil,
        scrollHelperLines: Bool? = nil,
        scrollHelperLineStyle: Int? = nil,
        showPageButtons: Bool? = nil,
        showReadingProgress: Bool? = nil,
        dayBackgroundImage: String? = nil,
        nightBackgroundImage: String? = nil,
        dayBackgroundImageOpacity: Int? = nil,
        nightBackgroundImageOpacity: Int? = nil
    ) {
        self.autoTrackReading = autoTrackReading
        self.scrollHelperLines = scrollHelperLines
        self.scrollHelperLineStyle = scrollHelperLineStyle
        self.showPageButtons = showPageButtons
        self.showReadingProgress = showReadingProgress
        self.dayBackgroundImage = dayBackgroundImage
        self.nightBackgroundImage = nightBackgroundImage
        self.dayBackgroundImageOpacity = dayBackgroundImageOpacity
        self.nightBackgroundImageOpacity = nightBackgroundImageOpacity
    }

    /// Returns whether at least one Android-only field is present.
    var hasValue: Bool {
        autoTrackReading != nil
            || scrollHelperLines != nil
            || scrollHelperLineStyle != nil
            || showPageButtons != nil
            || showReadingProgress != nil
            || dayBackgroundImage != nil
            || nightBackgroundImage != nil
            || dayBackgroundImageOpacity != nil
            || nightBackgroundImageOpacity != nil
    }
}

/** One Android `WorkspaceLabelOverride` row preserved by workspace synchronization. */
public struct RemoteSyncCurrentWorkspaceLabelOverrideRow: Codable, Sendable, Equatable {
    /// Owning workspace identifier.
    public let workspaceID: UUID

    /// Bookmark-label identifier whose style is overridden.
    public let labelID: UUID

    /// Android override mode: highlight, underline, marker, hidden, or `nil` for no override.
    public let overrideMode: Int?

    /** Creates one Android-compatible workspace label override. */
    public init(workspaceID: UUID, labelID: UUID, overrideMode: Int?) {
        self.workspaceID = workspaceID
        self.labelID = labelID
        self.overrideMode = overrideMode
    }
}

/** One Android `GlobalTextDisplaySettings` singleton row. */
public struct RemoteSyncCurrentGlobalTextDisplaySettingsRow: Codable, Sendable, Equatable {
    /// Android's fixed cross-device singleton identifier.
    public let id: UUID

    /// Text-display fields represented by iOS's native reader settings model.
    public let textDisplaySettings: TextDisplaySettings?

    /// Android-only text-display fields preserved outside the native model.
    public let fidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity

    /** Creates one complete Android global text-display row. */
    public init(
        id: UUID,
        textDisplaySettings: TextDisplaySettings?,
        fidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity = .init()
    ) {
        self.id = id
        self.textDisplaySettings = textDisplaySettings
        self.fidelity = fidelity
    }
}

/**
 Complete Room v24 text-display value used by SQLite readers, writers, and fingerprints.

 Column order is copied from Android's checked-in Room schema export. Every writer consumes the same
 list and value projection so initial and sparse databases cannot drift independently.
 */
struct RemoteSyncWorkspaceTextDisplaySettingsWire: Sendable, Equatable {
    /// Native iOS fields shared with Android.
    let settings: TextDisplaySettings?

    /// Android-only fields retained by the fidelity store.
    let fidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity

    /// Complete Room v24 embedded-column suffixes in canonical schema order.
    static let columnSuffixes = [
        "strongsMode",
        "showMorphology",
        "showFootNotes",
        "showFootNotesInline",
        "expandXrefs",
        "showXrefs",
        "showRedLetters",
        "showSectionTitles",
        "showVerseNumbers",
        "showVersePerLine",
        "showBookmarks",
        "showMyNotes",
        "justifyText",
        "hyphenation",
        "topMargin",
        "fontSize",
        "fontFamily",
        "lineSpacing",
        "bookmarksHideLabels",
        "showPageNumber",
        "infiniteScroll",
        "nonStrongsWordItalic",
        "showMarkAsReadButton",
        "showTitleScrollButton",
        "showMemorizationIndicators",
        "autoTrackReading",
        "showAiDocMarkers",
        "pageScrollAmount",
        "scrollHelperLines",
        "scrollHelperLineStyle",
        "showPageButtons",
        "showOrdinals",
        "showReadingProgress",
        "margin_size_marginLeft",
        "margin_size_marginRight",
        "margin_size_maxWidth",
        "colors_dayTextColor",
        "colors_dayBackground",
        "colors_dayNoise",
        "colors_nightTextColor",
        "colors_nightBackground",
        "colors_nightNoise",
        "colors_dayBackgroundImage",
        "colors_nightBackgroundImage",
        "colors_dayBackgroundImageOpacity",
        "colors_nightBackgroundImageOpacity",
    ]

    /** Creates one complete wire value from native and preserved fields. */
    init(
        settings: TextDisplaySettings?,
        fidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity = .init()
    ) {
        self.settings = settings
        self.fidelity = fidelity
    }

    /** Returns all embedded column names for one Room prefix. */
    static func columns(prefix: String = "text_display_settings_") -> [String] {
        columnSuffixes.map { "\(prefix)\($0)" }
    }

    /**
     Projects all 46 Room v24 columns as typed SQLite values.

     - Returns: Values in exact `columnSuffixes` order.
     - Side Effects: Encodes bookmark-label UUIDs as Android-compatible JSON text when present.
     - Throws: JSON encoding failures; no partial value generation is returned.
     */
    func sqliteValues() throws -> [RemoteSyncSQLiteValue] {
        let value = settings ?? TextDisplaySettings()
        let hiddenLabels: RemoteSyncSQLiteValue
        if let labels = value.bookmarksHideLabels {
            let data = try JSONEncoder().encode(labels.map { $0.uuidString.lowercased() })
            hiddenLabels = .text(String(decoding: data, as: UTF8.self))
        } else {
            hiddenLabels = .null()
        }

        return [
            Self.integer(value.strongsMode),
            Self.boolean(value.showMorphology),
            Self.boolean(value.showFootNotes),
            Self.boolean(value.showFootNotesInline),
            Self.boolean(value.expandXrefs),
            Self.boolean(value.showXrefs),
            Self.boolean(value.showRedLetters),
            Self.boolean(value.showSectionTitles),
            Self.boolean(value.showVerseNumbers),
            Self.boolean(value.showVersePerLine),
            Self.boolean(value.showBookmarks),
            Self.boolean(value.showMyNotes),
            Self.boolean(value.justifyText),
            Self.boolean(value.hyphenation),
            Self.integer(value.topMargin),
            Self.integer(value.fontSize),
            Self.text(value.fontFamily),
            Self.integer(value.lineSpacing),
            hiddenLabels,
            Self.boolean(value.showPageNumber),
            Self.boolean(value.infiniteScroll),
            Self.boolean(value.nonStrongsWordItalic),
            Self.boolean(value.showMarkAsReadButton),
            Self.boolean(value.showTitleScrollButton),
            Self.boolean(value.showMemorizationIndicators),
            Self.boolean(fidelity.autoTrackReading),
            Self.boolean(value.showAiDocMarkers),
            Self.integer(value.pageScrollAmount),
            Self.boolean(fidelity.scrollHelperLines),
            Self.integer(fidelity.scrollHelperLineStyle),
            Self.boolean(fidelity.showPageButtons),
            Self.boolean(value.showOrdinals),
            Self.boolean(fidelity.showReadingProgress),
            Self.integer(value.marginLeft),
            Self.integer(value.marginRight),
            Self.integer(value.maxWidth),
            Self.integer(value.dayTextColor),
            Self.integer(value.dayBackground),
            Self.integer(value.dayNoise),
            Self.integer(value.nightTextColor),
            Self.integer(value.nightBackground),
            Self.integer(value.nightNoise),
            Self.text(fidelity.dayBackgroundImage),
            Self.text(fidelity.nightBackgroundImage),
            Self.integer(fidelity.dayBackgroundImageOpacity),
            Self.integer(fidelity.nightBackgroundImageOpacity),
        ]
    }

    /**
     Decodes every Room v24 embedded column through caller-supplied SQLite accessors.

     - Parameters:
       - integer: Reads one nullable integer column by canonical suffix.
       - boolean: Reads one nullable Boolean column by canonical suffix.
       - text: Reads one nullable text column by canonical suffix.
       - hiddenLabels: Reads and validates the nullable bookmark-label identifier array.
     - Returns: One complete native-plus-fidelity wire value. Native settings remain `nil` when all
       native columns are null; Android-only fields remain independently representable.
     - Side Effects: Invokes each supplied accessor for its corresponding schema column.
     - Throws: Rethrows accessor or hidden-label decoding failures without returning a partial row.
     */
    static func decode(
        integer: (String) throws -> Int?,
        boolean: (String) throws -> Bool?,
        text: (String) throws -> String?,
        hiddenLabels: () throws -> [UUID]?
    ) throws -> Self {
        var settings = TextDisplaySettings()
        var hasNativeValue = false

        func assignInteger(
            _ suffix: String,
            _ keyPath: WritableKeyPath<TextDisplaySettings, Int?>
        ) throws {
            if let value = try integer(suffix) {
                settings[keyPath: keyPath] = value
                hasNativeValue = true
            }
        }

        func assignBoolean(
            _ suffix: String,
            _ keyPath: WritableKeyPath<TextDisplaySettings, Bool?>
        ) throws {
            if let value = try boolean(suffix) {
                settings[keyPath: keyPath] = value
                hasNativeValue = true
            }
        }

        func assignText(
            _ suffix: String,
            _ keyPath: WritableKeyPath<TextDisplaySettings, String?>
        ) throws {
            if let value = try text(suffix) {
                settings[keyPath: keyPath] = value
                hasNativeValue = true
            }
        }

        try assignInteger("strongsMode", \.strongsMode)
        try assignBoolean("showMorphology", \.showMorphology)
        try assignBoolean("showFootNotes", \.showFootNotes)
        try assignBoolean("showFootNotesInline", \.showFootNotesInline)
        try assignBoolean("expandXrefs", \.expandXrefs)
        try assignBoolean("showXrefs", \.showXrefs)
        try assignBoolean("showRedLetters", \.showRedLetters)
        try assignBoolean("showSectionTitles", \.showSectionTitles)
        try assignBoolean("showVerseNumbers", \.showVerseNumbers)
        try assignBoolean("showVersePerLine", \.showVersePerLine)
        try assignBoolean("showBookmarks", \.showBookmarks)
        try assignBoolean("showMyNotes", \.showMyNotes)
        try assignBoolean("justifyText", \.justifyText)
        try assignBoolean("hyphenation", \.hyphenation)
        try assignInteger("topMargin", \.topMargin)
        try assignInteger("fontSize", \.fontSize)
        try assignText("fontFamily", \.fontFamily)
        try assignInteger("lineSpacing", \.lineSpacing)
        if let labels = try hiddenLabels() {
            settings.bookmarksHideLabels = labels
            hasNativeValue = true
        }
        try assignBoolean("showPageNumber", \.showPageNumber)
        try assignBoolean("infiniteScroll", \.infiniteScroll)
        try assignBoolean("nonStrongsWordItalic", \.nonStrongsWordItalic)
        try assignBoolean("showMarkAsReadButton", \.showMarkAsReadButton)
        try assignBoolean("showTitleScrollButton", \.showTitleScrollButton)
        try assignBoolean("showMemorizationIndicators", \.showMemorizationIndicators)
        let autoTrackReading = try boolean("autoTrackReading")
        try assignBoolean("showAiDocMarkers", \.showAiDocMarkers)
        try assignInteger("pageScrollAmount", \.pageScrollAmount)
        let scrollHelperLines = try boolean("scrollHelperLines")
        let scrollHelperLineStyle = try integer("scrollHelperLineStyle")
        let showPageButtons = try boolean("showPageButtons")
        try assignBoolean("showOrdinals", \.showOrdinals)
        let showReadingProgress = try boolean("showReadingProgress")
        try assignInteger("margin_size_marginLeft", \.marginLeft)
        try assignInteger("margin_size_marginRight", \.marginRight)
        try assignInteger("margin_size_maxWidth", \.maxWidth)
        try assignInteger("colors_dayTextColor", \.dayTextColor)
        try assignInteger("colors_dayBackground", \.dayBackground)
        try assignInteger("colors_dayNoise", \.dayNoise)
        try assignInteger("colors_nightTextColor", \.nightTextColor)
        try assignInteger("colors_nightBackground", \.nightBackground)
        try assignInteger("colors_nightNoise", \.nightNoise)
        let dayBackgroundImage = try text("colors_dayBackgroundImage")
        let nightBackgroundImage = try text("colors_nightBackgroundImage")
        let dayBackgroundImageOpacity = try integer("colors_dayBackgroundImageOpacity")
        let nightBackgroundImageOpacity = try integer("colors_nightBackgroundImageOpacity")

        return Self(
            settings: hasNativeValue ? settings : nil,
            fidelity: .init(
                autoTrackReading: autoTrackReading,
                scrollHelperLines: scrollHelperLines,
                scrollHelperLineStyle: scrollHelperLineStyle,
                showPageButtons: showPageButtons,
                showReadingProgress: showReadingProgress,
                dayBackgroundImage: dayBackgroundImage,
                nightBackgroundImage: nightBackgroundImage,
                dayBackgroundImageOpacity: dayBackgroundImageOpacity,
                nightBackgroundImageOpacity: nightBackgroundImageOpacity
            )
        )
    }

    /** Returns a deterministic content representation containing every Room v24 column. */
    func canonicalString() -> String {
        (try? sqliteValues().map(Self.canonicalValue).joined(separator: "^")) ?? ""
    }

    /// Returns whether every native and Android-only wire column is null.
    var isEmpty: Bool {
        guard let values = try? sqliteValues() else { return false }
        return values.allSatisfy { $0.kind == .null }
    }

    /** Builds a nullable SQLite integer. */
    private static func integer(_ value: Int?) -> RemoteSyncSQLiteValue {
        value.map { .integer(Int64($0)) } ?? .null()
    }

    /** Builds a nullable SQLite Boolean integer. */
    private static func boolean(_ value: Bool?) -> RemoteSyncSQLiteValue {
        value.map { .integer($0 ? 1 : 0) } ?? .null()
    }

    /** Builds nullable SQLite text. */
    private static func text(_ value: String?) -> RemoteSyncSQLiteValue {
        value.map { .text($0) } ?? .null()
    }

    /** Converts one typed SQLite value into a stable fingerprint component. */
    private static func canonicalValue(_ value: RemoteSyncSQLiteValue) -> String {
        switch value.kind {
        case .null:
            return "n:"
        case .integer:
            return "i:\(value.integerValue ?? 0)"
        case .real:
            return "r:\(value.realValue ?? 0)"
        case .text:
            return "t:\(value.textValue ?? "")"
        case .blob:
            return "b:\(value.blobBase64Value ?? "")"
        }
    }
}

extension RemoteSyncCurrentGlobalTextDisplaySettingsRow {
    /// Android's fixed `GlobalTextDisplaySettings.SINGLETON_ID`.
    static let androidSingletonID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}
