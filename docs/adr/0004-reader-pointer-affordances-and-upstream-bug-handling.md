# 0004: Reader Pointer Affordances And Upstream Bug Handling

Status: Accepted

Date: 2026-06-05

## Context

Reader parity work targets Android-equivalent behavior, not accidental bug
replication. When Android has an implemented behavior, iOS should match it
unless there is a real platform constraint or a source-backed reason to improve
the shared behavior.

#174 added Android-style chapter read controls to the iOS reader WebView. The
Android shared Vue reader keeps the mark-as-read icon clickable after a chapter
has already been marked read. Repeated clicks are intentional because Android's
read-history model records multiple read instances for the same chapter.

The Android WebView CSS also changes the already-read icon cursor to `default`.
That is mostly inert on touch-first Android devices, but it is misleading in iOS
pointer contexts because iPadOS and Mac Catalyst users can interact with the
embedded reader using a pointer. The control remains actionable, so the cursor
should still communicate that it is actionable.

The same parity review found an Android-side RTL bug in the section title
scroll button. Android currently positions the button with a physical
`right: 0` inset. The correct shared behavior is a logical inline-end inset so
RTL layouts mirror the button placement. That should be fixed upstream in
Android's shared Vue source rather than copied into iOS.

## Decision

iOS reader WebView controls may use platform-appropriate pointer affordances
when all of these are true:

- the Android source behavior remains functionally matched
- the Android difference is a touch-first cursor styling artifact rather than a
  different user workflow
- iOS pointer users would otherwise see an affordance that contradicts the
  control's actual behavior
- the deviation is documented and covered by behavior-focused tests

For the chapter read control, iOS keeps the already-read mark-as-read button as
a pointer-actionable control. This is an intentional iOS pointer-context
deviation from Android's `cursor: default`, not a change to the read-history
contract. Repeated manual reads remain allowed and continue to record additional
read-history entries.

When parity work discovers a likely Android bug, iOS should not copy the bug
for superficial visual parity. The team should:

- confirm the Android source behavior and affected shared Vue/native path
- implement the correct iOS behavior when the fix is clear and low risk
- open an upstream Android issue with source references and expected behavior
- link the upstream issue from the relevant PR or ADR when the iOS behavior now
  intentionally differs from current Android source

## Consequences

- Strict parity still means matching Android behavior and workflow, not
  preserving Android defects that are already identified.
- iOS may preserve pointer-correct WebView affordances for controls that remain
  actionable after their visual state changes.
- Future reviewers should not revert the iOS mark-as-read cursor behavior merely
  because Android's CSS currently sets `cursor: default`.
- The RTL title scroll placement should be considered an upstream Android bug,
  not an iOS deviation to undo.
- If Android later fixes the shared Vue title scroll CSS, iOS and Android should
  converge on the same logical inline-end implementation.

## Related

- [ADR 0002: Route Reader Document Modals Through The Shared Document Pipeline](0002-route-reader-document-modals-through-shared-document-pipeline.md)
- [Reader parity contract](../parity/reader/contract.md)
- [Android issue #3824: Fix title scroll button placement in RTL reader layouts](https://github.com/AndBible/and-bible/issues/3824)
- AndBible iOS PR #181
- #174
