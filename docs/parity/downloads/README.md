# Downloads Parity

This directory tracks Android parity for the module download and repository
surfaces.

The Downloads list is not a shared Vue document surface on Android. Android
uses `DownloadActivity`, which extends the shared native
`DocumentSelectionBase` list machinery and adds download-specific row metadata,
refresh, status, and source-management actions. iOS can therefore stay native
for this surface, but its observable list behavior should match Android unless
a documented platform constraint exists.

## Reading Order

1. [module-browser-list-matrix.md](module-browser-list-matrix.md): iOS
   `ModuleBrowserView` versus Android `DownloadActivity` and
   `DocumentDownloadItemAdapter`
2. [repository-source-management-matrix.md](repository-source-management-matrix.md):
   iOS `RepositoryManagerView` versus Android `RepoFactory`,
   `CustomRepositories`, and `CustomRepositoryEditor`

Related issues:

- #120: Downloads list behavior and metadata parity
- #121: repository/source-management parity
- #133: startup/default-document flow using `default_documents_v2.json`
- #134: active download progress, cancel, and error/retry row state
- #135: row actions for about/delete index/unlock
- #136: Android add-ons filter/modeling
- #138: MyBible custom repository support
- #139: Android custom repository metadata persistence

Primary code references:

- `Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserView.swift`
- `Sources/BibleUI/Sources/BibleUI/Downloads/RepositoryManagerView.swift`
- `Sources/SwordKit/Sources/SwordKit/ModuleRepository.swift`
- `Sources/SwordKit/Sources/SwordKit/ModuleDownloadMetadata.swift`
