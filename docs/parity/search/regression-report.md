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

### UI

- `AndBibleUITests/testSearchDirectLaunchRetainsSeededQuery`
- `AndBibleUITests/testSearchDirectLaunchUsesSeededIndexAndReturnsBundledResults`
- `AndBibleUITests/testSearchMultiTranslationSelectionUpdatesGroupedTotals`
- `AndBibleUITests/testSearchScopeChangeRerunsQueryAndUpdatesResults`
- `AndBibleUITests/testSearchWordModeChangeRerunsQueryAndUpdatesResults`
- `AndBibleUITests/testSearchResultSelectionNavigatesReaderToBundledReference`

## Expected Assertions Covered

### Direct-launch search harness

- seeded query survives hydration into the visible Search screen
- the harness can build a disposable index against bundled modules
- the ready state reports non-zero bundled results for deterministic queries

### Search options

- switching scope from whole Bible -> OT -> NT reruns the same query
- OT scope correctly reduces `jesus` to zero bundled hits
- switching word mode from all-words -> phrase -> any-word reruns the same query
- phrase mode correctly reduces `earth void` to zero bundled hits

### Multi-translation grouped results

- selecting a second translation from the Search translation picker reruns the active query
- grouped Search state reports the selected translation set
- grouped Search state reports a combined total plus per-translation counts
- the regression fixture returns more hits only when both KJV and UITESTWEB participate
- selecting a grouped UITESTWEB result navigates the reader away from its original passage

### Strong's behavior

- `H02022` normalization preserves both padded and unpadded lookup forms
- decorated `lemma:strong:` input is accepted unchanged
- bundled KJV Strong's searches return at least one real verse hit
- KJV index creation stores canonical H00430/H0430 Strong's tokens from raw OSIS
- indexed Strong's search returns Genesis 1:1 with cleaned snippet text

### Reader integration

- opening Search from the real reader shell and selecting a result moves the
  reader away from its seeded `Genesis 1` state

## Historical Result And Current Interpretation

Focused Strong's validation was refreshed on 2026-06-18 after adding indexed
canonical-token coverage for the H00430/H0430 KJV path.

- unit: `6` tests, `0` failures
- UI: `6` tests, `0` failures
- focused unit subset runtime: about `32s` end-to-end, with `20s` of test execution
- focused Search UI subset runtime: about `507s` end-to-end, including fixture resets and simulator execution

This gives the search domain current regression evidence for:

- index lifecycle readiness
- query retention
- scope mutation
- word-mode mutation
- multi-translation grouped totals
- grouped-result navigation
- Strong's normalization/indexed lexical-token hit search
- result navigation into the reader

## Remaining Gap

No open Search parity gap is currently tracked in `verification-matrix.md`.
