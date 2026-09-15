# Test architecture: behavioral contracts, execution, and feedback cost

Status: in progress; contract replacement, integrated execution, and cost acceptance remain open
Owner: TBD
Last updated: 2026-09-14

## Why (adversarial review summary)

The original migration found substantial package-owned coverage in app-hosted
targets. That placement was a structural source of cost, but the historical
counts and timings below do not establish the dominant cost of the current
suite. Current execution and runner-cost measurements remain required before
changing shard counts, timeouts, or build reuse.

The original placement problem has largely been addressed. Moving tests does not establish that
an assertion measures the intended behavior, that its observer is valid, or that CI executes it.
Current work replaces implementation-shaped expectations, verifies real rendering and persistence,
and measures compilation, fixtures, test bodies, and teardown separately. Dependency reach determines
validation coverage; it is not a reason to preserve an obsolete implementation or cap the work.

Historical evidence captured during the original review:

| Signal | Value | Source |
|---|---|---|
| "Unit" test funcs in the app target | 633 funcs / 3,593 asserts / ~38k LOC | `AndBibleTests/` |
| Of those, files importing the app module | 0 (all `@testable import` package modules) | grep |
| Test funcs in actual package test targets | 42 (fast lane nearly empty) | `Sources/*/Tests/` |
| UI tests | 68 funcs / 184 asserts (~2.7 asserts/test) | `AndBibleUITests/` |
| UI suite serial wall-clock estimate | ~150 min, avg 145s/test, slowest 317s/test | Historical measurements now recorded with provenance in `Tests/UI/Fixtures/ui_test_timings.json` |
| App relaunches | 66 `app.launch()` ~ one cold launch per test | grep |
| Brittleness machinery | 102 polling loops, 463 `firstMatch`, sharding-by-timings, retry-upload | grep / `ios-ci.yml` |
| `.xcresult` rerun artifacts on disk | 434 (`rerun`/`fix`/`reliab`/`flak`/`retry`) | `.artifacts/` |
| Does CI ever run `swift test`? | No | `.github/workflows/ios-ci.yml` |

### Historical findings and their current interpretation
- **F1** Package-logic tests were historically misfiled into the app-target bundle. The package-owned slices have moved to their lowest practical owners, and the source guard moved to repo standards. `AndBibleTests+AppAndReader.swift` now contains only `AndBibleApplicationDelegate.sceneConfiguration`, the genuine app-target scene bootstrap contract.
- **F2** "God partial class": 633 tests on a single `AndBibleTests: XCTestCase` split across 27 `extension AndBibleTests` files (largest 4,168 lines), sharing setUp/tearDown state - ordering coupling, no per-file parallelism, merge-conflict magnet. Same pattern in `AndBibleUITests` (~11,700 lines of `...Support.swift` behind 68 tests).
- **F3** Some UI cases mixed package contracts with live navigation. The historical 317-second Settings case did not isolate setup from body and teardown, so it cannot establish launch/seed dominance. Recent execution has separately exposed product layout stalls, expensive accessibility observation, and a teardown crash-report wait.
- **F4** Scattered layout: app-target bundle vs package targets vs host-side fixture tool, with no single "where does my test go" rule.
- **F5** CI carried substantial flake-mitigation scaffolding (dynamic shard planning, duplicated retry-upload steps, a 90-minute UI timeout, and process-shape guardrails). Product reuse was previously optional even though separate-runner execution had succeeded.
- **F6** `CLAUDE.md` + `.github/copilot-instructions.md` steer contributors toward the slow app-target lane ("`swift test` is supplemental").

## Decision

Place each contract at its lowest executable owning boundary. Package colocation avoids app-host work where it is unnecessary; its cost benefit must be measured. Use a real app, framework host, or WebKit/Vue integration whenever the claimed behavior requires that boundary. Do not add production abstractions solely to relocate a test.

Target structure:

```
Sources/
  SwordKit/Tests/SwordKitTests/        <- libsword wrapper logic
  BibleCore/Tests/BibleCoreTests/      <- models, services, sync, backup, downloads, bookmarks
  BibleView/Tests/BibleViewTests/      <- bridge payload / contract tests
  BibleUI/Tests/BibleUITests/          <- view-model / catalog / navigation logic (no live app)
Tests/
  AppHost/AndBibleTests/               <- AndBibleTests target; ONLY app-host unit tests (AppDelegate/scene/bootstrap)
  UI/AndBibleUITests/                  <- AndBibleUITests target; visible interaction and rendering contracts requiring the app
  UI/Fixtures/                         <- UI fixture manifest and timing manifest consumed by XCUITest/CI
  Support/UITestFixtureTool/           <- host-side SwiftPM fixture executable for UI tests
```

Historical tracked-source snapshot captured on 2026-09-13 (not current discovery):

| Lane | Current state |
|---|---|
| App-host unit tests | 1 candidate `test…` declaration: the genuine scene-configuration bootstrap contract. CI selects the full target and reconciles its reported identity. |
| Package tests | 2,317 candidate `test…` declarations across SwordKit, BibleCore, BibleView, and BibleUI package lanes in that working tree snapshot. Declaration counts are an inventory aid, not discovered/executed totals. |
| UI tests | 31 candidate `test…` declarations: 29 product journeys and 2 observation-only harness helpers. Each CI shard uses direct selected `xcodebuild` execution plus per-test fixture seeding. No arbitrary journey-count target establishes correctness. |

CI now reconciles three identities for selected app-host and UI runs: source
discovery where target-wide selection needs expansion, the exact
`-only-testing` request, and the structured `xcresulttool get test-results`
report. A green summary or positive test count is insufficient when a requested
identity is absent, unexpected, or skipped. This runner evidence is the basis
for execution coverage; source declaration counts alone do not prove discovery.

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
| **stays in `AndBibleTests` (app host)** | `AndBibleApplicationDelegate.sceneConfiguration` | app host | The target now contains only the scene/bootstrap behavior that requires the application module. |

## Migration history and remaining execution work

Phases 0–3 below record the earlier target migration and its command decisions. Their counts and proposed sequencing are historical, not proof of current behavioral coverage. Preserve a useful assertion until its replacement boundary is verified; failed product behavior remains a failure even when a migration compiles.

### Phase 0 - Shared test-support strategy (keystone; no test moves yet)
Blocker: `AndBibleTestSupport.swift` is a 2,233-line `extension AndBibleTests` every test calls via `self`.
- Create a **`BibleTestSupport`** helper library target for framework-agnostic fixtures needing no `@testable` access: `MockURLProtocol`, `FakeSpeechSynthesizer`, `Android*Row` structs, `webDAVMultiStatusXML`, dir-copy utils. Each package test target depends on it.
- Helpers needing `@testable` internals (`makeInMemorySettingsStore`/`ModelContainer`, SWORD-module seeding) become free functions / a base `XCTestCase` subclass **inside** the relevant test target (`BibleCoreTestCase`, `BibleUITestCase`).
- Replace the single `final class AndBibleTests` with a small per-target base carrying `temporarySwordModulePaths` teardown; moved files become `final class ...Tests: BibleUITestCase`.
- **Toolchain.** Select a fully configured Xcode through an explicit `DEVELOPER_DIR` for each build and test command. Check its setup status before building; do not assume the machine's default selection or installation remains unchanged. Record Xcode, Swift, and simulator SDK version/build before and after producing test artifacts. Paired performance comparisons require matching compiler, SDK, configuration, and source-bound products; an installation change requires a new matched pair. Keep machine-specific installation paths and setup status in local workspace records.
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
  - `AndBibleTests+AndroidDatabaseBackup` has been split by owning module: Android `.abdb.zip` archive, restore/import/export, version-gate, and preserved-database contracts moved to `BibleCoreTests`, while the reset-success presentation copy assertion moved to `BibleUITests`.
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
- `AndBibleTests+BridgeIOS` has been split by owning module: WebKit/UIKit bridge lifecycle and emission contracts moved to `BibleViewTests`, while BibleUI reader modal-key routing remains in `BibleUITests`.
- `AndBibleTests+BridgeAndProgress` has been split by owning module: raw bridge dispatch moved to `BibleViewTests`, speech/progress stores moved to `BibleCoreTests`, and reader memorization/reading-progress bridge integration moved to `BibleUITests`.
- `AndBibleTests+RemoteSyncAdapters` and `AndBibleTests+RemoteSyncTransport` have moved to `BibleCoreTests` because they exercise WebDAV/Nextcloud transport request construction, multistatus parsing, and sync-folder marker behavior without UI or app bootstrap.
- `AndBibleTests+RemoteSyncReadingPlans` has moved to `BibleCoreTests` because it exercises Android-compatible reading-plan status storage, snapshot restore, patch replay, and initial backup upload through BibleCore services without UI or app bootstrap.
- `AndBibleTests+RemoteSyncState` has moved to `BibleCoreTests` because it exercises iCloud startup recovery, Android-compatible sync settings/state keys, WebDAV configuration, bootstrap coordination, patch discovery, and archive staging through BibleCore services without UI or app bootstrap.
- `AndBibleTests+RemoteSyncLifecycle` has moved to `BibleCoreTests` because it exercises category synchronization lifecycle, WebDAV adapter factory selection, reading-plan patch orchestration, and background-refresh coordination through BibleCore services without UI or app bootstrap.
- `AndBibleTests+RemoteSyncBookmarks` has moved to `BibleCoreTests` because it exercises Android-compatible bookmark snapshot restore, sparse patch replay/upload, initial backup handling, and bookmark category synchronization through BibleCore services without UI or app bootstrap.
- `AndBibleTests+ExternalDocumentImport` has been split by owning module: document import routing, Android toast feedback, provider filename normalization, and installer selection moved to `BibleUITests`, while Android-style TTF font repository filesystem contracts moved to `SwordKitTests`.
- `AndBibleTests+WorkspaceAndRepository` has been split by owning module: workspace settings/store/window-manager/selection, bookmark-label filtering, and global text-display propagation moved to `BibleCoreTests`; the UI-owned workspace text-options dirty-field propagation helper moved to `BibleUITests`; repository-source-manager manifest, sidecar, default-source, and reset contracts moved to `SwordKitTests`.
- `AndBibleTests+Downloads` has been split by owning module: Downloads browser presentation, Android filter/default-language, auto-refresh, cancellation, and localized error-copy contracts moved to `BibleUITests`; queued search-index deletion and MyBible reader payload readability moved to `BibleCoreTests`; SWORD/MyBible repository refresh, install layout, rollback, package fallback, ZIP import, and cancellation contracts moved to `SwordKitTests`. The duplicated restored-MyBible `SwordManager.installedModules()` cases were not re-migrated because equivalent package coverage already lives in `SwordManagerTests`.
- `AndBibleTests+Bookmarks` has been split by owning module: BookmarkService note/label/paragraph-break/StudyPad persistence contracts moved to `BibleCoreTests`, while bookmark-list reference formatting, reader bookmark/note/StudyPad bridge payloads, label-assignment routing, and reader accessibility snapshots moved to `BibleUITests`. JSword range parity still uses the shared bundled-SWORD fixture from app resources; moving that fixture into package test resources remains a follow-up cleanup, not a reason to keep these tests in the app-host bundle.
- `AndBibleTests+AppAndReader` boundary work has started: iPadOS windowing-control policy tests moved to `BibleUITests`, `BibleWebView` platform bootstrap tests moved to `BibleViewTests`, CI now runs the `BibleViewTests` package scheme, and `testContentViewDoesNotContainLegacyRootSidebarShell` became a repo-standards `source-guards` check. `testApplicationDelegateSceneConfigurationUsesWindowSceneDelegate` remains app-hosted because it validates app delegate scene wiring.
- `AndBibleTests+AppAndReader` settings slice has been split by owning module: application preference registry/default/normalization/reset contracts moved to `BibleCoreTests`, while settings-search matcher presentation contracts moved to `BibleUITests`.
- `AndBibleTests+AppAndReader` text-display slice has been split by owning module: app-default, inheritance, full-resolution, and dirty-override cleanup contracts moved to a dedicated `BibleCoreTests` suite, while Strong's legacy-mode bridge normalization moved to `BibleUITests`.
- `AndBibleTests+AppAndReader` SWORD coordinator slice has moved to `BibleUITests` because it exercises BibleUI reader SWORD setup, installed-module categorization, active-module fallback, book-list derivation, and display-option application without app delegate/bootstrap behavior.
- `AndBibleTests+AppAndReader` module-switch planner slice has moved to `BibleUITests` because it exercises BibleUI current-document switch planning, Android category mismatch rejection, atomic auxiliary-document persistence, module-only selection, and category reload decisions without SWORD fixtures or app bootstrap.
- `AndBibleTests+AppAndReader` reader chrome slice has moved to `BibleUITests` because it exercises BibleUI header, toolbar action, popup placement, overflow menu, Downloads routing, and keyboard shortcut construction without app delegate/bootstrap behavior.
- `AndBibleTests+AppAndReader` module-browser slice has been split by owning module: Downloads filtering/sorting, failed-source cache merge, and startup-default installable-row guards moved to `BibleUITests`; Android metadata token decoding and catalog `InstallSize` byte preservation moved to `SwordKitTests`; the duplicate recommended-document refresh failure test was removed from the app-host bundle because equivalent SwordKit package coverage already exists in `SwordManagerTests`.
- `AndBibleTests+AppAndReader` module-picker slice has moved to `BibleUITests` because it exercises BibleUI `ChooseDocument` filtering, pseudo-document/add-on rows, document-management actions, category mapping, map routing, and Android full-screen chooser presentation without app delegate/bootstrap behavior.
- `AndBibleTests+AppAndReader` quick-selector/document-switch behavior slice has moved to `BibleUITests`: pure quick-selector sorting/labeling/action contracts live in `BibleReaderQuickModuleSelectorTests`, and controller-level current-document switch side effects that need SWORD fixtures live in `BibleReaderDocumentSwitchControllerTests`.
- `AndBibleTests+AppAndReader` reader source-guard slice has moved to `BibleUITests`: quick-selector toolbar source guards and the active-window native-border guard live in `ReaderSourceGuardTests`, with function-boundary extraction shared through `BibleUITestSourceLocator`.
- `AndBibleTests+AppAndReader` reader shell construction slice has moved to `BibleUITests` because the speak mini-player, navigation drawer, and side-drawer overlay are package-owned BibleUI views with injected dependencies.
- `AndBibleTests+AppAndReader` passage chooser source/progress slice has moved to `BibleUITests` because those guards inspect BibleUI reader presentation source for Android full-screen chooser parity, workspace titles, native toolbar avoidance, and captured progress snapshots.
- `AndBibleTests+AppAndReader` color helper slice has moved to `BibleUITests` because the signed ARGB conversion helpers live with BibleUI color settings and do not require app bootstrap.
- The final `+AppAndReader` remainder was split by contract: memorization store and Android progress database cases moved to `BibleCoreTests`; reader presentation, WebView surface, document replacement/configuration, and memorization bridge cases moved to `BibleUITests`. Those tests reuse the package settings, SWORD fixture, bridge recorder, and payload parser. The broad Memorization view source-string inventory was retired: its data/percentage contract is asserted through `MemorizationProgressPresentation`, and opening an out-of-book range is asserted through the real reader-controller route. View styling remains a visible UI concern rather than a source-shape gate. Only the scene-configuration sentinel remains app-hosted.
- **Split `+AppAndReader` deliberately**: `sceneConfiguration` test stays app-hosted; the `ContentView` legacy root-sidebar source scan is now a repo-standards `source-guards` check; any future package-owned tests should move to the lowest owning package target instead of returning to the app-host bundle.
- `AndBibleTests+ReaderNavigation` bridge/payload slice has moved to `BibleUITests` because compare payloads, reader document JSON factories, auxiliary fallback documents, and rendered-content tokens are BibleUI reader/bridge contracts that do not require app bootstrap.
- `AndBibleTests+ReaderNavigation` reader interaction-policy slice has moved to `BibleUITests` because double-tap fullscreen gating, horizontal swipe mapping, and auto-fullscreen threshold logic are BibleUI policy/controller contracts with injected settings, not app bootstrap behavior.
- The rest of `AndBibleTests+ReaderNavigation` has moved to `BibleUITests` as a larger final ReaderNavigation package slice because bridge response contracts, download/Strong's/multi-reference routing, Android `Multi` document identity, reader selection, content loading, reader config/coordinators, infinite scroll, MyDocument bridge operations, synchronized scrolling, and navigation coordinator behavior are BibleUI/BibleView package contracts with injected fixtures, not app bootstrap behavior.
- Run BibleUITests via `xcodebuild test -scheme BibleUITests -destination 'platform=iOS Simulator,...'` against the **committed package test scheme from Phase 0** (no app host).
- Gate per batch: moved batch green in new target; equal count removed from app bundle; app build still green.

### Phase 4 — Complete the behavioral and execution migration

The app-host target now owns only the scene-configuration contract. Package lanes own source,
controller, store, archive, and policy contracts. The UI suite owns the visible interactions that
those lower boundaries cannot establish. A route catalog is not proof that a user can reach its
screen; a recorded bridge command is not proof that Vue rendered it; a persisted setting is not
proof of displayed color. Name tests and report results at the boundary they actually exercise.

Current work and acceptance:

- Search's ordinary text journey types and submits through the production form, observes a real
  result row, and selects it once. The launch-driven Search hook and hidden grouped-row token are
  removed. Reference-range and Strong's submission journeys have passed after separating submission
  from outcome observation; their production-wiring source guard is removed. Package tests retain
  malformed query, grouping, index readiness, lexical, exact-source, and versification contracts.
  These results belong to their recorded products; final integrated execution remains required.
- History and My Notes have dedicated journeys. Bookmarks retains label filtering, StudyPad handoff,
  label assignment, and row navigation in its own flow. A separate populated-list case requires
  visible notes, usable viewport geometry, and a reachable Back action. Both complete Bookmark
  assignment, child-Back, dismissal, and reopen journeys now pass on iOS17/26. The earlier stalled
  runs remain in the execution record; unrelated Downloads interaction failures remain open.
- Scoped SwiftData source observation replaces an unreliable notification dependency for bookmark
  row content. The retained layout, rendering, row-observation, and source-invalidation contracts
  pass on iOS17/26. Relationship-prefetch work still requires matched validation of independent
  note/link changes and saves from another context while the list remains mounted.
- Settings UI exercises the actual AI setup/disclaimer and Global Text Options routes. Package
  tests own the full row catalog. The latest native policy/draft/reset selection passes on both
  runtimes, but its visible replacement journeys are not accepted. They exposed a durable color
  save followed by a stale displayed workspace value, an incorrect font-list accessibility query,
  and a parent-link query that omitted scrolling. Unresolved iOS17 interaction and XCTest logging
  quarantine failures remain recorded. Correct those boundaries before retiring the corresponding
  source guards; lower test duration alone cannot establish product performance.
- Real WebKit/Vue tests complement native payload tests. Visible reader text uses screenshot
  recognition where WebKit's editable element does not expose its child text to accessibility.
  That observer currently covers English, single-pane fixtures; it does not establish screen-reader
  semantics, other locales, or chrome colors. Observation must not perform an extra interaction.
- The issue-402 parity-orchestrator checker no longer treats three reader service type names or
  the placement of `BibleReaderInstalledModuleResolver` construction and `resolveDocumentOwner`
  calls in `BibleReaderController` as behavior contracts. Moving those tokens behind forwarding
  methods would not change ownership. Exact installed/local owner precedence, locked and replacement
  rejection, category-safe restore dispatch, bookmark commit preflight, source-generation capture,
  and publication reauthorization remain protected by executable native tests. Repository guards for
  Search transaction ownership, Sword registry/backend ownership, and Strong's backend boundaries
  remain enforced.
- Remove source substrings, private-helper inventories, and exact branch/event counts when they
  preserve implementation rather than an explicit structural requirement. Existing Search and
  delayed-reader-routing source guards remain open work. Derive expected behavior from pinned
  Android sources or independent vectors, and exercise cancellation, replacement, rejection, and
  ready-time replay through the actual owner. Do not rewrite expectations merely to turn a failure
  green.

Fixture and execution ownership:

- Persistence tests use the actual app model partitions and disk stores when they claim durable
  commit, failure recovery, or cross-context visibility. Keep the stores alive for the container's
  lifetime and verify committed outcomes through a fresh context. A cached object or an in-memory
  fixture does not prove a disk outcome. Cross-context restore tests must exercise the actual
  replacement contract, including already registered rows and active selection when relevant.
- Query UI controls by their observed accessibility role and identifier. Reuse explicit queries
  within a journey, reveal offscreen controls before one action, and retain the visible outcome
  assertions. Do not extend a name-based role heuristic, scan every element type, or repeat actions
  until a test passes. Existing heuristic helpers remain migration work, not the target pattern.
  Diagnose missing elements with retained screenshots, hierarchy, and exact process logs before
  changing the product or its accessibility identifiers.
- Test observers record production outputs without introducing new production obligations.
  A synchronous bridge recorder must not manufacture native reentrancy during a message that
  WebKit only queues. Exercise real selection/persistence and navigation callbacks when validating
  reentrancy, and retain source-generation checks for actual concurrent source changes. Emitted
  JavaScript, accepted queueing, and rendered content are distinct outcomes.
- `run_xcodebuild_with_test_selection.py` owns a private macOS fixture service for one invocation.
  It resolves and validates `UITargetAppPath` from the selected xctestrun and installs that exact
  simulator app before fixture preparation. The service confirms the prior process stopped,
  resolves its authoritative data container, and runs one reset/seed operation. XCTest then launches
  normally. No discovery launch, guessed container, simulator-side host subprocess, or shared
  mutable fixture substitutes for that boundary.
- Normal UI teardown uses `XCUIApplication.terminate()`. The fixture service independently verifies
  termination before later mutation. Process-group cancellation and cleanup remain covered by
  behavioral host tests. The removed stop-request path caused an approximately twenty-second
  unexpected-termination report wait in earlier UI runs.
- Two observation-only XCUI helper cases remain with their real harness dependencies. A separate
  support target is justified only by measured cost and an equally faithful boundary. Detailed
  exports no longer change autofocus or pane-button fading, but their computation and observation
  cost still require validation; an opt-in flag is not proof that diagnostics are cheap.
- Reconcile compiled discovery, exact selected identities, executed results, skips, duplicates,
  and infrastructure failures for each lane. Preserve the first failing result and its evidence.
  A focused selection must cover the discovered impact, including indirect and dynamic callers.
- UI shards consume one validated same-run app/test/fixture archive. Validate revision, Xcode,
  SDK, architecture, signing settings, resources, modes, symlinks, and digests. For Debug apps, hash
  `AndBible.debug.dylib` as well as the executable stub. A relocated consumer must run using its
  own artifact inputs with producer paths unavailable. Repeat that check for the final products.
- Historical CI run `33124610055` measured 70 minutes 6 seconds elapsed and 174.60 raw job minutes,
  including 27.8 repeated app-build and 10.15 repeated fixture-build minutes. These establish the
  baseline for product reuse. Final cold/warm feedback and runner-cost budgets still require a
  current complete run. Missing/stale per-test timing estimates must remain explicit rather than
  borrowing a renamed case's time or inventing a value.

Keep changing per-run measurements and source/product manifests with execution artifacts. This
file describes ownership and completion criteria; it is not a canonical feature-parity tracker.

## Risks & mitigations
- **`@testable` re-export from shared lib** - can't re-expose internals; keep internal-touching helpers inside test targets (Phase 0).
- **Hidden inter-test state on shared `AndBibleTests` class** - per-class conversion may expose order-dependence; run each migrated file in isolation (`-only-testing`) early.
- **SwiftData/CLibSword on macOS host** - verify in Phase 2 that BibleCore links libsword on macOS; route any simulator-only slice to the simulator job rather than blocking the macOS lane.
- **Shared ownership** — coordinate edits to common controllers and helpers. Choose coherent implementation boundaries and validate all affected callers; a file-count limit is not a correctness rule.
- **Missing package test scheme / toolchain** - Phase 3 simulator runs and all `swift test` runs are blocked until the Phase 0 tasks (prove synthesized package-test schemes or commit explicit shared package test schemes; standardize `DEVELOPER_DIR` on full Xcode) are done and verified. CI's package-test lanes must use the same full-Xcode toolchain and must not rely on user-local Xcode state. A macOS `swift test` lane must additionally prove the whole package graph compiles under SwiftPM before it becomes required.
- **Classification by polluted imports** - placing files by today's `@testable import` set sends BibleCore-behavior tests into the simulator-bound BibleUITests and forfeits the speed win. Always re-minimize imports after Phase 0 and place at the lowest module that compiles.

## Success criteria

- Tests assert independently justified behavior at the boundary their names and reports claim.
  Superseded runtime paths and implementation-shaped expectations are removed after replacement
  contracts are proven. No selected feature ends at a permanent reduced-scope alignment.
- Package-owned contracts run without the app host. App-host tests cover genuine bootstrap;
  UI, native hosting, and real WebKit/Vue tests cover the remaining visible and lifecycle contracts.
  There is no arbitrary UI count, smoke-set size, or source-line reduction target.
- Every required lane executes its intended identities exactly, with omissions, skips, retries,
  infrastructure faults, and unsupported runtimes visible. Shared artifacts execute from an
  independent consumer with isolated fixture mutation.
- Controlled cold/warm feedback and total runner minutes meet budgets established from the
  baseline. Product Release latency, work counts, and supported-device results have separate gates;
  faster test teardown cannot establish a faster app.
- Guidance and documentation reflect the final ownership and known limits. Migration placement,
  compilation, or a partial passing selection alone cannot close this work.
