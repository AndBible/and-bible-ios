# 0001: Keep Parity Docs As Living Domain Docs

Status: Accepted

Date: 2026-05-25

## Context

The repo already has substantial parity documentation under `docs/parity/`:
global contracts, domain contracts, disposition files, verification matrices,
regression reports, guardrails, and some machine-readable baselines.

As parity work expands, there are two competing pressures:

- durable decisions need a stable place that does not depend on issue comments
  or stale PR descriptions
- domain status needs to remain easy to update as implementation, tests, and
  Android source references change

Converting the parity docs wholesale into ADRs would make the decision history
clearer, but it would turn living status documents into historical records. That
would make routine parity maintenance harder and would blur whether a document
is describing current behavior or a past choice.

## Decision

Keep `docs/parity/` as long-lived, living domain documentation.

Use ADRs for durable decisions that explain why the parity docs are shaped a
certain way, why an intentional divergence exists, or why a cross-cutting rule
was adopted.

Do not convert parity contracts, verification matrices, regression reports, or
status overviews into ADRs. Instead:

- parity docs describe the current contract, current status, evidence, and next
  action
- ADRs record stable decisions and link back to the parity docs that carry live
  status
- issue comments and PR descriptions may summarize decisions, but they are not
  the durable source of truth

## Consequences

- Parity docs remain editable in the same slice as parity implementation work.
- ADRs should be added sparingly for decisions that future maintainers are
  likely to revisit or accidentally reverse.
- When an ADR changes the parity posture of a domain, the matching domain
  contract, dispositions, verification matrix, regression report, and
  `status-overview.md` should be updated in the same change.
- When implementation status changes but the underlying decision does not, only
  the parity docs need to change.

## Related

- [Parity documentation](../parity/README.md)
- [Parity status overview](../parity/status-overview.md)
- [Android parity contract](../parity/android-parity-contract.md)
