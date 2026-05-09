# READER-701 Verification Matrix (Android Reader -> iOS)

Date: 2026-05-08

## Scope and Method

- Contract baseline: `docs/parity/reader/contract.md`
- Verification method:
  - direct code inspection of `BibleReaderView`, `BibleReaderController`, `BibleWindowPane`,
    `StrongsSheetView`, `HistoryView`, `WorkspaceSelectorView`, `WebViewCoordinator`,
    `DocumentBroker.vue`, and `StrongsDocument.vue`
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

- `Pass`: 7
- `Adapted Pass`: 1
- `Partial`: 2

## Matrix

| Reader Contract Area | iOS Evidence | Status | Notes |
|---|---|---|---|
| Reader shell routes primary destinations through the left drawer and reader-local options through the right overflow popup | `BibleReaderView.swift`; UI tests `testSettingsScreenShowsPrimaryNavigationRows`, `testDownloadsScreenOpensFromReaderMenu`, `testBookmarksScreenOpensFromReaderMenu`, `testAboutScreenOpensFromReaderMenu` | Adapted Pass | This part now feels close to Android in day-to-day use, even though iOS gets there with native SwiftUI shells and an anchored popup instead of Android view classes. |
| Search result selection returns control to the reader and moves the active reference | `BibleReaderView.swift`, `BibleReaderController.swift`; UI test `testSearchResultSelectionNavigatesReaderToBundledReference` | Pass | The reader side of search handoff is in a good place. Search query semantics still live under `docs/parity/search/`. |
| History jump-back plus destructive clear/delete flows persist through reopen | `HistoryView.swift`, `BibleReaderView.swift`, `BibleReaderController.swift`; UI tests `testHistorySelectionNavigatesReaderToSeededReference`, `testHistoryClearRemovesSeededRowAcrossReopen`, `testHistoryRowDeletePreservesOtherRowsAcrossReopen` | Pass | This now protects both the jump back into the reader and the more failure-prone destructive persistence paths. |
| Workspace selection and switching remain coordinated by the reader shell | `BibleReaderView.swift`, `WorkspaceSelectorView.swift`, `WindowManager`; UI test `testWorkspaceSelectorCreateAndSwitchFlow` | Pass | The current check is doing useful work here: it covers creation, activation, and a clean return to the reader shell, not just low-level persistence. |
| Restored reading position avoids stale verse highlighting while explicit verse navigation preserves its target highlight | `BibleReaderController.swift`; unit tests `testLoadCurrentContentDoesNotHighlightRestoredReadingPosition`, `testLoadCurrentContentHighlightsExplicitVerseNavigationTarget` | Pass | This is a small detail, but it is a very visible one when it breaks, so it is good to have it locked at the payload-emission layer. |
| Strong's / dictionary modal uses the dedicated Strong's document path with per-dictionary tabs and recursive in-modal navigation | `BibleReaderController.buildStrongsMultiDocJSON()`, `StrongsSheetView.swift`, `DocumentBroker.vue`, `StrongsDocument.vue`, `TabNavigation.vue` | Partial | The richer modal path is there now and it feels much better, but we are still leaning on implementation confidence more than focused regression coverage for this surface. |
| Horizontal swipe modes and auto-fullscreen thresholds are implemented natively | `WebViewCoordinator.swift` native swipe/scroll callbacks; `BibleReaderView.handleHorizontalSwipe(...)`; `BibleReaderInteractionPolicies.swift`; unit tests `testReaderHorizontalSwipePolicyMapsConfiguredModes`, `testAutoFullscreenPolicyAccumulatesThresholdByDirection`, `testAutoFullscreenPolicyHonorsDisabledAndDoubleTapLock` | Pass | The gesture callbacks still stay native, while the decision logic is now covered at the policy layer instead of depending on flaky web-view gesture timing. |
| Double-tap fullscreen remains owned by the native reader shell | `BibleBridge.dispatchMessage(method:args:)`, `BibleReaderController.bridgeDidRequestToggleFullScreen(...)`, `BibleReaderView` fullscreen state/overlay ownership; unit test `testDoubleTapFullscreenPreferenceGateControlsNativeToggleRequest`; documented in `dispositions.md` | Pass | The bridge path now has focused coverage proving the `double_tap_to_fullscreen` preference gate is honored before native fullscreen state changes. |
| Compare requests are presented through native iOS sheet flow | `BibleReaderController.compareSelection()`, `BibleReaderController.bridge(_:compareVerses:startOrdinal:endOrdinal:)`, `BibleReaderView.showCompare`, `presentCompareView(...)`; documented in `dispositions.md` | Partial | The entry points are in place, but this is still one of the places where a future regression could slip through unless we add a focused workflow check. |
| Reader config pushes active-window and display state into the embedded client | `BibleReaderController.buildConfigJSON()`, `BibleReaderController.updateConfig()`, `BibleReaderView.updateDisplaySettings(...)`; unit tests `testReaderConfigPayloadIncludesDisplaySettingsAndActiveWindowState`, `testReaderConfigPayloadMarksInactiveWindowWithoutActiveIndicator` | Pass | Focused payload-level coverage now locks the config/appSettings key shape, representative display settings, app preference values, workspace label state, and active/inactive window indicator behavior. |
