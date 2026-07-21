# Architecture Decision Records

This directory holds Architecture Decision Records for durable technical,
product-architecture, and documentation-ownership decisions.

ADRs are not status reports. They explain why a decision was made, what options
were considered, and what consequences follow from the decision. Current status,
test evidence, parity matrices, and implementation checklists belong in issues,
PRs, code, tests, or machine-readable guardrails rather than tracker-style
parity docs.

## When To Add An ADR

Add an ADR when a decision:

- changes a cross-cutting architecture or product-parity rule
- explains an intentional divergence from Android that future work might
  otherwise undo
- chooses between plausible documentation, ownership, or implementation models
- creates a rule that should survive the issue or PR that introduced it

Do not add an ADR for every small implementation change. Add one when the
change decides or revises product/architecture direction. If a change only
updates status, validation evidence, or implementation notes under an existing
decision, update the issue, PR, source, or test instead.

## Format

Use a numbered Markdown file:

```text
NNNN-short-kebab-case-title.md
```

New ADRs should include YAML front matter when practical, following this
metadata shape:

- `adr`: stable ADR identifier, such as `ADR-0008`
- `title`: short decision title
- `description`: one-sentence decision summary
- `date`: `YYYY-MM-DD`
- `status`: `proposed`, `accepted`, `rejected`, `deprecated`, or `superseded`
- `supersedes` / `superseded-by`: replacement relationships
- `decision-owner`, `deciders`, `consulted`, `informed`
- `tags`, `related-adrs`, `related-work-items`

Older ADRs may use the legacy body-only format. Either way, include these
sections or their front-matter equivalents:

- `Status`: Proposed, Accepted, Superseded, or Rejected
- `Date`: YYYY-MM-DD
- `Context`: why the decision is needed
- `Decision`: the rule being adopted
- `Consequences`: what this enables, requires, or rules out
- `Related`: issues, PRs, and docs that carry live status

## Current ADRs

- [0001: Gradually Convert Parity Decisions To ADRs](0001-gradually-convert-parity-decisions-to-adrs.md) (Superseded by ADR 0008)
- [0002: Route Reader Document Modals Through The Shared Document Pipeline](0002-route-reader-document-modals-through-shared-document-pipeline.md)
- [0003: Android Database Backup Restore Parity](0003-android-database-backup-restore-parity.md)
- [0004: Reader Pointer Affordances And Upstream Bug Handling](0004-reader-pointer-affordances-and-upstream-bug-handling.md)
- [0005: Workspace Color Scope And Reader Chrome](0005-workspace-color-scope-and-reader-chrome.md)
- [0006: Modal Presentation Ownership For Android Parity](0006-modal-presentation-ownership-for-android-parity.md)
- [0007: iOS Discrete SKU and Runtime Icon Boundary](0007-ios-discrete-mode-app-name-boundary.md)
- [0008: Parity Documentation Ownership](0008-parity-documentation-ownership.md)
- [0009: Android Localization Source Of Truth](0009-android-localization-source-of-truth.md)
- [0010: Unrecognized Module Versification Handling](0010-unrecognized-module-versification-handling.md)
