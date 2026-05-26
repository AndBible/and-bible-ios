# iOS Reader Parity Dispositions

This file records the places where iOS is deliberately taking a different path
to get to a similar result.

For the durable decision behind the reader document/modal routing split, see
[ADR 0002](../../adr/0002-route-reader-document-modals-through-shared-document-pipeline.md).

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

## 3. Compare native sheet presentation is reclassified as drift

- Status: confirmed parity drift, tracked by #123

What we do:

- Bridge-driven compare requests are currently presented through UIKit/SwiftUI
  sheet presentation.

Why this is not a disposition anymore:

- Android opens Compare through the fake compare document and Vue renders it
  with the shared `MultiDocument` path, including hide/restore translation
  behavior.
- The iOS native sheet is useful current behavior, but it should not be treated
  as the intended Android-parity endpoint.
- The intended endpoint is to replace the native sheet with the shared
  Vue/document compare flow unless a future ADR records a real iOS-only
  exception.

## 4. Reader fullscreen is coordinated by native shell state

- Status: intentional adaptation

What we do:

- Web content can request fullscreen toggles, but the actual fullscreen state is
  owned by the native reader shell.

Why this is fine:

- On iOS, hiding chrome, overlays, and bars is coordinated above the WebView,
  not inside the client bundle alone.

## 5. Dedicated Strong's native sheet presentation is reclassified as drift

- Status: confirmed parity drift, tracked by #8

What we do:

- iOS presents the Strong's / dictionary surface as a native bottom sheet.
- Inside that sheet, iOS now routes Strong's content through the dedicated
  `StrongsDocument` client path with tabbed per-dictionary rendering, rather
  than relying on generic multi-document rendering.

Why this is not a disposition anymore:

- Preserving `contentType: "strongs"` fixed an important embedded-client
  rendering gap, but Android still owns Strong's through the normal
  document/window pipeline.
- The remaining iOS-native sheet ownership is tracked as drift by #8.
- The intended endpoint is to replace the native sheet with the shared
  Vue/document pipeline while preserving the Strong's-specific route.

## 6. Some parity-sensitive reader inputs remain constrained by platform limits

- Status: documented constraint

What we do:

- Hardware volume-key scrolling does not exist as a functional reader feature on
  iOS even though the setting is preserved for parity and sync continuity.

Why this still remains a gap:

- iOS does not expose app-level interception of hardware volume buttons for this
  type of custom reader action.

## 7. Reader-adjacent native app surfaces remain acceptable adaptations after the modal audit

- Status: intentional adaptations or acceptable platform surfaces

What the #122 audit classified as acceptable for now:

- Book chooser and reference chooser: Android also uses native chooser flows
  here, so iOS sheet presentation is an adaptation rather than confirmed
  Vue-modal drift.
- Search, bookmarks list, history, settings, reading plans/progress, workspaces,
  about, sync/import-export/help, speak controls, and dictionary/general-book/
  map/EPUB browsers: these are app-level/native surfaces or Android native
  activity equivalents, not confirmed Vue `ModalDialog` replacements.
- Label assignment: Vue bookmark label actions call Android native
  `assignLabels`; iOS `LabelAssignmentView` is equivalent in kind.
- Memorize: iOS already emits the Vue memorize document, so no new reader-modal
  drift was identified there.
