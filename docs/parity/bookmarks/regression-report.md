# BOOKMARKS-702 Regression Report

Date: 2026-04-28

## Scope

Regression verification for the current bookmark parity surface, covering:

- native bookmark-list search, filter, sort, selection, and deletion
- label assignment and label-manager mutation flows
- StudyPad handoff from a real bookmark workflow
- service-layer My Notes/note-row persistence semantics
- local Android bookmark reference comparison

Contract reference:

- `docs/parity/bookmarks/contract.md`

Verification matrix:

- `docs/parity/bookmarks/verification-matrix.md`

## Environment

- Repository: `and-bible-ios`
- Simulator destination: `platform=iOS Simulator,name=iPhone 17`
- Validation style: focused `xcodebuild test` subset

## Current Rerunnable Test Set

### Unit

- `AndBibleTests/testBookmarkStoreBibleBookmarksCanFilterByLabel`
- `AndBibleTests/testBookmarkLabelSerializationSkipsDeletedBibleLabels`
- `AndBibleTests/testBookmarkServiceDeleteLabelDetachesBookmarkRelationships`
- `AndBibleTests/testBookmarkServiceClearingBibleBookmarkNoteDeletesPersistedNoteRow`
- `AndBibleTests/testBookmarkServiceClearingBibleBookmarkNoteRemovesBookmarkFromMyNotesQuery`

### UI

- `AndBibleUITests/testBookmarkSelectionNavigatesReaderToSeededReference`
- `AndBibleUITests/testBookmarkRowDeletePreservesOtherRowsAcrossReopen`
- `AndBibleUITests/testBookmarkListSortMenuReordersRows`
- `AndBibleUITests/testBookmarkListSearchNarrowsAndClearsVisibleRows`
- `AndBibleUITests/testBookmarkListLabelFilterNarrowsAndClearsVisibleRows`
- `AndBibleUITests/testLabelAssignmentTogglesFavouriteAndAssignment`
- `AndBibleUITests/testBookmarkListLabelAssignmentCreatesAndAssignsNewLabel`
- `AndBibleUITests/testBookmarkListLabelAssignmentRemovalHidesBookmarkUnderFilter`
- `AndBibleUITests/testLabelManagerCreateRenameDeleteFlow`
- `AndBibleUITests/testBookmarkListOpensStudyPadForSelectedLabel`

## Expected Assertions Covered

### Bookmark list

- selecting a seeded bookmark navigates the reader to the bookmarked reference
- deleting one bookmark preserves the other seeded row across reopen
- changing sort order reorders the visible rows
- text search narrows and then clears back to the full seeded list
- label filtering narrows and then clears back to the full seeded list

### Labels

- toggling a label assignment and favourite state mutates the exported row state
- creating a new label from bookmark label assignment immediately assigns it
- removing the last label assignment causes the bookmark to disappear under that label filter
- label manager create, rename, and delete complete through the real CRUD flow

### StudyPad and My Notes

- opening StudyPad from a selected bookmark label reaches the embedded StudyPad document path
- My Notes note mutation/delete is still supported at the service/controller layer, but the previous
  focused My Notes UI tests are no longer present

### Service-layer persistence

- bookmark filtering by label works at the store layer
- deleted labels are skipped when bookmark-label JSON is serialized for the reader
- deleting a label detaches existing bookmark relationships
- clearing a bookmark note deletes the persisted note row
- clearing a bookmark note removes it from the My Notes rebuild query

## Historical Result And Current Interpretation

Focused bookmark validation passed on 2026-03-16, but the original UI count/runtime claim is now
stale because three UI tests from that report no longer exist in `AndBibleUITests`. The current
rerunnable named subset in this report is:

- unit: `5` tests
- UI: `10` tests

This doc refresh did not rerun the simulator suite, so do not treat the old runtime or the
old UI count as current evidence. The checked-in named subset still gives the bookmark
domain rerunnable evidence for:

- bookmark-list search, filter, sort, selection, and deletion
- label assignment and label-manager CRUD
- StudyPad handoff from a selected label
- shared bookmark-note persistence semantics in the service layer

## Remaining Gap

The current bookmark parity gaps are:

- generic-bookmark visible workflows
- My Notes visible note update/delete workflows
- deeper StudyPad mutation coverage beyond handoff

Those areas remain `Partial` in `verification-matrix.md` until they have focused regression
coverage.
