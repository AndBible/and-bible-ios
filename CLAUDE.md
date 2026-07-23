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
- **Tests** (`Tests/AppHost/AndBibleTests/`, `Tests/UI/AndBibleUITests/`, package test targets): app-host, UI smoke, and package coverage

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

xcodebuild -project AndBible.xcodeproj -scheme AndBibleUnitTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

**Package Test Targets**

```bash
xcodebuild -project AndBible.xcodeproj -scheme SwordKitTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

xcodebuild -project AndBible.xcodeproj -scheme BibleCoreTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

xcodebuild -project AndBible.xcodeproj -scheme BibleViewTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

xcodebuild -project AndBible.xcodeproj -scheme BibleUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
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
- Package-owned tests run through the app-host-free package schemes (`SwordKitTests`, `BibleCoreTests`, `BibleViewTests`, `BibleUITests`)
- Whole-package `swift build` / `swift test` is currently a host-compile optimization only; it does not replace the package simulator schemes or app-target validation
- If you change `bibleview-js`, rebuild and atomically sync the production fallback with
  `scripts/manage_bibleview_bundle.py` before app validation; CI separately verifies and packages its
  build-owned Debug artifact
- Local secrets belong in `Config/Secrets.xcconfig.local`; do not commit real credentials

## Testing

**Run only tests relevant to the changes made.**

### Package-Owned Logic and UI Contracts

- Put new tests in the lowest package test target that owns the behavior after imports are minimized
- Prefer targeted package-scheme runs for package logic, reader/controller contracts, bridge DTOs, SwiftData services, and Android parity helpers
- Use `-only-testing:` whenever a focused subset is enough

Examples:

```bash
xcodebuild -project AndBible.xcodeproj -scheme BibleCoreTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:BibleCoreTests/TextDisplaySettingsTests

xcodebuild -project AndBible.xcodeproj -scheme BibleUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:BibleUITests/ReaderNavigationTests
```

### App Bootstrap and XCUITest Workflows

- Use `AndBibleUnitTests` / `AndBibleTests` only for behavior that genuinely requires the app host, app delegate, scene wiring, or installed app bundle
- Use `AndBibleUITests` only for true end-to-end workflows that require a launched app
- Keep physical app-host and UI smoke test files under `Tests/AppHost/AndBibleTests/` and `Tests/UI/AndBibleUITests/`; target and `-only-testing` identifiers remain `AndBibleTests/...` and `AndBibleUITests/...`
- Use `-only-testing:` whenever a focused subset is enough
- `AndBibleUnitTests` contains only the app-host unit-test bundle; `AndBible` includes the app and XCUITest workflow bundle

Examples:

```bash
xcodebuild -project AndBible.xcodeproj -scheme AndBibleUnitTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:AndBibleTests/AndBibleTests/testApplicationDelegateSceneConfigurationUsesWindowSceneDelegate

xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:AndBibleUITests/AndBibleUITests/testSearchOptionControlsMutateVisibleState
```

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
- `Tests/UI/AndBibleUITests/AndBibleUITests.swift`: XCUITest harnesses and workflow coverage
- `Tests/UI/Fixtures/`: UI smoke fixture and timing manifests consumed by XCUITest/CI
- `Tests/Support/UITestFixtureTool/`: host-side SwiftPM fixture executable used by UI tests
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
3. Run `npm run build-debug` for deterministic debug diagnostics
4. Build and atomically sync the production fallback as documented in
   `docs/howto/working-with-vuejs.md`
5. Re-run relevant app validation against the synchronized resource

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

### Sync Backends

- iOS sync supports iCloud and NextCloud/WebDAV only
- Google Drive is intentionally removed from the iOS sync surface
- Legacy `GOOGLE_DRIVE` backend values should fall back to iCloud

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

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **and-bible-ios** (46393 symbols, 332818 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Interpreting Impact Risk

GitNexus impact levels describe dependency reach and potential blast radius. They are inputs to engineering judgment, not permission levels. HIGH or CRITICAL does not mean "do not edit," does not by itself require user approval, and must not be used to justify a parallel implementation. A central shared symbol may be the correct and safest place for a root-cause fix.

When impact is HIGH or CRITICAL:

- Inspect the direct callers, affected execution flows, contracts, and relevant tests before editing.
- Briefly report the blast radius, why the selected symbol is or is not the correct owner, what behavior must remain unchanged, and how the change will be validated. Continue without waiting for approval unless a genuine escalation condition below applies.
- Make the smallest coherent change that fixes the root cause at the existing source of truth. "Smallest" means the narrowest architecturally complete solution, not the fewest lines, files, callers, or lowest GitNexus risk score.
- If the high-impact symbol owns the behavior, edit it carefully rather than bypassing it. Prefer one shared implementation over duplicated logic, shadow state, feature-specific forks, adapters, or parallel implementations that can drift.
- Preserve unrelated behavior and validate affected contracts proportionally to the blast radius.
- Cross-check GitNexus output against the actual source and tests. Treat stale, incomplete, or ambiguous graph results as supporting evidence, not authority.

Ask the user before proceeding only when analysis reveals that the change would:

- materially expand product scope beyond the request;
- require a breaking shared, bridge, sync, persistence, or public API change;
- require a data migration, irreversible operation, or external/platform coordination;
- depend on ambiguous intended behavior that cannot be resolved from the code, tests, documentation, or established parity baseline; or
- affect critical behavior that cannot be validated safely.

A HIGH or CRITICAL score alone is never an escalation condition.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER avoid the correct shared implementation solely because its impact score is HIGH or CRITICAL.
- NEVER create duplicated logic, parallel features, shadow state, or a drift-prone workaround merely to reduce the reported blast radius.
- NEVER modify every reported dependent automatically. Impact results identify what must be inspected and validated, not necessarily what must be edited.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/and-bible-ios/context` | Codebase overview, check index freshness |
| `gitnexus://repo/and-bible-ios/clusters` | All functional areas |
| `gitnexus://repo/and-bible-ios/processes` | All execution flows |
| `gitnexus://repo/and-bible-ios/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
