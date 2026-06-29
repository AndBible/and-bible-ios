# READER-701 Verification Matrix (Android Reader -> iOS)

Date: 2026-05-28

## Scope and Method

- Contract baseline: `docs/parity/reader/contract.md`
- Verification method:
  - direct code inspection of `BibleReaderView`, `BibleReaderController`, `BibleWindowPane`,
    `CrossReferenceView`, `HistoryView`,
    `WorkspaceSelectorView`, `WebViewCoordinator`, `DocumentBroker.vue`,
    `MultiDocument.vue`, `StrongsDocument.vue`, Vue `useModal`, and Android
    `BibleView` / `BibleJavascriptInterface`
  - simulator-backed UI coverage from `AndBibleUITests`
  - reader-adjacent unit regression coverage from `AndBibleTests`
- Regression evidence: `docs/parity/reader/regression-report.md`

Use this as a current snapshot, not as a claim that every reader detail is
already frozen forever.

The goal here is to make it easy to read the reader story in one pass: what now
feels solid, what is solid but intentionally iOS-shaped, and what is still more
trust than proof.

## Status Legend

- `Pass`: implemented and backed by direct code evidence plus current regression coverage
- `Adapted Pass`: parity is there, but the iOS path is intentionally different and called out in
  `dispositions.md`
- `Partial`: implemented or exposed, but still not backed by enough focused evidence to treat the
  area as truly locked

## Summary

- `Pass`: 12
- `Adapted Pass`: 1
- `Partial`: 1

## Matrix

| Reader Contract Area | iOS Evidence | Status | Notes |
|---|---|---|---|
| Reader shell routes primary destinations through the left drawer and reader-local options through the right overflow popup | `BibleReaderView.swift`; UI tests `testSettingsScreenShowsPrimaryNavigationRows`, `testDownloadsRepositoryManagerOpensFromOverflow`, `testBookmarkSelectionNavigatesReaderToSeededReference`, `testSettingsApplicationShortcutsOpenGlobalTextOptions` | Adapted Pass | This part now feels close to Android in day-to-day use, even though iOS gets there with native SwiftUI shells and an anchored popup instead of Android view classes. The Downloads smoke intentionally continues through the Android overflow to Custom repositories, the Bookmarks selection smoke proves drawer route ownership and row navigation, and the Settings shortcut smoke now also proves About remains reachable from the reader menu. |
| Reader sheets, modals, destinations, and transient dialogs are classified by ownership before parity is claimed | `modal-ownership-matrix.md`; ADR 0006; script guardrail `scripts/test_reader_modal_ownership_matrix.py` | Pass | This does not make every current route fully parity-complete. It locks the owner classification so follow-up issues can migrate the partial routes without re-litigating whether a SwiftUI sheet is automatically acceptable. |
| Reader document chooser opens the Android-style all-types module list from the drawer | `BibleReaderView.swift`, `BibleReaderModulePicker.swift`, `document-chooser-matrix.md`; unit tests `testBibleReaderModulePickerBuildsForBibleCategory`, `testBibleReaderModulePickerFiltersAndroidChooserCategoriesAndSearch`, `testBibleReaderModulePickerMapsAndroidDocumentTypeCategories` | Partial | The removed category-first sheet was drift. The remaining gaps are Android pseudo-doc rows, encrypted-module unlock prompts, and row context actions for about/delete/delete-index/unlock. |
| Search result selection returns control to the reader and moves the active reference | `BibleReaderView.swift`, `BibleReaderController.swift`; UI test `testSearchOptionControlsMutateVisibleState` | Pass | The reader side of search handoff is in a good place. The retained Search option-control workflow now finishes by selecting a deterministic result, while deeper query semantics still live under `docs/parity/search/`. |
| History jump-back plus destructive clear/delete flows persist through reopen | `HistoryView.swift`, `BibleReaderView.swift`, `BibleReaderController.swift`; UI test `testHistorySelectionNavigatesReaderToSeededReference`; package tests `HistoryListPresentationTests` | Pass | This now protects the live jump back into the reader at UI level and the more failure-prone destructive persistence paths in app-host-free package coverage. |
| Workspace selection and switching remain coordinated by the reader shell | `BibleReaderView.swift`, `WorkspaceSelectorView.swift`, `WindowManager`; UI test `testWorkspaceSelectorCreateAndSwitchFlow` | Pass | The current check is doing useful work here: it covers creation, activation, and a clean return to the reader shell, not just low-level persistence. |
| Restored reading position avoids stale verse highlighting while explicit verse navigation preserves its target highlight | `BibleReaderController.swift`; unit tests `testLoadCurrentContentDoesNotHighlightRestoredReadingPosition`, `testLoadCurrentContentHighlightsExplicitVerseNavigationTarget` | Pass | This is a small detail, but it is a very visible one when it breaks, so it is good to have it locked at the payload-emission layer. |
| Strong's / dictionary content routes through the shared document/window pipeline while keeping the dedicated Strong's document path | `BibleReaderController.buildStrongsMultiDocJSON()`, `BibleReaderController.loadDefinitionDocument(...)`, `BibleWindowPane.configureController()`, `DocumentBroker.vue`, `StrongsDocument.vue`, `TabNavigation.vue`; unit tests `testStrongsLinkEmitsVueDocumentInsteadOfNativeSheet` and `testStrongsLinkUsesLinksWindowRoutingCallbackWhenAvailable` | Pass | iOS now emits Vue `MultiDocument` payloads with `contentType: "strongs"` and uses the same links-window routing decision as other linked document content, instead of presenting the removed native sheet. |
| Horizontal swipe modes and auto-fullscreen thresholds are implemented natively | `WebViewCoordinator.swift` native swipe/scroll callbacks; `BibleReaderView.handleHorizontalSwipe(...)`; `BibleReaderInteractionPolicies.swift`; unit tests `testReaderHorizontalSwipePolicyMapsConfiguredModes`, `testAutoFullscreenPolicyAccumulatesThresholdByDirection`, `testAutoFullscreenPolicyHonorsDisabledAndDoubleTapLock` | Pass | The base gesture callbacks stay native and the decision logic is covered at the policy layer. Modal-open blocking is tracked separately in the Vue modal state row. |
| Double-tap fullscreen remains owned by the native reader shell | `BibleBridge.dispatchMessage(method:args:)`, `BibleReaderController.bridgeDidRequestToggleFullScreen(...)`, `BibleReaderView` fullscreen state/overlay ownership; unit test `testDoubleTapFullscreenPreferenceGateControlsNativeToggleRequest`; documented in `dispositions.md` | Pass | The bridge path now has focused coverage proving the `double_tap_to_fullscreen` preference gate is honored before native fullscreen state changes. |
| Compare requests route through the shared document/window pipeline | `BibleReaderController.compareSelection()`, `BibleReaderController.bridge(_:compareVerses:startOrdinal:endOrdinal:)`, `BibleReaderController.loadCompareDocument(startVerse:endVerse:)`, `MultiDocument.vue`; unit test `testReaderCompareBridgeRequestEmitsVueCompareDocument`; tracked by #123 | Pass | iOS now builds the Android-style fake compare document payload with `compare: true`, one Bible fragment per installed module, hidden-translation state handled through shared Vue config, and no native Compare sheet route. |
| Multi-reference and cross-reference links route through the shared document pipeline | Current iOS: `BibleReaderController.handleOsisLink(...)`, `BibleReaderController.handleMultiLink(...)`, `BibleReaderController.buildBibleMultiReferenceDocumentJSON(...)`; unit tests `testMultiReferenceLinkEmitsVueMultiDocumentInsteadOfCrossReferenceSheet`, `testMultiReferenceOsisLinkEmitsVueMultiDocumentInsteadOfCrossReferenceSheet`, `testOsisRangeLinkExpandsEveryVerseInVueMultiDocument`; Android/Vue: `multi://`, fake multi document, `OpenAllLink.vue`, `MultiDocument.vue`; completed by #124 / PR #128 | Pass | Multi-reference routes now emit the embedded Vue `MultiDocument` path while preserving single-reference navigation behavior. The legacy `CrossReferenceView` callback remains documented in the modal ownership matrix so it is not treated as an acceptable replacement for document-pipeline routing. |
| Vue modal-open state blocks native reader host navigation | `BibleReaderController.webModalIsOpen`, `BibleReaderController.closeWebModalIfNeeded()`, `BibleReaderView.handleHorizontalSwipe(...)`, `BibleReaderKeyboardShortcuts`, `BibleReaderInteractionPolicies.swift`; Android/Vue: `useModal`, `reportModalState`, `BibleView.modalOpen`, `close_modals`; unit tests `testReaderBridgeModalStateBlocksKeyNavigationAndRequestsClose`, `testReaderHorizontalSwipePolicyMapsConfiguredModes` | Pass | iOS now records modal state per pane, blocks native header/keyboard/swipe and bridge-forwarded chapter navigation while Vue owns the interaction, and sends `close_modals` for the native cancel equivalent. |
| Reader config pushes active-window and display state into the embedded client | `BibleReaderController.buildConfigJSON()`, `BibleReaderController.updateConfig()`, `BibleReaderView.updateDisplaySettings(...)`; unit tests `testReaderConfigPayloadIncludesDisplaySettingsAndActiveWindowState`, `testReaderConfigPayloadMarksInactiveWindowWithoutActiveIndicator` | Pass | Focused payload-level coverage now locks the config/appSettings key shape, representative display settings, app preference values, workspace label state, and active/inactive window indicator behavior. |
