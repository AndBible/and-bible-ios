# READING-PLANS-702 Regression Report

Date: 2026-05-16

## Scope

Regression verification for the current reading-plan parity surface, covering:

- daily-reading progression in the native SwiftUI screen
- visible reading-plan list start/delete/import affordance flow
- Android initial-backup snapshot reading and validation
- raw Android status-payload preservation
- Android-shaped initial-backup upload
- sparse patch replay and sparse patch upload
- steady-state remote synchronization of reading-plan changes
- custom Android-style `.properties` plan import semantics
- additive iOS algorithmic plan lifecycle behavior

Contract reference:

- `docs/parity/reading-plans/contract.md`

Verification matrix:

- `docs/parity/reading-plans/verification-matrix.md`

## Environment

- Repository: `and-bible-ios`
- Simulator destination: `platform=iOS Simulator,name=iPhone 17`
- Validation style: focused `xcodebuild test` subset

## Tests Executed

### Unit and Integration

- `AndBibleTests/testRemoteSyncReadingPlanRestoreReadsAndroidSnapshot`
- `AndBibleTests/testRemoteSyncReadingPlanRestoreReplacesLocalPlansAndPreservesAndroidStatuses`
- `AndBibleTests/testRemoteSyncReadingPlanRestoreRejectsUnknownPlanDefinitionsWithoutMutation`
- `AndBibleTests/testRemoteSyncReadingPlanRestoreRejectsOrphanStatusesWithoutMutation`
- `AndBibleTests/testRemoteSyncReadingPlanRestoreRejectsMalformedStatusPayloads`
- `AndBibleTests/testRemoteSyncReadingPlanStatusStorePersistsAndClearsStatuses`
- `AndBibleTests/testRemoteSyncReadingPlanStatusStorePreservesRemoteStatusIdentifiers`
- `AndBibleTests/testRemoteSyncReadingPlanPatchApplyReplaysNewerRowsAndRecordsPatchStatus`
- `AndBibleTests/testRemoteSyncReadingPlanPatchApplyDeletesStatusesByRemoteIdentifier`
- `AndBibleTests/testRemoteSyncReadingPlanPatchApplySkipsOlderRows`
- `AndBibleTests/testRemoteSyncInitialBackupUploadWritesReadingPlanDatabaseAndResetsBaseline`
- `AndBibleTests/testRemoteSyncSynchronizationServiceSynchronizesReadyReadingPlanCategory`
- `AndBibleTests/testRemoteSyncSynchronizationServiceUploadsLocalReadingPlanChangesWhenNoRemotePatchesExist`
- `AndBibleTests/testRemoteSyncReadingPlanPatchUploadReturnsNilWhenStateMatchesBaseline`
- `AndBibleTests/testRemoteSyncReadingPlanPatchUploadWritesAndUploadsSparsePatch`
- `AndBibleTests/testRemoteSyncReadingPlanPatchUploadDetectsDeleteAfterInitialRestoreRefresh`
- `AndBibleTests/testReadingPlanCustomPropertiesImportPreservesAndroidSyntax`
- `AndBibleTests/testReadingPlanAlgorithmicPlanLifecycleRemainsAdditive`

### UI

- `AndBibleUITests/testReadingPlanListStartDeleteAndImportAffordanceFlow`
- `AndBibleUITests/testReadingPlansStartPlanAndAdvanceDay`

## Expected Assertions Covered

### Daily-reading progression

- a built-in plan started from the visible list opens into `DailyReadingView`
- the current-day label starts on day `1`
- tapping `Mark as Read` advances the visible day to `2`

### Visible reading-plan list workflow

- the real Reading Plans list starts with no active plans under the baseline fixture
- the available-plan picker exposes the built-in Android-parity template list
- starting `y1ot1nt1_OTthenNT` creates one active row in the list state
- deleting that active row through the swipe action removes it from the list state
- the custom import affordance requests file-picker presentation

### Android initial-backup restore

- staged Android `readingplans.sqlite3` snapshots can be read successfully
- iOS rebuilds supported plans from bundled templates while preserving raw Android status payloads
- unsupported plan codes, orphan statuses, and malformed status JSON fail before mutation

### Android-shaped outbound sync

- initial-backup upload writes a full Android-shaped reading-plan database
- patch-zero bookkeeping is recorded after successful upload
- sparse patch upload stays idle when the local state matches the accepted baseline
- sparse patch upload emits only changed or deleted rows when the local state diverges

### Steady-state synchronization

- newer remote reading-plan patches replay into local SwiftData state
- remote delete patches remove preserved status rows correctly
- older patches are skipped
- a ready reading-plan category can both replay remote patches and upload local changes

### Custom `.properties` import

- numeric Android-style day keys are parsed into one-based day numbers
- non-numeric metadata keys such as `Versification` are ignored
- comma-separated OSIS reference strings and range references are preserved exactly
- custom import sizes the template from the highest numeric day key
- missing numeric days return empty readings instead of inventing assignments

### Additive iOS algorithmic plan lifecycle

- Android bundled templates remain present and retain their day-one readings
- the iOS-only `nt_90` algorithmic template remains additive
- starting the algorithmic plan creates an active persisted plan with `currentDay = 0`
- generated algorithmic day rows remain one-based and cover all 90 days
- completion percentage is calculated from completed generated day rows

## Current Result

Focused reading-plan validation passed on 2026-05-16:

- unit and integration: `18` tests, `0` failures
- UI: `2` tests, `0` failures

This gives the reading-plan domain current regression evidence for:

- Android initial-backup restore
- all-or-nothing snapshot validation
- visible list start/delete/import affordance behavior
- daily-reading advancement
- reading-plan status-store preservation
- Android-shaped initial-backup upload
- sparse patch replay
- sparse patch upload
- steady-state synchronization
- custom Android-style `.properties` plan import
- additive iOS algorithmic plan lifecycle

## Remaining Gap

No reading-plan parity matrix rows currently remain `Partial`. Future changes
should keep the focused import and algorithmic lifecycle tests green alongside
the existing sync and UI coverage.
