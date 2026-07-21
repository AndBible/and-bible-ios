# CLAUDE.md - bibleview-js

This file provides guidance to Claude Code when working in `bibleview-js/`.

## Project Overview

`bibleview-js` is the Vue.js frontend bundled into the iOS app's WKWebView. It
is a fork of the Android AndBible frontend, but Android compatibility is still a
hard requirement.

Most feature logic, document rendering, bridge payloads, and client-object
shapes are still shared in spirit with Android. Treat Android parity as the
default unless the repo explicitly documents an intentional iOS divergence.

## Android Compatibility

- Never break Android compatibility. Do not change shared bridge method names,
  event names, payload shapes, async response handling, document models, or
  localization keys in ways that would diverge from Android by accident.
- Prefer additive or routing-style changes over platform forks. If a platform
  difference is necessary, isolate it in a narrow abstraction instead of
  rewriting shared component behavior.
- When changing a shared contract, verify both the iOS usage here and the
  Android source of truth before treating the work as complete.
- If you need a local Android reference checkout, clone
  `https://github.com/andbible/and-bible` into `.and-bible-android/` at the
  repo root. That directory is gitignored and should remain local-only.

Useful Android reference paths inside that local clone:

- `.and-bible-android/app/bibleview-js/`
- `.and-bible-android/app/bibleview-js/src/composables/android.ts`
- `.and-bible-android/app/bibleview-js/src/types/client-objects.ts`

Do not commit machine-specific sibling-path assumptions such as `../and-bible/`.

## Architecture

### Key Files

- `src/main.ts`: frontend bootstrap
- `src/components/BibleView.vue`: root reader/document surface
- `src/composables/android.ts`: main bridge-facing frontend contract used by the
  app surface
- `src/composables/native-bridge.ts`: platform routing layer for Android WebView
  vs iOS WKWebView calls
- `src/types/client-objects.ts`: shared client-object payload shapes
- `src/utils.ts`: shared DOM/helpers, including some WKWebView-specific handling

### Bridge Model

- Android bridge calls still use `window.android.methodName(...)`
- iOS bridge calls use
  `window.webkit.messageHandlers.bibleView.postMessage({ method, args })`
- Async responses on both platforms flow back through
  `window.bibleView.response(callId, value)`
- Native-to-JS events still use the shared `bibleView.emit(event, data)` pattern

The main iOS-specific abstraction is `src/composables/native-bridge.ts`, but do
not assume all platform-specific logic lives only there. Keep any further
divergence narrow and deliberate.

## Build and Validation

Run only the frontend checks relevant to the change, but at minimum use the
standard repo commands:

```bash
npm install
npm run test:ci
npm run lint
npm run type-check
npm run build-debug
```

Other available scripts:

```bash
npm run dev
npm run build-production
```

The ignored build output in `dist/` is not packaged automatically by local Xcode builds. The committed
production fallback lives at `../Sources/BibleView/Sources/BibleView/Resources/bibleview-js/`; update
it atomically with `scripts/manage_bibleview_bundle.py` as documented in
`docs/howto/working-with-vuejs.md`. CI supplies a verified Debug bundle before test builds, while the
release workflow rebuilds Production before archive creation and verifies each archived copy.

## Working Rules

- Minimize divergence from Android unless iOS requires a specific bridge or
  platform adaptation.
- If you change bridge contracts, verify the corresponding native iOS code in
  `Sources/BibleView/` or `Sources/BibleUI/` and compare against Android.
- Keep shared payload and type changes synchronized with
  `src/types/client-objects.ts` and related consumers.
- Do not introduce iOS-only behavior into shared components when the change can
  be expressed in the bridge/adaptation layer instead.
