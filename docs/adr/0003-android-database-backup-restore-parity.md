# 0003: Android Database Backup Restore Parity

Status: Accepted

Date: 2026-06-04

## Context

#150 adds iOS support for Android manual database backup archives
(`AndBibleDatabaseBackup.abdb.zip`). #153 aligns the surrounding iOS Backup &
Restore settings workflow with Android's `BackupActivity` so the user-facing
semantics are shared across platforms instead of preserving iOS-specific backup
categories as the primary path.

Android's manual backup flow is user-facing behavior, not just an internal
storage detail. It lets users load a database backup archive, see the contained
sections, choose section-level Restore or Import behavior, and apply the
selected data. Restore is destructive for selected categories. Import is
non-destructive and keeps existing local rows when Android uniqueness keys
already exist.

iOS cannot honestly implement this by replacing local storage files with
Android Room SQLite databases. The iOS app stores these categories in SwiftData
models plus category-specific fidelity side stores. Directly installing Android
database files would bypass those models, break local invariants, and create a
data-loss risk.

The repo already has Android SQLite readers and restore engines for several
remote-sync categories. Those engines are the safest shared implementation
surface for backup parity because they already know how to map Android database
rows into iOS SwiftData state.

Some Android backup categories do not yet have safe iOS mappers. Hiding those
sections would make valid Android backup contents appear absent. Enabling them
without source-backed mappers would risk corrupt or partial restores.

Android's top-level Backup & Restore screen also has behavior outside database
archive apply: the user chooses Database, Documents, or Application for backup;
chooses Database or Documents for Restore or Import; then chooses Phone storage
or Share as the backup destination. The screen also contains Reset Databases
actions. iOS must preserve those visible decisions even when the platform APIs
behind them are different.

## Decision

iOS Android database backup support targets Android behavioral parity, not raw
storage-mechanism parity.

For manual Android database backups, iOS will:

- load `.abdb.zip` archives through the Android backup manifest
- validate extracted SQLite database sections and schema versions before apply
- show supported and unsupported sections distinctly
- allow Restore or Import only for sections that have safe iOS mappers
- preserve Android's selected-section apply model
- reset affected remote-sync bookkeeping after a manual apply

For the top-level Backup & Restore workflow, iOS will:

- expose the iOS-supported Android Backup choices in order: Database, Documents
- expose Android's Restore or Import choices in order: Database, Documents
- route Database backup to `AndBibleDatabaseBackup.abdb.zip`
- route Documents backup to `AndBibleModulesBackup.abmd.zip`
- present Android's backup destination decision, "Phone storage" or "Share"
- route Database Restore or Import only to `.abdb.zip` archives and the
  section-selection sheet
- route Documents Restore or Import through module/document import plumbing for
  `.abmd.zip`, SWORD ZIP modules, and EPUB files
- move legacy iOS JSON/CSV tools out of the primary workflow
- expose Reset Databases actions only for categories with a real iOS storage
  equivalent

Supported sections are limited to categories with safe Android-to-iOS mappers
and supported schema versions:

- Bookmarks
- Workspaces
- Reading Plans
- My Documents

Unsupported sections remain visible but disabled with a reason. This includes
Android categories that are present in the archive but do not yet have safe iOS
mappers, such as Settings, Repositories, Modules, EPUBs, AI Settings, and
Progress. Future work may enable a category only after adding a source-backed
mapper, version validation, focused tests, and any required fidelity state.

Restore mode replaces the selected local category data with the Android backup
section mapped through the existing restore engine.

Import mode preserves the existing local data state first and adds backup rows
whose Android uniqueness keys are absent. The implementation may build an
Android-shaped merged snapshot and rewrite the category through the existing
restore engine. That can recreate SwiftData object instances even when the
observable data is preserved. This is an accepted storage adaptation, not a
permission to overwrite local row contents or drift from Android's
`INSERT OR IGNORE` intent.

After each supported category is applied, iOS disables and clears the
Android-aligned remote-sync state for that category. Manual backup apply changes
local data outside the remote patch stream, so leaving remote-sync bookkeeping
intact would let later sync treat manually restored rows as already reconciled
remote state.

The category-selection UI may be native SwiftUI because this is an app settings
and system-file-import workflow, not a reader document/window surface. The UI
still has to preserve Android's observable flow: archive summary, visible
sections, disabled unsupported sections, section selection, Restore/Import
choice, and destructive confirmation for Restore. This native setting-sheet
decision is not a precedent for reader document surfaces, which are governed by
ADR 0002.

The top-level workflow may use native iOS plumbing:

- Android "Phone storage" maps to the iOS Files exporter.
- Android "Share" maps to the iOS share sheet.
- Android application backup exports an APK. iOS apps cannot export their
  installed bundle as an IPA/APK equivalent at runtime, so iOS omits the
  Application/APK backup row instead of presenting an inert choice.
- Android AI Settings backup/reset is represented by preserved Android-owned
  database storage until iOS has a native semantic AI settings model. iOS must
  not synthesize an empty `ai_settings.sqlite3`; it may export that category
  only after a real Android database was restored or otherwise preserved.
- Android crash-info export and local backup listing are platform-adjacent
  features that require dedicated iOS storage/logging contracts before they can
  be surfaced without inventing iOS-only semantics.

ZIP extraction should remain explicit and fail-closed. The reader supports the
stored and deflated central-directory ZIP shapes produced by Android backup
archives. Unsupported ZIP shapes must fail with an error instead of silently
skipping entries or treating a partial archive as a valid empty backup.

## Consequences

- Android backup parity is measured by user-observable restore/import behavior
  and final local data state, not by matching Android's storage files byte for
  byte.
- iOS must not enable an unsupported backup category just because the archive
  contains a valid SQLite file. The category needs a safe mapper and tests first.
- Unsupported sections should remain visible so users can tell the difference
  between "not in this backup" and "present but not supported by this iOS
  build."
- Import tests must prove local-first behavior and protect against overwriting
  existing local data.
- Restore tests must prove selected-category replacement and sync-state reset.
- Future mapper additions should update this ADR if they change the supported
  category set or the accepted parity boundary.
- Future UI additions must extend the Android BackupActivity semantics rather
  than restoring iOS-specific backup categories to the primary path.
- JSON and CSV import/export are legacy iOS tools. They may remain available
  under a clearly separated legacy section, but they must not be presented as
  the shared cross-platform backup model.
- Native presentation here is acceptable only for this settings/file-import
  workflow. Reader/document modal decisions still prefer the shared
  Vue/document pipeline unless a separate ADR records a real platform
  constraint.

## Related

- [ADR 0008: Parity Documentation Ownership](0008-parity-documentation-ownership.md)
- [ADR 0002: Route Reader Document Modals Through The Shared Document Pipeline](0002-route-reader-document-modals-through-shared-document-pipeline.md)
- [Android database backup service](../../Sources/BibleCore/Sources/BibleCore/Services/AndroidDatabaseBackupService.swift)
- [Android database backup import sheet](../../Sources/BibleUI/Sources/BibleUI/Settings/AndroidDatabaseBackupImportSheet.swift)
- [Android Backup & Restore workflow](../../Sources/BibleUI/Sources/BibleUI/Settings/ImportExportView.swift)
- [Android database backup core tests](../../Sources/BibleCore/Tests/BibleCoreTests/AndroidDatabaseBackupTests.swift)
- [Android database backup presentation tests](../../Sources/BibleUI/Tests/BibleUITests/AndroidDatabaseBackupPresentationTests.swift)
- #150
- #153
