# Test Architecture Migration Plan - Colocate Tests in Package Targets

Status: in progress (Phase 3 BibleUI package lane started)
Owner: TBD
Last updated: 2026-06-28

## Why (adversarial review summary)

The test suite's slowness and brittleness are structural, not per-test flakiness.

Root cause: ~38,000 lines of pure package-logic unit tests live inside the
app-target XCUITest bundle (`AndBibleTests/`), so every "unit" test pays the full
app-build + simulator-boot + app-install tax and cannot use the fast `swift test`
path. The sharding scripts, timing files, retry-upload steps, and 400+ `.xcresult`
rerun bundles are machinery built to cope with that root cause rather than remove it.

Evidence captured during review:

| Signal | Value | Source |
|---|---|---|
| "Unit" test funcs in the app target | 633 funcs / 3,593 asserts / ~38k LOC | `AndBibleTests/` |
| Of those, files importing the app module | 0 (all `@testable import` package modules) | grep |
| Test funcs in actual package test targets | 42 (fast lane nearly empty) | `Sources/*/Tests/` |
| UI tests | 68 funcs / 184 asserts (~2.7 asserts/test) | `AndBibleUITests/` |
| UI suite serial wall-clock | ~150 min, avg 145s/test, slowest 317s | `scripts/ui_test_timings.json` |
| App relaunches | 66 `app.launch()` ~ one cold launch per test | grep |
| Brittleness machinery | 102 polling loops, 463 `firstMatch`, sharding-by-timings, retry-upload | grep / `ios-ci.yml` |
| `.xcresult` rerun artifacts on disk | 434 (`rerun`/`fix`/`reliab`/`flak`/`retry`) | `.artifacts/` |
| Does CI ever run `swift test`? | No | `.github/workflows/ios-ci.yml` |

### Findings (most to least severe)
- **F1** Package-logic tests misfiled into the app-target bundle (root cause of "slow"). 26 of 27 `AndBibleTests/` files import only package modules. Genuinely app/source-aware tests are a small minority and live inside `+AppAndReader.swift` (80 funcs total): `AndBibleApplicationDelegate.sceneConfiguration` (line 2328) and `testContentViewDoesNotContainLegacyRootSidebarShell` (line 2361, reads `AndBible/ContentView.swift` from disk). The other ~78 funcs in that file are BibleUI logic.
- **F2** "God partial class": 633 tests on a single `AndBibleTests: XCTestCase` split across 27 `extension AndBibleTests` files (largest 4,168 lines), sharing setUp/tearDown state - ordering coupling, no per-file parallelism, merge-conflict magnet. Same pattern in `AndBibleUITests` (~11,700 lines of `...Support.swift` behind 68 tests).
- **F3** UI tests are full-app E2E doing unit/integration work (e.g. `testSettingsReadingProgressLinkOpensReadingProgressSettings` = 317s to assert one navigation). Launch+seed dominates wall-clock.
- **F4** Scattered layout: app-target bundle vs package targets vs host-side fixture tool, with no single "where does my test go" rule.
- **F5** CI is largely flake-mitigation scaffolding (dynamic shard planner, build-product reuse experiment, duplicated retry-upload steps, 90-min UI timeout, 8+ python tests about the harness itself).
- **F6** `CLAUDE.md` + `.github/copilot-instructions.md` steer contributors toward the slow app-target lane ("`swift test` is supplemental").

## Decision

Converge on **colocated package tests** (idiomatic SPM, biggest speed win).
Reserve app-target bundles for tests that genuinely need the running app.

Target structure:

```
Sources/
  SwordKit/Tests/SwordKitTests/        <- libsword wrapper logic
  BibleCore/Tests/BibleCoreTests/      <- models, services, sync, backup, downloads, bookmarks
  BibleView/Tests/BibleViewTests/      <- bridge payload / contract tests
  BibleUI/Tests/BibleUITests/          <- view-model / catalog / navigation logic (no live app)
AndBibleTests/                         <- ONLY app-host unit tests (AppDelegate/scene/bootstrap)
AndBibleUITests/                       <- ONLY true end-to-end journeys, trimmed to a small smoke set
```

## Destination mapping

**Classify by behavior under test, NOT by today's imports.** The current files
`@testable import` UI-heavy shared support (`AndBibleTestSupport`), so a sync or
backup test that exercises only BibleCore today still drags in BibleUI/UIKit. Mapping
by "highest module imported" would launder that pollution forward and defeat the speed
goal - a `RemoteSync*` test would land in the simulator-bound BibleUITests when its
behavior is pure BibleCore. Therefore destination is decided **after Phase 0 extracts
the shared helpers**, by asking "what module's behavior does this test actually
assert?" The dependency order (SwordKit < BibleCore < BibleView < BibleUI) only breaks
ties; it does not drive placement.

Concretely, after Phase 0 each file's `@testable import` set is re-minimized (drop UI
imports that came only from shared support), then placed at the lowest module that
still compiles it. Expect most `+RemoteSync*`, `+AndroidDatabaseBackup`, and bridge
payload tests to fall to **BibleCoreTests / BibleViewTests**, not BibleUITests. Under
the recommended option (b), those still run through app-host-free per-target simulator
schemes; macOS `swift test` is used only if Phase 0 proves option (a).

The table below is the **provisional** target; the import-reduction step in each phase
confirms or lowers each destination.

| Destination | Files (provisional) | Runs on | Notes |
|---|---|---|---|
| **SwordKitTests** | `DefaultDocumentDownloadPlannerTests`, `ModuleDownloadRowActionPlannerTests` | per-target simulator scheme baseline; optional macOS `swift test` only under option (a) | no UI frameworks |
| **BibleCoreTests** | `+AndroidModuleBackup`, `RemoteSyncMyDocumentRestoreTests`, `WorkspaceSyncRestoreTests`, plus most `+RemoteSync*` and `+AndroidDatabaseBackup` once UI imports are dropped | per-target simulator scheme baseline; optional macOS `swift test` only under option (a) | SwiftData host compatibility is still useful, but not required for the baseline migration |
| **BibleViewTests** | `+Bridge*` (bridge payload/contract behavior) once decoupled from UI support | per-target simulator scheme baseline; optional macOS `swift test` only under option (a) | reclassify per-file after Phase 0 |
| **BibleUITests** | genuinely BibleUI-behavior tests only: `+BookCatalog`, `+ReaderNavigation`, `+WindowPaneMenu`, `+WindowTabBarLayout`, `+SettingsIcons`, `+Strongs*`, `+PassageGrid`, `+ExternalDocumentImport`, view-model portions of `+AppAndReader`, `AndBibleTests.swift` (base) | iOS simulator via committed package test scheme (no app host) - see Phase 0 task | BibleUI pulls SwiftUI/UIKit/WebKit -> simulator-bound, but free of the app build/install |
| **stays in `AndBibleTests` (app host)** | `+AppAndReader` is **80 test funcs**, mostly BibleUI logic -> BibleUITests. App/source-aware ones that must NOT silently move: `AndBibleApplicationDelegate.sceneConfiguration` (line 2328, app host) and `testContentViewDoesNotContainLegacyRootSidebarShell` (line 2361, reads `AndBible/ContentView.swift` from disk) | app host or repo-standards | split the file deliberately; the ContentView source-scan test is a static guardrail and may instead become a `scripts/check_repo_standards.py` check rather than an app-hosted XCTest - decide explicitly, do not relocate it to BibleUITests |

## Phases (CI stays green after every phase - strangler approach: stand up new, prove parity, then delete old)

### Phase 0 - Shared test-support strategy (keystone; no test moves yet)
Blocker: `AndBibleTestSupport.swift` is a 2,233-line `extension AndBibleTests` every test calls via `self`.
- Create a **`BibleTestSupport`** helper library target for framework-agnostic fixtures needing no `@testable` access: `MockURLProtocol`, `FakeSpeechSynthesizer`, `Android*Row` structs, `webDAVMultiStatusXML`, dir-copy utils. Each package test target depends on it.
- Helpers needing `@testable` internals (`makeInMemorySettingsStore`/`ModelContainer`, SWORD-module seeding) become free functions / a base `XCTestCase` subclass **inside** the relevant test target (`BibleCoreTestCase`, `BibleUITestCase`).
- Replace the single `final class AndBibleTests` with a small per-target base carrying `temporarySwordModulePaths` teardown; moved files become `final class ...Tests: BibleUITestCase`.
- **Toolchain (do first - blocks all `swift`-driven work).** The machine's default toolchain is the Command Line Tools (`xcode-select -p` -> `/Library/Developer/CommandLineTools`), under which `swift build`/`swift test` fail. Run under the installed full Xcode (`/Applications/Xcode.app`, verified present):
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
  (or a one-time `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`).
- **Whole-package SwiftPM compile decision (do first - blocks the macOS `swift test` lane and determines the Phase 1 command).** `swift test` builds the **entire package graph for the macOS host** regardless of `--filter`; it does not build only the filtered target. Today that build **fails**: e.g. `BibleCore` declares `public final class Window` (`Sources/BibleCore/Sources/BibleCore/Models/Window.swift:13`) which collides with `SwiftUI.Window` (macOS 14+) where BibleUI imports SwiftUI, plus other macOS-host errors ("extra `for:` arguments"). Consequences:
  - The "fast macOS `swift test` lane" is **conditional**, not free. Either (a) make the whole package compile for the macOS host (disambiguate `Window`, platform-gate iOS-only code, fix the `for:` sites), or (b) drop macOS-host `swift test` and run every test target on the **iOS simulator via per-target xcodebuild schemes** - still app-host-free (the actual win), just not macOS-host-fast.
  - **Decision required here**: pick (a) or (b) before Phase 1. Recommended default is **(b) per-target simulator schemes** as the baseline mechanism, with macOS-host `swift test` pursued later as a stretch optimization for SwordKit/BibleCore only once the host compile is green. This makes the Phase 1 command a scoped `xcodebuild test -scheme SwordKitTests` (builds only SwordKit + CLibSword), not whole-graph `swift test`.
- **Package test schemes (do first - blocks Phase 3 and may block some option (b) targets).** `AndBible.xcscheme` is the only listed shared scheme, but Xcode 26 can synthesize project-integrated package test schemes from `Package.swift`: a clean worktree with a valid `libsword/libsword.xcframework` successfully ran `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project AndBible.xcodeproj -scheme SwordKitTests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/andbible-swordkit-pre-dd CODE_SIGNING_ALLOWED=NO -only-testing:SwordKitTests/SwordManagerTests/testModuleInfoCreation` and built only `CLibSword`, `SwordKit`, and `SwordKitTests`. Treat that command shape as the Phase 1 baseline. For later targets, if CI or Xcode stops resolving the synthesized package-test schemes, create and commit one shared scheme per test target (`SwordKitTests`, `BibleCoreTests`, `BibleViewTests`, `BibleUITests`). **Scheme location vs `.gitignore`:** Xcode writes shared package schemes to `.swiftpm/xcode/xcshareddata/xcschemes/`, but `.gitignore:29` ignores `.swiftpm/`. Add a precise un-ignore so the schemes are committable, e.g.:
  ```
  .swiftpm/*
  !.swiftpm/
  !.swiftpm/xcode/
  .swiftpm/xcode/*
  !.swiftpm/xcode/xcshareddata/
  .swiftpm/xcode/xcshareddata/*
  !.swiftpm/xcode/xcshareddata/xcschemes/
  !.swiftpm/xcode/xcshareddata/xcschemes/*.xcscheme
  ```
  (keep `xcuserdata` ignored). Confirm `git status` actually tracks the committed `.xcscheme` files before relying on explicit scheme files in CI. Verify each synthesized or explicit package-test scheme runs without the app host:
  `xcodebuild test -project AndBible.xcodeproj -scheme SwordKitTests -destination 'platform=iOS Simulator,name=iPhone 17'`.
- Gate: support compiles; the chosen run mechanism (a: whole-package `swift test` host build is green, or b: each package-test target builds and runs >=1 test on the simulator **without** building the app) is demonstrated; if explicit schemes were needed, `git status` shows the schemes tracked; nothing deleted.

### Phase 1 - Pilot SwordKit (smallest, fully reversible)
- Move `DefaultDocumentDownloadPlannerTests` and same-file `ModuleDownloadRowActionPlannerTests` -> `SwordKitTests`; both are already `final class ...: XCTestCase`.
- Run with the Phase 0 mechanism:
  - **Recommended option (b):**
    `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project AndBible.xcodeproj -scheme SwordKitTests -destination 'platform=iOS Simulator,name=iPhone 17'`
  - **Only if Phase 0 chose option (a) and whole-package macOS SwiftPM compile is green:**
    `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter SwordKitTests`
- Gate: chosen command succeeds; identical count/results; app target is not built for the package-test run; keep original until CI proves the new copy green, then delete original in same PR.

### Phase 2 - BibleCore logic tests
- Move the cleanest BibleCore-only files first, preserving app-host-free package execution after each slice.
  - `AndBibleTests+AndroidModuleBackup` has moved to `BibleCoreTests` as the first Phase 2 slice because it only needed local temporary-file cleanup after leaving `AndBibleTests`.
  - `RemoteSyncMyDocumentRestoreTests` has moved to `BibleCoreTests` as the second Phase 2 slice because it is already a standalone `XCTestCase`; its direct `CLibSword` import is now an explicit `BibleCoreTests` dependency.
  - `WorkspaceSyncRestoreTests` has moved to `BibleCoreTests` as the third Phase 2 slice after confirming its SQLite/gzip fixture ownership stays local to the package target.
- Add CI coverage using the chosen Phase 0 mechanism:
  - **Recommended option (b):** per-target simulator scheme job(s) for `SwordKitTests` and `BibleCoreTests`, with no app host.
  - **Optional option (a):** macOS `swift test` job only after the whole-package SwiftPM graph compiles under full Xcode.
- Gate: new package-test CI lane green; counts match; app build/install are not part of these package-test jobs; delete originals.

### Phase 3 - BibleUI bulk (largest; 3-4 sub-batch PRs by theme)
- **Per batch, first re-minimize imports** (drop UI imports inherited only from shared support) and re-confirm destination - many `+RemoteSync*` / `+Bridge*` tests should drop to BibleCoreTests/BibleViewTests and run in the package-test lane rather than BibleUITests. Under option (b), that still means per-target simulator schemes; under option (a), eligible targets may use macOS `swift test`.
- `AndBibleTests+BookCatalog` has moved to `BibleUITests` as the first Phase 3 slice because it exercises BibleUI reader catalog behavior without app bootstrap. Its direct `SwordKit` types are now an explicit `BibleUITests` dependency.
- CI now includes an app-host-free `ios-bibleui-package-tests` simulator job so moved BibleUI tests remain enforced outside the app-target bundle.
- `AndBibleTests+WindowPaneMenu` has been retired from the app-host bundle because equivalent Android-parity coverage already lives in `BibleWindowPaneMenuModelTests` under the `BibleUITests` package target.
- `AndBibleTests+WindowTabBarLayout` has moved to `BibleUITests` because it exercises pure BibleUI footer layout constants and Android-parity layout decisions without app bootstrap.
- `AndBibleTests+SettingsIcons` has moved to `BibleUITests` because it exercises BibleUI settings catalogs, text-display editor state, and reader chrome palette contracts without app bootstrap.
- `AndBibleTests+PassageGrid` has moved to `BibleUITests` because it exercises BibleUI passage chooser layout, palette, progress, and Android source guardrails without app bootstrap.
- `AndBibleTests+StrongsAndDictionary` has moved to `BibleUITests` because it exercises BibleUI Strong's, dictionary, search, and Android restored-MyBible dictionary contracts without app bootstrap.
- Batches for the genuinely BibleUI-behavior remainder: ReaderNavigation, Bookmarks/Strongs, Window/Settings, view-model parts of `+AppAndReader`.
- **Split `+AppAndReader` deliberately**: `sceneConfiguration` test stays app-hosted; `testContentViewDoesNotContainLegacyRootSidebarShell` becomes a repo-standards guardrail or stays app-hosted (decide explicitly - do not move to BibleUITests); the other ~78 funcs go to BibleUITests.
- Run BibleUITests via `xcodebuild test -scheme BibleUITests -destination 'platform=iOS Simulator,...'` against the **committed package test scheme from Phase 0** (no app host).
- Gate per batch: moved batch green in new target; equal count removed from app bundle; app build still green.

### Phase 4 - Retire scaffolding & lock structure
- Delete near-empty `AndBibleTests` extensions and `AndBibleTestSupport`; keep only app-host tests.
- Simplify CI: replace `ios-simulator-unit-tests` app-build path with app-host-free package-test lanes. Baseline is per-target simulator schemes; macOS `swift test` is an optimization only for targets proven to compile under SwiftPM. Reassess shard planner, timings file, build-product-reuse experiment.
- Trim `AndBibleUITests` to an explicit smoke set (target <=15 journeys); demote/convert the rest.
- Update `CLAUDE.md` + `.github/copilot-instructions.md`: replace "swift test is supplemental" with the actual placement rule - *new tests go in the lowest package test target that owns the behavior after imports are minimized; app-host only for true app-delegate/scene/bootstrap behavior.*

## Risks & mitigations
- **`@testable` re-export from shared lib** - can't re-expose internals; keep internal-touching helpers inside test targets (Phase 0).
- **Hidden inter-test state on shared `AndBibleTests` class** - per-class conversion may expose order-dependence; run each migrated file in isolation (`-only-testing`) early.
- **SwiftData/CLibSword on macOS host** - verify in Phase 2 that BibleCore links libsword on macOS; route any simulator-only slice to the simulator job rather than blocking the macOS lane.
- **Large diff churn** - batch by module/theme, parity-then-delete, never bulk-move in one PR.
- **Missing package test scheme / toolchain** - Phase 3 simulator runs and all `swift test` runs are blocked until the Phase 0 tasks (prove synthesized package-test schemes or commit explicit shared package test schemes; standardize `DEVELOPER_DIR` on full Xcode) are done and verified. CI's package-test lanes must use the same full-Xcode toolchain and must not rely on user-local Xcode state. A macOS `swift test` lane must additionally prove the whole package graph compiles under SwiftPM before it becomes required.
- **Classification by polluted imports** - placing files by today's `@testable import` set sends BibleCore-behavior tests into the simulator-bound BibleUITests and forfeits the speed win. Always re-minimize imports after Phase 0 and place at the lowest module that compiles.

## Success criteria
- ~38k lines of logic tests build against libraries, not the app. Baseline execution is app-host-free per-target package schemes; framework-agnostic targets may later run via macOS `swift test` once SwiftPM host compile is proven.
- `AndBibleTests` holds only app-host tests; `AndBibleUITests` is a small intentional smoke set.
- CI has fast app-host-free package-test lanes; the old app-host unit-test simulator job and much sharding machinery are retired. A macOS `swift test` lane is a stretch optimization, not a prerequisite for the migration's main win.
- One documented rule for test placement.
