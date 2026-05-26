# READER-702 Regression Report

Date: 2026-05-25

## Scope

This is the current validation snapshot for the reader surface. It covers:

- reader shell routing across the Android-style drawer and overflow split
- reader integration with search result selection
- history jump-back, clear, and single-row delete flows
- workspace selector create/switch flow from the reader shell
- restored-position highlight behavior in the emitted reader payload
- reader config/appSettings payload construction for embedded-client display and active-window state
- double-tap fullscreen preference gating
- bridge-driven compare presentation payload construction
- horizontal swipe-mode dispatch policy
- auto-fullscreen scroll-threshold policy
- documentation-only classification of the #122 reader-modal audit

Contract reference:

- `docs/parity/reader/contract.md`

Verification matrix:

- `docs/parity/reader/verification-matrix.md`

Related domain references:

- `docs/parity/search/verification-matrix.md`
- `docs/parity/bookmarks/verification-matrix.md`
- `docs/parity/settings/verification-matrix.md`

## Environment

- Repository: `and-bible-ios`
- Simulator destination: `platform=iOS Simulator,name=iPhone 17`
- Validation style:
  - full local serial simulator suite on `reader-menu-drawer-parity`
  - reader-relevant workflow assertions exercised within that suite
  - reader-adjacent unit regressions for payload-level restore/highlight behavior
  - focused reader/controller payload subset on `test/reader-config-payload-coverage`
  - focused reader gesture/fullscreen policy subset on `test/reader-fullscreen-swipe-coverage`
  - focused reader compare bridge subset on `test/reader-compare-workflow-coverage`

## Tests Executed

### Unit

- `AndBibleTests/testLoadCurrentContentDoesNotHighlightRestoredReadingPosition`
- `AndBibleTests/testLoadCurrentContentHighlightsExplicitVerseNavigationTarget`
- `AndBibleTests/testReaderConfigPayloadIncludesDisplaySettingsAndActiveWindowState`
- `AndBibleTests/testReaderConfigPayloadMarksInactiveWindowWithoutActiveIndicator`
- `AndBibleTests/testDoubleTapFullscreenPreferenceGateControlsNativeToggleRequest`
- `AndBibleTests/testReaderCompareBridgeRequestBuildsNativePresentationPayload`
- `AndBibleTests/testReaderHorizontalSwipePolicyMapsConfiguredModes`
- `AndBibleTests/testAutoFullscreenPolicyAccumulatesThresholdByDirection`
- `AndBibleTests/testAutoFullscreenPolicyHonorsDisabledAndDoubleTapLock`

### UI

- `AndBibleUITests/testSettingsScreenShowsPrimaryNavigationRows`
- `AndBibleUITests/testDownloadsScreenOpensFromReaderMenu`
- `AndBibleUITests/testWorkspaceSelectorCreateAndSwitchFlow`
- `AndBibleUITests/testBookmarksScreenOpensFromReaderMenu`
- `AndBibleUITests/testAboutScreenOpensFromReaderMenu`
- `AndBibleUITests/testSearchResultSelectionNavigatesReaderToBundledReference`
- `AndBibleUITests/testHistorySelectionNavigatesReaderToSeededReference`
- `AndBibleUITests/testHistoryClearRemovesSeededRowAcrossReopen`
- `AndBibleUITests/testHistoryRowDeletePreservesOtherRowsAcrossReopen`

## What This Validation Actually Covers

### Reader menu and shell ownership

- the reader shell exposes the expected overflow rows for Section titles, Strong's numbers, and Chapter & verse numbers
- the real reader shell can still open core destinations such as Downloads, Bookmarks, About, and Settings through the correct menu surface
- search result selection returns the app to a new reader reference, not only a search-side state change

### History

- selecting a prior history row moves the active reader from its seeded `Genesis 1` location
- clearing history removes persisted rows across reopen
- deleting one history row preserves the other persisted rows across reopen

### Workspaces

- workspace creation and switching remain driven through the reader-owned workspace selector and return control to the reader shell

### Restore / highlight behavior

- restoring a saved reading position does not emit a stale highlighted verse target
- explicit verse-target navigation still emits the expected highlighted target range

### Reader config payload

- `set_config` payloads retain the expected top-level `config`, `appSettings`, and `initial`
  sections
- `config` still includes the display-setting fields the embedded reader depends on, including
  color, margin, typography, footnote, cross-reference, and page-number values
- `appSettings` still includes app preference, workspace label, hidden compare document, modal
  button, experimental feature, and active-window state fields
- active windows with multiple visible panes emit `hasActiveIndicator: true`; inactive panes emit
  both `activeWindow: false` and `hasActiveIndicator: false`

### Fullscreen and swipe behavior

- embedded-client `toggleFullScreen` bridge messages honor the
  `double_tap_to_fullscreen` preference before invoking the native fullscreen
  toggle callback
- `CHAPTER`, `PAGE`, and `NONE` horizontal swipe modes resolve to the expected
  native navigation, page-scroll, or no-op action
- active text selection suppresses horizontal swipe actions
- auto-fullscreen scroll deltas accumulate by direction, reset on direction
  changes, enter/exit fullscreen only after the threshold, reset when disabled,
  and do not auto-toggle when fullscreen was entered by double tap

### Compare presentation payload

- embedded-client `compare` bridge messages are classified as handled and reach
  the controller's native compare presentation callback
- the callback receives the active reader book, chapter, current module name,
  and normalized start/end verse numbers derived from the web ordinal range
- this protects the current bridge payload path only; #123 tracks replacing the
  native Compare sheet with the Android-aligned document-pipeline flow

## Current Result

Latest focused reader compare validation passed on 2026-05-09:

- focused issue #41 subset: `1/1`
- command: `xcodebuild test -project AndBible.xcodeproj -scheme AndBible -destination 'platform=iOS Simulator,id=73679934-67DF-45BE-AEAC-186E2396213C' CODE_SIGNING_ALLOWED=NO -only-testing:AndBibleTests/AndBibleTests/testReaderCompareBridgeRequestBuildsNativePresentationPayload`

Latest full non-UI XCTest validation passed on 2026-05-09:

- `AndBibleTests`: `207/207`
- command: `xcodebuild test -project AndBible.xcodeproj -scheme AndBible -destination 'platform=iOS Simulator,id=73679934-67DF-45BE-AEAC-186E2396213C' CODE_SIGNING_ALLOWED=NO -only-testing:AndBibleTests`

Latest focused reader gesture/fullscreen validation passed on 2026-05-08:

- focused issue #40 subset: `4/4`
- command: `xcodebuild test -project AndBible.xcodeproj -scheme AndBible -destination 'platform=iOS Simulator,id=73679934-67DF-45BE-AEAC-186E2396213C' CODE_SIGNING_ALLOWED=NO -only-testing:AndBibleTests/AndBibleTests/testDoubleTapFullscreenPreferenceGateControlsNativeToggleRequest -only-testing:AndBibleTests/AndBibleTests/testReaderHorizontalSwipePolicyMapsConfiguredModes -only-testing:AndBibleTests/AndBibleTests/testAutoFullscreenPolicyAccumulatesThresholdByDirection -only-testing:AndBibleTests/AndBibleTests/testAutoFullscreenPolicyHonorsDisabledAndDoubleTapLock`

Latest focused reader/controller validation passed on 2026-05-08:

- focused shared-scheme reader/controller subset: `7/7`
- new reader config payload tests: `2/2`
- result bundle: `.artifacts/AndBibleTests-reader-config-20260507-v4.xcresult`

Previous full reader validation passed on 2026-04-01:

- non-UI XCTest suite: `146/146`
- full UI XCTest suite: `39/39`
- reader-relevant UI workflows listed above all passed within that full suite
- full serial UI runtime: about `4480.656s` (`74.7` minutes)

Taken together, this gives the reader domain current regression evidence for:

- reader shell routing across the drawer/overflow split
- search-to-reader navigation handoff
- history navigation and destructive persistence
- workspace selector create/switch handoff
- payload-level restore/highlight behavior
- payload-level config/appSettings propagation into the embedded document client
- double-tap fullscreen preference gating
- bridge-driven compare presentation payload construction
- horizontal swipe-mode dispatch policy
- auto-fullscreen threshold and lockout policy
- the audited #122 classification in the reader contract, dispositions, and
  verification matrix

That is a much healthier place than the branch was in earlier. The remaining
reader risk is no longer the basic shell/menu flow; it is the deeper
document/modal routing branches we still have not moved to the Android-aligned
paths or isolated with focused checks.

## What Is Still Not Well Locked Yet

The reader shell baseline is in much better shape now. The parts that still
need implementation and/or tighter protection are:

- #8 Strong's / dictionary document-pipeline routing and focused regression coverage
- #123 Compare document-pipeline routing
- #124 multi-reference / cross-reference document-pipeline routing
- #125 Vue modal-open host-navigation gating

Those areas show up as `Partial` in
[verification-matrix.md](verification-matrix.md). Existing tests still protect
the current implementation paths, but they should not be read as closing those
Android parity gaps.
