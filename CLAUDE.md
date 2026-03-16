# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AndBible iOS is the iPhone/iPad port of AndBible. It is an iOS app target with
Mac Catalyst enabled, built around a local Swift package plus a shared Vue.js
BibleView frontend running inside WKWebView.

This repository is no longer in an early scaffolding state:

- The app builds and runs through `AndBible.xcodeproj`
- Real `libsword` is provided through `libsword/libsword.xcframework`
- The repo has active unit and XCUITest coverage
- Search, bookmarks, history, settings, sync, and reading-plan flows all have
  meaningful native SwiftUI implementation and test coverage

The original Android reference codebase is at `../and-bible/`.

## Architecture

### Core Components

- **iOS App Target** (`AndBible/`): app entry point, app resources, and target-level configuration
- **SwordKit** (`Sources/SwordKit/`): Swift wrapper around libsword's flat C API
- **BibleCore** (`Sources/BibleCore/`): SwiftData models, services, sync, persistence, business logic
- **BibleView** (`Sources/BibleView/`): WKWebView bridge and bundled Vue.js frontend resources
- **BibleUI** (`Sources/BibleUI/`): native SwiftUI feature screens and reader coordinator
- **Tests** (`AndBibleTests/`, `AndBibleUITests/`, package test targets): unit and UI coverage

### Key Patterns

- **Reader-coordinator design**: `BibleReaderView` owns top-level sheet routing and delegates reading behavior to focused controllers managed by `WindowManager`
- **Hybrid native/web rendering**: Bible document content is still rendered in WKWebView, while navigation, settings, bookmarks, sync, and supporting workflows are native SwiftUI
- **SwiftData persistence**: workspaces, windows, bookmarks, labels, reading plans, and related state live in SwiftData-backed models and services inside `BibleCore`
- **Android-parity translation**: many services and UI contracts intentionally mirror Android behavior; the Android repo should be treated as the primary parity reference
- **Deterministic UI harnesses**: XCUITests use explicit `UITEST_*` launch arguments and in-memory stores. Test-only behavior must stay behind those gates

### Native ↔ WebView Communication

- Swift → WebView: `evaluateJavaScript(...)` through bridge/coordinator layers in `BibleView`
- WebView → Swift: `WKScriptMessageHandler`-driven bridge types and delegates
- Data contracts should stay aligned with the shared Vue.js surface and, where relevant, with Android bridge payloads

## Build System

### Prerequisites

- Xcode 17 or newer with an iOS 17 simulator available
- Node.js 20+ and npm for `bibleview-js`
- The checked-in `libsword/libsword.xcframework`

### Canonical Build Entry Points

**Xcode Project**

```bash
open AndBible.xcodeproj
```

**App Build / Test**

```bash
xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

**Package-Level Validation**

```bash
swift build
swift test
```

**Vue.js Frontend**

```bash
cd bibleview-js
npm install            # initial setup
npm run test:ci
npm run lint
npm run type-check
npm run build-debug
```

### Important Build Notes

- The checked-in `AndBible.xcodeproj` and shared `AndBible.xcscheme` are the authoritative app build configuration
- `project.yml` exists, but it can lag behind manual Xcode project changes. Validate against the real project and scheme, not just the YAML
- `swift build` is useful for package compilation, but it does not replace `xcodebuild` for app-target behavior, scheme wiring, or XCUITest validation
- If you change `bibleview-js`, rebuild the frontend bundle before app validation
- Local secrets belong in `Config/Secrets.xcconfig.local`; do not commit real credentials

## Testing

**Run only tests relevant to the changes made.**

### App / SwiftUI / Integration Changes

- Prefer targeted `xcodebuild test` runs against `AndBibleTests` and `AndBibleUITests`
- Use `-only-testing:` whenever a focused subset is enough
- The shared `AndBible` scheme includes both unit and UI test bundles

Examples:

```bash
xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:AndBibleTests/AndBibleTests/testExample

xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:AndBibleUITests/AndBibleUITests/testExample
```

### Package-Only Logic Changes

- `swift test` is useful for package targets, but still use `xcodebuild` if the change touches app wiring, SwiftUI behavior, environment injection, or UI harnesses

### Vue.js Changes

- Run:
```bash
cd bibleview-js
npm run test:ci
npm run lint
npm run type-check
```

### Standards / Guardrails

- Always run:
```bash
git diff --check
python3 scripts/check_repo_standards.py docblocks --all-files
```
- The repository enforces Swift docblock style and commit-message structure in CI

## Key Files

### Core Application

- `AndBible/AndBibleApp.swift`: app bootstrap, environment setup, test-harness launch behavior
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift`: main reader coordinator and top-level sheet routing
- `Sources/BibleUI/Sources/BibleUI/Search/SearchView.swift`: full-text Search UI and indexed-search workflow
- `Sources/BibleUI/Sources/BibleUI/Bookmarks/BookmarkListView.swift`: bookmark browsing, filtering, sorting, and label actions
- `Sources/BibleUI/Sources/BibleUI/Shared/HistoryView.swift`: navigation history workflows
- `Sources/BibleCore/Sources/BibleCore/Services/WindowManager.swift`: workspace/window coordination
- `Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncSynchronizationService.swift`: sync coordination
- `Sources/SwordKit/Sources/SwordKit/SwordManager.swift`: module management and libsword-facing orchestration
- `Sources/BibleView/Sources/BibleView/BibleWebView.swift`: WKWebView integration surface
- `AndBibleUITests/AndBibleUITests.swift`: XCUITest harnesses and workflow coverage
- `scripts/check_repo_standards.py`: docblock and commit-message guardrails

### Vue.js Frontend

- `bibleview-js/src/main.ts`: frontend bootstrap
- `bibleview-js/src/components/BibleView.vue`: root BibleView component
- `bibleview-js/src/composables/`: shared frontend logic

### Android Reference

- `../and-bible/app/src/main/java/`: native Android parity reference
- `../and-bible/app/bibleview-js/src/`: Android/shared frontend reference

## Code Patterns

### Persistence and Environment

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

### Test Harness Gating

```swift
private let uiTestOpensSearchOnLaunch =
    ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_SEARCH")
```

Use explicit `UITEST_*` gates for deterministic automation helpers. Do not let
test-only behavior leak into normal runtime paths.

### libsword Usage

- App code should go through `SwordKit`
- Do not call the flat C API directly from feature code

### Bridge Changes

- When changing bridge contracts, verify both:
  - iOS bridge/coordinator code in `BibleView`
  - shared frontend code in `bibleview-js`
- If the change is Android-parity-sensitive, compare against `../and-bible/`

## Persistence Structure

SwiftData-backed state lives primarily in `BibleCore` and includes:
- Workspaces, windows, page managers, and history
- Bookmarks, labels, StudyPads, and note-bearing bookmarks
- Reading plans and status tracking
- Sync metadata, initial-backup fidelity stores, patch state, and remote settings

Keep persistence logic in services/stores inside `BibleCore`; avoid pushing
storage concerns into SwiftUI views.

## Common Development Tasks

### Making Swift / SwiftUI Changes

1. Edit app or package sources
2. Run targeted `xcodebuild test` coverage for the changed workflow
3. Run guardrails:
   - `git diff --check`
   - `python3 scripts/check_repo_standards.py docblocks --all-files`

### Making Vue.js Changes

1. Edit `bibleview-js/src/`
2. Run:
   - `npm run test:ci`
   - `npm run lint`
   - `npm run type-check`
3. Rebuild the bundle with `npm run build-debug`
4. Re-run relevant app validation

### Rebuilding libsword

Only do this when the binary or native integration actually changes:
```bash
cd libsword
./build-ios.sh
```

## Troubleshooting

### Xcode / Package Resolution

- First-time package resolution can be slow
- If the project gets into a bad state, prefer a clean `xcodebuild` run with a dedicated `-derivedDataPath`

### UI Test Flakiness

- Prefer explicit accessibility identifiers and exported state labels over timing-based assertions
- Reuse the existing in-memory `UITEST_*` harness patterns instead of inventing ad hoc global state
- If a focused test appears to run stale code, use `clean test` with a fresh derived-data path

### Search UI Regressions

- UI Search tests depend on the test harness restoring bundled modules and using a temporary index path
- If Search suddenly returns zero bundled hits, inspect the temporary SWORD root and Search index setup before changing the UI test itself

### Google Drive

- Google Drive OAuth is intentionally build-config dependent
- See `docs/howto/google-drive-oauth-setup.md`
- `not configured` is expected in local or CI builds without real credentials

## Git Conventions

- When fixing a GitHub issue, start the commit message with `Fixes #NNN (short bug description)` so GitHub auto-closes the issue. Additional details go on subsequent lines. Example:

```
Fixes #3626 (popup menu search returning 0 results)

SearchResults now falls back to SEARCH_DOCUMENT when
SELECTED_TRANSLATIONS is not provided.
```

- Commit subject format:

```text
<type>(<scope>): <summary>
```

- Commit bodies must use these sections:

```text
Why:
What Changed:
Validation:
Impact:
```

## Notes

- The Android repo at `../and-bible/` remains the main parity reference
- Prefer targeted simulator validation over full-suite runs unless shared harness or coordinator state changed
- Keep `CLAUDE.md` factual and current; do not leave milestone-style status sections that become stale after major repository changes
