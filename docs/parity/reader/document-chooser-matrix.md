# Reader Document Chooser Parity Matrix

Date: 2026-05-28

## Intent

Android/iOS parity means matching the user-visible behavior of Android's
`ChooseDocument` flow where the platforms have a reasonable shared path. Native
iOS presentation is allowed only as a shell around the same decisions; it is not
a reason to keep a different chooser model. Any remaining deviation below is a
known gap or an explicit adaptation, not a new parity target definition.

## Baseline

Android references:

- `../and-bible/app/src/main/java/net/bible/android/view/activity/navigation/ChooseDocument.kt`
- `../and-bible/app/src/main/java/net/bible/android/view/activity/base/DocumentSelectionBase.kt`

iOS references:

- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift`
- `AndBibleTests/AndBibleTests.swift`

## Matrix

| Behavior | Android | iOS Status | Notes |
|---|---|---|---|
| Drawer Choose Document entry | Opens `ChooseDocument` directly without a type extra, so the document type spinner starts at all types. | Pass | The reader `.chooseDocument` route now presents `BibleReaderModulePicker` directly with `startsWithAllTypes: true`; the removed category-first Swift sheet was Android drift. |
| Category-specific picker entry | Bible/commentary launches pass a type extra and start the spinner on that category. | Pass | The existing module picker route still starts on the requested category unless the caller explicitly asks for all types. |
| Document type filters | Shows all types, Bible, commentary, dictionary, books, maps, and add-ons. | Partial | iOS now exposes all installed Bible/commentary/dictionary/general-book/map modules in one chooser. Add-ons and Android pseudo-document rows are not represented by the current `ModuleInfo` model. |
| Language default and sorting | Starts on all languages and sorts language names alphabetically. | Pass | iOS starts with the empty all-language filter and builds alphabetized display names from the full installed chooser dataset. |
| Search focus behavior | Entering search clears the selected language and moves document type to all types. | Pass | iOS clears both filters when non-empty search begins. |
| Search implementation | Uses Android's document search DAO for query matching. | Adapted | iOS searches installed module initials, descriptions, language, localized language, and category text in memory. This is acceptable for the current installed-only chooser, but should be revisited if iOS gains Android's full document search index. |
| Row ordering | Installed/recommended state is considered before category and abbreviation ordering. | Adapted | iOS chooser rows are installed-only, so it sorts by Android category order and localized module initials. Remote repository ordering remains Downloads-owned. |
| Locked encrypted documents | Selection attempts Android unlock before accepting the document. | Gap | iOS shows a lock affordance for encrypted locked modules but does not yet have the Android-equivalent unlock prompt/cipher-key coordinator in this chooser. |
| Pseudo-documents | Visible pseudo-documents are included, while `AND_BIBLE` pseudo-doc selections are ignored. | Gap | iOS has no pseudo-document row source in `ModuleInfo`; adding this requires a distinct model/source before it can be behaviorally matched. |
| About/delete/delete-index actions | Long-press action mode exposes about, delete, delete index, and unlock actions where applicable. | Gap | iOS has no row context-action parity yet. This should be implemented only when it can mutate modules through the same repository/module-management services used elsewhere. |
| Downloads handoff | Toolbar Downloads opens `DownloadActivity`; returning reloads the document list. | Pass | iOS exposes a persistent Downloads toolbar action and refreshes installed modules when the Downloads sheet closes. |
| Selection result | Returns selected initials to the reader, which updates the active document. | Adapted Pass | iOS switches the active pane controller directly. Dictionary/general-book/map selections still open their content browsers after switching, matching the existing reader category behavior. |

## Follow-Up Targets

- Add Android pseudo-document row support when iOS has a model/source for visible pseudo-documents.
- Add encrypted-module unlock parity instead of only displaying lock state.
- Add row context actions for about/delete/delete-index/unlock, backed by real module mutation services.
- Revisit search if iOS adopts Android's indexed document search semantics for chooser rows.
