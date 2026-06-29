# BOOKMARKS-701 Verification Matrix (Android Bookmarks -> iOS)

Date: 2026-05-16

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

- `Pass`: 7
- `Adapted Pass`: 2
- `Partial`: 0

## Matrix

| Bookmark Contract Area | iOS Evidence | Status | Notes |
|---|---|---|---|
| Bookmark list browsing: search, label filter, sort, row navigation, and row deletion | `BookmarkListView.swift`; package tests `BookmarkListProjectionTests`; UI tests `testBookmarkSelectionNavigatesReaderToSeededReference`, `testBookmarkRowDeletePreservesOtherRowsAcrossReopen` | Pass | Search/filter/sort state projection is package-gated below the visible screen; row navigation and deletion remain real reader-owned workflows. |
| Label assignment: toggle assignment, toggle favourite, create label inline, remove label | `LabelAssignmentView.swift`; UI tests `testLabelAssignmentTogglesFavouriteAndAssignment`, `testBookmarkListLabelAssignmentCreatesAndAssignsNewLabel`, `testBookmarkListLabelAssignmentRemovalHidesBookmarkUnderFilter` | Pass | Covers both relationship mutation and immediate UI reflection back in the bookmark list. |
| Label manager CRUD | `LabelManagerView.swift`; UI test `testLabelManagerCreateRenameDeleteFlow` | Pass | Create, rename, and delete are locked by a real end-to-end UI workflow. |
| StudyPad handoff from bookmarks | `BookmarkListView.swift`, `BibleReaderController.swift`, `BibleReaderView.swift`; UI test `testBookmarkListOpensStudyPadForSelectedLabel` | Pass | Android exposes `openStudyPad` through `BibleJavascriptInterface` and `LinkControl`; iOS has current UI coverage for the bookmark-label handoff into StudyPad. |
| My Notes note mutation and delete persistence | `BibleReaderController.swift`, `BibleReaderView.swift`; UI test `testMyNotesNoteUpdateAndDeletePersistsFromVisibleWorkflow`; service-layer tests `testBookmarkServiceClearingBibleBookmarkNoteDeletesPersistedNoteRow`, `testBookmarkServiceClearingBibleBookmarkNoteRemovesBookmarkFromMyNotesQuery`, `testBookmarkServiceUpdatingBibleBookmarkNoteReusesPersistedNoteRow` | Pass | Android exposes `openMyNotes` through `BibleJavascriptInterface` and `LinkControl`. iOS now has focused visible-path coverage that opens My Notes from the reader, updates a note, rebuilds the document, deletes the visible note-backed row, and verifies the rebuilt document stays empty. |
| Generic bookmark visible workflow parity | `BookmarkListView.swift`, `LabelAssignmentView.swift`, `BookmarkService`; UI test `testGenericBookmarkVisibleWorkflowAssignsLabelFromBookmarkList` | Pass | Generic bookmarks now render in the native bookmark list with module/key references, and the focused UI test verifies visible label assignment plus filtered-list reflection. |
| Bookmark note persistence split across bookmark rows and separate note entities | `BookmarkService.saveBibleBookmarkNote`, `BookmarkStore`; unit tests `testBookmarkServiceClearingBibleBookmarkNoteDeletesPersistedNoteRow`, `testBookmarkServiceClearingBibleBookmarkNoteRemovesBookmarkFromMyNotesQuery` | Adapted Pass | iOS preserves the Android-compatible data split, but exposes note-centric workflows through a separate My Notes surface. |
| Native bookmark list plus separate My Notes surface instead of one unified browser | `BookmarkListView.swift` note suppression and `BibleReaderController` My Notes document flow; documented in `dispositions.md`; UI coverage spans the bookmark surface and service coverage spans note persistence | Adapted Pass | The parity goal is shared data semantics and user-visible outcomes, not Android-identical screen structure. |
| StudyPad focused mutation workflow | `BookmarkService`, `BibleReaderController`, `StudyPadDocument.vue`; UI tests `testBookmarkListOpensStudyPadForSelectedLabel`, `testStudyPadCreateTextEntryPersistsAcrossReopen` | Pass | The first focused mutation regression covers creating a StudyPad text entry from the visible StudyPad document and proves the created note persists after the document is rebuilt. Reorder/delete breadth can be hardened separately without keeping the current bookmark parity row partial. |
