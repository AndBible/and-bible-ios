# iOS Sync Parity Dispositions

This file records explicit iOS sync dispositions where behavior is intentionally
extended or constrained relative to Android.

## 1. iCloud remains a first-class iOS backend

- Status: intentional iOS extension
- Scope: backend picker and sync settings surface

Disposition:

- iOS keeps `ICLOUD` as a first-class backend alongside the Android-aligned
  remote backends.
- This does not replace or redefine the Android parity contract for
  `NEXT_CLOUD` and `GOOGLE_DRIVE`.

Reason:

- CloudKit is already a shipped iOS-native sync path and must coexist with the
  Android-style remote sync implementation during parity rollout.

## 2. Google Drive is code-ready but operationally parked

- Status: intentional operational constraint
- Scope: Google Drive backend

Disposition:

- The repo contains the Google Drive transport, auth service, settings flow,
  and test coverage.
- End-user Google Drive sync is still parked until a real iOS OAuth client is
  provisioned for the app bundle.

Reason:

- iOS requires build-time bundle OAuth configuration and callback URL scheme
  wiring before Google Sign-In can complete successfully.
- This is a release/developer setup dependency, not a user workflow.

Reference:

- [../../howto/google-drive-oauth-setup.md](../../howto/google-drive-oauth-setup.md)

## 3. WebDAV persisted key names remain Android-compatible

- Status: intentional compatibility preservation
- Scope: NextCloud / WebDAV settings persistence

Disposition:

- iOS preserves Android-compatible raw preference keys such as
  `gdrive_server_url`, `gdrive_username`, `gdrive_folder_path`, and
  `gdrive_password` even though they now back NextCloud/WebDAV configuration on
  iOS.

Reason:

- The awkward names are part of the cross-platform persistence contract and
  should not be "cleaned up" casually if the goal is Android compatibility.

## 4. Adopt-versus-create stays explicit

- Status: intentional UX preservation
- Scope: same-named remote folder handling

Disposition:

- iOS does not silently adopt or overwrite a discovered remote folder.
- The user must explicitly choose whether to restore from the remote baseline
  or replace the remote folder with local state.

Reason:

- This matches Android's top-level synchronization branch point and avoids
  accidental destructive behavior during remote bootstrap.

## 5. Android-only categories are split into distinct deferred parity targets

- Status: documented deferred parity targets
- Scope: remote sync categories

Disposition:

- iOS currently implements Android-aligned sync for `bookmarks`, `workspaces`,
  and `readingplans`.
- Android currently also exposes `mydocuments`, `ai_settings`, and `progress`.
  Those categories are not implemented on iOS yet and must not be treated as one
  broad implementation task.
- `mydocuments` is tracked separately in #72. It depends on the iOS My
  Documents model/storage contract in #80 and the bridge disposition from #51
  before remote sync storage is added.
- `ai_settings` is tracked separately in #74. It is deferred behind #5 so iOS
  does not invent an AI settings sync schema before the shared AI backend and
  settings contract exist. The #53 AI bridge disposition and #89 bridge shell
  contract keep bridge-facing AI settings ownership aligned with that shared
  backend direction.
- `progress` is tracked separately in #73. It is deferred until the
  reader/memorization/progress product surface is explicit, and it should not be
  folded into `readingplans` without an explicit compatibility decision. The
  #52 reading-progress bridge disposition keeps this blocked on the native
  reading-progress model/storage and settings contract in #85. The #50
  memorization bridge state slice now has local iOS storage, but remote
  Android `progress` sync compatibility still belongs to #73.

Reason:

- The current iOS product surface does not yet expose the matching Android
  document, AI-settings, or reading-progress sync flows.
- Android exposes these as separate sync categories, so each needs its own
  product ownership, Android schema reference, iOS data mapping, settings UI
  decision, and regression plan.

Reference:

- #49 records the decision to split the categories into distinct parity targets.
