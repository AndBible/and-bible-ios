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
