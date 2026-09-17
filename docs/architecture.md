# Architecture

This project is an Xcode app plus four Swift package modules layered from low-level SWORD access up to SwiftUI screens.

## Start Here

- App entry point: [`AndBibleApp`](../AndBible/AndBibleApp.swift)
- Root navigation shell: [`ContentView`](../AndBible/ContentView.swift)
- Package and module graph: [`Package.swift`](../Package.swift)
- Main reading surface: [`BibleReaderView`](../Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift)
- Per-pane bridge and WebView host: [`BibleWindowPane`](../Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift)
- Reader orchestration: [`BibleReaderController`](../Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift)
- JS bridge contract: [`BibleBridge`](../Sources/BibleView/Sources/BibleView/BibleBridge.swift)

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

[`Package.swift`](../Package.swift) is the source of truth for this graph.

## Layers

### 1. `SwordKit`

Purpose: Swift wrapper around the prebuilt SWORD C++ library.

- `CLibSword` exposes the adapter C headers and links the native dependencies.
- `SwordKit` is the Swift API used by higher layers.
- This is the lowest layer that knows about SWORD module positioning, keys, options, entries, and live-tree mutation leases.
- [`SwordRuntime`](../Sources/SwordKit/Sources/SwordKit/SwordRuntime.swift) serializes access to libsword. [`SwordManager.performRenderOperation`](../Sources/SwordKit/Sources/SwordKit/SwordManager.swift) applies one option snapshot and captures copied source values while the native operation owns the cursor and module-store read lease.
- [`SwordModule.currentVerseSourceEntry`](../Sources/SwordKit/Sources/SwordKit/SwordModule.swift) copies the exact positioned key, converted OSIS, and fallback text without moving the cursor. `SwordBibleCanonicalTextProjection` parses that copied value after the native lease ends. A successful empty projection remains distinct from conversion failure: title- and note-only content can be canonically empty, `canonical=true` content overrides those exclusions, and separator handling uses Java-compatible UTF-16 whitespace without a later Foundation trim.

### 2. `BibleCore`

Purpose: persistence, services, and domain logic.

- Holds SwiftData models, stores, and services such as `WindowManager`, `BookmarkService`, `SearchIndexService`, and `SyncService`.
- `AndBibleApp` creates the `ModelContainer`, initializes stores and services, seeds default labels, and starts sync monitoring.
- SwiftData models remain on their owning context. Work that leaves that owner receives immutable copied values rather than live models or relationships.

### 3. `BibleView`

Purpose: host the packaged Vue.js client in `WKWebView` and translate between JS messages and native callbacks.

- [`BibleWebView`](../Sources/BibleView/Sources/BibleView/BibleWebView.swift) creates the web view, injects the Android compatibility shim, and loads the packaged bundle.
- [`BibleBridge`](../Sources/BibleView/Sources/BibleView/BibleBridge.swift) owns message dispatch, asynchronous response settlement, and native-to-JS events.
- [`WebViewCoordinator`](../Sources/BibleView/Sources/BibleView/WebViewCoordinator.swift) handles navigation interception and native scroll and swipe forwarding.

### 4. `BibleUI`

Purpose: SwiftUI feature screens and reader orchestration.

- [`BibleReaderView`](../Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift) coordinates toolbars, sheets, split windows, fullscreen state, and settings presentation.
- [`BibleWindowPane`](../Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift) binds one bridge, controller, WebView session, and persisted window.
- [`BibleReaderController`](../Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift) owns the selected reader destination, prepares typed family requests, captures context-owned values, and applies accepted publication effects.
- [`BibleReaderDocumentPreparationCoordinator`](../Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderDocumentPreparationCoordinator.swift) is the sole scheduler for reader document preparation. It owns coalescing, cancellation, phase order, worker execution, and terminal outcomes.
- [`BibleReaderPreparationPublicationOwner`](../Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderPreparationPublicationOwner.swift) applies the common main-queue publication transaction. Family adapters retain typed source capture, authorization, selected-intent, and accepted-render effects.

## App Boot Sequence

1. `AndBibleApp` runs data migration before creating SwiftData.
2. It reads the iCloud sync toggle before container creation.
3. It builds the Cloud/user-data and local-only model configurations.
4. It prepares the SWORD module directory with `SwordSetup.ensureModulesReady()`.
5. It creates stores and services, chooses or creates the active workspace, seeds system labels, and starts sync monitoring.
6. The app scene renders `CalculatorView` or `ContentView` according to the persecution setting.

## Reading Flow

1. `ContentView` presents `BibleReaderView` as the main detail surface.
2. `BibleReaderView` lays out one or more `BibleWindowPane` values for the active workspace.
3. Each pane owns a `BibleReaderController`, `BibleBridge`, and retained WebView session and registers the controller with `WindowManager`.
4. A navigation or document action records a typed destination and source request. The controller may commit an authorized selected document or key before rendering so a client that is not ready can replay that intent later.
5. The preparation coordinator runs the applicable source capture, main-owner capture, source enrichment, projection, and encoding phases. Native SWORD work remains serialized; SwiftData capture returns copied values before worker projection continues.
6. The publication owner revalidates the pane, workspace, source generation, authorization, and prepared owner. It dispatches any required configuration or labels, revalidates around synchronous callbacks, and sends the replacement or scroll through `BibleBridge`.
7. Accepted bridge dispatch advances committed render identity, loaded bounds, and render-owned side effects only while the destination and source remain current. Cancellation, supersession, rejection, and an accepted dispatch followed by synchronous invalidation have distinct terminal outcomes.
8. The Vue client renders the document in the packaged WebView. User actions return through `BibleBridge`; Promise-style calls settle exactly once.

## State Ownership

There are four distinct state boundaries.

### SwiftData persisted state

Examples include workspaces, windows, page managers, history, bookmarks, labels, StudyPad, reading plans, and local settings. The owning `ModelContext` captures the exact persisted fields and relationships needed by a request. Live SwiftData models do not move to preparation workers.

### Selected navigation intent

The controller and `PageManager` retain the authorized document, key, or position the user selected. This state can advance before WebView acceptance so a valid request survives client bootstrap and replays on readiness. A stale pane, workspace, owner, or source fails before selected intent changes.

### Accepted rendered state

`BibleReaderController.committedRenderState` records only content accepted by the bridge. Loaded chapter bounds, rendered document identity, accepted commentary navigation, and other render-owned effects advance at this boundary. Selected intent is not evidence that content rendered, and bridge dispatch alone is not evidence that Vue reached a visible settled position.

### Routed source authorization

Multi, Definition, and Memorize content can be prepared by one pane and published by another. A
`BibleReaderRoutedSourceAuthorization` value follows that payload and authorizes the backing manager,
installed-source generation, and exact dependencies at every destination publication boundary. It
does not make the source pane's later selection part of destination ownership: closing or navigating
the source pane cannot invalidate already handed-off content while its backing source remains current.
Payloads with no mutable backing source must opt into the explicit independent authorization rather
than receiving an implicit always-current default.

### Web client state

The WebView owns client readiness, its current rendered document set, modal and focus state, DOM selection, and the opaque UI state returned through `saveState`. Native code retains the saved state needed for ordinary client-ready reconstruction.

## Threading And Lifetime Rules

- SwiftUI state, `WKWebView`, bridge dispatch, selected-intent commits, and publication validation run on the main actor or the documented main-queue owner.
- SwiftData reads and relationship traversal stay on the model's owning context. Background phases use immutable `Sendable` snapshots.
- SWORD option application, cursor positioning, entry reads, and restoration run inside one serialized native operation and module-store lease. A worker may retain the lease while native work runs, but no unrestricted live handle becomes a cross-queue payload.
- Source projection and JSON encoding operate on copied values away from the UI owner. Memorize canonical-text projection consumes copied `SwordVerseSourceEntry` values after the SWORD operation releases its cursor and module-store lease.
- The preparation coordinator is the only preparation scheduler. The publication owner does not create an independent retry loop; a still-current family may explicitly request at most one fresh capture according to its policy.
- Cancellation and destination supersession settle without publication. A bridge side effect already accepted before synchronous invalidation is reported separately and never reused as an eligible pre-dispatch retry.

## Current Cost Limits

The asynchronous lifecycle removes native extraction and document serialization from ordinary main-thread input handling, but it does not make every owner capture constant-cost.

- Exact publication authorization may recapture persisted owner values to protect direct mutations that do not yet have complete event revisions.
- StudyPad, My Notes, My Documents, and annotation families still copy the rows that genuinely belong to the requested owner.
- Exact AI marker predicates bound primary marker rows, but projecting their parent document can fault the parent's complete inverse page collection. Measured 10,000-row fixtures still expose this relationship cost.
- Some settings and progress payloads remain whole-value JSON and can require repeated decode or copy work.
- Installed-source and cache generations protect freshness; they do not by themselves establish bounded retention, cache eviction correctness, or supported-device latency.

These costs remain validation and redesign inputs. Do not bypass exact owner authorization with private SQLite reads or an incomplete cache, and do not describe the reader lifecycle as performance-complete until Release, retained-memory, and device gates pass.

The copied-source canonical-text boundary and its exact empty/Java-whitespace behavior are part of the current source checkpoint. The exact source16 SwordKit selection passed 86/86, and source17's iOS 17 reader selection passed 73/73 with declared-canon sparse fixtures and no native read errors. Newer-runtime, device, and Release acceptance remains open. This architecture description does not claim those remaining evidence gates have completed.

## Multi-Window Model

AndBible iOS keeps Android's multi-window reading model.

- `WindowManager` is injected as an environment object from `AndBibleApp`.
- `BibleReaderView` reads focused and destination controllers from `WindowManager` and owns fullscreen and tab-bar presentation.
- Each `BibleWindowPane` has an independent bridge/controller/WebView session, so panes can retain different sources and positions.
- Destination policy, delayed pane registration, and lifecycle cancellation remain separate from document preparation. Preparation cannot silently redirect a request to a source pane.

## Where To Read Next

- Bridge details: [bridge-guide.md](bridge-guide.md)
- Persistence/entity reference: [data-model.md](data-model.md)
- Build and simulator workflow: [howto/building-and-testing.md](howto/building-and-testing.md)
- Module-by-module reading order: [module-structure.md](module-structure.md)
