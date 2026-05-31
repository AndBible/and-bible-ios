# Downloads Repository Source Management Matrix

Issue: #121

This matrix compares iOS repository/source management against Android's custom
repository flow. It covers configured sources, custom repository add/edit/delete
behavior, duplicate handling, unsupported protocols, persistence, reset/default
behavior, and user-facing help/error messaging. Downloads list rendering and
install state remain in the module browser matrix.

Android references:

- [RepoFactory.kt](https://github.com/AndBible/and-bible/blob/current-stable/app/src/main/java/net/bible/service/download/RepoFactory.kt)
- [CustomRepositories.kt](https://github.com/AndBible/and-bible/blob/current-stable/app/src/main/java/net/bible/android/view/activity/download/CustomRepositories.kt)
- [CustomRepositoryEditor.kt](https://github.com/AndBible/and-bible/blob/current-stable/app/src/main/java/net/bible/android/view/activity/download/CustomRepositoryEditor.kt)
- [CustomRepository.kt](https://github.com/AndBible/and-bible/blob/current-stable/app/src/main/java/net/bible/android/database/CustomRepository.kt)
- [DownloadActivity.kt](https://github.com/AndBible/and-bible/blob/current-stable/app/src/main/java/net/bible/android/view/activity/download/DownloadActivity.kt)

iOS references:

- `Sources/BibleUI/Sources/BibleUI/Downloads/RepositoryManagerView.swift`
- `Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserView.swift`
- `Sources/SwordKit/Sources/SwordKit/RepositorySourceManager.swift`
- `Sources/SwordKit/Sources/SwordKit/InstallManager.swift`
- `Sources/SwordKit/Sources/SwordKit/ModuleRepository.swift`

## Matrix

| Area | Android Behavior | iOS Status | Notes |
|---|---|---|---|
| Default and beta source coverage | `RepoFactory` exposes normal repositories first, then beta repositories, then custom repositories. | Pass | `InstallManager` seeds the same Android normal/beta repository names into `InstallMgr.conf`; the iOS manager renders these as read-only built-in rows. |
| Custom repository list | Android's `CustomRepositories` screen lists only DAO-backed custom repositories and has a create/help empty state. | Adapted Pass | iOS shows built-in and custom sections together because Downloads also exposes packaged SWORD defaults, but only custom rows from `InstallMgr.conf` or `CustomRepositories.json` can be edited or deleted. |
| Custom repository add flow | Android accepts one HTTPS manifest/spec URL, tries that URL, then `manifest.json`, then a direct SWORD catalog fallback. | Pass | `RepositorySourceManager` follows the same HTTPS-only validation order, writes successful SWORD sources to `InstallMgr.conf`, and stores Android MyBible specs in the custom metadata sidecar. |
| Custom repository edit flow | Android opens the selected custom repository in `CustomRepositoryEditor` and saves replacement data. | Adapted Pass | iOS custom rows open the same single-URL editor and replace the persisted source row or sidecar record after validation while retaining manifest URL/type/description/package-directory context. |
| Duplicate validation | Android rejects names already present in JSword installers and relies on a unique Room index for custom rows. | Pass | iOS resolves the custom URL first, then rejects names already present in default, beta, FTP, or custom config rows. |
| Unsupported protocols | Android requires `https://` for custom repositories. | Pass | iOS also requires HTTPS for custom additions. The legacy default FTP row remains visible as unsupported and continues to be skipped by catalog refresh. |
| Persistence model | Android persists `CustomRepository` rows with name, description, type, host, catalog directory, package directory, and manifest URL. | Adapted Pass | iOS keeps SWORD refresh rows in `InstallMgr.conf` and mirrors Android custom metadata in `CustomRepositories.json`, including description, type, package directory, manifest URL, and source URL for edit/delete round-tripping. Legacy source-only custom SWORD rows are backfilled into the sidecar from their host/catalog tuple, with the direct-catalog package directory inferred as `catalogDirectory/packages`. |
| Delete behavior | Android deletes DAO-backed custom rows and confirms delete from the editor. | Adapted Pass | iOS protects built-in rows, confirms destructive custom deletion, and removes matching custom rows from both `InstallMgr.conf` and `CustomRepositories.json`. |
| Reset/default behavior | Android defaults are code-defined and not user-deletable from the custom repository screen. | Documented iOS Accommodation | iOS keeps a reset action as a repair path for source configuration; it removes custom config and metadata, then recreates the packaged Android source list. |
| Help and errors | Android shows a custom repositories help dialog with a wiki link and toasts duplicate/save errors. | Adapted Pass | iOS exposes the same wiki link from the manager toolbar and keeps validation/persistence errors visible in the editor or alert. |
| MyBible custom repositories | Android accepts `MyBibleRepositorySpec` JSON and persists `mybible-https` rows. | Adapted Pass | iOS accepts the same manifest shape, persists `mybible-https` metadata without projecting it into SWORD config, exposes HTTPS package rows in Downloads, and installs MyBible SQLite payloads into a non-SWORD sidecar store. |
| Downloads integration | Android reloads documents after returning from custom repository management. | Pass | iOS posts a source-change notification after config or metadata writes; `ModuleBrowserView` reloads its source list for the next catalog refresh. |

## Follow-Ups

- Full reader-surface integration for installed non-SWORD MyBible packages remains outside the
  repository-source management matrix; this matrix covers accepting, persisting, listing,
  installing, and uninstalling repository-backed MyBible packages from Downloads.
