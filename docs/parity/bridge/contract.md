# Bridge Parity Notes (Current iOS Surface)

This file explains how the iOS bridge is currently trying to stay compatible
with the Android-facing web client.

It is written as a guide to the moving parts, not as a formal transport spec.

Primary code references:

- bridge host and Android compatibility shim:
  `Sources/BibleView/Sources/BibleView/BibleWebView.swift`
- bridge dispatcher and delegate protocol:
  `Sources/BibleView/Sources/BibleView/BibleBridge.swift`
- main native delegate implementation:
  `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`

## Core Transport Shape

The shared frontend still expects Android-style bridge semantics, even on iOS.
iOS currently implements the Android-style bridge subset exercised by the
bundled iOS frontend. That is enough for the current iOS bundle to run, but it
is not full bridge parity.

Android exposes additional methods for memorization, reading progress, AI
document actions, chapter navigation, and document-page editing. Those remain
tracked parity gaps until iOS implements them or records an explicit product
divergence.

### JavaScript to native

The effective transport shape on iOS is:

```javascript
window.webkit.messageHandlers.bibleView.postMessage({ method, args })
```

But the web client is still allowed to call Android-style APIs such as
`window.android.addBookmark(...)` because iOS injects an Android compatibility
shim before the page loads.

### Native to JavaScript

Native code sends events back through:

```javascript
bibleView.emit(event, data)
```

### Async responses

Deferred requests use the shared `callId` pattern:

```javascript
bibleView.response(callId, value)
```

That contract must remain stable across Android and iOS.

## Message Shape

The best place to understand the current message surface is still the
`BibleBridgeDelegate` protocol together with the dispatcher switch in
`BibleBridge`.

Current message groups:

- navigation and scroll position
- bookmark CRUD and label actions
- content actions such as share, copy, compare, and speak
- StudyPad and My Notes actions
- dialogs, reference parsing, and help
- client state/reporting messages

The main parity risk here is casual drift in shared method names, argument
ordering, response expectations, or assuming an Android-only method is safe to
call from the iOS-packaged frontend.

The current bridge gap inventory lives at:

- `docs/parity/bridge/baselines/android-bridge-gap-inventory.json`

Use that file as the track record for Android methods that still need iOS
implementation or an explicit iOS disposition.

## Event Shape

Current native-to-JS event groups include:

- document/config lifecycle (`set_config`, `clear_document`, `add_documents`,
  `setup_content`)
- navigation/scrolling (`scroll_to_verse`, `scroll_down`, `scroll_up`)
- bookmark and label updates (`add_or_update_bookmarks`, `delete_bookmarks`,
  `update_labels`)
- StudyPad updates
- selection and active-window state

If event names or payload shapes change, both iOS and Android should be treated
as affected.

## Compatibility Shim

iOS currently preserves Android-oriented frontend assumptions by injecting:

- `window.__PLATFORM__ = 'ios'`
- `window.android = new Proxy(...)`
- a synchronous `getActiveLanguages()` cache via `window.__activeLanguages__`

This shim is part of the parity story, not incidental glue. The Vue bundle
still relies on Android-style bridge calls in multiple places.

## Payload Shape

Swift payload definitions live in:

- `Sources/BibleView/Sources/BibleView/BridgeTypes.swift`

The corresponding TypeScript-side expectations live under:

- `bibleview-js/src/types/`

Payload drift is a high-risk change because it often fails at runtime without a
compile-time signal.

## Document Routing

The embedded client now relies on document routing that is broader than the
top-level `type` field alone.

Important current examples:

- generic multi-fragment content still routes through `type: "multi"`
- Strong's / dictionary modal content routes through:
  - `type: "multi"`
  - `contentType: "strongs"`
  - optional Strong's modal state such as selected dictionary tabs

In other words, it is no longer enough to think "this is just a multi
document." The safe mental model is:

- emit the correct multi-document content type
- preserve the route-specific state fields the client expects
- keep the Swift payload shape aligned with the corresponding TypeScript types

This matters most for the Strong's modal because losing
`contentType: "strongs"` silently drops the richer Android-style tabbed path
and falls back to generic multi-document rendering.
