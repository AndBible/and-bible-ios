// TextDisplaySettingsPresentation.swift - Android-backed text-display row metadata

import Foundation

/**
 Android-backed presentation and disposition metadata for the native SwiftUI All Text Options
 surface.

 Android owns the complete source inventory in `text_display_settings.xml` and resolves dynamic
 labels/icons through `OptionsMenuItems.kt`. iOS keeps this catalog as a contract so the native
 SwiftUI screen can expose only rows that have a real iOS model/renderer path while documenting
 every Android row that is adapted, deferred, or platform-specific.

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
    }

    /// Complete Android `text_display_settings.xml` row order with current iOS dispositions.
    static let androidRows: [Row] = [
        Row(
            androidKey: "open_workspace_settings",
            section: .parent,
            disposition: .adaptedElsewhere,
            note: "iOS routes reader All Text Options directly to workspace-scope settings."
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

    /// Android keys currently exposed as interactive rows in the iOS All Text Options surface.
    static var implementedAndroidKeys: [String] {
        androidRows
            .filter { $0.disposition == .implemented }
            .map(\.androidKey)
    }

    /// Android keys deferred to explicit follow-up issues rather than exposed as dead controls.
    static var deferredAndroidKeys: [String] {
        androidRows
            .filter { $0.disposition == .deferred }
            .map(\.androidKey)
    }
}
