# BRIDGE-701 Verification Matrix (Android WebView Bridge -> iOS)

Date: 2026-04-28

## Scope and Method

- Contract baseline: `docs/parity/bridge/contract.md`
- Verification method:
  - direct code inspection of `BibleWebView`, `BibleBridge`, `BridgeTypes`,
    `BibleReaderController`, and `StrongsSheetView`
  - direct comparison with a local Android reference checkout, especially
    Android's `bibleview-js/src/composables/android.ts` and `BibleJavascriptInterface.kt`
  - machine-readable gap tracking in
    `docs/parity/bridge/baselines/android-bridge-gap-inventory.json`
  - focused unit and simulator-backed regression coverage for StudyPad handoff
    and note-persistence support
- Regression evidence: `docs/parity/bridge/regression-report.md`

Use this as a map of what currently feels solid versus what still needs better
protection.

The table is meant to be read as a narrative snapshot, not just a checklist.
Some areas are already dependable, while others are still documented more
strongly than they are tested.

## Status Legend

- `Pass`: implemented and backed by direct code evidence plus current regression coverage
- `Adapted Pass`: parity is there, but iOS gets there through an intentionally different path
- `Partial`: implemented or exposed, but still not backed by enough focused evidence to treat it
  as locked

## Summary

- `Pass`: 1
- `Adapted Pass`: 1
- `Partial`: 6

## Matrix

| Bridge Contract Area | iOS Evidence | Status | Notes |
|---|---|---|---|
| StudyPad handoff stays connected to native persistence and document reload | `BibleBridge.swift`, `BibleReaderController.swift`; UI test `testBookmarkListOpensStudyPadForSelectedLabel` | Pass | The current focused UI evidence covers the bookmark-label handoff into the embedded StudyPad document path. |
| My Notes visible document lifecycle and note mutation remain connected to native persistence | `BibleBridge.swift`, `BibleReaderController.swift`; unit tests `testBookmarkServiceClearingBibleBookmarkNoteDeletesPersistedNoteRow`, `testBookmarkServiceClearingBibleBookmarkNoteRemovesBookmarkFromMyNotesQuery`, `testBookmarkServiceUpdatingBibleBookmarkNoteReusesPersistedNoteRow` | Partial | The route and service support still exist, but the previous focused My Notes UI regressions are no longer present. |
| iOS preserves the shared Android-style `window.android.*` call subset and synchronous `getActiveLanguages()` behavior via an injected shim | `BibleWebView.swift` shim injection and `BibleBridge.updateActiveLanguages(_:)`; documented in `dispositions.md` | Adapted Pass | The transport path is intentionally different, and the iOS-packaged frontend boots against the Android-oriented API subset used by this repo. This is not full bridge parity. |
| Full current Android bridge surface breadth | Local comparison of iOS `bibleview-js/src/composables/android.ts` with the Android reference checkout's `app/bibleview-js/src/composables/android.ts`; `android-bridge-gap-inventory.json` | Partial | iOS currently exposes 62 bridge methods in its bundled frontend type, while Android exposes 88. The inventory tracks 26 missing Android methods plus 3 iOS no-op methods that need implementation or explicit product divergence. |
| Async `callId` request/response flows remain available for content expansion and native dialogs | `BibleBridge.sendResponse(...)`; `BibleReaderController` handlers for `requestMoreToBeginning`, `requestMoreToEnd`, `refChooserDialog`, and `parseRef` | Partial | The plumbing is there, but we still do not have a focused regression gate for `callId` request/response semantics. |
| Bookmark, label, and StudyPad delegate dispatch remains centralized in `BibleBridge` | `BibleBridge.userContentController(...)` bookmark and StudyPad switch branches; `BridgeTypes.swift` payload models | Partial | The dispatcher is still nicely centralized, but it is broad enough that argument-order or method-name drift could still sneak through without a dedicated suite. |
| Strong's sheet reuses the same bridge transport while depending on a dedicated `contentType: \"strongs\"` document route | `StrongsSheetView.swift` dedicated `BibleBridge`, `BibleReaderController.buildStrongsMultiDocJSON()`, `DocumentBroker.vue`, and `StrongsDocument.vue` | Partial | This one matters more now because losing `contentType: \"strongs\"` does not fail loudly; it quietly falls back to generic multi-document rendering. |
| Fullscreen, compare, help, external-link, and reference-dialog entry points remain exposed through the bridge | `BibleBridge.swift` switch branches for `toggleFullScreen`, `compare`, `helpDialog`, `openExternalLink`, and `refChooserDialog`; `BibleReaderController.swift` handlers | Partial | These branches are real and still parity-relevant, but they are not yet backed by focused bridge-domain regression coverage. |
| Swift bridge payloads remain centralized and expected to stay aligned with `bibleview-js` type expectations | `BridgeTypes.swift`; `bibleview-js/src/types/`; summarized in `bridge-guide.md` | Partial | The contract is at least explicit now, but we still lack an automated parity diff or generated-schema guard that would make this safer. |
