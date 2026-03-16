# SEARCH-701 Verification Matrix (Android Search -> iOS)

Date: 2026-03-16

## Scope and Method

- Contract baseline: `docs/parity/search/contract.md`
- Verification method:
  - direct code inspection of `SearchView`, `SearchService`, and `StrongsSearchSupport`
  - focused simulator-backed UI coverage from `AndBibleUITests`
  - focused unit regression coverage from `AndBibleTests`
- Regression evidence: `docs/parity/search/regression-report.md`

## Status Legend

- `Pass`: implemented and backed by direct code evidence plus current regression coverage
- `Adapted Pass`: parity delivered with explicit iOS implementation differences documented in `dispositions.md`
- `Partial`: implemented or exposed, but not yet backed by enough focused evidence to treat the area as locked

## Summary

- `Pass`: 5
- `Adapted Pass`: 2
- `Partial`: 1

## Matrix

| Search Contract Area | iOS Evidence | Status | Notes |
|---|---|---|---|
| Indexed search state machine (`checkingIndex -> needsIndex -> creatingIndex -> ready`) | `SearchView.swift` state machine and index-check flow; UI tests cover direct-launch query retention plus index creation | Adapted Pass | iOS uses `SearchIndexService` + native sheet flow instead of Android implementation internals, but preserves the visible contract. |
| Word modes (`all words`, `any word`, `phrase`) rerun the active query | `SearchView.swift` option changes rerun the active query; `SearchService.swift` word-mode decoration and `searchType`; UI test `testSearchWordModeChangeRerunsQueryAndUpdatesResults` | Pass | Phrase mode is verified to collapse `earth void` to zero hits, and any-word restores hits. |
| Search scopes (`whole Bible`, `OT`, `NT`, `current book`) rerun the active query | `SearchView.swift` scope controls and rerun path; UI test `testSearchScopeChangeRerunsQueryAndUpdatesResults` | Pass | Current-book scope is reader-context driven and documented as an iOS adaptation. |
| Strong's and lemma query normalization | `SearchService.isStrongsQuery`, `SearchService.normalizeStrongsQuery`, `StrongsSearchSupport`; unit tests for `H02022`, decorated input, and bundled KJV Strong's hit search | Pass | Shorthand and decorated forms stay Android-compatible. |
| Result selection navigates the reader | `SearchView.navigateTo(_:)`; UI test `testSearchResultSelectionNavigatesReaderToBundledReference` | Pass | Search is verified as a real reader-owned workflow, not only a direct-launch harness. |
| Direct-launch query retention for deterministic search workflows | UI test `testSearchDirectLaunchRetainsSeededQuery` | Pass | This protects the test harness path used by deeper search regression coverage. |
| Search implementation backing via local FTS service plus direct SWORD fallback | `SearchView.swift`, `SearchService.swift`, `SearchIndexService`; documented in `dispositions.md` | Adapted Pass | The parity goal is query semantics and user-facing behavior, not Android's exact internal search stack. |
| Multi-translation selection and grouped result totals | `SearchView.swift` translation picker and `MultiResultGroup`; `SearchService.searchMultiple(...)` | Partial | Code path exists, but this area does not yet have a focused simulator or unit regression gate. |
