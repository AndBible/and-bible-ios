# Parity Documentation

This subtree holds cross-platform parity material.

Recommended reading order:

1. [android-parity-contract.md](android-parity-contract.md): global functional,
   visual, and architecture standard
2. [status-overview.md](status-overview.md): current parity posture and automation state by domain
3. domain `README.md` files: scoped reading order for each domain

Use domain folders so each parity area can carry, as needed:

- source-of-truth contract
- documented iOS dispositions/divergences
- verification matrix
- regression evidence
- machine-readable baselines

Current maturity:

- all current domains now carry:
  - contract
  - dispositions
  - verification matrix
  - regression report
  - guardrails
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
- [sync/](sync/README.md)
