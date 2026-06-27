# iOS Reader Parity Dispositions

This file records the places where iOS is deliberately taking a different path
to get to a similar result.

For the durable decision behind the reader document/modal routing split, see
[ADR 0002](../../adr/0002-route-reader-document-modals-through-shared-document-pipeline.md).
For the cross-domain owner categories used below, see
[ADR 0006](../../adr/0006-modal-presentation-ownership-for-android-parity.md).

## 1. Reader shell routing uses a native drawer plus a custom anchored overflow popup

- Status: intentional adaptation

What we do:

- iOS now mirrors Android's shell split with a left navigation drawer for
  primary destinations and a right overflow popup for reader-local toggles and
  options.
- The shell uses native SwiftUI/UIKit presentation and packaged Android-style
  assets rather than Android's original view classes.

Why this is fine:

- The parity goal is the resulting menu structure, ordering, and affordance
  semantics, not a literal port of Android widget plumbing.

## 2. Swipe navigation is implemented with native gestures, not Android view plumbing

- Status: intentional adaptation

What we do:

- iOS maps `bible_view_swipe_mode` onto native gesture recognizers and WebView
  scrolling behavior rather than Android's exact view stack.

Why this is fine:

- The parity goal is the resulting chapter/page/none behavior, not identical UI
  implementation.
- This disposition covers gesture plumbing only. Vue modal-open host gating is
  covered separately by the modal-state contract row in the verification matrix.

## 3. Compare uses the shared document pipeline

- Status: resolved parity drift, tracked by #123

What we do:

- Bridge-driven and reader-overflow Compare requests now build the same
  `compare: true` `MultiDocument` payload shape Android uses.
- The shared Vue `MultiDocument` path owns translation display, hide buttons,
  and restore behavior.

Why this is not a native iOS disposition:

- Android opens Compare through the fake compare document and Vue renders it
  with the shared `MultiDocument` path, including hide/restore translation
  behavior.
- The retired native iOS sheet is not the intended Android-parity endpoint.
- A future native Compare path would need its own ADR with a real iOS-only
  constraint or product requirement.

## 4. Reader fullscreen is coordinated by native shell state

- Status: intentional adaptation

What we do:

- Web content can request fullscreen toggles, but the actual fullscreen state is
  owned by the native reader shell.

Why this is fine:

- On iOS, hiding chrome, overlays, and bars is coordinated above the WebView,
  not inside the client bundle alone.

## 5. Strong's / dictionary routing uses the shared document pipeline

- Status: resolved parity drift

What we do:

- iOS presents Strong's / dictionary results as transient reader documents.
- The reader controller emits the dedicated `contentType: "strongs"`
  `StrongsDocument` payload and the pane owner decides whether to render it in
  the current pane or the configured links target window.

Why this is the parity endpoint:

- Android routes Strong's through normal document/window handling rather than an
  iOS-only native sheet.
- The shared Vue route still owns the Strong's-specific tabbed rendering,
  recursive Strong's navigation, morphology fragments, and "Find all
  occurrences" links.
- Reintroducing a native sheet would be a new parity decision, not a cleanup.

## 6. Some parity-sensitive reader inputs remain constrained by platform limits

- Status: documented constraint

What we do:

- Hardware volume-key scrolling does not exist as a functional reader feature on
  iOS even though the setting is preserved for parity and sync continuity.

Why this still remains a gap:

- iOS does not expose app-level interception of hardware volume buttons for this
  type of custom reader action.

## 7. Reader presentation routes must remain classified by owner

- Status: documented guardrail

What we do:

- The current reader sheets, modals, destinations, and state-backed transient
  routes are classified in
  [modal-ownership-matrix.md](modal-ownership-matrix.md).
- App-owned Android surfaces can remain native iOS app surfaces only when the
  behavior, choice set, and visual information architecture stay equivalent.
- Platform boundaries such as iOS sharing are acceptable only at the OS handoff
  point.
- WebView-owned document flows, such as multi-reference/cross-reference
  rendering, should move through the shared document pipeline rather than keep a
  native sheet.

Why this replaces the older audit language:

- The #122 audit was useful, but its broad "acceptable native surface" language
  made it too easy to preserve iOS sheets without re-checking ownership.
- ADR 0006 now requires an explicit owner category before a presentation route
  can be called parity.
