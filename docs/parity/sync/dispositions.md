# iOS Sync Parity Dispositions

This file records explicit iOS sync dispositions where behavior is intentionally
extended, constrained, or deferred relative to Android.

## 1. iCloud is the default iOS backend

- Status: intentional iOS platform extension
- Scope: backend picker, missing-backend fallback, and sync settings surface

Disposition:

- iOS keeps `ICLOUD` as the default backend.
- Fresh installs, missing `sync_adapter` values, unknown backend values, removed
  backend values, and legacy `GOOGLE_DRIVE` selections after #116 should resolve
  to iCloud.
- NextCloud/WebDAV remains available as an explicit user choice.
- This does not redefine Android's remote-cloud backend contract; it documents a
  legitimate platform difference.

Reason:

- Android has only remote cloud backends in this settings area. iOS already has
  a shipped platform-native CloudKit path, and the product direction is to make
  that the default iOS sync path.
- #160 tracks preserving the iCloud default when #116 removes Google Drive.

## 2. Google Drive is a removal target

- Status: planned removal
- Scope: Google Drive backend, auth flow, transport code, tests, and docs

Disposition:

- Google Drive should no longer be treated as a retained iOS backend.
- #116 owns removing the selectable backend, Google auth/session UI, Drive
  adapter/auth services, GoogleSignIn dependency, Google-focused tests, and OAuth
  setup documentation.
- Until #116 lands, existing Google Drive code is historical implementation
  surface, not a future parity target to preserve.

Reason:

- The iOS sync product target is iCloud plus NextCloud/WebDAV.
- The previous Google Drive posture required build-time OAuth setup and Google
  integration maintenance that is no longer desired for iOS.
- Android Google Drive behavior can remain Android source context, but iOS
  parity work should not add new Google Drive functionality.

Reference:

- #116 records the removal scope.

## 3. WebDAV persisted key names remain compatibility surface

- Status: intentional compatibility preservation
- Scope: NextCloud / WebDAV settings persistence

Disposition:

- iOS preserves Android-compatible raw preference keys such as
  `gdrive_server_url`, `gdrive_username`, `gdrive_folder_path`, and
  `gdrive_password` even though they now back NextCloud/WebDAV configuration on
  iOS.
- #116 removes Google Drive functionality, but does not automatically authorize
  deleting or renaming these historical WebDAV keys.

Reason:

- The awkward names are part of the cross-platform and existing-user persistence
  contract. Changing them is a migration decision, not a cleanup.

## 4. Adopt-versus-create stays explicit

- Status: intentional UX preservation
- Scope: same-named remote folder handling

Disposition:

- iOS does not silently adopt or overwrite a discovered remote folder.
- The user must explicitly choose whether to restore from the remote baseline or
  replace the remote folder with local state.

Reason:

- This matches Android's top-level synchronization branch point and avoids
  accidental destructive behavior during remote bootstrap.

## 5. Sync category breadth and visibility stay source-backed

- Status: partial parity, split into focused follow-ups
- Scope: remote sync categories and visible toggle rows

Disposition:

- Android defines six sync categories: `bookmarks`, `workspaces`,
  `readingplans`, `mydocuments`, `ai_settings`, and `progress`.
- Android currently hides the Reading Plans toggle at runtime while keeping the
  category in the sync definition.
- iOS currently implements Android-aligned sync for `bookmarks`, `workspaces`,
  `readingplans`, and `mydocuments`.
- iOS currently shows Reading Plans, while Android hides that row. #158 owns the
  final visible-toggle parity decision.
- Android exposes AI Settings and Reading Progress toggle rows. iOS does not
  implement those remote sync categories yet; they remain separate parity
  targets in #74 and #73.
- Reading Progress must stay distinct from Reading Plans unless a later
  documented compatibility decision explicitly changes that.

Reason:

- Android models each category as an independent sync stream. Folding missing
  categories together or silently omitting visible Android rows would hide real
  parity work.

Reference:

- #49 records the decision to split broad category parity into distinct targets.
- #158 tracks visible category toggle alignment.
- #74 tracks `ai_settings`.
- #73 tracks `progress`.

## 6. Sync settings can be native, but must match Android behavior

- Status: intentional native implementation with Android behavior contract
- Scope: Sync settings rows, icons, grouping, dynamic visibility, and status
  summaries

Disposition:

- iOS may use native SwiftUI controls for picker, text fields, buttons, and
  toggles.
- Native implementation is not permission to drift into a generic platform form.
- The visible settings experience should follow Android's information
  architecture: backend row first, Android row labels/summaries/icons where rows
  overlap, dynamic credential/reset/status visibility, and category toggle
  behavior that reflects sync bootstrap state.
- The NextCloud/WebDAV connection test remains an iOS additive workflow only if
  it improves the experience without contradicting Android behavior.

Reason:

- Android also uses native preference primitives, but the screen feels integrated
  with AndBible through custom icons, grouping, summaries, dynamic visibility,
  and sync-side effects.
- iOS parity should target that behavior and experience, not only the presence
  of similarly named controls.

Reference:

- #159 completed the first presentation/workflow pass.
- #116, #158, and #160 own the remaining source-backed follow-ups.
