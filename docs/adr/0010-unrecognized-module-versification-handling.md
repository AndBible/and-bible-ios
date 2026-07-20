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

- **iOS (libsword)** — before this ADR, `SwordManager` had no `supported` gate;
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

1. **Match Android fully: an unsupported module is invisible everywhere.** A Bible
   module whose declared `Versification` is not registered in libsword is treated
   as **unsupported** — mirroring JSword's `SwordBookMetaData.isSupported() == false`,
   which keeps the book out of `Books.installed()` entirely. It is not readable, not
   in any picker, not shown as installed in Downloads (so it appears as
   re-downloadable, which overwrites and heals a broken conf), and not listed in
   Settings/Import-Export. It lies dormant on disk exactly as on Android.

   Implemented with a **single filter in `SwordManager`**, the `Books.installed()`
   equivalent: `ModuleInfo.isSupported` (a `.bible` module requires
   `SwordVersification.isVersificationDefined(aboutMetadata.versification)`, backed by
   `SWVersification_isSystemDefined` / JSword `Versifications.isDefined`) gates both
   `installedModules()` and `module(named:)`. Every consumer inherits the exclusion,
   so there are no per-path gates to keep in sync.

   *Evolution:* an earlier iteration of this PR applied per-path versification gates
   across the reader (catalog, active-module resolution, restore, switch, pane-copy)
   and deliberately kept the module in the raw inventory so it stayed uninstallable.
   Two adversarial reviews each found a newly-missed activation path, and the
   "keep it uninstallable" clause was itself a divergence from Android (Android never
   surfaces an unsupported book anywhere, including its delete list). This ADR
   supersedes that approach with the single `SwordManager` filter above. Uninstall is
   unaffected — it operates by name at the InstallMgr/file level, not through the
   filtered inventory — but the Downloads UI now offers the module as re-downloadable
   rather than as an installed item to remove, exactly as on Android.

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

- Enables true parity: the same modules are usable (or not) on iOS and Android,
  and an unsupported module is invisible on the same surfaces on both.
- The gate lives in one place — `SwordManager.installedModules()` and
  `module(named:)` (the `Books.installed()` equivalent) — so no reader path can
  drift out of sync, and a future activation path is covered automatically.
- An unsupported module has no direct "Uninstall" affordance (it is not shown as
  installed); the user re-downloads to heal it, as on Android. Uninstall-by-name
  and index deletion still work for supported modules and are unaffected.
- Requires keeping libsword current, or legitimately-new versifications would be
  treated as unsupported on iOS until libsword is updated. This is an **accepted**
  maintenance cost: the project is committed to tracking Android on an ongoing
  basis, so keeping libsword's av11n tables aligned with the shipped JSword is
  part of normal upkeep, not a new burden this decision introduces.
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
  default for absent v11n); `Books.installed()` as the single filtered registry.
- SwordKit: `ModuleInfo.isSupported` and its use in `SwordManager.installedModules()`
  / `module(named:)` (the single filter); `SwordVersification.isVersificationDefined`
  (the primitive) and the mapping engine (`mapVerseToKJVA` / `mapVerseFromKJVA` /
  `decodeOrdinal`).
