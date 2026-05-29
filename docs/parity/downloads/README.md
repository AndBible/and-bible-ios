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

Related issues:

- #120: Downloads list behavior and metadata parity
- #121: repository/source-management parity

Primary code references:

- `Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserView.swift`
- `Sources/BibleUI/Sources/BibleUI/Downloads/RepositoryManagerView.swift`
- `Sources/SwordKit/Sources/SwordKit/ModuleRepository.swift`
- `Sources/SwordKit/Sources/SwordKit/ModuleDownloadMetadata.swift`
