# BOOKMARKS-701 Verification Matrix (Android Bookmarks -> iOS)

Date: 2026-05-16

## Scope and Method

- Contract baseline: `docs/parity/bookmarks/contract.md`
- Verification method:
  - direct code inspection of `BookmarkService`, `BookmarkListView`, `LabelAssignmentView`,
    `LabelManagerView`, and the reader-side bookmark document hooks
  - direct comparison with a local Android reference checkout, especially
    `LinkControl.kt`, `BibleJavascriptInterface.kt`, and `BookmarksDao.kt`
  - focused simulator-backed UI smoke coverage from `AndBibleUITests`
  - app-host-free package coverage from `BibleUITests`
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
| Bookmark list browsing: search, label filter, sort, row navigation, and row deletion | `BookmarkListView.swift`; package tests `BookmarkListProjectionTests`; UI test `testBookmarkSelectionNavigatesReaderToSeededReference` | Pass | Search/filter/sort state projection and destructive row persistence are package-gated below the visible screen; row navigation remains a real reader-owned workflow. |
| Label assignment: toggle assignment, toggle favourite, create label inline, remove label | `LabelAssignmentView.swift`; package tests `LabelAssignmentMutationTests`; UI smoke `testBookmarkSelectionNavigatesReaderToSeededReference` | Pass | Relationship mutation, favourite state, create-and-assign behavior, and generic-bookmark assignment are package-gated below the visible screen; the retained BookmarkList navigation smoke also opens Label Assignment, verifies seeded assignment state, dismisses back to the list, and then selects a row. |
| Label manager CRUD | `LabelManagerView.swift`; package tests `LabelManagerMutationTests`; UI smoke `testSettingsApplicationShortcutsOpenGlobalTextOptions` | Pass | Create, edit-save, and delete relationship cleanup are package-gated below the visible screen; the retained reader/admin shortcut smoke proves the reader Label Settings action still reaches Label Manager and exports readiness state without spending a standalone app launch. |
| StudyPad handoff from bookmarks | `BookmarkListView.swift`, `BibleReaderController.swift`, `BibleReaderView.swift`; UI test `testBookmarkListOpensStudyPadForSelectedLabel` | Pass | Android exposes `openStudyPad` through `BibleJavascriptInterface` and `LinkControl`; iOS has current UI coverage for the bookmark-label handoff into StudyPad. |
| My Notes note mutation and delete persistence | `BibleReaderController.swift`, `BibleReaderView.swift`; UI test `testMyNotesPseudoDocumentOpensFromChooser`; service-layer tests `testBookmarkServiceClearingBibleBookmarkNoteDeletesPersistedNoteRow`, `testBookmarkServiceClearingBibleBookmarkNoteRemovesBookmarkFromMyNotesQuery`, `testBookmarkServiceUpdatingBibleBookmarkNoteReusesPersistedNoteRow`; bridge tests `testReaderSaveBookmarkNoteUsesConfiguredMarkdownContentTypeForNewNote`, `testReaderSaveBookmarkNoteDeletesWhitespaceOnlyNotesLikeAndroidBridge` | Pass | Android exposes `openMyNotes` through `BibleJavascriptInterface` and `LinkControl`. iOS keeps visible-path coverage for opening the reader-owned My Notes pseudo-document, while persistence and delete semantics are locked below the UI. |
| Generic bookmark visible workflow parity | `BookmarkListView.swift`, `LabelAssignmentView.swift`, `BookmarkService`; package tests `BookmarkListProjectionTests` and `LabelAssignmentMutationTests` | Pass | Generic bookmarks render in the native bookmark list with module/key references; projection tests verify label-filter visibility, while mutation tests verify the same package assignment path used by the visible row. |
| Bookmark note persistence split across bookmark rows and separate note entities | `BookmarkService.saveBibleBookmarkNote`, `BookmarkStore`; unit tests `testBookmarkServiceClearingBibleBookmarkNoteDeletesPersistedNoteRow`, `testBookmarkServiceClearingBibleBookmarkNoteRemovesBookmarkFromMyNotesQuery` | Adapted Pass | iOS preserves the Android-compatible data split, but exposes note-centric workflows through a separate My Notes surface. |
| Native bookmark list plus separate My Notes surface instead of one unified browser | `BookmarkListView.swift` note suppression and `BibleReaderController` My Notes document flow; documented in `dispositions.md`; UI coverage spans the bookmark surface and service coverage spans note persistence | Adapted Pass | The parity goal is shared data semantics and user-visible outcomes, not Android-identical screen structure. |
| StudyPad focused mutation workflow | `BookmarkService`, `BibleReaderController`, `StudyPadDocument.vue`; UI test `testBookmarkListOpensStudyPadForSelectedLabel`; package tests `testBookmarkServiceCreateAndUpdateStudyPadEntryPersistsText`, `testStudyPadActionCoordinatorCreatesEntryAfterBibleBookmarkLikeAndroidBridge`, `testStudyPadActionCoordinatorUpdatesTextLikeAndroidBridge`, `testReaderStudyPadDeleteBridgeEmitsAndroidStringPayload` | Pass | Visible UI coverage proves the Android handoff route from a selected bookmark label; package tests lock create/update/delete bridge and persistence semantics without reopening the full app. |
