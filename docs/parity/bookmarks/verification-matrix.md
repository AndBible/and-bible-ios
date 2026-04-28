# BOOKMARKS-701 Verification Matrix (Android Bookmarks -> iOS)

Date: 2026-04-28

## Scope and Method

- Contract baseline: `docs/parity/bookmarks/contract.md`
- Verification method:
  - direct code inspection of `BookmarkService`, `BookmarkListView`, `LabelAssignmentView`,
    `LabelManagerView`, and the reader-side bookmark document hooks
  - direct comparison with a local Android reference checkout, especially
    `LinkControl.kt`, `BibleJavascriptInterface.kt`, and `BookmarksDao.kt`
  - focused simulator-backed UI coverage from `AndBibleUITests`
  - focused unit regression coverage from `AndBibleTests`
- Regression evidence: `docs/parity/bookmarks/regression-report.md`

## Status Legend

- `Pass`: implemented and backed by direct code evidence plus current regression coverage
- `Adapted Pass`: parity delivered with explicit iOS implementation differences documented in
  `dispositions.md`
- `Partial`: implemented or exposed, but not yet backed by enough focused evidence to treat the
  area as locked

## Summary

- `Pass`: 4
- `Adapted Pass`: 2
- `Partial`: 3

## Matrix

| Bookmark Contract Area | iOS Evidence | Status | Notes |
|---|---|---|---|
| Bookmark list browsing: search, label filter, sort, row navigation, and row deletion | `BookmarkListView.swift`; UI tests `testBookmarkSelectionNavigatesReaderToSeededReference`, `testBookmarkRowDeletePreservesOtherRowsAcrossReopen`, `testBookmarkListSortMenuReordersRows`, `testBookmarkListSearchNarrowsAndClearsVisibleRows`, `testBookmarkListLabelFilterNarrowsAndClearsVisibleRows` | Pass | The native list surface is regression-gated as a real reader-owned workflow, not only by direct launch. |
| Label assignment: toggle assignment, toggle favourite, create label inline, remove label | `LabelAssignmentView.swift`; UI tests `testLabelAssignmentTogglesFavouriteAndAssignment`, `testBookmarkListLabelAssignmentCreatesAndAssignsNewLabel`, `testBookmarkListLabelAssignmentRemovalHidesBookmarkUnderFilter` | Pass | Covers both relationship mutation and immediate UI reflection back in the bookmark list. |
| Label manager CRUD | `LabelManagerView.swift`; UI test `testLabelManagerCreateRenameDeleteFlow` | Pass | Create, rename, and delete are locked by a real end-to-end UI workflow. |
| StudyPad handoff from bookmarks | `BookmarkListView.swift`, `BibleReaderController.swift`, `BibleReaderView.swift`; UI test `testBookmarkListOpensStudyPadForSelectedLabel` | Pass | Android exposes `openStudyPad` through `BibleJavascriptInterface` and `LinkControl`; iOS has current UI coverage for the bookmark-label handoff into StudyPad. |
| My Notes note mutation and delete persistence | `BibleReaderController.swift`, `BibleReaderView.swift`; service-layer tests `testBookmarkServiceClearingBibleBookmarkNoteDeletesPersistedNoteRow`, `testBookmarkServiceClearingBibleBookmarkNoteRemovesBookmarkFromMyNotesQuery`, `testBookmarkServiceUpdatingBibleBookmarkNoteReusesPersistedNoteRow` | Partial | Android exposes `openMyNotes` through `BibleJavascriptInterface` and `LinkControl`. iOS still has the route and persistence support, but the previous focused My Notes UI tests are no longer present. |
| Bookmark note persistence split across bookmark rows and separate note entities | `BookmarkService.saveBibleBookmarkNote`, `BookmarkStore`; unit tests `testBookmarkServiceClearingBibleBookmarkNoteDeletesPersistedNoteRow`, `testBookmarkServiceClearingBibleBookmarkNoteRemovesBookmarkFromMyNotesQuery` | Adapted Pass | iOS preserves the Android-compatible data split, but exposes note-centric workflows through a separate My Notes surface. |
| Native bookmark list plus separate My Notes surface instead of one unified browser | `BookmarkListView.swift` note suppression and `BibleReaderController` My Notes document flow; documented in `dispositions.md`; UI coverage spans the bookmark surface and service coverage spans note persistence | Adapted Pass | The parity goal is shared data semantics and user-visible outcomes, not Android-identical screen structure. |
| StudyPad ordering, reorder, and delete breadth | `BookmarkService` and `BibleReaderController` StudyPad entry operations exist; no focused UI regression currently covers create, reorder, or delete | Partial | Current UI evidence locks handoff only; the full StudyPad mutation surface still needs focused coverage. |
| Generic bookmark visible workflow parity | `BookmarkService` and models support generic bookmarks; no focused regression currently exercises generic-bookmark browsing, editing, or label assignment from a visible UI path | Partial | The generic side of the bookmark domain exists in persistence and bridge logic, but it is not yet gated by focused workflow coverage. |
