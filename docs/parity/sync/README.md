# Sync Parity

This directory holds Android-aligned sync parity documentation for iOS.

## Reading Order

1. [contract.md](contract.md): current sync contract and supported flows
2. [mydocuments-schema.md](mydocuments-schema.md): Android-backed `mydocuments`
   schema and policy contract for #104
3. [dispositions.md](dispositions.md): explicit iOS deviations and operational constraints
4. [verification-matrix.md](verification-matrix.md): current status by contract area
5. [regression-report.md](regression-report.md): focused validation evidence
6. [guardrails.md](guardrails.md): maintenance rules for high-risk sync changes

Operational companion docs:

- [../../howto/google-drive-oauth-setup.md](../../howto/google-drive-oauth-setup.md):
  developer/release guidance for the parked Google Drive OAuth dependency

## Scope

This subtree is for parity-sensitive sync behavior:

- backend selection semantics
- category coverage
- bootstrap/adopt/create flows
- initial-backup and patch behavior
- explicit iOS divergences from Android

It is not the place for one-off local task tracking or release checklists.

Primary references:

- `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncSettingsStore.swift`
- `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncBootstrapCoordinator.swift`
- `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncSynchronizationService.swift`
- `Sources/BibleCore/Sources/BibleCore/Services/NextCloudSyncAdapter.swift`
- `Sources/BibleCore/Sources/BibleCore/Services/GoogleDriveAuthService.swift`
- `Sources/BibleCore/Sources/BibleCore/Services/GoogleDriveSyncAdapter.swift`
- `Sources/BibleUI/Sources/BibleUI/Settings/SyncSettingsView.swift`
