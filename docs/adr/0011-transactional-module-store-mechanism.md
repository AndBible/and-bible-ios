---
adr: ADR-0011
title: "Transactional Module Store Mechanism"
description: >-
  Keep Android's observable document-management contract while replacing its
  in-place mutation mechanics with a transactional, journaled, serialized
  module store on iOS.
date: 2026-08-08
status: accepted
supersedes: []
superseded-by: null
decision-owner: "iOS parity maintainers"
deciders: ["iOS parity maintainers"]
consulted:
  - "jsword AbstractSwordInstaller / IOUtil.unpackZip"
  - "jsword SwordBookDriver / Books registry"
  - "AndBible DownloadControl / DownloadQueue / BackupControl"
  - "SwordKit ModuleStoreTransactionPublisher / ModuleStoreMutationCoordinator"
informed: ["AndBible iOS contributors"]
tags: [parity, module-store, install, transactions, android]
related-adrs: [ADR-0010, ADR-0012]
related-work-items: ["PR #380"]
---

# 0011: Transactional Module Store Mechanism

Status: Accepted

Date: 2026-08-08

## Context

Android's document management mutates the live SWORD tree in place. JSword's
installer unpacks a downloaded ZIP directly into `mods.d/` and `modules/`,
upgrades overwrite files without pruning stale ones, uninstall deletes the
config and then the data non-atomically, and installs run on unbounded
concurrent coroutines. Recovery from interruption is "idempotent rescan":
partially written modules can register and fail at read time, failed uninstalls
can orphan payload, and a corrupt config silently disappears from enumeration.

iOS rebuilt the same workflows around a single transactional publisher. That
mechanism intentionally does not match Android's mechanics, and without a
durable record the divergence invites two kinds of future error: weakening the
transactional core in the name of parity, or extending its strictness into
behavior users can observe (which ADR-0012 governs).

## Decision

1. Observable behavior follows Android; mutation mechanics do not have to. The
   parity contract for document management is what users and shared data
   formats can observe: which modules install, the repository list, install
   statuses, on-disk layout, identity rules, and Android-compatible backup
   archives. The machinery that produces those observations is iOS-owned.

2. Every mutation of the installed module tree goes through
   `ModuleStoreTransactionPublisher` under the process-wide
   `ModuleStoreMutationCoordinator` lease: staged extraction into an isolated
   root, payload published before configs, displaced files moved to a backup
   tree, rollback on failure, an fsync-backed recovery journal for overlay
   publishes, and cache invalidation plus a payload-free change notification
   after commit. Startup recovery failure is fatal rather than running on a
   half-published store. Ad-hoc `FileManager` writes into the live tree are
   not an accepted implementation pattern.

3. Remote SWORD installs are package-ZIP-only. Android's raw file-by-file
   fallback can publish a partial module after one transient missing file, so
   iOS does not implement it. If a repository that serves only raw files ever
   matters in practice, the fallback must download into staging and publish
   through the same transaction, not write into the live tree.

4. Commits are serialized; downloads are not. Concurrent catalog refreshes and
   downloads remain allowed, and the coordinator lease is the single choke
   point where the live tree changes.

5. Enumeration re-projects installed state from disk instead of trusting
   process-global caches. `SwordManager.installedModules()` reads `mods.d`
   directly, bypassing the flat bridge's global module list, keeping locked
   encrypted modules visible for the unlock affordance, and re-deriving
   non-SWORD custom modules from their on-disk state on every scan. Rejected
   files surface as diagnostics rather than disappearing silently.

## Consequences

- Interrupted installs, upgrades, uninstalls, and restores leave either the
  old state or the new state, never a mixture — a deliberate improvement over
  Android that must not be traded away for mechanical parity.
- A repository without package ZIPs reports the module unavailable where
  Android's raw fallback might install it. This is an accepted coverage gap
  until a real repository demonstrates the need (none of the shipped
  repositories do).
- Replacing a non-SWORD module file on disk is reflected at the next scan,
  unlike Android's register-once model that requires an app restart.
- The transactional mechanism carries real complexity (leases, journals,
  staged plans, byte-identical revalidation). That cost is accepted; changes
  to it need concurrency and recovery test coverage, not simplification for
  its own sake.
- Mechanism-level divergence is never a justification for observable
  divergence. When observable behavior differs from Android, ADR-0012's rule
  applies.

## Alternatives Considered

- **Port Android's in-place mutation for maximum fidelity.** Rejected: its
  failure modes (partial installs, orphaned payload, silent corruption) are
  defects users experience, not contracts to preserve.
- **Transactional writes without serialization.** Rejected: concurrent
  transactions over one live tree reintroduce the races serialization exists
  to prevent, and commit time is negligible next to download time.
- **Implement Android's raw file-by-file install fallback now.** Rejected:
  no shipped repository requires it, and done naively it defeats the
  transactional guarantee.
- **Keep libsword's global module-list cache for enumeration.** Rejected:
  process-global staleness hides just-installed modules and locked modules,
  and cache bypass has negligible cost at realistic library sizes.

## Related

- SwordKit `ModuleStoreTransactionPublisher` (+ Uninstall/ExactOverlay
  extensions), `ModuleStoreMutationCoordinator`, `ModuleStoreRecoveryJournal`,
  `ModuleStoreInstalledLayout`, `ModuleRepository.installModulePackage`,
  `SwordManager.installedModules()`.
- JSword `AbstractSwordInstaller.install`, `IOUtil.unpackZip`,
  `SwordBookDriver.delete`, `Books`.
- ADR-0012 for the validation semantics applied inside this mechanism.
