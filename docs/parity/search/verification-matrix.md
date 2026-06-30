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

- `Pass`: 7
- `Adapted Pass`: 2
- `Partial`: 0

## Matrix

| Search Contract Area | iOS Evidence | Status | Notes |
|---|---|---|---|
| Indexed search state machine (`checkingIndex -> needsIndex -> creatingIndex -> ready`) | `SearchView.swift` state machine and index-check flow; package/service tests cover index creation and readiness; retained seeded UI search smoke covers ready-state direct-launch query retention and explicitly avoids runtime index creation | Adapted Pass | iOS uses `SearchIndexService` + native sheet flow instead of Android implementation internals, but preserves the visible contract. |
| Word modes (`all words`, `any word`, `phrase`) rerun the active query | `SearchView.swift` option changes rerun the active query; `SearchService.swift` word-mode decoration and `searchType`; package test `SearchIndexServiceQueryTests.testIndexedSearchWordModesMatchAndroidSearchContracts`; UI test `testSearchOptionControlsMutateVisibleState` | Pass | Package coverage locks indexed result semantics; UI coverage keeps the visible controls tied to active-query rerenders and then selects a result through the same live route. |
| Search scopes (`whole Bible`, `OT`, `NT`, `current book`) rerun the active query | `SearchView.swift` scope controls and rerun path; package test `SearchIndexServiceQueryTests.testIndexedSearchScopeFiltersMatchAndroidSearchContracts`; UI test `testSearchOptionControlsMutateVisibleState` | Pass | Current-book scope is reader-context driven and documented as an iOS adaptation; UI coverage keeps scope buttons tied to active-query rerenders and then selects a result through the same live route. |
| Strong's and lemma query normalization plus indexed lexical search | `SearchView.swift` Strong's index-readiness flow; `SearchIndexService.searchStrongs(...)`; `StrongsTokenNormalizer`; unit tests for `H02022`, decorated input, bundled KJV Strong's hit search, and indexed H00430/H0430 lookup | Pass | Shorthand and decorated forms stay Android-compatible, and Strong's find-all uses indexed canonical tokens extracted from raw OSIS before falling back to direct SWORD search. |
| Result selection navigates the reader | `SearchView.navigateTo(_:)`; UI test `testSearchOptionControlsMutateVisibleState` | Pass | Search is verified as a real reader-owned workflow, not only a direct-launch harness; the visible option-control smoke now finishes by selecting a deterministic bundled result. |
| Indexed scripture result ordering | `SearchIndexService.search(...)`; unit test `testSearchIndexReturnsTextHitsInCanonicalEntryOrder`; Android reference sorts grouped scripture results by book/chapter/verse in `SearchControl.getMultiSearchResults(...)` | Pass | iOS stores module entry order in the FTS index so broad queries display canonical scripture order instead of SQLite rank order. |
| Search route and direct-launch query retention for deterministic workflows | UI test `testSearchOptionControlsMutateVisibleState` | Pass | The retained Search workflow protects Android destination chrome, no sheet-style `Done` affordance, launch-seeded query retention, option rerendering, and result handoff in one app launch. |
| Search implementation backing via local FTS service plus direct SWORD fallback | `SearchView.swift`, `SearchService.swift`, `SearchIndexService`; documented in `dispositions.md` | Adapted Pass | The parity goal is query semantics and user-facing behavior, not Android's exact internal search stack. |
| Multi-translation selection and grouped result totals | `SearchView.swift` translation picker, `MultiResultGroup`, and rerun-on-selection path; `SearchIndexService.searchMultiple(...)`; package tests `SearchIndexServiceQueryTests.testIndexedSearchMultipleReturnsPerModuleBucketsForGroupedTotals`, `StrongsAndDictionaryTests.testSearchTranslationSelectionKeepsPrimaryFirstAfterAndroidSortedCommit`, `StrongsAndDictionaryTests.testSearchTranslationEmptyDialogConfirmationPreservesPreviousSelection`, and `StrongsAndDictionaryTests.testSearchTranslationSummaryUsesAndroidPrimaryFirstAbbreviationList`; UI test `testSearchOptionControlsMutateVisibleState`; Android reference uses `selectedTranslations` and `getMultiSearchResults(...)` in `SearchResults.kt` | Pass | Package coverage verifies grouped buckets/counts, Android ordering, empty confirmation, and summary semantics; the retained Search UI regression proves visible picker commit, abbreviation summary, grouped totals, and grouped-row navigation inside the same route/options workflow. |
