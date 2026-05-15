# READING-PLANS-702 Regression Report

Date: 2026-05-15

## Scope

Regression verification for the current reading-plan parity surface, covering:

- daily-reading progression in the native SwiftUI screen
- visible reading-plan list start/delete/import affordance flow
- Android initial-backup snapshot reading and validation
- raw Android status-payload preservation
- Android-shaped initial-backup upload
- sparse patch replay and sparse patch upload
- steady-state remote synchronization of reading-plan changes

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

## Current Result

Focused reading-plan validation passed on 2026-05-15:

- unit and integration: `16` tests, `0` failures
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

## Remaining Gap

The current reading-plan parity gap is not the sync core or visible list workflow. It is:

- regression coverage for the additive iOS algorithmic plans
- a focused parser/import-content regression for custom `.properties` plans

Those areas are implemented, but they are not yet locked by focused regression
coverage, so they remain `Partial` in `verification-matrix.md`.
