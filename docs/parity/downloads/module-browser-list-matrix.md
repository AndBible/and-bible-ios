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
| Entry points | Reader menu and startup flows open `DownloadActivity`; `download://` links can target module initials. | Partial | Reader `download://?initials=...` handoff seeds iOS search and starts on All types. Android startup/default-document flow is separate follow-up work. |
| Document type filters | Spinner exposes All, Bible, commentary, dictionary, books, maps, and add-ons. | Partial | iOS now exposes All, Bible, commentary, dictionary, books, and maps. Add-ons remain missing because there is no iOS add-on module category/model yet. |
| Language filter | Android language autocomplete is populated from all documents and sorted by `DownloadControl.sortLanguages`. | Adapted Pass | iOS computes languages from installed and available modules, keeps English first, and preserves all-language selection. Exact Android relevant-language ranking is not implemented. |
| Free-text search | Android clears language/type filters when search gains focus and uses the document search DAO. | Adapted Pass | iOS uses SwiftUI `.searchable` over initials, description, language, and source. Non-empty search clears type/language filters, and `download://?initials=...` pre-populates search on All types. |
| Refresh behavior | Swipe refresh reloads metadata JSON and repository lists, clears search, and updates stale-repo state. | Partial | iOS refresh reloads repository catalogs, pseudo/unavailable metadata, recommended metadata, bad-document metadata, and default metadata. It does not yet implement swipe refresh, stale-date messaging, or search clearing on refresh. |
| Recommended metadata | `recommended_documents_v2.json` marks rows and affects ordering when a language filter is active. | Pass | iOS now caches/refreshes the same JSON, shows a Recommended badge, and sorts recommended rows first for a concrete language. |
| Bad-document metadata | `bad_documents.json` can warn (`W`) or hide (`H`) matching module/repository/version rows. | Pass | iOS now caches/refreshes the same JSON, hides `H` rows, and shows a warning badge for `W` rows. |
| Default metadata | `default_documents_v2.json` drives Android's `download-recommended` startup/default flow. | Missing | iOS can cache/refresh the JSON opportunistically, but no startup/default auto-download flow consumes it yet. Refresh failures are not surfaced until #133 adds a consumer. |
| Pseudo/unavailable documents | `pseudo_books.json` creates unavailable Bible rows with explanatory text. | Pass | iOS already maps pseudo books to unavailable remote rows and now keeps them in the sorted list. |
| Installed state | Android rows show installed status using `DownloadControl.getDocumentStatus`. | Adapted Pass | iOS resolves installed rows from `SwordManager`, sorts them before normal installable rows, shows a checkmark, and exposes uninstall through row swipe/context actions. Like Android `DownloadActivity`, this view only shows modules present in the active download catalog. |
| Update state | Android compares repository and installed versions and shows upgrade state before installed rows. | Pass | iOS now carries remote versions into `RemoteModuleInfo`, detects newer versions, sorts update rows ahead of installed rows, and offers an Update action. |
| Install unavailable state | Android disables pseudo/unavailable rows and marks them visually. | Pass | iOS unavailable rows show a disabled lock affordance and no install action. |
| In-progress state | Android shows progress, cancel, and download events through `DocumentDownloadItemAdapter`. | Partial | iOS tracks installing module initials and shows progress, but does not expose percent progress, cancel, or error-retry state. |
| Row metadata | Android rows show initials, name, language, repository, size, lock/recommended/warning icons. | Partial | iOS rows show initials, description, language, repository, install size, recommended/warning badges, unavailable/update/install/installed state. Encrypted lock/unlock handling is still broader module-management work. |
| Row actions | Android row tap downloads/updates, about button opens about, long press exposes delete/delete index/unlock. | Partial | iOS installs/updates from row buttons and uninstalls installed rows from swipe/context actions. About, delete index, unlock, and Android-style confirmation breadth are not complete. |
| Sorting | Android sorts being-installed, update, installed, recommended-for-language, category order, then abbreviation. | Pass | iOS now applies the same visible ordering dimensions to remote rows. |

## Follow-Ups

- Add the Android startup/default-document download flow that consumes
  `default_documents_v2.json` (#133).
- Add percent progress, cancel, and error state parity for active downloads
  (#134).
- Add row action parity for about/delete index/unlock and Android confirmation
  messages (#135).
- Add iOS add-on modeling before exposing Android's Add-ons filter (#136).
- #121 owns repository/source editing parity.
