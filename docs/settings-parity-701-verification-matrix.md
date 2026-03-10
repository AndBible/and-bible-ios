# SETPAR-701 Verification Matrix (Android Application Preferences -> iOS)

Date: 2026-03-10

## Scope and Method

- Contract baseline: `docs/settings-parity-contract.md`.
- Key inventory: `Sources/BibleCore/Sources/BibleCore/Database/AppPreferenceRegistry.swift` (`AppPreferenceKey.allCases` = 35).
- Verification method: direct code inspection of iOS UI persistence points and runtime consumers.

## Status Legend

- `Pass`: key has iOS UI/action + persisted value + runtime consumer.
- `Adapted Pass`: parity delivered with explicit iOS platform adaptation.
- `Partial`: key exists, but parity is incomplete (for example runtime-only without iOS UI, or behavior drift).
- `Documented Divergence`: intentionally not implemented on iOS; disposition documented.

## Summary

- `Pass`: 24/35
- `Adapted Pass`: 9/35
- `Partial`: 0/35
- `Documented Divergence`: 2/35

## Key-by-Key Matrix

| Key | iOS Evidence (UI/persistence) | iOS Evidence (runtime consumer) | Status | Notes |
|---|---|---|---|---|
| `strongs_greek_dictionary` | `SettingsView.swift:161-187,745,802,1152` | `BibleReaderController.swift:2658-2670` | Pass | Selected-set semantics match Android (empty = runtime default/all). |
| `strongs_hebrew_dictionary` | `SettingsView.swift:190-215,746,806,1161` | `BibleReaderController.swift:2658-2670` | Pass | Same pattern as Greek selection. |
| `robinson_greek_morphology` | `SettingsView.swift:218-243,747,810,1170` | `BibleReaderController.swift:2701-2720` | Pass | Multi-select + stale-value fallback behavior present. |
| `disabled_word_lookup_dictionaries` | `SettingsView.swift:246-271,748,814,1178` | `BibleReaderController.swift:2746-2764,2773-2795` | Pass | Inverse selection is consumed by lookup path. |
| `navigate_to_verse_pref` | `SettingsView.swift:276-295,761` | `BibleReaderView.swift:75,241,334-340`; `BookChooserView.swift:46-60` | Pass | Verse-step chooser flow is wired. |
| `open_links_in_special_window_pref` | `SettingsView.swift:460-477,750` | `BibleWindowPane.swift:341-347` | Pass | Switches between current-window navigation and links-window behavior. |
| `screen_keep_on_pref` | `SettingsView.swift:297-313,761,1121-1124` | `BibleReaderView.swift:250` | Pass | Uses `UIApplication.isIdleTimerDisabled`. |
| `double_tap_to_fullscreen` | `SettingsView.swift:315-333,763` | `BibleReaderController.swift:3231-3234` | Pass | Double-tap bridge event is preference-gated. |
| `auto_fullscreen_pref` | `SettingsView.swift:335-350,764` | `BibleReaderView.swift:1627-1654` | Pass | Direction-aware threshold logic implemented. |
| `toolbar_button_actions` | `SettingsView.swift:352-377,767,1211-1217` | `BibleReaderView.swift:1459-1497,1499-1563` | Adapted Pass | Android chooser/activity concept adapted to iOS sheet/module picker. |
| `disable_two_step_bookmarking` | `SettingsView.swift:379-397,765` | `BibleWindowPane.swift:395-447` | Pass | One-step and two-step bookmark flows implemented. |
| `bible_view_swipe_mode` | `SettingsView.swift:399-424,769,1202-1208` | `BibleReaderView.swift:1656-1676`; `WebViewCoordinator.swift:82-109,122-137` | Adapted Pass | Native iOS swipe recognizers/scroll delegate bridge into chapter/page/none actions. |
| `volume_keys_scroll` | `SettingsView.swift:426-451,770` | No runtime consumer; disposition in `settings-parity-ios-dispositions.md:5-20` | Documented Divergence | Kept for parity/sync continuity; iOS cannot intercept hardware volume keys for app actions. |
| `night_mode_pref3` | `SettingsView.swift:832-857,773,1192-1200` | `BibleReaderView.swift:65,234-240,1612-1618`; `ContentView.swift:20,46-63`; `NightModeSettings.swift:19-60` | Adapted Pass | `automatic` mode excluded by platform constraint (`autoModeAvailable = false`). |
| `locale_pref` | `SettingsView.swift:1024-1050,782-797,1241-1281` | Applied via `AppleLanguages` override in `SettingsView.swift:1043-1049` | Pass | Android locale-value mapping and legacy code normalization are implemented. |
| `monochrome_mode` | `SettingsView.swift:860-877,751,867` | `BibleReaderController.swift:4069,4102` | Pass | Emitted into Vue appSettings payload. |
| `disable_animations` | `SettingsView.swift:878-895,752,885` | `BibleReaderController.swift:4070,4102` | Pass | Emitted into Vue appSettings payload. |
| `disable_click_to_edit` | `SettingsView.swift:896-914,753,906` | `BibleReaderController.swift:4071,4102` | Pass | Emitted into Vue appSettings payload. |
| `font_size_multiplier` | `SettingsView.swift:917-939,757,923` | `BibleReaderController.swift:4072-4073,4102` | Pass | 10-500 clamp and runtime min-guard present. |
| `full_screen_hide_buttons_pref` | `SettingsView.swift:940-960,758,950` | `BibleReaderView.swift:139-141,246,1609` | Pass | Fullscreen tab-bar visibility follows preference. |
| `hide_window_buttons` | `SettingsView.swift:961-980,759,971` | `BibleReaderView.swift:699`; `BibleWindowPane.swift:79-83` | Pass | Window hamburger control visibility follows preference. |
| `hide_bible_reference_overlay` | `SettingsView.swift:982-1002,760,992` | `BibleReaderView.swift:143-147,199-210,1611` | Pass | Fullscreen Bible reference capsule overlay is preference-gated. |
| `show_active_window_indicator` | `SettingsView.swift:1003-1023,754,1013` | `BibleReaderController.swift:4030-4033,4064-4065,4102` | Pass | Indicator propagated via both `set_active` event and config payload. |
| `disable_bible_bookmark_modal_buttons` | `SettingsView.swift:1071-1093,780,852,1292-1304` | `BibleReaderController.swift:4074,4102` | Pass | Inverse multi-select editor now matches Android action IDs and persists disabled button set. |
| `disable_gen_bookmark_modal_buttons` | `SettingsView.swift:1096-1118,781,857,1299-1304` | `BibleReaderController.swift:4075,4102` | Pass | Inverse multi-select editor now matches Android action IDs and persists disabled button set. |
| `discrete_help` | `SettingsView.swift:483-499,688-709` | Action-only key shape validated by `AndBibleTests.swift:25-45` | Adapted Pass | Implemented as help action + sheet content. |
| `discrete_mode` | `SettingsView.swift:500-503` | `AndBibleApp.swift:29,163-165,176-190` | Adapted Pass | iOS icon switching implemented via alternate icon API. |
| `show_calculator` | `SettingsView.swift:505-508` | `AndBibleApp.swift:31,143-149` | Pass | Startup calculator gate follows persisted preference. |
| `calculator_pin` | `SettingsView.swift:510-525` | `CalculatorView.swift:31-32,133-146` | Pass | Numeric PIN entry and unlock behavior are wired. |
| `experimental_features` | `SettingsView.swift:551-571,771,818,1182-1189` | `BibleReaderController.swift:4076,4102` | Pass | Multi-select IDs are sanitized and emitted in appSettings. |
| `enable_bluetooth_pref` | `SettingsView.swift:529-549,756,540` | `SpeakService.swift:85,107-113` | Adapted Pass | Android media-button behavior adapted to iOS `MPRemoteCommandCenter`. |
| `request_sdcard_permission_pref` | Not surfaced in iOS settings UI | Disposition documented in `settings-parity-ios-dispositions.md:49-58` | Documented Divergence | No iOS SD-card permission model equivalent. |
| `show_errorbox` | `SettingsView.swift:603-624,789` | `BibleReaderController.swift:4068,4102` | Adapted Pass | Visibility is now debug-only (`#if DEBUG`) to match Android beta-only visibility contract. |
| `open_links` | `SettingsView.swift:595-617,1127-1131` | iOS adaptation in `settings-parity-ios-dispositions.md:60-72` | Adapted Pass | Opens iOS app settings as closest supported equivalent. |
| `crash_app` | `SettingsView.swift:620-649,1134-1140` | iOS adaptation in `settings-parity-ios-dispositions.md:73-84` | Adapted Pass | Debug-only destructive action with 10-second delay and single-shot guard. |

## Open Gaps Identified by This Matrix

No functional gaps remain for the 35-key Android application-preferences contract. Remaining entries are documented platform divergences (`volume_keys_scroll`, `request_sdcard_permission_pref`).
