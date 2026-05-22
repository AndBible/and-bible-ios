# SYNC-701 Verification Matrix (Android Sync -> iOS)

Date: 2026-05-19

## Scope and Method

- Contract baseline: `docs/parity/sync/contract.md`
- Verification method:
  - direct code inspection of `RemoteSyncSettingsStore`, `RemoteSyncBootstrapCoordinator`,
    `RemoteSyncSynchronizationService`, `NextCloudSyncAdapter`, `GoogleDriveAuthService`,
    `GoogleDriveSyncAdapter`, and `SyncSettingsView`
  - direct comparison with a local Android reference checkout, especially
    `SyncUtilities.kt`, `CloudSync.kt`, `SyncSettings.kt`, and
    `GoogleDriveCloudAdapter.kt`
  - focused simulator-backed UI coverage from `AndBibleUITests`
  - focused unit and integration coverage from `AndBibleTests`, including
    `WorkspaceSyncRestoreTests.swift`
- Regression evidence: `docs/parity/sync/regression-report.md`

## Status Legend

- `Pass`: implemented and backed by direct code evidence plus current regression coverage
- `Adapted Pass`: parity delivered with explicit iOS implementation differences documented in
  `dispositions.md`
- `Partial`: implemented or exposed, but not yet backed by enough focused evidence to treat the
  area as locked

## Summary

- `Pass`: 7
- `Adapted Pass`: 2
- `Partial`: 1

The remaining `Partial` item is implementation breadth, not an unresolved
category-breadth decision. Issue #49 records the decision to track Android's
remaining `mydocuments`, `ai_settings`, and `progress` categories as separate
deferred parity targets in #72, #74, and #73. The `mydocuments` category is
mapped to the iOS My Documents model/storage contract in
`../bridge/my-documents-model.md`; the local model and read bridge are now in
place, while remote sync remains blocked on #72 and the remaining product
slices. The `ai_settings` category is blocked on the
shared AI backend direction in #5 and the #53/#89 bridge disposition. The
`progress` category is blocked on the iOS reading-progress model/storage and
settings contract in #85 and the #52 bridge disposition.

## Matrix

| Sync Contract Area | iOS Evidence | Status | Notes |
|---|---|---|---|
| Backend selection plus Android-compatible persisted keys for NextCloud/WebDAV and supported category toggles | `RemoteSyncSettingsStore.swift`; unit tests `testRemoteSyncSettingsStoreDefaultsToICloudWhenBackendMissing`, `testRemoteSyncSettingsStorePersistsAndroidCompatibleNextCloudKeys`, `testRemoteSyncSettingsStoreFallsBackToICloudForUnknownBackendValue`, `testRemoteSyncSettingsStoreClearsStoredValuesAndPassword`, `testRemoteSyncSettingsStorePersistsAndroidCompatibleCategoryToggleKeys`, `testRemoteSyncSettingsStoreGeneratesStableLowercaseDeviceIdentifier` | Pass | This locks the Android-shaped settings contract for iOS-supported categories while preserving iCloud as an iOS extension. |
| NextCloud/WebDAV URL normalization, DAV transport, and invalid-input handling | `WebDAVSyncConfiguration`, `WebDAVClient`, `NextCloudSyncAdapter`; unit tests `testWebDAVPropfindBuildsAuthenticatedRequestAndParsesMultiStatus`, `testWebDAVSearchBuildsSearchRequestBody`, `testWebDAVMultiStatusParserDecodesPercentEncodedHrefs`, `testWebDAVSyncConfigurationExpandsServerRootToNextCloudDAVEndpoint`, `testWebDAVSyncConfigurationPreservesExplicitDAVEndpoint`, `testWebDAVSyncConfigurationRejectsLoginPageURLs`; UI test `testSyncSettingsNextCloudInvalidURLShowsValidationStatus` | Pass | The current evidence covers both low-level DAV request semantics and the user-visible invalid-URL branch in Sync Settings. |
| Bootstrap inspection and the ready/adopt/create decision tree | `RemoteSyncBootstrapCoordinator`, `RemoteSyncSynchronizationService`; unit tests `testRemoteSyncBootstrapCoordinatorReturnsReadyForKnownStoredFolder`, `testRemoteSyncBootstrapCoordinatorRepairsMissingDeviceFolderForKnownStoredFolder`, `testRemoteSyncBootstrapCoordinatorRequiresRemoteAdoptionWhenNamedFolderExists`, `testRemoteSyncBootstrapCoordinatorClearsStaleBootstrapAndRequestsCreationWhenMarkerMissing`, `testRemoteSyncBootstrapCoordinatorAdoptRemoteFolderPersistsMarkerAndDeviceFolder`, `testRemoteSyncBootstrapCoordinatorCreateRemoteFolderCanReplaceExistingRemoteFolder`, `testRemoteSyncSynchronizationServiceReturnsRemoteAdoptionDecision` | Pass | Bootstrap decisions are regression-gated before any local mutation or remote overwrite occurs. |
| Initial-backup restore and initial-backup upload preserve Android baseline semantics for supported categories | `RemoteSyncInitialBackupRestoreService`, `RemoteSyncInitialBackupUploadService`; shared-scheme unit tests `testRemoteSyncInitialBackupRestoreDispatchesReadingPlanBackups`, `testRemoteSyncInitialBackupRestoreDispatchesBookmarkBackups`, `testRemoteSyncInitialBackupRestoreDispatchesWorkspaceBackups`, `testRemoteSyncInitialBackupUploadWritesReadingPlanDatabaseAndResetsBaseline`, `testRemoteSyncInitialBackupUploadWritesBookmarkDatabaseAndResetsBaseline`, `testRemoteSyncInitialBackupUploadWritesWorkspaceDatabaseAndResetsBaseline`, `testRemoteSyncSynchronizationServiceCreateRemoteFolderUploadsInitialBackupAndSuppressesSparseUpload`, `testRemoteSyncSynchronizationServiceAdoptRemoteFolderRestoresInitialAndRecordsPatchZero` | Pass | Bookmark, reading-plan, and workspace baseline flows are now in the shared `AndBibleTests` target through the shared `AndBible` scheme. |
| Ready-state sparse patch replay/upload and steady-state synchronization run for supported categories | `RemoteSyncSynchronizationService`, category-specific patch apply/upload services; shared-scheme unit tests `testRemoteSyncSynchronizationServiceUploadsLocalBookmarkChangesWhenNoRemotePatchesExist`, `testRemoteSyncSynchronizationServiceUploadsLocalReadingPlanChangesWhenNoRemotePatchesExist`, `testRemoteSyncSynchronizationServiceUploadsLocalWorkspaceChangesWhenNoRemotePatchesExist`, `testRemoteSyncSynchronizationServiceSynchronizesReadyReadingPlanCategory`, `testRemoteSyncSynchronizationServiceAdoptRemoteFolderReplaysRemotePatchWithoutUploadingLocally`, `WorkspaceSyncRestoreTests.swift` patch apply/upload coverage | Pass | Bookmark, reading-plan, and workspace steady-state flows are covered by the shared scheme. |
| Full current Android category breadth | Android `SyncableDatabaseDefinition` currently includes `BOOKMARKS`, `WORKSPACES`, `READINGPLANS`, `MYDOCUMENTS`, `AI_SETTINGS`, and `PROGRESS`; iOS `RemoteSyncCategory` currently includes `bookmarks`, `workspaces`, and `readingplans`; #49 records the disposition split for the remaining categories | Partial | iOS aligns with Android names and file semantics for the first three categories. Android's `mydocuments`, `ai_settings`, and `progress` categories are deferred as distinct parity targets tracked by #72, #74, and #73 rather than one broad implementation task; `mydocuments` now has a local model and read bridge recorded in `../bridge/my-documents-model.md` but remote sync remains blocked on #72, `ai_settings` remains blocked on #5 and the #53/#89 bridge disposition, and `progress` remains blocked on #85 and the #52 bridge disposition. |
| Sync settings UI supports backend switching and category persistence across reopen | `SyncSettingsView.swift`; UI tests `testSettingsSyncLinkOpensSyncSettings`, `testSyncSettingsCategoryToggleMutatesExportedState`, `testSyncSettingsCategoryDisablePersistsAcrossDirectReopen`, `testSyncSettingsBackendSwitchMutatesVisibleSection`, `testSyncSettingsBackendSwitchPersistsAcrossDirectReopen` | Pass | The current gate is focused on persisted state and visible section changes, not just navigation smoke. |
| Google Drive uses the Android-aligned OAuth + Drive API model but is operationally parked until real iOS OAuth provisioning exists | `GoogleDriveAuthService.swift`, `GoogleDriveSyncAdapter.swift`, `RemoteSyncSynchronizationServiceFactory`; unit tests `testGoogleDriveSyncAdapterListsFilesFromAppDataFolderWithPagination`, `testGoogleDriveSyncAdapterCreatesFolderUnderAppDataRoot`, `testGoogleDriveSyncAdapterUploadsMultipartPatchArchive`, `testGoogleDriveSyncAdapterUsesFolderExistenceForOwnershipProof`, `testGoogleDriveOAuthConfigurationParsesValidInfoDictionary`, `testGoogleDriveOAuthConfigurationRejectsMissingURLScheme`, `testGoogleDriveAuthServiceRestoresPreviousSignInOnceAndBecomesReadyForSync`, `testRemoteSyncSynchronizationServiceFactoryBuildsGoogleDriveAdapter`; documented in `dispositions.md` | Adapted Pass | The code path is regression-backed, but live end-user sign-in remains intentionally parked until release OAuth credentials exist. |
| iCloud remains a first-class backend alongside Android-aligned remote sync | `RemoteSyncBackend.iCloud`, `SyncSettingsView.swift`, `dispositions.md` | Adapted Pass | This is an intentional iOS extension and does not redefine the Android parity contract for remote backends. |
| UI coverage for the adopt-versus-create confirmation branch itself | `SyncSettingsView.swift`; UI test `testSyncSettingsAdoptCreateConfirmationCreateChoiceSynchronizesFromVisibleWorkflow` | Pass | The focused workflow drives the visible adopt/create sheet, chooses the create-new cloud replacement branch, confirms the destructive reset-cloud alert, and waits for the bookmarks category to finish enabled with `lastConfirmation=resetCloud:bookmarks`. |
