# SEARCH-703 Guardrails

## Purpose

Prevent high-risk search regressions by making the non-negotiable behavioral
rules explicit for changes in:

- `Sources/BibleUI/Sources/BibleUI/Search/SearchView.swift`
- `Sources/BibleCore/Sources/BibleCore/Services/SearchService.swift`
- `Sources/BibleCore/Sources/BibleCore/Services/SearchIndexService.swift`
- `Sources/BibleUI/Sources/BibleUI/Search/StrongsSearchSupport.swift`

## Rules

1. Treat search option changes as query-semantics changes, not UI-only refactors.

   Scope changes and word-mode changes are expected to rerun the active query.
   If that stops happening, the visible search contract is broken even if the
   screen still renders normally.

2. Preserve the indexed-search state machine.

   The `checkingIndex -> needsIndex -> creatingIndex -> ready` flow is part of
   the user-visible contract. Reworking it casually can break deterministic
   launch behavior and first-run indexing expectations.

3. Do not change Strong's normalization semantics casually.

   Query forms such as `H02022` and decorated Strong's input are part of the
   expected search contract. Changing normalization rules is a parity change,
   not a local cleanup.

   Strong's queries must also keep the indexed lexical-token path when an index
   service is available. Android relies on JSword's indexed `strong` field for
   find-all behavior; iOS should use raw-OSIS canonical tokens in
   `SearchIndexService` and reserve direct SWORD entry-attribute scanning for
   no-index-service fallback.

4. Treat result selection as a reader-navigation contract, not only a search
   list affordance.

   Search is only correct if a selected result moves the reader to the intended
   reference. UI changes that preserve the list but break navigation are still
   parity regressions.

5. Do not remove the local-index plus fallback-search split casually.

   iOS intentionally uses local indexing plus SWORD-backed fallback behavior.
   The implementation may differ from Android, but the visible search contract
   depends on those semantics staying coherent.

6. Multi-translation search remains a live contract surface even though it is
   still only partially regression-gated.

   Thin coverage is not a license to simplify or remove multi-translation
   behaviors opportunistically.

7. Search changes must update the docs in the same slice.

   When adding or changing search contract behavior, update:

   - `docs/parity/search/contract.md`
   - `docs/parity/search/dispositions.md` when behavior is iOS-specific
   - `docs/parity/search/verification-matrix.md` if status changes
   - `docs/parity/search/regression-report.md` when validation scope changes

## Validation Expectations

At minimum, search-adjacent changes should keep the focused search subset
described in `regression-report.md` green, especially:

- direct-launch query retention and index creation
- scope rerun behavior
- word-mode rerun behavior
- Strong's normalization and indexed lexical-token regressions
- result selection navigation back into the reader

If a change touches the still-partial multi-translation area, raise the bar and
add focused coverage rather than relying on the current subset alone.

## Current Automation Status

- The repo currently has focused search UI coverage and targeted unit
  regressions for Strong's normalization, indexed canonical tokens, and bundled KJV hits.
- Current protection is a combination of:
  - search workflow tests in `AndBibleUITests`
  - Strong's search regressions in `AndBibleTests`
  - explicit parity documentation in this directory

## Potential Improvements

- add focused regression coverage for multi-translation selection and grouped result totals
- add a tighter guardrail around search option-to-query rerun wiring
- add a machine-readable snapshot of supported search scopes and word modes if the option surface
  expands materially
