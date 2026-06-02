# SETPAR-701 Verification Matrix (Android Application Preferences -> iOS)

Date: 2026-06-01

## Scope and Method

- Android source baseline: `docs/parity/settings/contract.md`, re-audited from
  `and-bible/app/src/main/res/xml/settings.xml:23-293`.
- Android actionable preference rows: 41.
- iOS registry baseline: `Sources/BibleCore/Sources/BibleCore/Database/AppPreferenceRegistry.swift`
  (`AppPreferenceKey.allCases` = 35).
- Verification method: direct inspection of Android XML/runtime sources, iOS registry,
  iOS Settings UI, iOS reader payload, and the Android/iOS Vue `appSettings` contracts.

The previous matrix treated the 35 iOS registry keys as the complete Android contract.
That was incorrect. The matrix now distinguishes registry-backed iOS parity from
Android rows that are action shortcuts, deferred feature gaps, or platform-specific
divergences.

## Status Legend

- `Pass`: key has iOS UI/action + persisted value + runtime consumer where applicable.
- `Adapted Pass`: parity delivered with explicit iOS platform adaptation.
- `Partial`: iOS has some behavior, but the source-backed Android contract is not complete.
- `Tracked Gap`: not implemented on iOS and tracked by a follow-up issue.
- `Documented Divergence`: intentionally not implemented on iOS; disposition documented.
- `Outside Registry`: Android action row is handled outside `AppPreferenceRegistry`.

## Summary

- Android actionable rows inventoried: 41/41.
- iOS registry-backed rows: 35.
- Registry-backed `Pass`: 21.
- Registry-backed `Adapted Pass`: 11.
- Registry-backed `Partial`: 1 (`locale_pref`, tracked by #164).
- Registry-backed `Documented Divergence`: 2 (`volume_keys_scroll`, `request_sdcard_permission_pref`).
- Non-registry tracked gap: 1 (`notes_content_type`, tracked by #163).
- Non-registry documented divergence: 1 (`eink_mode`).
- Android action shortcuts outside registry: 4 (`global_text_display_settings`,
  `sync_settings_shortcut`, `ai_settings_shortcut`, `reading_progress_settings_shortcut`).
  Three are implemented as native iOS navigation/actions; `ai_settings_shortcut`
  remains deferred until iOS has an AI settings workflow.

## Key-by-Key Matrix

| Key | iOS Evidence | Status | Notes |
|---|---|---|---|
| `strongs_greek_dictionary` | `AppPreferenceRegistry`; `SettingsView` dictionary section; `BibleReaderController` dictionary selection | Pass | Empty selected set retains Android all-enabled semantics. |
| `strongs_hebrew_dictionary` | `AppPreferenceRegistry`; `SettingsView` dictionary section; `BibleReaderController` dictionary selection | Pass | Same pattern as Greek dictionary selection. |
| `robinson_greek_morphology` | `AppPreferenceRegistry`; `SettingsView` dictionary section; `BibleReaderController` morphology lookup | Pass | Stale selections are sanitized against installed modules. |
| `disabled_word_lookup_dictionaries` | `AppPreferenceRegistry`; `SettingsView` inverse dictionary selector; `BibleReaderController` lookup path | Pass | Stored set is disabled modules, matching Android inverse preference. |
| `navigate_to_verse_pref` | `AppPreferenceRegistry`; `SettingsView`; reader/book chooser navigation | Pass | Verse-step chooser flow is wired. |
| `open_links_in_special_window_pref` | `AppPreferenceRegistry`; `SettingsView`; `BibleWindowPane` link handling | Pass | Switches current-window versus links-window behavior. |
| `screen_keep_on_pref` | `AppPreferenceRegistry`; `SettingsView.applyScreenKeepOn`; `BibleReaderView` idle timer state | Pass | Uses `UIApplication.isIdleTimerDisabled`. |
| `double_tap_to_fullscreen` | `AppPreferenceRegistry`; `SettingsView`; `BibleReaderController` double-tap gate | Pass | Preference gates fullscreen gesture handling. |
| `auto_fullscreen_pref` | `AppPreferenceRegistry`; `SettingsView`; `BibleReaderView` auto-fullscreen logic | Pass | Native scroll threshold implementation. |
| `toolbar_button_actions` | `AppPreferenceRegistry`; `SettingsView` picker; `BibleReaderView` toolbar behavior | Adapted Pass | Android menu/activity concept adapted to iOS sheet/module picker. |
| `disable_two_step_bookmarking` | `AppPreferenceRegistry`; `SettingsView`; `BibleWindowPane` bookmark flow | Pass | One-step and two-step bookmark flows implemented. |
| `bible_view_swipe_mode` | `AppPreferenceRegistry`; `SettingsView` picker; `BibleReaderView`/`WebViewCoordinator` gestures | Adapted Pass | Implemented with native iOS swipe recognizers. |
| `volume_keys_scroll` | `AppPreferenceRegistry`; `SettingsView` persistence plus iOS note; `dispositions.md` | Documented Divergence | iOS cannot intercept hardware volume buttons for arbitrary app scrolling. |
| `night_mode_pref3` | `AppPreferenceRegistry`; `SettingsView`; `NightModeSettingsResolver`; app color-scheme state | Adapted Pass | Android automatic sensor mode is excluded by platform constraint. |
| `global_text_display_settings` | `SettingsStore.globalTextDisplaySettingsKey`; `SettingsView.lookAndFeelSection`; `TextDisplaySettingsView`/`ColorSettingsView` | Outside Registry | Android action row is adapted as iOS Look & feel navigation, not a registry preference. |
| `locale_pref` | `AppPreferenceRegistry`; `SettingsView.localeOptions`; `AppleLanguages` override | Partial | Persistence works, but Android locale arrays are not fully represented; tracked by #164. |
| `disable_click_to_edit` | `AppPreferenceRegistry`; `SettingsView`; iOS Vue `appSettings.disableClickToEdit` | Pass | Emitted into iOS reader payload. |
| `notes_content_type` | No iOS registry key; no iOS Vue `appSettings.notesContentType`; Android source emits and consumes it | Tracked Gap | Real note-editor parity gap tracked by #163. |
| `font_size_multiplier` | `AppPreferenceRegistry`; `SettingsView` stepper; iOS Vue `fontSizeMultiplier` payload | Pass | 10-500 clamp and percent-to-float conversion implemented. |
| `full_screen_hide_buttons_pref` | `AppPreferenceRegistry`; `SettingsView`; `BibleReaderView` fullscreen controls | Pass | Fullscreen button-bar visibility follows preference. |
| `hide_window_buttons` | `AppPreferenceRegistry`; `SettingsView`; `BibleWindowPane` window control visibility | Pass | In-window button visibility follows preference. |
| `hide_bible_reference_overlay` | `AppPreferenceRegistry`; `SettingsView`; `BibleReaderView` overlay gate | Pass | Fullscreen reference overlay follows preference. |
| `show_active_window_indicator` | `AppPreferenceRegistry`; `SettingsView`; `BibleReaderController.emitActiveState` and config payload | Pass | Propagated through config and `set_active`. |
| `disable_bible_bookmark_modal_buttons` | `AppPreferenceRegistry`; `SettingsView` inverse selector; iOS Vue modal button payload | Pass | Android action IDs are persisted as disabled set. |
| `disable_gen_bookmark_modal_buttons` | `AppPreferenceRegistry`; `SettingsView` inverse selector; iOS Vue modal button payload | Pass | Android action IDs are persisted as disabled set. |
| `monochrome_mode` | `AppPreferenceRegistry`; `SettingsView`; iOS Vue `monochromeMode` payload | Adapted Pass | iOS default is `false`; Android Onyx-device default does not apply. |
| `eink_mode` | No iOS registry/UI/payload; Android Vue uses it for e-ink helper lines/page buttons | Documented Divergence | iOS has no e-ink-specific reader controls; see `dispositions.md`. |
| `disable_animations` | `AppPreferenceRegistry`; `SettingsView`; iOS Vue `disableAnimations` payload | Adapted Pass | iOS default is `false`; Android Onyx-device default does not apply. |
| `discrete_help` | `AppPreferenceRegistry` action; `SettingsView` help sheet | Adapted Pass | Android dialog is adapted to native iOS sheet. |
| `discrete_mode` | `AppPreferenceRegistry`; `SettingsView`; `AndBibleApp` alternate icon behavior | Adapted Pass | Android launcher identity behavior adapted to iOS alternate icon API. |
| `show_calculator` | `AppPreferenceRegistry`; `SettingsView`; `AndBibleApp` startup calculator gate | Pass | Startup calculator gate follows persisted preference. |
| `calculator_pin` | `AppPreferenceRegistry`; `SettingsView` numeric field; `CalculatorView` unlock | Pass | Numeric PIN entry and unlock behavior are wired. |
| `sync_settings_shortcut` | `SettingsView` Features section exposes `settingsSyncLink` to `SyncSettingsView`; `AndBibleIconCatalog` maps Android icon | Outside Registry | Implemented as a native iOS shortcut, not a durable preference. |
| `ai_settings_shortcut` | No direct iOS Application preferences shortcut | Outside Registry | Deferred to AI parity issues (#5, #74, #89-#92) because iOS has no AI settings workflow to open. |
| `reading_progress_settings_shortcut` | `SettingsView` Features section exposes `settingsReadingProgressLink` to `ReadingProgressSettingsView`; `AndBibleIconCatalog` maps Android icon | Outside Registry | Implemented as a native iOS shortcut, not a durable preference. |
| `experimental_features` | `AppPreferenceRegistry`; `SettingsView` multi-select; iOS Vue `enabledExperimentalFeatures` payload | Pass | Android feature IDs are sanitized and emitted. |
| `enable_bluetooth_pref` | `AppPreferenceRegistry`; `SettingsView`; `SpeakService` remote command handling | Adapted Pass | Android media-button behavior adapted to iOS remote command center. |
| `request_sdcard_permission_pref` | `AppPreferenceRegistry`; not surfaced; `dispositions.md` | Documented Divergence | iOS has no SD-card permission model equivalent. |
| `show_errorbox` | `AppPreferenceRegistry`; debug-only `SettingsView`; iOS Vue `errorBox` payload | Adapted Pass | Android beta-only visibility adapted to iOS debug builds. |
| `open_links` | `AppPreferenceRegistry` action; `SettingsView.openBibleLinkSystemSettings` | Adapted Pass | iOS opens app settings as closest supported equivalent. |
| `crash_app` | `AppPreferenceRegistry` action; debug-only `SettingsView.triggerDebugCrash` | Adapted Pass | Debug-only destructive action with delayed crash and single-shot guard. |

## Open Gaps Identified By This Matrix

- #163: implement `notes_content_type` only after the iOS note editor supports the
  same HTML/Markdown default behavior Android exposes.
- #164: reconcile `locale_pref` option arrays with Android source and actual iOS
  localization resources.
- AI settings shortcut remains intentionally absent until the iOS AI settings workflow
  exists. The shortcut is tracked with the AI parity issues (#5, #74, #89-#92), not
  as a standalone dead Application preferences row.
- `eink_mode` is not an implementation gap today. It is an Android-only e-ink
  behavior and is intentionally documented as a divergence.

## Application Preferences Workflow Parity

- Settings presentation: Application preferences are opened as an integrated reader
  navigation destination, not as a modal sheet.
- Search: native SwiftUI search filters visible Application preferences sections by
  normalized all-term matching across row identifiers, titles, summaries, details,
  and keywords.
- Reset: native reset action restores registry-backed Application preferences through
  `SettingsStore.resetApplicationPreferences()` and
  `AppPreferenceRegistry.applicationPreferencesResetKeys`; action rows and global
  text-display settings are outside that reset scope.
- Feature shortcuts: Sync and Reading Progress are visible in the Android-aligned
  Features section with Android-sourced icon mappings. AI is documented as deferred
  because iOS has no AI settings workflow yet.
- Admin-flow placement: Downloads, repositories, import/export, labels, and about
  remain reader drawer/overflow/admin workflows rather than Application preferences
  rows, matching Android's separation of Application preferences from broader app
  administration.

Regression hardening note: Strong's "Find all occurrences" retains module-backed
simulator coverage to prevent recurrence of the `H02022` no-results failure.
