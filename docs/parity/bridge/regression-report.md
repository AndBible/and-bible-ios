# BRIDGE-702 Regression Report

Date: 2026-05-10

## Scope

This is the current validation snapshot for the bridge-adjacent surface. It
covers:

- StudyPad document handoff from a real bookmark workflow
- visible My Notes note update/delete from the production reader path
- the native persistence paths that support those embedded note surfaces
- representative async `callId` request/response bridge flows
- known malformed bridge message classification for positional JS-to-native
  dispatch
- representative Swift bridge payload key shapes consumed by `bibleview-js`
- paragraph-break bookmark persistence for the former no-op bridge actions
- local Android bridge surface comparison
- machine-readable gap inventory for Android-only and iOS no-op/former no-op bridge methods
- pasteable bridge inventory summaries for parity issues and PR validation notes

Contract reference:

- `docs/parity/bridge/contract.md`

Verification matrix:

- `docs/parity/bridge/verification-matrix.md`

Related domain references:

- `docs/parity/bookmarks/verification-matrix.md`
- `docs/parity/reader/verification-matrix.md`

## Environment

- Repository: `and-bible-ios`
- Simulator destination: `platform=iOS Simulator,name=iPhone 17`
- Validation style: focused `xcodebuild test` subset

## Current Rerunnable Test Set

### Machine-readable guardrails

- `python3 scripts/check_bridge_parity_inventory.py`
- `python3 scripts/check_bridge_parity_inventory.py --android-root ../and-bible`
  when the Android checkout is available locally

### Unit

- `AndBibleTests/testBookmarkServiceClearingBibleBookmarkNoteDeletesPersistedNoteRow`
- `AndBibleTests/testBookmarkServiceClearingBibleBookmarkNoteRemovesBookmarkFromMyNotesQuery`
- `AndBibleTests/testBookmarkServiceUpdatingBibleBookmarkNoteReusesPersistedNoteRow`
- `AndBibleTests/testBookmarkServiceCreatesParagraphBreakBibleBookmark`
- `AndBibleTests/testBookmarkServiceCreatesParagraphBreakGenericBookmark`
- `AndBibleTests/testBridgeCallIdRequestMappingMatchesWebClientContract`
- `AndBibleTests/testBridgeCallIdDispatchClassifiesKnownMalformedMessages`
- `AndBibleTests/testBridgeMessageDispatchClassifiesKnownMalformedMessages`
- `AndBibleTests/testBridgeSendResponseEmitsCallIdResponseJavaScript`
- `AndBibleTests/testBridgePayloadKeysMatchWebClientContracts`
- `AndBibleTests/testRequestMoreToBeginningSendsDocumentResponseWithOriginalCallId`
- `AndBibleTests/testRefChooserDialogSendsResponseWithOriginalCallId`
- `AndBibleTests/testParseRefSendsResponseWithOriginalCallId`

### UI

- `AndBibleUITests/testBookmarkListOpensStudyPadForSelectedLabel`
- `AndBibleUITests/testMyNotesNoteUpdateAndDeletePersistsFromVisibleWorkflow`

## What This Validation Actually Covers

### Embedded note surfaces

- service-layer note persistence still feeds the embedded My Notes data model
- visible My Notes note update/delete is covered through the production reader My Notes path

### StudyPad handoff

- a real bookmark-list label flow can hand off into the matching StudyPad document

### Persistence support

- clearing a bookmark note deletes the persisted note row
- rebuilding the My Notes bookmark query after note deletion removes the bookmark from the
  resulting note-backed surface

### Async callId flows

- bridge dispatch keeps `callId` as the first positional argument for content expansion and
  native reference dialog/parser requests
- `BibleBridge.sendResponse(...)` emits `bibleView.response(callId, value)` with the original
  call identifier
- content expansion can return a previous-chapter Bible document payload for the original
  `requestMoreToBeginning` call ID
- native `refChooserDialog` and `parseRef` controller handlers send their responses through the
  original call ID

### Message dispatch validation

- known bridge methods with missing required arguments classify as malformed
- wrong-type required arguments and wrong-type present optional arguments classify as malformed
- `shareBookmarkVerse` follows the web-client contract and accepts a bookmark ID string rather
  than an invented bookmark dictionary payload
- intentionally supported no-argument branches such as `helpBookmarks` remain handled
- paragraph-break bridge actions validate required arguments before creating native bookmarks
- memorization bridge state methods validate required arguments, preserve single-verse
  `endOrdinal < 0` behavior, and mutate local native memorization state; speech-loop parity
  remains deferred to #78

### Payload shapes

- representative `OsisFragment`, label/style, and selection-query payloads preserve the key names
  expected by `bibleview-js/src/types/client-objects.ts` and `bibleview-js/src/composables/android.ts`

## Historical Result And Current Interpretation

Focused bridge-adjacent validation passed on 2026-03-16, but the original UI result is now stale
because four UI tests from that report no longer exist in `AndBibleUITests`. The current rerunnable
named subset in this report is:

- Unit: `13` tests
- UI: `2` tests

This doc refresh reran the focused bridge dispatcher/callId/payload subset locally, but did not
rerun the full bridge-adjacent simulator suite. Do not treat the old UI runtime/count as current
evidence. The checked-in named subset gives the bridge domain rerunnable evidence for:

- service-layer note persistence
- StudyPad document handoff
- visible My Notes update/delete and document rebuild from the reader-owned path
- bookmark-note persistence feeding those embedded surfaces
- paragraph-break bookmark persistence using the reserved system label
- async `callId` request/response transport for representative content expansion and native
  reference workflows
- malformed known-message classification for positional JS-to-native dispatch
- representative bridge payload key shapes for OSIS fragments, labels/styles, and selection query

So the bridge story is not "everything is shaky." It is more specific than
that: the StudyPad handoff, visible My Notes lifecycle, and note persistence support are present,
while full valid delegate-call coverage still needs more direct protection.

## What Is Still Not Well Locked Yet

The pieces that still need tighter protection are:

- full current Android bridge breadth beyond the shared iOS subset (`89` Android
  methods versus `66` iOS-bundled methods in
  `bibleview-js/src/composables/android.ts`)
- the tracked bridge gap inventory: 23 missing Android methods plus 3 former no-op method
  dispositions; memorization bridge state is implemented while `speakMemorizationLoop`
  remains deferred through #78, My Documents is deferred through #80, #81, #82, and #83,
  reading progress is deferred through #85, #86, and #87, AI bridge methods are deferred
  through #89, #90, #91, and #92, and no current iOS no-op method remains in
  "needs decision" status
- raw `window.android.*` compatibility-shim behavior on a per-method basis
- Strong's sheet bridge coverage, especially the dedicated `contentType: "strongs"` route
- fullscreen, compare, help, and full reference-dialog UI workflows
- positive delegate-callback assertions across the full JS-to-native message surface
- generated or full-surface payload-shape parity checks between `BridgeTypes.swift` and
  `bibleview-js/src/types/` beyond the current representative key-shape tests

Those areas are implemented and documented, but they are not yet locked by
focused bridge-domain regression coverage, so they still show up as `Partial`
in [verification-matrix.md](verification-matrix.md).
