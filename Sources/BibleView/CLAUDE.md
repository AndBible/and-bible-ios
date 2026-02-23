# CLAUDE.md - BibleView

## Module Purpose
WKWebView container that loads the Vue.js Bible rendering frontend and bridges
communication between Swift and JavaScript. This is the hybrid rendering layer.

## Architecture
```
BibleView
  ├── BibleWebView.swift          # SwiftUI WKWebView wrapper
  ├── BibleBridge.swift           # WKScriptMessageHandler (56+ methods)
  ├── BridgeTypes.swift           # Swift Codable types matching client-objects.ts
  └── WebViewCoordinator.swift    # UIViewRepresentable coordinator
```

## Bridge Communication

### Vue.js → Swift (56 sync + 5 async methods)
```javascript
// In Vue.js:
window.webkit.messageHandlers.bibleView.postMessage({
    method: 'scrolledToOrdinal',
    args: ['Gen.1', 42]
})
```
```swift
// In BibleBridge.swift:
func userContentController(_ controller: WKUserContentController,
                          didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any],
          let method = body["method"] as? String,
          let args = body["args"] as? [Any] else { return }
    switch method {
    case "scrolledToOrdinal": handleScrolledToOrdinal(args)
    // ...
    }
}
```

### Swift → Vue.js (events + async responses)
```swift
// Send event
webView.evaluateJavaScript("bibleView.emit('updateBookmarks', \(json))")

// Respond to async request
webView.evaluateJavaScript("bibleView.response(\(callId), '\(result)')")
```

## Bridge Method Tiers
- **Tier 1 (10 methods)**: Logging, toast, client ready, scroll reporting, modal state
- **Tier 2 (35 methods)**: Bookmark CRUD, label management, StudyPad, share/copy
- **Tier 3 (6 methods)**: Async dialog results, document fetching, TTS, navigation

## Key Types (BridgeTypes.swift)
Must match TypeScript interfaces in `client-objects.ts`:
- `OsisFragment`: Bible text with metadata
- `BibleBookmarkData` / `GenericBookmarkData`: Bookmark representations
- `LabelData`: Label with style
- `StudyPadItem`: Journal or bookmark entry
- `BookmarkStyle`: Color, underline, marker options

## Testing
```bash
swift test --filter BibleViewTests
```

## Reference
- Android bridge: `BibleJavascriptInterface.kt`
- Vue.js bridge: `composables/android.ts`
- Data types: `types/client-objects.ts`
- Init pattern: `main.ts`
