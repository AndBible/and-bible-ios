# Android Settings Contract (Source Of Truth)

Last audited: 2026-06-11 for #164 `locale_pref` option contract.
Full settings inventory last re-audited: 2026-06-03 for #170.

This file records the Android Application preferences contract and the current iOS
disposition for each Android preference row. It intentionally separates two layers:

- Android source inventory: every actionable preference row in
  `and-bible/app/src/main/res/xml/settings.xml`.
- iOS implementation registry: `AppPreferenceRegistry`, which only contains durable
  iOS parity settings and action rows that iOS currently implements.

The two counts are not expected to be equal. Android currently exposes 41 actionable
preference rows. iOS currently registers 36 of them in `AppPreferenceRegistry`; every
Android row outside that registry must have an explicit disposition below.

Primary Android sources:
- Settings schema: `and-bible/app/src/main/res/xml/settings.xml:23-293`
- Runtime setup/reset/visibility: `and-bible/app/src/main/java/net/bible/android/view/activity/settings/SettingsActivity.kt:134-385`
- Reader config values: `and-bible/app/src/main/java/net/bible/service/common/CommonUtils.kt:452-459`
- Reader config payload: `and-bible/app/src/main/java/net/bible/android/view/activity/page/BibleView.kt:1508-1538`
- Shared Vue reader config: `and-bible/app/bibleview-js/src/composables/config.ts`

Primary iOS sources:
- Registry: `Sources/BibleCore/Sources/BibleCore/Database/AppPreferenceRegistry.swift`
- Settings UI: `Sources/BibleUI/Sources/BibleUI/Settings/SettingsView.swift`
- Settings search: `Sources/BibleUI/Sources/BibleUI/Settings/AndBibleSettingsSearch.swift`
- Android icon mapping: `Sources/BibleUI/Sources/BibleUI/Shared/AndBibleIconCatalog.swift`
- Reader config payload: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`
- Shared Vue reader config: `bibleview-js/src/composables/config.ts`

## Inventory Rules

- `bible_display_pref` is the Android `PreferenceScreen` container key and is not an
  actionable application preference.
- `dictionaries_category` is a category container key. It is documented as category
  metadata, not as a user preference.
- `global_text_display_settings`, `sync_settings_shortcut`,
  `ai_settings_shortcut`, and `reading_progress_settings_shortcut` are action rows,
  not durable preference values. They should not be added to `AppPreferenceRegistry`
  unless iOS intentionally models them as registry-backed actions.
- iOS Application preferences reset uses `AppPreferenceRegistry.applicationPreferencesResetKeys`.
  Action rows and global text-display settings are excluded from that reset contract.
- iOS Application preferences search is native SwiftUI search over normalized row
  identifiers, titles, summaries, details, and keywords. All query terms must match.
- `eink_mode` is an Android e-ink feature switch and is intentionally not registered
  on iOS unless iOS gains equivalent e-ink behavior.
- `notes_content_type` is registry-backed on iOS for Settings/default/appSettings
  parity. Full note-editor content-type behavior remains tracked by #163.
- `locale_pref` is registry-backed. Its option list is source-backed against
  Android `arrays.xml`, filtered to Android values that can load a shipped iOS
  `.lproj`, and protected by `scripts/check_settings_localization_guardrails.py`.

## Category Titles

| Category | String key | English text | Reference |
|---|---|---|---|
| Dictionaries | `prefs_dictionaries_cat` | Dictionaries | `strings.xml:277` |
| Application behavior | `prefs_behavior_customization_cat` | Application behavior | `strings.xml:227` |
| Look & feel | `prefs_display_customization_cat` | Look & feel | `strings.xml:226` |
| E-ink settings | `prefs_eink_settings_cat` | E-ink settings | `strings.xml:120` |
| Settings for the persecuted | `prefs_persecution_cat` | Settings for the persecuted | `strings.xml:1166` |
| Features | `prefs_features_cat` | Features | `strings.xml:225` |
| Advanced settings | `prefs_advanced_settings_cat` | Advanced settings | `strings.xml:224` |

## Android Preference Inventory And iOS Disposition

| Key | Android source / behavior | iOS disposition |
|---|---|---|
| `strongs_greek_dictionary` | XML `settings.xml:28-32`; dictionary rows/defaults are populated at `SettingsActivity.kt:245-254`. | Registry-backed pass. |
| `strongs_hebrew_dictionary` | XML `settings.xml:33-37`; dictionary rows/defaults are populated at `SettingsActivity.kt:245-254`. | Registry-backed pass. |
| `robinson_greek_morphology` | XML `settings.xml:38-42`; dictionary rows/defaults are populated at `SettingsActivity.kt:245-254`. | Registry-backed pass. |
| `disabled_word_lookup_dictionaries` | XML `settings.xml:43-47`; inverse dictionary row is populated at `SettingsActivity.kt:251-254`. | Registry-backed pass. |
| `navigate_to_verse_pref` | XML `settings.xml:52-57`; default `false`. | Registry-backed pass. |
| `open_links_in_special_window_pref` | XML `settings.xml:58-62`; default `true`. | Registry-backed pass. |
| `screen_keep_on_pref` | XML `settings.xml:63-68`; default `false`. | Registry-backed pass. |
| `double_tap_to_fullscreen` | XML `settings.xml:69-74`; default `true`. | Registry-backed pass. |
| `auto_fullscreen_pref` | XML `settings.xml:75-80`; default `false`. | Registry-backed pass. |
| `toolbar_button_actions` | XML `settings.xml:81-86`; blank values are normalized to `default` at `SettingsActivity.kt:270-273`. | Registry-backed adapted pass. |
| `disable_two_step_bookmarking` | XML `settings.xml:88-93`; default `false`. | Registry-backed pass. |
| `bible_view_swipe_mode` | XML `settings.xml:94-100`; default `CHAPTER`. | Registry-backed adapted pass. |
| `volume_keys_scroll` | XML `settings.xml:101-106`; Android handles hardware volume-key scrolling. | Registry-backed documented divergence: iOS keeps persistence/UI for sync continuity but cannot intercept volume buttons for app actions. |
| `night_mode_pref3` | XML `settings.xml:107-113`; runtime entries/default are replaced at `SettingsActivity.kt:233-242`. | Registry-backed adapted pass. |
| `global_text_display_settings` | XML `settings.xml:118-122`; action starts global `TextDisplaySettingsActivity` at `SettingsActivity.kt:299-308`. Android's nested color UI can inflate `workspace_color`, but durable workspace-color writes belong to `SettingsLevel.WORKSPACE`; see [ADR 0005](../../adr/0005-workspace-color-scope-and-reader-chrome.md). | Outside registry, adapted on iOS. Global display settings use `SettingsStore.globalTextDisplaySettingsKey`; Settings links live in `SettingsView.lookAndFeelSection`; true global settings do not mutate workspace color. |
| `locale_pref` | XML `settings.xml:124-130`; option arrays are `arrays.xml:121-230`; Android applies the stored value through `LocaleHelper` and `Locale.forLanguageTag`. | Registry-backed pass. iOS persists Android values and maps them to `AppleLanguages` only at the platform boundary. The picker shows Android values that have shipped iOS `.lproj` resources and documents unavailable Android values below. |
| `disable_click_to_edit` | XML `settings.xml:131-137`; Android emits `disableClickToEdit` into `appSettings`. | Registry-backed pass. |
| `notes_content_type` | XML `settings.xml:138-145`; default `HTML`; values `HTML`/`MARKDOWN` at `arrays.xml:264-271`; Android emits `notesContentType` at `BibleView.kt:1537`. | Registry-backed partial. iOS shows the row, persists the value, and emits `appSettings.notesContentType`; applying it to newly created bookmark notes and Study Pad entries remains tracked by #163. |
| `font_size_multiplier` | XML `settings.xml:146-153`; default `100`, min `10`, max `500`; summary updates at `SettingsActivity.kt:255-268`. | Registry-backed pass. |
| `full_screen_hide_buttons_pref` | XML `settings.xml:154-159`; effective default `true`. | Registry-backed pass. |
| `hide_window_buttons` | XML `settings.xml:160-165`; default `false`. | Registry-backed pass. |
| `hide_bible_reference_overlay` | XML `settings.xml:166-171`; default `false`. | Registry-backed pass. |
| `show_active_window_indicator` | XML `settings.xml:172-177`; default `true`. | Registry-backed pass. |
| `disable_bible_bookmark_modal_buttons` | XML `settings.xml:178-184`; Android inverse multi-select action IDs from `arrays.xml:231-250`. | Registry-backed pass. |
| `disable_gen_bookmark_modal_buttons` | XML `settings.xml:185-191`; Android inverse multi-select action IDs from `arrays.xml:251-262`. | Registry-backed pass. |
| `monochrome_mode` | XML `settings.xml:195-200`; Android runtime default is `isOnyxDevice` at `CommonUtils.kt:452`. | Registry-backed adapted pass. iOS default remains `false` because iOS has no Onyx-device default path. |
| `eink_mode` | XML `settings.xml:201-206`; Android emits `einkMode` at `BibleView.kt:1531`; Vue uses it for scroll helper lines/page buttons at `BibleView.vue:74-83`. | Documented divergence. Do not implement as dead iOS UI; see `dispositions.md`. |
| `disable_animations` | XML `settings.xml:207-212`; Android runtime default is `isOnyxDevice` at `CommonUtils.kt:454`. | Registry-backed adapted pass. iOS default remains `false` because iOS has no Onyx-device default path. |
| `discrete_help` | XML `settings.xml:216-221`; click behavior is `SettingsActivity.kt:325-353`. | Registry-backed adapted action. |
| `discrete_mode` | XML `settings.xml:222-227`; hidden in discrete flavor at `SettingsActivity.kt:310-314`; standard Android toggles launcher identity through activity aliases, while the discrete flavor bakes calculator identity into resources. | Registry-backed adapted pass. iOS changes the alternate launcher icon only; runtime app-name changes are not supported by the iOS bundle metadata model. See [ADR 0007](../../adr/0007-ios-discrete-mode-app-name-boundary.md). |
| `show_calculator` | XML `settings.xml:228-232`; hidden/summary adjusted at `SettingsActivity.kt:315-324`. | Registry-backed pass. |
| `calculator_pin` | XML `settings.xml:233-238`; numeric editor enforced at `SettingsActivity.kt:280-282`. | Registry-backed pass. |
| `sync_settings_shortcut` | XML `settings.xml:241-245`; starts `SyncSettingsActivity` at `SettingsActivity.kt:284-287`. | Outside registry, adapted as an iOS Features shortcut to `SyncSettingsView` with Android-sourced icon mapping. |
| `ai_settings_shortcut` | XML `settings.xml:246-250`; starts `AiSettingsActivity` at `SettingsActivity.kt:289-292`. | Outside registry, intentionally absent until iOS has an AI settings contract; tracked by the iOS AI parity issues (#5, #74, #89-#92). |
| `reading_progress_settings_shortcut` | XML `settings.xml:251-255`; starts `ReadingProgressSettingsActivity` at `SettingsActivity.kt:294-297`. | Outside registry, adapted as an iOS Features shortcut to native `ReadingProgressSettingsView` with Android-sourced icon mapping. |
| `experimental_features` | XML `settings.xml:258-265`; option arrays are `arrays.xml:273-280`. | Registry-backed pass. |
| `enable_bluetooth_pref` | XML `settings.xml:266-270`; default `true`. | Registry-backed adapted pass through iOS remote command handling. |
| `request_sdcard_permission_pref` | XML `settings.xml:271-274`; hidden on Android Q+ at `SettingsActivity.kt:275-278`. | Registry-backed documented divergence. iOS has no SD-card permission model. |
| `show_errorbox` | XML `settings.xml:275-280`; visible only for beta at `SettingsActivity.kt:243-244`. | Registry-backed adapted pass; iOS exposes only in debug builds. |
| `open_links` | XML `settings.xml:281-286`; visible on Android S+ and opens app-link settings at `SettingsActivity.kt:368-383`. | Registry-backed adapted action; iOS opens app settings. |
| `crash_app` | XML `settings.xml:287-291`; visible only for beta/debug at `SettingsActivity.kt:355-367`. | Registry-backed adapted action; iOS debug-only delayed crash. |

## List / Multi-Select Option Contracts

| Key | Options contract | Reference | iOS disposition |
|---|---|---|---|
| `toolbar_button_actions` | `default`, `swap-menu`, `swap-activity` | `arrays.xml:65-74` | Implemented. |
| `bible_view_swipe_mode` | `CHAPTER`, `PAGE`, `NONE` | `arrays.xml:77-87` | Implemented with native iOS gestures. |
| `night_mode_pref3` | runtime-dependent `system`/`automatic`/`manual` or `system`/`manual` | `arrays.xml:90-116`, `SettingsActivity.kt:233-242` | Adapted: iOS supports system/manual and documents excluded automatic behavior. |
| `locale_pref` | Android language label/value arrays | `arrays.xml:121-230` | Implemented with iOS resource filtering and machine-readable drift guard. |
| `notes_content_type` | `HTML`, `MARKDOWN` | `arrays.xml:264-271` | Implemented for Settings/default/payload; note creation/storage behavior remains #163. |
| `disable_bible_bookmark_modal_buttons` | Bible one-tap action IDs | `arrays.xml:231-250` | Implemented. |
| `disable_gen_bookmark_modal_buttons` | Generic one-tap action IDs | `arrays.xml:251-262` | Implemented. |
| `experimental_features` | `bookmark_edit_actions`, `add_paragraph_break` | `arrays.xml:273-280` | Implemented. |

## `locale_pref` Option Contract

The iOS picker preserves Android `prefs_interface_locale_values` order after
filtering values that cannot load a shipped iOS localization resource. Persisted
values remain Android values for sync/settings parity; the iOS-only mapping is:

| Android value | iOS resource / Apple language value |
|---|---|
| `iw` | `he` |
| `in` | `id` |
| `zh-Hant-TW` | `zh-Hant` |
| `zh-Hans-CN` | `zh-Hans` |

Supported iOS picker values:

`""` (default), `af`, `ar`, `bg`, `bn`, `my`, `cs`, `de`, `en`, `eo`, `es`, `et`,
`fi`, `fr`, `iw`, `hi`, `hr`, `hu`, `in`, `it`, `kk`, `ko`, `lt`, `nb`, `nl`,
`pl`, `pt`, `pt-BR`, `ro`, `ru`, `sk`, `sl`, `sr`, `sr-Latn`, `ta`, `te`,
`tr`, `uk`, `uz`, `yue`, `zh-Hant-TW`, `zh-Hans-CN`.

Android values intentionally unavailable on iOS because no matching app
localization resource is shipped:

`ca`, `da`, `fil`, `ja`, `ms`, `ne`, `sw`, `th`, `ur`, `vi`.

iOS resource locales `az`, `el`, `ml`, and `sv` are not shown in this picker
because Android does not expose them in `prefs_interface_locale_values`. They
must not become iOS-only picker options unless the Android source contract also
adds them.

## Android Runtime Visibility / Dynamic Rules

| Rule | Reference | iOS disposition |
|---|---|---|
| `night_mode_pref3` entries/default are adjusted by `autoModeAvailable`. | `SettingsActivity.kt:233-242` | Adapted. |
| `show_errorbox` visible only in beta builds. | `SettingsActivity.kt:243-244` | Adapted to debug builds. |
| Dictionary category hidden if no dictionary modules are available. | `SettingsActivity.kt:245-254` | Implemented. |
| `font_size_multiplier` summary shows the current multiplier. | `SettingsActivity.kt:255-268` | Implemented with a SwiftUI stepper value. |
| `request_sdcard_permission_pref` hidden on Android Q+. | `SettingsActivity.kt:275-278` | iOS divergence. |
| `calculator_pin` editor forced to numeric input. | `SettingsActivity.kt:280-282` | Implemented. |
| Sync, AI, and Reading Progress shortcuts open adjacent settings screens. | `SettingsActivity.kt:284-297` | Sync and Reading Progress are adapted as native iOS Features shortcuts. AI remains deferred because iOS has no AI settings workflow yet. |
| `global_text_display_settings` opens global text-display settings. | `SettingsActivity.kt:299-308` | Adapted through Look & feel settings links and `SettingsStore.globalTextDisplaySettingsKey`. |
| `discrete_mode` and `show_calculator` hidden in discrete flavor. | `SettingsActivity.kt:310-324` | Adapted through iOS app-icon/calculator behavior. |
| `discrete_help` shows flavor-dependent help dialog. | `SettingsActivity.kt:325-353` | Adapted as iOS help sheet. |
| `crash_app` visible only in beta/debug. | `SettingsActivity.kt:355-367` | Adapted to debug builds. |
| `open_links` visible only on Android S+; otherwise hidden. | `SettingsActivity.kt:368-383` | Adapted to iOS app settings. |

## Ownership And Review Checklist

- Owner: iOS parity maintainers (`and-bible-ios`)
- Source owner: Android settings maintainers (`and-bible`)
- Review cadence: verify on each Android settings schema/string/array change

Checklist for parity updates:

- Confirm `settings.xml` actionable row set still matches this inventory.
- Confirm new Android rows are either added to `AppPreferenceRegistry`, tracked by a
  follow-up issue, or documented as an intentional divergence.
- Confirm defaults in XML/runtime code still match this contract.
- Confirm labels/summaries and option arrays still match this contract.
- Confirm runtime visibility/dynamic rules still match this contract.
- Confirm the verification matrix does not summarize parity as a 36-key Android
  contract unless Android source still proves that count.
