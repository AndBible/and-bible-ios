# Working With Vue.js

The web client lives in:
- `bibleview-js/`

The packaged bundle is loaded by `BibleWebView` from SwiftPM resources:
- `Sources/BibleView/Sources/BibleView/BibleWebView.swift:279-301`

## Useful Commands

```bash
cd bibleview-js
npm run type-check
npm run test:ci
npm run build-debug
```

`dist/` is intentionally ignored. To update the checked-in, Node-free Xcode fallback, build and
atomically install a production bundle:

```bash
cd bibleview-js
npm run build-production
python3 ../scripts/manage_bibleview_bundle.py sync \
  --source dist \
  --destination ../Sources/BibleView/Sources/BibleView/Resources/bibleview-js \
  --mode production
```

CI rebuilds Debug twice and requires deterministic bytes with no checkout-specific Vue `__file`
metadata. BibleView and BibleUI package jobs install that verified Debug artifact before SwiftPM
resolution so package-level bridge diagnostics remain available. CI also rebuilds Production and
requires the committed fallback to match source exactly. App-host unit and UI jobs validate and test
that checked-in Production bundle, matching the resource packaged by normal application builds. The
release workflow always rebuilds Production before either archive and verifies the embedded SwiftPM
resource in both finished archives.

Available scripts come from:
- `bibleview-js/package.json`

## Native Bridge Assumption

The client mostly talks to native through `window.android.*` calls.
On iOS, `BibleWebView` injects a proxy that forwards those calls to `window.webkit.messageHandlers.bibleView`.

Relevant code:
- `Sources/BibleView/Sources/BibleView/BibleWebView.swift:154-176`

## Logging

`console.log`, `console.warn`, and `console.error` are forwarded back to native logging through the `jsLog` bridge message.

UI shards also retain `reader-gestures.log` alongside their XCTest results before deleting the
dedicated simulator. It contains notice-level native swipe recognition and policy dispatch records,
filtered to exclude reader text, references, and model identifiers. This file is collected on passing
and failing runs because XCTest does not always include simulator system logs in its result bundle.

Relevant code:
- `Sources/BibleView/Sources/BibleView/BibleWebView.swift:189-227`

## When You Change Client Contracts

If you change:
- a bridge method name
- a payload shape
- a native event name
- `set_config` expectations

then update both sides in the same change:
- Vue.js code in `bibleview-js/src/`
- Swift bridge types/dispatcher in `Sources/BibleView/Sources/BibleView/`
- controller emit/response code in `Sources/BibleUI/Sources/BibleUI/Bible/`
