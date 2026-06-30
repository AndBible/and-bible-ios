# 0001: Gradually Convert Parity Decisions To ADRs

Status: Superseded by [ADR 0008](0008-parity-documentation-ownership.md)

Date: 2026-05-25

## Context

The repo already has substantial parity documentation under `docs/parity/`:
global contracts, domain contracts, disposition files, verification matrices,
regression reports, guardrails, and some machine-readable baselines.

That structure helped during the first parity push, but it also creates a
maintenance problem. If every audit, decision, exception, issue map, and
validation result stays in long-form tracker docs, the parity tree will grow
without a clear boundary between:

- durable product or architecture decisions
- current implementation status
- validation evidence
- issue planning notes
- historical rationale

The durable decisions need a stable home that can be read independently from
temporary status and issue comments. At the same time, converting every parity
file in one large rewrite would create churn and would risk losing useful
current-state context.

## Decision

Gradually move durable parity decisions into ADRs.

ADRs are the long-lived source for:

- cross-cutting parity policy
- accepted Android/iOS divergence
- feature-surface classification that future work might otherwise re-litigate
- architecture or documentation ownership rules
- decisions that should survive the issue or PR that introduced them

`docs/parity/` remained useful during the migration, but it was expected to
become lighter over time. Its role was:

- orientation and current status snapshots
- links to ADRs that own durable decisions
- validation matrices, regression evidence, and machine-readable baselines while
  those artifacts are still useful
- short domain indexes that point to the active issues, ADRs, and guardrails

Do not add new durable parity rationale only to tracker-style parity docs. If a
change decides what parity means for a surface, add or update an ADR and link it
from the relevant parity page.

## Consequences

- This ADR allowed an incremental migration period.
- ADR 0008 supersedes that migration period and makes ADRs, source, tests,
  issues, and PRs the durable homes for parity decisions and status.
- Reviewers should treat a new long-form parity rationale outside an ADR as a
  documentation smell unless it is a machine-readable guardrail baseline.

## Related

- [ADR 0008: Parity Documentation Ownership](0008-parity-documentation-ownership.md)
