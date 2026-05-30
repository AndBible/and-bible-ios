# Downloads Row Actions Matrix

Issue: #135

This matrix compares Android Downloads row actions against the iOS
`ModuleBrowserView` implementation.

Android references:

- `DocumentDownloadItemAdapter.kt`: row About button and install status controls
- `DocumentListItem.kt`: hides About while a row is being installed
- `DownloadActivity.kt`: contextual delete, delete index, and unlock visibility
- `DocumentSelectionBase.kt`: About, delete, and delete-index confirmation handlers
- `CommonUtils.kt`: encrypted-module unlock dialog and About metadata composition

iOS references:

- `Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserView.swift`
- `Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserRowActionPresentation.swift`
- `Sources/SwordKit/Sources/SwordKit/ModuleDownloadRowActionPlanner.swift`
- `Sources/BibleCore/Sources/BibleCore/Services/SearchIndexService.swift`
- `Sources/SwordKit/Sources/SwordKit/ModuleRepository.swift`

## Matrix

| Action | Android Behavior | iOS Status | Notes |
|---|---|---|---|
| About | Downloads rows expose an About button except while the row is actively installing; contextual action mode also includes About. Android reloads `SwordBookMetaData` so About can include copyright, version, and unlock info. | Adapted Pass | iOS now exposes an info action on non-installing rows and in the context menu. The sheet shows all remote and installed metadata currently modeled on iOS. Rich copyright/unlock text is limited by the current iOS catalog model. |
| Delete / uninstall | Installed rows expose `delete` when Android `installedDoc.canDelete`; confirmation asks before deleting and then reloads documents. | Adapted Pass | iOS installed catalog rows expose Uninstall through swipe and context menu, now behind confirmation before removing local SWORD module files and refreshing installed state. iOS does not currently model a separate `canDelete` flag, so installed rows are treated as removable. |
| Delete index | Android exposes `delete_index` for installed rows and confirms before calling `SwordDocumentFacade.deleteDocumentIndex`. | Pass | iOS now exposes Delete Index for installed rows and confirms before calling `SearchIndexService.deleteIndex(for:)`. Missing indexes are harmless, matching Android's installed-row visibility rather than pre-checking index existence. |
| Unlock | Android exposes Unlock for installed encrypted rows, prompts for a passphrase, persists the cipher key, and can show unlock info from About. | Documented Deviation | iOS can detect encrypted installed modules, but the current SWORD adapter only has a module-level cipher setter that is a no-op for the real API and no persisted cipher-key coordinator. iOS deliberately hides Unlock rather than presenting a nonfunctional action. True parity requires adding a real manager-level cipher-key path and persistence before surfacing the control. |
| Active install row | Android shows progress/cancel and hides the inline About button for `BEING_INSTALLED`. Installed management actions are still based on installed document state. | Pass | iOS hides inline About while active, keeps cancel/progress, and leaves installed management actions available through the shared planner when a local installed row exists. |

## Follow-Ups

- Add real encrypted-module unlock support after SwordKit exposes and persists a
  manager-level cipher-key coordinator.
- Expand the iOS catalog/about model if we need Android's richer copyright,
  distribution, and unlock-info text in the About sheet.
