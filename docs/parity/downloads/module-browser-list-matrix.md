# Downloads Module Browser List Matrix

Issue: #120

This matrix compares the iOS Downloads module browser against Android's
`DownloadActivity` list behavior. It covers the module/document list itself:
filters, search, metadata, row state, sorting, refresh, and install/update
actions. Repository editing remains in #121.

Android references:

- [DownloadActivity.kt](https://github.com/AndBible/and-bible/blob/current-stable/app/src/main/java/net/bible/android/view/activity/download/DownloadActivity.kt)
- [DocumentSelectionBase.kt](https://github.com/AndBible/and-bible/blob/current-stable/app/src/main/java/net/bible/android/view/activity/base/DocumentSelectionBase.kt)
- [DocumentDownloadItemAdapter.kt](https://github.com/AndBible/and-bible/blob/current-stable/app/src/main/java/net/bible/android/view/activity/download/DocumentDownloadItemAdapter.kt)
- [DocumentListItem.kt](https://github.com/AndBible/and-bible/blob/current-stable/app/src/main/java/net/bible/android/view/activity/download/DocumentListItem.kt)
- [DownloadControl.kt](https://github.com/AndBible/and-bible/blob/current-stable/app/src/main/java/net/bible/android/control/download/DownloadControl.kt)
- [FakeBookFactory.kt](https://github.com/AndBible/and-bible/blob/current-stable/app/src/main/java/net/bible/service/download/FakeBookFactory.kt)

iOS references:

- `Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserView.swift`
- `Sources/SwordKit/Sources/SwordKit/ModuleRepository.swift`
- `Sources/SwordKit/Sources/SwordKit/ModuleDownloadMetadata.swift`
- `Sources/SwordKit/Sources/SwordKit/InstallManager.swift`

## Matrix

| Area | Android Behavior | iOS Status | Notes |
|---|---|---|---|
| Entry points | Reader menu and startup flows open `DownloadActivity`; `download://` links can target module initials. | Adapted Pass | Reader `download://?initials=...` handoff seeds iOS search and starts on All types. When no Bible modules are installed, iOS presents a startup Downloads prompt over the reader shell; English Easy Start opens Downloads in default-document mode because iOS has no separate `StartupActivity` screen. |
| Document type filters | Spinner exposes All, Bible, commentary, dictionary, books, maps, and add-ons. Android's All filter excludes `BookCategory.AND_BIBLE`; add-ons are shown through the dedicated Add-ons filter. | Adapted Pass | iOS now models JSword's `AND_BIBLE` category as `ModuleCategory.addon` (`And Bible`) instead of folding those rows into another SWORD category. The Add-ons segment appears once loaded catalog rows contain add-ons, and the All filter excludes them to match Android. |
| Language filter | Android language autocomplete is populated from all documents and sorted by `DownloadControl.sortLanguages`. | Adapted Pass | iOS computes languages from installed and available modules, keeps English first, and preserves all-language selection. Exact Android relevant-language ranking is not implemented. |
| Free-text search | Android clears language/type filters when search gains focus and uses the document search DAO. | Adapted Pass | iOS uses SwiftUI `.searchable` over initials, description, language, and source. Non-empty search clears type/language filters, and `download://?initials=...` pre-populates search on All types. |
| Refresh behavior | Swipe refresh reloads metadata JSON and repository lists, clears search, and updates stale-repo state. | Partial | iOS refresh reloads repository catalogs, pseudo/unavailable metadata, recommended metadata, bad-document metadata, and default metadata. It does not yet implement swipe refresh, stale-date messaging, or search clearing on refresh. |
| Recommended metadata | `recommended_documents_v2.json` marks rows and affects ordering when a language filter is active. | Pass | iOS now caches/refreshes the same JSON, shows a Recommended badge, and sorts recommended rows first for a concrete language. |
| Bad-document metadata | `bad_documents.json` can warn (`W`) or hide (`H`) matching module/repository/version rows. | Pass | iOS now caches/refreshes the same JSON, hides `H` rows, and shows a warning badge for `W` rows. |
| Default metadata | `default_documents_v2.json` drives Android's `download-recommended` startup/default flow. | Adapted Pass | iOS refreshes or falls back to cached default metadata when English Easy Start opens Downloads, selects defaults in Android order for supported categories (Bibles, commentaries, add-ons, books, dictionaries, maps), skips installed/unavailable/missing rows, and auto-requests installs once. |
| Pseudo/unavailable documents | `pseudo_books.json` creates unavailable Bible rows with explanatory text. | Pass | iOS already maps pseudo books to unavailable remote rows and now keeps them in the sorted list. |
| Installed state | Android rows show installed status using `DownloadControl.getDocumentStatus`. | Adapted Pass | iOS resolves installed rows from `SwordManager`, sorts them before normal installable rows, shows a checkmark, and exposes uninstall through row swipe/context actions. Like Android `DownloadActivity`, this view only shows modules present in the active download catalog. |
| Update state | Android compares repository and installed versions and shows upgrade state before installed rows. | Pass | iOS now carries remote versions into `RemoteModuleInfo`, detects newer versions, sorts update rows ahead of installed rows, and offers an Update action. |
| Install unavailable state | Android disables pseudo/unavailable rows and marks them visually. | Pass | iOS unavailable rows show a disabled lock affordance and no install action. |
| In-progress state | Android shows progress, cancel, and download events through `DocumentDownloadItemAdapter`. | Adapted Pass | iOS now keeps per-module row activity with determinate staged-download progress, row cancel, and retained error/retry state. The Swift installer streams files and reports byte progress when the response exposes content length, then publishes staged data only after every required file succeeds. Both surfaces keep active downloads sorted first and clear cancelled rows back to normal installed/not-installed state. |
| Row metadata | Android rows show initials, name, language, repository, size, lock/recommended/warning icons. | Partial | iOS rows show initials, description, language, repository, install size, recommended/warning badges, unavailable/update/install/installed state. Encrypted lock/unlock handling is still broader module-management work. |
| Row actions | Android row tap downloads/updates, about button opens about, long press exposes delete/delete index/unlock. | Adapted Pass | iOS installs/updates from row buttons, exposes About through row/context actions, confirms uninstall from swipe/context actions, and confirms Delete Index for installed rows. Unlock is a documented deviation until SwordKit has a real persisted cipher-key coordinator. See [row-actions-matrix.md](row-actions-matrix.md). |
| Sorting | Android sorts being-installed, update, installed, recommended-for-language, category order, then abbreviation. | Pass | iOS now applies the same visible ordering dimensions to remote rows. |

## Follow-Ups

- Repository/source editing parity is documented in
  [repository-source-management-matrix.md](repository-source-management-matrix.md).
