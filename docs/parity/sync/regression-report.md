# SYNC-702 Regression Report

Date: 2026-05-18

## Scope

Regression verification for the current sync parity surface, covering:

- Android-compatible backend and supported-category settings persistence
- NextCloud/WebDAV URL normalization plus DAV request semantics
- bootstrap ready/adopt/create decisions
- Android-shaped initial-backup restore and initial-backup upload behavior for bookmarks,
  workspaces, reading plans, and My Documents
- ready-state patch replay and steady-state outbound upload
- Sync settings backend/category mutation, My Documents category exposure, and reopen persistence
- Sync settings adopt-versus-create confirmation branch
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
- `RemoteSyncMyDocumentRestoreTests/testRemoteSyncInitialBackupRestoreDispatchesMyDocumentBackups`
- `AndBibleTests/testRemoteSyncInitialBackupUploadWritesReadingPlanDatabaseAndResetsBaseline`
- `AndBibleTests/testRemoteSyncInitialBackupUploadWritesBookmarkDatabaseAndResetsBaseline`
- `AndBibleTests/testRemoteSyncInitialBackupUploadWritesWorkspaceDatabaseAndResetsBaseline`
- `RemoteSyncMyDocumentRestoreTests/testRemoteSyncInitialBackupUploadWritesMyDocumentDatabaseAndResetsBaseline`
- `AndBibleTests/testRemoteSyncSynchronizationServiceCreateRemoteFolderUploadsInitialBackupAndSuppressesSparseUpload`
- `AndBibleTests/testRemoteSyncSynchronizationServiceAdoptRemoteFolderRestoresInitialAndRecordsPatchZero`
- `AndBibleTests/testRemoteSyncSynchronizationServiceAdoptRemoteFolderReplaysRemotePatchWithoutUploadingLocally`
- `AndBibleTests/testRemoteSyncSynchronizationServiceSynchronizesReadyReadingPlanCategory`
- `RemoteSyncMyDocumentRestoreTests/testRemoteSyncSynchronizationServiceReplaysRemoteMyDocumentPatch`
- `AndBibleTests/testRemoteSyncSynchronizationServiceUploadsLocalBookmarkChangesWhenNoRemotePatchesExist`
- `AndBibleTests/testRemoteSyncSynchronizationServiceUploadsLocalReadingPlanChangesWhenNoRemotePatchesExist`
- `AndBibleTests/testRemoteSyncSynchronizationServiceUploadsLocalWorkspaceChangesWhenNoRemotePatchesExist`
- `RemoteSyncMyDocumentRestoreTests/testRemoteSyncSynchronizationServiceUploadsLocalMyDocumentChangesWhenNoRemotePatchesExist`
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
- `AndBibleUITests/testSyncSettingsAdoptCreateConfirmationCreateChoiceSynchronizesFromVisibleWorkflow`
- `AndBibleUITests/testSyncSettingsMyDocumentsCategoryToggleStartsManualSyncPath`
- `AndBibleUITests/testSyncSettingsBackendSwitchMutatesVisibleSection`
- `AndBibleUITests/testSyncSettingsBackendSwitchPersistsAcrossDirectReopen`

## Expected Assertions Covered

### Settings persistence and UI state

- missing or unknown backend values fall back safely to iCloud
- Android-compatible raw keys persist NextCloud/WebDAV credentials and per-category enablement
- backend and category mutations persist across direct Sync Settings reopen
- invalid NextCloud URL input surfaces the expected UI validation state
- the visible adopt/create prompt can drive the create-new cloud replacement branch and complete
  synchronization with the selected category enabled
- the My Documents category is visible in Sync Settings and starts the same manual remote-sync
  prompt path as the other supported categories

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
- initial-backup restore and initial-backup upload for bookmark, workspace, reading-plan, and
  My Documents flows
- ready-state synchronization for bookmark, workspace, reading-plan, and My Documents categories
- parked Google Drive auth and adapter contracts
- Sync settings backend/category mutation plus reopen persistence
- Sync settings adopt-versus-create confirmation UI coverage, including My Documents category entry

## Remaining Gap

The current sync parity gap is not the core bootstrap or patch engine. It is
implementation breadth beyond the supported category set:

- Android category breadth beyond iOS's supported `bookmarks`, `workspaces`,
  `readingplans`, and `mydocuments` categories.
- Android also exposes `ai_settings` and `progress`.

The adopt-versus-create branch is now covered both below the UI through coordinator and
synchronization tests and through a focused simulator workflow. The remaining `Partial` sync parity
area is Android category breadth beyond the currently supported iOS categories.

Issue #49 resolves the category-breadth decision by splitting Android-only
categories into distinct parity targets:

- #72 tracks `mydocuments`, mapped to the iOS My Documents model/storage
  contract in `../bridge/my-documents-model.md`. #104 records the
  Android-backed sync schema and policy contract in `mydocuments-schema.md`;
  initial restore (#105), initial upload (#106), patch replay (#108), patch
  upload (#107), and settings/docs exposure (#109) are implemented.
- #74 tracks `ai_settings`, blocked on the shared AI backend/settings direction
  in #5. The #53 AI bridge disposition and #89 bridge shell contract keep
  bridge-facing settings ownership aligned with that shared backend direction.
- #73 tracks `progress`. The #52 reading-progress bridge decision now has the
  local model/storage/settings contract recorded in
  `../bridge/reading-progress-model.md`, and the #50 memorization bridge state
  slice has local iOS storage. Remote Android `progress` sync compatibility,
  including KJVA persistence, adoption, and conflict behavior, still belongs to
  #73.
