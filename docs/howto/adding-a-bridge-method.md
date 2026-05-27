# Adding A Bridge Method

Use this flow when the Vue.js client needs a new native capability.

## 1. Define The Native Contract

Add a method to `BibleBridgeDelegate` in:
- `Sources/BibleView/Sources/BibleView/BibleBridge.swift`

The delegate protocol is the source of truth for JS -> Swift capabilities.

## 2. Route The JS Message

Add a `case` in `BibleBridge.userContentController(...)`:
- `Sources/BibleView/Sources/BibleView/BibleBridge.swift:195-457`

Pattern:
- read `method`
- decode `args`
- normalize odd values if needed
- call the typed delegate method

If the JS side expects an async reply, keep the `callId` and answer later with `sendResponse(...)`.

## 3. Implement The Delegate In The Main Controller

Primary implementation target:
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`

That controller owns reading state, services, bookmarks, navigation, and most bridge-backed behavior.

## 4. Check Secondary Delegate Owners If Needed

The main reader controller owns the active document bridge. If a future feature
adds another bridge-backed surface with its own delegate, decide whether new
required protocol methods need real handling there or an explicit no-op.

## 5. Add Or Update Native -> JS Events

If your new capability changes client-visible state, emit the matching update event back to the web client with `bridge.emit(...)`.

Search existing event usage:

```bash
rg -n 'emit\(event:' Sources -g '*.swift'
```

## 6. Update The Web Client

Relevant web bundle root:
- `bibleview-js/src/`

The iOS host injects an Android-style bridge shim in:
- `Sources/BibleView/Sources/BibleView/BibleWebView.swift:154-176`

That means most client changes still call `window.android.someMethod(...)`.

## 7. Rebuild The Bundle If Needed

If you changed the Vue.js client:

```bash
cd bibleview-js
npm run build-debug
```

Then ensure the packaged resources used by `BibleWebView` are current.

## 8. Validate End To End

Run the simulator tests:

```bash
xcodebuild \
  -project AndBible.xcodeproj \
  -scheme AndBible \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .derivedData \
  -resultBundlePath .artifacts/AndBibleTests.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Then exercise the feature in the simulator if it is UI-visible.
