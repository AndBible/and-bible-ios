# SEARCH-702 Regression Report

Date: 2026-06-18

## Scope

Regression verification for the current search parity surface, covering:

- direct-launch search harness behavior
- local index creation against bundled modules
- scope and word-mode rerun semantics
- multi-translation selection with grouped-result totals
- Strong's normalization, indexed lexical-token search, and bundled-module hit search
- navigation from real search results back into the reader
- local Android reference comparison for word modes and multi-translation result flow

Contract reference:

- `docs/parity/search/contract.md`

Verification matrix:

- `docs/parity/search/verification-matrix.md`

## Environment

- Repository: `and-bible-ios`
- Simulator destination: `platform=iOS Simulator,name=iPhone 17`
- Validation style: focused `xcodebuild test` subset

## Current Rerunnable Test Set

### Unit

- `AndBibleTests/testStrongsQueryNormalizationHandlesLeadingZeroes`
- `AndBibleTests/testStrongsQueryNormalizationAcceptsDecoratedInput`
- `AndBibleTests/testParseVerseKeySupportsHumanReadableFormat`
- `AndBibleTests/testParseVerseKeySupportsOsisFormat`
- `AndBibleTests/testParseVerseKeySupportsOsisFormatWithSuffix`
- `AndBibleTests/testStrongsSearchFindAllOccurrencesReturnsBundledKJVMatches`
- `AndBibleTests/testStrongsSearchFindAllOccurrencesSupportsIntermediateZeroTrimVariant`
- `AndBibleTests/testSearchIndexFindsCanonicalStrongsTokens`
- `AndBibleTests/testSearchIndexReturnsTextHitsInCanonicalEntryOrder`
- `BibleCoreTests/SearchIndexServiceQueryTests/testIndexedSearchWordModesMatchAndroidSearchContracts`
- `BibleCoreTests/SearchIndexServiceQueryTests/testIndexedSearchScopeFiltersMatchAndroidSearchContracts`
- `BibleCoreTests/SearchIndexServiceQueryTests/testIndexedSearchMultipleReturnsPerModuleBucketsForGroupedTotals`
- `BibleUITests/StrongsAndDictionaryTests/testSearchTranslationSelectionKeepsPrimaryFirstAfterAndroidSortedCommit`
- `BibleUITests/StrongsAndDictionaryTests/testSearchTranslationEmptyDialogConfirmationPreservesPreviousSelection`
- `BibleUITests/StrongsAndDictionaryTests/testSearchTranslationPickerDraftStateDiscardsCancelAndOutsideDismissDrafts`
- `BibleUITests/StrongsAndDictionaryTests/testSearchTranslationSummaryUsesAndroidPrimaryFirstAbbreviationList`

### UI

- `AndBibleUITests/testSearchOptionControlsMutateVisibleState`

## Expected Assertions Covered

### Reader-owned search route

- Search opens as an Android-style reader destination, not an iOS sheet
- seeded query survives hydration into the visible Search screen
- indexed text results are emitted in canonical verse order for broad queries through package tests
- the retained visible Search workflow also commits a second translation and selects a grouped
  result without launching a second app session

### Search options

- OT, NT, and current-book filters constrain indexed search result sets
- switching scope through the visible UI controls mutates Search state and rerenders the active query
- all-words requires every query term
- switching word mode through the visible UI controls mutates Search state and rerenders the active query
- phrase mode correctly reduces non-adjacent `earth void` to zero hits
- any-word mode restores rows that contain either query term

### Multi-translation grouped results

- selecting a second translation from the Search translation picker reruns the active query
- live Cancel, outside-dismiss, and Select all -> Select none -> OK picker actions preserve the
  previous selected translation instead of committing the draft
- the visible selected-translation summary preserves Android's primary-first abbreviation list
- grouped Search state reports the selected translation set
- grouped Search state reports a combined total plus per-translation counts
- the regression fixture returns more hits only when both KJV and AATESTWEB participate
- selecting a grouped result navigates the reader away from its original passage

### Strong's behavior

- `H02022` normalization preserves both padded and unpadded lookup forms
- decorated `lemma:strong:` input is accepted unchanged
- bundled KJV Strong's searches return at least one real verse hit
- KJV index creation stores canonical H00430/H0430 Strong's tokens from raw OSIS
- indexed Strong's search returns Genesis 1:1 with cleaned snippet text

### Reader integration

- opening Search from the real reader shell, mutating option controls, then selecting a result moves
  the reader away from its seeded `Genesis 1` state

## Historical Result And Current Interpretation

Focused Strong's validation was refreshed on 2026-06-18 after adding indexed
canonical-token coverage for the H00430/H0430 KJV path.

- unit: `6` tests, `0` failures
- UI: `6` tests, `0` failures
- focused unit subset runtime: about `32s` end-to-end, with `20s` of test execution
- focused Search UI subset runtime: about `507s` end-to-end before the scope/word-mode UI workflows were combined; current focused runtime is tracked in `scripts/ui_test_timings.json`

This gives the search domain current regression evidence for:

- index lifecycle readiness
- query retention
- scope and word-mode mutation
- multi-translation grouped totals
- live multi-translation dialog cancel/dismiss/empty-OK wiring
- grouped-result navigation
- Strong's normalization/indexed lexical-token hit search
- result navigation into the reader

## Remaining Gap

No open Search parity gap is currently tracked in `verification-matrix.md`.
