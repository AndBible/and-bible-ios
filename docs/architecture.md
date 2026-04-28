# Architecture

This project is an Xcode app plus four Swift package modules layered from low-level SWORD access up to SwiftUI screens.

## Start Here

- App entry point: `AndBible/AndBibleApp.swift:15`
- Root navigation shell: `AndBible/ContentView.swift:12`
- Package/module graph: `Package.swift:5`
- Main reading coordinator: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift:42`
- Per-pane bridge/web view host: `Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift:16`
- JS bridge contract: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:19`

## Module Graph

```text
AndBible.xcodeproj app
  -> BibleUI
    -> BibleView
      -> BibleCore
        -> SwordKit
          -> CLibSword
            -> libsword.xcframework
```

Source of truth for this graph: `Package.swift:11-93`.

## Layers

### 1. `SwordKit`

Purpose: Swift wrapper around the prebuilt SWORD C++ library.

Key points:
- `CLibSword` exposes the adapter C headers and links `z`, `bz2`, and `c++`: `Package.swift:24-38`
- `SwordKit` is the Swift API surface used everywhere else: `Package.swift:40-50`
- This is the lowest layer that should know about SWORD module positioning, keys, and raw entries.

### 2. `BibleCore`

Purpose: persistence, services, and domain logic.

Key points:
- Declared at `Package.swift:52-65`
- Holds SwiftData models, stores, and services such as `WindowManager`, `BookmarkService`, `SearchIndexService`, and `SyncService`
- `AndBibleApp` creates the `ModelContainer`, initializes stores/services, seeds default labels, and starts sync monitoring: `AndBible/AndBibleApp.swift:39-137`

### 3. `BibleView`

Purpose: host the packaged Vue.js client in `WKWebView` and translate between JS messages and native callbacks.

Key points:
- Declared at `Package.swift:67-80`
- `BibleWebView` creates the web view, injects the Android compatibility shim, and loads the packaged bundle: `Sources/BibleView/Sources/BibleView/BibleWebView.swift:164` and `:345`
- `BibleBridge` owns the message handler, async response path, and native-to-JS emit API: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:212`
- `WebViewCoordinator` handles navigation interception plus native scroll/swipe gesture forwarding: `Sources/BibleView/Sources/BibleView/WebViewCoordinator.swift:12-143`

### 4. `BibleUI`

Purpose: SwiftUI feature screens and controllers.

Key points:
- Declared at `Package.swift:82-92`
- `BibleReaderView` coordinates toolbars, sheets, split windows, fullscreen state, and settings reload: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift:151`
- `BibleWindowPane` binds one `BibleBridge`, one `BibleReaderController`, and one `BibleWebView` to a single window: `Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift:34`
- `BibleReaderController` is the main feature controller implementing the bridge delegate and emitting document/config/bookmark updates back to Vue.js: for example `updateDisplaySettings` at `.../BibleReaderController.swift:245`, async content expansion at `:1751`, selection actions at `:2392`, and active-window emission at `:5000`

## App Boot Sequence

1. `AndBibleApp` runs `DataMigration.migrateIfNeeded()` before creating SwiftData: `AndBible/AndBibleApp.swift:39-44`
2. It reads the iCloud sync toggle from `UserDefaults` before container creation: `AndBible/AndBibleApp.swift:43-45`
3. It builds two model configurations:
   - Cloud/user data store: `AndBible/AndBibleApp.swift:46-82`
   - Local-only store: `AndBible/AndBibleApp.swift:84-89`
4. It prepares the SWORD module directory with `SwordSetup.ensureModulesReady()`: `AndBible/AndBibleApp.swift:91-92`
5. It creates stores/services, chooses or creates the active workspace, seeds system labels, and starts sync monitoring: `AndBible/AndBibleApp.swift:99-135`
6. The app scene renders either `CalculatorView` or `ContentView` depending on persecution settings: `AndBible/AndBibleApp.swift:140-174`

## Reading Flow

Typical Bible reading flow:

1. `ContentView` shows `BibleReaderView` as the main detail surface: `AndBible/ContentView.swift:11`
2. `BibleReaderView` lays out one or more `BibleWindowPane`s for the active workspace: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift`
3. Each pane initializes a `BibleReaderController` and registers it with `WindowManager`: `Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift:34`
4. `BibleReaderController` loads SWORD content, builds bridge JSON, and emits `clear_document`, `add_documents`, and `setup_content`: for example document emission at `.../BibleReaderController.swift:702`
5. The Vue.js client renders the document in the packaged `WKWebView`
6. User actions from the client come back through `BibleBridge.userContentController(...)`: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:212`
7. Native responses and state pushes go back through `sendResponse(...)` and `emit(...)`: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:507`

## State Ownership

There are three distinct state domains.

### SwiftData persisted state

Examples:
- Workspaces, windows, page managers, history items: `AndBible/AndBibleApp.swift:48-52`
- Bookmarks, labels, StudyPad, reading plans: `AndBible/AndBibleApp.swift:53-63`
- Device-local repositories and settings: `AndBible/AndBibleApp.swift:66-69`

### Native in-memory UI state

Examples:
- Current fullscreen and sheet state in `BibleReaderView`: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift:47-103`
- Per-pane bridge/controller lifetime in `BibleWindowPane`: `Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift:24-53`
- Current selection, loaded chapter range, and active module state in `BibleReaderController`

### Web client state

Examples:
- Client readiness, current rendered document set, modal state, input focus, and DOM selection
- Persisted opaque UI state sent back through `saveState`: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:252-255`
- Requested again through `PageManager.jsState` restore flows in the controller layer

## Threading Model

The practical threading rules are:

- SwiftUI and `WKWebView` interactions stay on the main actor/thread.
- `BibleBridge.querySelection()` is explicitly `@MainActor`: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:548`
- Bridge JS evaluation is marshalled back to the main queue in `evaluateJavaScript(...)`: `Sources/BibleView/Sources/BibleView/BibleBridge.swift:605`
- SWORD and service work is generally orchestrated by controllers/services, then pushed back to the bridge on the main thread.

When adding new code, treat `WKWebView`, SwiftUI view state, and bridge callbacks as main-thread work unless a specific service already isolates background work for you.

## Multi-Window Model

AndBible iOS keeps Android's multi-window reading model.

- `WindowManager` is injected as an environment object from `AndBibleApp`: `AndBible/AndBibleApp.swift:149-153`
- `BibleReaderView` reads the focused controller from `WindowManager` and manages fullscreen/tab bar behavior from that single source of truth: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift:151`
- `BibleWindowPane` instances render independent bridges/controllers, so each pane can hold a different module/category and scroll position: `Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift:34`
- The web client receives active-window state from `emitActiveState()`: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift:5000`

## Where To Read Next

- Bridge details: [bridge-guide.md](bridge-guide.md)
- Persistence/entity reference: [data-model.md](data-model.md)
- Build and simulator workflow: [howto/building-and-testing.md](howto/building-and-testing.md)
- Module-by-module reading order: [module-structure.md](module-structure.md)
