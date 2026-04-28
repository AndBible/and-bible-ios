# SYNC-701 Verification Matrix (Android Sync -> iOS)

Date: 2026-04-28

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

- `Pass`: 6
- `Adapted Pass`: 2
- `Partial`: 2

## Matrix

| Sync Contract Area | iOS Evidence | Status | Notes |
|---|---|---|---|
| Backend selection plus Android-compatible persisted keys for NextCloud/WebDAV and supported category toggles | `RemoteSyncSettingsStore.swift`; unit tests `testRemoteSyncSettingsStoreDefaultsToICloudWhenBackendMissing`, `testRemoteSyncSettingsStorePersistsAndroidCompatibleNextCloudKeys`, `testRemoteSyncSettingsStoreFallsBackToICloudForUnknownBackendValue`, `testRemoteSyncSettingsStoreClearsStoredValuesAndPassword`, `testRemoteSyncSettingsStorePersistsAndroidCompatibleCategoryToggleKeys`, `testRemoteSyncSettingsStoreGeneratesStableLowercaseDeviceIdentifier` | Pass | This locks the Android-shaped settings contract for iOS-supported categories while preserving iCloud as an iOS extension. |
| NextCloud/WebDAV URL normalization, DAV transport, and invalid-input handling | `WebDAVSyncConfiguration`, `WebDAVClient`, `NextCloudSyncAdapter`; unit tests `testWebDAVPropfindBuildsAuthenticatedRequestAndParsesMultiStatus`, `testWebDAVSearchBuildsSearchRequestBody`, `testWebDAVMultiStatusParserDecodesPercentEncodedHrefs`, `testWebDAVSyncConfigurationExpandsServerRootToNextCloudDAVEndpoint`, `testWebDAVSyncConfigurationPreservesExplicitDAVEndpoint`, `testWebDAVSyncConfigurationRejectsLoginPageURLs`; UI test `testSyncSettingsNextCloudInvalidURLShowsValidationStatus` | Pass | The current evidence covers both low-level DAV request semantics and the user-visible invalid-URL branch in Sync Settings. |
| Bootstrap inspection and the ready/adopt/create decision tree | `RemoteSyncBootstrapCoordinator`, `RemoteSyncSynchronizationService`; unit tests `testRemoteSyncBootstrapCoordinatorReturnsReadyForKnownStoredFolder`, `testRemoteSyncBootstrapCoordinatorRepairsMissingDeviceFolderForKnownStoredFolder`, `testRemoteSyncBootstrapCoordinatorRequiresRemoteAdoptionWhenNamedFolderExists`, `testRemoteSyncBootstrapCoordinatorClearsStaleBootstrapAndRequestsCreationWhenMarkerMissing`, `testRemoteSyncBootstrapCoordinatorAdoptRemoteFolderPersistsMarkerAndDeviceFolder`, `testRemoteSyncBootstrapCoordinatorCreateRemoteFolderCanReplaceExistingRemoteFolder`, `testRemoteSyncSynchronizationServiceReturnsRemoteAdoptionDecision` | Pass | Bootstrap decisions are regression-gated before any local mutation or remote overwrite occurs. |
| Initial-backup restore and initial-backup upload preserve Android baseline semantics for supported categories | `RemoteSyncInitialBackupRestoreService`, `RemoteSyncInitialBackupUploadService`; shared-scheme unit tests `testRemoteSyncInitialBackupRestoreDispatchesReadingPlanBackups`, `testRemoteSyncInitialBackupRestoreDispatchesBookmarkBackups`, `testRemoteSyncInitialBackupRestoreDispatchesWorkspaceBackups`, `testRemoteSyncInitialBackupUploadWritesReadingPlanDatabaseAndResetsBaseline`, `testRemoteSyncInitialBackupUploadWritesBookmarkDatabaseAndResetsBaseline`, `testRemoteSyncInitialBackupUploadWritesWorkspaceDatabaseAndResetsBaseline`, `testRemoteSyncSynchronizationServiceCreateRemoteFolderUploadsInitialBackupAndSuppressesSparseUpload`, `testRemoteSyncSynchronizationServiceAdoptRemoteFolderRestoresInitialAndRecordsPatchZero` | Pass | Bookmark, reading-plan, and workspace baseline flows are now in the shared `AndBibleTests` target through the shared `AndBible` scheme. |
| Ready-state sparse patch replay/upload and steady-state synchronization run for supported categories | `RemoteSyncSynchronizationService`, category-specific patch apply/upload services; shared-scheme unit tests `testRemoteSyncSynchronizationServiceUploadsLocalBookmarkChangesWhenNoRemotePatchesExist`, `testRemoteSyncSynchronizationServiceUploadsLocalReadingPlanChangesWhenNoRemotePatchesExist`, `testRemoteSyncSynchronizationServiceUploadsLocalWorkspaceChangesWhenNoRemotePatchesExist`, `testRemoteSyncSynchronizationServiceSynchronizesReadyReadingPlanCategory`, `testRemoteSyncSynchronizationServiceAdoptRemoteFolderReplaysRemotePatchWithoutUploadingLocally`, `WorkspaceSyncRestoreTests.swift` patch apply/upload coverage | Pass | Bookmark, reading-plan, and workspace steady-state flows are covered by the shared scheme. |
| Full current Android category breadth | Android `SyncableDatabaseDefinition` currently includes `BOOKMARKS`, `WORKSPACES`, `READINGPLANS`, `MYDOCUMENTS`, `AI_SETTINGS`, and `PROGRESS`; iOS `RemoteSyncCategory` currently includes `bookmarks`, `workspaces`, and `readingplans` | Partial | iOS aligns with Android names and file semantics for the first three categories, but it does not yet implement Android's `mydocuments`, `ai_settings`, or `progress` sync categories. |
| Sync settings UI supports backend switching and category persistence across reopen | `SyncSettingsView.swift`; UI tests `testSettingsSyncLinkOpensSyncSettings`, `testSyncSettingsCategoryToggleMutatesExportedState`, `testSyncSettingsCategoryDisablePersistsAcrossDirectReopen`, `testSyncSettingsBackendSwitchMutatesVisibleSection`, `testSyncSettingsBackendSwitchPersistsAcrossDirectReopen` | Pass | The current gate is focused on persisted state and visible section changes, not just navigation smoke. |
| Google Drive uses the Android-aligned OAuth + Drive API model but is operationally parked until real iOS OAuth provisioning exists | `GoogleDriveAuthService.swift`, `GoogleDriveSyncAdapter.swift`, `RemoteSyncSynchronizationServiceFactory`; unit tests `testGoogleDriveSyncAdapterListsFilesFromAppDataFolderWithPagination`, `testGoogleDriveSyncAdapterCreatesFolderUnderAppDataRoot`, `testGoogleDriveSyncAdapterUploadsMultipartPatchArchive`, `testGoogleDriveSyncAdapterUsesFolderExistenceForOwnershipProof`, `testGoogleDriveOAuthConfigurationParsesValidInfoDictionary`, `testGoogleDriveOAuthConfigurationRejectsMissingURLScheme`, `testGoogleDriveAuthServiceRestoresPreviousSignInOnceAndBecomesReadyForSync`, `testRemoteSyncSynchronizationServiceFactoryBuildsGoogleDriveAdapter`; documented in `dispositions.md` | Adapted Pass | The code path is regression-backed, but live end-user sign-in remains intentionally parked until release OAuth credentials exist. |
| iCloud remains a first-class backend alongside Android-aligned remote sync | `RemoteSyncBackend.iCloud`, `SyncSettingsView.swift`, `dispositions.md` | Adapted Pass | This is an intentional iOS extension and does not redefine the Android parity contract for remote backends. |
| UI coverage for the adopt-versus-create confirmation branch itself | `SyncSettingsView.swift` confirmation flow exists, but current focused UI subset does not drive the explicit adopt/create sheet end to end | Partial | The branch is well-covered in coordinator and synchronization unit tests, but not yet by a focused user-visible confirmation workflow test. |
