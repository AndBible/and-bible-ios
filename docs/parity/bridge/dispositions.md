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

- Status: implemented bridge state and speech-loop slice with remaining deferred sync work
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
- The local model, range-normalization decision, and Android owner references
  are recorded in `memorization-progress-model.md`.
- iOS exposes `speakMemorizationLoop` with Android-style
  `(bookInitials, v11n, startOrdinal, endOrdinal)` bridge validation and routes
  it through a native `SpeakService` memorization loop instead of generic
  chapter auto-advance speech.
- Remote Android `progress` sync remains blocked on #73 and the broader
  progress-model compatibility decisions.

Reason:

- The bridge state methods now have native product state to mutate, so they no
  longer need to remain missing from the iOS bundle.
- Keeping remote sync separate prevents this bridge slice from expanding into a
  full Android progress database migration.

## 5. Android My Documents bridge parity is a staged method family

- Status: read/copy/share/edit/reload and AI page action bridge behavior implemented
- Implemented scope: `getMyDocumentPageRawContent`, `copyMyDocumentContent`,
  `shareMyDocumentContent`, `saveMyDocumentPageContent`, and
  `reloadMyDocumentPage`, `regenerateMyDocumentPage`, and
  `deleteMyDocumentPage`

Disposition:

- iOS treats My Documents as an accepted parity target, but bridge methods must
  remain backed by native model behavior rather than method-name-only stubs.
- Android My Documents depends on a dedicated `mydocuments.sqlite3` Room
  database, page metadata, separately stored page content, AI-page cache
  metadata, generated JSword general-book registration, native clipboard/share
  behavior, editor save/reload behavior, and AI page regeneration/deletion.
- The native iOS My Documents model/storage, raw-content payload, and Android
  owner references are recorded in `my-documents-model.md`.
- Read-only bridge behavior for raw content, copy, and share is implemented in
  #81 through `MyDocumentStore`.
- Editor save/reload behavior is implemented in #82 through
  `MyDocumentStore` mutations and reader document rebuilds.
- AI-generated page deletion and regeneration handoff are implemented in #83.
  Delete is limited to pages with source prompt metadata, removes the AI page,
  and refreshes the reader. Regenerate validates the same metadata and hands a
  native action context to iOS. The shared AI dialog/backend remains tracked by
  #5/#89.
- Remote sync for Android's `mydocuments` category is implemented separately
  through #72/#104/#105/#106/#108/#107/#109 and remains outside the bridge method
  family itself.

Reason:

- Implementing only deferred bridge method names would create false parity
  because iOS would still lack the native behavior those calls need.
- Keeping read/share, edit/reload, and AI-page actions separate prevents the
  first implementation PR from becoming a full document editor plus AI feature
  migration.

## 6. Android reading-progress bridge parity has local UI/settings behavior

- Status: local model/settings contract recorded; chapter-read mutation and UI/settings bridge behavior implemented
- Scope: Android bridge names `recordChapterRead`, `openChapterReadHistory`,
  `openReadingProgress`,
  `openReadingProgressSettings`, and
  `setReadingProgressSettings`

Disposition:

- iOS treats Android reading progress as an accepted parity target backed by
  native local state and SwiftUI presentation.
- The native iOS reading-progress model, storage, settings, Android owner
  references, and bridge argument mapping are recorded in
  `reading-progress-model.md`.
- iOS reading progress is append-only Bible chapter-read history. Read state is
  derived from `chapterReadCount > 0` for the active cycle, not from reading-plan
  completion state.
- `recordChapterRead` is implemented on iOS by appending local
  `ReadingProgressStore` history rows, updating `chapterReadCount`, and
  emitting `update_chapter_read_status`.
- iOS also exposes `markChapterRead` and `unmarkChapterRead` as local
  product-operation aliases for #86. They are not Android bridge methods
  tracked by the gap inventory.
- `openChapterReadHistory` presents a native chapter-history sheet for the
  active-cycle rows keyed by KJVA book ordinal and chapter.
- `openReadingProgress(tab)` presents the native reading-progress sheet and maps
  Android tab `0` to Reading and tab `1` to Memorization.
- `openReadingProgressSettings` presents native reading-progress settings.
- `setReadingProgressSettings(json)` validates the six-field Android JavaScript
  settings bundle, preserves native-only `autoTrackReading` and `activeCycle`,
  persists the supported fields, and emits `update_reading_progress_settings`.
- Remote sync for Android's `progress` category remains tracked separately in
  #73, after the local product surface and KJVA compatibility decisions are
  explicit.

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

## 8. Fullscreen is handled through iOS-native presentation paths

- Status: intentional adaptation

What we do:

- Fullscreen toggling is driven by injected web-side double-tap handling plus
  native reader state.

Why this is fine:

- The user-facing behavior remains parity-oriented, but UIKit/SwiftUI
  presentation constraints differ from Android's activity/dialog model.
- Compare is no longer covered by this disposition. The native iOS Compare
  sheet is tracked as reader parity drift by #123.

## 9. Strong's content uses a dedicated embedded-client route, but native sheet routing remains drift

- Status: mixed; embedded-client route accepted, native sheet routing tracked by #8

What we do:

- iOS presents the Strong's surface as a native bottom sheet owned by the
  reader shell.
- Within that sheet, the embedded client now uses the dedicated
  `contentType: "strongs"` route and `StrongsDocument` rendering path rather
  than the generic multi-document renderer.

What this means:

- The richer Android-style Strong's experience depends on route-specific client
  behavior such as per-dictionary tabs and preserved in-modal state.
- Preserving `contentType: "strongs"` is an accepted bridge requirement.
- The remaining native sheet ownership is not an accepted final parity endpoint;
  #8 tracks routing Strong's through the normal document/window pipeline.

## 10. Android-only bridge breadth is not fully implemented on iOS

- Status: current parity gap

What we do:

- iOS preserves the bridge methods needed by this repo's bundled frontend and
  native feature set.
- Android currently exposes 89 methods in its `BibleJavascriptInterface` type,
  while the iOS-bundled frontend exposes 81. The remaining Android-only methods
  cover areas such as AI document actions, chapter navigation, scoped help, and
  whole-page bookmarks.
- The memorization state-method subset has a recorded disposition in #50 and is
  implemented on iOS; `speakMemorizationLoop` has a recorded implementation
  disposition in #78.
- The My Documents subset has a recorded disposition in #51; #81 read/copy/share
  behavior, #82 edit/reload behavior, and #83 AI page delete/regenerate handoff
  behavior are implemented.
- The reading-progress subset has a recorded disposition in #52, a local
  model/settings contract in #85, chapter-read mutation behavior in #86, and
  history/UI/settings bridge behavior in #87.
- The AI bridge subset has a recorded disposition in #53 and follow-up issues
  #89, #90, #91, and #92, but it remains Android-only until the shared backend
  and bridge shell slices are implemented.

Why this is still a gap:

- Those Android-only methods are real product surface in the Android checkout.
  If the iOS bundle starts calling them, the iOS bridge contract and regression
  coverage need to grow in the same change.
- The machine-readable gap inventory tracks these as work to close, not as
  permanently acceptable omissions.
