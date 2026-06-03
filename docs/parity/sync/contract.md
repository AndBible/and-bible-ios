# Android Sync Contract and iOS Target

Source audit date: 2026-06-02

This document captures the Android sync settings contract and the iOS target
state. It separates current iOS implementation details from deliberate iOS
platform deviations so follow-up implementation work does not preserve stale
assumptions.

Primary Android references:

- `../and-bible/app/src/main/res/xml/sync_settings.xml`
- `../and-bible/app/src/main/java/net/bible/android/view/activity/settings/SyncSettings.kt`
- `../and-bible/app/src/main/java/net/bible/service/cloudsync/CloudSync.kt`
- `../and-bible/app/src/main/java/net/bible/service/cloudsync/SyncUtilities.kt`
- `../and-bible/app/src/main/res/values/strings.xml`

Primary iOS references:

- backend selection and credential persistence:
  `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncSettingsStore.swift`
- category definitions and bootstrap/progress metadata:
  `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncStateStore.swift`
- end-to-end orchestration:
  `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncSynchronizationService.swift`
- user-facing settings flow:
  `Sources/BibleUI/Sources/BibleUI/Settings/SyncSettingsView.swift`

## Backend Contract

Android currently models sync as remote-cloud-only:

| Android backend | Persisted value | Source-backed behavior |
|---|---|---|
| Google Drive | `GOOGLE_DRIVE` | Enabled outside F-Droid builds; uses Drive `appDataFolder`; hidden NextCloud credential rows when selected. |
| Next Cloud | `NEXT_CLOUD` | Uses server URL, username, password, and folder-path preferences. |

Android falls back to the first enabled adapter when `sync_adapter` is missing.
iOS must not copy that fallback literally because iCloud is the platform-native
default.

The iOS target backend contract is:

| iOS backend | Persisted value | Target state |
|---|---|---|
| iCloud / CloudKit | `ICLOUD` | Default iOS backend. Missing, unknown, removed, or legacy backend values fall back to iCloud. |
| NextCloud / WebDAV | `NEXT_CLOUD` | Explicit cross-platform remote choice. Uses Android-compatible persisted keys for server URL, username, folder path, and password storage semantics. |

The historical `gdrive_*` WebDAV preference keys are compatibility surface even
after Google Drive is removed. Do not rename or delete those keys casually if
that would break existing NextCloud/WebDAV users.

Legacy persisted `sync_adapter=GOOGLE_DRIVE` values are not retained as a
selectable iOS backend. They resolve to `ICLOUD`.

## Android Settings Row Inventory

Android declares the sync settings screen in `sync_settings.xml` and applies
runtime behavior in `SyncSettings.kt`.

### General Rows

| Android key | Android title | Icon | Runtime behavior |
|---|---|---|---|
| `sync_adapter` | Synchronization Backend | `ic_syncdb_24dp` | Disabled while signed in. Summary includes the introduction and `Current: <adapter>`. Google Drive-specific app-files copy is appended only when Google Drive is selected. |
| `cloud_sync_reset` | Sign Out | `baseline_logout_24` | Visible only when cloud sync is enabled and signed in. Confirmation signs out, disables sync categories, clears sync status/configuration, and recreates the settings activity. |
| `cloud_sync_info` | Cloud information | `ic_info_grey_24dp` | Visible only when cloud sync is enabled and signed in. Summary reports total remote storage used. |
| `cloud_sync_server_url` | Server URL | `outline_shield_24` | NextCloud credential row. Hidden for Google Drive and disabled while signed in. Rejects blank/invalid URLs, `/login` URLs, spaces, and non-HTTP(S) schemes. |
| `cloud_sync_username` | User name | `outline_shield_24` | NextCloud credential row. Hidden for Google Drive and disabled while signed in. |
| `cloud_sync_password` | Password | `outline_shield_24` | NextCloud credential row. Hidden for Google Drive and disabled while signed in. |
| `cloud_sync_folder_path` | Sync folder path | `outline_shield_24` | NextCloud credential row. Hidden for Google Drive and disabled while signed in. Summary: parent folder for sync data, empty means root. |

### Category Rows

| Android key | Android title | Summary | Icon | Android runtime visibility |
|---|---|---|---|---|
| `sync_enable_bookmarks` | Bookmarks | Bookmarks, Labels and Study Pads | `ic_bookmark_24dp` | Visible |
| `sync_enable_workspaces` | Workspaces | Workspaces and Windows | `ic_baseline_workspace_24` | Visible |
| `sync_enable_readingplans` | Reading plans | Reading plans and their statuses | `ic_reading_plan_24dp` | Declared but hidden by `SyncSettings.kt` |
| `sync_enable_mydocuments` | My Documents | My Documents and their content | `ic_baseline_description_gray_24` | Visible |
| `sync_enable_ai_settings` | AI Settings | AI prompts and provider configurations | `icon_robot` | Visible |
| `sync_enable_progress` | Reading Progress | Memorized verses and chapter reading records | `ic_baseline_check_circle_24` | Visible |

Android toggle behavior:

- enabling a category starts the sign-in/bootstrap/sync path before the toggle is
  allowed to appear enabled
- if not signed in, Android signs in first
- after sign-in, Android waits for any current sync, starts sync, waits for it,
  posts the after-restore event, dismisses the hourglass, and recreates the
  settings activity
- disabling a category writes `sync_enable_<category>=false` immediately
- enabled categories append `Last updated: <date>` to the summary when a
  category-level `lastSynchronized` timestamp exists

## iOS Settings Target

The iOS settings screen may stay native SwiftUI, but native controls are an
implementation choice, not a parity exemption. The visible information
architecture should match Android where the behavior exists:

- backend row first
- iCloud default, NextCloud/WebDAV explicit, Google Drive removed from iOS
- NextCloud credential rows use Android titles and folder-path summary
- reset/sign-out and cloud-info/status rows should appear only when meaningful
- category rows should use Android ordering, labels, summaries, icons, and
  `sync_enable_*` keys when implemented
- enabling a category should run the Android-style sign-in/bootstrap/sync path
  before presenting the category as effectively enabled
- disabling a category should be immediate

Current iOS additions and gaps:

- iCloud is an intentional iOS platform extension and default backend.
- The NextCloud/WebDAV connection test is an iOS additive workflow. It is
  acceptable only as a documented improvement that does not contradict Android's
  sync behavior.
- iOS exposes the Android-runtime-visible row order: `bookmarks`, `workspaces`,
  `mydocuments`, deferred `ai_settings`, and deferred `progress`.
- iOS keeps Reading Plans sync implemented, but hides its settings toggle to
  match Android runtime behavior.
- #73 owns Android `progress` remote sync parity.
- #74 owns Android `ai_settings` remote sync parity.

## Category Contract

Android's `SyncableDatabaseDefinition` defines six sync categories:

| Category | Android raw name | Android visible toggle | Current iOS state | Follow-up |
|---|---|---|---|---|
| Bookmarks | `BOOKMARKS` / `bookmarks` | Visible | Implemented and visible | Keep aligned |
| Workspaces | `WORKSPACES` / `workspaces` | Visible | Implemented and visible | Keep aligned |
| Reading plans | `READINGPLANS` / `readingplans` | Hidden at runtime | Implemented and hidden from settings | Keep hidden unless Android changes |
| My Documents | `MYDOCUMENTS` / `mydocuments` | Visible | Implemented and visible | Keep aligned |
| AI Settings | `AI_SETTINGS` / `ai_settings` | Visible | Visible as disabled deferred row | #74 |
| Reading Progress | `PROGRESS` / `progress` | Visible | Visible as disabled deferred row | #73 |

These categories are tracked independently for:

- remote folder naming
- bootstrap state
- patch progress
- initial-backup restore/upload
- patch replay/upload
- settings toggle persistence

Reading Progress must not be folded into Reading Plans. Android treats
`readingplans` and `progress` as distinct sync streams.

## Bootstrap Contract

For each implemented category, iOS mirrors Android's top-level remote bootstrap
decision points:

1. inspect remote state
2. decide whether the category is ready, adoptable, or missing remotely
3. surface explicit user choice when a same-named remote folder exists
4. continue only after the user chooses adopt vs create

Possible synchronization outcomes:

- ready to synchronize immediately
- requires remote adoption
- requires remote creation

## Initial Backup Contract

### Remote Adoption

When adopting an existing Android-style remote folder, iOS expects the staged
remote baseline archive:

- `initial.sqlite3.gz`

The adopted initial backup is restored into local SwiftData plus fidelity
stores before normal patch replay continues.

### Remote Creation

When creating a fresh remote folder, iOS exports and uploads a local
Android-shaped:

- `initial.sqlite3.gz`

This establishes the same patch-zero baseline Android expects before
steady-state patch synchronization begins.

## Ready-State Synchronization Contract

For a category with ready bootstrap state, iOS performs the Android-aligned
flow:

1. discover pending remote patches
2. stage and download archives
3. replay remote patches into local state
4. update Android-aligned bootstrap and progress bookkeeping
5. upload one outbound sparse patch when local state changed and the category
   supports export

Current outbound patch coverage exists for:

- bookmarks
- workspaces
- reading plans
- My Documents

## Out of Scope

This contract does not describe:

- local-only CloudKit implementation details beyond iCloud's default/backend
  disposition
- Android Google Drive implementation details beyond their value as source
  context for iOS removal/fallback behavior
- AI Settings sync implementation details owned by #74
- Reading Progress sync implementation details owned by #73
- local task tracking outside repo history
