# BRIDGE-703 Guardrails

## Purpose

Prevent high-risk bridge regressions by making the non-negotiable compatibility
rules explicit for changes in:

- `Sources/BibleView/Sources/BibleView/BibleWebView.swift`
- `Sources/BibleView/Sources/BibleView/BibleBridge.swift`
- `Sources/BibleView/Sources/BibleView/BridgeTypes.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/StrongsSheetView.swift`
- `bibleview-js/src/`

## Rules

1. Do not rename or remove existing JavaScript message names casually.

   The switch cases in `BibleBridge.userContentController(...)` are part of the
   shared contract. Changing names like `openMyNotes`, `openStudyPad`,
   `parseRef`, `toggleFullScreen`, or `setClientReady` is a cross-platform
   breaking change unless Android and `bibleview-js` are updated in lockstep.
   Also do not assume iOS implements every method in Android's current
   `window.android` interface; the supported iOS subset must stay aligned with
   this repo's bundled frontend.

2. Do not change bridge argument ordering casually.

   The frontend still sends positional `args` arrays, not keyed payload objects,
   for many calls. Reordering arguments in Swift without a coordinated client
   change is a silent runtime break.

3. Treat the `window.android` compatibility shim as contract surface.

   The injected `Proxy` in `BibleWebView.swift` is not optional glue. It is the
   mechanism that keeps the shared frontend working on iOS while preserving the
   Android-style API shape.

4. Preserve synchronous `getActiveLanguages()` semantics unless the shared
   frontend contract changes.

   The `window.__activeLanguages__` cache exists because the client expects a
   synchronous answer. Replacing it with an async-only path is a behavioral
   contract break.

5. Treat documented no-op methods as stable surface, not dead code.

   Current no-op branches such as `memorize`,
   `addParagraphBreakBookmark`, and `addGenericParagraphBreakBookmark` remain
   part of the contract because the shared frontend still knows about them.
   Removing them requires coordinated contract work, not opportunistic cleanup.

6. Do not change `BridgeTypes.swift` payload keys casually.

   Payload drift between Swift Codable models and `bibleview-js/src/types/`
   typically fails at runtime rather than at compile time. Any field rename,
   removal, or required-field addition should be treated as a parity change.

7. New bridge methods or emitted events must update the docs in the same slice.

   When adding or changing bridge surface area, update:

   - `docs/parity/bridge/contract.md`
   - `docs/parity/bridge/dispositions.md` when the behavior is iOS-specific
   - `docs/bridge-guide.md`
   - `docs/parity/bridge/verification-matrix.md` if status changes
   - `docs/parity/bridge/baselines/android-bridge-gap-inventory.json` if an
     Android-only method is implemented, intentionally no-oped, or declared an
     explicit iOS product divergence

## Validation Expectations

At minimum, bridge-adjacent changes should keep the focused embedded-document
subset green:

```bash
xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .derivedData-bridge-docs \
  CODE_SIGNING_ALLOWED=NO test \
  -only-testing:AndBibleTests/AndBibleTests/testBookmarkServiceClearingBibleBookmarkNoteDeletesPersistedNoteRow \
  -only-testing:AndBibleTests/AndBibleTests/testBookmarkServiceClearingBibleBookmarkNoteRemovesBookmarkFromMyNotesQuery \
  -only-testing:AndBibleUITests/AndBibleUITests/testBookmarkListOpensStudyPadForSelectedLabel
```

Bridge-surface changes should also run:

```bash
python3 scripts/check_bridge_parity_inventory.py
```

If a local Android reference checkout is available, include it for stricter
Android-only method drift detection:

```bash
python3 scripts/check_bridge_parity_inventory.py --android-root .and-bible-android
```

If a change touches one of the still-partial branches in the bridge matrix,
raise the bar and add focused regression coverage rather than relying on these
indirect note/document workflows alone.

## Current Automation Status

- The repo currently has no dedicated machine-readable bridge drift checker.
- Current protection is a combination of:
  - focused regression coverage documented in `regression-report.md`
  - machine-readable gap tracking in
    `baselines/android-bridge-gap-inventory.json`
  - explicit parity documentation in `contract.md`, `dispositions.md`, and
    `bridge-guide.md`
  - review discipline on `BibleBridge`, `BibleWebView`, `BridgeTypes`, and the
    corresponding `bibleview-js` types

## Potential Improvements

- expand the bridge inventory from gap tracking into a full per-method status
  ledger when implementation work begins
- add a lightweight parity checker for `BridgeTypes.swift` versus selected
  TypeScript type definitions
- restore focused My Notes UI lifecycle coverage if that visible surface remains
  in scope
- add dedicated focused coverage for `callId` request/response flows
