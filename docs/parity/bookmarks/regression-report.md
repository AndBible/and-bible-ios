# BOOKMARKS-702 Regression Report

Date: 2026-05-16

## Scope

Regression verification for the current bookmark parity surface, covering:

- native bookmark-list search, filter, sort, selection, and deletion
- generic bookmark visibility plus label assignment from the native bookmark list
- label assignment and label-manager mutation flows
- StudyPad handoff from a real bookmark workflow
- StudyPad text-entry creation from the visible StudyPad document with persisted rebuild evidence
- visible My Notes note update/delete from the production reader path
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
- `AndBibleUITests/testGenericBookmarkVisibleWorkflowAssignsLabelFromBookmarkList`
- `AndBibleUITests/testLabelAssignmentTogglesFavouriteAndAssignment`
- `AndBibleUITests/testBookmarkListLabelAssignmentCreatesAndAssignsNewLabel`
- `AndBibleUITests/testBookmarkListLabelAssignmentRemovalHidesBookmarkUnderFilter`
- `AndBibleUITests/testLabelManagerCreateRenameDeleteFlow`
- `AndBibleUITests/testBookmarkListOpensStudyPadForSelectedLabel`
- `AndBibleUITests/testStudyPadCreateTextEntryPersistsAcrossReopen`
- `AndBibleUITests/testMyNotesNoteUpdateAndDeletePersistsFromVisibleWorkflow`

## Expected Assertions Covered

### Bookmark list

- selecting a seeded bookmark navigates the reader to the bookmarked reference
- deleting one bookmark preserves the other seeded row across reopen
- changing sort order reorders the visible rows
- text search narrows and then clears back to the full seeded list
- label filtering narrows and then clears back to the full seeded list
- a seeded generic bookmark appears in the native bookmark list by module/key reference
- assigning a label to the generic bookmark through the visible row makes it appear under that
  label filter

### Labels

- toggling a label assignment and favourite state mutates the exported row state
- creating a new label from bookmark label assignment immediately assigns it
- removing the last label assignment causes the bookmark to disappear under that label filter
- label manager create, rename, and delete complete through the real CRUD flow

### StudyPad and My Notes

- opening StudyPad from a selected bookmark label reaches the embedded StudyPad document path
- adding a StudyPad text entry from the visible document updates the visible state export and
  remains present after returning to Bible and reopening the StudyPad from storage
- opening My Notes from the reader reaches the embedded My Notes document path
- editing a visible My Notes note persists through the bridge and is present after rebuilding
  the document
- deleting the visible My Notes note-backed row removes it from the rebuilt document

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
- UI: `13` tests

This doc refresh reran the focused StudyPad handoff and text-entry creation UI tests, but did not
rerun the full simulator suite. Do not treat the old runtime as current evidence. The checked-in
named subset still gives the bookmark domain rerunnable evidence for:

- bookmark-list search, filter, sort, selection, and deletion
- generic-bookmark visibility and label assignment from the bookmark list
- label assignment and label-manager CRUD
- StudyPad handoff from a selected label and focused text-entry creation persistence
- visible My Notes update/delete from the reader-owned document path
- shared bookmark-note persistence semantics in the service layer

## Remaining Gap

No bookmark parity gap is currently tracked in this report. The first StudyPad mutation regression
locks text-entry creation beyond handoff; reorder and delete breadth can be added later as focused
hardening without keeping the bookmark matrix partial.
