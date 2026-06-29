# Reader Modal Ownership Matrix

Date: 2026-06-23

## Intent

This matrix applies [ADR 0006](../../adr/0006-modal-presentation-ownership-for-android-parity.md)
to the reader shell. Its purpose is to classify the current iOS reader
presentations before future PRs preserve, migrate, or replace SwiftUI sheets.

The matrix is not a blanket approval of every current sheet. It separates:

- app-owned Android surfaces that iOS may present with native app UI when the
  behavior and visual information architecture match
- WebView-owned or shared-document flows that should move through the embedded
  client instead of native SwiftUI sheets
- true platform boundaries such as iOS share UI
- known follow-up issues where the current route is still partial

## Source Baseline

iOS references:

- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/CrossReferenceView.swift`

Android references:

- `app/src/main/java/net/bible/android/view/activity/page/MainBibleActivity.kt`
- `app/src/main/java/net/bible/android/view/activity/page/MenuCommandHandler.kt`
- `app/src/main/java/net/bible/android/view/activity/page/BibleJavascriptInterface.kt`
- `app/src/main/java/net/bible/android/view/activity/navigation/ChooseDocument.kt`
- `app/src/main/java/net/bible/android/view/activity/base/DocumentSelectionBase.kt`
- `app/src/main/java/net/bible/android/view/activity/bookmark/ManageLabels.kt`

## Reader Sheet Routes

| iOS route token | Current iOS surface | ADR 0006 owner | Android owner or target | Disposition |
| --- | --- | --- | --- | --- |
| `ReaderSheet.history` | `HistoryView` in a reader sheet | `Android app-owned` | `History` activity and history manager | Adapted reader shell route with focused UI coverage for selection, clear, and delete. |
| `ReaderSheet.readingProgress` | Reader sheet for reading-progress status | `Android app-owned` | Reading-progress activity/settings surfaces | Adapted app-owned route; progress sync/status details remain in the sync and reading-progress docs. |
| `ReaderSheet.readingProgressSettings` | Reader sheet for reading-progress settings | `Android app-owned` | `ReadingProgressSettingsActivity` | Adapted app-owned settings route. |
| `ReaderSheet.chapterReadHistory` | Reader sheet for chapter read history | `Android app-owned` | Reading-progress/history support surfaces | Adapted app-owned route. Keep pane-target capture intact. |
| `ReaderSheet.workspaces` | `WorkspaceSelectorView` in a reader sheet | `Android app-owned` | `WorkspaceSelectorActivity` | Adapted reader shell route with UI coverage for create; durable switching behavior is package-covered. |
| `ReaderSheet.about` | About surface in a reader sheet | `Android app-owned` | Android app information/help menu surface | Acceptable app-owned informational route; verify labels/actions when touched. |

## Reader Destination Routes

| iOS route token | Current iOS surface | ADR 0006 owner | Android owner or target | Disposition |
| --- | --- | --- | --- | --- |
| `ReaderDestination.search` | `SearchView` pushed as a reader destination | `Android app-owned` | Android `Search` activity from `MenuCommandHandler` | Adapted app-owned route with UI coverage protecting destination presentation and translation-picker parity. |
| `ReaderDestination.bookmarks` | `BookmarkListView` pushed as a reader destination from drawer, pane, overflow, and shortcut routes | `Android app-owned` | Android `Bookmarks` activity from `MenuCommandHandler` | App-owned route with UI coverage protecting `readerSheet=none`, `readerDestination=bookmarks`, and no sheet Done chrome. Bookmarks must not be reintroduced as a `ReaderSheet` route. |
| `ReaderDestination.studyPads` | `LabelManagerView` configured for StudyPad selection from drawer and chooser routes | `Android app-owned` | Android `ManageLabels` with `Mode.STUDYPAD` from `MenuCommandHandler` | App-owned route with UI coverage protecting `readerSheet=none`, `readerModal=none`, `readerDestination=studyPads`, and no sheet Done chrome. Primary row selection opens the StudyPad document, matching Android's `studyPadSelected` path. StudyPads must not be reintroduced as a nested StudyPad selector modal. |
| `ReaderDestination.myDocuments` | `MyDocumentsListView` pushed as a reader destination from the drawer | `Android app-owned` | Android `MyDocumentsActivity` and `MyDocumentPagesActivity` from `MenuCommandHandler` | Drawer-owned app route with UI coverage protecting `readerSheet=none`, `readerModal=none`, `readerDestination=myDocuments`, document/page list navigation, and selected-page loading through the reader My Documents document pipeline. |
| `ReaderDestination.readingPlans` | `ReadingPlanListView` pushed as a reader destination from drawer, pane, and overflow routes | `Android app-owned` | Reading-plan list/selector activities | App-owned route with UI coverage protecting `readerSheet=none`, `readerDestination=readingPlans`, and no sheet Done chrome. Reading Plans must not be reintroduced as a `ReaderSheet` route. |
| `ReaderDestination.settings` | `SettingsView` pushed as a reader destination | `Android app-owned` | `SettingsActivity` from drawer/menu routing | Adapted app-owned route with Settings UI coverage. |
| `ReaderDestination.downloads` | `ModuleBrowserView` pushed as a reader destination | `Android app-owned` | `DownloadActivity` from drawer/chooser/startup flows | Adapted app-owned route. Repository/source and list details live in downloads docs. |
| `ReaderDestination.globalTextOptions` | `TextDisplaySettingsView` with global scope | `Android app-owned` | `TextDisplaySettingsActivity` with `SettingsLevel.GLOBAL` | App-owned settings route. Scope semantics are governed by settings docs and ADR 0005. |
| `ReaderDestination.workspaceTextOptions` | `TextDisplaySettingsView` with workspace scope | `Android app-owned` | Reader All Text Options / `SettingsLevel.WORKSPACE` | App-owned settings route. Workspace color behavior is governed by ADR 0005. |
| `ReaderDestination.windowTextOptions` | `TextDisplaySettingsView` with window scope | `Android app-owned` | Window popup text options / `SettingsLevel.WINDOW` | App-owned settings route. |
| `ReaderDestination.windowColorSettings` | `ColorSettingsView` with window settings | `Android app-owned` | `ColorSettingsActivity` for window colors | App-owned settings route. Editor widget parity is tracked by #248. |

## Reader Modal Routes

| iOS route token | Current iOS surface | ADR 0006 owner | Android owner or target | Disposition |
| --- | --- | --- | --- | --- |
| `ReaderModal.syncSettings` | `SyncSettingsView` in a coordinator modal | `Android app-owned` | `SyncSettingsActivity` | Adapted app-owned settings route. |
| `ReaderModal.importExport` | `ImportExportView` in a coordinator modal | `Android app-owned` plus `iOS system boundary` | Android backup/import/export flows plus OS file/share intents | App-owned route may use native iOS file/share boundaries only at OS handoff points. |
| `ReaderModal.speakControls` | `SpeakControlView` with detents | `Android app-owned` | Android speak transport/activity/widget | Adapted app-owned route; transport semantics must remain reader/pane-aware. |
| `ReaderModal.modulePicker` | Category-scoped `BibleReaderModulePicker` in the full-screen document chooser presenter | `Android app-owned` | `ChooseDocument` with type extra | App-owned full-screen route. Remaining encrypted unlock behavior is documented in the chooser matrix. |
| `ReaderModal.dictionaryBrowser` | Dictionary browser modal | `Android app-owned` | Android dictionary/key selection surfaces | Adapted app-owned browser route. Verify key-selection behavior when touched. |
| `ReaderModal.generalBookBrowser` | General-book browser modal | `Android app-owned` | Android general-book/key selection surfaces | Adapted app-owned browser route. Verify key-selection behavior when touched. |
| `ReaderModal.mapBrowser` | Map browser modal | `Android app-owned` | Android map/key selection surfaces | Adapted app-owned browser route. Verify key-selection behavior when touched. |
| `ReaderModal.epubLibrary` | EPUB library modal | `Android app-owned` | Android EPUB library/search surfaces | Adapted app-owned route. EPUB-specific parity belongs in EPUB follow-ups. |
| `ReaderModal.epubBrowser` | EPUB browser modal | `Android app-owned` | Android EPUB document browser | Adapted app-owned route. |
| `ReaderModal.epubSearch` | EPUB search modal | `Android app-owned` | Android EPUB search activity | Adapted app-owned route. |
| `ReaderModal.labelManager` | `LabelManagerView` from overflow | `Android app-owned` | `ManageLabels` activity | Partial. Label/StudyPad ownership details are tracked by #246. |
| `ReaderModal.chooseDocument` | All-types `BibleReaderModulePicker` in the full-screen document chooser presenter | `Android app-owned` | `ChooseDocument` without a type extra | App-owned full-screen route. Remaining encrypted unlock behavior is documented in the chooser matrix. |
| `ReaderModal.help` | `HelpView` in a coordinator modal | `Android app-owned` | Android help dialog/activity surfaces | Adapted informational route. Vue-scoped help remains bridge-owned when invoked from Vue. |

## Standalone Transient Routes

| iOS route token | Current iOS surface | ADR 0006 owner | Android owner or target | Disposition |
| --- | --- | --- | --- | --- |
| `showStartupDownloadPrompt` | SwiftUI `confirmationDialog` | `Android app-owned` | Android startup/download prompt dialogs | Acceptable dialog adaptation if labels, cancel/default behavior, and Downloads handoff remain equivalent. |
| `showReaderStrongsModeDialog` | SwiftUI `confirmationDialog` | `Android app-owned` | `StrongsPreference.openDialog` / Android option dialog | Acceptable dialog adaptation if choices, reset/default semantics, and preference mutation match Android. |
| `shareSheetBinding` | `ShareSheet` / `UIActivityViewController` | `iOS system boundary` | Android share intents/widgets | Acceptable platform boundary when it only hands selected/generated content to OS sharing. |
| `crossReferenceSheetBinding` | Legacy native `CrossReferenceView` sheet callback | `Vue/WebView-owned` | Android `multi://` and fake multi document through shared Vue `MultiDocument` | Multi-reference links already bypass this route through the Vue `MultiDocument` path. Do not expand the legacy sheet as a substitute for document-pipeline routing. |
| `showRefChooser` | `BookChooserView` sheet returned to a WebView callback | `Android app-owned` | `BibleJavascriptInterface.refChooserDialog` launching `GridChoosePassageBook` | Adapted app-owned chooser route. Keep async callback semantics and pane context intact. |
| `BibleReaderModulePicker.AndroidPseudoDocument.myNotes` | Embedded My Notes document loaded into the active reader pane from Choose Document | `Vue/WebView-owned` | Android `FakeBookFactory` My Note pseudo-document in `ChooseDocument` | Chooser-owned pseudo-document route with visible My Notes lifecycle coverage. Drawer My Notes/My Documents must instead route through `ReaderDestination.myDocuments` and Android's app-owned My Documents manager contract. |

## Maintenance Guardrail

`scripts/test_reader_modal_ownership_matrix.py` verifies that every current
`ReaderSheet`, `ReaderDestination`, and `ReaderModal` enum case appears in this
matrix. When a new reader presentation route is added, classify it here before
claiming parity. It also prevents Bookmarks, StudyPads, and Reading Plans from
returning to legacy iOS sheet/modal routes after their Android app-owned
destination migration.
