---
adr: ADR-0009
title: "Android Localization Source Of Truth"
description: >-
  Shared iOS localization strings must be sourced from Android translations and
  enforced by the settings localization guardrail.
date: 2026-07-01
status: accepted
supersedes: []
superseded-by: null
decision-owner: "iOS parity maintainers"
deciders: ["iOS parity maintainers"]
consulted: ["Android string resources", "iOS localization files", "settings localization guardrail"]
informed: ["AndBible iOS contributors"]
tags: [parity, localization, android-source, guardrail]
related-adrs: [ADR-0008]
related-work-items: ["#324"]
---

# ADR-0009: Android Localization Source Of Truth

> This ADR records the localization ownership rule. It is not a translation
> coverage report.

## 1. Decision Summary

**Decision:** Android string resources are the source of truth for shared
AndBible iOS localization strings. iOS must not hand-author independent
translations for keys whose English text and user-facing meaning are already
implemented in Android. The settings localization guardrail owns the executable
contract for importing, auditing, and snapshotting those Android-sourced values.

**Business outcome this supports:** Users receive the same translated product
language across Android and iOS wherever the apps share behavior, and future iOS
changes cannot silently reintroduce incomplete local translation sets.

## 2. Context and Problem Statement

Issue #324 exposed a Finnish localization gap, but the root cause was not
Finnish-specific. iOS had accumulated independently authored localization files
for strings that Android already translated. That made iOS translation coverage
depend on a separate, incomplete translation surface instead of the mature
Android catalog.

The initial parity pass found that same-name Android and iOS keys were easy to
source from Android, but preserving English differences as manual exceptions
would keep the systemic problem alive. A stricter review also found iOS keys
whose English text matched Android under a different resource name. Those keys
needed explicit provenance rather than being treated as legitimate iOS-only
translations.

The decision question is: what should be canonical when iOS and Android expose
the same localized text, and how should contributors prevent drift after the
bulk sync?

## 3. Goals and Non-Goals

### Goals

- Use Android translations for shared user-facing strings.
- Enforce English parity and translated-value parity for Android-sourced keys.
- Preserve source provenance for cross-name mappings.
- Keep generated translation state machine-readable and CI-checkable.
- Make intentional localization deviations explicit and reviewable.

### Non-Goals

- This ADR does not require Android sourcing for iOS-only features.
- This ADR does not make ADRs the place to track per-locale coverage counts.
- This ADR does not replace translator review for strings whose source English
  meaning changes upstream.
- This ADR does not decide unrelated localization mechanics outside shared
  AndBible strings.

## 4. Decision Drivers

1. Android has the broader existing translation catalog for shared product
   behavior.
2. Independent iOS translations create predictable coverage drift.
3. Same visible English text under different resource names still represents a
   shared localization contract when the product meaning matches.
4. Cross-name mappings need explicit provenance so generic strings are not
   accidentally joined to unrelated Android text.
5. CI needs an executable guardrail because prose-only localization rules are
   easy to regress.

## 5. Options Considered

### Option A - Keep iOS Localizations Independent

**Description:** Treat iOS `.strings` files as separately authored
translations, fixing missing locale values as they are reported.

**Pros:**

- Minimizes immediate churn in localization files.
- Allows iOS-specific wording everywhere.

**Cons:**

- Preserves the root cause of #324.
- Requires duplicate translation effort for shared product text.
- Makes missing translations a locale-by-locale bug class.
- Gives no durable way to detect drift from Android.

**Estimated cost / complexity:** High over time because every shared string can
diverge independently.

**Fit with project direction:** Weak. It contradicts Android parity.

### Option B - Source Shared Localization From Android And Enforce With A Guardrail

**Description:** Import Android translations for shared keys, record provenance
for same-name and explicit cross-name mappings, and fail the guardrail on
missing keys, English drift, placeholder fallbacks, translated-value drift, or
resource-tree mismatches.

**Pros:**

- Fixes the systemic localization drift.
- Reuses Android's mature translation catalog.
- Keeps cross-name mappings explicit and reviewable.
- Gives CI a machine-readable regression boundary.
- Lets iOS-only strings remain independently owned.

**Cons:**

- Produces large generated localization diffs when Android values are synced.
- Requires contributors to update the mapping table when adding shared keys
  under different names.
- Requires Android string normalization before comparing runtime values.

**Estimated cost / complexity:** Medium. The sync is broad, but enforcement is
localized to one guardrail and its fixture.

**Fit with project direction:** Strong.

### Option C - Import Android Translations But Allow Manual iOS Overrides

**Description:** Use Android as a starting point, but keep existing iOS values
or future iOS edits when they appear acceptable.

**Pros:**

- Reduces some immediate diffs.
- Allows selective iOS wording changes.

**Cons:**

- Reintroduces manual exceptions without a clear parity rule.
- Makes guardrail failures subjective.
- Keeps future contributors guessing whether a difference is intentional or
  stale.

**Estimated cost / complexity:** Medium initially and high over time.

**Fit with project direction:** Weak. It preserves drift under a softer name.

## 6. Selected Decision

**Selected option:** Option B - source shared localization from Android and
enforce it with a guardrail.

**Why this option was selected:** The reported issue was a symptom of a broader
ownership problem. Android already owns the shared translation catalog. Making
that ownership executable is the only reliable way to keep iOS from rebuilding a
parallel, incomplete catalog.

**Why the other options were not selected:**

- **Option A:** It treats each missing translation as an isolated bug and keeps
  the duplicate catalog.
- **Option C:** It imports Android values without making Android authoritative,
  so parity can drift again through manual overrides.

**Confidence level:** High.

**Reversibility:** Moderate. Individual mappings can be corrected, but the
source-of-truth direction should only change through a superseding ADR because
it affects every shared localized string.

**Review trigger:** Revisit if Android no longer owns the relevant product
translation catalog, if iOS intentionally diverges for a platform-specific
feature, or if a mapped key is shown to share English text but not product
meaning.

## 7. Localization Parity Rules

Android `app/src/main/res/values*/strings.xml` resources are canonical for iOS
keys that represent the same user-facing AndBible text.

Same-name shared keys are Android-sourced automatically when both platforms
define the key and the Android catalog provides the source English value, unless
the iOS key is listed as a same-name semantic collision in the guardrail. A
same-name collision means Android and iOS use the same resource key for
different product surfaces.

Cross-name shared keys must be listed in
`ANDROID_SHARED_KEY_MAPPINGS` in
`scripts/check_settings_localization_guardrails.py`. Each entry maps one iOS key
to one Android resource key. Contributors must not rely on fuzzy matching,
partial English matching, or unstated manual judgment for these keys.

Same-name semantic collisions must be listed in
`ANDROID_SHARED_SAME_NAME_EXCLUSIONS` in the same script. Exclusions apply only
to automatic same-name sourcing; an explicit cross-name mapping may still use
that Android key when the mapped iOS surface is Android-equivalent.

The generated settings localization snapshot must record `source_key_by_key` so
reviewers can see the Android resource key that sources each iOS key. Snapshot
data belongs under `scripts/fixtures/` because it is executable guardrail input,
not human-maintained parity documentation.

The guardrail must compare Android runtime text, not raw XML text. Android
escapes, XML whitespace behavior, and Android `%s` string placeholders must be
normalized into the iOS `.strings` representation before values are audited or
synced.

For Android-sourced keys, iOS English values are not overrides. They must match
the normalized Android source English. Non-English iOS values must come from the
corresponding Android locale when Android provides a translation that differs
from Android English. English placeholder fallbacks are audit failures for
Android-sourced translated locales.

Both iOS localization trees, `AndBible/*.lproj/Localizable.strings` and
`Localizations/*.lproj/Localizable.strings`, must stay synchronized for
Android-sourced values. A value present in one tree and not the other is a
regression.

Intentional deviations require an explicit documented exception. A deviation is
valid only when the iOS string is genuinely iOS-only, the product meaning is not
shared with Android, or a platform constraint requires different wording. Shared
Android-backed text must not be preserved as an iOS-specific translation simply
because the old iOS file already contained it.

## 8. Contributor Workflow

When Android-backed localization changes are needed, contributors should:

- inspect the relevant Android string resources
- update `ANDROID_SHARED_KEY_MAPPINGS` for any shared iOS key whose Android
  source key has a different name
- run the settings localization guardrail against a current Android checkout
- sync Android-sourced translations into both iOS localization trees
- regenerate the settings localization snapshot
- run unit tests for the guardrail
- run the guardrail in snapshot fallback mode
- lint the generated `.strings` files

The guardrail output owns current counts, gaps, and mismatch details. ADRs
should record the rule, not copy generated inventories that can change when
Android adds or removes strings.

## 9. Consequences

- Large generated localization diffs are expected when Android translations are
  synced.
- Reviewers should inspect guardrail/mapping changes more closely than every
  generated `.strings` line.
- New shared strings with different Android and iOS resource names require an
  explicit mapping before they can claim parity.
- CI can enforce parity even without an Android checkout by using the generated
  snapshot fixture.
- iOS-only strings remain iOS-owned, but that classification must not be used to
  preserve stale translations for shared behavior.
- If Android source English changes, iOS English and translated values for that
  source key must be resynced rather than patched independently.

## 10. Validation Plan

- `python3 -m unittest scripts.test_check_settings_localization_guardrails`
- `python3 scripts/check_settings_localization_guardrails.py --android-root <android-app-res-root>`
- `python3 scripts/check_settings_localization_guardrails.py --android-root /private/tmp/nonexistent-android-res`
- `find AndBible Localizations -name Localizable.strings -print0 | xargs -0 plutil -lint`
- `git diff --check`

For commits that include code or generated localization changes, run GitNexus
change detection before committing and confirm the affected scope matches the
localization guardrail and generated resource files.

## 11. References

- [ADR 0008: Parity Documentation Ownership](0008-parity-documentation-ownership.md)
- `scripts/check_settings_localization_guardrails.py`
- `scripts/test_check_settings_localization_guardrails.py`
- `scripts/fixtures/settings-localization/localization-android.json`
- `AndBible/*.lproj/Localizable.strings`
- `Localizations/*.lproj/Localizable.strings`
- #324
