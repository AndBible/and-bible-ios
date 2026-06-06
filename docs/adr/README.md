# Architecture Decision Records

This directory holds Architecture Decision Records for durable technical,
product-architecture, and documentation-ownership decisions.

ADRs are not status reports. They explain why a decision was made, what options
were considered, and what consequences follow from the decision. Current status,
test evidence, parity matrices, and implementation checklists can stay in
domain docs while they are useful, but durable decisions should move here over
time instead of accumulating in tracker-style parity docs.

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
decision, update the domain doc or issue instead.

## Format

Use a numbered Markdown file:

```text
NNNN-short-kebab-case-title.md
```

Use these sections:

- `Status`: Proposed, Accepted, Superseded, or Rejected
- `Date`: YYYY-MM-DD
- `Context`: why the decision is needed
- `Decision`: the rule being adopted
- `Consequences`: what this enables, requires, or rules out
- `Related`: issues, PRs, and docs that carry live status

## Current ADRs

- [0001: Gradually Convert Parity Decisions To ADRs](0001-gradually-convert-parity-decisions-to-adrs.md)
- [0002: Route Reader Document Modals Through The Shared Document Pipeline](0002-route-reader-document-modals-through-shared-document-pipeline.md)
- [0003: Android Database Backup Restore Parity](0003-android-database-backup-restore-parity.md)
- [0004: Reader Pointer Affordances And Upstream Bug Handling](0004-reader-pointer-affordances-and-upstream-bug-handling.md)
