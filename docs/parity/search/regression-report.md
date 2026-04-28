# SEARCH-702 Regression Report

Date: 2026-04-28

## Scope

Regression verification for the current search parity surface, covering:

- direct-launch search harness behavior
- local index creation against bundled modules
- scope and word-mode rerun semantics
- Strong's normalization and bundled-module hit search
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

### UI

- `AndBibleUITests/testSearchDirectLaunchRetainsSeededQuery`
- `AndBibleUITests/testSearchDirectLaunchUsesSeededIndexAndReturnsBundledResults`
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

### Strong's behavior

- `H02022` normalization preserves both padded and unpadded lookup forms
- decorated `lemma:strong:` input is accepted unchanged
- bundled KJV Strong's searches return at least one real verse hit

### Reader integration

- opening Search from the real reader shell and selecting a result moves the
  reader away from its seeded `Genesis 1` state

## Historical Result And Current Interpretation

Focused search validation passed on 2026-03-16. The direct-launch indexed-result UI test has since
been renamed to `testSearchDirectLaunchUsesSeededIndexAndReturnsBundledResults`; this doc refresh
did not rerun the simulator suite.

- unit: `6` tests, `0` failures
- UI: `5` tests, `0` failures
- combined focused subset runtime: about `221s` end-to-end, including build and simulator execution

This gives the search domain current regression evidence for:

- index lifecycle readiness
- query retention
- scope mutation
- word-mode mutation
- Strong's normalization/hit search
- result navigation into the reader

## Remaining Gap

The current search parity gap is not the core indexed search workflow. It is:

- multi-translation selection and grouped-result verification

That path exists in code but is not yet covered by a focused regression test,
so it remains `Partial` in `verification-matrix.md`.
