# SEARCH-701 Verification Matrix (Android Search -> iOS)

Date: 2026-06-18

## Scope and Method

- Contract baseline: `docs/parity/search/contract.md`
- Verification method:
  - direct code inspection of `SearchView`, `SearchIndexService`, `SearchService`,
    `StrongsSearchSupport`, and `StrongsTokenNormalizer`
  - direct comparison with a local Android reference checkout, especially
    `Search.kt`, `SearchResults.kt`, `EpubSearch.kt`, and `MultiSearchItemAdapter.kt`
  - focused simulator-backed UI coverage from `AndBibleUITests`
  - focused unit regression coverage from `AndBibleTests`
- Regression evidence: `docs/parity/search/regression-report.md`

## Status Legend

- `Pass`: implemented and backed by direct code evidence plus current regression coverage
- `Adapted Pass`: parity delivered with explicit iOS implementation differences documented in `dispositions.md`
- `Partial`: implemented or exposed, but not yet backed by enough focused evidence to treat the area as locked

## Summary

- `Pass`: 6
- `Adapted Pass`: 2
- `Partial`: 0

## Matrix

| Search Contract Area | iOS Evidence | Status | Notes |
|---|---|---|---|
| Indexed search state machine (`checkingIndex -> needsIndex -> creatingIndex -> ready`) | `SearchView.swift` state machine and index-check flow; UI tests cover direct-launch query retention plus index creation | Adapted Pass | iOS uses `SearchIndexService` + native sheet flow instead of Android implementation internals, but preserves the visible contract. |
| Word modes (`all words`, `any word`, `phrase`) rerun the active query | `SearchView.swift` option changes rerun the active query; `SearchService.swift` word-mode decoration and `searchType`; UI test `testSearchWordModeChangeRerunsQueryAndUpdatesResults` | Pass | Phrase mode is verified to collapse `earth void` to zero hits, and any-word restores hits. |
| Search scopes (`whole Bible`, `OT`, `NT`, `current book`) rerun the active query | `SearchView.swift` scope controls and rerun path; UI test `testSearchScopeChangeRerunsQueryAndUpdatesResults` | Pass | Current-book scope is reader-context driven and documented as an iOS adaptation. |
| Strong's and lemma query normalization plus indexed lexical search | `SearchView.swift` Strong's index-readiness flow; `SearchIndexService.searchStrongs(...)`; `StrongsTokenNormalizer`; unit tests for `H02022`, decorated input, bundled KJV Strong's hit search, and indexed H00430/H0430 lookup | Pass | Shorthand and decorated forms stay Android-compatible, and Strong's find-all uses indexed canonical tokens extracted from raw OSIS before falling back to direct SWORD search. |
| Result selection navigates the reader | `SearchView.navigateTo(_:)`; UI test `testSearchResultSelectionNavigatesReaderToBundledReference` | Pass | Search is verified as a real reader-owned workflow, not only a direct-launch harness. |
| Direct-launch query retention for deterministic search workflows | UI test `testSearchDirectLaunchRetainsSeededQuery` | Pass | This protects the test harness path used by deeper search regression coverage. |
| Search implementation backing via local FTS service plus direct SWORD fallback | `SearchView.swift`, `SearchService.swift`, `SearchIndexService`; documented in `dispositions.md` | Adapted Pass | The parity goal is query semantics and user-facing behavior, not Android's exact internal search stack. |
| Multi-translation selection and grouped result totals | `SearchView.swift` translation picker, `MultiResultGroup`, and rerun-on-selection path; `SearchIndexService.searchMultiple(...)`; UI test `testSearchMultiTranslationSelectionUpdatesGroupedTotals`; Android reference uses `selectedTranslations` and `getMultiSearchResults(...)` in `SearchResults.kt` | Pass | The focused UI regression selects a second translation, verifies grouped totals/per-module counts, and selects a grouped result, so this path now fails if Search only returns the primary translation or grouped rows stop navigating. |
