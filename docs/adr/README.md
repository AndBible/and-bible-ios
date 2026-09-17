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

Create each new ADR from the [authoring template](../templates/adr.md) and give it an
unused four-digit identifier:

```text
NNNN-short-kebab-case-title.md
```

New ADRs use YAML front matter with this metadata:

- `adr`: stable ADR identifier, such as `ADR-0008`
- `title`: short decision title
- `description`: one-sentence decision summary
- `date`: `YYYY-MM-DD`
- `status`: `proposed`, `accepted`, `rejected`, or `superseded`
- `review-status`: `pending_review` or `reviewed`
- `extends` / `extended-by`, `amends` / `amended-by`, and `supersedes` /
  `superseded-by`: decision relationships
- `decision-owner`, `deciders`, `consulted`, `informed`
- `tags`, `related-adrs`, `related-work-items`

Use these authored sections in this order:

- `Decision`
- `Why this came up`
- `Alternatives considered`
- `Consequences`
- `When to revisit this`
- `References`

Older ADRs may use the legacy body-only format. They remain historical inputs;
do not copy or normalize them as the template for new decisions.

## Lifecycle And Relationships

New ADRs start with `status: proposed` and
`review-status: pending_review`. Only a human can accept a decision. Acceptance
requires a human to manually review the proposal and manually commit the
accepted status through the pull-request process. Agent review, pull-request
approval, merge, and successful checks do not accept an ADR.

Keep accepted decision prose and rationale intact. Use a new ADR when a later
decision extends, amends, or supersedes an accepted record. A proposed
successor records its forward relationship, but does not change the accepted
record. After a human accepts the successor, update the older record's reverse
relationship and status where appropriate. Only full supersession changes an
older accepted record to `superseded`; extension and amendment leave it
accepted.

Keep each ADR decision in its own branch and pull request, separate from its
dependent implementation. The ADR index and factual relationship maintenance
may accompany that decision. Implementation status and validation evidence
remain in issues, pull requests, code, tests, or machine-readable guardrails.

Investigation remains open regardless of decision status. Pause affected
implementation for human alignment when a significant architectural choice
remains unresolved. Once a compatible direction is agreed, implementation may
proceed while its ADR is proposed. Implementation that contradicts an accepted
provision waits for human acceptance of its amendment or supersession; that
does not block independent compatible work. Accepted decisions preserve the
chosen contract and rationale, not every implementation that once served them.

Before review, run:

```bash
python3 scripts/check_adr_structure.py
```

The checker verifies stable unique identities, index coverage, and resolvable
relationships. It does not judge prose or accept decisions.

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
- [0011: Transactional Module Store Mechanism](0011-transactional-module-store-mechanism.md)
- [0012: Install Validation Follows Observed SWORD Packaging](0012-install-validation-follows-observed-sword-packaging.md)
- [0013: Reader Annotation Parity Divergences](0013-reader-annotation-parity-divergences.md)
