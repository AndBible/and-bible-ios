# Reader Document Chooser Parity Matrix

Date: 2026-06-23

## Intent

Android/iOS parity means matching the user-visible behavior of Android's
`ChooseDocument` flow where the platforms have a reasonable shared path. Native
iOS presentation is allowed only as a shell around the same decisions; it is not
a reason to keep a different chooser model. Any remaining deviation below is a
known gap or an explicit adaptation, not a new parity target definition.

## Baseline

Android references:

- [ChooseDocument.kt](https://github.com/AndBible/and-bible/blob/current-stable/app/src/main/java/net/bible/android/view/activity/navigation/ChooseDocument.kt)
- [DocumentSelectionBase.kt](https://github.com/AndBible/and-bible/blob/current-stable/app/src/main/java/net/bible/android/view/activity/base/DocumentSelectionBase.kt)

iOS references:

- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift`
- `AndBibleTests/AndBibleTests+AppAndReader.swift`

## Matrix

| Behavior | Android | iOS Status | Notes |
|---|---|---|---|
| Drawer Choose Document entry | Opens `ChooseDocument` directly without a type extra, so the document type spinner starts at all types. | Pass | The reader `.chooseDocument` route now presents `BibleReaderModulePicker` directly with `startsWithAllTypes: true`; the removed category-first Swift sheet was Android drift. |
| Category-specific picker entry | Bible/commentary launches pass a type extra and start the spinner on that category. | Pass | The existing module picker route still starts on the requested category unless the caller explicitly asks for all types. |
| Document type filters | Shows all types, Bible, commentary, dictionary, books, maps, and add-ons. | Pass | iOS exposes all installed Bible/commentary/dictionary/general-book/map modules, hides add-ons from all types, and exposes installed add-ons from the Add-ons filter like Android's AND_BIBLE branch. |
| Language default and sorting | Starts on all languages and sorts language names alphabetically. | Pass | iOS starts with the empty all-language filter and builds alphabetized display names from the full chooser dataset. Add-ons survive concrete language filtering, matching Android's AND_BIBLE language exception. |
| Search focus behavior | Entering search clears the selected language and moves document type to all types. | Pass | iOS clears both filters when non-empty search begins. |
| Search implementation | Uses Android's document search DAO for query matching. | Adapted | iOS searches installed module and pseudo-document initials, descriptions, language, localized language, and category text in memory. This is acceptable for the current app-owned chooser, but should be revisited if iOS gains Android's full document search index. |
| Row ordering | Installed/recommended state is considered before category and abbreviation ordering. | Adapted Pass | iOS chooser rows are installed or built-in pseudo rows, so it mirrors Android's installed-before-fake, category, and initials ordering. Remote repository and actively installing states remain Downloads-owned. |
| Locked encrypted documents | Selection attempts Android unlock before accepting the document. | Gap | iOS shows a lock affordance for encrypted locked modules but does not yet have the Android-equivalent unlock prompt/cipher-key coordinator in this chooser. |
| Pseudo-documents | Visible pseudo-documents are included; hidden Memorize and non-chooser Multi are excluded. | Pass | iOS now adds My Notes, StudyPad/Journal, and Compare rows from an explicit Android pseudo-document model, maps them to existing reader routes, excludes Memorize because Android marks it `HideFromSelector=1`, and excludes Multi because Android does not include it in `FakeBookFactory.pseudoDocuments`. |
| About/delete/delete-index actions | Long-press action mode exposes about, delete, delete index, and unlock actions where applicable. | Partial Pass | iOS installed-module rows expose About, Uninstall, and Delete Index through the same presentation and module-management services used by Downloads. Unlock remains hidden because iOS still lacks a real cipher-key coordinator. |
| Downloads handoff | Toolbar Downloads opens `DownloadActivity`; returning reloads the document list. | Pass | iOS exposes a persistent Downloads toolbar action and refreshes installed modules when the Downloads sheet closes. |
| Selection result | Returns selected initials to the reader, which updates the active document. | Adapted Pass | iOS switches the active pane controller directly. Dictionary/general-book/map selections still open their content browsers after switching, matching the existing reader category behavior. |

## Follow-Up Targets

- Add encrypted-module unlock parity instead of only displaying lock state.
- Revisit search if iOS adopts Android's indexed document search semantics for chooser rows.
