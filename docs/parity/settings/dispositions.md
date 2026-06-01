# iOS Settings Parity Dispositions

This file records explicit iOS disposition decisions for Android parity tickets where behavior is implemented differently due to platform constraints.

## SETPAR-209 — `volume_keys_scroll`

- Android contract:
  - Key: `volume_keys_scroll`
  - Source: `and-bible/app/src/main/res/xml/settings.xml:101-106`
  - Runtime consumer: `MainBibleActivity.kt` intercepts `KEYCODE_VOLUME_UP/DOWN` and emits Bible scroll events.
- iOS platform constraint:
  - Public iOS APIs do not provide app-level interception of hardware volume-button presses for arbitrary in-app actions.
- iOS disposition (implemented):
  - Keep the setting in iOS settings UI and persistence for cross-platform parity and synced preference continuity.
  - Show an iOS-specific note in UI clarifying the platform limitation.
  - No native volume-button scroll action is bound on iOS.
- iOS references:
  - UI + persistence: `Sources/BibleUI/Sources/BibleUI/Settings/SettingsView.swift`
  - Key registry/default: `Sources/BibleCore/Sources/BibleCore/Database/AppPreferenceRegistry.swift`

## SETPAR-501 — `experimental_features`

- Android contract:
  - Key: `experimental_features`
  - Source: `and-bible/app/src/main/res/xml/settings.xml:218-225`
  - Values: `bookmark_edit_actions`, `add_paragraph_break` (`arrays.xml:224-231`)
- iOS disposition (implemented):
  - Added matching multi-select UI with Android feature IDs.
  - Added sanitization of stale/unknown persisted values.
  - Persisted selected IDs are emitted via `appSettings.enabledExperimentalFeatures`.
- iOS references:
  - UI + persistence + sanitization: `Sources/BibleUI/Sources/BibleUI/Settings/SettingsView.swift`
  - Runtime emission: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`

## SETPAR-502 — `enable_bluetooth_pref`

- Android contract:
  - Key: `enable_bluetooth_pref`
  - Source: `and-bible/app/src/main/res/xml/settings.xml:226-230`
  - Runtime consumer: `MediaButtonHandler.kt` media-session controls.
- iOS adaptation (implemented):
  - Mapped to iOS `MPRemoteCommandCenter` handling in `SpeakService`.
  - When disabled, iOS remote play/pause/stop/next/previous handlers are unregistered and disabled.
  - When enabled, handlers are registered and control speech playback/navigation.
- iOS references:
  - UI + persistence: `Sources/BibleUI/Sources/BibleUI/Settings/SettingsView.swift`
  - Runtime consumer: `Sources/BibleCore/Sources/BibleCore/Services/SpeakService.swift`

## SETPAR-503 — `request_sdcard_permission_pref`

- Android contract:
  - Key: `request_sdcard_permission_pref`
  - Source: `and-bible/app/src/main/res/xml/settings.xml:231-234`
  - Runtime behavior: Android storage permission pathway.
- iOS disposition (Android-only divergence):
  - iOS has no SD-card permission model equivalent to Android storage permissions.
  - This preference is intentionally not surfaced in iOS settings UI.
  - No iOS runtime consumer is added.

## SETPAR-154 — `eink_mode`

- Android contract:
  - Key: `eink_mode`
  - Source: `and-bible/app/src/main/res/xml/settings.xml:201-206`
  - Runtime preference reader: `and-bible/app/src/main/java/net/bible/service/common/CommonUtils.kt:453`
  - Reader payload: `and-bible/app/src/main/java/net/bible/android/view/activity/page/BibleView.kt:1531`
  - Vue consumers: `and-bible/app/bibleview-js/src/components/BibleView.vue:74-83`
- Android behavior:
  - Enables Android e-ink-specific reader affordances, specifically scroll helper lines and page scroll buttons when the corresponding text-display settings are enabled.
  - This is distinct from `monochrome_mode` and `disable_animations`, which are already represented on iOS.
- iOS disposition (Android-only divergence):
  - Do not add `eink_mode` to `AppPreferenceRegistry`, Settings UI, or the iOS reader payload unless iOS gains equivalent e-ink-specific behavior.
  - Adding a no-op switch would create dead UI and would not improve behavioral parity.
  - `monochrome_mode` and `disable_animations` remain the supported cross-platform rendering preferences on iOS.
- Tracking:
  - #154 records the source-backed audit.
  - #156 should not be implemented as written because it bundles this Android-only e-ink setting with the separate `notes_content_type` gap.
  - #163 tracks the real `notes_content_type` follow-up independently.

## SETPAR-155 — Application preferences presentation and workflows

- Android contract:
  - `SettingsActivity` hosts Application preferences inside app chrome, adds
    preference search, supports reset for the screen's preferences, and exposes
    feature shortcuts for Sync, AI settings, and Reading Progress.
  - Android keeps broader administration workflows, including downloads and backup,
    outside Application preferences.
- iOS adaptation (implemented):
  - Keep the screen native SwiftUI, but open it as an integrated reader navigation
    destination instead of a modal sheet.
  - Use the shared Android icon catalog for Application preference rows and feature
    shortcuts rather than inventing a separate iOS-only icon vocabulary.
  - Add native search over Application preference row identifiers, titles,
    summaries, details, and keywords.
  - Add a reset action backed by `AppPreferenceRegistry.applicationPreferencesResetKeys`
    and `SettingsStore.resetApplicationPreferences()`. Action rows and global
    text-display settings are deliberately excluded from the reset scope.
  - Add the Android-aligned Features shortcuts for Sync and Reading Progress.
  - Keep Downloads, repositories, import/export, labels, and about in reader
    drawer/overflow/admin flows rather than folding them into Application preferences.
- iOS deviation:
  - Do not add `ai_settings_shortcut` until iOS has an AI settings workflow. Adding a
    dead row would make the screen look more Android-like while reducing functional
    parity.
- iOS references:
  - Presentation and search UI: `Sources/BibleUI/Sources/BibleUI/Settings/SettingsView.swift`
  - Search matcher: `Sources/BibleUI/Sources/BibleUI/Settings/AndBibleSettingsSearch.swift`
  - Reset contract: `Sources/BibleCore/Sources/BibleCore/Database/AppPreferenceRegistry.swift`
  - Reset implementation: `Sources/BibleCore/Sources/BibleCore/Database/SettingsStore.swift`
  - Reader navigation destination: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift`
  - Icon mapping: `Sources/BibleUI/Sources/BibleUI/Shared/AndBibleIconCatalog.swift`

## SETPAR-505 — `open_links`

- Android contract:
  - Key: `open_links`
  - Source: `and-bible/app/src/main/res/xml/settings.xml:241-246`
  - Runtime behavior: opens Android App "Open by default" settings (`SettingsActivity.kt:334-349`).
- iOS adaptation (implemented):
  - Added Advanced settings action row using `open_bible_links_title` / `open_bible_links_summary`.
  - Action opens iOS app system settings via `UIApplication.openSettingsURLString`.
  - iOS does not expose a public deep link to per-app "Open by default links" equivalent; app settings is the supported fallback.
- iOS references:
  - UI + action: `Sources/BibleUI/Sources/BibleUI/Settings/SettingsView.swift`

## SETPAR-506 — `crash_app`

- Android contract:
  - Key: `crash_app`
  - Source: `and-bible/app/src/main/res/xml/settings.xml:247-251`
  - Runtime behavior: debug/beta-only action that crashes app after 10 seconds (`SettingsActivity.kt:321-333`).
- iOS adaptation (implemented):
  - Added debug-only destructive action row in Advanced settings.
  - On tap, schedules app crash after 10 seconds and disables repeat taps while pending.
  - Action is excluded from non-debug builds.
- iOS references:
  - UI + action: `Sources/BibleUI/Sources/BibleUI/Settings/SettingsView.swift`
