---
adr: ADR-0011
title: "Reader Annotation Parity Divergences"
description: >-
  Record the intentional Android divergences kept after the My Notes /
  StudyPad / links-window parity audit, and the follow-ups that need their
  own scoped changes.
date: 2026-08-08
status: accepted
supersedes: []
superseded-by: null
decision-owner: "iOS parity maintainers"
deciders: ["iOS parity maintainers"]
consulted:
  - "and-bible LinkControl / WindowControl / CurrentMyNotePage"
  - "and-bible ClientPageObjects serialization"
  - "and-bible HistoryManager"
informed: ["AndBible iOS contributors"]
tags: [parity, mynotes, studypad, links-window, history, android]
related-adrs: [ADR-0003, ADR-0008]
related-work-items: ["PR #382", "issue #376"]
---

# 0011: Reader Annotation Parity Divergences

Status: Accepted

Date: 2026-08-08

## Context

A deliberate parity audit of the My Notes, StudyPad, and links-window surfaces
against Android produced a set of behavioral fixes (links-window routing, My
Notes chapter paging and row inclusion, StudyPad scroll targets and row
queries, payload details). The same audit surfaced divergences that we are
intentionally keeping, plus gaps that need their own scoped work. This ADR
records both so future audits do not re-litigate them one bug report at a
time.

## Accepted intentional divergences

- **Bridge UUID casing.** Android serializes lowercase ids (`IdType`
  hex); iOS serializes uppercase `UUID.uuidString` everywhere, including the
  `journal_<id>` document id. Nothing on either platform parses these ids
  back out of the wire format, and every iOS `hashCode` (and therefore every
  shared-DOM `o-<hashCode>` element id) derives from the uppercase string, so
  changing the casing would risk regressions for zero behavioral gain.
- **Persisted ordinal trust gate.** `BookmarkStore` hides Bible rows whose
  KJVA coordinates fail `PersistedOrdinalTrustPolicy`. Android has no
  equivalent state — its rows are natively KJVA-authoritative — while iOS
  quarantines legacy rows whose coordinates could belong to another ordinal
  domain until `PersistedOrdinalTrustMigrationService` verifies them.
  Rendering quarantined coordinates would place rows on wrong verses, a
  failure mode Android cannot reach.
- **Window creation exits maximize.** Android's window creation leaves a new
  window active but hidden behind the maximized pane; iOS clears
  `maximizedWindowId` so the created window is visible. Link results never
  reach this path while maximized because the pane-level links gate mirrors
  Android's `checkIfOpenLinksInDedicatedWindow`.
- **`setup_content` toolbar offsets are always zero.** Android sends live
  toolbar offsets because its chrome overlays the WebView; iOS positions the
  WebView below native chrome, sends `topOffset`/`bottomOffset` of 0 for
  every document type uniformly, and never emits `set_offsets`.
- **Links-window controller retry fallback.** `BibleWindowPane` retries
  links-controller registration briefly and falls back to the source pane;
  Android assigns the links document synchronously. The fallback only
  matters under slow SwiftUI pane creation and degrades to Android's
  "open here" behavior.

## Confirmed-parity behaviors that read as bugs

- **Chained links windows.** A link tapped inside the dedicated links window
  (for example a My Notes row's verse-number link while My Notes occupies the
  links window) opens a *new* chained links window, exactly like Android's
  `Window.targetLinksWindow`. On a phone this shrinks every pane and moves
  focus to the new pane, which can scroll the My Notes heading out of view.
  Verified against a live trace and explicitly decided (2026-08-09) to keep
  Android's behavior rather than reuse the tapped pane or route to the main
  window.

## Follow-ups that need their own scoped changes

- **History semantics.** Android records the pre-navigation location before
  every `setCurrentDocumentAndKey`, including StudyPad / My Notes / Multi /
  Memorize documents; iOS records only Bible navigation and stores the
  destination. Aligning this touches sync-validated `HistoryItem`
  persistence and the history-restore routing, and must be designed against
  the Android workspace-database contract.
- **Per-link window-mode override.** Android's link long-press menu offers
  open-in-this/new/special-window (`WINDOW_MODE_*`); iOS has no link context
  menu. This is a new feature: WKWebView link context menus plus a mode
  override threaded through every pane link route.
- **Divergent-canon My Notes shape.** Android derives the My Notes page by
  mapping the source module's whole chapter into KJVA (the span can cross
  KJVA chapter bounds, and the heading renders JSword's range name); iOS
  always renders exactly one KJVA chapter with a fixed "Book N" heading.
  Chapter stepping also does not wrap at the canon boundary the way
  Android's `BibleTraverser` does.

## Consequences

Future parity reports touching these areas should be checked against this
ADR first. Accepted divergences require a new decision here before being
"fixed"; follow-ups should reference this ADR when they land.
