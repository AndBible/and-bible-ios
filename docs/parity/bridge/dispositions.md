# iOS Bridge Parity Dispositions

This file records the places where iOS is deliberately doing something
different while still trying to preserve the shared client contract.

## 1. iOS preserves Android-style `window.android.*` calls via an injected shim

- Status: intentional adaptation

What we do:

- iOS does not expose a literal Android `JavascriptInterface`.
- Instead, `BibleWebView` injects a `window.android` `Proxy` that forwards calls
  through `WKScriptMessageHandler`.

Why this is fine:

- The shared frontend still calls Android-style APIs directly.
- Preserving that call surface is lower risk than forking the client contract.
- This means preserving the iOS-bundled shared subset, not every method that
  exists in Android's current `window.android` interface.

## 2. `getActiveLanguages()` is cached for synchronous parity

- Status: intentional adaptation

What we do:

- `getActiveLanguages()` is served from the injected
  `window.__activeLanguages__` cache on iOS.

Why this is fine:

- `WKScriptMessageHandler` does not support synchronous return values.
- The cache preserves the frontend's expectation that this call is synchronous.

## 3. Former no-op bridge actions now have explicit dispositions

- Status: mixed

Current dispositions:

- `addParagraphBreakBookmark`: implemented on iOS by creating a Bible bookmark
  with the reserved paragraph-break label.
- `addGenericParagraphBreakBookmark`: implemented on iOS by creating a generic
  bookmark with the reserved paragraph-break label.
- `memorize`: implemented on iOS by adding the selected range as a local
  memorization target and opening the bundled Memorize document.

Why this is no longer fuzzy:

- Paragraph-break actions now mutate native bookmark state and preserve the
  shared method surface used by the frontend.
- Memorization bridge state now mutates local native state rather than staying
  an accidental silent no-op.

## 4. Android memorization bridge state parity is partially implemented

- Status: implemented bridge state slice with remaining deferred speech/sync work
- Scope: `memorize`, `addMemorizationTarget`, `markAsMemorized`,
  `removeMemorizationTarget`, `unmarkMemorized`, and
  `speakMemorizationLoop`

Disposition:

- iOS now backs `memorize`, `addMemorizationTarget`, `markAsMemorized`,
  `removeMemorizationTarget`, and `unmarkMemorized` with a local
  `SettingsStore`-backed memorization state model.
- `memorize` preserves Android's `endOrdinal < 0` single-verse semantics, adds
  the selected range as a target if needed, and presents the bundled
  `MemorizeDocument`.
- Bible and Memorize document payloads now carry `memorizedOrdinals` and
  `targetOrdinals` arrays for the loaded ordinal range.
- Android routes `speakMemorizationLoop` through a distinct native speech-loop
  path rather than the existing generic `speak` behavior.
- Speech-loop parity remains tracked separately in #78. Remote Android
  `progress` sync remains blocked on #73 and the broader progress-model
  compatibility decisions.

Reason:

- The bridge state methods now have native product state to mutate, so they no
  longer need to remain missing from the iOS bundle.
- Keeping speech-loop and remote sync separate prevents this bridge slice from
  expanding into a full Android progress database and TTS-loop migration.

## 5. Android My Documents bridge parity is a deferred method family

- Status: documented deferred parity target
- Scope: `getMyDocumentPageRawContent`, `copyMyDocumentContent`,
  `shareMyDocumentContent`, `saveMyDocumentPageContent`,
  `reloadMyDocumentPage`, `regenerateMyDocumentPage`, and
  `deleteMyDocumentPage`

Disposition:

- iOS should treat My Documents as an accepted parity target, but should not
  add these as standalone bridge stubs.
- Android My Documents depends on a dedicated `mydocuments.sqlite3` Room
  database, page metadata, separately stored page content, AI-page cache
  metadata, generated JSword general-book registration, native clipboard/share
  behavior, editor save/reload behavior, and AI page regeneration/deletion.
- The first iOS slice is therefore the native My Documents model/storage and
  rendering contract in #80.
- Read-only bridge behavior for raw content, copy, and share follows in #81.
- Editor save/reload behavior follows in #82.
- AI-generated page regeneration and deletion follow in #83, with regeneration
  also depending on the shared AI direction in #5.
- Remote sync for Android's `mydocuments` category remains blocked on this
  local product surface and is tracked separately in #72.

Reason:

- Implementing only the bridge method names would create false parity because
  iOS would still lack the document/page state those calls read, mutate, render,
  or share.
- Keeping read/share, edit/reload, and AI-page actions separate prevents the
  first implementation PR from becoming a full document editor plus AI feature
  migration.

## 6. Android reading-progress bridge parity is a deferred method family

- Status: documented deferred parity target
- Scope: `markChapterRead`, `unmarkChapterRead`, `openReadingProgress`,
  `openReadingProgressSettings`, and `setReadingProgressSettings`

Disposition:

- iOS should treat Android reading progress as an accepted parity target, but
  should not add these as standalone bridge stubs.
- Android's method family mutates or presents general reading-progress state
  and settings, which are distinct from iOS reading-plan completion state.
- The first iOS slice is therefore the native reading-progress model, storage,
  and settings contract in #85.
- Chapter-read mutation behavior for `markChapterRead` and
  `unmarkChapterRead` follows in #86.
- Reading-progress UI and settings bridge behavior for `openReadingProgress`,
  `openReadingProgressSettings`, and `setReadingProgressSettings` follows in
  #87.
- Remote sync for Android's `progress` category remains blocked on this local
  product surface and is tracked separately in #73.

Reason:

- Implementing only the bridge method names would create false parity because
  iOS would still lack the reading-progress state and settings those calls
  mutate or present.
- Keeping reading-progress separate from reading-plan completion prevents the
  Android `progress` sync category from being folded into `readingplans`
  without an explicit compatibility decision.

## 7. Android AI bridge parity is a deferred method family

- Status: documented deferred parity target
- Scope: `llmAction`, `llmActionGeneric`, `noteEditorLlmAction`,
  `openAiDocPage`, `openAiDocPageChooser`, and `openPromptEditor`

Disposition:

- iOS should treat Android AI bridge behavior as an accepted parity target, but
  should not add these as standalone bridge stubs.
- Android's AI methods depend on prompt definitions, provider/model settings,
  execution semantics, AI document state, prompt editing, and platform
  integration that should be shared or explicitly platform-owned by #5.
- The first iOS bridge slice is therefore the AI bridge shell contract in #89,
  after the shared AI backend direction in #5 is concrete enough to define
  ownership.
- Text-action bridge behavior for `llmAction`, `llmActionGeneric`, and
  `noteEditorLlmAction` follows in #90.
- AI document navigation behavior for `openAiDocPage` and
  `openAiDocPageChooser` follows in #91.
- Prompt editor bridge behavior for `openPromptEditor` follows in #92.
- Remote sync for Android's `ai_settings` category remains blocked on the
  shared AI settings/backend contract and is tracked separately in #74.
- AI My Documents regeneration/deletion stays in the My Documents bridge slice
  #83 and also depends on the shared AI direction in #5.

Reason:

- Implementing only the bridge method names would create false parity because
  iOS would still lack the AI backend, prompt/settings model, document state,
  and platform shell those calls invoke.
- Keeping #89 as the first bridge slice prevents this repo from growing a
  parallel iOS-only AI architecture that would conflict with the backend-first
  direction in #5.

## 8. Fullscreen and compare are handled through iOS-native presentation paths

- Status: intentional adaptation

What we do:

- Fullscreen toggling is driven by injected web-side double-tap handling plus
  native reader state.
- Compare presentation uses native iOS presentation paths instead of Android's
  exact UI structure.

Why this is fine:

- The user-facing behavior remains parity-oriented, but UIKit/SwiftUI
  presentation constraints differ from Android's activity/dialog model.

## 9. Strong's modal uses a dedicated embedded-client route inside a native iOS sheet

- Status: intentional adaptation

What we do:

- iOS presents the Strong's surface as a native bottom sheet owned by the
  reader shell.
- Within that sheet, the embedded client now uses the dedicated
  `contentType: "strongs"` route and `StrongsDocument` rendering path rather
  than the generic multi-document renderer.

Why this is fine:

- The richer Android-style Strong's experience depends on route-specific client
  behavior such as per-dictionary tabs and preserved in-modal state.
- iOS still needs native sheet ownership for presentation, dismissal, and
  nested reader coordination.

## 10. Android-only bridge breadth is not fully implemented on iOS

- Status: current parity gap

What we do:

- iOS preserves the bridge methods needed by this repo's bundled frontend and
  native feature set.
- Android currently exposes 89 methods in its `BibleJavascriptInterface` type,
  while the iOS-bundled frontend exposes 66. The Android-only methods cover
  areas such as memorization, reading progress, AI document actions, chapter
  navigation, scoped help, and document-page editing.
- The memorization state-method subset has a recorded disposition in #50 and is
  implemented on iOS; `speakMemorizationLoop` remains deferred to #78.
- The My Documents subset has a recorded disposition in #51 and follow-up
  issues #80, #81, #82, and #83, but it remains Android-only until those slices
  are implemented.
- The reading-progress subset has a recorded disposition in #52 and follow-up
  issues #85, #86, and #87, but it remains Android-only until those slices are
  implemented.
- The AI bridge subset has a recorded disposition in #53 and follow-up issues
  #89, #90, #91, and #92, but it remains Android-only until the shared backend
  and bridge shell slices are implemented.

Why this is still a gap:

- Those Android-only methods are real product surface in the Android checkout.
  If the iOS bundle starts calling them, the iOS bridge contract and regression
  coverage need to grow in the same change.
- The machine-readable gap inventory tracks these as work to close, not as
  permanently acceptable omissions.
