# AndBible AI Agent Instructions

**ALWAYS follow these instructions first and only fall back to additional search and context gathering if the information here is incomplete or found to be in error.**

AndBible iOS is the iPhone/iPad port of AndBible. It uses a hybrid architecture:
- native SwiftUI for app navigation, settings, bookmarks, sync, and supporting workflows
- WKWebView + Vue.js for Bible content rendering where the shared frontend is still the product surface
- `libsword` via Swift wrappers for SWORD Bible/module access

## Architecture Overview

### Core Components
- **iOS App Target** (`AndBible/`): app entry point, resources, app-level configuration
- **SwordKit** (`Sources/SwordKit/`): Swift wrapper over libsword's flat C API
- **BibleCore** (`Sources/BibleCore/`): SwiftData models, persistence, services, sync, business logic
- **BibleView** (`Sources/BibleView/`): WKWebView bridge and bundled Vue.js resources
- **BibleUI** (`Sources/BibleUI/`): native SwiftUI feature screens and the reader coordinator
- **Vue.js Frontend** (`bibleview-js/`): shared BibleView frontend built with Vite/Vue 3

### Key Architectural Patterns
- **Reader-coordinator design**: `BibleReaderView` owns top-level sheet routing and delegates reading behavior to focused controllers from `WindowManager`
- **Workspace-centric model**: workspaces, windows, page managers, bookmarks, labels, reading plans, and history are modeled in SwiftData-backed services
- **Hybrid web/native rendering**: Bible document content is still rendered in WebView, while native SwiftUI handles the rest of the application shell
- **Deterministic UI harnesses**: XCUITests use explicit `UITEST_*` launch arguments and in-memory stores; test-only behavior must remain behind those gates

## Prerequisites and Environment Setup

**Required baseline**:
- Xcode 17 or newer
- iOS 17 simulator available
- Node.js 20+ and npm for `bibleview-js`
- checked-in `libsword/libsword.xcframework`

**Useful verification commands**:
```bash
xcodebuild -version
node --version
npm --version
```

## Working Effectively - Core Build Commands

### App Build / Test
```bash
# Build for simulator
xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# Full shared-scheme test run (unit + UI)
xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

# Focused test run
xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:AndBibleUITests/AndBibleUITests/testExample
```

### Swift Package Validation
```bash
swift build
swift test
```

### Vue.js Development
```bash
cd bibleview-js
npm install            # initial setup
npm run test:ci
npm run lint
npm run type-check
npm run build-debug
```

### Repo Guardrails
```bash
git diff --check
python3 scripts/check_repo_standards.py docblocks --all-files
```

## Validation Scenarios

**ALWAYS run the narrowest relevant validation for the area changed.**

### SwiftUI / App / Integration Changes
- Prefer targeted `xcodebuild test` runs
- Use `-only-testing:` whenever practical
- If you changed shared reader coordination, UI harnesses, or scheme-level behavior, run a broader shared-scheme test pass

### Package-Only Logic Changes
- `swift test` is useful for package targets
- Still use `xcodebuild` if the change touches app wiring, SwiftUI behavior, environment injection, or UI harnesses

### Vue.js / WebView Changes
```bash
cd bibleview-js
npm run test:ci
npm run lint
npm run type-check
npm run build-debug
```

If frontend assets changed, rebuild before app validation.

## Build and Test Expectations

- `xcodebuild` is the authoritative validation path for app behavior
- `swift build` and `swift test` are supplemental, not replacements for app-target validation
- `project.yml` may lag the live Xcode project; trust the checked-in `AndBible.xcodeproj` and shared scheme first
- Use a dedicated `-derivedDataPath` plus `clean test` when UI tests look stale

## Key Files and Directories

### Core Application
- `AndBible/AndBibleApp.swift`: app bootstrap and environment setup
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift`: main reader coordinator and test harness routing
- `Sources/BibleUI/Sources/BibleUI/Search/SearchView.swift`: indexed search UI
- `Sources/BibleUI/Sources/BibleUI/Bookmarks/BookmarkListView.swift`: bookmark workflows
- `Sources/BibleUI/Sources/BibleUI/Shared/HistoryView.swift`: history workflows
- `Sources/BibleCore/Sources/BibleCore/Services/WindowManager.swift`: workspace/window coordination
- `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncSynchronizationService.swift`: sync orchestration
- `Sources/SwordKit/Sources/SwordKit/SwordManager.swift`: module management and libsword-facing orchestration
- `Sources/BibleView/Sources/BibleView/`: WKWebView integration and bridge surface
- `AndBibleUITests/AndBibleUITests.swift`: XCUITest workflow coverage
- `scripts/check_repo_standards.py`: docblock and commit guardrails

### Shared Frontend
- `bibleview-js/src/main.ts`
- `bibleview-js/src/components/BibleView.vue`
- `bibleview-js/src/composables/`

### Product Reference
- Android reference repository: https://github.com/andbible/and-bible

## Common Development Patterns

### Environment and Persistence
```swift
@Environment(\\.modelContext) private var modelContext
@Environment(WindowManager.self) private var windowManager
```

### Reader-Sheet Routing
```swift
@State private var showSearch = false

.sheet(isPresented: $showSearch) {
    NavigationStack {
        SearchView(...)
    }
}
```

### UI Test Harness Gating
```swift
private let uiTestOpensSearchOnLaunch =
    ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_SEARCH")
```

Keep deterministic test behavior behind explicit `UITEST_*` gates only.

### libsword Usage
- Go through `SwordKit`
- Do not call flat C APIs directly from feature code

## Troubleshooting Common Issues

### Package / Build State Problems
```bash
xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .derivedData-local clean test
```

### UI Test Flakiness
- Prefer explicit accessibility identifiers and exported state labels over timing-based assertions
- Reuse existing in-memory `UITEST_*` harnesses instead of inventing ad hoc state mutation paths
- If a focused test appears stale, rerun with `clean test` and a fresh `-derivedDataPath`

### Search UI Regressions
- Direct-launch Search tests depend on:
  - a temporary SWORD root
  - a temporary Search index path
  - bundled modules being available in the harness
- If Search suddenly returns zero bundled hits, inspect the harness setup before changing assertions

### Google Drive
- Google Drive OAuth is intentionally build-config dependent
- See `docs/howto/google-drive-oauth-setup.md`
- `not configured` is expected in local/CI builds without real credentials

## Copilot Workflow Recommendations

1. Start with the narrowest relevant validation
2. Run repo guardrails after edits
3. Use targeted simulator tests for workflow changes
4. Only broaden to full shared-scheme `xcodebuild test` when shared harness or coordinator state changed
5. Keep documentation factual and repository-valid; avoid local-machine path assumptions in tracked docs
