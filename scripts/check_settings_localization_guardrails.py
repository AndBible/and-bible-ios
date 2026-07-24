#!/usr/bin/env python3
"""
SETPAR-603 localization guardrails for settings parity keys.

Checks:
1. AndBible and Localizations trees must match for tracked settings keys.
2. No iOS locale can remain English for a key when Android has a non-English translation.
3. Per-key English-placeholder count may not exceed committed baseline (plus optional allowance).
4. The iOS locale_pref picker must match Android arrays.xml values that have iOS resources.
5. Runtime Calculator security help must use Android copy plus the truthful iOS name limitation.
6. Every AI source key and literal fallback must have exact Android provenance.
7. Product-feedback copy must cover every shipped locale with Android provenance or truthful iOS fallback.
8. Every statically declared shipped localization key must participate in Android-source discovery.
9. Shipped SwiftUI presentation code may not embed user-visible prose as an unlocalized literal.

Usage:
  python3 scripts/check_settings_localization_guardrails.py
  python3 scripts/check_settings_localization_guardrails.py --write-baseline
  python3 scripts/check_settings_localization_guardrails.py --write-android-snapshot
  python3 scripts/check_settings_localization_guardrails.py --sync-android-shared-translations
  python3 scripts/check_settings_localization_guardrails.py --sync-android-ai-translations
  python3 scripts/check_settings_localization_guardrails.py --sync-discrete-security-copy
  python3 scripts/check_settings_localization_guardrails.py --sync-product-feedback-copy
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path
import re
import xml.etree.ElementTree as ET


PARITY_KEYS = [
    "choose_strongs_greek_dictionary_title",
    "choose_strongs_greek_dictionary_summary",
    "choose_strongs_hebrew_dictionary_title",
    "choose_strongs_hebrew_dictionary_summary",
    "choose_strongs_greek_morphology_title",
    "choose_strongs_greek_morphology_summary",
    "choose_word_lookup_dictionary_title",
    "choose_word_lookup_dictionary_summary",
    "prefs_behavior_customization_cat",
    "prefs_display_customization_cat",
    "prefs_advanced_settings_cat",
    "prefs_navigate_to_verse_title",
    "prefs_navigate_to_verse_summary",
    "prefs_open_links_in_special_window_title",
    "prefs_open_links_in_special_window_summary",
    "prefs_screen_keep_on_title",
    "prefs_screen_keep_on_summary",
    "prefs_double_tap_to_fullscreen_title",
    "prefs_double_tap_to_fullscreen_summary",
    "auto_fullscreen",
    "auto_fullscreen_summary",
    "prefs_toolbar_button_action_title",
    "prefs_toolbar_button_action_summary",
    "prefs_disable_two_step_bookmarking_title",
    "prefs_disable_two_step_bookmarking_summary",
    "prefs_bible_view_swipe_mode_title",
    "prefs_bible_view_swipe_mode_summary",
    "prefs_volume_keys_scroll_title",
    "prefs_volume_keys_scroll_summary",
    "prefs_night_mode_title",
    "prefs_night_mode_summary",
    "prefs_interface_locale_title",
    "prefs_interface_locale_summary",
    "prefs_e_ink_mode_title",
    "prefs_eink_mode_summary",
    "prefs_disable_animations_title",
    "prefs_disable_animations_summary",
    "prefs_disable_click_to_edit_title",
    "prefs_disable_click_to_edit_summary",
    "pref_font_size_multiplier_title",
    "full_screen_hide_buttons_pref_title",
    "full_screen_hide_buttons_pref_summary",
    "hide_window_buttons_title",
    "hide_window_buttons_summary",
    "hide_bible_reference_overlay_title",
    "hide_bible_reference_overlay_summary",
    "active_window_indicator_title",
    "active_window_indicator_summary",
    "prefs_experimental_features_title",
    "prefs_experimental_features_summary",
    "prefs_enable_bluetooth_title",
    "prefs_enable_bluetooth_summary",
    "prefs_show_error_box_title",
    "prefs_show_error_box_summary",
    "open_bible_links_title",
    "open_bible_links_summary",
    "crash_app",
    "crash_app_summary",
]


LOCALE_TO_ANDROID_VALUES = {
    "af": "values-af",
    "ar": "values-ar",
    "az": "values-az",
    "bg": "values-bg",
    "bn": "values-bn",
    "ca": "values-ca",
    "cs": "values-cs",
    "da": "values-da",
    "de": "values-de",
    "el": "values-el",
    "en": "values",
    "eo": "values-eo",
    "es": "values-es",
    "et": "values-et",
    "fil": "values-fil",
    "fi": "values-fi",
    "fr": "values-fr",
    "he": "values-iw",
    "hi": "values-hi",
    "hr": "values-hr",
    "hu": "values-hu",
    "id": "values-id",
    "it": "values-it",
    "ja": "values-ja",
    "kk": "values-kk",
    "ko": "values-ko",
    "lt": "values-lt",
    "ml": "values-ml",
    "ms": "values-ms",
    "my": "values-my",
    "nb": "values-nb",
    "ne": "values-ne",
    "nl": "values-nl",
    "pl": "values-pl",
    "pt": "values-pt",
    "pt-BR": "values-pt-rBR",
    "ro": "values-ro",
    "ru": "values-ru",
    "sk": "values-sk",
    "sl": "values-sl",
    "sr": "values-b+sr+RS",
    "sr-Latn": "values-b+sr+Latn",
    "sv": "values-sv",
    "sw": "values-sw",
    "ta": "values-ta",
    "te": "values-te",
    "th": "values-th",
    "tr": "values-tr",
    "uk": "values-uk",
    "ur": "values-ur",
    "uz": "values-uz",
    "vi": "values-vi",
    "yue": "values-yue",
    "zh-Hans": "values-zh-rCN",
    "zh-Hant": "values-zh-rTW",
}

ANDROID_ROOT_ENV = "ANDBIBLE_ANDROID_ROOT"
# Stable provenance label for generated snapshots; never serialize a local checkout path.
ANDROID_SNAPSHOT_SOURCE_RES = "app/src/main/res"
DISCRETE_SECURITY_ANDROID_KEYS = (
    "calculator_par1",
    "calculator_par2",
    "calculator_par3",
)
DISCRETE_SECURITY_IOS_FALLBACKS = {
    "discrete_mode_description": (
        "Changes only the launcher icon. AndBible remains visible as the app name in system app "
        "information."
    ),
    "discrete_help_ios_note": (
        "On iOS, the app icon changes to a calculator when 'Hide religious symbols' is enabled, "
        "but the app display name cannot be changed at runtime due to platform limitations."
    ),
}
REMOVED_DISCRETE_SECURITY_KEYS = {
    "discrete_help_par1",
    "discrete_help_par2",
    "discrete_help_par3",
    "prefs_volume_keys_scroll_ios_note",
    "discrete_mode_info_par1",
    "discrete_mode_info_par2",
    "discrete_mode_link",
    "discrete_help_standard_icon_only_ios",
    "discrete_help_calculator_enforced_ios",
    "discrete_help_calculator_fallback_ios",
}
OBSOLETE_DISCRETE_MODE_SENTENCE = (
    "When enabled, the app always launches as a calculator. Tap = seven times to temporarily "
    "access the Bible. Disable this toggle to return to normal."
)
PRODUCT_FEEDBACK_ANDROID_KEYS = (
    "bug_report_archive_too_large",
    "bug_report_attachment_line_1",
    "bug_report_attachment_too_large",
    "bug_report_collecting_evidence",
    "bug_report_email_text",
    "bug_report_email_title",
    "bug_report_export",
    "bug_report_export_failed",
    "bug_report_export_preparing",
    "bug_report_log_empty",
    "bug_report_log_unavailable",
    "bug_report_mail_unavailable",
    "bug_report_no_attachments",
    "bug_report_not_sent",
    "bug_report_preparation_notes",
    "bug_report_screenshot_unavailable",
    "bug_report_show_in_finder",
    "cancel",
    "report_bug_big_heading",
    "report_bug_email_subject_3",
    "report_bug_heading1",
    "report_bug_heading_3",
    "report_bug_heading_4",
    "report_bug_line_1",
    "send_bug_report_title",
)
"""Android-owned strings used by the manual feedback and crash-evidence flow.

Every user-visible report string is sourced from Android's catalog so both platforms share one
translation pipeline. Strings that only iOS displays (export, Finder, delivery-state dialogs)
still live in Android's `values/strings.xml` and receive translations through Android's normal
localization process instead of shipping invented iOS-only English fallbacks.
"""

PRODUCT_FEEDBACK_IOS_FALLBACKS: dict[str, str] = {}
"""iOS-only report copy with no Android catalog entry.

Deliberately empty: an iOS-only English fallback is a last resort. New report strings must be
added to Android's `values/strings.xml` first (see PRODUCT_FEEDBACK_ANDROID_KEYS) so every locale
can receive a real translation.
"""

REMOVED_PRODUCT_FEEDBACK_KEYS = {
    "bug_report_attached_evidence",
    "bug_report_reproduction_prompt",
    "bug_report_app_id",
    "bug_report_version",
    "bug_report_operating_system",
    "bug_report_device",
    "bug_report_locale",
    "bug_report_time_zone",
    "bug_report_physical_memory",
    "bug_report_free_storage",
    "bug_report_unavailable",
}
"""Superseded iOS-only strings.

The first two were replaced by Android's report-body resources. The device-info labels follow
Android's `BugReport.createErrorText`, which intentionally hardcodes English so the developer
team can read every submitted report; they are plain literals on iOS as well, not localized keys.
"""

LINE_RE = re.compile(r'^"(?P<key>[^"]+)"\s*=\s*"(?P<val>(?:[^"\\]|\\.)*)";\s*$')
LOCALE_OPTIONS_BLOCK_RE = re.compile(
    r"private static let localeOptions:\s*\[LocaleOption\]\s*=\s*\[(?P<body>.*?)\n\s*\]",
    re.DOTALL,
)
SWIFT_LOCALE_OPTION_RE = re.compile(
    r'\.init\(\s*value:\s*"(?P<value>[^"]*)",\s*'
    r'labelKey:\s*"(?P<label_key>[^"]+)",\s*'
    r'labelDefault:\s*"(?P<label_default>[^"]*)"\s*\)',
    re.DOTALL,
)
ANDROID_ESCAPE_RE = re.compile(r"\\(u[0-9a-fA-F]{4}|.)", re.DOTALL)
ANDROID_STRING_FORMAT_RE = re.compile(
    r"(?<!%)%(?!%)(?P<position>\d+\$)?(?P<flags>[-#+ 0,(<]*)?"
    r"(?P<width>\d+)?(?P<precision>\.\d+)?s"
)
ANDROID_NEWLINE_SENTINEL = "__ANDROID_ESCAPED_NEWLINE__"
ANDROID_TAB_SENTINEL = "__ANDROID_ESCAPED_TAB__"
ANDROID_SPACE_SENTINEL = "__ANDROID_ESCAPED_SPACE__"


LOCALE_PREF_RESOURCE_OVERRIDES = {
    "iw": "he",
    "in": "id",
    "zh-Hant-TW": "zh-Hant",
    "zh-Hans-CN": "zh-Hans",
}


ANDROID_SHARED_KEY_MAPPINGS = {
    "%@ (%@)": "something_with_parenthesis",
    "Find in %@": "search_in",
    "add_custom_repository": "custom_repositories_create_button_label",
    "ai_document_markers": "prefs_show_ai_doc_markers_title",
    "ai_hidden_status": "hidden",
    "all_text_options": "all_text_options_window_menutitle",
    "app_name": "app_name_andbible",
    "application_preferences": "settings",
    "background": "color_background",
    "backup_backup_message_ios": "backup_backup_message",
    "backup_modules": "backup_modules2",
    "bookmark": "add_bookmark1",
    "buy_development2": "buy_development2",
    "calculator_pin": "prefs_calculator_pin",
    "calculator_pin_description": "prefs_calculator_pin_desc",
    "choose_book": "choosePassageBookName",
    "choose_document": "chooce_document",
    "compare_choose_translations": "choose_translations",
    "completed": "agent_log_completed",
    "copy_of %@": "copy_of_workspace",
    "create": "index_create",
    "cross_references": "prefs_show_xrefs_title",
    "current_book": "search_current_book",
    "delete_custom_repository_message_format": "delete_doc",
    "delete_module_index_title": "delete_index",
    "description": "prompt_description",
    "dictionaries": "prefs_dictionaries_cat",
    "discrete_help_summary": "prefs_persecuted_summary",
    "discrete_help_title": "prefs_persecuted_help",
    "discrete_mode": "prefs_discrete_mode",
    "edit": "ai_provider_edit",
    "errorTitle": "error_occurred",
    "error_occurred": "error_occurred",
    "extracting_zip_file": "extracting_zip_file",
    "footnotes": "prefs_show_footnotes_title",
    "fullscreen": "toggle_fullscreen",
    "greek_dictionary": "choose_strongs_greek_dictionary_title",
    "hebrew_dictionary": "choose_strongs_hebrew_dictionary_title",
    "help_bookmarks": "bookmarks",
    "help_full_documentation_link": "help_full_documentation_link",
    "help_navigation": "help_nav_title",
    "help_pinning": "window_pinning_menutitle",
    "help_search": "help_search_title",
    "help_selection": "prompt_context_text_selection",
    "help_studypads": "studypads",
    "help_tips": "help_and_tips",
    "help_workspaces": "help_workspaces_title",
    "hyphenation": "prefs_hyphenation_title",
    "import": "import2",
    "infinite_scroll": "prefs_infinite_scroll_title",
    "install_failed_reason": "install_failed_reason",
    "install_zip_successfull": "install_zip_successfull",
    "justify_text": "prefs_justify_title",
    "label_edit_name": "label_name_prompt",
    "label_settings": "auto_assign_labels_title",
    "labels_search_hint": "labels_search_hint",
    "line_spacing": "line_spacing_title",
    "links": "strongs_links",
    "main_menu": "menu",
    "map": "doc_type_map",
    "mark_as_read_button": "prefs_mark_as_read_button_title",
    "maximize": "windowMaximise",
    "memorization_indicators": "prefs_show_memorization_indicators_title",
    "module_category": "prompt_category",
    "module_install_phase_committing": "install_zip_title",
    "module_install_phase_downloading": "download_document_confirm_prefix",
    "module_install_phase_queued": "please_wait",
    "module_installed": "cloud_doc_filter_installed",
    "module_installed_version": "cloud_doc_filter_installed",
    "module_language": "chooce_language_hint",
    "module_name": "prompt_name",
    "move_down": "move_category_down",
    "move_up": "move_category_up",
    "my_documents": "my_documents_title",
    "my_notes": "mynotes",
    "name": "prompt_name",
    "new_testament": "search_new_testament",
    "night_mode": "options_menu_night_mode",
    "non_strongs_word_italic": "prefs_non_strongs_word_italic_title",
    "ok": "okay",
    "old_testament": "search_old_testament",
    "open_studypad": "tool_finish_with_study_pad",
    "overwrite": "yes",
    "package_directory": "packages_dir",
    "page_scroll_amount": "prefs_page_scroll_amount_title",
    "paragraph_break": "add_paragraph_break",
    "pin": "window_pin_mode",
    "read": "tool_category_read",
    "reading_plan_choose": "rdg_plan_selector_title",
    "reading_plan_completed": "agent_log_completed",
    "reading_plan_custom": "custom_system_prompt_custom",
    "reading_plan_import_error_read": "sqlite_cant_read",
    "reading_plan_set_current_day": "set_current_day",
    "reading_plan_set_start_date": "rdg_plan_set_start_date",
    "reading_plans": "reading_plans_plural",
    "red_letters": "prefs_red_letter_title",
    "repository_url": "repository_specification",
    "reset": "reset_generic",
    "reset_to_defaults": "reset_to_default",
    "save": "save_and_exit",
    "search_all": "all",
    "search_bible": "tool_search_bible",
    "search_bible_text": "tool_search_bible",
    "search_create_index": "index_create",
    "search_indexing_message": "indexing_wait_msg",
    "search_scope_all": "all",
    "section_titles": "prefs_section_title_title",
    "settings_about": "about",
    "settings_content": "search_mode_content",
    "settings_dictionaries": "prefs_dictionaries_cat",
    "settings_language": "chooce_language_hint",
    "settings_security": "prefs_persecution_cat",
    "show_bookmarks": "prefs_show_bookmarks_title",
    "show_calculator": "prefs_show_calculator",
    "skip": "error_skip",
    "sleep_timer": "speak_sleep_timer_title",
    "sort_bible_order": "sort_by_bible_book",
    "sort_last_updated": "last_updated_at",
    "speak_sleep_timer": "speak_sleep_timer_title",
    "speak_stopped": "speak_status_stopped",
    "storage_space_warning": "storage_space_warning",
    "strongs_hidden": "strongs_hidden_links",
    "strongs_inline": "strongs_text_and_links",
    "strongs_numbers": "prefs_show_strongs_title",
    "study_pad": "studypad",
    "success": "done",
    "summary": "default_prompt_summary",
    "sync_disabled": "tool_option_disabled",
    "test_connection": "easy_setup_test_connection",
    "text_color": "color_text",
    "text_display_font_family_title_format": "pref_font_family_label_name",
    "text_display_font_size_title_format": "font_size_title_pt",
    "text_display_left_margin_title_format": "pref_left_margin_label_mm",
    "text_display_line_spacing_title_format": "prefs_line_spacing_pt_title",
    "text_display_margin_size_title_format": "prefs_margin_size_mm_title",
    "text_display_max_width_title_format": "pref_maximum_width_of_text_label_mm",
    "text_display_right_margin_title_format": "pref_right_margin_label_mm",
    "text_display_top_margin_title_format": "prefs_top_margin_title_mm",
    "tilt_to_scroll": "prefs_tilt_to_scroll_title",
    "title_scroll_button": "prefs_title_scroll_button_title",
    "top_margin": "prefs_top_margin_title",
    "translations": "search_translations",
    "underline_style": "display_mode_underline",
    "undo": "cancel",
    "verse_numbers": "show_versenumbers",
    "verse_per_line": "prefs_verse_per_line_title",
    "verse_selection": "prompt_context_verse_selection",
    "whole_bible": "search_all_bible",
    "window_disable_sync": "disable_sync",
    "window_pinning": "window_pinning_menutitle",
    "workspaces": "help_workspaces_title",
}
"""Explicit iOS-key to Android-key localization mappings.

Entries cover iOS keys whose English text matches Android under a different
resource name or whose translated copy is Android-owned but requires an explicit
iOS English platform boundary. They are intentionally one-to-one so the
generated snapshot can show the exact Android source for every imported value.
The table performs no file I/O by itself; build/sync code ignores entries whose
keys are absent from a particular fixture or checkout.
"""


IOS_PLATFORM_ENGLISH_OVERRIDES = {
    "backup_backup_message_ios": (
        "Backup to phone or elsewhere via Share function (email, iCloud Drive etc.)?"
    ),
    "maximize": "Maximize",
    "speak_stopped": "Stopped",
}
"""English platform-boundary copy layered on Android translation provenance.

Each key must also appear in ``ANDROID_SHARED_KEY_MAPPINGS``. Non-English values
continue to come from that Android source resource, so every shipped locale stays
translated and tree-aligned; only English terminology that would be false or
misleading on iOS is replaced explicitly.
"""


ANDROID_SHARED_SAME_NAME_EXCLUSIONS = {
    "disable_sync",
    "hidden",
}
"""iOS keys that must not be Android-sourced by same-name matching.

Entries are same-name semantic collisions: Android has the same resource key,
but the iOS key is used for a different product surface. Explicit cross-name
mappings may still point at one of these Android keys when that mapping names an
Android-equivalent iOS surface.
"""


AI_LOCALIZATION_SOURCE_DIRECTORIES = (
    "Sources/BibleCore/Sources/BibleCore/AI",
    "Sources/BibleUI/Sources/BibleUI/AI",
)
AI_ADDITIONAL_LOCALIZATION_KEYS = frozenset(
    {
        "ai_settings_shortcut_summary",
        "llm_actions",
        "prefs_features_cat",
    }
)
AI_LOCALIZATION_LITERAL_PATTERNS = (
    re.compile(r'String\s*\(\s*localized:\s*"([^"]+)"', re.DOTALL),
    re.compile(r'\.localized\(\s*"([^"]+)"', re.DOTALL),
    re.compile(
        r'\b(?:titleKey|bodyKey|labelKey|emphasizedTextKey)\s*:\s*"([^"]+)"',
        re.DOTALL,
    ),
)
AI_LOCALIZATION_VALUE_LITERAL_RE = re.compile(
    r'String\.LocalizationValue\(\s*"([^"]+)"',
    re.DOTALL,
)
AI_LOCALIZATION_DEFAULT_RE = re.compile(
    r'String\s*\(\s*localized:\s*"([^"]+)"\s*,\s*'
    r'defaultValue:\s*"((?:[^"\\]|\\.)*)"',
    re.DOTALL,
)
ANDROID_RUNTIME_RESOURCE_KEY_PATTERNS = (
    re.compile(r'localizedDrawerString\(\s*"([^"]+)"'),
    re.compile(r'localizedAndroidOverflowString\(\s*androidKey:\s*"([^"]+)"'),
)
SHIPPED_SWIFT_LOCALIZATION_DIRECTORIES = (
    "AndBible",
    "Sources",
)
SHIPPED_SWIFT_LOCALIZATION_PATTERNS = (
    re.compile(r'String\s*\(\s*localized:\s*"([^"]+)"', re.DOTALL),
    re.compile(r'\.localized\(\s*"([^"]+)"', re.DOTALL),
    re.compile(r'String\.LocalizationValue\(\s*"([^"]+)"', re.DOTALL),
    re.compile(r'NSLocalizedString\(\s*"([^"]+)"', re.DOTALL),
    re.compile(r'localizedString\(\s*forKey:\s*"([^"]+)"', re.DOTALL),
    re.compile(
        r'\b(?:titleKey|bodyKey|labelKey|emphasizedTextKey|localizationKey|'
        r'messageKey|summaryKey|descriptionKey|placeholderKey)\s*:\s*"([^"]+)"',
        re.DOTALL,
    ),
)
SHIPPED_SWIFT_UI_LITERAL_START_PATTERN = re.compile(
    r'(?<![A-Za-z0-9_])'
    r'(?P<owner>Text|Button|Label|TextField|SecureField|Toggle|Picker|Menu|Section|'
    r'navigationTitle|alert|confirmationDialog)'
    r'\s*\(\s*"',
)
SHIPPED_SWIFT_UI_VERBATIM_ALLOWLIST = frozenset(
    {
        "AI",
        "F",
        "M",
        "RRGGBB",
        "W",
    }
)
ANDROID_EXACT_DEFAULT_KEYS = frozenset(
    {
        "creating_index_for",
        "help",
        "help_ai_connection_text",
        "help_ai_document_filter_text",
        "help_ai_models_text",
        "help_ai_providers_text",
        "help_ai_settings_text",
        "help_document_sync_text",
        "help_global_tool_permissions_text",
        "help_memorize_text",
        "help_prompt_edit_text",
        "help_read_more_link",
        "help_reading_progress_text",
        "help_tool_info_text",
        "label_blue",
        "label_green",
        "label_red",
        "label_salvation",
        "label_underline",
        "okay",
        "plan_description_y1ntpspr",
        "plan_description_y1ot1nt1_OTandNT",
        "plan_description_y1ot1nt1_OTthenNT",
        "plan_description_y1ot1nt1_chronological",
        "plan_description_y1ot1nt2_mcheyne",
        "plan_description_y1ot6nt4_profHorner",
        "plan_description_y2ot1ntps2",
        "plan_name_y1ntpspr",
        "plan_name_y1ot1nt1_OTandNT",
        "plan_name_y1ot1nt1_OTthenNT",
        "plan_name_y1ot1nt1_chronological",
        "plan_name_y1ot1nt2_mcheyne",
        "plan_name_y1ot6nt4_profHorner",
        "plan_name_y2ot1ntps2",
        "workspace_number",
    }
)


def discover_shipped_swift_localization_keys(repo_root: Path) -> set[str]:
    """Return every statically declared localization key used by shipped Swift.

    The inventory deliberately walks product code rather than a feature allowlist. It
    recognizes direct Foundation/Swift localization APIs, typed `.localized` values,
    and indirect localization-key fields used by presentation models. Test fixtures
    and interpolated localization values are excluded because interpolated values are
    format patterns rather than stable resource keys. The function performs read-only
    source-file I/O and returns an empty set for focused fixtures without product
    source directories.
    """
    keys: set[str] = set()
    for relative_directory in SHIPPED_SWIFT_LOCALIZATION_DIRECTORIES:
        root = repo_root / relative_directory
        if not root.is_dir():
            continue
        for source_path in sorted(root.rglob("*.swift")):
            if "Tests" in source_path.parts:
                continue
            source = source_path.read_text(encoding="utf-8")
            for pattern in SHIPPED_SWIFT_LOCALIZATION_PATTERNS:
                keys.update(key for key in pattern.findall(source) if r"\(" not in key)
    return keys


def discover_unlocalized_swift_ui_literals(repo_root: Path) -> list[str]:
    """Return shipped SwiftUI prose that bypasses named localization resources.

    Literal-only technical glyphs and the exact Android calendar/format tokens in
    ``SHIPPED_SWIFT_UI_VERBATIM_ALLOWLIST`` are permitted. Interpolated values are
    permitted only when their non-interpolated remainder contains no letters; this
    allows dynamic values such as a verse number while rejecting prose such as
    ``"Page \\(number)"``. Each deterministic result includes source path, line,
    constructor, and literal so CI failures point directly at the escape path.

    The scan is read-only. It intentionally covers the standard SwiftUI controls
    that create visible text while excluding accessibility-only automation markers.
    """
    failures: list[str] = []
    for relative_directory in SHIPPED_SWIFT_LOCALIZATION_DIRECTORIES:
        root = repo_root / relative_directory
        if not root.is_dir():
            continue
        for source_path in sorted(root.rglob("*.swift")):
            if "Tests" in source_path.parts:
                continue
            source = source_path.read_text(encoding="utf-8")
            for match in SHIPPED_SWIFT_UI_LITERAL_START_PATTERN.finditer(source):
                parsed_literal = parse_swift_string_literal(source, match.end())
                if parsed_literal is None:
                    continue
                literal, prose = parsed_literal
                if literal in SHIPPED_SWIFT_UI_VERBATIM_ALLOWLIST:
                    continue
                if not any(character.isalpha() for character in prose):
                    continue
                line = source.count("\n", 0, match.start()) + 1
                relative_path = source_path.relative_to(repo_root)
                failures.append(
                    f"{relative_path}:{line}:{match.group('owner')}:{literal}"
                )
    return failures


def parse_swift_string_literal(source: str, start: int) -> tuple[str, str] | None:
    """Parse one ordinary Swift string after its opening quote.

    - Parameters:
      - source: Complete Swift source text.
      - start: Offset immediately after the opening quote.
    - Returns: Raw literal content plus only the text outside interpolations, or
      ``None`` for an unterminated literal.
    - Side effects: none.
    - Failure modes: malformed source returns ``None`` rather than inventing a
      localization violation.
    """
    raw: list[str] = []
    prose: list[str] = []
    interpolation_depth = 0
    index = start

    while index < len(source):
        character = source[index]

        if interpolation_depth == 0:
            if character == '"':
                return "".join(raw), "".join(prose)
            if character == "\\" and index + 1 < len(source):
                next_character = source[index + 1]
                raw.extend((character, next_character))
                index += 2
                if next_character == "(":
                    interpolation_depth = 1
                continue
            raw.append(character)
            prose.append(character)
            index += 1
            continue

        raw.append(character)
        if character == '"':
            index += 1
            while index < len(source):
                nested_character = source[index]
                raw.append(nested_character)
                index += 1
                if nested_character == "\\" and index < len(source):
                    raw.append(source[index])
                    index += 1
                elif nested_character == '"':
                    break
            continue
        if character == "(":
            interpolation_depth += 1
        elif character == ")":
            interpolation_depth -= 1
        index += 1

    return None


def discover_android_owned_swift_localization_keys(
    repo_root: Path,
    android_base: dict[str, str],
) -> dict[str, str]:
    """Map shipped literal Swift keys with Android provenance to Android resources.

    A same-name Android resource establishes ownership directly; an explicit
    mapping establishes ownership where platforms use different resource names.
    Swift-only keys are intentionally omitted because Android cannot provide a
    translation contract for them. The result is deterministic and performs no
    writes beyond the source reads delegated to the shipped-key inventory.
    """
    source_keys: dict[str, str] = {}
    for ios_key in discover_shipped_swift_localization_keys(repo_root):
        android_key = ANDROID_SHARED_KEY_MAPPINGS.get(ios_key, ios_key)
        if android_key in android_base:
            source_keys[ios_key] = android_key
    return dict(sorted(source_keys.items()))


def discover_android_runtime_resource_keys(repo_root: Path) -> set[str]:
    """Return literal Android resource keys used by iOS runtime lookup helpers.

    Drawer and overflow code intentionally resolves Android-named resources through
    ``Bundle.main.localizedString`` rather than Swift ``String(localized:)``. Those keys are
    invisible to the ordinary iOS-English intersection, so this source scan makes them explicit
    Android-owned catalog inputs. Dynamic keys are deliberately excluded because they cannot be
    validated without a concrete resource contract.
    """
    keys: set[str] = set()
    for source_path in sorted((repo_root / "Sources").rglob("*.swift")):
        source = source_path.read_text(encoding="utf-8")
        for pattern in ANDROID_RUNTIME_RESOURCE_KEY_PATTERNS:
            keys.update(pattern.findall(source))
    return keys


def discover_ai_localization_keys(repo_root: Path) -> set[str]:
    """Return every statically declared localization key in the AI feature.

    The inventory scans both AI source directories for direct localization
    calls, localized help contracts, and indirect key fields. The Android-owned
    entry-point strings declared outside those directories are included whenever the AI feature
    sources are present. The function performs read-only source-file I/O and raises
    ``ValueError`` for any interpolated localization literal because Swift treats
    it as a format-pattern key rather than resolving the runtime interpolation.
    """
    source_paths = sorted(
        path
        for relative_directory in AI_LOCALIZATION_SOURCE_DIRECTORIES
        for path in (repo_root / relative_directory).rglob("*.swift")
    )
    if not source_paths:
        return set()

    keys = set(AI_ADDITIONAL_LOCALIZATION_KEYS)
    for path in source_paths:
        source = path.read_text(encoding="utf-8")
        for pattern in AI_LOCALIZATION_LITERAL_PATTERNS:
            keys.update(pattern.findall(source))
        for raw_key in AI_LOCALIZATION_VALUE_LITERAL_RE.findall(source):
            if r"\(" in raw_key:
                raise ValueError(
                    "Interpolated AI localization key in "
                    f"{path.relative_to(repo_root)}: {raw_key}"
                )
            else:
                keys.add(raw_key)
    return keys


def discover_ai_localization_defaults(repo_root: Path) -> dict[str, set[str]]:
    """Return direct AI localization fallbacks grouped by their iOS key.

    Only literal ``defaultValue`` arguments are included; indirect localization
    contracts have no fallback to compare. Swift string escapes are normalized
    with the same parser used for `.strings` values. The function performs
    read-only source-file I/O and returns an empty dictionary when the AI source
    directories are absent from a focused test fixture.
    """
    defaults: dict[str, set[str]] = {}
    for relative_directory in AI_LOCALIZATION_SOURCE_DIRECTORIES:
        for path in sorted((repo_root / relative_directory).rglob("*.swift")):
            source = path.read_text(encoding="utf-8")
            for key, raw_default in AI_LOCALIZATION_DEFAULT_RE.findall(source):
                defaults.setdefault(key, set()).add(unescape_ios(raw_default))
    return defaults


def discover_shipped_swift_localization_defaults(repo_root: Path) -> dict[str, set[str]]:
    """Return every shipped literal localization fallback grouped by resource key.

    Product code can render a ``defaultValue`` whenever a resource is unavailable, so
    Android parity requires those fallbacks to match Android English just as strictly
    as the bundled `.strings` value. Test sources are excluded, interpolation remains
    outside this literal-only contract, and all file access is read-only.
    """
    defaults: dict[str, set[str]] = {}
    for relative_directory in SHIPPED_SWIFT_LOCALIZATION_DIRECTORIES:
        root = repo_root / relative_directory
        if not root.is_dir():
            continue
        for source_path in sorted(root.rglob("*.swift")):
            if "Tests" in source_path.parts:
                continue
            source = source_path.read_text(encoding="utf-8")
            for key, raw_default in AI_LOCALIZATION_DEFAULT_RE.findall(source):
                defaults.setdefault(key, set()).add(unescape_ios(raw_default))
    return defaults


def missing_ai_localization_catalog_keys(
    repo_root: Path,
    catalog: AndroidSharedLocalization,
) -> list[str]:
    """Return AI source keys absent from an Android-derived localization catalog.

    This read-only comparison catches a stale committed snapshot when CI has no
    Android checkout. An empty result means every currently referenced AI key,
    including ``llm_actions``, has recorded Android provenance and values.
    """
    return sorted(discover_ai_localization_keys(repo_root) - set(catalog.english_by_key))


def missing_android_owned_localization_catalog_keys(
    repo_root: Path,
    catalog: AndroidSharedLocalization,
) -> list[str]:
    """Return Android-owned source keys absent from a generated catalog.

    This extends the previous AI-only stale-snapshot check to every shipped
    literal Swift localization key with Android provenance and to runtime
    Android-resource helpers. A non-empty result means CI could otherwise pass
    while the app falls back to a raw localization key at runtime.
    """
    catalog_keys = set(catalog.english_by_key)
    android_resource_keys = set(catalog.android_resource_keys)
    android_owned_source_keys = {
        key
        for key in discover_shipped_swift_localization_keys(repo_root)
        if ANDROID_SHARED_KEY_MAPPINGS.get(key, key) in android_resource_keys
    }
    android_owned_source_keys.update(discover_ai_localization_keys(repo_root))
    android_owned_source_keys.update(discover_android_runtime_resource_keys(repo_root))
    return sorted(android_owned_source_keys - catalog_keys)


def default_repo_root() -> Path:
    """Return the checkout root containing this localization guardrail.

    Resolution is based only on this script's path, performs no I/O, and works in both primary and
    linked Git worktrees. The returned path may not exist only when the script itself has been moved
    during process execution.
    """
    return Path(__file__).resolve().parents[1]


def primary_git_checkout_root(repo_root: Path) -> Path | None:
    """Resolve the primary checkout that owns a linked worktree's common Git directory.

    ``repo_root`` may be either a primary checkout or a linked worktree. The helper runs one read-only
    ``git rev-parse`` command and returns the common directory's parent. Git failures, empty output,
    and filesystem resolution errors return ``None`` so callers can retain their normal sibling
    fallback without hiding an explicit environment override.
    """
    result = subprocess.run(
        [
            "git",
            "-C",
            str(repo_root),
            "rev-parse",
            "--path-format=absolute",
            "--git-common-dir",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return None
    try:
        return Path(result.stdout.strip()).resolve().parent
    except OSError:
        return None


def default_android_root() -> Path:
    """Return the Android resource tree used for live parity checks.

    ANDBIBLE_ANDROID_ROOT points to the Android repository checkout root so
    bridge and localization guardrails can share one CI/local setup contract. Without an override,
    normal checkouts use the adjacent Android repository and linked worktrees also inspect the sibling
    of their primary checkout. Git discovery is read-only; when no candidate exists, the conventional
    sibling path is returned so the caller reports the expected missing-resource diagnostic.
    """
    android_root_env = os.environ.get(ANDROID_ROOT_ENV)
    if android_root_env:
        return Path(android_root_env).expanduser() / "app" / "src" / "main" / "res"

    repo_root = default_repo_root()
    candidates = [repo_root.parent / "and-bible"]
    primary_checkout = primary_git_checkout_root(repo_root)
    if primary_checkout is not None:
        candidates.append(primary_checkout.parent / "and-bible")
    resource_candidates = [candidate / "app" / "src" / "main" / "res" for candidate in candidates]
    for candidate in resource_candidates:
        if candidate.is_dir():
            return candidate
    return resource_candidates[0]


def default_android_snapshot() -> Path:
    return (
        default_repo_root()
        / "scripts"
        / "fixtures"
        / "settings-localization"
        / "localization-android.json"
    )


def parse_ios_strings(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = LINE_RE.match(line.strip())
        if match:
            values[match.group("key")] = match.group("val")
    return values


def unescape_ios(value: str) -> str:
    return value.replace(r"\\", "\\").replace(r"\"", '"').replace(r"\t", "\t").replace(r"\n", "\n")


def escape_ios(value: str) -> str:
    """Escape a localized value for a `.strings` assignment.

    The sync path writes Android XML text into iOS resource files, so it must
    preserve visible text while escaping characters that would break the
    property-list strings syntax. The function is deterministic and performs no
    file I/O.
    """
    return value.replace("\\", r"\\").replace('"', r"\"").replace("\t", r"\t").replace("\n", r"\n")


def parse_android_strings(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    root = ET.parse(path).getroot()
    values: dict[str, str] = {}
    for node in root.findall("string"):
        name = node.get("name")
        if name:
            values[name] = "".join(node.itertext())
    return values


def unescape_android_string(value: str) -> str:
    """Convert Android XML string text into Android runtime text.

    ElementTree returns Android escape sequences such as `\\n` and `\\t` as
    backslash text and preserves indentation from multiline XML fixtures. The
    guardrail compares runtime values, so this normalizes Android escapes,
    collapses unquoted XML whitespace, and preserves escaped whitespace. The
    function performs no XML parsing or file I/O and is deterministic for a
    single resource value.
    """
    is_quoted = len(value) >= 2 and value.startswith('"') and value.endswith('"')
    body = value[1:-1] if is_quoted else value

    def replace_escape(match: re.Match[str]) -> str:
        sequence = match.group(1)
        if sequence.startswith("u"):
            char = chr(int(sequence[1:], 16))
        else:
            char = {
                "n": "\n",
                "t": "\t",
                '"': '"',
                "'": "'",
                "@": "@",
                "?": "?",
                "\\": "\\",
            }.get(sequence, sequence)

        if char == "\n":
            return ANDROID_NEWLINE_SENTINEL
        if char == "\t":
            return ANDROID_TAB_SENTINEL
        if char == " ":
            return ANDROID_SPACE_SENTINEL
        return char

    normalized = ANDROID_ESCAPE_RE.sub(replace_escape, body)
    if not is_quoted:
        normalized = re.sub(r"\s+", " ", normalized).strip()

    return (
        normalized.replace(ANDROID_NEWLINE_SENTINEL, "\n")
        .replace(ANDROID_TAB_SENTINEL, "\t")
        .replace(ANDROID_SPACE_SENTINEL, " ")
    )


def android_string_for_ios(value: str) -> str:
    """Return Android runtime text converted to iOS `.strings` format syntax.

    Android translations are the source of truth, but Java string placeholders
    use `%s` while iOS `String(format:)` expects object arguments as `%@`.
    This conversion keeps numeric printf specifiers intact, rewrites string
    specifiers including positional forms, performs no file I/O, and leaves
    malformed format strings to the existing iOS lint/build checks.
    """
    runtime_value = unescape_android_string(value)

    def replace_string_specifier(match: re.Match[str]) -> str:
        return (
            "%"
            + (match.group("position") or "")
            + (match.group("flags") or "")
            + (match.group("width") or "")
            + (match.group("precision") or "")
            + "@"
        )

    return ANDROID_STRING_FORMAT_RE.sub(replace_string_specifier, runtime_value)


@dataclass(frozen=True)
class LocalePrefOption:
    value: str
    label_key: str


@dataclass
class LocalePrefAudit:
    supported_values: list[str]
    unsupported_values: list[str]
    extra_ios_locales: list[str]
    failures: list[str]


@dataclass(frozen=True)
class AndroidSharedLocalization:
    """Android translations that source same-name iOS localization keys.

    `safe_keys` contains iOS keys backed by either a same-name Android key or an
    explicit cross-name mapping. `source_key_by_key` records the Android resource
    key for traceability, while `english_by_key` carries the Android English
    source text that iOS must use. Locale translation dictionaries include only
    Android values that differ from Android English, so consumers can distinguish
    real translated coverage from normal fallback. The object is immutable and
    has no file I/O side effects.
    """

    safe_keys: list[str]
    english_mismatch_keys: list[str]
    android_resource_keys: list[str]
    source_key_by_key: dict[str, str]
    english_by_key: dict[str, str]
    non_english_by_key: dict[str, list[str]]
    translations_by_locale: dict[str, dict[str, str]]


@dataclass
class SharedLocalizationAudit:
    """Audit result for Android-sourced shared localization keys.

    The result separates missing keys, English placeholders, and translated
    values that still drift from Android. This lets CI explain whether a locale
    needs a new key appended, an English fallback replaced, or an independent
    iOS translation overwritten by Android's source-of-truth value.
    """

    missing_key_by_key: dict[str, list[str]]
    english_value_mismatch_by_key: dict[str, list[str]]
    english_placeholder_by_key: dict[str, list[str]]
    value_mismatch_by_key: dict[str, list[str]]
    tree_mismatch_by_key: dict[str, list[str]]


@dataclass(frozen=True)
class SharedLocalizationSyncResult:
    """Summary of files and values changed by the Android shared-string sync.

    The sync command reports this value so local runs can verify that the repair
    touched both iOS resource trees and so tests can assert deterministic write
    counts without reading git diffs.
    """

    files_changed: int
    values_written: int


def parse_android_array_items(arrays_path: Path, array_name: str) -> list[str]:
    root = ET.parse(arrays_path).getroot()
    node = root.find(f"string-array[@name='{array_name}']")
    if node is None:
        raise ValueError(f"Android array not found: {array_name}")
    return ["".join(item.itertext()).strip() for item in node.findall("item")]


def build_android_locale_pref_options(android_root: Path) -> list[LocalePrefOption]:
    arrays_path = android_root / "values" / "arrays.xml"
    descriptions = parse_android_array_items(arrays_path, "prefs_interface_locale_descriptions")
    values = parse_android_array_items(arrays_path, "prefs_interface_locale_values")
    if len(descriptions) != len(values):
        raise ValueError(
            "Android locale_pref array length mismatch: "
            f"descriptions={len(descriptions)}, values={len(values)}"
        )

    options: list[LocalePrefOption] = []
    for description, value in zip(descriptions, values):
        if not description.startswith("@string/"):
            raise ValueError(f"Android locale_pref description is not a string ref: {description}")
        options.append(LocalePrefOption(value=value, label_key=description.removeprefix("@string/")))
    return options


def discrete_security_values_for_locale(
    catalog: AndroidSharedLocalization,
    locale: str,
) -> dict[str, str]:
    """Return complete security copy for one iOS locale.

    Android-owned help uses a real Android translation when present and Android English otherwise.
    iOS-only boundary statements intentionally use truthful English fallback in every locale until
    Android owns equivalent text. The function performs no file I/O and fails when the generated
    Android catalog omits a required source key.
    """
    missing = sorted(set(DISCRETE_SECURITY_ANDROID_KEYS) - set(catalog.english_by_key))
    if missing:
        raise ValueError(f"Android security copy missing source keys: {', '.join(missing)}")

    translations = catalog.translations_by_locale.get(locale, {})
    values = {
        key: translations.get(key, catalog.english_by_key[key])
        for key in DISCRETE_SECURITY_ANDROID_KEYS
    }
    values.update(DISCRETE_SECURITY_IOS_FALLBACKS)
    return values


def remove_ios_strings_keys(path: Path, keys: set[str]) -> tuple[bool, int]:
    """Remove obsolete assignments from one `.strings` file without touching unrelated rows."""
    old_text = path.read_text(encoding="utf-8")
    output: list[str] = []
    removed = 0
    for line in old_text.splitlines():
        match = LINE_RE.match(line.strip())
        if match and match.group("key") in keys:
            removed += 1
            continue
        output.append(line)

    new_text = "\n".join(output) + "\n"
    if new_text == old_text:
        return False, 0
    path.write_text(new_text, encoding="utf-8")
    return True, removed


def sync_discrete_security_localizations(
    repo_root: Path,
    catalog: AndroidSharedLocalization,
) -> SharedLocalizationSyncResult:
    """Write runtime Calculator security copy to both iOS localization trees.

    The sync covers every supported iOS locale, imports Android translations where available,
    applies the truthful iOS runtime-name limitation, and removes obsolete product-specific keys.
    """
    changed_paths: set[Path] = set()
    values_written = 0

    for tree in ("AndBible", "Localizations"):
        for locale in sorted(LOCALE_TO_ANDROID_VALUES):
            path = repo_root / tree / f"{locale}.lproj" / "Localizable.strings"
            if not path.exists():
                continue
            values = discrete_security_values_for_locale(catalog, locale)
            changed, written = update_ios_strings_file(path, values)
            if changed:
                changed_paths.add(path)
                values_written += written
            changed, removed = remove_ios_strings_keys(path, REMOVED_DISCRETE_SECURITY_KEYS)
            if changed:
                changed_paths.add(path)
                values_written += removed

    return SharedLocalizationSyncResult(
        files_changed=len(changed_paths),
        values_written=values_written,
    )


def audit_discrete_security_localizations(
    repo_root: Path,
    catalog: AndroidSharedLocalization,
) -> list[str]:
    """Enforce complete runtime Calculator copy across all locales and resource trees."""
    failures: list[str] = []
    expected_locales = set(LOCALE_TO_ANDROID_VALUES)

    for tree in ("AndBible", "Localizations"):
        root = repo_root / tree
        actual_locales = {
            path.name.removesuffix(".lproj")
            for path in root.glob("*.lproj")
            if path.is_dir()
        }
        for locale in sorted(expected_locales - actual_locales):
            failures.append(f"discrete security missing locale: {tree}:{locale}")

        for locale in sorted(expected_locales & actual_locales):
            path = root / f"{locale}.lproj" / "Localizable.strings"
            if not path.exists():
                failures.append(f"discrete security missing resource: {tree}:{locale}")
                continue
            actual = parse_ios_strings(path)
            expected = discrete_security_values_for_locale(catalog, locale)
            for key, expected_value in sorted(expected.items()):
                raw_value = actual.get(key)
                if raw_value is None:
                    failures.append(f"discrete security missing key: {tree}:{locale}:{key}")
                elif unescape_ios(raw_value) != expected_value:
                    failures.append(f"discrete security value drift: {tree}:{locale}:{key}")
            for key in sorted(REMOVED_DISCRETE_SECURITY_KEYS & set(actual)):
                failures.append(f"obsolete localization key remains: {tree}:{locale}:{key}")
            if any(
                OBSOLETE_DISCRETE_MODE_SENTENCE in unescape_ios(value)
                for value in actual.values()
            ):
                failures.append(f"obsolete false security sentence remains: {tree}:{locale}")

    return failures


def product_feedback_values_for_locale(
    catalog: AndroidSharedLocalization,
    locale: str,
) -> dict[str, str]:
    """Return complete product-feedback copy for one iOS locale.

    Android-owned dialog, subject, and report-body text uses Android's translation when available
    and Android English otherwise. iOS-only evidence, delivery, and export statements use a
    truthful English fallback until Android owns equivalent resources. The function performs no
    file I/O and raises ``ValueError`` if the Android-derived catalog is stale or incomplete.
    """
    missing = sorted(set(PRODUCT_FEEDBACK_ANDROID_KEYS) - set(catalog.english_by_key))
    if missing:
        raise ValueError(f"Android product-feedback copy missing source keys: {', '.join(missing)}")

    translations = catalog.translations_by_locale.get(locale, {})
    values = {
        key: translations.get(key, catalog.english_by_key[key])
        for key in PRODUCT_FEEDBACK_ANDROID_KEYS
    }
    values.update(PRODUCT_FEEDBACK_IOS_FALLBACKS)
    return values


def sync_product_feedback_localizations(
    repo_root: Path,
    catalog: AndroidSharedLocalization,
) -> SharedLocalizationSyncResult:
    """Write complete product-feedback copy to both shipped iOS localization trees.

    Every supported locale receives Android-owned values plus all iOS-only evidence and export
    fallbacks. Superseded one-off report-body keys are removed from the same files. Writes are
    limited to ``Localizable.strings`` resources beneath ``repo_root`` and ``ValueError`` is
    propagated before the first write when Android provenance is incomplete.
    """
    values_by_locale = {
        locale: product_feedback_values_for_locale(catalog, locale)
        for locale in sorted(LOCALE_TO_ANDROID_VALUES)
    }
    changed_paths: set[Path] = set()
    values_written = 0

    for tree in ("AndBible", "Localizations"):
        for locale, values in values_by_locale.items():
            path = repo_root / tree / f"{locale}.lproj" / "Localizable.strings"
            if not path.exists():
                continue
            changed, written = update_ios_strings_file(path, values)
            if changed:
                changed_paths.add(path)
                values_written += written
            changed, removed = remove_ios_strings_keys(path, REMOVED_PRODUCT_FEEDBACK_KEYS)
            if changed:
                changed_paths.add(path)
                values_written += removed

    return SharedLocalizationSyncResult(
        files_changed=len(changed_paths),
        values_written=values_written,
    )


def audit_product_feedback_localizations(
    repo_root: Path,
    catalog: AndroidSharedLocalization,
) -> list[str]:
    """Enforce complete, provenance-backed product-feedback copy in both resource trees.

    The returned failures identify missing locale directories, missing resources, value drift, and
    obsolete keys. The audit is read-only and raises ``ValueError`` when required Android source
    keys are absent from the catalog.
    """
    failures: list[str] = []
    expected_locales = set(LOCALE_TO_ANDROID_VALUES)

    for tree in ("AndBible", "Localizations"):
        root = repo_root / tree
        actual_locales = {
            path.name.removesuffix(".lproj")
            for path in root.glob("*.lproj")
            if path.is_dir()
        }
        for locale in sorted(expected_locales - actual_locales):
            failures.append(f"product feedback missing locale: {tree}:{locale}")

        for locale in sorted(expected_locales & actual_locales):
            path = root / f"{locale}.lproj" / "Localizable.strings"
            if not path.exists():
                failures.append(f"product feedback missing resource: {tree}:{locale}")
                continue
            actual = parse_ios_strings(path)
            expected = product_feedback_values_for_locale(catalog, locale)
            for key, expected_value in sorted(expected.items()):
                raw_value = actual.get(key)
                if raw_value is None:
                    failures.append(f"product feedback missing key: {tree}:{locale}:{key}")
                elif unescape_ios(raw_value) != expected_value:
                    failures.append(f"product feedback value drift: {tree}:{locale}:{key}")
            for key in sorted(REMOVED_PRODUCT_FEEDBACK_KEYS & set(actual)):
                failures.append(f"obsolete product feedback key remains: {tree}:{locale}:{key}")

    return failures


def load_snapshot_payload(path: Path) -> dict[str, object]:
    """Load a generated Android parity snapshot as a JSON object.

    Snapshot readers use this boundary so malformed files fail before their
    values can be coerced into plausible-looking audit inputs. The function
    performs only file I/O and JSON decoding, returning the parsed object or
    raising ValueError when the snapshot root shape is not valid.
    """
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"Snapshot root must be an object: {path}")
    return payload


def load_android_locale_pref_options_from_snapshot(path: Path) -> list[LocalePrefOption]:
    """Load locale_pref options from a generated Android parity snapshot.

    The default Android option intentionally uses an empty string value, but
    both snapshot fields must still be present strings. Missing or non-string
    values indicate a corrupt snapshot and are reported immediately so the
    parity audit does not continue with fabricated option values.
    """
    payload = load_snapshot_payload(path)
    raw_options = payload.get("locale_pref_options")
    if not isinstance(raw_options, list):
        raise ValueError(f"Snapshot missing locale_pref_options: {path}")

    options: list[LocalePrefOption] = []
    for index, raw in enumerate(raw_options):
        if not isinstance(raw, dict):
            raise ValueError(f"Invalid locale_pref_options[{index}] in {path}")
        value = raw.get("value")
        if not isinstance(value, str):
            raise ValueError(
                f"Invalid locale_pref_options[{index}].value in {path}: expected string"
            )
        label_key = raw.get("label_key")
        if not isinstance(label_key, str):
            raise ValueError(
                f"Invalid locale_pref_options[{index}].label_key in {path}: expected string"
            )
        options.append(
            LocalePrefOption(
                value=value,
                label_key=label_key,
            )
        )
    return options


def parse_swift_locale_options(settings_view_path: Path) -> list[LocalePrefOption]:
    text = settings_view_path.read_text(encoding="utf-8")
    block = LOCALE_OPTIONS_BLOCK_RE.search(text)
    if block is None:
        raise ValueError(f"Could not find SettingsView.localeOptions in {settings_view_path}")

    options = [
        LocalePrefOption(value=match.group("value"), label_key=match.group("label_key"))
        for match in SWIFT_LOCALE_OPTION_RE.finditer(block.group("body"))
    ]
    if not options:
        raise ValueError(f"Could not parse SettingsView.localeOptions in {settings_view_path}")
    return options


def ios_resource_locale_for_locale_pref(value: str) -> str:
    return LOCALE_PREF_RESOURCE_OVERRIDES.get(value, value)


def ios_localization_locales(repo_root: Path) -> set[str]:
    ios_a_root = repo_root / "AndBible"
    ios_b_root = repo_root / "Localizations"
    locales_a = {
        p.name.removesuffix(".lproj")
        for p in ios_a_root.glob("*.lproj")
        if p.name.endswith(".lproj")
    }
    locales_b = {
        p.name.removesuffix(".lproj")
        for p in ios_b_root.glob("*.lproj")
        if p.name.endswith(".lproj")
    }
    return locales_a & locales_b


def audit_locale_pref_contract(
    repo_root: Path,
    android_options: list[LocalePrefOption],
) -> LocalePrefAudit:
    swift_options = parse_swift_locale_options(
        repo_root / "Sources" / "BibleUI" / "Sources" / "BibleUI" / "Settings" / "SettingsView.swift"
    )
    ios_locales = ios_localization_locales(repo_root)
    android_values = [option.value for option in android_options]
    swift_values = [option.value for option in swift_options]
    supported_options = [
        option
        for option in android_options
        if option.value == "" or ios_resource_locale_for_locale_pref(option.value) in ios_locales
    ]
    supported_values = [option.value for option in supported_options]
    unsupported_values = [
        option.value
        for option in android_options
        if option.value and option.value not in supported_values
    ]
    android_label_by_value = {option.value: option.label_key for option in android_options}
    ios_resource_values = {
        ios_resource_locale_for_locale_pref(value)
        for value in android_values
        if value
    }
    extra_ios_locales = sorted(locale for locale in ios_locales if locale not in ios_resource_values)

    failures: list[str] = []
    if swift_values != supported_values:
        missing = [value for value in supported_values if value not in swift_values]
        unsupported = [value for value in swift_values if value not in supported_values]
        if missing:
            failures.append(f"locale_pref missing supported Android values: {', '.join(missing)}")
        if unsupported:
            failures.append(f"locale_pref shows unsupported Android values: {', '.join(unsupported)}")
        if not missing and not unsupported:
            failures.append(
                "locale_pref order drift: Swift options must preserve Android arrays.xml order "
                "after unsupported iOS locales are removed"
            )

    for option in swift_options:
        expected_label = android_label_by_value.get(option.value)
        if expected_label is None:
            continue
        if option.label_key != expected_label:
            failures.append(
                "locale_pref label key mismatch for "
                f"{option.value or '<default>'}: android={expected_label}, swift={option.label_key}"
            )

    return LocalePrefAudit(
        supported_values=supported_values,
        unsupported_values=unsupported_values,
        extra_ios_locales=extra_ios_locales,
        failures=failures,
    )


def build_android_non_english_by_key(android_root: Path) -> dict[str, list[str]]:
    android_base = {
        key: unescape_android_string(value)
        for key, value in parse_android_strings(android_root / "values" / "strings.xml").items()
    }
    android_base.update(
        {
            key: unescape_android_string(value)
            for key, value in parse_android_strings(
                android_root / "values" / "untranslated_strings.xml"
            ).items()
        }
    )
    android_by_locale = {
        loc: {
            key: unescape_android_string(value)
            for key, value in parse_android_strings(android_root / qualifier / "strings.xml").items()
        }
        for loc, qualifier in LOCALE_TO_ANDROID_VALUES.items()
    }

    non_english_by_key: dict[str, list[str]] = {k: [] for k in PARITY_KEYS}
    for key in PARITY_KEYS:
        base_value = android_base.get(key, "")
        for locale, locale_strings in android_by_locale.items():
            locale_value = locale_strings.get(key)
            if locale_value is not None and locale_value != base_value:
                non_english_by_key[key].append(locale)
        non_english_by_key[key].sort()

    return non_english_by_key


def build_android_shared_localization(repo_root: Path, android_root: Path) -> AndroidSharedLocalization:
    """Build the Android source-of-truth catalog for shared iOS keys.

    Same-name keys and explicitly mapped cross-name keys are treated as
    Android-sourced localization contracts. Android XML values are normalized to
    runtime text and converted to iOS format specifiers before comparison or
    sync. AI source keys are required even before they exist in iOS English, so
    the structured sync can bootstrap every Android translation instead of
    relying on ad hoc locale edits. The returned mismatch list records current
    iOS English drift or absence, but those keys remain in scope so the sync and
    audit paths can repair and enforce parity. Missing Android provenance for an
    AI source key raises ``ValueError`` before any file can be written.
    """
    ios_english = {
        key: unescape_ios(value)
        for key, value in parse_ios_strings(
            repo_root / "AndBible" / "en.lproj" / "Localizable.strings"
        ).items()
    }
    android_base = {
        key: android_string_for_ios(value)
        for key, value in parse_android_strings(android_root / "values" / "strings.xml").items()
    }
    required_ai_keys = discover_ai_localization_keys(repo_root)
    required_runtime_resource_keys = discover_android_runtime_resource_keys(repo_root)
    source_key_by_key = {
        key: key
        for key in set(ios_english) & set(android_base)
        if key not in ANDROID_SHARED_SAME_NAME_EXCLUSIONS
    }
    source_key_by_key.update(
        {
            ios_key: android_key
            for ios_key, android_key in ANDROID_SHARED_KEY_MAPPINGS.items()
            if ios_key in ios_english and android_key in android_base
        }
    )
    missing_android_sources: list[str] = []
    for ios_key in sorted(required_ai_keys):
        android_key = ANDROID_SHARED_KEY_MAPPINGS.get(ios_key, ios_key)
        if (
            android_key not in android_base
            or (
                ios_key in ANDROID_SHARED_SAME_NAME_EXCLUSIONS
                and ios_key not in ANDROID_SHARED_KEY_MAPPINGS
            )
        ):
            missing_android_sources.append(f"{ios_key} -> {android_key}")
            continue
        source_key_by_key[ios_key] = android_key
    for ios_key in sorted(required_runtime_resource_keys):
        android_key = ANDROID_SHARED_KEY_MAPPINGS.get(ios_key, ios_key)
        if android_key not in android_base:
            missing_android_sources.append(f"{ios_key} -> {android_key}")
            continue
        source_key_by_key[ios_key] = android_key
    source_key_by_key.update(
        discover_android_owned_swift_localization_keys(repo_root, android_base)
    )
    if missing_android_sources:
        raise ValueError(
            "Android-owned localization keys have no Android string resource: "
            + ", ".join(missing_android_sources)
        )

    mismatched_defaults: list[str] = []
    exact_defaults = discover_ai_localization_defaults(repo_root)
    for ios_key, defaults in discover_shipped_swift_localization_defaults(repo_root).items():
        if ios_key in ANDROID_EXACT_DEFAULT_KEYS:
            exact_defaults.setdefault(ios_key, set()).update(defaults)
    for ios_key, defaults in sorted(exact_defaults.items()):
        android_key = ANDROID_SHARED_KEY_MAPPINGS.get(ios_key, ios_key)
        expected = android_base.get(android_key)
        if expected is None:
            continue
        for default in sorted(defaults):
            if default != expected:
                mismatched_defaults.append(
                    f"{ios_key} -> {android_key}: {default!r} != {expected!r}"
                )
    if mismatched_defaults:
        raise ValueError(
            "Shipped localization defaults differ from Android English: "
            + "; ".join(mismatched_defaults)
        )

    safe_keys = sorted(source_key_by_key)
    expected_english_by_key = {
        key: IOS_PLATFORM_ENGLISH_OVERRIDES.get(
            key,
            android_base[source_key_by_key[key]],
        )
        for key in safe_keys
    }
    english_mismatch_keys = sorted(
        key
        for key in safe_keys
        if ios_english.get(key) != expected_english_by_key[key]
    )
    english_by_key = expected_english_by_key

    non_english_by_key: dict[str, list[str]] = {key: [] for key in safe_keys}
    translations_by_locale: dict[str, dict[str, str]] = {}
    for locale, qualifier in LOCALE_TO_ANDROID_VALUES.items():
        if locale == "en":
            continue
        locale_strings = {
            key: android_string_for_ios(value)
            for key, value in parse_android_strings(android_root / qualifier / "strings.xml").items()
        }
        locale_translations: dict[str, str] = {}
        for key in safe_keys:
            source_key = source_key_by_key[key]
            locale_value = locale_strings.get(source_key)
            if locale_value is None or locale_value == android_base[source_key]:
                continue
            non_english_by_key[key].append(locale)
            locale_translations[key] = locale_value
        if locale_translations:
            translations_by_locale[locale] = dict(sorted(locale_translations.items()))

    for key in safe_keys:
        non_english_by_key[key].sort()

    return AndroidSharedLocalization(
        safe_keys=safe_keys,
        english_mismatch_keys=english_mismatch_keys,
        android_resource_keys=sorted(android_base),
        source_key_by_key=dict(sorted(source_key_by_key.items())),
        english_by_key=english_by_key,
        non_english_by_key=non_english_by_key,
        translations_by_locale=translations_by_locale,
    )


def _load_string_list(payload: object, path: Path, field: str) -> list[str]:
    """Validate and return a list of strings from a snapshot field.

    Snapshot readers use this helper so corrupt Android-derived metadata fails
    before the guardrail can silently lower coverage. It performs no I/O and
    raises ValueError with the field name that needs regeneration.
    """
    if not isinstance(payload, list):
        raise ValueError(f"Invalid android_shared_localization.{field} in {path}: expected list")
    values: list[str] = []
    for index, value in enumerate(payload):
        if not isinstance(value, str):
            raise ValueError(
                f"Invalid android_shared_localization.{field}[{index}] in {path}: "
                "expected string"
            )
        values.append(value)
    return values


def load_android_shared_localization_from_snapshot(path: Path) -> AndroidSharedLocalization:
    """Load same-name Android translations from a generated snapshot.

    CI usually lacks a sibling Android checkout, so this parser validates the
    committed snapshot shape used by both audit and sync modes. Missing keys or
    non-string translations indicate snapshot corruption and abort the guardrail
    instead of treating Android coverage as empty.
    """
    payload = load_snapshot_payload(path)
    raw = payload.get("android_shared_localization")
    if not isinstance(raw, dict):
        raise ValueError(f"Snapshot missing android_shared_localization: {path}")

    safe_keys = _load_string_list(raw.get("safe_keys"), path, "safe_keys")
    english_mismatch_keys = _load_string_list(
        raw.get("english_mismatch_keys"),
        path,
        "english_mismatch_keys",
    )
    android_resource_keys = _load_string_list(
        raw.get("android_resource_keys"),
        path,
        "android_resource_keys",
    )

    raw_source_key_by_key = raw.get("source_key_by_key")
    if not isinstance(raw_source_key_by_key, dict):
        raise ValueError(
            f"Invalid android_shared_localization.source_key_by_key in {path}: expected object"
        )
    source_key_by_key: dict[str, str] = {}
    for key in safe_keys:
        value = raw_source_key_by_key.get(key)
        if not isinstance(value, str):
            raise ValueError(
                f"Invalid android_shared_localization.source_key_by_key.{key} in {path}: "
                "expected string"
            )
        source_key_by_key[key] = value

    raw_english_by_key = raw.get("english_by_key")
    if not isinstance(raw_english_by_key, dict):
        raise ValueError(
            f"Invalid android_shared_localization.english_by_key in {path}: expected object"
        )
    english_by_key: dict[str, str] = {}
    for key in safe_keys:
        value = raw_english_by_key.get(key)
        if not isinstance(value, str):
            raise ValueError(
                f"Invalid android_shared_localization.english_by_key.{key} in {path}: "
                "expected string"
            )
        english_by_key[key] = value

    raw_non_english = raw.get("non_english_by_key")
    if not isinstance(raw_non_english, dict):
        raise ValueError(
            f"Invalid android_shared_localization.non_english_by_key in {path}: expected object"
        )
    non_english_by_key: dict[str, list[str]] = {}
    for key in safe_keys:
        non_english_by_key[key] = sorted(
            _load_string_list(raw_non_english.get(key), path, f"non_english_by_key.{key}")
        )

    raw_translations = raw.get("translations_by_locale")
    if not isinstance(raw_translations, dict):
        raise ValueError(
            f"Invalid android_shared_localization.translations_by_locale in {path}: expected object"
        )
    translations_by_locale: dict[str, dict[str, str]] = {}
    for locale, raw_values in raw_translations.items():
        if not isinstance(locale, str):
            raise ValueError(
                f"Invalid android_shared_localization.translations_by_locale key in {path}"
            )
        if not isinstance(raw_values, dict):
            raise ValueError(
                "Invalid android_shared_localization.translations_by_locale"
                f".{locale} in {path}: expected object"
            )
        locale_values: dict[str, str] = {}
        for key, value in raw_values.items():
            if not isinstance(key, str) or not isinstance(value, str):
                raise ValueError(
                    "Invalid android_shared_localization.translations_by_locale"
                    f".{locale} entry in {path}: expected string key/value"
                )
            locale_values[key] = value
        translations_by_locale[locale] = dict(sorted(locale_values.items()))

    return AndroidSharedLocalization(
        safe_keys=safe_keys,
        english_mismatch_keys=english_mismatch_keys,
        android_resource_keys=android_resource_keys,
        source_key_by_key=source_key_by_key,
        english_by_key=english_by_key,
        non_english_by_key=non_english_by_key,
        translations_by_locale=translations_by_locale,
    )


def audit_android_shared_translations(
    repo_root: Path,
    catalog: AndroidSharedLocalization,
) -> SharedLocalizationAudit:
    """Compare same-name iOS keys against Android localized values.

    English values are always enforced for same-name keys. Non-English locales
    are enforced only when Android provides a translated value. The audit checks
    both iOS resource trees because Xcode bundles `AndBible` while CI also
    tracks the mirrored `Localizations` tree. It performs no file writes and
    returns empty dictionaries when all shared keys match Android.
    """
    ios_english_a = parse_ios_strings(repo_root / "AndBible" / "en.lproj" / "Localizable.strings")
    ios_english_b = parse_ios_strings(repo_root / "Localizations" / "en.lproj" / "Localizable.strings")
    ios_english = {key: unescape_ios(value) for key, value in ios_english_a.items()}
    ios_locales = sorted(
        p.name.removesuffix(".lproj")
        for p in (repo_root / "AndBible").glob("*.lproj")
        if p.name.endswith(".lproj") and p.name != "en.lproj"
    )

    missing_key_by_key: dict[str, list[str]] = {}
    english_value_mismatch_by_key: dict[str, list[str]] = {}
    english_placeholder_by_key: dict[str, list[str]] = {}
    value_mismatch_by_key: dict[str, list[str]] = {}
    tree_mismatch_by_key: dict[str, list[str]] = {}

    for key in missing_android_owned_localization_catalog_keys(repo_root, catalog):
        missing_key_by_key[key] = ["android-catalog"]

    for key, expected_value in catalog.english_by_key.items():
        raw_a = ios_english_a.get(key)
        raw_b = ios_english_b.get(key)
        if raw_a is None or raw_b is None:
            missing_key_by_key.setdefault(key, []).append("en")
            continue

        value_a = unescape_ios(raw_a)
        value_b = unescape_ios(raw_b)
        if value_a != value_b:
            tree_mismatch_by_key.setdefault(key, []).append("en")
        if value_a != expected_value or value_b != expected_value:
            english_value_mismatch_by_key.setdefault(key, []).append("en")

    for locale in ios_locales:
        expected_values = catalog.translations_by_locale.get(locale, {})
        if not expected_values:
            continue
        ios_a = parse_ios_strings(
            repo_root / "AndBible" / f"{locale}.lproj" / "Localizable.strings"
        )
        ios_b = parse_ios_strings(
            repo_root / "Localizations" / f"{locale}.lproj" / "Localizable.strings"
        )

        for key, expected_value in expected_values.items():
            raw_a = ios_a.get(key)
            raw_b = ios_b.get(key)
            if raw_a is None or raw_b is None:
                missing_key_by_key.setdefault(key, []).append(locale)
                continue

            value_a = unescape_ios(raw_a)
            value_b = unescape_ios(raw_b)
            if value_a != value_b:
                tree_mismatch_by_key.setdefault(key, []).append(locale)
            if value_a == ios_english.get(key):
                english_placeholder_by_key.setdefault(key, []).append(locale)
            if value_a != expected_value or value_b != expected_value:
                value_mismatch_by_key.setdefault(key, []).append(locale)

    for values in (
        missing_key_by_key,
        english_value_mismatch_by_key,
        english_placeholder_by_key,
        value_mismatch_by_key,
        tree_mismatch_by_key,
    ):
        for key in values:
            values[key].sort()

    return SharedLocalizationAudit(
        missing_key_by_key=dict(sorted(missing_key_by_key.items())),
        english_value_mismatch_by_key=dict(sorted(english_value_mismatch_by_key.items())),
        english_placeholder_by_key=dict(sorted(english_placeholder_by_key.items())),
        value_mismatch_by_key=dict(sorted(value_mismatch_by_key.items())),
        tree_mismatch_by_key=dict(sorted(tree_mismatch_by_key.items())),
    )


def update_ios_strings_file(path: Path, values: dict[str, str]) -> tuple[bool, int]:
    """Replace or append localized values in one `.strings` file.

    Existing rows keep their surrounding order and all unrelated comments or
    blank lines. Missing Android-sourced keys are appended in sorted order under a
    generated-section comment. The function writes only when content changes
    and returns `(file_changed, values_written)`.
    """
    lines = path.read_text(encoding="utf-8").splitlines()
    output: list[str] = []
    seen: set[str] = set()
    values_written = 0

    for line in lines:
        match = LINE_RE.match(line.strip())
        if match and match.group("key") in values:
            key = match.group("key")
            seen.add(key)
            escaped_value = escape_ios(values[key])
            if unescape_ios(match.group("val")) != values[key]:
                output.append(f'"{key}" = "{escaped_value}";')
                values_written += 1
            else:
                output.append(line)
        else:
            output.append(line)

    missing_keys = sorted(key for key in values if key not in seen)
    if missing_keys:
        if output and output[-1].strip():
            output.append("")
        output.append("/* Android shared translations */")
        for key in missing_keys:
            output.append(f'"{key}" = "{escape_ios(values[key])}";')
            values_written += 1

    new_text = "\n".join(output) + "\n"
    old_text = path.read_text(encoding="utf-8")
    if new_text == old_text:
        return False, 0
    path.write_text(new_text, encoding="utf-8")
    return True, values_written


def sync_android_shared_translations(
    repo_root: Path,
    catalog: AndroidSharedLocalization,
    *,
    included_keys: set[str] | None = None,
) -> SharedLocalizationSyncResult:
    """Write Android English and translations for selected shared iOS keys.

    The sync covers both `AndBible` and `Localizations` locale trees. Passing no
    key filter preserves the full shared-catalog behavior; a filter limits both
    English and translated writes to that set. Non-English resources are
    rewritten only where Android has a translated value. It mutates only
    existing iOS locale directories and returns deterministic write counts for
    reporting and tests. A stale Android catalog raises ``ValueError`` before
    writes begin, preventing a partial locale import.
    """
    requested_keys = set(catalog.english_by_key) if included_keys is None else included_keys
    missing_catalog_keys = sorted(requested_keys - set(catalog.english_by_key))
    if included_keys is None:
        missing_catalog_keys = sorted(
            set(missing_catalog_keys)
            | set(missing_android_owned_localization_catalog_keys(repo_root, catalog))
        )
    if missing_catalog_keys:
        raise ValueError(
            "Android localization catalog is missing requested source keys: "
            + ", ".join(missing_catalog_keys)
        )

    files_changed = 0
    values_written = 0
    english_values = {
        key: value
        for key, value in catalog.english_by_key.items()
        if key in requested_keys
    }

    for tree in ("AndBible", "Localizations"):
        path = repo_root / tree / "en.lproj" / "Localizable.strings"
        if not path.exists():
            continue
        changed, written = update_ios_strings_file(path, english_values)
        if changed:
            files_changed += 1
            values_written += written

    ios_locales = sorted(
        p.name.removesuffix(".lproj")
        for p in (repo_root / "AndBible").glob("*.lproj")
        if p.name.endswith(".lproj") and p.name != "en.lproj"
    )

    for locale in ios_locales:
        expected_values = {
            key: value
            for key, value in catalog.translations_by_locale.get(locale, {}).items()
            if key in requested_keys
        }
        if not expected_values:
            continue
        for tree in ("AndBible", "Localizations"):
            path = repo_root / tree / f"{locale}.lproj" / "Localizable.strings"
            if not path.exists():
                continue
            changed, written = update_ios_strings_file(path, expected_values)
            if changed:
                files_changed += 1
                values_written += written

    return SharedLocalizationSyncResult(
        files_changed=files_changed,
        values_written=values_written,
    )


def sync_android_ai_translations(
    repo_root: Path,
    catalog: AndroidSharedLocalization,
) -> SharedLocalizationSyncResult:
    """Write only source-referenced AI translations from the Android catalog.

    The source inventory includes both AI module trees and ``llm_actions``. The
    shared writer still preserves ordering, comments, and unrelated keys in both
    iOS localization trees. Missing Android provenance raises ``ValueError``
    before any locale file is changed.
    """
    return sync_android_shared_translations(
        repo_root,
        catalog,
        included_keys=discover_ai_localization_keys(repo_root),
    )


def load_android_non_english_snapshot(path: Path) -> dict[str, list[str]]:
    """Load Android translation coverage from a generated parity snapshot.

    Each tracked parity key must be present and mapped to a list of locale
    strings. Rejecting missing keys and non-string locales keeps a corrupt
    baseline from weakening the localization audit through implicit defaults.
    """
    payload = load_snapshot_payload(path)
    raw = payload.get("android_non_english_by_key")
    if not isinstance(raw, dict):
        raise ValueError(f"Snapshot missing android_non_english_by_key: {path}")

    non_english_by_key: dict[str, list[str]] = {}
    for key in PARITY_KEYS:
        values = raw.get(key)
        if not isinstance(values, list):
            raise ValueError(f"Invalid android_non_english_by_key[{key}] in {path}: expected list")

        locales: list[str] = []
        for index, locale in enumerate(values):
            if not isinstance(locale, str):
                raise ValueError(
                    f"Invalid android_non_english_by_key[{key}][{index}] in {path}: "
                    "expected string"
                )
            locales.append(locale)

        non_english_by_key[key] = sorted(locales)
    return non_english_by_key


def write_android_non_english_snapshot(
    path: Path,
    non_english_by_key: dict[str, list[str]],
    locale_pref_options: list[LocalePrefOption],
    shared_localization: AndroidSharedLocalization,
) -> None:
    """Write a deterministic Android localization snapshot for iOS parity checks.

    The live Android resource directory is intentionally not serialized as an absolute path.
    Local and CI runs can use different checkout directories, and committing those
    machine-specific paths causes noisy fixture churn without improving audit behavior.
    """
    payload = {
        "generated_on": date.today().isoformat(),
        "source_android_res": ANDROID_SNAPSHOT_SOURCE_RES,
        "parity_keys": PARITY_KEYS,
        "locale_to_android_values": LOCALE_TO_ANDROID_VALUES,
        "locale_pref_options": [
            {"value": option.value, "label_key": option.label_key}
            for option in locale_pref_options
        ],
        "android_non_english_by_key": non_english_by_key,
        "android_shared_localization": {
            "safe_keys": shared_localization.safe_keys,
            "english_mismatch_keys": shared_localization.english_mismatch_keys,
            "android_resource_keys": shared_localization.android_resource_keys,
            "source_key_by_key": shared_localization.source_key_by_key,
            "english_by_key": shared_localization.english_by_key,
            "non_english_by_key": shared_localization.non_english_by_key,
            "translations_by_locale": shared_localization.translations_by_locale,
        },
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


@dataclass
class Audit:
    locales: list[str]
    english_placeholder_by_key: dict[str, list[str]]
    ios_gap_by_key: dict[str, list[str]]
    tree_mismatches: list[str]
    android_source: str
    shared_localization: AndroidSharedLocalization | None
    shared_audit: SharedLocalizationAudit | None


def run_audit(
    repo_root: Path,
    android_non_english_by_key: dict[str, list[str]],
    android_source: str,
    shared_localization: AndroidSharedLocalization | None = None,
) -> Audit:
    ios_a_root = repo_root / "AndBible"
    ios_b_root = repo_root / "Localizations"

    en_a = parse_ios_strings(ios_a_root / "en.lproj" / "Localizable.strings")
    en_b = parse_ios_strings(ios_b_root / "en.lproj" / "Localizable.strings")
    english = {k: unescape_ios(en_a[k]) for k in PARITY_KEYS}

    tree_mismatches: list[str] = []
    for key in PARITY_KEYS:
        if key not in en_a or key not in en_b:
            tree_mismatches.append(f"missing_en_key:{key}")
        elif en_a[key] != en_b[key]:
            tree_mismatches.append(f"en_tree_mismatch:{key}")

    locales = sorted(
        p.name.replace(".lproj", "")
        for p in ios_a_root.glob("*.lproj")
        if p.name.endswith(".lproj") and p.name != "en.lproj"
    )

    english_placeholder_by_key = {k: [] for k in PARITY_KEYS}
    ios_gap_by_key = {k: [] for k in PARITY_KEYS}

    for locale in locales:
        ios_a = parse_ios_strings(ios_a_root / f"{locale}.lproj" / "Localizable.strings")
        ios_b = parse_ios_strings(ios_b_root / f"{locale}.lproj" / "Localizable.strings")

        for key in PARITY_KEYS:
            if key not in ios_a or key not in ios_b:
                tree_mismatches.append(f"missing_locale_key:{locale}:{key}")
                continue

            va = unescape_ios(ios_a[key])
            vb = unescape_ios(ios_b[key])
            if va != vb:
                tree_mismatches.append(f"locale_tree_mismatch:{locale}:{key}")

            ios_is_english = va == english[key]
            if ios_is_english:
                english_placeholder_by_key[key].append(locale)

            if ios_is_english and locale in android_non_english_by_key.get(key, []):
                ios_gap_by_key[key].append(locale)

    for key in PARITY_KEYS:
        english_placeholder_by_key[key].sort()
        ios_gap_by_key[key].sort()

    return Audit(
        locales=locales,
        english_placeholder_by_key=english_placeholder_by_key,
        ios_gap_by_key=ios_gap_by_key,
        tree_mismatches=tree_mismatches,
        android_source=android_source,
        shared_localization=shared_localization,
        shared_audit=(
            audit_android_shared_translations(repo_root, shared_localization)
            if shared_localization is not None
            else None
        ),
    )


def write_baseline(path: Path, audit: Audit) -> None:
    payload = {
        "generated_on": date.today().isoformat(),
        "parity_keys": PARITY_KEYS,
        "locales": audit.locales,
        "english_placeholder_by_key": audit.english_placeholder_by_key,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    repo_root_default = default_repo_root()
    android_root_default = default_android_root()
    android_snapshot_default = default_android_snapshot()

    parser = argparse.ArgumentParser(description="Settings localization parity guardrails (SETPAR-603)")
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=repo_root_default,
        help="Path to and-bible-ios repository root",
    )
    parser.add_argument(
        "--android-root",
        type=Path,
        default=android_root_default,
        help="Path to Android app res directory",
    )
    parser.add_argument(
        "--android-snapshot",
        type=Path,
        default=android_snapshot_default,
        help="Path to committed Android non-English parity snapshot JSON",
    )
    parser.add_argument(
        "--baseline",
        type=Path,
        default=(
            repo_root_default
            / "scripts"
            / "fixtures"
            / "settings-localization"
            / "localization-guardrail.json"
        ),
        help="Baseline JSON path",
    )
    parser.add_argument(
        "--allow-count-increase",
        type=int,
        default=0,
        help="Allowed increase in English-placeholder count per key vs baseline",
    )
    parser.add_argument(
        "--write-baseline",
        action="store_true",
        help="Write baseline file from current state and exit 0",
    )
    parser.add_argument(
        "--write-android-snapshot",
        action="store_true",
        help="Write Android non-English parity snapshot from --android-root and exit 0",
    )
    parser.add_argument(
        "--sync-android-shared-translations",
        action="store_true",
        help=(
            "Update iOS locale files from Android for same-name keys whose English text matches"
        ),
    )
    parser.add_argument(
        "--sync-android-ai-translations",
        action="store_true",
        help="Update only source-referenced AI localization keys from Android",
    )
    parser.add_argument(
        "--sync-discrete-security-copy",
        action="store_true",
        help="Update runtime Calculator security help from Android plus the iOS limitation",
    )
    parser.add_argument(
        "--sync-product-feedback-copy",
        action="store_true",
        help="Update product-feedback copy from Android plus truthful iOS-only fallbacks",
    )
    args = parser.parse_args()

    if args.write_android_snapshot:
        if not args.android_root.exists():
            print(f"Android root not found: {args.android_root}", file=sys.stderr)
            return 2
        non_english_by_key = build_android_non_english_by_key(args.android_root)
        locale_pref_options = build_android_locale_pref_options(args.android_root)
        shared_localization = build_android_shared_localization(args.repo_root, args.android_root)
        write_android_non_english_snapshot(
            args.android_snapshot,
            non_english_by_key,
            locale_pref_options,
            shared_localization,
        )
        print(f"Wrote Android snapshot: {args.android_snapshot}")
        return 0

    if args.android_root.exists():
        non_english_by_key = build_android_non_english_by_key(args.android_root)
        locale_pref_options = build_android_locale_pref_options(args.android_root)
        shared_localization = build_android_shared_localization(args.repo_root, args.android_root)
        android_source = f"live:{args.android_root}"
    elif args.android_snapshot.exists():
        try:
            non_english_by_key = load_android_non_english_snapshot(args.android_snapshot)
            locale_pref_options = load_android_locale_pref_options_from_snapshot(args.android_snapshot)
            shared_localization = load_android_shared_localization_from_snapshot(args.android_snapshot)
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        android_source = f"snapshot:{args.android_snapshot}"
    else:
        print(
            "Neither Android res directory nor snapshot file is available.\n"
            f"  android_root: {args.android_root}\n"
            f"  android_snapshot: {args.android_snapshot}",
            file=sys.stderr,
        )
        return 2

    if args.sync_android_shared_translations:
        result = sync_android_shared_translations(args.repo_root, shared_localization)
        print("Android shared localization sync summary")
        print(f"- files changed: {result.files_changed}")
        print(f"- values written: {result.values_written}")
        print(f"- Android-sourced shared keys: {len(shared_localization.safe_keys)}")
        print(f"- explicit mapped keys: {len(ANDROID_SHARED_KEY_MAPPINGS)}")
        print(f"- English values repaired: {len(shared_localization.english_mismatch_keys)}")
        print(f"- android source: {android_source}")
        return 0

    if args.sync_android_ai_translations:
        result = sync_android_ai_translations(args.repo_root, shared_localization)
        print("Android AI localization sync summary")
        print(f"- files changed: {result.files_changed}")
        print(f"- values written: {result.values_written}")
        print(f"- source-referenced AI keys: {len(discover_ai_localization_keys(args.repo_root))}")
        print(f"- android source: {android_source}")
        return 0

    if args.sync_discrete_security_copy:
        try:
            result = sync_discrete_security_localizations(args.repo_root, shared_localization)
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        print("Runtime Calculator security-copy sync summary")
        print(f"- files changed: {result.files_changed}")
        print(f"- values written or removed: {result.values_written}")
        print(f"- locales checked: {len(LOCALE_TO_ANDROID_VALUES)}")
        print(f"- android source: {android_source}")
        return 0

    if args.sync_product_feedback_copy:
        try:
            result = sync_product_feedback_localizations(args.repo_root, shared_localization)
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        print("Product-feedback localization sync summary")
        print(f"- files changed: {result.files_changed}")
        print(f"- values written or removed: {result.values_written}")
        print(f"- locales checked: {len(LOCALE_TO_ANDROID_VALUES)}")
        print(f"- android source: {android_source}")
        return 0

    audit = run_audit(args.repo_root, non_english_by_key, android_source, shared_localization)
    locale_pref_audit = audit_locale_pref_contract(args.repo_root, locale_pref_options)

    if args.write_baseline:
        write_baseline(args.baseline, audit)
        print(f"Wrote baseline: {args.baseline}")
        return 0

    if not args.baseline.exists():
        print(f"Baseline not found: {args.baseline}", file=sys.stderr)
        print("Run with --write-baseline first.", file=sys.stderr)
        return 2

    baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
    base_counts = {
        key: len(locales)
        for key, locales in baseline.get("english_placeholder_by_key", {}).items()
    }

    failures: list[str] = []

    unlocalized_swift_ui_literals = discover_unlocalized_swift_ui_literals(args.repo_root)
    if unlocalized_swift_ui_literals:
        failures.append("Unlocalized shipped SwiftUI literals:")
        failures.extend(f"  - {item}" for item in unlocalized_swift_ui_literals)

    try:
        discrete_security_failures = audit_discrete_security_localizations(
            args.repo_root,
            shared_localization,
        )
    except ValueError as exc:
        discrete_security_failures = [str(exc)]
    if discrete_security_failures:
        failures.append("Runtime Calculator security-copy failures:")
        failures.extend(f"  - {item}" for item in discrete_security_failures)

    try:
        product_feedback_failures = audit_product_feedback_localizations(
            args.repo_root,
            shared_localization,
        )
    except ValueError as exc:
        product_feedback_failures = [str(exc)]
    if product_feedback_failures:
        failures.append("Product-feedback localization failures:")
        failures.extend(f"  - {item}" for item in product_feedback_failures)

    if audit.tree_mismatches:
        failures.append("Tree consistency failures:")
        failures.extend(f"  - {item}" for item in sorted(audit.tree_mismatches))

    ios_gap_count = sum(len(v) for v in audit.ios_gap_by_key.values())
    if ios_gap_count > 0:
        failures.append("iOS-vs-Android translation gaps (must be zero):")
        for key in PARITY_KEYS:
            bad = audit.ios_gap_by_key.get(key, [])
            if bad:
                failures.append(f"  - {key}: {', '.join(bad)}")

    for key in PARITY_KEYS:
        current = len(audit.english_placeholder_by_key.get(key, []))
        baseline_count = int(base_counts.get(key, 0))
        if current > baseline_count + args.allow_count_increase:
            failures.append(
                f"English-placeholder count regression for {key}: "
                f"baseline={baseline_count}, current={current}, "
                f"allowed_increase={args.allow_count_increase}"
            )

    if locale_pref_audit.failures:
        failures.append("locale_pref option contract failures:")
        failures.extend(f"  - {item}" for item in locale_pref_audit.failures)

    shared_missing_count = 0
    shared_english_mismatch_count = 0
    shared_placeholder_count = 0
    shared_mismatch_count = 0
    shared_tree_mismatch_count = 0
    if audit.shared_audit is not None:
        shared_missing_count = sum(len(v) for v in audit.shared_audit.missing_key_by_key.values())
        shared_english_mismatch_count = sum(
            len(v) for v in audit.shared_audit.english_value_mismatch_by_key.values()
        )
        shared_placeholder_count = sum(
            len(v) for v in audit.shared_audit.english_placeholder_by_key.values()
        )
        shared_mismatch_count = sum(
            len(v) for v in audit.shared_audit.value_mismatch_by_key.values()
        )
        shared_tree_mismatch_count = sum(
            len(v) for v in audit.shared_audit.tree_mismatch_by_key.values()
        )

        if shared_missing_count > 0:
            failures.append("Android shared localization missing iOS keys:")
            for key, locales in audit.shared_audit.missing_key_by_key.items():
                failures.append(f"  - {key}: {', '.join(locales)}")

        if shared_english_mismatch_count > 0:
            failures.append("Android shared localization English value drift:")
            for key, locales in audit.shared_audit.english_value_mismatch_by_key.items():
                failures.append(f"  - {key}: {', '.join(locales)}")

        if shared_mismatch_count > 0:
            failures.append("Android shared localization value drift:")
            for key, locales in audit.shared_audit.value_mismatch_by_key.items():
                failures.append(f"  - {key}: {', '.join(locales)}")

        if shared_tree_mismatch_count > 0:
            failures.append("Android shared localization tree mismatches:")
            for key, locales in audit.shared_audit.tree_mismatch_by_key.items():
                failures.append(f"  - {key}: {', '.join(locales)}")

    print("SETPAR-603 guardrail summary")
    print(f"- tree mismatches: {len(audit.tree_mismatches)}")
    print(f"- ios_gap count: {ios_gap_count}")
    print(f"- android source: {audit.android_source}")
    print(f"- keys checked: {len(PARITY_KEYS)}")
    print(f"- locales checked: {len(audit.locales)}")
    print(f"- locale_pref supported values: {len(locale_pref_audit.supported_values)}")
    print(f"- locale_pref unavailable Android values: {len(locale_pref_audit.unsupported_values)}")
    print(f"- locale_pref extra iOS-only resource locales: {len(locale_pref_audit.extra_ios_locales)}")
    print(f"- discrete security-copy locales: {len(LOCALE_TO_ANDROID_VALUES)}")
    print(f"- product-feedback localization locales: {len(LOCALE_TO_ANDROID_VALUES)}")
    print(f"- unlocalized shipped SwiftUI literals: {len(unlocalized_swift_ui_literals)}")
    if audit.shared_localization is not None:
        print(f"- android shared source keys: {len(audit.shared_localization.safe_keys)}")
        print(f"- android shared explicit mapped keys: {len(ANDROID_SHARED_KEY_MAPPINGS)}")
        print(f"- android shared English value drift: {shared_english_mismatch_count}")
        print(f"- android shared missing iOS keys: {shared_missing_count}")
        print(f"- android shared English placeholders: {shared_placeholder_count}")
        print(f"- android shared value mismatches: {shared_mismatch_count}")
        print(f"- android shared tree mismatches: {shared_tree_mismatch_count}")

    if failures:
        print("\nFAILURES:")
        for line in failures:
            print(line)
        return 1

    print("Guardrails passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
