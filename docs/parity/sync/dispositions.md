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

## 5. Remaining Android-only categories stay split into distinct parity targets

- Status: `mydocuments` implemented; remaining Android-only categories deferred
- Scope: remote sync categories

Disposition:

- iOS currently implements Android-aligned sync for `bookmarks`, `workspaces`,
  `readingplans`, and `mydocuments`.
- Android currently also exposes `ai_settings` and `progress`. Those categories
  are not implemented on iOS yet and must not be treated as one broad
  implementation task.
- `mydocuments` remains documented under #72. The local model, rendering, and
  bridge prerequisites are recorded in `../bridge/my-documents-model.md`.
  #104 records the Android-source-backed sync schema and policy contract in
  `mydocuments-schema.md`; restore (#105), initial upload (#106), patch replay
  (#108), patch upload (#107), and settings/docs exposure (#109) complete the
  runtime sync surface.
- `ai_settings` is tracked separately in #74. It is deferred behind #5 so iOS
  does not invent an AI settings sync schema before the shared AI backend and
  settings contract exist. The #53 AI bridge disposition and #89 bridge shell
  contract keep bridge-facing AI settings ownership aligned with that shared
  backend direction.
- `progress` is tracked separately in #73. It should not be folded into
  `readingplans` without an explicit compatibility decision. The #52
  reading-progress bridge disposition now has a local model/storage/settings
  contract in `../bridge/reading-progress-model.md`. The #50 memorization
  bridge state slice also has local iOS storage, with the #77 model recorded in
  `../bridge/memorization-progress-model.md`. Remote Android `progress` sync
  compatibility, including KJVA persistence, remote adoption, and conflicts,
  still belongs to #73.

Reason:

- The current iOS product surface now exposes the matching Android My Documents
  sync flow, backed by the Android schema and focused regression coverage.
- Android exposes AI settings and reading progress as separate sync categories,
  so each still needs its own product ownership, Android schema reference, iOS
  data mapping, settings UI decision, and regression plan.

Reference:

- #49 records the decision to split the categories into distinct parity targets.
