---
adr: ADR-0008
title: "Parity Documentation Ownership"
description: "Durable Android/iOS parity decisions live in ADRs while tracker-style parity docs are deprecated."
date: 2026-06-30
status: accepted
supersedes: [ADR-0001]
superseded-by: null
decision-owner: "iOS parity maintainers"
deciders: ["iOS parity maintainers"]
consulted: ["Android source", "iOS parity docs", "iOS test suite"]
informed: ["AndBible iOS contributors"]
tags: [parity, documentation, adr]
related-adrs: [ADR-0002, ADR-0003, ADR-0004, ADR-0005, ADR-0006, ADR-0007]
related-work-items: []
---

# ADR-0008: Parity Documentation Ownership

> This ADR records documentation ownership. It is not a parity status tracker.

## 1. Decision Summary

**Decision:** Durable Android/iOS parity decisions must live in ADRs, source
code, and tests. Human-maintained tracker docs under `docs/parity/` are
deprecated and should not be used as canonical contracts, matrices, guardrails,
or regression reports. Machine-readable guardrail inputs belong with the scripts
that consume them, not in a parity documentation tree.

**Business outcome this supports:** Maintainers can review parity changes from
current Android source, code, tests, and durable ADRs instead of reconciling
large status documents that drift from implementation.

## 2. Context and Problem Statement

The repository accumulated a large `docs/parity/` tree during the initial parity
push. It included global contracts, domain contracts, dispositions, guardrails,
verification matrices, regression reports, archived analyses, and JSON
guardrail inputs.

That structure helped bootstrap audits, but it created a maintenance problem:
many Markdown files mixed durable decisions with current status, issue maps,
implementation details, validation evidence, and historical notes. As the app
changed, those tracker docs required constant updates and could silently drift
from Android source, iOS code, or tests.

The decision question is: where should future parity truth live so Android
parity remains rigorous without preserving a parallel documentation system?

## 3. Goals and Non-Goals

### Goals

- Keep Android production behavior as the parity oracle.
- Keep accepted platform deviations and meaningful parity decisions in ADRs.
- Keep detailed behavior enforcement in source code and tests.
- Preserve machine-readable guardrail fixtures that scripts actually consume.
- Remove or deprecate human-maintained parity tracker Markdown.

### Non-Goals

- This ADR does not declare every parity domain complete.
- This ADR does not remove the requirement to inspect Android source.
- This ADR does not move implementation status into ADRs.
- This ADR does not convert every historical tracker paragraph into a new ADR.

## 4. Decision Drivers

1. Parity decisions need durable, reviewable ownership.
2. Implementation status and validation evidence go stale quickly in prose.
3. Tests and source are stronger enforcement mechanisms than tracker tables.
4. Machine-readable fixtures remain useful only when scripts consume them.
5. Contributors need one clear rule for where new parity rationale belongs.

## 5. Options Considered

### Option A - Keep The Parity Tree As Canonical

**Description:** Continue maintaining `docs/parity/` contracts, dispositions,
matrices, guardrails, and regression reports as the source of truth.

**Pros:**

- Preserves existing organization.
- Keeps all historical audit context in place.

**Cons:**

- Continues duplicate status tracking outside code, tests, issues, and ADRs.
- Requires frequent prose updates for every parity change.
- Makes stale docs look authoritative.

**Estimated cost / complexity:** High, because every parity change needs
multiple synchronized documentation edits.

**Fit with project direction:** Weak. It preserves the drift problem.

### Option B - Move Durable Decisions To ADRs And Remove The Parity Tree

**Description:** Keep ADRs for durable parity decisions, keep tests/source for
behavior contracts, keep script-consumed JSON inputs under `scripts/fixtures/`,
and remove the parity documentation tree.

**Pros:**

- Gives durable decisions a stable home.
- Reduces stale status and matrix maintenance.
- Preserves machine-readable guardrails as script fixtures.
- Keeps detailed behavior close to code and tests.

**Cons:**

- Historical tracker prose is no longer in the active docs tree.
- Contributors must use Git history for removed audit details.

**Estimated cost / complexity:** Medium. It requires link cleanup and a clear
deprecation page, but it removes recurring maintenance cost.

**Fit with project direction:** Strong.

### Option C - Move Every Parity Detail Into ADRs

**Description:** Convert every contract, matrix, disposition, and regression
report into ADRs.

**Pros:**

- Avoids deleting historical detail.
- Keeps everything under one document type.

**Cons:**

- Turns ADRs into status trackers, which violates ADR purpose.
- Produces many low-value ADRs for implementation details and test evidence.
- Keeps the maintenance burden under a different directory.

**Estimated cost / complexity:** High.

**Fit with project direction:** Weak. ADRs should record decisions, not
implementation checklists.

## 6. Selected Decision

**Selected option:** Option B - Move durable decisions to ADRs and remove the
parity tree.

**Why this option was selected:** It preserves the meaningful parts of parity
documentation while eliminating the highest-drift artifacts. Android source
remains the oracle; ADRs own accepted deviations and cross-cutting rules; tests
and source own executable behavior contracts.

**Why the other options were not selected:**

- **Option A:** It keeps stale tracker documents as authoritative surfaces.
- **Option C:** It misuses ADRs as status reports and test ledgers.

**Confidence level:** High.

**Reversibility:** Moderate. Removed tracker prose remains recoverable from Git
history, but the intended direction is to avoid restoring it as canonical docs.

**Review trigger:** Revisit if contributors repeatedly cannot determine parity
requirements from Android source, ADRs, code, tests, issues, and PRs.

## 7. Parity Documentation Rules

Android production behavior remains the source of truth for parity. When the
desired behavior is unclear, inspect the local Android checkout and cite the
source in the PR, test, comment, or ADR.

Use ADRs for:

- accepted Android/iOS deviations
- cross-cutting parity policy
- platform-boundary decisions
- behavior ownership classifications that future work might re-litigate
- durable documentation ownership rules

Use source code and tests for:

- payload shapes
- row order and option inventories
- persistence details
- current implementation status
- regression evidence
- validation commands and results

Use GitHub issues and PRs for:

- incomplete work
- issue maps
- temporary plans
- CI status
- rollout notes

Use `scripts/fixtures/` for machine-readable inputs that are consumed by scripts
or CI. New human-maintained contract, disposition, matrix, guardrail,
regression-report, or status Markdown must not be added under `docs/parity/`.

The current retained script fixtures are:

- bridge parity inventory: current Android bridge methods that are absent from
  the iOS bundle, so new Android bridge methods or stale gap entries are caught
- settings localization snapshots: Android settings translation coverage and
  the current iOS English-placeholder ceiling, so iOS does not regress below
  Android-backed localization parity

## 8. Consequences

- ADR 0001 is superseded by this decision.
- Existing parity ADRs remain the durable decision records.
- Tracker-style Markdown under `docs/parity/` can be removed rather than
  migrated wholesale.
- PRs should cite relevant ADRs, Android source, tests, or script fixtures
  instead of removed parity tracker files.
- If a removed tracker doc contained rationale that becomes important again,
  restore the decision as a focused ADR, not as a new matrix or status doc.
- The JSON inputs used by localization and bridge guardrail scripts live under
  `scripts/fixtures/` because they are executable test data, not documentation.

## 9. Validation Plan

- Repository reference search must show no links to removed parity Markdown.
- Guardrail scripts that consume JSON fixtures must still pass.
- GitNexus change detection should report documentation-only scope and no
  unexpected execution-flow impact.

## 10. References

- [ADR 0002: Route Reader Document Modals Through The Shared Document Pipeline](0002-route-reader-document-modals-through-shared-document-pipeline.md)
- [ADR 0003: Android Database Backup Restore Parity](0003-android-database-backup-restore-parity.md)
- [ADR 0004: Reader Pointer Affordances And Upstream Bug Handling](0004-reader-pointer-affordances-and-upstream-bug-handling.md)
- [ADR 0005: Workspace Color Scope And Reader Chrome](0005-workspace-color-scope-and-reader-chrome.md)
- [ADR 0006: Modal Presentation Ownership For Android Parity](0006-modal-presentation-ownership-for-android-parity.md)
- [ADR 0007: iOS Discrete SKU and Runtime Icon Boundary](0007-ios-discrete-mode-app-name-boundary.md)
- `scripts/check_bridge_parity_inventory.py`
- `scripts/check_settings_localization_guardrails.py`
- `scripts/fixtures/`
