# Architecture Decision Records

This directory holds Architecture Decision Records for durable technical,
product-architecture, and documentation-ownership decisions.

ADRs are not status reports. They explain why a decision was made, what options
were considered, and what consequences follow from the decision. Current status,
test evidence, parity matrices, and implementation checklists should live in
the domain docs that own them.

## When To Add An ADR

Add an ADR when a decision:

- changes a cross-cutting architecture or product-parity rule
- explains an intentional divergence from Android that future work might
  otherwise undo
- chooses between plausible documentation, ownership, or implementation models
- creates a rule that should survive the issue or PR that introduced it

Do not add an ADR for every small implementation change. If a change is fully
explained by an existing domain contract, disposition, or verification matrix,
update that domain doc instead.

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

- [0001: Keep Parity Docs As Living Domain Docs](0001-keep-parity-docs-as-living-domain-docs.md)
- [0002: Route Reader Document Modals Through The Shared Document Pipeline](0002-route-reader-document-modals-through-shared-document-pipeline.md)
