# iOS My Documents Model

This records the iOS model and storage decision for #80. My Documents is an
accepted iOS parity target, but it is not just a bridge method family. The
local document/page/content model must exist before iOS can safely implement
the Android bridge methods from #81, #82, and #83 or the remote `mydocuments`
sync category from #72.

## Android Owner References

Android owns My Documents through a dedicated syncable Room database and a
generated JSword general-book backend:

- `../and-bible/app/src/main/java/net/bible/android/database/mydocument/MyDocumentDatabase.kt`
  defines `mydocuments.sqlite3` and the syncable Room database boundary.
- `../and-bible/app/src/main/java/net/bible/android/database/mydocument/MyDocumentEntities.kt`
  defines `MyDocument`, `MyDocumentPage`, `MyDocumentPageContent`,
  `AiPageCacheEntry`, and combined page/content projections.
- `../and-bible/app/src/main/java/net/bible/android/database/mydocument/MyDocumentDao.kt`
  owns document, page, raw-content, AI-cache, and marker lookup queries.
- `../and-bible/app/src/main/java/net/bible/service/sword/mydocument/MyDocumentBookManager.kt`
  registers documents, exposes raw page content, saves page content, creates AI
  pages, deletes AI pages, and refreshes document registrations.
- `../and-bible/app/src/main/java/net/bible/service/sword/mydocument/MyDocumentBackend.kt`
  presents stored pages as a generated `SwordGenBook` and renders page content.
- `../and-bible/app/src/main/java/net/bible/android/view/activity/page/BibleJavascriptInterface.kt`
  exposes the Android bridge methods for raw-content, copy/share, save/reload,
  regenerate, and delete behavior.
- `../and-bible/app/bibleview-js/src/components/documents/OsisDocument.vue`
  and `../and-bible/app/bibleview-js/src/components/documents/DocumentActionMenu.vue`
  consume My Documents page metadata in the embedded client.

Android stores document metadata, page metadata, and page content separately.
That split is part of the contract because sync patches and raw-content bridge
calls can update page bodies without rewriting document metadata.

## iOS Ownership

iOS should model My Documents as native user data in BibleCore, not as a
`SettingsStore` blob and not as bookmark or StudyPad state. The accepted owner
shape is:

- `Sources/BibleCore/Sources/BibleCore/Models/MyDocument.swift` for SwiftData
  model types.
- `Sources/BibleCore/Sources/BibleCore/Database/MyDocumentStore.swift` for
  low-level document/page/content queries and mutations.
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift` or a
  dedicated document builder for rendering pages into the current WebView
  document pipeline.

The SwiftData graph should mirror Android's split closely enough for future
sync mapping:

- `MyDocument`
  - `id: UUID`
  - `name: String`
  - `description: String?`
  - `initials: String`
  - `orderNumber: Int`
  - `createdAt: Date`
  - `updatedAt: Date`
  - `sourcePromptId: UUID?`
- `MyDocumentPage`
  - `id: UUID`
  - relationship to `MyDocument`
  - `title: String`
  - `pageKey: String`
  - `contentType: MyDocumentContentType`
  - `orderNumber: Int`
  - `createdAt: Date`
  - `updatedAt: Date`
  - `sourcePromptId: UUID?`
  - `languageCode: String?`
- `MyDocumentPageContent`
  - `pageId: UUID`
  - relationship to `MyDocumentPage`
  - `content: String`
- `AiPageCacheEntry`
  - `pageId: UUID`
  - relationship to `MyDocumentPage`
  - `sourcePromptId: UUID`
  - `sourceContext: String?`
  - `kjvOrdinalStart: Int?`
  - `kjvOrdinalEnd: Int?`
  - `contextHash: String?`
  - `usedWriteTools: Bool`
  - `sourceModelName: String?`
  - `sourceBookInitials: String?`
  - `sourceBookKey: String?`

`MyDocumentContentType` should persist Android-aligned raw values:
`MARKDOWN`, `HTML`, and `OSIS`.

Document `initials` must be unique. Page `pageKey` must be unique within a
document. iOS may generate `initials` and `pageKey` differently from Android,
but stored values must remain stable because bridge calls, rendered document
payloads, and future sync mapping use them as lookup keys.

## User And AI Document Ownership

User-created and AI-generated pages should share the same document and page
tables. Ownership is distinguished by nullable prompt metadata:

- `sourcePromptId == nil` means user-created content.
- `sourcePromptId != nil` means AI-generated content or a document/page created
  from a prompt.

The Android default AI document uses the stable initials `AIDocuments`. iOS
should reserve the same initials for the default AI document when shared AI
support is implemented. Until then, the base My Documents model can store the
field but should not implement AI regeneration behavior. That remains #83 and
depends on the shared AI direction in #5.

`AiPageCacheEntry` is part of the accepted model because it is required for AI
document markers, deletion side effects, regeneration context, and future
Android `mydocuments` sync compatibility. The first model implementation may
add the entity before all AI workflows are active.

## Rendering Path

Android registers each My Document as a generated JSword general book. iOS does
not need to fake SWORD module registration for the first implementation slice.
The accepted iOS rendering path is:

1. `MyDocumentStore` resolves a page by `(document.initials, page.pageKey)`.
2. A My Documents document builder renders the stored page content.
3. `BibleReaderController` emits a normal WebView document with `type: "osis"`
   and `bookCategory: "GENERAL_BOOK"`.
4. The payload includes My Documents metadata so the embedded client can show
   edit, share, copy, AI-footer, and marker affordances when those bridge
   slices are implemented.

The rendered document payload should include:

- `type: "osis"`
- `bookCategory: "GENERAL_BOOK"`
- `bookInitials: document.initials`
- `bookName: document.name`
- `key: page.pageKey`
- `osisRef: page.pageKey`
- `isNativeHtml`
- `isMyDocument: true`
- `isAiDocument: document.initials == "AIDocuments"`
- `myDocumentPageId: page.id.uuidString`
- `sourcePromptId: page.sourcePromptId?.uuidString`
- `sourcePromptName`
- `sourceModelName`
- `aiDocMarkers`

The iOS-bundled frontend now exposes the #81 raw-content/copy/share bridge
methods and the #82 save/reload bridge methods. The remaining Android My
Documents fields and action menu behavior should only be added as the #83
AI-page behavior becomes real.

Content rendering should preserve Android's content-type meanings:

- `MARKDOWN`: convert Markdown to XHTML-compatible HTML before embedding.
- `HTML`: render as sanitized/native HTML without losing raw edit content.
- `OSIS`: render the stored OSIS fragment as-is.

The raw stored content remains unchanged. Rendering is a view concern.

## Raw-Content Bridge Payload

The raw-content payload needed by #81 is:

```json
{
  "pageId": "UUID string",
  "contentType": "MARKDOWN",
  "content": "stored raw page content",
  "title": "Page title",
  "sourcePromptId": "UUID string or null"
}
```

`getMyDocumentPageRawContent(callId, bookInitials, pageKey)` responds with that
payload through `bibleView.response(callId, payload)`. Missing documents or
pages respond with `bibleView.response(callId, null)`.

`copyMyDocumentContent` and `shareMyDocumentContent` use the same raw lookup
path and operate on the stored page `content`, not the rendered HTML.
`saveMyDocumentPageContent` updates `MyDocumentPageContent.content` and
optionally `MyDocumentPage.title`, while `reloadMyDocumentPage` rebuilds the
visible rendered document for the matching `bookInitials`.

## Sync Boundary

Android exposes My Documents as the separate `mydocuments` sync category backed
by `mydocuments.sqlite3`. iOS must keep it separate from `bookmarks`,
`workspaces`, and `readingplans`.

#72 owns remote sync behavior. It should use this model as its local
prerequisite and then define:

- Android table mapping for `MyDocument`, `MyDocumentPage`,
  `MyDocumentPageContent`, and `AiPageCacheEntry`.
- Initial-backup restore/upload behavior for the separate category.
- Patch replay/upload behavior, including content-only page updates.
- Remote adoption and conflict behavior.
- How AI cache rows are preserved when shared AI support is not yet enabled.

This #80 decision does not add a remote sync category by itself.

## First Implementation Slice

The first code slice after this decision should be small enough to test without
porting every Android My Documents behavior:

- Add the SwiftData models and `MyDocumentStore`. (Done for #81.)
- Cover document creation, page creation, page lookup by `(initials, pageKey)`,
  raw-content retrieval, content update, title update, and cascade deletion.
- Add a minimal renderer or builder that can produce one My Documents
  `type: "osis"` page payload from stored content.

#81 adds read-only bridge methods, #82 adds edit/reload behavior, and #83 can
add AI regenerate/delete behavior.
