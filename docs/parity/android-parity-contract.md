# Android Parity Contract

Date: 2026-05-08

## Purpose

This contract defines the long-term target for `and-bible-ios`: functional and
visual parity with Android AndBible.

Swift, SwiftUI, UIKit, WKWebView, and SwiftData do not need to mirror Android's
Kotlin, Android View, WebView, and Room internals. The user-facing result should
still be indistinguishable in behavior and presentation unless an explicit iOS
platform constraint is documented.

Use this document as the parent contract for every domain-specific parity file
under `docs/parity/`.

Architecture Decision Records under `docs/adr/` record durable choices that
shape this contract or a domain's parity posture. They do not replace the
parity docs. Current status, verification evidence, and next actions belong in
this tree.

## Source Of Truth

The Android checkout is the behavior and visual oracle.

When a question is not settled by iOS code or docs, inspect the local Android
checkout at a configurable sibling path such as `../and-bible`. Do not hardcode
that path into tracked source.

Relevant Android evidence can include:

- Kotlin controllers, services, activities, fragments, and adapters
- Android XML layouts, menus, drawables, and string resources
- `app/bibleview-js/src/` shared document client code
- Android database schemas and sync table definitions
- Android tests and production behavior when available

## Parity Standard

A parity area is complete only when all three dimensions are satisfied.

### Functional Parity

iOS must expose the same user-visible capabilities as Android:

- the same primary actions, secondary actions, destructive actions, and disabled
  states
- the same state transitions and persistence semantics
- the same data import, export, sync, and conflict behavior
- the same bridge method names, argument order, payload shapes, response timing,
  and error handling for shared WebView-facing APIs
- the same visible error, empty, loading, authentication, and confirmation states

Implementation can differ. Observable behavior should not differ.

### Visual Parity

iOS screens should match Android's visible product contract:

- same screen purpose, entry points, and navigation hierarchy
- same control set, labels, ordering, grouping, and destructive/cancel affordances
- same reader chrome concepts, document presentation, modal/dialog structure, and
  transient overlays
- same icon semantics where platform iconography permits
- same state-specific content, including empty/loading/error/authentication states
- same localization meaning, not just presence of string keys

Platform-native controls are allowed only when they preserve the same visual
information architecture and user outcome. A native iOS sheet can replace an
Android dialog, for example, but the offered choices, default/cancel/destructive
semantics, and follow-up behavior must remain equivalent.

### Architecture Parity

Architecture exists to keep functional and visual parity easy to verify.

iOS should not mirror Android implementation classes one-for-one. Instead, iOS
should preserve Android contracts through small, named adapters:

- bridge adapters for `window.android.*` and async `callId` behavior
- sync adapters for Android sync category and table semantics
- data mappers for Android-shaped snapshots, patches, and payloads
- view models or coordinators for screens with nontrivial state machines
- focused SwiftUI views for visual surfaces

If a parity behavior requires reading one very large view/controller to understand
both UI and business behavior, that is architectural drift even if the feature
works today.

## Explicit Divergence

iOS may diverge only when at least one condition is true:

- iOS does not expose the necessary platform capability.
- Apple platform policy or API constraints prevent the Android behavior.
- Product scope intentionally excludes the Android feature on iOS.
- The Android UI pattern is replaced by a native iOS presentation that preserves
  the same choices and outcome.

Every divergence must have:

- the Android behavior being diverged from
- the iOS behavior users will see
- the reason for divergence
- the validation that prevents accidental expansion or regression
- a re-evaluation trigger, if platform or product constraints may change

Undocumented absence is a parity gap, not a divergence.

## Status Vocabulary

Use these statuses consistently across domain matrices and tracking issues:

- `Pass`: implemented and backed by code evidence plus focused validation.
- `Visual Pass`: implemented and backed by visual/screenshot or UI hierarchy
  validation against Android-equivalent expectations.
- `Adapted Pass`: different implementation or presentation, explicitly
  documented, with equivalent user outcome.
- `Partial`: implemented or exposed, but missing focused evidence or visual
  validation.
- `Missing`: Android has user-visible or bridge/API behavior that iOS does not
  implement.
- `Documented Divergence`: intentionally different, with a written reason and
  validation boundary.
- `Automation Gap`: behavior is documented but not protected by a repeatable
  guardrail, unit test, UI test, screenshot comparison, or machine-readable
  inventory.

Do not use `Pass` for a visually important surface that has only service-level
unit coverage. Use `Partial` until the user-visible path is covered.

## Anti-God-Class Guardrails

Large parity classes make drift harder to see. These are review triggers, not
mechanical failure thresholds:

- A parity-sensitive view/controller over 800 lines needs a named owner for each
  responsibility and a clear extraction path.
- A type that owns more than one of UI layout, navigation, persistence, bridge
  dispatch, payload building, sync orchestration, and domain mutation should not
  gain another responsibility without extracting one first.
- New Android-alignment work should prefer a small adapter, service, view model,
  mapper, or subview over adding another branch to a reader, settings, or bridge
  hub.
- Bridge dispatch can remain centralized for routing, but domain behavior should
  live outside the dispatcher.
- SwiftUI files may compose screens, but nontrivial state machines should move to
  testable coordinators or models.

When extraction competes with shipping a parity fix, ship the behavior behind a
clear seam and create a follow-up extraction task in the same parity domain.

## Required Ledgers

Each parity-sensitive domain should maintain or link to ledgers that answer:

- Android surface: what Android exposes.
- iOS surface: what iOS exposes.
- Status: pass, adapted pass, partial, missing, divergence, or automation gap.
- Evidence: tests, screenshots, guardrail scripts, direct source references.
- Owner area: the iOS file or adapter responsible for keeping the contract.
- Next action: implement, document divergence, add visual validation, or add
  machine-readable guardrail.

Existing examples:

- `settings/baselines/` for localization guardrails
- `bridge/baselines/android-bridge-gap-inventory.json` for bridge method breadth

Future ledgers should be added where repeated manual comparison is currently
required, especially visual screen structure and shared payload schemas.

## Validation Ladder

Use the cheapest validation that proves the user-facing claim.

1. Contract inspection: Android and iOS source references agree.
2. Unit or service test: state transition, parser, mapper, payload, or sync
   behavior is deterministic.
3. UI test: the visible workflow is exercised through the real screen.
4. Visual check: screenshots or UI hierarchy assertions verify screen structure,
   controls, labels, and state-specific presentation.
5. Drift guardrail: a script or machine-readable inventory fails when Android or
   iOS changes the contract silently.

For visual parity claims, step 3 alone is not enough unless the UI test asserts
the visible structure and state, not just navigation success.

## Change Rules

When changing parity-sensitive code:

1. Identify the Android behavior or visual surface first.
2. Decide whether the change is implementation, visual, behavioral, divergence,
   or automation work.
3. Keep Android-facing contracts stable unless Android and iOS are changed
   together.
4. Update the domain contract, disposition, verification matrix, and regression
   report when status changes.
5. Add or update the relevant ledger when the changed surface can drift again.
6. Avoid expanding parity-critical hub files unless there is no smaller adapter
   or coordinator to own the behavior.
7. Add or update an ADR when the change records a durable architecture,
   platform-divergence, or documentation-ownership decision rather than only a
   status or validation update.

## Current Priority Interpretation

Under this contract, the current repo is strongest where there are
machine-readable ledgers or focused user-visible workflows:

- settings localization and preference contracts
- bridge method gap inventory
- supported sync categories
- core bookmark-list, search, reading-plan, reader-shell workflows

The remaining priority is not a full architecture rewrite. The priority is to
turn each current `Partial`, `Missing`, or `Automation Gap` into one of:

- implemented and visually/functionally validated parity
- documented iOS divergence
- a small adapter/coordinator plus a repeatable drift check
