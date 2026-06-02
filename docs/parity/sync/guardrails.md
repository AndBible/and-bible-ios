# SYNC-703 Guardrails

## Purpose

Prevent high-risk sync regressions by making the non-negotiable compatibility
rules explicit for changes in:

- `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncSettingsStore.swift`
- `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncBootstrapCoordinator.swift`
- `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncSynchronizationService.swift`
- category-specific restore/apply/upload services under
  `Sources/BibleCore/Sources/BibleCore/Services/RemoteSync*`
- `Sources/BibleUI/Sources/BibleUI/Settings/SyncSettingsView.swift`

## Rules

1. Do not rename Android-compatible persisted keys casually.

   Keys such as `sync_adapter`, `gdrive_server_url`, `gdrive_username`,
   `gdrive_folder_path`, `gdrive_password`, and the category-toggle keys are
   part of the cross-platform contract. Renaming them is a sync-data break, not
   a local refactor.

2. Preserve category identifiers and category-to-service wiring.

   The iOS-supported category names and their dispatch mapping must stay stable across:

   - initial-backup restore
   - initial-backup upload
   - patch replay
   - sparse upload
   - settings persistence

   Any category rename or remapping is a compatibility change.
   Current iOS-implemented Android-aligned categories are `bookmarks`,
   `workspaces`, `readingplans`, and `mydocuments`. Android also exposes
   `ai_settings` and `progress`, which are not implemented on iOS yet. Issue #49
   records these as separate deferred parity targets tracked by #74 and #73;
   adding either one is new parity surface, not a local cleanup. Android
   currently hides the Reading Plans toggle at runtime, while iOS currently
   shows it; #158 owns that visible-toggle parity decision. `mydocuments`
   remains governed by the iOS My Documents model/storage contract recorded in
   `../bridge/my-documents-model.md` and the Android-backed sync schema contract
   in `mydocuments-schema.md`.
   `ai_settings` depends on the shared AI backend/settings direction in #5 and
   the bridge shell ownership contract in #89; it must not introduce an iOS-only
   AI settings schema. `progress` depends on the iOS reading-progress
   model/storage and settings contract in `../bridge/reading-progress-model.md`
   and must stay distinct from reading-plan completion unless a later
   compatibility decision explicitly changes that.

3. Treat bootstrap markers and remote-folder ownership semantics as contract
   surface.

   The create/adopt/ready decision tree depends on marker files, folder naming,
   and device-folder ownership rules. Changing those rules casually can cause
   destructive remote overwrite or silent folder mis-adoption.

4. Do not change initial-backup or patch numbering semantics casually.

   Patch-zero recording, staged `initial.sqlite3.gz`, and steady-state sparse
   patch numbering are all parity-sensitive. “Cleanup” changes to numbering or
   suppression behavior can corrupt the remote baseline contract.

5. Keep NextCloud/WebDAV normalization behavior explicit.

   Resolving a human-entered server root into a DAV endpoint is intentional.
   Changing URL normalization, login-page rejection, or authenticated DAV
   request semantics needs coordinated validation, not ad hoc tweaking.

6. Treat Google Drive as a removal target.

   #116 supersedes the prior Google Drive posture. Do not add new Google Drive
   sync UI, auth behavior, tests, or docs. When #116 is implemented, remove the
   selectable backend, auth/session UI, adapter/auth paths, GoogleSignIn
   dependency, Google-focused tests, and OAuth setup docs unless a documented
   non-sync dependency remains. Preserve the historical `gdrive_*` WebDAV keys
   until an explicit migration decision says otherwise.

7. Keep iCloud scoped as the default iOS platform backend.

   iCloud is a legitimate iOS platform extension and the default backend. Do
   not make NextCloud/WebDAV the implicit default merely because #116 removes
   Google Drive. #160 owns the removed-backend and unknown-backend fallback
   contract. iCloud must not change the Android-compatible semantics for
   NextCloud/WebDAV.

8. Sync UI changes must preserve stored-state hydration and reopen persistence.

   `SyncSettingsView` is not just a form shell. It is where backend/category
   mutations, validation status, and reopen persistence are surfaced to the
   user. UI-only refactors still need to respect those contracts.

9. New sync surface area must update the docs in the same slice.

   When adding or changing sync contract behavior, update:

   - `docs/parity/sync/contract.md`
   - `docs/parity/sync/mydocuments-schema.md` when My Documents sync behavior changes
   - `docs/parity/sync/dispositions.md` when behavior is iOS-specific
   - `docs/parity/sync/verification-matrix.md` if status changes
   - `docs/parity/sync/regression-report.md` when validation scope changes
   - `docs/howto/google-drive-oauth-setup.md` if Google Drive removal changes its status

## Validation Expectations

At minimum, sync-adjacent changes should keep the focused shared-scheme subset
described in `regression-report.md` green, especially:

- backend/category settings persistence
- WebDAV normalization and request semantics
- bootstrap ready/adopt/create decisions
- initial-backup restore/upload for iOS-supported categories
- Sync settings backend/category reopen persistence

If a change touches one of the remaining partial areas, raise the bar and add
focused coverage rather than relying on the existing subset alone.

## Current Automation Status

- The repo currently has focused sync regression coverage, but no separate
  machine-readable sync drift checker.
- Current protection is a combination of:
  - focused unit/integration coverage in `AndBibleTests`, including workspace
    sync coverage from `WorkspaceSyncRestoreTests.swift`
  - focused Sync UI coverage in `AndBibleUITests`
  - explicit parity documentation in this directory

## Potential Improvements

- add a machine-readable snapshot of Android-compatible sync keys and category names
- add a machine-readable snapshot of Android's visible sync settings rows,
  including the runtime-hidden Reading Plans row
- expand iOS coverage to Android's remaining `ai_settings` and `progress` sync
  categories only through their separate tracking issues (#74, #73), with
  `ai_settings` gated by #5/#89 and `progress` gated by the local model in
  `../bridge/reading-progress-model.md`
