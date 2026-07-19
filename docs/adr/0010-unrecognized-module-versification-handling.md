---
adr: ADR-0010
title: "Unrecognized Module Versification Handling"
description: >-
  Decide how iOS treats a Bible module whose declared versification is not
  registered in the pinned libsword, versus Android/JSword rejecting it at load.
date: 2026-07-19
status: accepted
supersedes: []
superseded-by: null
decision-owner: "iOS parity maintainers + product"
deciders: ["iOS parity maintainers", "product"]
consulted:
  - "jsword SwordBookMetaData.adjustBookType"
  - "libsword VersificationMgr / VerseKey"
  - "SwordKit SwordManager / SwordVersification"
informed: ["AndBible iOS contributors"]
tags: [parity, versification, module-loading, android-divergence]
related-adrs: [ADR-0003]
related-work-items: ["PR #359", "PR #360"]
---

# 0010: Unrecognized Module Versification Handling

Status: Accepted

Date: 2026-07-19

## Context

A Bible module's `.conf` declares a `Versification` (v11n). Android and iOS
diverge on what happens when that name is **present but not recognized** by the
platform's versification library. (An **absent** `Versification` defaults to
`KJV` on both platforms — jsword `SwordBookMetaData` line 169 sets the default;
that case is not in scope.)

Confirmed behavior:

- **Android (JSword)** — `SwordBookMetaData.adjustBookType()`
  (`jsword/.../book/sword/SwordBookMetaData.java:899-904`): if
  `!Versifications.instance().isDefined(v11n)` it logs
  `"Book not supported: Unknown versification"`, sets `supported = false`, and
  returns. The book's `isSupported()` is then false, so AndBible does not load,
  render, or allow bookmarking it. This is a long-standing, correctness-driven
  design (JSword cannot map verses without the v11n's tables), not a recent
  choice — the surrounding git history (2014–2016) only touches logging/memory,
  never the rejection itself.

- **iOS (libsword)** — `SwordManager` has no `supported` gate;
  `VersificationMgr::getVersificationSystem(name)` returns null for an unknown
  name and SWORD falls back to KJV. **Empirically confirmed:** a module whose
  `.conf` is edited to `Versification=BogusV11n` is still listed
  (`installedModules: ["KJV"]`), loaded, and rendered under KJV
  (`verseOrdinal(Matt 1:1)=24118`; `rawEntry` returns the correct Matthew 1:1
  text). So iOS treats an unrecognized v11n as KJV and keeps the module usable.

Two consequences follow:

1. **The versification sets can differ.** libsword is pinned; JSword ships with
   AndBible. A v11n known to one but not the other is handled differently, so
   neither "always reject" nor "always accept" is automatically parity.
2. **Correctness depends on the module's real numbering.** SWORD reads a zText
   index (`.bzv`) by verse ordinal. If the module's data is genuinely
   KJV-numbered (a typo'd/custom conf name), reading it with a KJV key is
   **correct**. If the module truly uses a different canon libsword doesn't
   know, the KJV key **mis-indexes** it — shifted/garbled/missing verses.

### Risk of the current iOS behavior (accept + map as KJV)

- **KJV-compatible module (typo/custom name):** renders correctly; bookmarks
  store correct KJVA ordinals. iOS is strictly more permissive than Android
  here, with no harm.
- **Genuinely divergent module unknown to libsword (rare):**
  - Rendering is mis-indexed (verses shown under the wrong numbers).
  - Bookmarks store the KJV-rendered position's KJVA ordinal, so the note can be
    **off by the versification offset** (e.g. a whole Psalm, like the 9/10
    shift). On sync/export the note lands on the wrong canonical reference.
  - The module is visible on iOS but **absent on Android** (rejected) —
    cross-platform inconsistency and user confusion.
- **Data integrity:** the mapping-layer `unknown → KJV` fallback (PR #360)
  guarantees a *valid* KJVA ordinal is stored (never a raw source ordinal), so
  the failure mode is "wrong-but-canonical reference," not "garbage ordinal."

In practice this is a **low-frequency** edge: mainstream CrossWire modules use
registered versifications. The unknown case requires a malformed/custom `.conf`
or a v11n newer than the pinned libsword.

## Decision

Accepted and implemented:

1. **Match Android for truly-unrecognized versifications.** A Bible module whose
   declared `Versification` is not registered in libsword is treated as
   **unsupported** — not offered for reading or bookmarking — mirroring JSword's
   `isSupported() == false`. Rationale: iOS should not render, and let users
   annotate, content it cannot correctly interpret; doing so risks mis-numbered
   verses, offset notes, and modules that exist on iOS but not Android.

   Implemented via `SwordVersification.isVersificationDefined(_:)` (backed by
   `SWVersification_isSystemDefined`, mirroring JSword `Versifications.isDefined`),
   applied where the reader partitions installed modules
   (`BibleReaderSwordCoordinator.configure` and the Compare builder's fallback):
   a Bible module is included in the readable set only when its versification is
   defined. The unsupported module stays in the raw `installedModules` inventory,
   so it remains manageable/uninstallable — iOS is intentionally more forgiving
   than Android on management while matching it on reading.

2. **Keep libsword's av11n tables reasonably current** with the JSword version
   AndBible ships, so a *legitimate* versification is recognized on both
   platforms and neither side rejects a module the other accepts. This is the
   real parity lever; rejection is only the fallback for genuinely-unknown v11n.

3. **Retain the mapping-layer `unknown → KJV` fallback as defense-in-depth**
   (already in PR #360). It is a safety net that keeps any residual or legacy
   bookmark's stored value a valid KJVA ordinal rather than a raw source ordinal,
   under either decision. It does not need to change for this ADR.

This is the "good UX decision," not cruft: accepting modules we cannot interpret
is the "keep a random thing working" path; rejecting them is the principled,
Android-aligned, cross-platform-consistent choice.

### Alternatives considered

- **A — Status quo (accept + render as KJV).** Simplest; more permissive than
  Android; correct for KJV-compatible modules. Rejected as the primary rule
  because it silently mis-renders divergent modules and creates offset notes and
  iOS/Android inconsistency.
- **C — Accept with a visible "unsupported versification, numbering may be
  inaccurate" warning.** A middle ground that keeps the module readable while
  flagging the risk. Viable if product wants to preserve read access to
  unrecognized modules; still permits offset bookmarks, so weaker on data parity.

## Consequences

- Enables true parity: the same modules are usable (or not) for reading on iOS
  and Android.
- The readable-Bible gate lives at the reader boundary
  (`BibleReaderSwordCoordinator`), not in `SwordManager.installedModules`, so
  management/uninstall of an unsupported module is preserved (more forgiving than
  Android, low risk).
- Requires a maintenance commitment to keep libsword current, or legitimately-new
  versifications would be treated as unsupported on iOS until libsword is updated.
- The `unknown → KJV` mapping fallback (PR #360) is retained as defense-in-depth:
  it keeps any residual/legacy bookmark's stored value a valid KJVA ordinal even
  though such modules are no longer offered for new reading/bookmarking.
- Not chosen: Alternative C (render with a warning). If product later prefers
  keeping unrecognized modules readable, revisit this ADR and add the warning
  affordance instead of the read-time exclusion.

## Related

- PR #359 (versification engine), PR #360 (active-versification projection +
  `unknown → KJV` mapping fallback).
- jsword `SwordBookMetaData.java:899-904` (Android rejection), line 169 (KJV
  default for absent v11n).
- SwordKit `SwordVersification` (`mapVerseToKJVA` / `mapVerseFromKJVA` /
  `decodeOrdinal`), `SwordManager.installedModules`.
