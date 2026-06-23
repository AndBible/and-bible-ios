# Parity Documentation

This subtree holds cross-platform parity material.

Recommended reading order:

1. [android-parity-contract.md](android-parity-contract.md): global functional,
   visual, and architecture standard
2. [status-overview.md](status-overview.md): current parity posture and automation state by domain
3. domain `README.md` files: scoped reading order for each domain

Decision records that explain durable parity choices live in
[`../adr/`](../adr/README.md). The key rule is documented in
[ADR 0001](../adr/0001-gradually-convert-parity-decisions-to-adrs.md): durable
parity decisions should gradually move into ADRs so this subtree does not become
an endlessly growing tracker.

Presentation-surface ownership is governed by
[ADR 0006](../adr/0006-modal-presentation-ownership-for-android-parity.md).
Use that matrix before treating a SwiftUI sheet, native dialog, file picker, or
share sheet as Android parity.

Use domain folders so each parity area can carry, as needed:

- current contract summaries
- links to ADR-owned dispositions/divergences
- verification matrix
- regression evidence
- machine-readable baselines

When a parity decision changes the intended long-term shape of a feature, add
or update the ADR that records the decision, then keep the relevant domain docs
as short status, evidence, and navigation pages that point to that ADR. When
only implementation status or validation evidence changes, update the parity
docs or issue without creating a new ADR.

Current maturity:

- established domains carry:
  - contract
  - dispositions
  - verification matrix
  - regression report
  - guardrails
- `downloads/` currently carries a source-backed list matrix from the #120
  parity pass; expand it into the full domain-doc set when follow-up work needs
  durable contracts or guardrails
- `settings/` remains the most operationally mature domain because it has
  machine-readable baselines plus a dedicated localization guardrail script
- `bridge/` now has a dedicated inventory checker for the bundled iOS bridge
  surface and optional local Android-backed drift detection
- the remaining domains currently rely on focused unit/UI coverage and
  documentation guardrails, with room to add more machine-readable protection
  where it is worth the maintenance cost

Current domains:

- [android-parity-contract.md](android-parity-contract.md)
- [status-overview.md](status-overview.md)
- [bridge/](bridge/README.md)
- [reader/](reader/README.md)
- [bookmarks/](bookmarks/README.md)
- [search/](search/README.md)
- [reading-plans/](reading-plans/README.md)
- [settings/](settings/README.md)
- [downloads/](downloads/README.md)
- [sync/](sync/README.md)
