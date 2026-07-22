---
adr: ADR-0010
title: "Registered Versification Boundary"
description: >-
  Define the shared Android-derived registry, module-admission rule, and
  fail-closed mapping behavior for named Bible versifications.
date: 2026-07-19
status: accepted
supersedes: []
superseded-by: null
decision-owner: "iOS parity maintainers + product"
deciders: ["iOS parity maintainers", "product"]
consulted:
  - "jsword SwordBookMetaData.adjustBookType"
  - "jsword Versifications and mapping resources"
  - "libsword VersificationMgr / VerseKey"
  - "SwordKit SwordManager / SwordVersification"
informed: ["AndBible iOS contributors"]
tags: [parity, versification, module-loading, android]
related-adrs: [ADR-0003]
related-work-items: ["PR #359", "PR #360"]
---

# 0010: Registered Versification Boundary

Status: Accepted

Date: 2026-07-19

## Context

A Bible module's `.conf` may declare a named `Versification`. Android accepts the
module only when the pinned JSword `Versifications` registry defines that exact
name; an absent value defaults to `KJV`. A present but unknown name marks the book
unsupported, so it never enters Android's installed-book registry.

iOS has two relevant authorities:

- bundled JSword canon dimensions and mapping resources, which define Android's
  conversion behavior;
- libsword's compiled canon tables, which define which modules iOS can address and
  render correctly.

Those registries overlap but are not interchangeable. Accepting a libsword-only
name exposes a module Android rejects. Accepting a JSword-only name lets iOS load a
module whose coordinates libsword cannot safely render. Treating either unknown
case as KJV creates a valid-looking reference in the wrong canon.

## Decision

1. `JSwordVersificationRegistry` in SwordKit owns the single pinned Android-derived
   registry. Its canon fixture and mapping resources all come from JSword revision
   `0da7412d7716731f402c9002a0b92e4c00ef30eb`. Revision mismatch, malformed data,
   missing data, unknown names, and mis-cased names fail closed. Only an absent name
   receives Android's `KJV` default.

2. A Bible module is supported only when its versification belongs to both the
   pinned JSword registry and libsword's renderable registry. `ModuleInfo.isSupported`
   owns that intersection, and `SwordManager.installedModules()` plus
   `module(named:)` apply it at the installed-book boundary. Non-Bible modules are
   unaffected because they do not use verse-keyed canon addressing.

3. BibleCore's `VersificationMapper` owns Android-equivalent conversion. It uses the
   pinned JSword canon and property resources, returns structured addressability,
   and never persists or emits unchanged source coordinates under a target canon
   after conversion failure.

4. `SwordVersification` and the CLibSword adapter remain lower-level SWORD
   primitives. Generalized mapping is canonical; compatibility wrappers delegate to
   it. Empty names default to KJV, while unknown non-empty source or target names
   return failure. High-level feature code must use `VersificationMapper` when exact
   Android behavior is required.

## Consequences

- Android and iOS expose the same JSword-supported module population, bounded by
  what iOS can render correctly.
- An unsupported Bible remains dormant on disk and is absent from reader, picker,
  installed-download, and import/export inventories, matching Android's registry
  behavior.
- Adding or updating a versification requires updating the pinned JSword fixture and
  resources together, then verifying libsword supports the same name before iOS can
  admit modules that declare it.
- Conversion failures are explicit. Callers must show an unavailable state, skip an
  unsafe mutation, or retain source-domain metadata; they must not relabel the source
  ordinal as KJV/KJVA.
- Compatibility API names remain available for callers, but they do not restore the
  former unknown-to-KJV fallback.

## Alternatives Considered

- **Accept every libsword-known name.** Rejected because Android can reject the same
  module and its JSword conversion contract is unavailable.
- **Accept every JSword-known name.** Rejected because libsword may not safely render
  the module on iOS.
- **Treat unknown names as KJV.** Rejected because it can silently display and persist
  the wrong physical verse.
- **Warn but render unsupported modules.** Rejected because a warning does not prevent
  offset bookmarks, notes, memorization state, and progress from crossing platforms.

## Related

- JSword `SwordBookMetaData.adjustBookType()` and `Versifications` registry.
- SwordKit `JSwordVersificationRegistry`, `ModuleInfo.isSupported`, `SwordManager`,
  and `SwordVersification`.
- BibleCore `JSwordCanon`, `JSwordVersificationMapping`, and `VersificationMapper`.
