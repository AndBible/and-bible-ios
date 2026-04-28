# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AndBible iOS is the iPhone/iPad port of AndBible. It is an iOS app target with
Mac Catalyst enabled, built around a local Swift package plus a shared Vue.js
BibleView frontend running inside WKWebView.

This repository is no longer in an early scaffolding state:

- The app builds and runs through `AndBible.xcodeproj`
- Real `libsword` is consumed through `libsword/libsword.xcframework`, built locally and in CI via `libsword/build-ios.sh`
- The repo has active unit and XCUITest coverage
- Search, bookmarks, history, settings, sync, and reading-plan flows all have
  meaningful native SwiftUI implementation and test coverage

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
- **Cross-platform parity translation**: many services and UI contracts intentionally mirror the existing AndBible product behavior across platforms
- **Android compatibility is mandatory**: do not change shared data contracts, sync formats, bridge payloads, or frontend semantics in ways that would break Android parity unless the change is explicitly coordinated across platforms
- **Deterministic UI harnesses**: XCUITests use explicit `UITEST_*` launch arguments and in-memory stores. Test-only behavior must stay behind those gates

### Native ↔ WebView Communication

- Swift → WebView: `evaluateJavaScript(...)` through bridge/coordinator layers in `BibleView`
- WebView → Swift: `WKScriptMessageHandler`-driven bridge types and delegates
- Data contracts should stay aligned with the shared Vue.js surface and existing product bridge payloads

## Android Compatibility

- Never break Android compatibility as a side effect of iOS work. Android behavior remains the parity baseline for shared workflows, persisted formats, localization keys, and bridge contracts unless the repo explicitly documents an intended divergence.
- When changing shared contracts, check both the native iOS implementation and the shared/frontend surface before treating the change as complete.
- If you need a local Android reference checkout, clone `https://github.com/andbible/and-bible` into `.and-bible-android/` at the repo root. That directory is gitignored and should be used only as a local parity reference.
- Do not commit machine-specific sibling-path assumptions such as `../and-bible/`.

## Build System

### Prerequisites

- Xcode 17 or newer with an iOS 17 simulator available
- Node.js 20+ and npm for `bibleview-js`
- `libsword/libsword.xcframework`, built with `libsword/build-ios.sh` when missing

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
  test -only-testing:AndBibleTests/AndBibleTests/testStrongsQueryNormalizationHandlesLeadingZeroes

xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:AndBibleUITests/AndBibleUITests/testSearchDirectLaunchUsesSeededIndexAndReturnsBundledResults
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

- Prefer targeted simulator validation over full-suite runs unless shared harness or coordinator state changed
- Keep `CLAUDE.md` factual and current; do not leave milestone-style status sections that become stale after major repository changes
