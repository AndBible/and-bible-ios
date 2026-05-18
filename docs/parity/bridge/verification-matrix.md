# BRIDGE-701 Verification Matrix (Android WebView Bridge -> iOS)

Date: 2026-05-18

## Scope and Method

- Contract baseline: `docs/parity/bridge/contract.md`
- Verification method:
  - direct code inspection of `BibleWebView`, `BibleBridge`, `BridgeTypes`,
    `BibleReaderController`, and `StrongsSheetView`
  - direct comparison with a local Android reference checkout, especially
    Android's `bibleview-js/src/composables/android.ts` and `BibleJavascriptInterface.kt`
  - machine-readable gap tracking in
    `docs/parity/bridge/baselines/android-bridge-gap-inventory.json`, checked by
    `python3 scripts/check_bridge_parity_inventory.py`
  - focused unit and simulator-backed regression coverage for StudyPad handoff
    note-persistence support, representative async `callId` flows, and selected
    bridge payload key shapes
  - focused malformed-message classification coverage for known JS-to-native
    bridge dispatch branches
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

- `Pass`: 3
- `Adapted Pass`: 1
- `Partial`: 4

## Matrix

| Bridge Contract Area | iOS Evidence | Status | Notes |
|---|---|---|---|
| StudyPad handoff stays connected to native persistence and document reload | `BibleBridge.swift`, `BibleReaderController.swift`; UI test `testBookmarkListOpensStudyPadForSelectedLabel` | Pass | The current focused UI evidence covers the bookmark-label handoff into the embedded StudyPad document path. |
| My Notes visible document lifecycle and note mutation remain connected to native persistence | `BibleBridge.swift`, `BibleReaderController.swift`; UI test `testMyNotesNoteUpdateAndDeletePersistsFromVisibleWorkflow`; unit tests `testBookmarkServiceClearingBibleBookmarkNoteDeletesPersistedNoteRow`, `testBookmarkServiceClearingBibleBookmarkNoteRemovesBookmarkFromMyNotesQuery`, `testBookmarkServiceUpdatingBibleBookmarkNoteReusesPersistedNoteRow` | Pass | The route, web bridge note mutation, native persistence, document rebuild, and visible row deletion are now covered from the production reader My Notes path. |
| iOS preserves the shared Android-style `window.android.*` call subset and synchronous `getActiveLanguages()` behavior via an injected shim | `BibleWebView.swift` shim injection and `BibleBridge.updateActiveLanguages(_:)`; documented in `dispositions.md` | Adapted Pass | The transport path is intentionally different, and the iOS-packaged frontend boots against the Android-oriented API subset used by this repo. This is not full bridge parity. |
| Full current Android bridge surface breadth | Local comparison of iOS `bibleview-js/src/composables/android.ts` with the Android reference checkout's `app/bibleview-js/src/composables/android.ts`; `android-bridge-gap-inventory.json` | Partial | iOS currently exposes 62 bridge methods in its bundled frontend type, while Android exposes 88. The inventory tracks 26 Android-only methods plus 3 former no-op dispositions: paragraph-break bookmarks are implemented, memorization is deferred by #50 into #77, #76, and #78, and My Documents is deferred by #51 into #80, #81, #82, and #83. |
| Async `callId` request/response flows remain available for content expansion and native dialogs | `BibleBridge.sendResponse(...)`; `BibleReaderController` handlers for `requestMoreToBeginning`, `requestMoreToEnd`, `refChooserDialog`, and `parseRef`; unit tests `testBridgeCallIdRequestMappingMatchesWebClientContract`, `testBridgeCallIdDispatchClassifiesKnownMalformedMessages`, `testBridgeSendResponseEmitsCallIdResponseJavaScript`, `testRequestMoreToBeginningSendsDocumentResponseWithOriginalCallId`, `testRefChooserDialogSendsResponseWithOriginalCallId`, `testParseRefSendsResponseWithOriginalCallId` | Pass | Focused shared-scheme coverage now locks the web-client `callId` argument position, malformed `callId` classification, response JavaScript shape, content expansion document response, and native dialog/parser responses preserving the original call ID. |
| Bookmark, label, and StudyPad delegate dispatch remains centralized in `BibleBridge` | `BibleBridge.dispatchMessage(method:args:)` bookmark and StudyPad switch branches; `BridgeTypes.swift` payload models; unit tests `testBridgeMessageDispatchClassifiesKnownMalformedMessages`, `testBookmarkServiceCreatesParagraphBreakBibleBookmark`, and `testBookmarkServiceCreatesParagraphBreakGenericBookmark` | Partial | Known malformed required and wrong-type positional arguments are now regression-gated, and paragraph-break bookmark creation has service-level persistence coverage. Valid delegate-callback assertions still do not cover every branch. |
| Strong's sheet reuses the same bridge transport while depending on a dedicated `contentType: \"strongs\"` document route | `StrongsSheetView.swift` dedicated `BibleBridge`, `BibleReaderController.buildStrongsMultiDocJSON()`, `DocumentBroker.vue`, and `StrongsDocument.vue` | Partial | This one matters more now because losing `contentType: \"strongs\"` does not fail loudly; it quietly falls back to generic multi-document rendering. |
| Fullscreen, compare, help, external-link, and reference-dialog entry points remain exposed through the bridge | `BibleBridge.swift` switch branches for `toggleFullScreen`, `compare`, `helpDialog`, `openExternalLink`, and `refChooserDialog`; `BibleReaderController.swift` handlers | Partial | These branches are real and still parity-relevant, but they are not yet backed by focused bridge-domain regression coverage. |
| Swift bridge payloads remain centralized and expected to stay aligned with `bibleview-js` type expectations | `BridgeTypes.swift`; `bibleview-js/src/types/`; unit test `testBridgePayloadKeysMatchWebClientContracts`; summarized in `bridge-guide.md` | Partial | Representative `OsisFragment`, `Label`/`BookmarkStyle`, and `SelectionQuery` key sets are now regression-gated, but we still lack an automated parity diff or generated-schema guard for the full payload surface. |
