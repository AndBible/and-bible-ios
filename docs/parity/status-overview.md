# Parity Status Overview

Date: 2026-05-18

## Purpose

This is the quickest way to get oriented on Android parity in
`and-bible-ios`.

Start with [android-parity-contract.md](android-parity-contract.md) for the
global functional, visual, and architecture standard. Then use this file to
answer four questions without having to reconstruct repo history first:

1. what domains are formally documented
2. what their current parity posture is
3. what validation and automation currently protect them
4. where the remaining durable gaps still are

## Domain Snapshot

The counts below are there to orient you quickly, but they are not the whole
story. If a row looks relevant to your change, the linked domain docs should
give you the fuller human context behind it.

| Domain | Current Posture | Automation State | Primary Remaining Gap |
|---|---|---|---|
| [settings](settings/README.md) | Mature: `24 Pass`, `9 Adapted Pass`, `0 Partial`, `2 Documented Divergence` | Dedicated localization guardrail script, committed baselines, CI integration, focused simulator/unit validation | Broader machine-readable guardrails beyond localization if the settings surface grows materially |
| [sync](sync/README.md) | Strong for supported Android categories: `7 Pass`, `2 Adapted Pass`, `1 Partial` | Focused unit/integration coverage, focused Sync UI coverage, explicit guardrails | Android-only category implementation breadth is split into deferred parity targets: `mydocuments` (#72, blocked on #80), `ai_settings` (#74), and `progress` (#73) |
| [bookmarks](bookmarks/README.md) | Strong bookmark-list, StudyPad, and My Notes lifecycle coverage: `7 Pass`, `2 Adapted Pass`, `0 Partial` | Focused bookmark UI workflows, visible StudyPad create coverage, visible My Notes lifecycle coverage, plus note-persistence unit regressions | No bookmark parity gap currently tracked; StudyPad reorder/delete breadth remains optional future hardening |
| [search](search/README.md) | Strong semantic coverage: `5 Pass`, `2 Adapted Pass`, `1 Partial` | Focused search UI workflows plus Strong's unit regressions | Multi-translation search still lacks focused regression coverage |
| [reading-plans](reading-plans/README.md) | Strong sync and progression coverage: `5 Pass`, `1 Adapted Pass`, `3 Partial` | Focused daily-reading UI coverage plus restore/upload/patch unit coverage | Custom plan import, reading-plan list/start/import breadth, and additive iOS-only plan lifecycle coverage |
| [reader](reader/README.md) | Reader shell/menu parity is stronger, with the remaining gap concentrated in the Strong's modal branch: `8 Pass`, `1 Adapted Pass`, `1 Partial` | Focused reader-shell UI coverage, restored-position/config-payload/gesture-policy/compare-payload unit regressions, and full local UI validation | Strong's modal coverage still needs tighter focused regression locking |
| [bridge](bridge/README.md) | StudyPad handoff, visible My Notes lifecycle, async `callId` flows, and shared iOS bridge subset are present; full Android bridge breadth remains partial: `3 Pass`, `1 Adapted Pass`, `4 Partial` | Focused StudyPad handoff, visible My Notes lifecycle coverage, async `callId`, note-persistence regressions, bridge guardrails, machine-readable gap inventory, and local Android-backed drift checking | Android-only bridge method breadth, including memorization slices #77, #76, and #78 plus My Documents slices #80, #81, #82, and #83, plus delegate branch coverage and payload-schema breadth |

## How To Read Each Domain

Each domain directory is organized the same way so it is easier to hand context
from one person to the next:

1. `contract.md`: what parity means for that domain
2. `dispositions.md`: what intentional iOS adaptations exist
3. `verification-matrix.md`: what is currently locked versus partial
4. `regression-report.md`: what validation evidence exists now
5. `guardrails.md`: what review rules apply to high-risk changes

`settings/` also carries:

- `baselines/` for machine-readable snapshots used by guardrails
- `archive/` for historical one-off analysis

## Automation Posture

The current parity story has three layers of protection.

### Tier 1: Machine-readable guardrails

Currently strongest in:

- [settings](settings/README.md)
- [bridge](bridge/README.md), for bridge inventory drift against the bundled iOS
  interface and optional local Android checkout

Current mechanisms:

- `scripts/check_settings_localization_guardrails.py`
- `scripts/check_bridge_parity_inventory.py`
- committed snapshots in `docs/parity/settings/baselines/`
- committed bridge gap inventory in `docs/parity/bridge/baselines/`
- CI integration in `.github/workflows/ios-ci.yml`

### Tier 2: Focused regression coverage

Currently strongest in:

- [sync](sync/README.md)
- [bookmarks](bookmarks/README.md)
- [search](search/README.md)
- [reading-plans](reading-plans/README.md)
- [reader](reader/README.md)
- [bridge](bridge/README.md)

Current mechanisms:

- focused `AndBibleTests` unit/integration subsets
- focused `AndBibleUITests` simulator workflows
- domain-specific regression reports documenting the rerunnable subsets

### Tier 3: Documentation guardrails

All current domains now have:

- explicit contract docs
- explicit dispositions
- explicit verification matrices
- explicit regression reports
- explicit maintenance guardrails

This is the baseline defense against silent parity drift when heavier
automation is still missing.

## Interpretation

This repo is no longer in a "parity planning only" state.

It now has:

- a top-level Android parity contract for functional, visual, and architecture
  expectations
- a documented parity contract for every current domain
- explicit iOS adaptations for every current domain
- a verification snapshot for every current domain
- a documented automation and validation posture for every current domain

What it still does not have is one uniform machine-readable drift check for
every domain. That is deliberate for now. The current posture is:

- strongest automation in `settings`
- a dedicated bridge inventory drift checker for the local
  `python3 scripts/check_bridge_parity_inventory.py --android-root ../and-bible`
  workflow
- strong focused regression evidence in `sync`, `search`, and `reading-plans`
- strong bookmark-list, visible StudyPad create, and visible My Notes evidence in `bookmarks`
- meaningful but still partial protection in `reader` and `bridge` where the
  remaining gaps are mostly focused workflow coverage, Android-only breadth, and
  payload-schema breadth

That means the docs matter. In some areas they are still the clearest way to
understand not just what the app does, but why we are treating a behavior as
"good enough", "adapted", or "still shaky".

## How To Use This Tree

When you are changing a parity-sensitive area:

1. start with [android-parity-contract.md](android-parity-contract.md)
2. use this overview to find the target domain
3. open the target domain `README.md`
4. read `contract.md` and `dispositions.md`
5. check `verification-matrix.md` for current status
6. use `regression-report.md` and `guardrails.md` to choose the validation bar

If a change meaningfully shifts the parity story, update both:

- the domain docs
- this overview
- the global contract when the standard itself changes
