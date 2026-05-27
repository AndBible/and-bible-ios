# Adding A New View

## 1. Pick The Right Layer

Most user-facing views belong in:
- `Sources/BibleUI/Sources/BibleUI/`

Examples:
- Search: `.../Search/SearchView.swift`
- Settings: `.../Settings/SettingsView.swift`
- Downloads: `.../Downloads/ModuleBrowserView.swift`
- Reading shell: `.../Bible/BibleReaderView.swift`

## 2. Decide Whether It Is Pure SwiftUI Or Bridge-Backed

Use pure SwiftUI when the feature is native-only.

Use `BibleWebView` plus a controller/bridge when the feature needs the existing Vue.js document renderer.

Examples:
- Main reading panes: `Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift`
- Transient reader documents: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`

## 3. Wire Services Through The Existing Environment

Common dependencies:
- `@Environment(\.modelContext)` for SwiftData
- `@Environment(WindowManager.self)` for multi-window state
- `@Environment(SearchIndexService.self)` for search index operations

The root injections happen in `AndBible/AndBibleApp.swift:149-153`.

## 4. Attach The View To Navigation

Common attachment points:
- `AndBible/ContentView.swift` for top-level tabs/sidebar entries
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift` for sheets, menus, and reading-flow surfaces
- `Sources/BibleUI/Sources/BibleUI/Settings/SettingsView.swift` for settings-linked flows

## 5. Persist State Deliberately

If the view changes durable app state, route through the correct store/service in `BibleCore`.

Do not let SwiftUI local state become the only source of truth for:
- bookmarks
- workspaces
- settings
- reading plans
- repositories

## 6. Validate On Simulator

Use `xcodebuild` and the simulator. Do not rely on `swift build` for app validation.
