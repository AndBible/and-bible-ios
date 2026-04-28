# Bridge Guide

This guide describes the current Swift <-> Vue.js bridge used by `BibleView`.

## Entry Points

- Native message handler registration: `Sources/BibleView/Sources/BibleView/BibleWebView.swift:271`
- Android compatibility shim injected into the web page: `Sources/BibleView/Sources/BibleView/BibleWebView.swift:164`
- Central Swift dispatcher: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:212`
- Bridge delegate contract: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:22`
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

Swift receives that in `BibleBridge.userContentController(...)`: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:212`.

### Swift -> JavaScript

Native code pushes events with:

```swift
bridge.emit(event: "set_config", data: buildConfigJSON())
```

That is implemented in `BibleBridge.emit(...)`: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:525`.

### Async request/response

Some JS calls expect a deferred response. Native answers them with:

```swift
bridge.sendResponse(callId: callId, value: json)
```

Implementation: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:507`.

Examples:
- Expand content above/below current range: `.../BibleReaderController.swift:1751` and `:1795`
- Open native reference chooser: `.../BibleReaderController.swift:4007`
- Parse a typed reference: `.../BibleReaderController.swift:4036`

## JS -> Swift Message Catalog

The authoritative grouped catalog is the `BibleBridgeDelegate` protocol at `Sources/BibleView/Sources/BibleView/BibleBridge.swift:22`.

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

Dispatcher section: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:294`

### Content actions

Messages:
- `shareVerse`
- `copyVerse`
- `shareBookmarkVerse`
- `compare`
- `speak`
- `speakGeneric`

Dispatcher section: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:359`

Notes:
- The bridge normalizes `endOrdinal < 0` to `startOrdinal` for single-verse operations.
- `memorize` and paragraph-break bookmark actions are explicitly no-ops on iOS right now.

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

Dispatcher section: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:397`

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

Dispatcher section: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:449`

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

Dispatcher section: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:227`

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

- Shim creation: `Sources/BibleView/Sources/BibleView/BibleWebView.swift:164`
- `getActiveLanguages()` is handled synchronously by reading `window.__activeLanguages__`: `.../BibleWebView.swift:166`
- Native refresh of that cache happens in `BibleBridge.updateActiveLanguages(...)`: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:599`

## Logging and Error Handling

- Browser console output is rerouted to native with `jsLog`: `Sources/BibleView/Sources/BibleView/BibleWebView.swift:208`
- `BibleBridge.emit(...)` wraps JS emission in a `try/catch` and reports failures back through the console bridge: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:525`
- Unknown methods are logged at debug level instead of crashing: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:493`

## Selection Queries

There are two selection-query paths.

1. Lightweight DOM query in `BibleBridge.querySelection()`: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:548`
2. Richer Vue.js query used by bookmark-selection flows in `BibleReaderController.querySelectionDetails()`: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift:2392`

Use the richer path when you need start/end offsets. Use the bridge fallback when you only need text and verse ordinals.

## Adding a New Bridge Method

See [howto/adding-a-bridge-method.md](howto/adding-a-bridge-method.md) for the expanded workflow. The concrete implementation pattern is:

1. Add a delegate method in `BibleBridgeDelegate`: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:22`
2. Route the JS `method` in `userContentController(...)`: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:212`
3. Implement the delegate in `BibleReaderController`
4. If it is async, return through `sendResponse(...)`
5. If it mutates client state, emit the matching update event back to JS
