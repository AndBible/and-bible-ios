# Parity Status Overview

Date: 2026-04-28

## Purpose

This is the quickest way to get oriented on Android parity in
`and-bible-ios`.

If you are touching a parity-sensitive area, this file should help you answer
four questions without having to reconstruct repo history first:

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
| [sync](sync/README.md) | Strong for supported Android categories: `6 Pass`, `2 Adapted Pass`, `2 Partial` | Focused unit/integration coverage, focused Sync UI coverage, explicit guardrails | Android-only category breadth (`mydocuments`, `ai_settings`, `progress`) and adopt/create confirmation UI still partial |
| [bookmarks](bookmarks/README.md) | Strong bookmark-list coverage, thinner note-document UI coverage: `4 Pass`, `2 Adapted Pass`, `3 Partial` | Focused bookmark UI workflows plus note-persistence unit regressions | Generic-bookmark visible workflows, My Notes visible note mutation, and broader StudyPad mutation breadth |
| [search](search/README.md) | Strong semantic coverage: `5 Pass`, `2 Adapted Pass`, `1 Partial` | Focused search UI workflows plus Strong's unit regressions | Multi-translation search still lacks focused regression coverage |
| [reading-plans](reading-plans/README.md) | Strong sync and progression coverage: `5 Pass`, `1 Adapted Pass`, `3 Partial` | Focused daily-reading UI coverage plus restore/upload/patch unit coverage | Custom plan import, reading-plan list/start/import breadth, and additive iOS-only plan lifecycle coverage |
| [reader](reader/README.md) | Reader shell/menu parity is stronger, but deeper gesture/modal/config branches remain partial: `4 Pass`, `1 Adapted Pass`, `5 Partial` | Focused reader-shell UI coverage, restored-position unit regressions, and full local UI validation | Strong's modal, fullscreen, swipe-mode, compare, and config-bridge coverage still need tighter focused regression locking |
| [bridge](bridge/README.md) | StudyPad handoff and shared iOS bridge subset are present; full Android bridge breadth remains partial: `1 Pass`, `1 Adapted Pass`, `6 Partial` | Focused StudyPad handoff, note-persistence regressions, bridge guardrails, and a machine-readable gap inventory | Raw bridge drift detection, visible My Notes lifecycle coverage, Android-only bridge method breadth, payloads, and async `callId` flows |

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

Current mechanisms:

- `scripts/check_settings_localization_guardrails.py`
- committed snapshots in `docs/parity/settings/baselines/`
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

- a documented parity contract for every current domain
- explicit iOS adaptations for every current domain
- a verification snapshot for every current domain
- a documented automation and validation posture for every current domain

What it still does not have is one uniform machine-readable drift check for
every domain. That is deliberate for now. The current posture is:

- strongest automation in `settings/`
- strong focused regression evidence in `sync`, `search`, and `reading-plans`
- strong bookmark-list evidence in `bookmarks`, with visible My Notes and broader
  StudyPad mutation still partial
- meaningful but still partial protection in `reader` and `bridge` where the
  remaining gaps are mostly boundary and protocol behaviors

That means the docs matter. In some areas they are still the clearest way to
understand not just what the app does, but why we are treating a behavior as
"good enough", "adapted", or "still shaky".

## How To Use This Tree

When you are changing a parity-sensitive area:

1. start with this overview
2. open the target domain `README.md`
3. read `contract.md` and `dispositions.md`
4. check `verification-matrix.md` for current status
5. use `regression-report.md` and `guardrails.md` to choose the validation bar

If a change meaningfully shifts the parity story, update both:

- the domain docs
- this overview
