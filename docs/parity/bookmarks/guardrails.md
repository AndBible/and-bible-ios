# BOOKMARKS-703 Guardrails

## Purpose

Prevent high-risk bookmark regressions by making the non-negotiable
compatibility rules explicit for changes in:

- `Sources/BibleCore/Sources/BibleCore/Services/BookmarkService.swift`
- `Sources/BibleCore/Sources/BibleCore/Database/BookmarkStore.swift`
- `Sources/BibleUI/Sources/BibleUI/Bookmarks/BookmarkListView.swift`
- `Sources/BibleUI/Sources/BibleUI/Bookmarks/LabelAssignmentView.swift`
- `Sources/BibleUI/Sources/BibleUI/Bookmarks/LabelManagerView.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`

## Rules

1. Do not collapse bookmark rows and note rows into one persistence concept.

   iOS currently preserves the Android-compatible split between bookmark rows
   and separate note-bearing entities. “Simplifying” that split is a parity
   change, not a local cleanup.

2. Treat label assignment semantics as contract surface.

   Assignment, favourite state, primary-label behavior, and inline label
   creation are all user-visible parity behavior. Renaming or redefining these
   interactions casually will break expected bookmark/StudyPad outcomes.

3. Preserve the separation between bookmark list and My Notes unless the
   contract docs change.

   iOS intentionally adapts Android’s unified bookmark-plus-notes browsing into
   a native bookmark list plus a separate My Notes surface. That separation is
   documented behavior, not an accident.

4. Treat StudyPad handoff from labels as part of the bookmark contract.

   Label chips and “Open StudyPad” are not merely convenience affordances. They
   are part of how bookmark labels connect to StudyPad workflows on iOS.

5. Do not remove generic-bookmark support because the current UI coverage is
   thinner.

   Generic bookmarks still exist in persistence and bridge logic. Limited UI
   coverage is not a license to prune those branches casually.

6. Bookmark list search, filter, and sort behavior should be treated as stateful
   workflow behavior, not presentation-only polish.

   Changes to list querying or row ordering can silently break user workflows
   even when the screen still “looks fine”.

7. New bookmark-domain behavior must update the docs in the same slice.

   When adding or changing bookmark contract behavior, update:

   - `docs/parity/bookmarks/contract.md`
   - `docs/parity/bookmarks/dispositions.md` when behavior is iOS-specific
   - `docs/parity/bookmarks/verification-matrix.md` if status changes
   - `docs/parity/bookmarks/regression-report.md` when validation scope changes

## Validation Expectations

At minimum, bookmark-adjacent changes should keep the focused workflow coverage
described in `regression-report.md` green, especially:

- bookmark-list search, filter, sort, row navigation, and row deletion
- label assignment create/remove/toggle paths
- label manager CRUD
- StudyPad handoff from bookmark labels
- note-row persistence regressions in `AndBibleTests`

If a change touches one of the still-partial areas, raise the bar and add
focused coverage rather than relying on the existing bookmark subset alone.

## Current Automation Status

- The repo currently has focused bookmark-domain UI coverage and targeted unit
  regressions for note persistence.
- Current protection is a combination of:
  - bookmark workflow tests in `AndBibleUITests`
  - note persistence regressions in `AndBibleTests`
  - explicit parity documentation in this directory

## Potential Improvements

- add focused UI coverage for generic-bookmark visible workflows
- add focused UI coverage for My Notes visible note update/delete workflows
- add focused UI coverage for broader StudyPad create, reorder, and delete behavior
- add machine-readable snapshots of bookmark sort and filter state contracts if the UI surface grows
  materially more complex
