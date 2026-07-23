// AndroidTextDisplayRecentSettings.swift -- Shared Android recent text-setting contract

import BibleCore
import Foundation

/**
 Stable Android `WorkspaceEntities.TextDisplaySettings.Types` identity.

 Raw values intentionally match the Kotlin enum names because Android serializes the five most
 recently changed types into the `lastDisplaySettings` setting as JSON. Keeping the complete enum
 here lets iOS read an Android-created preference without silently discarding a known value, while
 `isAvailableOnIOS` prevents platform-divergent controls from being exposed as fake actions.
 */
enum AndroidTextDisplaySettingType: String, CaseIterable, Codable, Sendable {
    case fontSize = "FONTSIZE"
    case fontFamily = "FONTFAMILY"
    case colors = "COLORS"
    case marginSize = "MARGINSIZE"
    case justify = "JUSTIFY"
    case hyphenation = "HYPHENATION"
    case topMargin = "TOPMARGIN"
    case lineSpacing = "LINE_SPACING"
    case strongs = "STRONGS"
    case morphology = "MORPH"
    case footnotes = "FOOTNOTES"
    case footnotesInline = "FOOTNOTES_INLINE"
    case expandXrefs = "EXPAND_XREFS"
    case xrefs = "XREFS"
    case redLetters = "REDLETTERS"
    case sectionTitles = "SECTIONTITLES"
    case verseNumbers = "VERSENUMBERS"
    case versePerLine = "VERSEPERLINE"
    case bookmarksShow = "BOOKMARKS_SHOW"
    case bookmarksHideLabels = "BOOKMARKS_HIDELABELS"
    case myNotes = "MYNOTES"
    case pageNumber = "PAGENUMBER"
    case infiniteScroll = "INFINITE_SCROLL"
    case nonStrongsWordItalic = "NON_STRONGS_WORD_ITALIC"
    case markAsReadButton = "MARK_AS_READ_BUTTON"
    case titleScrollButton = "TITLE_SCROLL_BUTTON"
    case memorizationIndicators = "MEMORIZATION_INDICATORS"
    case autoTrackReading = "AUTO_TRACK_READING"
    case aiDocumentMarkers = "AI_DOC_MARKERS"
    case pageScrollAmount = "PAGE_SCROLL_AMOUNT"
    case scrollHelperLines = "SCROLL_HELPER_LINES"
    case scrollHelperLineStyle = "SCROLL_HELPER_LINE_STYLE"
    case pageButtons = "PAGE_BUTTONS"
    case ordinals = "ORDINALS"
    case showReadingProgress = "SHOW_READING_PROGRESS"

    /// Whether the iOS model, reader bridge, and app-owned editor implement this Android type.
    var isAvailableOnIOS: Bool {
        TextDisplaySettingsPresentation.rowByAndroidKey[rawValue]?.disposition == .implemented
    }

    /// Whether Android handles this type as an immediate checkable menu command.
    var isBoolean: Bool {
        switch self {
        case .fontSize, .fontFamily, .colors, .marginSize, .topMargin, .lineSpacing,
             .strongs, .bookmarksHideLabels, .pageScrollAmount, .scrollHelperLineStyle:
            return false
        default:
            return true
        }
    }

    /// Existing shared staged editor used by Android's non-Boolean dialog preferences.
    var editorKind: TextDisplayPreferenceEditorKind? {
        switch self {
        case .strongs: return .strongsMode
        case .fontSize: return .fontSize
        case .fontFamily: return .fontFamily
        case .marginSize: return .margins
        case .topMargin: return .topMargin
        case .lineSpacing: return .lineSpacing
        case .pageScrollAmount: return .pageScrollAmount
        default: return nil
        }
    }

    /**
     Resolves Android's localized and, where applicable, value-bearing popup title.

     - Parameter settings: Fully resolved target-window settings used by Android's dynamic titles.
     - Returns: Localized menu title matching the corresponding `Preference.title` implementation.
     - Side effects: Reads localization resources only.
     - Failure modes: Missing translations fall back to Android's English presentation catalog.
     */
    func localizedTitle(settings: TextDisplaySettings) -> String {
        switch self {
        case .fontSize:
            return String.localizedStringWithFormat(
                Self.localized("font_size_title_pt", default: "Font size: %d pt"),
                settings.fontSize ?? TextDisplaySettings.appDefaults.fontSize ?? 16
            )
        case .fontFamily:
            return String.localizedStringWithFormat(
                Self.localized("pref_font_family_label_name", default: "Font family: %@"),
                settings.fontFamily ?? TextDisplaySettings.appDefaults.fontFamily ?? "sans-serif"
            )
        case .marginSize:
            return String.localizedStringWithFormat(
                Self.localized(
                    "prefs_margin_size_mm_title",
                    default: "Margins: %1$d, %2$d; max width: %3$d mm"
                ),
                settings.marginLeft ?? TextDisplaySettings.appDefaults.marginLeft ?? 3,
                settings.marginRight ?? TextDisplaySettings.appDefaults.marginRight ?? 3,
                settings.maxWidth ?? TextDisplaySettings.appDefaults.maxWidth ?? 170
            )
        case .topMargin:
            return String.localizedStringWithFormat(
                Self.localized("prefs_top_margin_title_mm", default: "Top margin: %d mm"),
                settings.topMargin ?? TextDisplaySettings.appDefaults.topMargin ?? 0
            )
        case .lineSpacing:
            let value = settings.lineSpacing ?? TextDisplaySettings.appDefaults.lineSpacing ?? 16
            return String.localizedStringWithFormat(
                Self.localized("prefs_line_spacing_pt_title", default: "Line spacing: %1.1fx"),
                Double(value) / 10.0
            )
        default:
            return Self.localized(localizationKey, default: presentationDefaultTitle)
        }
    }

    /// Android string resource used by `OptionsMenuItems.Preference.title`.
    private var localizationKey: String {
        switch self {
        case .strongs: return "prefs_show_strongs_title"
        case .morphology: return "prefs_show_morphology_title"
        case .footnotes: return "prefs_show_footnotes_title"
        case .footnotesInline: return "prefs_show_footnotes_inline_title"
        case .expandXrefs: return "prefs_expand_footnotes_title"
        case .xrefs: return "prefs_show_xrefs_title"
        case .redLetters: return "prefs_red_letter_title"
        case .sectionTitles: return "prefs_section_title_title"
        case .verseNumbers: return "prefs_show_verseno_title"
        case .versePerLine: return "prefs_verse_per_line_title"
        case .myNotes: return "prefs_show_mynotes_title"
        case .colors: return "prefs_text_colors_menutitle"
        case .justify: return "prefs_justify_title"
        case .hyphenation: return "prefs_hyphenation_title"
        case .fontSize: return "font_size_title"
        case .fontFamily: return "pref_font_family_label"
        case .marginSize: return "prefs_margin_size_title"
        case .topMargin: return "prefs_top_margin_title"
        case .lineSpacing: return "line_spacing_title"
        case .aiDocumentMarkers: return "prefs_show_ai_doc_markers_title"
        case .bookmarksShow: return "prefs_show_bookmarks_title"
        case .bookmarksHideLabels: return "bookmark_settings_hide_labels_title"
        case .pageNumber: return "page_number_title"
        case .infiniteScroll: return "prefs_infinite_scroll_title"
        case .nonStrongsWordItalic: return "prefs_non_strongs_word_italic_title"
        case .markAsReadButton: return "prefs_mark_as_read_button_title"
        case .titleScrollButton: return "prefs_title_scroll_button_title"
        case .memorizationIndicators: return "prefs_show_memorization_indicators_title"
        case .autoTrackReading: return "prefs_auto_track_reading_title"
        case .pageScrollAmount: return "prefs_page_scroll_amount_title"
        case .scrollHelperLines: return "prefs_scroll_helper_lines_title"
        case .scrollHelperLineStyle: return "prefs_scroll_helper_line_style_title"
        case .pageButtons: return "prefs_page_buttons_title"
        case .ordinals: return "prefs_show_ordinals_title"
        case .showReadingProgress: return "prefs_show_reading_progress_title"
        }
    }

    /// Android catalog fallback when one locale does not contain the expected resource key.
    private var presentationDefaultTitle: String {
        TextDisplaySettingsPresentation.rowByAndroidKey[rawValue]?.titleDefault ?? rawValue
    }

    /// Resolves one main-bundle localization without displaying the raw resource key.
    private static func localized(_ key: String, default defaultValue: String) -> String {
        let value = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? defaultValue : value
    }
}

/** Android-compatible JSON payload stored under `lastDisplaySettings`. */
private struct AndroidRecentTextDisplaySettingsPayload: Codable, Equatable {
    /// Most-recent-first type list; Android caps this list at five elements.
    var types: [AndroidTextDisplaySettingType]
}

/**
 Reads and updates Android's shared five-item recent text-setting history.

 Android records on value changes, keeps recency order in persistence, and sorts by enum name only
 when building a menu. The store deliberately uses `SettingsStore`'s raw string API because
 `lastDisplaySettings` is a CommonUtils runtime preference rather than an Application Preferences
 XML row.
 */
enum AndroidTextDisplayRecentSettings {
    /// Exact Android shared-preference/Settings key.
    static let storageKey = "lastDisplaySettings"

    /// Android's maximum retained setting types.
    static let maximumCount = 5

    /**
     Reads the persisted Android payload in most-recent-first order.

     - Parameter settingsStore: App settings owner containing the raw Android JSON value.
     - Returns: At most five known enum values; malformed or missing JSON returns an empty list.
     - Side effects: None.
     - Failure modes: Decode failures fail closed without overwriting recoverable user data.
     */
    static func recentTypes(settingsStore: SettingsStore) -> [AndroidTextDisplaySettingType] {
        guard let rawValue = settingsStore.getString(storageKey),
              let data = rawValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode(
                  AndroidRecentTextDisplaySettingsPayload.self,
                  from: data
              ) else {
            return []
        }
        return Array(payload.types.prefix(maximumCount))
    }

    /**
     Returns Android's popup order after filtering unsupported iOS types.

     Android sorts `lastDisplaySettings` by Kotlin enum name rather than recency before rendering.
     Platform-divergent types remain readable in storage but cannot become inert fake menu rows.
     */
    static func displayedTypes(settingsStore: SettingsStore) -> [AndroidTextDisplaySettingType] {
        recentTypes(settingsStore: settingsStore)
            .filter(\.isAvailableOnIOS)
            .sorted { $0.rawValue < $1.rawValue }
    }

    /**
     Records one changed setting with Android's deduplicate-and-prepend algorithm.

     - Parameters:
       - type: Exact Android text-setting type whose value was committed.
       - settingsStore: Durable app settings owner.
     - Side effects: Replaces `lastDisplaySettings` with Android-compatible JSON.
     - Failure modes: JSON encoding failure leaves the previous value unchanged.
     */
    static func record(
        _ type: AndroidTextDisplaySettingType,
        settingsStore: SettingsStore
    ) {
        var types = recentTypes(settingsStore: settingsStore)
        types.removeAll { $0 == type }
        types.insert(type, at: 0)
        types = Array(types.prefix(maximumCount))
        let payload = AndroidRecentTextDisplaySettingsPayload(types: types)
        guard let data = try? JSONEncoder().encode(payload),
              let rawValue = String(data: data, encoding: .utf8) else {
            return
        }
        settingsStore.setString(storageKey, value: rawValue)
    }
}

extension TextDisplayPreferenceEditorKind {
    /// Android setting type committed by this shared staged editor.
    var androidSettingType: AndroidTextDisplaySettingType {
        switch self {
        case .strongsMode: return .strongs
        case .fontSize: return .fontSize
        case .fontFamily: return .fontFamily
        case .margins: return .marginSize
        case .topMargin: return .topMargin
        case .lineSpacing: return .lineSpacing
        case .pageScrollAmount: return .pageScrollAmount
        }
    }
}
