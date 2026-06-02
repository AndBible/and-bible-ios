# SYNC-701 Verification Matrix (Android Sync -> iOS)

Date: 2026-06-02

## Scope and Method

- Contract baseline: `docs/parity/sync/contract.md`
- Verification method:
  - direct code inspection of `RemoteSyncSettingsStore`, `RemoteSyncStateStore`,
    `RemoteSyncBootstrapCoordinator`, `RemoteSyncSynchronizationService`,
    `NextCloudSyncAdapter`, `GoogleDriveAuthService`, `GoogleDriveSyncAdapter`,
    and `SyncSettingsView`
  - direct comparison with a local Android reference checkout, especially
    `sync_settings.xml`, `SyncSettings.kt`, `CloudSync.kt`, `SyncUtilities.kt`,
    and `strings.xml`
  - focused simulator-backed UI coverage from `AndBibleUITests`
  - focused unit and integration coverage from `AndBibleTests`, including
    `WorkspaceSyncRestoreTests.swift` and `RemoteSyncMyDocumentRestoreTests.swift`
- Regression evidence: `docs/parity/sync/regression-report.md`

## Status Legend

- `Pass`: implemented and backed by direct code evidence plus current regression
  coverage
- `Adapted Pass`: parity delivered with explicit iOS implementation differences
  documented in `dispositions.md`
- `Partial`: implemented or exposed, but not yet aligned with the audited
  Android source or current iOS product direction

## Summary

- `Pass`: 6
- `Adapted Pass`: 1
- `Partial`: 4

The remaining partials are now explicit:

- #116 removes Google Drive from the iOS backend surface.
- #160 preserves iCloud as the iOS default after Google Drive removal.
- #158 reconciles visible category toggles against Android's runtime behavior.
- #73 and #74 own the Android `progress` and `ai_settings` sync categories.

## Matrix

| Sync Contract Area | iOS Evidence | Status | Notes |
|---|---|---|---|
| Backend selection and persisted keys for the post-#116 target | `RemoteSyncSettingsStore.swift`; tests `testRemoteSyncSettingsStoreDefaultsToICloudWhenBackendMissing`, `testRemoteSyncSettingsStorePersistsAndroidCompatibleNextCloudKeys`, `testRemoteSyncSettingsStoreFallsBackToICloudForUnknownBackendValue`, `testRemoteSyncSettingsStorePersistsAndroidCompatibleCategoryToggleKeys`, `testRemoteSyncSettingsStoreGeneratesStableLowercaseDeviceIdentifier` | Partial | iCloud already defaults missing/unknown values and NextCloud/WebDAV keys are covered. Current code still exposes Google Drive; #116 removes it and #160 preserves iCloud as default for removed `GOOGLE_DRIVE` values. |
| NextCloud/WebDAV URL normalization, DAV transport, and invalid-input handling | `WebDAVSyncConfiguration`, `WebDAVClient`, `NextCloudSyncAdapter`; tests `testWebDAVPropfindBuildsAuthenticatedRequestAndParsesMultiStatus`, `testWebDAVSearchBuildsSearchRequestBody`, `testWebDAVMultiStatusParserDecodesPercentEncodedHrefs`, `testWebDAVSyncConfigurationExpandsServerRootToNextCloudDAVEndpoint`, `testWebDAVSyncConfigurationPreservesExplicitDAVEndpoint`, `testWebDAVSyncConfigurationRejectsLoginPageURLs`; UI test `testSyncSettingsNextCloudInvalidURLShowsValidationStatus` | Pass | The current evidence covers low-level DAV semantics and the user-visible invalid-URL branch. The historical `gdrive_*` WebDAV keys remain compatibility surface after Google Drive removal. |
| Bootstrap inspection and ready/adopt/create decision tree | `RemoteSyncBootstrapCoordinator`, `RemoteSyncSynchronizationService`; tests `testRemoteSyncBootstrapCoordinatorReturnsReadyForKnownStoredFolder`, `testRemoteSyncBootstrapCoordinatorRepairsMissingDeviceFolderForKnownStoredFolder`, `testRemoteSyncBootstrapCoordinatorRequiresRemoteAdoptionWhenNamedFolderExists`, `testRemoteSyncBootstrapCoordinatorClearsStaleBootstrapAndRequestsCreationWhenMarkerMissing`, `testRemoteSyncBootstrapCoordinatorAdoptRemoteFolderPersistsMarkerAndDeviceFolder`, `testRemoteSyncBootstrapCoordinatorCreateRemoteFolderCanReplaceExistingRemoteFolder`, `testRemoteSyncSynchronizationServiceReturnsRemoteAdoptionDecision` | Pass | Bootstrap decisions are regression-gated before local mutation or remote overwrite occurs. |
| Initial-backup restore and upload preserve Android baseline semantics for implemented categories | `RemoteSyncInitialBackupRestoreService`, `RemoteSyncInitialBackupUploadService`; tests `testRemoteSyncInitialBackupRestoreDispatchesReadingPlanBackups`, `testRemoteSyncInitialBackupRestoreDispatchesBookmarkBackups`, `testRemoteSyncInitialBackupRestoreDispatchesWorkspaceBackups`, `testRemoteSyncInitialBackupRestoreDispatchesMyDocumentBackups`, `testRemoteSyncInitialBackupUploadWritesReadingPlanDatabaseAndResetsBaseline`, `testRemoteSyncInitialBackupUploadWritesBookmarkDatabaseAndResetsBaseline`, `testRemoteSyncInitialBackupUploadWritesWorkspaceDatabaseAndResetsBaseline`, `testRemoteSyncInitialBackupUploadWritesMyDocumentDatabaseAndResetsBaseline`, `testRemoteSyncSynchronizationServiceCreateRemoteFolderUploadsInitialBackupAndSuppressesSparseUpload`, `testRemoteSyncSynchronizationServiceAdoptRemoteFolderRestoresInitialAndRecordsPatchZero` | Pass | Bookmark, reading-plan, workspace, and My Documents baseline flows are covered by the shared `AndBible` scheme. |
| Ready-state sparse patch replay/upload and steady-state synchronization for implemented categories | `RemoteSyncSynchronizationService`, category-specific patch apply/upload services; tests `testRemoteSyncSynchronizationServiceUploadsLocalBookmarkChangesWhenNoRemotePatchesExist`, `testRemoteSyncSynchronizationServiceUploadsLocalReadingPlanChangesWhenNoRemotePatchesExist`, `testRemoteSyncSynchronizationServiceUploadsLocalWorkspaceChangesWhenNoRemotePatchesExist`, `testRemoteSyncSynchronizationServiceUploadsLocalMyDocumentChangesWhenNoRemotePatchesExist`, `testRemoteSyncSynchronizationServiceSynchronizesReadyReadingPlanCategory`, `testRemoteSyncSynchronizationServiceReplaysRemoteMyDocumentPatch`, `testRemoteSyncSynchronizationServiceAdoptRemoteFolderReplaysRemotePatchWithoutUploadingLocally`, workspace patch coverage, and My Documents patch replay/upload coverage | Pass | Bookmark, reading-plan, workspace, and My Documents steady-state flows are covered by the shared scheme. |
| Android category breadth and visible toggle behavior | Android `SyncableDatabaseDefinition` includes `BOOKMARKS`, `WORKSPACES`, `READINGPLANS`, `MYDOCUMENTS`, `AI_SETTINGS`, and `PROGRESS`; Android `SyncSettings.kt` hides `sync_enable_readingplans`; iOS `RemoteSyncCategory.activeSyncCases` includes `bookmarks`, `workspaces`, `readingplans`, and `mydocuments` | Partial | iOS currently shows Reading Plans even though Android hides it, and iOS does not expose AI Settings or Reading Progress. #158 owns visible toggle alignment; #74 and #73 own the missing sync categories. |
| Sync settings row presentation, grouping, dynamic visibility, and status behavior | `SyncSettingsView.swift`, `SyncSettingsPresentation.swift`, `AndBibleIconCatalog.swift`; tests `testSyncSettingsPresentationUsesAndroidBackedRows`, `testSyncCategoryPresentationMatchesAndroidCategoryIcons`, and Sync Settings UI tests | Partial | Icons and some row metadata are source-backed, but the audited contract now requires stricter behavioral parity: Google Drive UI removal (#116), iCloud default positioning (#160), Android-visible category reconciliation (#158), and reset/status visibility after backend cleanup. |
| Sync settings UI persists backend and category state across reopen | `SyncSettingsView.swift`; UI tests `testSettingsSyncLinkOpensSyncSettings`, `testSyncSettingsCategoryToggleMutatesExportedState`, `testSyncSettingsCategoryDisablePersistsAcrossDirectReopen`, `testSyncSettingsMyDocumentsCategoryToggleStartsManualSyncPath`, `testSyncSettingsBackendSwitchMutatesVisibleSection`, `testSyncSettingsBackendSwitchPersistsAcrossDirectReopen` | Pass | The current gate covers persisted state and visible section changes. Tests need pruning/updating when #116 removes Google Drive. |
| Google Drive removal from iOS sync | `GoogleDriveAuthService.swift`, `GoogleDriveSyncAdapter.swift`, `RemoteSyncSynchronizationServiceFactory`, `SyncSettingsView.swift`, GoogleSignIn dependency, Google-focused tests, and OAuth docs | Partial | Current code still contains Google Drive. #116 is the source of truth: remove the selectable backend, auth UI, adapter/auth paths, tests, dependency, and OAuth setup docs unless a documented non-sync dependency remains. |
| iCloud remains the default iOS backend | `RemoteSyncBackend.iCloud`, `RemoteSyncSettingsStore.selectedBackend`, `SyncSettingsView.swift`, `dispositions.md`; tests `testRemoteSyncSettingsStoreDefaultsToICloudWhenBackendMissing`, `testRemoteSyncSettingsStoreFallsBackToICloudForUnknownBackendValue` | Adapted Pass | This is an intentional iOS platform extension. #160 extends the gate to removed `GOOGLE_DRIVE` values once #116 lands. |
| Adopt-versus-create confirmation branch | `SyncSettingsView.swift`; UI test `testSyncSettingsAdoptCreateConfirmationCreateChoiceSynchronizesFromVisibleWorkflow` | Pass | The focused workflow drives the visible adopt/create sheet, chooses the create-new cloud replacement branch, confirms the destructive reset-cloud alert, and waits for the selected category to finish enabled. |
