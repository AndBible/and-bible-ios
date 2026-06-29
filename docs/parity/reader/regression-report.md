# READER-702 Regression Report

Date: 2026-05-28

## Scope

This is the current validation snapshot for the reader surface. It covers:

- reader shell routing across the Android-style drawer and overflow split
- reader integration with search result selection
- history jump-back, clear, and single-row delete flows
- workspace selector create flow from the reader shell, with switching persistence covered in package tests
- restored-position highlight behavior in the emitted reader payload
- reader config/appSettings payload construction for embedded-client display and active-window state
- double-tap fullscreen preference gating
- bridge-driven compare document-pipeline payload construction
- Strong's / dictionary document-pipeline routing
- horizontal swipe-mode dispatch policy
- Vue modal-state host-navigation gating
- auto-fullscreen scroll-threshold policy
- documentation-only classification of the #122 reader-modal audit
- ADR 0006 ownership classification for current reader sheet/modal/destination routes
- document chooser all-types entry, installed-module category/language/search
  filtering, and explicit classification of remaining Android `ChooseDocument`
  gaps

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
  - focused reader modal-state bridge/policy subset on `fix/125-vue-modal-state`
  - focused reader compare bridge subset on `fix/123-compare-vue-pipeline`
  - focused reader Strong's document-routing subset on `fix/8-strongs-document-routing`
  - focused reader document chooser subset on `fix/119-document-chooser-parity`

## Tests Executed

### Unit

- `AndBibleTests/testLoadCurrentContentDoesNotHighlightRestoredReadingPosition`
- `AndBibleTests/testLoadCurrentContentHighlightsExplicitVerseNavigationTarget`
- `AndBibleTests/testReaderConfigPayloadIncludesDisplaySettingsAndActiveWindowState`
- `AndBibleTests/testReaderConfigPayloadMarksInactiveWindowWithoutActiveIndicator`
- `AndBibleTests/testDoubleTapFullscreenPreferenceGateControlsNativeToggleRequest`
- `AndBibleTests/testReaderCompareBridgeRequestEmitsVueCompareDocument`
- `AndBibleTests/testStrongsLinkEmitsVueDocumentInsteadOfNativeSheet`
- `AndBibleTests/testStrongsLinkUsesLinksWindowRoutingCallbackWhenAvailable`
- `AndBibleTests/testReaderHorizontalSwipePolicyMapsConfiguredModes`
- `AndBibleTests/testReaderBridgeModalStateBlocksKeyNavigationAndRequestsClose`
- `AndBibleTests/testAutoFullscreenPolicyAccumulatesThresholdByDirection`
- `AndBibleTests/testAutoFullscreenPolicyHonorsDisabledAndDoubleTapLock`
- `AndBibleTests/testBibleReaderModulePickerBuildsForBibleCategory`
- `AndBibleTests/testBibleReaderModulePickerFiltersAndroidChooserCategoriesAndSearch`
- `AndBibleTests/testBibleReaderModulePickerMapsAndroidDocumentTypeCategories`
- `scripts/test_reader_modal_ownership_matrix.py`

### UI

- `AndBibleUITests/testSettingsScreenShowsPrimaryNavigationRows`
- `AndBibleUITests/testDownloadsRepositoryManagerOpensFromOverflow`
- `AndBibleUITests/testWorkspaceSelectorCreateFlowReturnsToReaderShell`
- `AndBibleUITests/testBookmarkSelectionNavigatesReaderToSeededReference`
- `AndBibleUITests/testSettingsApplicationShortcutsOpenGlobalTextOptions`
- `AndBibleUITests/testSearchOptionControlsMutateVisibleState`
- `AndBibleUITests/testBookmarkSelectionNavigatesReaderToSeededReference`
- `BibleUITests/HistoryListPresentationTests`

## What This Validation Actually Covers

### Reader menu and shell ownership

- the reader shell exposes the expected overflow rows for Section titles, Strong's numbers, and Chapter & verse numbers
- the real reader shell can still open core destinations such as Downloads, Bookmarks, About, and Settings through the correct menu surface
- search result selection returns the app to a new reader reference, not only a search-side state change
- every `ReaderSheet`, `ReaderDestination`, and `ReaderModal` enum case is
  represented in the ADR 0006 reader ownership matrix
- state-backed reader presentations outside those enums, including Search,
  startup download prompt, Strong's mode dialog, sharing, cross references, and
  reference chooser, are represented in the same matrix

### History

- selecting a prior history row moves the active reader from its seeded `Genesis 1` location
- clearing history removes persisted rows across reopen
- deleting one history row preserves the other persisted rows across reopen

### Workspaces

- workspace creation remains driven through the reader-owned workspace selector and returns control to the reader shell; switching persistence remains covered at the package layer

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

### Compare document payload

- embedded-client `compare` bridge messages are classified as handled and emit
  a Vue `MultiDocument` payload with `compare: true`
- the payload carries the active Bible module as a compare fragment, preserves
  the selected OSIS range, and exposes the module name for Vue hide/restore
  controls
- reader overflow Compare also routes through `loadCompareDocument(...)` instead
  of presenting a native Swift sheet

### Strong's document payload

- Strong's links emit a Vue `MultiDocument` payload with `contentType: "strongs"`
  instead of presenting a native iOS sheet
- the payload preserves the Strong's feature metadata consumed by
  `StrongsDocument.vue`
- the reader's rendered-content state exposes the active dictionary module/key
  so bottom window tabs label Strong's panes like Android dictionary documents
- when the links-window preference is active, Strong's documents go through the
  same pane-owned links-window routing callback used by other linked document
  content

### Document chooser

- drawer-level Choose Document opens the shared module picker directly on
  Android's all-types filter instead of showing the removed category-first native
  sheet
- category-specific picker entry still starts on the requested document type
  when the caller is choosing a Bible/commentary/dictionary/book/map module
- installed module filtering covers Android's representable document-type,
  all-language, specific-language, free-text search, and category-order behavior
- unsupported Android rows and actions remain explicit gaps: pseudo-documents,
  add-ons, encrypted-module unlock prompts, and row context actions for
  about/delete/delete-index/unlock

## Current Result

Latest focused reader document chooser validation passed on 2026-05-28:

- focused issue #119 subset: `3/3`
- command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project AndBible.xcodeproj -scheme AndBible -configuration Debug -destination 'platform=iOS Simulator,id=98C37D62-54A5-4C52-846B-B0801AEAD2CB' -derivedDataPath /private/tmp/andbible-dd-119 -only-testing:AndBibleTests/AndBibleTests/testBibleReaderModulePickerBuildsForBibleCategory -only-testing:AndBibleTests/AndBibleTests/testBibleReaderModulePickerFiltersAndroidChooserCategoriesAndSearch -only-testing:AndBibleTests/AndBibleTests/testBibleReaderModulePickerMapsAndroidDocumentTypeCategories`

Latest focused reader compare validation passed on 2026-05-26:

- focused issue #123 subset: `6/6`
- command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project AndBible.xcodeproj -scheme AndBible -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /private/tmp/andbible-dd-123 test -only-testing:AndBibleTests/AndBibleTests/testReaderCompareBridgeRequestEmitsVueCompareDocument -only-testing:AndBibleTests/AndBibleTests/testToggleCompareDocumentPersistsWorkspaceHiddenStateAndReemitsConfig -only-testing:AndBibleTests/AndBibleTests/testReaderConfigPayloadIncludesDisplaySettingsAndActiveWindowState -only-testing:AndBibleTests/AndBibleTests/testMultiReferenceLinkEmitsVueMultiDocumentInsteadOfCrossReferenceSheet -only-testing:AndBibleTests/AndBibleTests/testMultiReferenceOsisLinkEmitsVueMultiDocumentInsteadOfCrossReferenceSheet -only-testing:AndBibleTests/AndBibleTests/testSingleOsisReferenceStillNavigatesWithoutMultiDocument`

Latest focused reader Strong's validation passed on 2026-05-27:

- focused issue #8 subset: `6/6`
- command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project AndBible.xcodeproj -scheme AndBible -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /private/tmp/andbible-dd-8 test -only-testing:AndBibleTests/AndBibleTests/testBuildStrongsMultiDocJSONReturnsInstallFallbackWhenNoStrongsDictionaryIsInstalled -only-testing:AndBibleTests/AndBibleTests/testStrongsLinkEmitsVueDocumentInsteadOfNativeSheet -only-testing:AndBibleTests/AndBibleTests/testStrongsLinkUsesLinksWindowRoutingCallbackWhenAvailable -only-testing:AndBibleTests/AndBibleTests/testMultiReferenceLinkEmitsVueMultiDocumentInsteadOfCrossReferenceSheet -only-testing:AndBibleTests/AndBibleTests/testMultiReferenceOsisLinkEmitsVueMultiDocumentInsteadOfCrossReferenceSheet -only-testing:AndBibleTests/AndBibleTests/testReaderCompareBridgeRequestEmitsVueCompareDocument`

Latest full non-UI XCTest validation passed on 2026-05-26:

- `AndBibleTests`: `253/253`
- command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project AndBible.xcodeproj -scheme AndBible -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /private/tmp/andbible-dd-123 test -only-testing:AndBibleTests`

Latest focused reader gesture/fullscreen validation passed on 2026-05-08:

- focused issue #40 subset: `4/4`
- command: `xcodebuild test -project AndBible.xcodeproj -scheme AndBible -destination 'platform=iOS Simulator,id=73679934-67DF-45BE-AEAC-186E2396213C' CODE_SIGNING_ALLOWED=NO -only-testing:AndBibleTests/AndBibleTests/testDoubleTapFullscreenPreferenceGateControlsNativeToggleRequest -only-testing:AndBibleTests/AndBibleTests/testReaderHorizontalSwipePolicyMapsConfiguredModes -only-testing:AndBibleTests/AndBibleTests/testAutoFullscreenPolicyAccumulatesThresholdByDirection -only-testing:AndBibleTests/AndBibleTests/testAutoFullscreenPolicyHonorsDisabledAndDoubleTapLock`

Latest focused reader modal-state validation passed on 2026-05-25:

- focused issue #125 subset: `2/2`
- command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project AndBible.xcodeproj -scheme AndBible -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO -only-testing:AndBibleTests/AndBibleTests/testReaderBridgeModalStateBlocksKeyNavigationAndRequestsClose -only-testing:AndBibleTests/AndBibleTests/testReaderHorizontalSwipePolicyMapsConfiguredModes`

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
- workspace selector create handoff
- payload-level restore/highlight behavior
- payload-level config/appSettings propagation into the embedded document client
- double-tap fullscreen preference gating
- bridge-driven compare document-pipeline payload construction
- Strong's / dictionary document-pipeline routing
- multi-reference document-pipeline routing through the shared Vue
  `MultiDocument` path
- reader presentation ownership classification through
  [modal-ownership-matrix.md](modal-ownership-matrix.md)
- document chooser all-types entry and installed-module filtering, with
  remaining Android chooser gaps recorded in
  [document-chooser-matrix.md](document-chooser-matrix.md)
- horizontal swipe-mode dispatch policy
- Vue modal-state host-navigation gating
- auto-fullscreen threshold and lockout policy
- the audited #122 classification in the reader contract, dispositions, and
  verification matrix
  is superseded by the ADR 0006 ownership matrix for future presentation work

That is a much healthier place than the branch was in earlier. The remaining
reader risk is no longer the basic shell/menu flow; it is the deeper
reader-owned chooser, bookmark, label, and StudyPad presentation behavior that
still needs Android-aligned completion or tighter focused checks.

## What Is Still Not Well Locked Yet

The reader shell baseline is in much better shape now. The parts that still
need implementation and/or tighter protection are:

- #245 document chooser completion
- #246 bookmark, label, and StudyPad presentation ownership details

The remaining open areas show up as `Partial` in
[verification-matrix.md](verification-matrix.md). Existing tests still protect
the current implementation paths, but they should not be read as closing those
Android parity gaps.
