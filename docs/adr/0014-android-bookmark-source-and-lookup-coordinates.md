---
adr: ADR-0014
title: "Android Bookmark Source and Lookup Coordinates"
description: "Preserve Android bookmark identity in its source versification while supporting Android's KJVA lookup projections, including fallback projections."
date: 2026-10-24
status: accepted
review-status: reviewed
extends: []
extended-by: []
amends: [ADR-0010, ADR-0013]
amended-by: []
supersedes: []
superseded-by: null
decision-owner: "iOS parity maintainers"
deciders: ["primetheus"]
consulted: ["Android BookmarkEntities and BookmarksDao", "JSword VersificationConverter and Versification"]
informed: []
tags: [bookmarks, versification, android, parity]
related-adrs: [ADR-0003]
related-work-items: ["issue #441", "PR #442"]
---

# ADR-0014: Android Bookmark Source and Lookup Coordinates

## Decision

Match Android's Bible bookmark contract for all supported source
versifications. A bookmark's original `v11n`, `ordinalStart`, and `ordinalEnd`
identify the selected source passage. The `kjvOrdinalStart` and `kjvOrdinalEnd`
fields are Android-compatible lookup projections, not proof that the source
passage has an exact KJVA equivalent.

For bookmarks only, permit the pinned JSword public conversion and ordinal
calculation, including its coordinate-retaining fallback and zero ordinal when
the target cannot address a book or chapter. Validate the source coordinates
and retain them independently. Distinguish an exact mapping from a fallback or
unaddressable lookup result; never claim the latter is an authoritative KJVA
passage. Unknown versifications and invalid source selections still fail closed.

Bookmark creation, editing, visibility, text, navigation, reader annotations,
notes, labels, StudyPads, and Android backup/sync must preserve this distinction.
Returning to the source module must use the original source passage, rather
than reverse-converting a lossy lookup index. Cross-module behavior must follow
Android's source-range conversion, including its treatment of unsupported
positions. A successful save alone is insufficient implementation of this decision.

This decision replaces ADR-0010 decision 3 and its strict-failure consequence
only where they prohibit Android-compatible bookmark lookup projections. The
registered-versification/module-admission rules and strict boundaries for other
persisted features remain in force.

It also amends ADR-0013's persisted ordinal trust gate for Bible bookmarks:
verified source identity and a reproducible Android lookup projection are valid
bookmark provenance even without an exact KJVA equivalent. Legacy rows with
unknown provenance remain quarantined. The premise that all Android bookmark
lookup coordinates are authoritative KJVA passages no longer applies.

## Acceptance

Accepted by primetheus on 2026-10-24 through the explicit instruction to approve
and merge PR #443. The acceptance commit records that human decision.

## Why this came up

Issue #441 demonstrates a valid Calvin Revelation 12:18 selection that Android
can bookmark but iOS rejects. iOS's shared verified-range boundary requires a
strict KJVA equivalent before allowing the bookmark panel to open. Reader and
navigation paths also assume that an exact KJVA range can be recovered.

Android stores both coordinate domains explicitly. Its bookmark constructor
keeps the original verse range while deriving a separate KJVA lookup range.
JSword's public converter retains source coordinates after a strict miss, and
its target ordinal arithmetic can continue beyond a chapter or return zero.
Treating those lookup fields as exact passage identity loses information that
Android preserves in the source fields.

The requested direction is to resolve every behavior in #441 and match Android,
including bookmarking, rather than retaining an iOS-specific rejection.

## Alternatives considered

### Keep rejecting extra verses and improve the error message

This would explain the failure but would continue preventing a valid Android
bookmark workflow. It does not meet the requested behavior.

### Relax the shared strict KJVA gate for every persisted feature

This could make the save succeed, but would expose progress and memorization
consumers to coordinates they currently treat as exact passages. The decision
limits the change to bookmarks and makes projection fidelity explicit.

### Store a generic bookmark instead of a Bible bookmark

That would avoid the KJVA fields but change Android backup/sync identity and
Bible bookmark behavior. Android uses a Bible bookmark with source metadata.

## Consequences

- Valid source selections can be bookmarked even when no exact KJVA equivalent exists.
- Lookup indexes may collide or be zero, as on Android; they cannot replace source identity.
- All bookmark read/write boundaries must support the same contract, including imports and exports.
- Existing valid bookmarks retain their identity, notes, labels, and StudyPad associations.
- Previously quarantined rows may be admitted only when retained source metadata proves the
  Android-compatible projection. No guessed source identity is introduced.
- ADRs 0010 and 0013 retain their historical text; this accepted amendment governs the
  bookmark-specific exceptions described above.

## When to revisit this

Revisit if Android or the pinned JSword revision changes bookmark conversion or
storage semantics, or if interoperation tests demonstrate that preserving the
source range and Android lookup projection is insufficient for faithful exchange.

## References

- [Issue #441](https://github.com/AndBible/and-bible-ios/issues/441)
- [PR #442](https://github.com/AndBible/and-bible-ios/pull/442)
- [ADR-0010](0010-unrecognized-module-versification-handling.md)
- [ADR-0013](0013-reader-annotation-parity-divergences.md)
- [Android bookmark entities](https://github.com/AndBible/and-bible/blob/master/app/src/main/java/net/bible/android/database/bookmarks/BookmarkEntities.kt)
- Android `BookmarksDao.bookmarksForVerseRange`, `BookmarkControl` source-range text extraction.
- JSword `VersificationConverter.convert(Verse, Versification)` and `Versification.getOrdinal(Verse)`.
