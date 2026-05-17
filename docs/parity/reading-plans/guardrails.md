# READING-PLANS-703 Guardrails

## Purpose

Prevent high-risk reading-plan regressions by making the non-negotiable
behavioral rules explicit for changes in:

- `Sources/BibleCore/Sources/BibleCore/Services/ReadingPlanService.swift`
- `Sources/BibleCore/Sources/BibleCore/Models/ReadingPlan.swift`
- `Sources/BibleUI/Sources/BibleUI/ReadingPlans/`
- `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncReadingPlan*`

## Rules

1. Do not change Android `.properties` parsing semantics casually.

   The `dayNumber=OsisRef...` format and the handling of non-numeric keys are
   part of the import contract. Parser “cleanup” can become a cross-platform
   compatibility break.

2. Preserve the documented `currentDay` versus `dayNumber` distinction.

   iOS intentionally keeps `ReadingPlan.currentDay` zero-based while persisted
   `ReadingPlanDay.dayNumber` rows remain 1-based. That asymmetry is deliberate
   and should not be flattened casually.

3. Treat Android raw reading-plan status payloads as fidelity data.

   The restore/apply/upload pipeline preserves Android status JSON for a
   reason. Replacing that with a lossy local-only representation is a parity
   change.

4. Do not change patch and baseline semantics casually.

   Reading plans participate in initial-backup import/export, patch-zero
   recording, sparse replay, and sparse upload. Changes to those semantics are
   sync-contract changes, not local model cleanups.

5. iOS-only algorithmic plans must remain additive.

   Plans such as `ntIn90Days` and `psalmsProverbs` are documented iOS
   extensions. They must not replace, rename, or redefine the Android bundled
   plan contract.

6. Reading-plan UI changes must preserve progression semantics.

   A plan is only correct if day completion and next-day advancement still work
   from the user’s point of view. Visual changes that break advancement are
   parity regressions.

7. Reading-plan changes must update the docs in the same slice.

   When adding or changing reading-plan contract behavior, update:

   - `docs/parity/reading-plans/contract.md`
   - `docs/parity/reading-plans/dispositions.md` when behavior is iOS-specific
   - `docs/parity/reading-plans/verification-matrix.md` if status changes
   - `docs/parity/reading-plans/regression-report.md` when validation scope changes

## Validation Expectations

At minimum, reading-plan-adjacent changes should keep the focused coverage
described in `regression-report.md` green, especially:

- daily-reading progression
- Android snapshot restore and validation failures
- initial-backup upload/reset behavior
- sparse patch replay/upload and ready-state synchronization

If a change touches one of the still-partial areas, raise the bar and add
focused coverage rather than relying on the existing subset alone.

## Current Automation Status

- The repo currently has focused reading-plan UI coverage plus targeted unit and
  integration coverage for restore, upload, and patch behavior.
- Current protection is a combination of:
  - reading-plan workflow tests in `AndBibleUITests`
  - custom import and additive algorithmic lifecycle tests in `AndBibleTests`
  - restore/apply/upload regressions in `AndBibleTests`
  - explicit parity documentation in this directory

## Potential Improvements

- broaden UI coverage around actual custom file-import success paths when an
  automation-safe file-picker harness exists
