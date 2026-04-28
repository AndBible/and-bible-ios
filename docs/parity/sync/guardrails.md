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
   Current iOS-supported Android-aligned categories are `bookmarks`, `workspaces`, and
   `readingplans`. Android also exposes `mydocuments`, `ai_settings`, and `progress`, which are
   not implemented on iOS yet; adding them is new parity surface, not a local cleanup.

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

6. Treat the Google Drive parked branch as operationally blocked, not removed.

   Google Drive remains part of the parity contract even though live iOS OAuth
   provisioning is intentionally parked. Do not delete or redefine that branch
   because local/CI builds show “not configured”.

7. Keep iCloud scoped as an iOS extension, not a redefinition of Android remote
   sync.

   iCloud can coexist as an iOS-native backend, but it must not change the
   Android-compatible semantics for NextCloud/WebDAV or Google Drive.

8. Sync UI changes must preserve stored-state hydration and reopen persistence.

   `SyncSettingsView` is not just a form shell. It is where backend/category
   mutations, validation status, and reopen persistence are surfaced to the
   user. UI-only refactors still need to respect those contracts.

9. New sync surface area must update the docs in the same slice.

   When adding or changing sync contract behavior, update:

   - `docs/parity/sync/contract.md`
   - `docs/parity/sync/dispositions.md` when behavior is iOS-specific
   - `docs/parity/sync/verification-matrix.md` if status changes
   - `docs/parity/sync/regression-report.md` when validation scope changes
   - `docs/howto/google-drive-oauth-setup.md` if Google Drive operational status changes

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
- expand iOS coverage to Android's remaining `mydocuments`, `ai_settings`, and `progress`
  sync categories if those surfaces become product scope
- add a focused XCUITest for the adopt-versus-create confirmation branch
