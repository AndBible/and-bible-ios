# READER-703 Guardrails

## Purpose

This file is here to make the easy-to-break reader assumptions explicit when
someone is changing:

- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderInteractionPolicies.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/CrossReferenceView.swift`
- `Sources/BibleView/Sources/BibleView/WebViewCoordinator.swift`
- `Sources/BibleUI/Sources/BibleUI/Shared/HistoryView.swift`
- `Sources/BibleUI/Sources/BibleUI/Workspace/WorkspaceSelectorView.swift`

## Things To Keep In Mind

1. Treat the reader shell as the owner of top-level reading workflows.

   Drawer routing, overflow-menu routing, history presentation, workspace
   selection, Compare routing, Strong's routing, multi-reference routing, Vue
   modal state, and fullscreen state all belong to the reader shell. If they
   start drifting into ad hoc view-local ownership, parity usually gets messier
   fast.

2. Preserve the reader handoff from adjacent domains.

   Search, history, bookmarks, and workspaces are only really correct if they
   can move the active reader to the intended location or state. A screen that
   still opens but no longer hands back to the reader correctly is still a
   parity regression.

3. Preserve persisted history semantics.

   History clear and single-row delete are persistent mutations, not temporary
   UI edits. Changes to `HistoryView` or its backing reader integration should
   keep reopen behavior intact.

4. Treat workspace selection as reader-owned state, not only a workspace-domain
   concern.

   The reader is where active workspace changes become visible. Create, rename,
   clone, and delete all need to keep the reader-shell invariants intact.

5. Fullscreen, swipe-mode, and auto-fullscreen behavior are parity-sensitive.

   These branches are easy to break through gesture or layout refactors. Thin
   policy coverage is useful, but it is not a good reason to simplify them
   casually. Vue modal-open state is part of the host-navigation contract and
   should not be bypassed by native swipe, keyboard, or page/chapter navigation.

6. Reader config emission into the embedded client is part of the parity
   surface.

   `buildConfigJSON()`, `updateConfig()`, and display-setting propagation are
   how reader state reaches the embedded document client. Changes there are
   bridge-affecting parity work, not isolated cleanup.

7. Reader changes should update the docs in the same slice.

   When adding or changing reader contract behavior, update:

   - `docs/parity/reader/contract.md`
   - `docs/parity/reader/dispositions.md` when behavior is iOS-specific
   - `docs/parity/reader/verification-matrix.md` if status changes
   - `docs/parity/reader/regression-report.md` when validation scope changes

## Validation Expectations

At minimum, reader-adjacent changes should keep the focused workflow subset in
`regression-report.md` green, especially:

- reader drawer/overflow routing
- search-result navigation back into the reader
- history jump-back plus clear/delete persistence
- workspace selector create/switch from the reader shell
- restored-position highlight behavior
- bridge-driven compare and Strong's document-pipeline payload construction

If a change touches one of the still-partial areas, it is worth raising the bar
and adding focused coverage instead of leaning only on the current reader
subset.

## Current Automation Status

- The repo currently has focused reader-shell UI coverage for drawer/overflow
  routing, history workflows, and workspace switching plus unit regressions for
  restored-position highlight behavior, reader config payloads, double-tap
  fullscreen gating, compare presentation payload construction, horizontal
  swipe-mode mapping, and auto-fullscreen threshold behavior.
- In practice, current protection is a mix of:
  - reader workflow tests in `AndBibleUITests`
  - reader-adjacent payload regressions in `AndBibleTests`
  - explicit parity documentation in this directory
  - adjacent-domain coverage where reader handoff is part of the assertion

## Useful Next Improvements

- implement and cover #124 multi-reference / cross-reference document-pipeline routing
- add a tighter guardrail around reader config emission into the embedded document client
