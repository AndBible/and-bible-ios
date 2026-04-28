# Module Structure

This is the quickest orientation map for the repo's code modules.

## App Shell

### `AndBible.xcodeproj`

Purpose: main iOS app target, assets, entitlements, and platform-specific app lifecycle.

Start with:
- `AndBible/AndBibleApp.swift:15`
- `AndBible/ContentView.swift:12`
- `AndBible/Info.plist`

Notes:
- This is the entry point you build with `xcodebuild`, not `swift build`.
- The app consumes the Swift package modules declared in `Package.swift`.

## Swift Package Modules

Source of truth: `Package.swift`

### `CLibSword`

Purpose: C adapter layer between Swift and the prebuilt SWORD C++ binary.

Location:
- `Sources/SwordKit/CLibSword`

Dependencies:
- `libsword.xcframework`

Use when:
- Flat API calls are missing from Swift and you need a new bridge function into libsword.

### `SwordKit`

Purpose: Swift wrapper over `CLibSword` and SWORD concepts.

Location:
- `Sources/SwordKit/Sources/SwordKit`

Read first:
- `SwordManager.swift`
- `SwordModule.swift`
- `ModuleInfo.swift`

Use when:
- You need to inspect modules, positions, keys, versification, or raw/rendered entries.

Tests:
- `Sources/SwordKit/Tests/SwordKitTests`

### `BibleCore`

Purpose: domain models, SwiftData stores, services, and import/export/search logic.

Location:
- `Sources/BibleCore/Sources/BibleCore`

Read first:
- `Services/WindowManager.swift`
- `Services/BookmarkService.swift`
- `Services/SearchIndexService.swift`
- `Models/`
- `Database/`

Use when:
- The feature touches persistence, bookmarks, workspaces, reading plans, repositories, settings, or app-level business rules.

Reference:
- Persistence/entity details: [data-model.md](data-model.md)

Tests:
- `Sources/BibleCore/Tests/BibleCoreTests`

### `BibleView`

Purpose: packaged Vue.js client host plus native bridge.

Location:
- `Sources/BibleView/Sources/BibleView`

Read first:
- `BibleBridge.swift`
- `BibleWebView.swift`
- `WebViewCoordinator.swift`
- `BridgeTypes.swift`

Use when:
- The feature crosses the Swift/JS boundary or changes how the web content is loaded, configured, or messaged.

Tests:
- `Sources/BibleView/Tests/BibleViewTests`

### `BibleUI`

Purpose: SwiftUI screens, feature controllers, and app interaction flow.

Location:
- `Sources/BibleUI/Sources/BibleUI`

Read first:
- `Bible/BibleReaderView.swift`
- `Bible/BibleWindowPane.swift`
- `Bible/BibleReaderController.swift`
- `Settings/SettingsView.swift`
- `Search/SearchView.swift`

Use when:
- The feature is user-facing and involves toolbars, sheets, SwiftUI state, or feature coordination.

Tests:
- `Sources/BibleUI/Tests/BibleUITests`

## Resource Structure

### SWORD resources

- Repo copy: `AndBible/Resources/sword`
- Standalone source tree: `sword-modules/`

### Web bundle

- Packaged bundle path used by `BibleWebView`: `Sources/BibleView/Sources/BibleView/Resources`
- Loader implementation: `Sources/BibleView/Sources/BibleView/BibleWebView.swift:345`

### Docs

- Docs index: `docs/README.md`
- Parity docs: `docs/parity/`
- Developer guides: `docs/howto/`
- Backlog/task tracking outside repo history: `../parity-tasks/`
