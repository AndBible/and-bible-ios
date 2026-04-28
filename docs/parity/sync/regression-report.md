# SYNC-702 Regression Report

Date: 2026-04-28

## Scope

Regression verification for the current sync parity surface, covering:

- Android-compatible backend and supported-category settings persistence
- NextCloud/WebDAV URL normalization plus DAV request semantics
- bootstrap ready/adopt/create decisions
- Android-shaped initial-backup restore and initial-backup upload behavior for bookmarks,
  workspaces, and reading plans
- ready-state patch replay and steady-state outbound upload
- Sync settings backend/category mutation and reopen persistence
- the parked Google Drive auth and adapter contract
- local Android reference comparison

Contract reference:

- `docs/parity/sync/contract.md`

Verification matrix:

- `docs/parity/sync/verification-matrix.md`

Operational setup reference:

- `docs/howto/google-drive-oauth-setup.md`

## Environment

- Repository: `and-bible-ios`
- Simulator destination: `platform=iOS Simulator,name=iPhone 17`
- Validation style: focused `xcodebuild test` subset

## Current Rerunnable Test Set

### Unit and Integration

- `AndBibleTests/testWebDAVPropfindBuildsAuthenticatedRequestAndParsesMultiStatus`
- `AndBibleTests/testWebDAVSearchBuildsSearchRequestBody`
- `AndBibleTests/testWebDAVMultiStatusParserDecodesPercentEncodedHrefs`
- `AndBibleTests/testRemoteSyncSettingsStoreDefaultsToICloudWhenBackendMissing`
- `AndBibleTests/testRemoteSyncSettingsStorePersistsAndroidCompatibleNextCloudKeys`
- `AndBibleTests/testRemoteSyncSettingsStoreFallsBackToICloudForUnknownBackendValue`
- `AndBibleTests/testRemoteSyncSettingsStoreClearsStoredValuesAndPassword`
- `AndBibleTests/testRemoteSyncSettingsStoreClearsPasswordWhenSaveReceivesWhitespaceOnlySecret`
- `AndBibleTests/testRemoteSyncSettingsStorePersistsAndroidCompatibleCategoryToggleKeys`
- `AndBibleTests/testRemoteSyncSettingsStoreGeneratesStableLowercaseDeviceIdentifier`
- `AndBibleTests/testWebDAVSyncConfigurationExpandsServerRootToNextCloudDAVEndpoint`
- `AndBibleTests/testWebDAVSyncConfigurationPreservesExplicitDAVEndpoint`
- `AndBibleTests/testWebDAVSyncConfigurationRejectsLoginPageURLs`
- `AndBibleTests/testRemoteSyncBootstrapCoordinatorReturnsReadyForKnownStoredFolder`
- `AndBibleTests/testRemoteSyncBootstrapCoordinatorRepairsMissingDeviceFolderForKnownStoredFolder`
- `AndBibleTests/testRemoteSyncBootstrapCoordinatorRequiresRemoteAdoptionWhenNamedFolderExists`
- `AndBibleTests/testRemoteSyncBootstrapCoordinatorClearsStaleBootstrapAndRequestsCreationWhenMarkerMissing`
- `AndBibleTests/testRemoteSyncBootstrapCoordinatorAdoptRemoteFolderPersistsMarkerAndDeviceFolder`
- `AndBibleTests/testRemoteSyncBootstrapCoordinatorCreateRemoteFolderCanReplaceExistingRemoteFolder`
- `AndBibleTests/testRemoteSyncSynchronizationServiceReturnsRemoteAdoptionDecision`
- `AndBibleTests/testRemoteSyncInitialBackupRestoreDispatchesReadingPlanBackups`
- `AndBibleTests/testRemoteSyncInitialBackupRestoreDispatchesBookmarkBackups`
- `AndBibleTests/testRemoteSyncInitialBackupRestoreDispatchesWorkspaceBackups`
- `AndBibleTests/testRemoteSyncInitialBackupUploadWritesReadingPlanDatabaseAndResetsBaseline`
- `AndBibleTests/testRemoteSyncInitialBackupUploadWritesBookmarkDatabaseAndResetsBaseline`
- `AndBibleTests/testRemoteSyncInitialBackupUploadWritesWorkspaceDatabaseAndResetsBaseline`
- `AndBibleTests/testRemoteSyncSynchronizationServiceCreateRemoteFolderUploadsInitialBackupAndSuppressesSparseUpload`
- `AndBibleTests/testRemoteSyncSynchronizationServiceAdoptRemoteFolderRestoresInitialAndRecordsPatchZero`
- `AndBibleTests/testRemoteSyncSynchronizationServiceAdoptRemoteFolderReplaysRemotePatchWithoutUploadingLocally`
- `AndBibleTests/testRemoteSyncSynchronizationServiceSynchronizesReadyReadingPlanCategory`
- `AndBibleTests/testRemoteSyncSynchronizationServiceUploadsLocalBookmarkChangesWhenNoRemotePatchesExist`
- `AndBibleTests/testRemoteSyncSynchronizationServiceUploadsLocalReadingPlanChangesWhenNoRemotePatchesExist`
- `AndBibleTests/testRemoteSyncSynchronizationServiceUploadsLocalWorkspaceChangesWhenNoRemotePatchesExist`
- `AndBibleTests/testGoogleDriveSyncAdapterListsFilesFromAppDataFolderWithPagination`
- `AndBibleTests/testGoogleDriveSyncAdapterCreatesFolderUnderAppDataRoot`
- `AndBibleTests/testGoogleDriveSyncAdapterUploadsMultipartPatchArchive`
- `AndBibleTests/testGoogleDriveSyncAdapterUsesFolderExistenceForOwnershipProof`
- `AndBibleTests/testGoogleDriveOAuthConfigurationParsesValidInfoDictionary`
- `AndBibleTests/testGoogleDriveOAuthConfigurationRejectsMissingURLScheme`
- `AndBibleTests/testGoogleDriveOAuthConfigurationRejectsBlankClientID`
- `AndBibleTests/testGoogleDriveAuthServiceRestoresPreviousSignInOnceAndBecomesReadyForSync`
- `AndBibleTests/testGoogleDriveAuthServiceAccessTokenThrowsWhenDriveScopeMissing`
- `AndBibleTests/testRemoteSyncSynchronizationServiceFactoryRequiresGoogleDriveAuthProvider`
- `AndBibleTests/testRemoteSyncSynchronizationServiceFactoryBuildsGoogleDriveAdapter`

### UI

- `AndBibleUITests/testSettingsSyncLinkOpensSyncSettings`
- `AndBibleUITests/testSyncSettingsNextCloudInvalidURLShowsValidationStatus`
- `AndBibleUITests/testSyncSettingsCategoryToggleMutatesExportedState`
- `AndBibleUITests/testSyncSettingsCategoryDisablePersistsAcrossDirectReopen`
- `AndBibleUITests/testSyncSettingsBackendSwitchMutatesVisibleSection`
- `AndBibleUITests/testSyncSettingsBackendSwitchPersistsAcrossDirectReopen`

## Expected Assertions Covered

### Settings persistence and UI state

- missing or unknown backend values fall back safely to iCloud
- Android-compatible raw keys persist NextCloud/WebDAV credentials and per-category enablement
- backend and category mutations persist across direct Sync Settings reopen
- invalid NextCloud URL input surfaces the expected UI validation state

### Bootstrap and baseline handling

- bootstrap inspection can return ready, adoption-required, or creation-required outcomes
- stale bootstrap state is repaired or cleared when the remote marker/device folder no longer matches
- adopting a remote folder restores the staged Android baseline and records patch-zero state
- creating a new remote folder uploads a local Android-shaped baseline and suppresses immediate sparse echo

### Steady-state synchronization

- ready categories can replay newer remote patches
- ready categories can upload sparse local patches when no newer remote patch exists
- bookmark, reading-plan, and workspace category streams are in the shared `AndBible`
  scheme through the `AndBibleTests` target

### Google Drive parked branch

- the adapter uses Drive `appDataFolder` semantics for listing, folder creation, upload, and ownership checks
- OAuth bundle configuration is validated before sign-in can begin
- auth state can restore a prior sign-in and still reject access-token reads when Drive scope is missing

## Historical Result And Current Interpretation

Focused sync validation passed on 2026-03-16 for the then-current non-workspace subset:

- unit and integration: `41` tests, `0` failures
- UI: `6` tests, `0` failures
- combined focused subset runtime: about `238s` end-to-end

The stale workspace-scheme limitation from the original report has been removed. As of this
audit, `WorkspaceSyncRestoreTests.swift` is part of the `AndBibleTests` target and is included by
the shared `AndBible` scheme, so workspace sync is a standard rerunnable path. This doc refresh did
not rerun the simulator suite, so the old runtime/counts above should not be treated as a fresh
2026-04-28 execution result.

The checked-in shared-scheme test set gives the sync domain rerunnable regression coverage for:

- Android-compatible backend and category persistence
- NextCloud/WebDAV normalization and transport behavior
- bootstrap ready/adopt/create decisions
- initial-backup restore and initial-backup upload for bookmark, workspace, and reading-plan flows
- ready-state synchronization for bookmark, workspace, and reading-plan categories
- parked Google Drive auth and adapter contracts
- Sync settings backend/category mutation plus reopen persistence

## Remaining Gap

The current sync parity gap is not the core bootstrap or patch engine. It is:

- a focused UI workflow that drives the explicit adopt-versus-create confirmation sheet end to end
- Android category breadth beyond iOS's supported `bookmarks`, `workspaces`, and `readingplans`
  categories: Android also exposes `mydocuments`, `ai_settings`, and `progress`

That branch is already covered in unit and integration tests through the coordinator and
synchronization service. It remains `Partial` because the user-facing confirmation path is not yet
locked by a focused simulator workflow, and the remaining Android-only categories are not
implemented on iOS yet.
