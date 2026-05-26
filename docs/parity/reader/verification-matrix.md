# READER-701 Verification Matrix (Android Reader -> iOS)

Date: 2026-05-25

## Scope and Method

- Contract baseline: `docs/parity/reader/contract.md`
- Verification method:
  - direct code inspection of `BibleReaderView`, `BibleReaderController`, `BibleWindowPane`,
    `CompareView`, `CrossReferenceView`, `StrongsSheetView`, `HistoryView`,
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

- `Pass`: 8
- `Adapted Pass`: 1
- `Partial`: 3

## Matrix

| Reader Contract Area | iOS Evidence | Status | Notes |
|---|---|---|---|
| Reader shell routes primary destinations through the left drawer and reader-local options through the right overflow popup | `BibleReaderView.swift`; UI tests `testSettingsScreenShowsPrimaryNavigationRows`, `testDownloadsScreenOpensFromReaderMenu`, `testBookmarksScreenOpensFromReaderMenu`, `testAboutScreenOpensFromReaderMenu` | Adapted Pass | This part now feels close to Android in day-to-day use, even though iOS gets there with native SwiftUI shells and an anchored popup instead of Android view classes. |
| Search result selection returns control to the reader and moves the active reference | `BibleReaderView.swift`, `BibleReaderController.swift`; UI test `testSearchResultSelectionNavigatesReaderToBundledReference` | Pass | The reader side of search handoff is in a good place. Search query semantics still live under `docs/parity/search/`. |
| History jump-back plus destructive clear/delete flows persist through reopen | `HistoryView.swift`, `BibleReaderView.swift`, `BibleReaderController.swift`; UI tests `testHistorySelectionNavigatesReaderToSeededReference`, `testHistoryClearRemovesSeededRowAcrossReopen`, `testHistoryRowDeletePreservesOtherRowsAcrossReopen` | Pass | This now protects both the jump back into the reader and the more failure-prone destructive persistence paths. |
| Workspace selection and switching remain coordinated by the reader shell | `BibleReaderView.swift`, `WorkspaceSelectorView.swift`, `WindowManager`; UI test `testWorkspaceSelectorCreateAndSwitchFlow` | Pass | The current check is doing useful work here: it covers creation, activation, and a clean return to the reader shell, not just low-level persistence. |
| Restored reading position avoids stale verse highlighting while explicit verse navigation preserves its target highlight | `BibleReaderController.swift`; unit tests `testLoadCurrentContentDoesNotHighlightRestoredReadingPosition`, `testLoadCurrentContentHighlightsExplicitVerseNavigationTarget` | Pass | This is a small detail, but it is a very visible one when it breaks, so it is good to have it locked at the payload-emission layer. |
| Strong's / dictionary content keeps the dedicated Strong's document path, but routing still uses an iOS-native sheet | `BibleReaderController.buildStrongsMultiDocJSON()`, `StrongsSheetView.swift`, `DocumentBroker.vue`, `StrongsDocument.vue`, `TabNavigation.vue`; tracked by #8 | Partial | The richer embedded-client path is present, but the dedicated native sheet remains a confirmed routing drift. The intended endpoint is Vue/document-pipeline presentation, not preserving the native sheet. |
| Horizontal swipe modes and auto-fullscreen thresholds are implemented natively | `WebViewCoordinator.swift` native swipe/scroll callbacks; `BibleReaderView.handleHorizontalSwipe(...)`; `BibleReaderInteractionPolicies.swift`; unit tests `testReaderHorizontalSwipePolicyMapsConfiguredModes`, `testAutoFullscreenPolicyAccumulatesThresholdByDirection`, `testAutoFullscreenPolicyHonorsDisabledAndDoubleTapLock` | Pass | The base gesture callbacks stay native and the decision logic is covered at the policy layer. Modal-open blocking is tracked separately in the Vue modal state row. |
| Double-tap fullscreen remains owned by the native reader shell | `BibleBridge.dispatchMessage(method:args:)`, `BibleReaderController.bridgeDidRequestToggleFullScreen(...)`, `BibleReaderView` fullscreen state/overlay ownership; unit test `testDoubleTapFullscreenPreferenceGateControlsNativeToggleRequest`; documented in `dispositions.md` | Pass | The bridge path now has focused coverage proving the `double_tap_to_fullscreen` preference gate is honored before native fullscreen state changes. |
| Compare requests route through the shared document/window pipeline | Current iOS: `BibleReaderController.compareSelection()`, `BibleReaderController.bridge(_:compareVerses:startOrdinal:endOrdinal:)`, `presentCompareView(...)`, `CompareView.swift`; Android/Vue: fake compare document plus `MultiDocument.vue`; unit test `testReaderCompareBridgeRequestBuildsNativePresentationPayload`; tracked by #123 | Partial | Current coverage proves the bridge request reaches native presentation, but the native sheet is drift. The intended endpoint is Android's document-pipeline Compare flow, not preserving `CompareView`. |
| Multi-reference and cross-reference links route through the shared document pipeline | Current iOS: `BibleReaderController.handleOsisLink(...)`, `BibleReaderController.handleMultiLink(...)`, `BibleReaderView` cross-reference sheet, `CrossReferenceView.swift`; Android/Vue: `multi://`, fake multi document, `OpenAllLink.vue`, `MultiDocument.vue`; tracked by #124 | Partial | iOS still diverts multi-reference links into a native Swift sheet. The intended endpoint is the embedded Vue `MultiDocument` path while preserving single-reference navigation behavior, not preserving `CrossReferenceView`. |
| Vue modal-open state blocks native reader host navigation | `BibleReaderController.webModalIsOpen`, `BibleReaderController.closeWebModalIfNeeded()`, `BibleReaderView.handleHorizontalSwipe(...)`, `BibleReaderKeyboardShortcuts`, `BibleReaderInteractionPolicies.swift`; Android/Vue: `useModal`, `reportModalState`, `BibleView.modalOpen`, `close_modals`; unit tests `testReaderBridgeModalStateBlocksKeyNavigationAndRequestsClose`, `testReaderHorizontalSwipePolicyMapsConfiguredModes` | Pass | iOS now records modal state per pane, blocks native header/keyboard/swipe and bridge-forwarded chapter navigation while Vue owns the interaction, and sends `close_modals` for the native cancel equivalent. |
| Reader config pushes active-window and display state into the embedded client | `BibleReaderController.buildConfigJSON()`, `BibleReaderController.updateConfig()`, `BibleReaderView.updateDisplaySettings(...)`; unit tests `testReaderConfigPayloadIncludesDisplaySettingsAndActiveWindowState`, `testReaderConfigPayloadMarksInactiveWindowWithoutActiveIndicator` | Pass | Focused payload-level coverage now locks the config/appSettings key shape, representative display settings, app preference values, workspace label state, and active/inactive window indicator behavior. |
