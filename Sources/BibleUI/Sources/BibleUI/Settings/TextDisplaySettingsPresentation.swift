// TextDisplaySettingsPresentation.swift - Android-backed text-display row metadata

import Foundation

/**
 Android-backed presentation and disposition metadata for the native SwiftUI All Text Options
 surface.

 Android owns the complete source inventory in `text_display_settings.xml` and resolves dynamic
 labels/icons through `OptionsMenuItems.kt`. iOS keeps this catalog as a contract so the native
 SwiftUI screen can render the Android category and row inventory even when a row is not yet backed
 by an iOS model or renderer path.

 - Returns: Row metadata consumed by parity tests, documentation, and future settings work.
 - Side effects: none.
 - Failure modes: Missing icon mappings leave `icon` nil rather than crashing.
 */
enum TextDisplaySettingsPresentation {
    /**
     Android `PreferenceCategory` group represented by one text-display row.

     Explicit raw values preserve Android source identifiers when the category key is needed for
     parity docs or tests. Cases without explicit raw values use stable Swift identifiers for local
     grouping only; row-level `androidKey` values remain the source-of-truth Android metadata.
     */
    enum Section: String, CaseIterable, Sendable {
        /// Parent links between workspace/global text options in Android's nested activity.
        case parent = "parent_settings_category"

        /// Android `prefs_font_and_colors_title`.
        case fontAndColors

        /// Android `prefs_text_layout_title`.
        case textLayout

        /// Android `prefs_strongs_and_morphology_title`.
        case strongsAndMorphology

        /// Android `prefs_footnotes_and_xrefs_title`.
        case footnotesAndXrefs

        /// Android `prefs_verses_and_headings_title`.
        case versesAndHeadings

        /// Android `prefs_page_scrolling_title`.
        case pageScrolling

        /// Android `prefs_text_bookmarks_title`.
        case textBookmarks

        /// Android `prefs_reading_and_memorization_title`.
        case readingAndMemorization

        /// English Android section title from `text_display_settings.xml`.
        var titleDefault: String {
            switch self {
            case .parent:
                return "Parent settings"
            case .fontAndColors:
                return "Font & Colors"
            case .textLayout:
                return "Text Layout"
            case .strongsAndMorphology:
                return "Strong's & Morphology"
            case .footnotesAndXrefs:
                return "Footnotes & Cross-references"
            case .versesAndHeadings:
                return "Verses & Headings"
            case .pageScrolling:
                return "Page Scrolling"
            case .textBookmarks:
                return "Bookmark & My Notes settings"
            case .readingAndMemorization:
                return "Reading & Memorization"
            }
        }
    }

    /**
     Current iOS disposition for one Android text-display row.

     - `implemented`: exposed in the iOS All Text Options surface and backed by iOS model/rendering
       behavior.
     - `adaptedElsewhere`: implemented through an iOS route or adjacent settings surface rather
       than as an interactive row in the All Text Options list.
     - `deferred`: requires explicit follow-up work before exposing a native control.
     - `platformDivergence`: Android-only behavior that iOS should not expose without a new scoped
       platform feature.
     */
    enum Disposition: String, Sendable {
        case implemented
        case adaptedElsewhere
        case deferred
        case platformDivergence
    }

    /**
     One Android text-display settings row and its iOS disposition.

     - Parameters:
       - androidKey: Android preference key from `text_display_settings.xml`.
       - section: Android preference category containing the row.
       - disposition: Current iOS treatment.
       - trackingIssueNumber: GitHub issue that owns deferred convergence, when applicable.
       - note: Short rationale used by tests/docs to keep deviations intentional.
     - Returns: Value semantics suitable for tests and SwiftUI row composition.
     - Side effects: none.
     - Failure modes: Unknown Android keys resolve a nil icon.
     */
    struct Row: Equatable, Sendable {
        /// Android preference key from `text_display_settings.xml`.
        let androidKey: String

        /// Android preference category containing this row.
        let section: Section

        /// Current iOS disposition for this Android row.
        let disposition: Disposition

        /// GitHub issue that owns deferred convergence, when applicable.
        let trackingIssueNumber: Int?

        /// Short rationale for adapted/deferred/platform-specific rows.
        let note: String?

        /// Android-sourced icon metadata for this row.
        let icon: AndBibleIcon?

        /// English Android title from `text_display_settings.xml` or `OptionsMenuItems.kt`.
        var titleDefault: String {
            Self.titleDefaultsByAndroidKey[androidKey] ?? androidKey
        }

        /// English Android summary from `text_display_settings.xml` or `OptionsMenuItems.kt`.
        var summaryDefault: String? {
            Self.summaryDefaultsByAndroidKey[androidKey]
        }

        /**
         Creates one Android-backed text-display row.

         - Parameters:
           - androidKey: Android preference key from `text_display_settings.xml`.
           - section: Android preference category containing the row.
           - disposition: Current iOS treatment.
           - trackingIssueNumber: GitHub issue that owns deferred convergence, when applicable.
           - note: Short rationale for non-implemented rows.
         - Returns: A row whose icon is resolved from the shared Android icon catalog.
         - Side effects: none.
         - Failure modes: Unknown icon keys leave `icon` nil.
         */
        init(
            androidKey: String,
            section: Section,
            disposition: Disposition,
            trackingIssueNumber: Int? = nil,
            note: String? = nil
        ) {
            self.androidKey = androidKey
            self.section = section
            self.disposition = disposition
            self.trackingIssueNumber = trackingIssueNumber
            self.note = note
            self.icon = AndBibleIconCatalog.settingsIcon(forAndroidKey: androidKey)
        }

        /// English Android title defaults keyed by Android preference key.
        private static let titleDefaultsByAndroidKey: [String: String] = [
            "open_workspace_settings": "Workspace text options",
            "open_global_settings": "Global text options",
            "COLORS": "Color settings",
            "FONTSIZE": "Font size",
            "FONTFAMILY": "Font family",
            "LINE_SPACING": "Line spacing",
            "REDLETTERS": "Red Letter",
            "MARGINSIZE": "Change margin size",
            "TOPMARGIN": "Top margin",
            "JUSTIFY": "Justify-align text",
            "HYPHENATION": "Hyphenation",
            "VERSEPERLINE": "One verse per line",
            "STRONGS": "Strong's numbers",
            "MORPH": "Morphological codes",
            "NON_STRONGS_WORD_ITALIC": "Italicize added words",
            "FOOTNOTES": "Footnotes",
            "FOOTNOTES_INLINE": "Footnotes inline",
            "XREFS": "Cross references",
            "EXPAND_XREFS": "Inline cross references",
            "VERSENUMBERS": "Chapter & verse numbers",
            "SECTIONTITLES": "Section titles",
            "TITLE_SCROLL_BUTTON": "Title scroll button",
            "PAGENUMBER": "Relative page number",
            "INFINITE_SCROLL": "Infinite scroll",
            "PAGE_SCROLL_AMOUNT": "Page scroll amount",
            "SCROLL_HELPER_LINES": "Scroll helper lines",
            "SCROLL_HELPER_LINE_STYLE": "Helper line style",
            "PAGE_BUTTONS": "Page scroll buttons",
            "ORDINALS": "Show ordinal numbers",
            "BOOKMARKS_SHOW": "Show bookmarks",
            "MYNOTES": "Show My Note icons",
            "AI_DOC_MARKERS": "Show AI document markers",
            "BOOKMARKS_HIDELABELS": "Hide specified labels",
            "MARK_AS_READ_BUTTON": "Mark as read button",
            "MEMORIZATION_INDICATORS": "Memorization indicators",
            "AUTO_TRACK_READING": "Auto-track reading",
        ]

        /// English Android summary defaults keyed by Android preference key.
        private static let summaryDefaultsByAndroidKey: [String: String] = [
            "open_workspace_settings": "Edit text display settings for this workspace",
            "open_global_settings": "Edit default text display settings for all workspaces",
            "COLORS": "Adjust text and background colors and noise effect",
            "FONTSIZE": "Adjust main text font size",
            "FONTFAMILY": "Change font family. Tip: more fonts can be installed via Download Documents / Add-ons.",
            "LINE_SPACING": "Set the space between lines",
            "REDLETTERS": "Show words of Christ in red",
            "MARGINSIZE": "Adjust left and right margin of the text view. You can also set maximum width of text. Tip: You can tap margin area to jump one page up / down.",
            "TOPMARGIN": "Add margin (with visual indication) to top of the window that contains Bible document. Bible is scrolled so that current verse starts below the margin.",
            "JUSTIFY": "Align text in 'justify' style, meaning left and right margins of the text are in line",
            "HYPHENATION": "Automatically hyphenate words, if language is supported",
            "VERSEPERLINE": "Show each verse on a different line",
            "STRONGS": "Links to Greek & Hebrew definitions",
            "MORPH": "Show Robinson's Greek morphology",
            "NON_STRONGS_WORD_ITALIC": "Italicize words without Strong's numbers",
            "FOOTNOTES": "Show footnotes, if they are available in the document",
            "FOOTNOTES_INLINE": "Show footnotes inline with the text instead of as clickable handles",
            "XREFS": "Show cross references, if they are available in the document",
            "EXPAND_XREFS": "Show cross reference content in-line within the text, instead of a link that opens a pop-up dialog",
            "VERSENUMBERS": "Show chapter & verse numbers",
            "SECTIONTITLES": "Show non-canonical section titles",
            "TITLE_SCROLL_BUTTON": "Show scroll-to-top button next to section titles",
            "PAGENUMBER": "Show page number overlay. Page number is relative to the starting position.",
            "INFINITE_SCROLL": "Automatically load more content when scrolling",
            "PAGE_SCROLL_AMOUNT": "How much of the page to scroll with page up/down",
            "SCROLL_HELPER_LINES": "Show horizontal guide lines at page scroll boundaries",
            "SCROLL_HELPER_LINE_STYLE": "Choose the visual style of scroll helper lines",
            "PAGE_BUTTONS": "Show visible page up/down buttons on screen",
            "ORDINALS": "Show ordinal position markers in text",
            "BOOKMARKS_SHOW": "Untick to hide all bookmarks",
            "MYNOTES": "Show icon in verses with My Note",
            "AI_DOC_MARKERS": "Show marker icons for AI-generated document pages linked to verses",
            "BOOKMARKS_HIDELABELS": "Hide bookmarks that are marked with specified label(s)",
            "MARK_AS_READ_BUTTON": "Show a button at the end of each chapter to mark it as read",
            "MEMORIZATION_INDICATORS": "Show colored margin indicators for memorized and target verses",
            "AUTO_TRACK_READING": "Automatically mark chapters as read when you scroll through them",
        ]
    }

    /// Complete Android `text_display_settings.xml` row order with current iOS dispositions.
    static let androidRows: [Row] = [
        Row(
            androidKey: "open_workspace_settings",
            section: .parent,
            disposition: .adaptedElsewhere,
            note: "iOS exposes this as the window-scope parent link to workspace text options."
        ),
        Row(
            androidKey: "open_global_settings",
            section: .parent,
            disposition: .adaptedElsewhere,
            note: "iOS keeps global text-display defaults under Application Preferences."
        ),
        Row(androidKey: "COLORS", section: .fontAndColors, disposition: .implemented),
        Row(androidKey: "FONTSIZE", section: .fontAndColors, disposition: .implemented),
        Row(androidKey: "FONTFAMILY", section: .fontAndColors, disposition: .implemented),
        Row(androidKey: "LINE_SPACING", section: .fontAndColors, disposition: .implemented),
        Row(androidKey: "REDLETTERS", section: .fontAndColors, disposition: .implemented),
        Row(androidKey: "MARGINSIZE", section: .textLayout, disposition: .implemented),
        Row(androidKey: "TOPMARGIN", section: .textLayout, disposition: .implemented),
        Row(androidKey: "JUSTIFY", section: .textLayout, disposition: .implemented),
        Row(androidKey: "HYPHENATION", section: .textLayout, disposition: .implemented),
        Row(androidKey: "VERSEPERLINE", section: .textLayout, disposition: .implemented),
        Row(androidKey: "STRONGS", section: .strongsAndMorphology, disposition: .implemented),
        Row(androidKey: "MORPH", section: .strongsAndMorphology, disposition: .implemented),
        Row(
            androidKey: "NON_STRONGS_WORD_ITALIC",
            section: .strongsAndMorphology,
            disposition: .deferred,
            trackingIssueNumber: 174,
            note: "iOS shared client has no config/rendering field yet."
        ),
        Row(androidKey: "FOOTNOTES", section: .footnotesAndXrefs, disposition: .implemented),
        Row(androidKey: "FOOTNOTES_INLINE", section: .footnotesAndXrefs, disposition: .implemented),
        Row(androidKey: "XREFS", section: .footnotesAndXrefs, disposition: .implemented),
        Row(androidKey: "EXPAND_XREFS", section: .footnotesAndXrefs, disposition: .implemented),
        Row(androidKey: "VERSENUMBERS", section: .versesAndHeadings, disposition: .implemented),
        Row(androidKey: "SECTIONTITLES", section: .versesAndHeadings, disposition: .implemented),
        Row(
            androidKey: "TITLE_SCROLL_BUTTON",
            section: .versesAndHeadings,
            disposition: .deferred,
            trackingIssueNumber: 174,
            note: "iOS shared client has no title-scroll-button field yet."
        ),
        Row(androidKey: "PAGENUMBER", section: .versesAndHeadings, disposition: .implemented),
        Row(
            androidKey: "INFINITE_SCROLL",
            section: .pageScrolling,
            disposition: .deferred,
            trackingIssueNumber: 174,
            note: "iOS reader paging/scroll config is not wired to this Android field yet."
        ),
        Row(
            androidKey: "PAGE_SCROLL_AMOUNT",
            section: .pageScrolling,
            disposition: .deferred,
            trackingIssueNumber: 174,
            note: "iOS shared client has no page-scroll-amount field yet."
        ),
        Row(
            androidKey: "SCROLL_HELPER_LINES",
            section: .pageScrolling,
            disposition: .platformDivergence,
            note: "Android shows this only in e-ink mode; iOS has no e-ink mode."
        ),
        Row(
            androidKey: "SCROLL_HELPER_LINE_STYLE",
            section: .pageScrolling,
            disposition: .platformDivergence,
            note: "Android shows this only in e-ink mode; iOS has no e-ink mode."
        ),
        Row(
            androidKey: "PAGE_BUTTONS",
            section: .pageScrolling,
            disposition: .platformDivergence,
            note: "Android shows this only in e-ink mode; iOS has no e-ink mode."
        ),
        Row(
            androidKey: "ORDINALS",
            section: .pageScrolling,
            disposition: .deferred,
            trackingIssueNumber: 174,
            note: "iOS shared client has no ordinals visibility field yet."
        ),
        Row(androidKey: "BOOKMARKS_SHOW", section: .textBookmarks, disposition: .implemented),
        Row(androidKey: "MYNOTES", section: .textBookmarks, disposition: .implemented),
        Row(
            androidKey: "AI_DOC_MARKERS",
            section: .textBookmarks,
            disposition: .deferred,
            trackingIssueNumber: 174,
            note: "iOS AI document marker rendering is not implemented yet."
        ),
        Row(androidKey: "BOOKMARKS_HIDELABELS", section: .textBookmarks, disposition: .implemented),
        Row(
            androidKey: "MARK_AS_READ_BUTTON",
            section: .readingAndMemorization,
            disposition: .deferred,
            trackingIssueNumber: 174,
            note: "iOS shared client has no mark-as-read button config field yet."
        ),
        Row(
            androidKey: "MEMORIZATION_INDICATORS",
            section: .readingAndMemorization,
            disposition: .deferred,
            trackingIssueNumber: 174,
            note: "iOS shared client has no memorization indicator config field yet."
        ),
        Row(
            androidKey: "AUTO_TRACK_READING",
            section: .readingAndMemorization,
            disposition: .adaptedElsewhere,
            note: "iOS implements this under Reading Progress Settings and emits appSettings.autoTrackReading."
        ),
    ]

    /// Android row metadata keyed by Android preference key.
    static let rowByAndroidKey: [String: Row] = Dictionary(
        uniqueKeysWithValues: androidRows.map { ($0.androidKey, $0) }
    )

    /// Android keys currently exposed as interactive rows in the iOS All Text Options surface.
    static var implementedAndroidKeys: [String] {
        androidRows
            .filter { $0.disposition == .implemented }
            .map(\.androidKey)
    }

    /// Android keys visible as disabled parity targets until explicit follow-up issues implement them.
    static var deferredAndroidKeys: [String] {
        androidRows
            .filter { $0.disposition == .deferred }
            .map(\.androidKey)
    }

    /**
     Android rows visible in the normal iOS window-level All Text Options screen.

     Android shows workspace/global parent links at window scope and hides e-ink-only
     page-scrolling rows unless e-ink mode is enabled. iOS has no e-ink mode, so
     platform-divergence e-ink rows stay documented in `androidRows` but are not rendered in the
     standard iOS list.
     */
    static var iosWindowVisibleAndroidKeys: [String] {
        androidRows
            .filter { $0.disposition != .platformDivergence }
            .map(\.androidKey)
    }

    /**
     Android rows visible when the user follows the parent link to workspace-level text options.

     Android hides the workspace parent link at workspace scope, leaves the global parent link
     visible, and still hides e-ink-only page-scrolling rows when e-ink mode is disabled.
     */
    static var iosWorkspaceVisibleAndroidKeys: [String] {
        androidRows
            .filter { row in
                row.androidKey != "open_workspace_settings" &&
                    row.disposition != .platformDivergence
            }
            .map(\.androidKey)
    }

    /**
     Android rows visible when editing global text options.

     Android hides the whole parent category at global scope. iOS follows that behavior and keeps
     e-ink-only page-scrolling rows documented but hidden because there is no iOS e-ink mode.
     */
    static var iosGlobalVisibleAndroidKeys: [String] {
        androidRows
            .filter { row in
                row.section != .parent &&
                    row.disposition != .platformDivergence
            }
            .map(\.androidKey)
    }
}
