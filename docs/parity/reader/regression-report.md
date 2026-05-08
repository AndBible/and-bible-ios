# READER-702 Regression Report

Date: 2026-05-08

## Scope

This is the current validation snapshot for the reader surface. It covers:

- reader shell routing across the Android-style drawer and overflow split
- reader integration with search result selection
- history jump-back, clear, and single-row delete flows
- workspace selector create/switch flow from the reader shell
- restored-position highlight behavior in the emitted reader payload
- reader config/appSettings payload construction for embedded-client display and active-window state

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

## Tests Executed

### Unit

- `AndBibleTests/testLoadCurrentContentDoesNotHighlightRestoredReadingPosition`
- `AndBibleTests/testLoadCurrentContentHighlightsExplicitVerseNavigationTarget`
- `AndBibleTests/testReaderConfigPayloadIncludesDisplaySettingsAndActiveWindowState`
- `AndBibleTests/testReaderConfigPayloadMarksInactiveWindowWithoutActiveIndicator`

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

## Current Result

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

That is a much healthier place than the branch was in earlier. The remaining
reader risk is no longer the basic shell/menu flow; it is the deeper behavior
branches we still have not isolated with their own focused checks.

## What Is Still Not Well Locked Yet

The reader shell baseline is in much better shape now. The parts that still
need tighter protection are:

- dedicated Strong's / dictionary modal regression coverage
- swipe-mode and auto-fullscreen behavior
- double-tap fullscreen behavior
- compare presentation workflows

Those areas are implemented and documented, but they are not yet locked by
focused reader-domain regression coverage, so they still show up as `Partial`
in [verification-matrix.md](verification-matrix.md).
