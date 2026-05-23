# My Documents Sync Schema

This records the #104 sync-schema and policy decision for the Android
`mydocuments` category. It is the contract that the #72 implementation slices
must follow before iOS exposes My Documents remote sync in settings.

## Android Source References

The contract below is grounded in the current Android source:

- `../and-bible/app/src/main/java/net/bible/service/cloudsync/SyncUtilities.kt`
  defines `SyncableDatabaseDefinition.MYDOCUMENTS`, the `mydocuments` category
  name, and the four domain tables that participate in sync.
- `../and-bible/app/src/main/java/net/bible/android/database/mydocument/MyDocumentDatabase.kt`
  defines `mydocuments.sqlite3` and Android Room database version `4`.
- `../and-bible/app/src/main/java/net/bible/android/database/mydocument/MyDocumentEntities.kt`
  defines the persisted My Documents entities and the derived views.
- `../and-bible/app/schemas/net.bible.android.database.mydocument.MyDocumentDatabase/4.json`
  is the checked-in Room schema snapshot for the current database shape.
- `../and-bible/app/src/main/java/net/bible/android/database/mydocument/MyDocumentDao.kt`
  owns document, page, content, AI-cache, and marker lookup behavior.
- `../and-bible/app/src/main/java/net/bible/android/database/migrations/MyDocumentMigrations.kt`
  records the version 2 through 4 AI cache additions.
- `../and-bible/app/src/main/java/net/bible/service/cloudsync/CloudSync.kt`
  defines `initial.sqlite3.gz`, patch naming, initial restore/upload, and
  patch replay/upload flow shared by all syncable databases.

## Category Boundary

Android exposes My Documents as its own sync category:

- category enum: `MYDOCUMENTS`
- persisted/settings category name: `mydocuments`
- database file name: `mydocuments.sqlite3`
- current Android schema version: `4`
- setting key: `sync_enable_mydocuments`

iOS must keep this category separate from `bookmarks`, `workspaces`, and
`readingplans`. The iOS settings UI must not expose `mydocuments` until the
restore, upload, patch replay, and patch upload services exist and are covered.
That settings exposure belongs to #109, after #105, #106, #108, and #107.

## Synced Domain Tables

Android's `SyncableDatabaseDefinition.MYDOCUMENTS.tables` lists exactly four
domain tables. iOS must map every one of them to a local owner.

| Android table | Android identity | iOS owner | Sync decision |
|---|---|---|---|
| `MyDocument` | `id` | `BibleCore.MyDocument` | Sync. Preserve `id`, `name`, `description`, `initials`, `orderNumber`, `createdAt`, `updatedAt`, and `sourcePromptId`. |
| `MyDocumentPage` | `id` | `BibleCore.MyDocumentPage` | Sync. Preserve the Android page UUID, parent `documentId`, `title`, `pageKey`, `contentType`, `orderNumber`, timestamps, `sourcePromptId`, and `languageCode`. |
| `MyDocumentPageContent` | `pageId` | `BibleCore.MyDocumentPageContent` | Sync. Treat `pageId` as the row identity and allow content-only updates without requiring a metadata row change. |
| `AiPageCacheEntry` | `pageId` | `BibleCore.AiPageCacheEntry` | Sync. Treat `pageId` as the Android row identity, even if the local SwiftData entity keeps an iOS-only `id` for storage. Preserve cache metadata without requiring shared AI regeneration support. |

Every current Android domain column is either preserved or explicitly ignored:

- `MyDocument.id` maps to `MyDocument.id`.
- `MyDocument.name` maps to `MyDocument.name`.
- `MyDocument.description` maps to `MyDocument.documentDescription`.
- `MyDocument.initials` maps to `MyDocument.initials`.
- `MyDocument.orderNumber` maps to `MyDocument.orderNumber`.
- `MyDocument.createdAt` maps to `MyDocument.createdAt`.
- `MyDocument.updatedAt` maps to `MyDocument.updatedAt`.
- `MyDocument.sourcePromptId` maps to `MyDocument.sourcePromptId`.
- `MyDocumentPage.id` maps to `MyDocumentPage.id`.
- `MyDocumentPage.documentId` maps to the parent `MyDocument.id`
  relationship and must be preserved during export.
- `MyDocumentPage.title` maps to `MyDocumentPage.title`.
- `MyDocumentPage.pageKey` maps to `MyDocumentPage.pageKey`.
- `MyDocumentPage.contentType` maps to
  `MyDocumentPage.contentTypeRawValue`.
- `MyDocumentPage.orderNumber` maps to `MyDocumentPage.orderNumber`.
- `MyDocumentPage.createdAt` maps to `MyDocumentPage.createdAt`.
- `MyDocumentPage.updatedAt` maps to `MyDocumentPage.updatedAt`.
- `MyDocumentPage.sourcePromptId` maps to
  `MyDocumentPage.sourcePromptId`.
- `MyDocumentPage.languageCode` maps to `MyDocumentPage.languageCode`.
- `MyDocumentPageContent.pageId` maps to
  `MyDocumentPageContent.pageId`.
- `MyDocumentPageContent.content` maps to
  `MyDocumentPageContent.content`.
- `AiPageCacheEntry.pageId` maps to `AiPageCacheEntry.pageId` and the owning
  page relationship.
- `AiPageCacheEntry.sourcePromptId` maps to
  `AiPageCacheEntry.sourcePromptId`.
- `AiPageCacheEntry.sourceContext` maps to
  `AiPageCacheEntry.sourceContext`.
- `AiPageCacheEntry.kjvOrdinalStart` maps to
  `AiPageCacheEntry.kjvOrdinalStart`.
- `AiPageCacheEntry.kjvOrdinalEnd` maps to
  `AiPageCacheEntry.kjvOrdinalEnd`.
- `AiPageCacheEntry.contextHash` maps to
  `AiPageCacheEntry.contextHash`.
- `AiPageCacheEntry.usedWriteTools` maps to
  `AiPageCacheEntry.usedWriteTools`.
- `AiPageCacheEntry.sourceModelName` maps to
  `AiPageCacheEntry.sourceModelName`.
- `AiPageCacheEntry.sourceBookInitials` maps to
  `AiPageCacheEntry.sourceBookInitials`.
- `AiPageCacheEntry.sourceBookKey` maps to
  `AiPageCacheEntry.sourceBookKey`.
- `AiPageCacheEntry.id` is an iOS-only SwiftData storage key and must be
  ignored for Android import/export.

Android `IdType` columns are Room `BLOB` columns and serialize as UUID-shaped
strings in Kotlin serialization. iOS stores these values as `UUID`; import and
export code must preserve the Android identifiers rather than generating new
ones during restore, replay, or upload.

Android timestamps are epoch milliseconds in `createdAt` and `updatedAt`. iOS
`Date` values must import from and export to those millisecond values.

`MyDocumentContentType` raw values are part of the contract and must remain:

- `MARKDOWN`
- `HTML`
- `OSIS`

## Shared Sync Tables

The Android Room database also contains the shared sync plumbing tables from
`SyncableRoomDatabase`. They are not My Documents user-data tables, but the
category services must preserve their meaning.

| Android table | iOS owner | Decision |
|---|---|---|
| `LogEntry` | `RemoteSyncLogEntryStore` and category patch services | Sync metadata. Use it for Android-style sparse patch identity, operation type, timestamps, and source device. Do not expose it as My Documents user data. |
| `SyncConfiguration` | `RemoteSyncStateStore` and bootstrap state | Sync configuration. Preserve folder/device/bootstrap values according to the existing category contract. |
| `SyncStatus` | `RemoteSyncPatchStatusStore` | Patch progress metadata. Use it to track applied and uploaded patch numbers per device folder. |

## Derived Views And Ignored Rows

Android defines two views:

- `MyDocumentPageWithContent`
- `AiCachedPageWithContent`

These are projections over the four domain tables. They must not be imported,
exported, or patched as independent rows. iOS should reconstruct equivalent
read models from `MyDocumentPage`, `MyDocumentPageContent`, and
`AiPageCacheEntry` when the bridge or UI needs them.

SQLite metadata tables, Room metadata rows, indexes, and triggers are not
user-data rows. Exported Android-shaped SQLite files may need the expected
schema objects, but row-level sync ownership remains limited to the tables
listed above.

## Initial Restore Contract (#105)

When the user adopts an existing remote `mydocuments` folder, the remote
`initial.sqlite3.gz` is authoritative for the category. The restore service
must:

- accept Android schema versions up to the current supported version `4`
- reject newer schema versions before mutating local state
- import `MyDocument` before `MyDocumentPage`, then `MyDocumentPageContent`,
  then `AiPageCacheEntry`
- preserve Android UUIDs, timestamps, content-type raw values, document
  initials, and page keys exactly
- preserve AI cache rows as metadata, without invoking shared AI behavior
- refuse to create orphan pages, content rows, or cache rows if the archive is
  structurally invalid
- rebuild local sync metadata so later patch replay starts from patch zero

The existing adopt-versus-create UI decision remains the conflict boundary. iOS
must not silently merge an adopted Android baseline into unrelated local My
Documents data.

## Initial Upload Contract (#106)

When the user creates a fresh remote `mydocuments` folder from local iOS state,
the upload service must produce Android-shaped `initial.sqlite3.gz` for schema
version `4`. It must include:

- the four domain tables with Android-compatible columns and identifiers
- Android-compatible `LogEntry`, `SyncConfiguration`, and `SyncStatus` tables
- the derived views expected by the Android schema
- empty sync log/status content for the uploaded baseline, matching Android's
  clear-log and clear-status initial upload behavior

The exported graph must maintain parent-child integrity. Documents are exported
before pages; pages are exported before content and AI cache rows.

## Patch Replay Contract (#108)

Android replays patch databases in the table order declared by
`SyncableDatabaseDefinition.MYDOCUMENTS.tables`:

1. `MyDocument`
2. `MyDocumentPage`
3. `MyDocumentPageContent`
4. `AiPageCacheEntry`

iOS replay must match the Android outcome:

- process only patch `LogEntry` rows that are newer than the local preserved
  `LogEntry` for the same table and identity
- apply `UPSERT` rows from the patch database when the referenced row exists in
  the patch table
- apply `DELETE` rows by Android identity
- clean up child rows that become foreign-key-invalid after parent deletion
- record accepted patch `LogEntry` rows in the local metadata baseline
- handle content-only page updates through `MyDocumentPageContent`
- treat `AiPageCacheEntry.pageId` as the remote row key

The replay service must not regenerate AI content. It only preserves or removes
stored rows according to the patch.

## Patch Upload Contract (#107)

Outbound sparse upload must emit an Android-shaped patch database for local My
Documents changes. It must:

- use `LogEntry.tableName` values `MyDocument`, `MyDocumentPage`,
  `MyDocumentPageContent`, and `AiPageCacheEntry`
- use `entityId1` values from `id`, `id`, `pageId`, and `pageId` respectively
- leave `entityId2` empty for all four tables
- emit `UPSERT` with the matching table row for changed or newly created rows
- emit `DELETE` for locally deleted rows known from the preserved baseline
- emit content-only changes as `MyDocumentPageContent` changes
- omit a patch entirely when there are no local changes
- update `lastPatchWritten` and patch status only after a successful upload

Any local SwiftData-only identifier that does not exist in Android, such as an
iOS storage `id` for `AiPageCacheEntry`, must not appear in exported Android
SQLite rows or `LogEntry` identities.

## Follow-Up Ownership

#104 is complete when this source-backed contract is recorded. Runtime parity
then belongs to these smaller #72 children:

- #105: restore Android `mydocuments` initial backups into the iOS model
- #106: upload iOS My Documents as Android-shaped initial backups
- #108: replay Android `mydocuments` sparse patches into iOS
- #107: upload Android-shaped sparse patches for iOS My Documents changes
- #109: expose the `mydocuments` sync category in UI/docs after services pass
