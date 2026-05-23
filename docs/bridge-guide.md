# Bridge Guide

This guide describes the current Swift <-> Vue.js bridge used by `BibleView`.

## Entry Points

- Native message handler registration: `Sources/BibleView/Sources/BibleView/BibleWebView.swift:272`
- Android compatibility shim injected into the web page: `Sources/BibleView/Sources/BibleView/BibleWebView.swift:182`
- Central Swift dispatcher: `BibleBridge.dispatchMessage(method:args:)` in `Sources/BibleView/Sources/BibleView/BibleBridge.swift`
- Bridge delegate contract: `BibleBridgeDelegate` in `Sources/BibleView/Sources/BibleView/BibleBridge.swift`
- Main controller implementation: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`

## Transport Model

### JavaScript -> Swift

The web client posts messages through:

```javascript
window.webkit.messageHandlers.bibleView.postMessage({
  method: "addBookmark",
  args: ["KJV", 5, 5, false]
})
```

Swift receives that in `BibleBridge.userContentController(...)`, then routes it
through `BibleBridge.dispatchMessage(method:args:)` in
`Sources/BibleView/Sources/BibleView/BibleBridge.swift`.

### Swift -> JavaScript

Native code pushes events with:

```swift
bridge.emit(event: "set_config", data: buildConfigJSON())
```

That is implemented by `BibleBridge.emit(event:data:)` in
`Sources/BibleView/Sources/BibleView/BibleBridge.swift`.

### Async request/response

Some JS calls expect a deferred response. Native answers them with:

```swift
bridge.sendResponse(callId: callId, value: json)
```

Implementation: `BibleBridge.sendResponse(callId:value:)` in
`Sources/BibleView/Sources/BibleView/BibleBridge.swift`.

Examples:
- Expand content above/below current range: `.../BibleReaderController.swift:1751` and `:1795`
- Open native reference chooser: `.../BibleReaderController.swift:4025`
- Parse a typed reference: `.../BibleReaderController.swift:4054`

## JS -> Swift Message Catalog

The authoritative grouped catalog is the `BibleBridgeDelegate` protocol in
`Sources/BibleView/Sources/BibleView/BibleBridge.swift`.

### Navigation and scroll

Messages:
- `scrolledToOrdinal`
- `requestMoreToBeginning`
- `requestMoreToEnd`

Native handling:
- Reading position and range expansion start at `.../BibleReaderController.swift:1751`
- Active-window sync is emitted at `.../BibleReaderController.swift:5000`

### Bookmark actions

Messages:
- `addBookmark`
- `addGenericBookmark`
- `removeBookmark`
- `removeGenericBookmark`
- `saveBookmarkNote`
- `saveGenericBookmarkNote`
- `assignLabels`
- `genericAssignLabels`
- `toggleBookmarkLabel`
- `toggleGenericBookmarkLabel`
- `removeBookmarkLabel`
- `removeGenericBookmarkLabel`
- `setAsPrimaryLabel`
- `setAsPrimaryLabelGeneric`
- `setBookmarkWholeVerse`
- `setGenericBookmarkWholeVerse`
- `setBookmarkCustomIcon`
- `setGenericBookmarkCustomIcon`

Dispatcher section: `BibleBridge.dispatchMessage(method:args:)` bookmark cases in
`Sources/BibleView/Sources/BibleView/BibleBridge.swift`

### Content actions

Messages:
- `shareVerse`
- `copyVerse`
- `shareBookmarkVerse`
- `compare`
- `speak`
- `speakGeneric`
- `speakMemorizationLoop`

Dispatcher section: `BibleBridge.dispatchMessage(method:args:)` content-action cases in
`Sources/BibleView/Sources/BibleView/BibleBridge.swift`

Notes:
- The bridge normalizes `endOrdinal < 0` to `startOrdinal` for single-verse operations.
- `shareBookmarkVerse` accepts the bookmark ID string sent by the web client, then the native
  controller resolves the persisted bookmark before sharing the saved verse range.
- `addParagraphBreakBookmark` and `addGenericParagraphBreakBookmark` create native bookmarks
  with the reserved paragraph-break label so the web renderer inserts the break marker.
- `memorize` now adds the selected range as a local memorization target and opens the bundled
  Memorize document. The related state methods `addMemorizationTarget`, `markAsMemorized`,
  `removeMemorizationTarget`, and `unmarkMemorized` mutate the same local iOS state.
- `speakMemorizationLoop` accepts Android-style `(bookInitials, v11n, startOrdinal, endOrdinal)`
  arguments and delegates to the native speech service's selected-range repeat mode.
- Android's My Documents read/edit/action bridge is now partially implemented. iOS
  accepts `getMyDocumentPageRawContent`, `copyMyDocumentContent`,
  `shareMyDocumentContent`, `saveMyDocumentPageContent`, and
  `reloadMyDocumentPage`; the controller resolves pages through
  `MyDocumentStore`, returns Android-compatible raw-content JSON or `null` via
  `bibleView.response(callId, ...)`, copies/shares stored raw content, persists
  raw editor updates with optional title changes, and rebuilds the visible page
  after edit close. iOS also accepts `regenerateMyDocumentPage` and
  `deleteMyDocumentPage` for pages with `sourcePromptId` metadata. Delete removes
  only AI-generated pages and refreshes the active reader document, falling back
  to the current Bible chapter when the visible page was deleted. Regenerate
  validates the AI-page metadata and hands native context to the iOS regeneration
  callback; the shared AI dialog/backend remains tracked separately in #5/#89.
  User-authored pages without source prompt metadata are ignored and logged. The
  related `mydocuments` sync category remains tracked separately in #72.
- Android's reading-progress bridge family is accepted and model-backed on iOS.
  The native iOS reading-progress model, storage, settings contract, and Android
  owner references are recorded in
  `docs/parity/bridge/reading-progress-model.md`. `recordChapterRead` appends
  local chapter-read history, updates `chapterReadCount`, and emits
  `update_chapter_read_status`; iOS also exposes local `markChapterRead` and
  `unmarkChapterRead` operation aliases for #86. #87 adds
  `openChapterReadHistory`, `openReadingProgress`,
  `openReadingProgressSettings`, and `setReadingProgressSettings` with native
  sheet presentation, Android tab-position mapping, settings validation, and
  `update_reading_progress_settings` events. The related `progress` sync
  category remains tracked in #73 and distinct from `readingplans`.
- Android's AI bridge family is accepted but deferred. iOS should not add
  `llmAction`, `llmActionGeneric`, `noteEditorLlmAction`, `openAiDocPage`,
  `openAiDocPageChooser`, or `openPromptEditor` as standalone bridge names before the
  shared AI backend and iOS bridge shell contract exist. #89 owns the bridge shell
  contract after #5, #90 owns text-action behavior, #91 owns AI document navigation, and
  #92 owns prompt editor behavior. The related `ai_settings` sync category remains tracked
  in #74 and must wait for the shared AI settings contract.

### StudyPad

Messages:
- `openStudyPad`
- `openMyNotes`
- `deleteStudyPadEntry`
- `createNewStudyPadEntry`
- `setStudyPadCursor`
- `updateOrderNumber`
- `updateStudyPadTextEntry`
- `updateStudyPadTextEntryText`
- `updateBookmarkToLabel`
- `updateGenericBookmarkToLabel`
- `setBookmarkEditAction`

Dispatcher section: `BibleBridge.dispatchMessage(method:args:)` StudyPad cases in
`Sources/BibleView/Sources/BibleView/BibleBridge.swift`

### Navigation, dialogs, and external links

Messages:
- `openExternalLink`
- `openEpubLink`
- `openDownloads`
- `toggleCompareDocument`
- `refChooserDialog`
- `parseRef`
- `helpDialog`
- `helpBookmarks`
- `shareHtml`
- `toggleFullScreen`

Dispatcher section: `BibleBridge.dispatchMessage(method:args:)` navigation, dialog, and external-link cases in
`Sources/BibleView/Sources/BibleView/BibleBridge.swift`

### Passive state/reporting messages

Messages:
- `console`
- `jsLog`
- `toast`
- `setClientReady`
- `reportModalState`
- `reportInputFocus`
- `setLimitAmbiguousModalSize`
- `selectionCleared`
- `selectionChanged`
- `setEditing`
- `saveState`
- `onKeyDown`

Dispatcher section: `BibleBridge.dispatchMessage(method:args:)` passive state/reporting cases in
`Sources/BibleView/Sources/BibleView/BibleBridge.swift`

## Native -> JS Event Catalog

These are the active event names currently emitted from Swift. Search source with `emit(event:` if you add new ones.

### Document/config lifecycle

Primary sources:
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift:251`
- `.../BibleReaderController.swift:702`
- `.../BibleReaderController.swift:768`
- `Sources/BibleUI/Sources/BibleUI/Bible/StrongsSheetView.swift:233`

Events:
- `set_config`
- `clear_document`
- `add_documents`
- `setup_content`

### Navigation and scrolling

Primary sources:
- `.../BibleReaderController.swift:1735`
- `.../BibleReaderController.swift:1562`

Events:
- `scroll_to_verse`
- `scroll_down`
- `scroll_up`

### Bookmark and label updates

Primary sources:
- `.../BibleReaderController.swift:1883`
- `.../BibleReaderController.swift:2014`
- `.../BibleReaderController.swift:4604`

Events:
- `add_or_update_bookmarks`
- `delete_bookmarks`
- `bookmark_clicked`
- `bookmark_note_modified`
- `update_labels`

### StudyPad updates

Primary sources:
- `.../BibleReaderController.swift:2175`
- `.../BibleReaderController.swift:2204`

Events:
- `delete_study_pad_text_entry`
- `add_or_update_study_pad`
- `add_or_update_bookmark_to_label`

### Selection and active-window state

Primary sources:
- `.../BibleReaderController.swift:2373`
- `.../BibleReaderController.swift:5000`

Events:
- `set_action_mode`
- `set_active`

## Payload Types

Swift payload definitions live in `Sources/BibleView/Sources/BibleView/BridgeTypes.swift`.

High-value types:
- `OsisFragment`: rendered document fragment plus metadata
- `BibleBookmarkData`
- `GenericBookmarkData`
- `BookmarkToLabelData`
- `LabelData`
- `StudyPadTextItemData`
- `SelectionQuery`

If the Swift and TypeScript shapes drift, the failure mode is usually silent rendering breakage rather than a compile error.

## Android Compatibility Shim

The Vue.js bundle still calls `window.android.*` in many places. On iOS, `BibleWebView` injects a `Proxy` that turns those calls into `WKScriptMessageHandler` posts:

- Shim creation: `Sources/BibleView/Sources/BibleView/BibleWebView.swift:182`
- `getActiveLanguages()` is handled synchronously by reading `window.__activeLanguages__`: `.../BibleWebView.swift:184`
- Native refresh of that cache happens in `BibleBridge.updateActiveLanguages(_:)` in
  `Sources/BibleView/Sources/BibleView/BibleBridge.swift`

## Logging and Error Handling

- Browser console output is rerouted to native with `jsLog`: `Sources/BibleView/Sources/BibleView/BibleWebView.swift:219`
- `BibleBridge.emit(event:data:)` wraps JS emission in a `try/catch` and reports failures
  back through the console bridge in `Sources/BibleView/Sources/BibleView/BibleBridge.swift`
- Known methods with missing or wrong-type required arguments classify as malformed and log
  argument type diagnostics.
- Unknown methods are logged at debug level instead of crashing in
  `BibleBridge.dispatchMessage(method:args:)`.

## Selection Queries

There are two selection-query paths.

1. Lightweight DOM query in `BibleBridge.querySelection()`
2. Richer Vue.js query used by bookmark-selection flows in `BibleReaderController.querySelectionDetails()`: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift:2392`

Use the richer path when you need start/end offsets. Use the bridge fallback when you only need text and verse ordinals.

## Adding a New Bridge Method

See [howto/adding-a-bridge-method.md](howto/adding-a-bridge-method.md) for the expanded workflow. The concrete implementation pattern is:

1. Add a delegate method in `BibleBridgeDelegate` in `Sources/BibleView/Sources/BibleView/BibleBridge.swift`
2. Route the JS `method` in `BibleBridge.dispatchMessage(method:args:)` in `Sources/BibleView/Sources/BibleView/BibleBridge.swift`
3. Implement the delegate in `BibleReaderController`
4. If it is async, return through `sendResponse(...)`
5. If it mutates client state, emit the matching update event back to JS
