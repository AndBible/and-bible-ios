# Android Sync Contract (Current iOS Surface)

This document captures the current Android-aligned sync contract implemented in
the iOS repo.

Primary code references:

- backend selection and credential persistence:
  `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncSettingsStore.swift`
- category definitions and bootstrap/progress metadata:
  `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncStateStore.swift`
- end-to-end orchestration:
  `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncSynchronizationService.swift`
- user-facing settings flow:
  `Sources/BibleUI/Sources/BibleUI/Settings/SyncSettingsView.swift`

## Backend Contract

### Android-aligned remote backends

The iOS remote sync layer currently preserves Android-style backend values under
the `sync_adapter` setting:

| Backend | Persisted value | Notes |
|---|---|---|
| NextCloud / WebDAV | `NEXT_CLOUD` | Uses Android-compatible persisted keys for server URL, username, folder path, and password storage semantics. |
| Google Drive | `GOOGLE_DRIVE` | Uses Google OAuth plus Drive `appDataFolder`, matching Android's high-level model. |

### iOS-only backend extension

| Backend | Persisted value | Notes |
|---|---|---|
| iCloud / CloudKit | `ICLOUD` | Existing iOS-native backend kept alongside the Android-aligned remote backends. This is an iOS extension, not part of Android parity. |

## Category Contract

The Android-style remote sync implementation preserves three independent
category streams on iOS:

| Category | Persisted value | Scope |
|---|---|---|
| Bookmarks | `bookmarks` | bookmarks, labels, note-bearing bookmarks, StudyPad data |
| Workspaces | `workspaces` | workspaces, windows, page managers, workspace history |
| Reading plans | `readingplans` | reading-plan definitions and completion state |

These categories are tracked independently for:

- remote folder naming
- bootstrap state
- patch progress
- initial-backup restore/upload
- patch replay/upload

The current Android app also defines `mydocuments`, `ai_settings`, and
`progress` sync categories. Those are Android contract surface, but they are not
implemented in the current iOS sync surface yet.

## Bootstrap Contract

For each category, iOS mirrors Android's top-level remote bootstrap decision
points:

1. inspect remote state
2. decide whether the category is ready, adoptable, or missing remotely
3. surface explicit user choice when a same-named remote folder exists
4. continue only after the user chooses adopt vs create

Possible synchronization outcomes:

- ready to synchronize immediately
- requires remote adoption
- requires remote creation

## Initial Backup Contract

### Remote adoption

When adopting an existing Android-style remote folder, iOS expects the staged
remote baseline archive:

- `initial.sqlite3.gz`

The adopted initial backup is restored into local SwiftData plus fidelity
stores before normal patch replay continues.

### Remote creation

When creating a fresh remote folder, iOS exports and uploads a local Android-
shaped:

- `initial.sqlite3.gz`

This establishes the same patch-zero baseline Android expects before steady-
state patch synchronization begins.

## Ready-State Synchronization Contract

For a category with ready bootstrap state, iOS performs the Android-aligned flow:

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

## Settings UI Contract

The Sync settings screen currently provides:

- backend picker
- iCloud controls
- NextCloud/WebDAV credential editing and connection test
- Google Drive sign-in/sign-out/reset flow
- per-supported-category enable/disable controls
- adopt/create confirmation flow for discovered remote folders

The settings screen is the user-facing branch point for Android-style remote
bootstrap decisions on iOS.

## Out of Scope

This contract does not describe:

- local-only CloudKit implementation details
- release engineering steps for provisioning Google OAuth values
- local task tracking outside repo history

For Google Drive operational setup, use
[../../howto/google-drive-oauth-setup.md](../../howto/google-drive-oauth-setup.md).
