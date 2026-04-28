# BRIDGE-702 Regression Report

Date: 2026-04-28

## Scope

This is the current validation snapshot for the bridge-adjacent surface. It
covers:

- StudyPad document handoff from a real bookmark workflow
- the native persistence paths that support those embedded note surfaces
- local Android bridge surface comparison
- machine-readable gap inventory for Android-only and iOS no-op bridge methods

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

### Unit

- `AndBibleTests/testBookmarkServiceClearingBibleBookmarkNoteDeletesPersistedNoteRow`
- `AndBibleTests/testBookmarkServiceClearingBibleBookmarkNoteRemovesBookmarkFromMyNotesQuery`
- `AndBibleTests/testBookmarkServiceUpdatingBibleBookmarkNoteReusesPersistedNoteRow`

### UI

- `AndBibleUITests/testBookmarkListOpensStudyPadForSelectedLabel`

## What This Validation Actually Covers

### Embedded note surfaces

- service-layer note persistence still feeds the embedded My Notes data model
- visible My Notes note update/delete workflows no longer have focused UI coverage

### StudyPad handoff

- a real bookmark-list label flow can hand off into the matching StudyPad document

### Persistence support

- clearing a bookmark note deletes the persisted note row
- rebuilding the My Notes bookmark query after note deletion removes the bookmark from the
  resulting note-backed surface

## Historical Result And Current Interpretation

Focused bridge-adjacent validation passed on 2026-03-16, but the original UI result is now stale
because four UI tests from that report no longer exist in `AndBibleUITests`. The current rerunnable
named subset in this report is:

- Unit: `3` tests
- UI: `1` test

This doc refresh did not rerun the simulator suite, so do not treat the old UI runtime/count as
current evidence. The checked-in named subset gives the bridge domain rerunnable evidence for:

- service-layer note persistence
- StudyPad document handoff
- bookmark-note persistence feeding those embedded surfaces

So the bridge story is not "everything is shaky." It is more specific than
that: the StudyPad handoff and note persistence support are present, while the visible My Notes
lifecycle and rawer transport edges still need more direct protection.

## What Is Still Not Well Locked Yet

The pieces that still need tighter protection are:

- visible My Notes open/update/delete workflows
- full current Android bridge breadth beyond the shared iOS subset (`88` Android methods versus
  `62` iOS-bundled methods in `bibleview-js/src/composables/android.ts`)
- the tracked bridge gap inventory: 26 missing Android methods plus 3 iOS no-op methods that
  still need implementation or explicit product divergence
- raw `window.android.*` compatibility-shim behavior on a per-method basis
- `callId` async request/response flows for content expansion and native dialogs
- Strong's sheet bridge coverage, especially the dedicated `contentType: "strongs"` route
- fullscreen, compare, help, and reference-dialog bridge workflows
- explicit payload-shape guardrails between `BridgeTypes.swift` and `bibleview-js/src/types/`

Those areas are implemented and documented, but they are not yet locked by
focused bridge-domain regression coverage, so they still show up as `Partial`
in [verification-matrix.md](verification-matrix.md).
