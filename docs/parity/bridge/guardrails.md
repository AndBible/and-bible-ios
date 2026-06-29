# BRIDGE-703 Guardrails

## Purpose

Prevent high-risk bridge regressions by making the non-negotiable compatibility
rules explicit for changes in:

- `Sources/BibleView/Sources/BibleView/BibleWebView.swift`
- `Sources/BibleView/Sources/BibleView/BibleBridge.swift`
- `Sources/BibleView/Sources/BibleView/BridgeTypes.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`
- `bibleview-js/src/`

## Rules

1. Do not rename or remove existing JavaScript message names casually.

   The switch cases in `BibleBridge.dispatchMessage(method:args:)` are part of the
   shared contract. Changing names like `openMyNotes`, `openStudyPad`,
   `parseRef`, `toggleFullScreen`, or `setClientReady` is a cross-platform
   breaking change unless Android and `bibleview-js` are updated in lockstep.
   Also do not assume iOS implements every method in Android's current
   `window.android` interface; the supported iOS subset must stay aligned with
   this repo's bundled frontend.

2. Do not change bridge argument ordering casually.

   The frontend still sends positional `args` arrays, not keyed payload objects,
   for many calls. Reordering arguments in Swift without a coordinated client
   change is a silent runtime break. Async methods must keep `callId` as the
   first argument unless the shared web-client bridge changes with it.
   Known bridge methods should validate required argument count/types and return
   a malformed dispatch result instead of silently no-oping or defaulting a
   required value. Optional arguments may be omitted or `null`, but a present
   wrong-type optional value should also be treated as malformed.

3. Treat the `window.android` compatibility shim as contract surface.

   The injected `Proxy` in `BibleWebView.swift` is not optional glue. It is the
   mechanism that keeps the shared frontend working on iOS while preserving the
   Android-style API shape.

4. Preserve synchronous `getActiveLanguages()` semantics unless the shared
   frontend contract changes.

   The `window.__activeLanguages__` cache exists because the client expects a
   synchronous answer. Replacing it with an async-only path is a behavioral
   contract break.

5. Treat documented bridge dispositions as stable surface, not dead code.

   `memorize`, `addParagraphBreakBookmark`, and
   `addGenericParagraphBreakBookmark` remain part of the contract because the
   shared frontend still knows about them. Paragraph-break actions now create
   native bookmarks with the reserved paragraph-break label; `memorize` now
   adds a local memorization target and opens the bundled Memorize document.
   The related state methods mutate the same local iOS state, while
   `speakMemorizationLoop` validates Android-style arguments and delegates to
   native selected-range repeat playback. Removing or weakening these branches
   requires coordinated contract work, not opportunistic cleanup.

   Android's My Documents bridge family is partially implemented. Keep
   `getMyDocumentPageRawContent`, `copyMyDocumentContent`,
   `shareMyDocumentContent`, `saveMyDocumentPageContent`, and
   `reloadMyDocumentPage` backed by `MyDocumentStore` lookup/mutation and reader
   document rebuilds; do not downgrade them to method-name-only stubs.
   `regenerateMyDocumentPage` and `deleteMyDocumentPage` are implemented only
   for pages with source prompt metadata: delete removes AI-generated pages and
   refreshes the reader, while regenerate validates the same metadata and hands
   native context to the iOS regeneration callback. User-authored pages must not
   be deleted through the AI action path. The native model/storage contract is
   recorded in `my-documents-model.md`, #82 owns edit/reload behavior, and #83
   owns AI page regenerate/delete behavior.

   Android's reading-progress bridge family is local model-backed surface.
   `recordChapterRead`, `openChapterReadHistory`, `openReadingProgress`,
   `openReadingProgressSettings`, and `setReadingProgressSettings` must stay
   connected to `ReadingProgressStore`, native sheet presentation, and validated
   settings persistence. Do not downgrade any of them to method-name-only
   branches. The native reading-progress model/storage, settings contract, and
   Android owner references are recorded in
   `reading-progress-model.md`. Planning names `markChapterRead` and
   `unmarkChapterRead` are local product-operation aliases, not Android bridge
   methods in the gap inventory.
   The related Android `progress` sync category remains separate in #73 and must
   not be folded into
   `readingplans` casually.

   Android's AI bridge family is documented deferred surface too. Do not add
   `llmAction`, `llmActionGeneric`, `noteEditorLlmAction`, `openAiDocPage`,
   `openAiDocPageChooser`, or `openPromptEditor` as method-name-only stubs.
   #89 owns the iOS AI bridge shell contract after #5 defines the shared AI
   backend direction, #90 owns text-action bridge behavior, #91 owns AI
   document navigation, and #92 owns prompt editor handoff. The related
   Android `ai_settings` sync category remains separate in #74 and must not
   invent an iOS-only AI settings schema.

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
     Android-only method is implemented, deferred to a linked issue family,
     intentionally no-oped, or declared an explicit iOS product divergence

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
  -only-testing:AndBibleUITests/AndBibleUITests/testBookmarkSelectionNavigatesReaderToSeededReference
```

Bridge-surface changes should also run:

```bash
python3 scripts/check_bridge_parity_inventory.py
```

Changes that touch async request/response handling or payload models should also
run the focused shared-scheme bridge subset:

```bash
xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO test \
  -only-testing:AndBibleTests/AndBibleTests/testBridgeCallIdRequestMappingMatchesWebClientContract \
  -only-testing:AndBibleTests/AndBibleTests/testBridgeCallIdDispatchClassifiesKnownMalformedMessages \
  -only-testing:AndBibleTests/AndBibleTests/testBridgeMessageDispatchClassifiesKnownMalformedMessages \
  -only-testing:AndBibleTests/AndBibleTests/testBridgeSendResponseEmitsCallIdResponseJavaScript \
  -only-testing:AndBibleTests/AndBibleTests/testBridgePayloadKeysMatchWebClientContracts \
  -only-testing:AndBibleTests/AndBibleTests/testRequestMoreToBeginningSendsDocumentResponseWithOriginalCallId \
  -only-testing:AndBibleTests/AndBibleTests/testRefChooserDialogSendsResponseWithOriginalCallId \
  -only-testing:AndBibleTests/AndBibleTests/testParseRefSendsResponseWithOriginalCallId \
  -only-testing:AndBibleTests/AndBibleTests/testMyDocumentRawContentBridgeSendsAndroidCompatiblePayloadAndNullFallback \
  -only-testing:AndBibleTests/AndBibleTests/testMyDocumentEditBridgePersistsContentAndReloadsVisiblePage
```

For parity-sensitive bridge work, run the Android alignment check against a
local Android checkout. The expected sibling checkout path is `../and-bible`:

```bash
python3 scripts/check_bridge_parity_inventory.py --android-root ../and-bible
```

If the Android checkout lives somewhere else, pass that path with
`--android-root` or set `ANDBIBLE_ANDROID_ROOT`. The command prints a compact
summary that can be pasted into an issue or PR. That summary should show:

- the iOS bundled bridge method count
- the Android reference method count when an Android checkout is supplied
- tracked Android-only methods
- new Android-only methods
- stale inventory entries
- resolved iOS bridge dispositions, including any methods that still need a
  decision

Run the Android-backed check when:

- Android has moved since the last parity pass
- bridge method names, argument ordering, or payloads are touched
- a PR changes `bibleview-js/src/composables/android.ts`
- an issue claims a bridge gap has been implemented or intentionally diverged

If a change touches one of the still-partial branches in the bridge matrix,
raise the bar and add focused regression coverage rather than relying on these
indirect note/document workflows alone.

## Current Automation Status

- The repo now has a dedicated machine-readable bridge inventory checker:
  `scripts/check_bridge_parity_inventory.py`.
- Current protection is a combination of:
  - focused regression coverage documented in `regression-report.md`
  - machine-readable gap tracking in
    `baselines/android-bridge-gap-inventory.json`
  - CI execution of `python3 scripts/check_bridge_parity_inventory.py` against
    the checked-in iOS bundle and inventory
  - local Android-backed drift detection through
    `python3 scripts/check_bridge_parity_inventory.py --android-root ../and-bible`
  - shared-scheme unit checks for async `callId` dispatch/response handling,
    malformed known-message dispatch classification, and representative bridge
    payload key shapes
  - explicit parity documentation in `contract.md`, `dispositions.md`, and
    `bridge-guide.md`
  - review discipline on `BibleBridge`, `BibleWebView`, `BridgeTypes`, and the
    corresponding `bibleview-js` types

## Potential Improvements

- expand the bridge inventory from gap tracking into a full per-method status
  ledger when implementation work begins
- add a lightweight parity checker for `BridgeTypes.swift` versus selected
  TypeScript type definitions
