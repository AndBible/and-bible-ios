// AndBibleIconCatalog.swift - Android-sourced icon metadata

import Foundation

/**
 Describes one packaged AndBible icon and, when applicable, its Android drawable source.

 The value keeps source metadata beside the iOS asset name so settings, toolbar, drawer, and overflow
 code can converge on one icon contract without physically merging unrelated asset catalogs. Android
 drawable metadata is optional because some existing iOS assets are already named by their UI role
 rather than by a specific Android preference key.

 - Parameters:
   - assetName: iOS asset catalog image name available to the `BibleUI` module bundle.
   - androidDrawableName: Android drawable resource name without the `@drawable/` prefix, when this
     icon is copied from an Android XML/drawable source.
 - Returns: Value semantics suitable for tests, row metadata, and SwiftUI rendering decisions.
 - Side effects: none.
 - Failure modes: Asset and drawable names are not validated at construction time; resource loading
   failures are handled by `AndBibleIconView` when a missing asset is rendered.
 */
struct AndBibleIcon: Equatable, Sendable {
    /// iOS template image asset name used by SwiftUI `Image`.
    let assetName: String

    /// Android drawable resource name, excluding the `@drawable/` prefix, when Android defines one.
    let androidDrawableName: String?
}

/**
 Canonical icon metadata catalog for Android-parity AndBible glyphs.

 Settings entries are copied from Android `settings.xml`, `sync_settings.xml`,
 `text_display_settings.xml`, and `OptionsMenuItems.kt`. Keeping the mapping in one catalog prevents
 individual screens from selecting ad hoc SF Symbols or screenshot-derived substitutes, while still
 allowing separate physical asset catalogs for settings, toolbar, drawer, and overflow images.

 - Parameter key: Android preference/action key such as `navigate_to_verse_pref`.
 - Returns: `AndBibleIcon` records for rows that have Android source icons.
 - Side effects: none.
 - Failure modes: Unknown keys return `nil`, allowing iOS-only rows to document deliberate fallback
   treatment without crashing.
 */
enum AndBibleIconCatalog {
    /// Application preferences icon mappings from Android `app/src/main/res/xml/settings.xml`.
    private static let applicationSettingsIconByAndroidKey: [String: AndBibleIcon] = [
        "strongs_greek_dictionary": .init(
            assetName: "SettingsIconStrongsGreek",
            androidDrawableName: "ic_strongs_greek"
        ),
        "strongs_hebrew_dictionary": .init(
            assetName: "SettingsIconStrongsHebrew",
            androidDrawableName: "ic_strongs_hebrew"
        ),
        "robinson_greek_morphology": .init(
            assetName: "SettingsIconMorphology",
            androidDrawableName: "ic_morphology_24dp"
        ),
        "disabled_word_lookup_dictionaries": .init(
            assetName: "SettingsIconDictionary",
            androidDrawableName: "ic_dictionary_24dp"
        ),
        "navigate_to_verse_pref": .init(
            assetName: "SettingsIconChapterVerseNumbers",
            androidDrawableName: "ic_chapter_verse_numbers_24dp"
        ),
        "open_links_in_special_window_pref": .init(
            assetName: "SettingsIconLinksWindow",
            androidDrawableName: "ic_link_window_24dp"
        ),
        "screen_keep_on_pref": .init(
            assetName: "SettingsIconLightMode",
            androidDrawableName: "ic_baseline_light_mode_24"
        ),
        "double_tap_to_fullscreen": .init(
            assetName: "SettingsIconFullscreen",
            androidDrawableName: "ic_full_screen_24"
        ),
        "auto_fullscreen_pref": .init(
            assetName: "SettingsIconFullscreenByScrolling",
            androidDrawableName: "ic_full_screen_by_scrolling_24dp"
        ),
        "toolbar_button_actions": .init(
            assetName: "SettingsIconButtonPressAction",
            androidDrawableName: "ic_action_for_button_press_24dp"
        ),
        "disable_two_step_bookmarking": .init(
            assetName: "SettingsIconBookmark",
            androidDrawableName: "ic_bookmark_24dp"
        ),
        "bible_view_swipe_mode": .init(
            assetName: "SettingsIconFullscreenByScrolling",
            androidDrawableName: "ic_full_screen_by_scrolling_24dp"
        ),
        "volume_keys_scroll": .init(
            assetName: "SettingsIconVolumeUp",
            androidDrawableName: "ic_baseline_volume_up_24"
        ),
        "night_mode_pref3": .init(
            assetName: "SettingsIconNightModeSwitching",
            androidDrawableName: "ic_night_mode_switching_24dp"
        ),
        "global_text_display_settings": .init(
            assetName: "SettingsIconTextFormat",
            androidDrawableName: "ic_text_format_white_24dp"
        ),
        "open_workspace_settings": .init(
            assetName: "SettingsIconWorkspace",
            androidDrawableName: "ic_workspace_overlay_24dp"
        ),
        "open_global_settings": .init(
            assetName: "SettingsIconSettings",
            androidDrawableName: "ic_settings_black_24dp"
        ),
        "locale_pref": .init(
            assetName: "SettingsIconApplicationLanguage",
            androidDrawableName: "ic_application_language_24dp"
        ),
        "disable_click_to_edit": .init(
            assetName: "SettingsIconClick",
            androidDrawableName: "ic_click_24dp"
        ),
        "notes_content_type": .init(
            assetName: "SettingsIconTextFormat",
            androidDrawableName: "ic_text_format_white_24dp"
        ),
        "font_size_multiplier": .init(
            assetName: "SettingsIconFontSize",
            androidDrawableName: "ic_font_size_grey_24dp"
        ),
        "full_screen_hide_buttons_pref": .init(
            assetName: "SettingsIconHideWindowButtonBar",
            androidDrawableName: "ic_hide_window_button_bar_24dp"
        ),
        "hide_window_buttons": .init(
            assetName: "SettingsIconHideWindowButtons",
            androidDrawableName: "ic_hide_window_buttons_24dp"
        ),
        "hide_bible_reference_overlay": .init(
            assetName: "SettingsIconHideBibleReferenceOverlay",
            androidDrawableName: "ic_hide_bible_reference_overlay_24dp"
        ),
        "show_active_window_indicator": .init(
            assetName: "SettingsIconActiveWindow",
            androidDrawableName: "ic_active_window_24dp"
        ),
        "disable_bible_bookmark_modal_buttons": .init(
            assetName: "SettingsIconOneTapBible",
            androidDrawableName: "ic_one_tap_bible_24"
        ),
        "disable_gen_bookmark_modal_buttons": .init(
            assetName: "SettingsIconOneTapOther",
            androidDrawableName: "ic_one_tap_other_24"
        ),
        "monochrome_mode": .init(
            assetName: "SettingsIconEink",
            androidDrawableName: "ic_eink_24dp"
        ),
        "eink_mode": .init(
            assetName: "SettingsIconEink",
            androidDrawableName: "ic_eink_24dp"
        ),
        "disable_animations": .init(
            assetName: "SettingsIconAnimate",
            androidDrawableName: "ic_animate_24dp"
        ),
        "discrete_help": .init(
            assetName: "SettingsIconWarning",
            androidDrawableName: "ic_warning_red_24dp"
        ),
        "discrete_mode": .init(
            assetName: "SettingsIconCalculator",
            androidDrawableName: "ic_calc_24"
        ),
        "show_calculator": .init(
            assetName: "SettingsIconCalculatorSmokeScreen",
            androidDrawableName: "ic_calc_smoke_screen"
        ),
        "calculator_pin": .init(
            assetName: "SettingsIconCalculatorPin",
            androidDrawableName: "ic_calc_pin"
        ),
        "sync_settings_shortcut": .init(
            assetName: "SettingsIconSync",
            androidDrawableName: "ic_syncdb_24dp"
        ),
        "ai_settings_shortcut": .init(
            assetName: "SettingsIconRobot",
            androidDrawableName: "icon_robot"
        ),
        "reading_progress_settings_shortcut": .init(
            assetName: "SettingsIconCheckCircle",
            androidDrawableName: "ic_baseline_check_circle_24"
        ),
        "experimental_features": .init(
            assetName: "SettingsIconBugReport",
            androidDrawableName: "ic_bug_report_white_24dp"
        ),
        "enable_bluetooth_pref": .init(
            assetName: "SettingsIconBluetoothMedia",
            androidDrawableName: "ic_baseline_media_bluetooth_on_24"
        ),
        "show_errorbox": .init(
            assetName: "SettingsIconBugReport",
            androidDrawableName: "ic_bug_report_white_24dp"
        ),
        "open_links": .init(
            assetName: "SettingsIconLink",
            androidDrawableName: "ic_link_black_24dp"
        ),
        "crash_app": .init(
            assetName: "SettingsIconBugReport",
            androidDrawableName: "ic_bug_report_white_24dp"
        )
    ]

    /// Sync settings icon mappings from Android `app/src/main/res/xml/sync_settings.xml`.
    private static let syncSettingsIconByAndroidKey: [String: AndBibleIcon] = [
        "sync_adapter": .init(
            assetName: "SettingsIconSync",
            androidDrawableName: "ic_syncdb_24dp"
        ),
        "reset_or_sign_out": .init(
            assetName: "SettingsIconLogout",
            androidDrawableName: "baseline_logout_24"
        ),
        "sync_info": .init(
            assetName: "SettingsIconInfo",
            androidDrawableName: "ic_info_grey_24dp"
        ),
        "remote_storage": .init(
            assetName: "SettingsIconShield",
            androidDrawableName: "outline_shield_24"
        ),
        "sync_bookmarks": .init(
            assetName: "SettingsIconBookmark",
            androidDrawableName: "ic_bookmark_24dp"
        ),
        "sync_workspaces": .init(
            assetName: "SettingsIconWorkspace",
            androidDrawableName: "ic_baseline_workspace_24"
        ),
        "sync_reading_plans": .init(
            assetName: "SettingsIconReadingPlan",
            androidDrawableName: "ic_reading_plan_24dp"
        ),
        "sync_documents": .init(
            assetName: "SettingsIconDescription",
            androidDrawableName: "ic_baseline_description_gray_24"
        ),
        "sync_ai": .init(
            assetName: "SettingsIconRobot",
            androidDrawableName: "icon_robot"
        ),
        "sync_reading_progress": .init(
            assetName: "SettingsIconCheckCircle",
            androidDrawableName: "ic_baseline_check_circle_24"
        )
    ]

    /// AI connection preference icons from Android `ai_connection_settings.xml`.
    private static let aiConnectionSettingsIconByAndroidKey: [String: AndBibleIcon] = [
        "ai_disclaimer_warning": .init(
            assetName: "SettingsIconWarning",
            androidDrawableName: "ic_warning_red_24dp"
        ),
        "ai_getting_started": .init(
            assetName: "SettingsIconCloud",
            androidDrawableName: "ic_baseline_cloud_24"
        ),
        "ai_providers_shortcut": .init(
            assetName: "SettingsIconCloud",
            androidDrawableName: "ic_baseline_cloud_24"
        ),
        "ai_models_shortcut": .init(
            assetName: "SettingsIconRobot",
            androidDrawableName: "icon_robot"
        ),
        "agent_permission_mode": .init(
            assetName: "SettingsIconShield",
            androidDrawableName: "ic_baseline_security_24"
        ),
        "manage_tool_permissions": .init(
            assetName: "SettingsIconShield",
            androidDrawableName: "ic_baseline_security_24"
        ),
        "llm_reset_usage": .init(
            assetName: "ActivityReset",
            androidDrawableName: "ic_baseline_refresh_gray_24"
        ),
        "raw_log_retention": .init(
            assetName: "ActivityDelete",
            androidDrawableName: "ic_delete_24dp"
        ),
        "model_override": .init(
            assetName: "SettingsIconCloud",
            androidDrawableName: "ic_baseline_cloud_24"
        ),
        "strict_context_matching": .init(
            assetName: "SettingsIconDescription",
            androidDrawableName: "ic_baseline_description_gray_24"
        ),
        "max_iterations": .init(
            assetName: "ActivityReset",
            androidDrawableName: "ic_baseline_refresh_gray_24"
        ),
        "specify_before_run": .init(
            assetName: "PromptAdvancedKeyboard",
            androidDrawableName: "ic_baseline_keyboard_24"
        ),
        "no_document_creation": .init(
            assetName: "PromptAdvancedVisibilityOff",
            androidDrawableName: "ic_baseline_visibility_off_24"
        ),
        "auto_include_documents": .init(
            assetName: "PromptAdvancedDocuments",
            androidDrawableName: "ic_baseline_menu_book_gray_24"
        ),
        "auto_include_commentaries": .init(
            assetName: "PromptAdvancedCommentaries",
            androidDrawableName: "ic_baseline_chat_bubble_outline_gray_24"
        ),
    ].merging(
        Dictionary(
            uniqueKeysWithValues: [
                "ai_language",
                "manage_ai_documents",
                "commentary_max_response_chars",
                "agent_max_iterations",
                "ask_model_before_run",
                "auto_hide_agent_log_on_completion",
                "custom_agent_system_prompt",
                "custom_text_transform_system_prompt",
                "llm_usage_summary",
                "raw_log_history",
            ].map { key in
                (
                    key,
                    AndBibleIcon(
                        assetName: "SettingsIconDescription",
                        androidDrawableName: "ic_baseline_description_gray_24"
                    )
                )
            }
        )
    ) { explicit, _ in explicit }

    /// Text display icon mappings from Android `OptionsMenuItems.kt` and `text_display_settings.xml`.
    private static let textDisplayIconByAndroidKey: [String: AndBibleIcon] = [
        "STRONGS": .init(
            assetName: "SettingsIconStrongsGreek",
            androidDrawableName: "ic_strongs_greek"
        ),
        "BOOKMARKS_SHOW": .init(
            assetName: "SettingsIconBookmarksShow",
            androidDrawableName: "ic_bookmarks_show_24dp"
        ),
        "BOOKMARKS_HIDELABELS": .init(
            assetName: "SettingsIconLabelsHide",
            androidDrawableName: "ic_labels_hide_24dp"
        ),
        "MORPH": .init(
            assetName: "SettingsIconMorphology",
            androidDrawableName: "ic_morphology_24dp"
        ),
        "FOOTNOTES": .init(
            assetName: "SettingsIconFootnotes",
            androidDrawableName: "ic_footnotes_24dp"
        ),
        "FOOTNOTES_INLINE": .init(
            assetName: "SettingsIconStar",
            androidDrawableName: "ic_baseline_star_24"
        ),
        "EXPAND_XREFS": .init(
            assetName: "SettingsIconXrefsInline",
            androidDrawableName: "ic_xrefs_inline_24dp"
        ),
        "XREFS": .init(
            assetName: "SettingsIconXrefs",
            androidDrawableName: "ic_xrefs_24dp"
        ),
        "SECTIONTITLES": .init(
            assetName: "SettingsIconSectionTitles",
            androidDrawableName: "ic_section_titles_24dp"
        ),
        "TITLE_SCROLL_BUTTON": .init(
            assetName: "SettingsIconSectionTitles",
            androidDrawableName: "ic_section_titles_24dp"
        ),
        "VERSENUMBERS": .init(
            assetName: "SettingsIconChapterVerseNumbers",
            androidDrawableName: "ic_chapter_verse_numbers_24dp"
        ),
        "PAGENUMBER": .init(
            assetName: "SettingsIconChapterVerseNumbers",
            androidDrawableName: "ic_chapter_verse_numbers_24dp"
        ),
        "COLORS": .init(
            assetName: "SettingsIconColorSettings",
            androidDrawableName: "ic_color_settings_24dp"
        ),
        "FONTSIZE": .init(
            assetName: "SettingsIconTextFontSize",
            androidDrawableName: "ic_font_size_24dp"
        ),
        "FONTFAMILY": .init(
            assetName: "SettingsIconFontFamily",
            androidDrawableName: "ic_font_family_24dp"
        ),
        "MARGINSIZE": .init(
            assetName: "SettingsIconMarginSize",
            androidDrawableName: "ic_margin_size_24dp"
        ),
        "TOPMARGIN": .init(
            assetName: "SettingsIconMarginTop",
            androidDrawableName: "ic_margin_top_24dp"
        ),
        "LINE_SPACING": .init(
            assetName: "SettingsIconLineSpacing",
            androidDrawableName: "ic_line_spacing_24dp"
        ),
        "REDLETTERS": .init(
            assetName: "SettingsIconRedLetter",
            androidDrawableName: "ic_red_letter_24dp"
        ),
        "VERSEPERLINE": .init(
            assetName: "SettingsIconOneVersePerLine",
            androidDrawableName: "ic_one_verse_per_line_24dp"
        ),
        "JUSTIFY": .init(
            assetName: "SettingsIconJustifyText",
            androidDrawableName: "ic_justify_text_24dp"
        ),
        "HYPHENATION": .init(
            assetName: "SettingsIconHyphenation",
            androidDrawableName: "ic_hyphenation_24dp"
        ),
        "MYNOTES": .init(
            assetName: "SettingsIconNote",
            androidDrawableName: "ic_note_regular_24dp"
        ),
        "INFINITE_SCROLL": .init(
            assetName: "SettingsIconFullscreenByScrolling",
            androidDrawableName: "ic_full_screen_by_scrolling_24dp"
        ),
        "PAGE_SCROLL_AMOUNT": .init(
            assetName: "SettingsIconStar",
            androidDrawableName: "ic_baseline_star_24"
        ),
        "SCROLL_HELPER_LINES": .init(
            assetName: "SettingsIconStar",
            androidDrawableName: "ic_baseline_star_24"
        ),
        "SCROLL_HELPER_LINE_STYLE": .init(
            assetName: "SettingsIconStar",
            androidDrawableName: "ic_baseline_star_24"
        ),
        "PAGE_BUTTONS": .init(
            assetName: "SettingsIconStar",
            androidDrawableName: "ic_baseline_star_24"
        ),
        "ORDINALS": .init(
            assetName: "SettingsIconStar",
            androidDrawableName: "ic_baseline_star_24"
        ),
        "NON_STRONGS_WORD_ITALIC": .init(
            assetName: "SettingsIconItalic",
            androidDrawableName: "ic_format_italic_24dp"
        ),
        "AI_DOC_MARKERS": .init(
            assetName: "SettingsIconStar",
            androidDrawableName: "ic_baseline_star_24"
        ),
        "MARK_AS_READ_BUTTON": .init(
            assetName: "SettingsIconCheckCircle",
            androidDrawableName: "ic_baseline_check_circle_24"
        ),
        "MEMORIZATION_INDICATORS": .init(
            assetName: "SettingsIconCheckCircle",
            androidDrawableName: "ic_baseline_check_circle_24"
        ),
        "AUTO_TRACK_READING": .init(
            assetName: "SettingsIconCheckCircle",
            androidDrawableName: "ic_baseline_check_circle_24"
        )
    ]

    /// Combined Android settings icon mappings keyed by Android preference/action key.
    static let settingsIconByAndroidKey: [String: AndBibleIcon] = {
        applicationSettingsIconByAndroidKey
            .merging(syncSettingsIconByAndroidKey) { applicationIcon, _ in applicationIcon }
            .merging(textDisplayIconByAndroidKey) { applicationIcon, _ in applicationIcon }
            .merging(aiConnectionSettingsIconByAndroidKey) { existingIcon, _ in existingIcon }
    }()

    /**
     Returns Android-sourced settings icon metadata for one Android preference/action key.

     - Parameter key: Android preference or action key from settings XML or `OptionsMenuItems.kt`.
     - Returns: Icon metadata when Android defines a drawable for the key; otherwise `nil`.
     - Side effects: none.
     - Failure modes: Unknown keys are intentionally non-fatal so platform-specific rows can opt
       into documented fallback behavior.
     */
    static func settingsIcon(forAndroidKey key: String) -> AndBibleIcon? {
        settingsIconByAndroidKey[key]
    }
}
