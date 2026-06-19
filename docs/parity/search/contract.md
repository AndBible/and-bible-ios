# Android Search Contract (Current iOS Surface)

This document captures the current Android-aligned search contract implemented
by iOS.

Primary code references:

- search UI and state machine:
  `Sources/BibleUI/Sources/BibleUI/Search/SearchView.swift`
- indexed search logic:
  `Sources/BibleCore/Sources/BibleCore/Services/SearchIndexService.swift`
- direct SWORD fallback logic:
  `Sources/BibleCore/Sources/BibleCore/Services/SearchService.swift`
- Strong's support:
  `Sources/BibleUI/Sources/BibleUI/Search/StrongsSearchSupport.swift`
  and `Sources/BibleCore/Sources/BibleCore/Services/StrongsTokenNormalizer.swift`

## Search State Contract

The iOS search UI preserves the Android-style state progression:

- checking for an index
- prompting index creation when missing
- showing indexing progress
- running searches in the ready state

This state machine is the current user-facing contract for indexed search.

## Word Mode Contract

The search domain preserves Android-style word-mode semantics:

- all words
- any word
- phrase

These modes control query decoration and the underlying search type used for
indexed or direct SWORD searches.

## Scope Contract

The search UI currently preserves these scopes:

- whole Bible
- Old Testament
- New Testament
- current book

Scope changes rerun the active query rather than only changing future searches.

## Strong's Contract

Strong's and lemma searches preserve Android-oriented semantics:

- `strong:<key>` and `lemma:` forms are accepted directly
- shorthand `H1234` and `G5620` forms are normalized
- these queries bypass normal word-mode decoration
- Strong's-capable Bible modules require an index before the visible search runs
- the index stores canonical Strong's tokens from raw OSIS lexical markup, matching
  Android's JSword/Lucene `strong` field behavior
- direct SWORD entry-attribute search remains a fallback when no index service is
  available

## Multi-Translation Contract

iOS supports Android-style multi-translation selection across installed Bible
modules.

The result surface preserves:

- per-module hit totals
- flattened passage hit rows for navigation
- canonical module entry ordering for scripture hits, matching Android's
  book/chapter/verse display order rather than search-engine relevance rank

## Result Navigation Contract

Selecting a search hit dismisses search and navigates the reader to the chosen
reference rather than treating search as an isolated results screen.
