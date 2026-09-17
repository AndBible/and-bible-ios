# Data Model

This is the current SwiftData persistence map for AndBible iOS. It documents the entities that actually exist today, how they relate to each other, and the store/layout rules enforced by `AndBibleApp`.

## Source Files

- Store configuration: `AndBible/AndBibleApp.swift:39-100`
- Store repair/migration: `Sources/BibleCore/Sources/BibleCore/Services/DataMigration.swift:5-72`
- Workspace/window models: `Sources/BibleCore/Sources/BibleCore/Models/Workspace.swift:8-224`, `Sources/BibleCore/Sources/BibleCore/Models/Window.swift:8-155`
- Bookmark/label models: `Sources/BibleCore/Sources/BibleCore/Models/Bookmark.swift:47-277`, `Sources/BibleCore/Sources/BibleCore/Models/Label.swift:14-150`, `Sources/BibleCore/Sources/BibleCore/Models/StudyPad.swift:8-53`
- Reading plan models: `Sources/BibleCore/Sources/BibleCore/Models/ReadingPlan.swift:7-85`
- Local-only models: `Sources/BibleCore/Sources/BibleCore/Database/SettingsStore.swift:6-98`, `Sources/BibleCore/Sources/BibleCore/Database/RepoStore.swift:6-68`

## Store Layout

The app uses two SwiftData configurations:

- Sync-eligible store: `AndBible.store`
  - configured in `AndBible/AndBibleApp.swift:46-82`
  - contains `Workspace`, `Window`, `PageManager`, `HistoryItem`, bookmarks, labels, StudyPad entries, and reading plans
  - optionally syncs to CloudKit when `icloud_sync_enabled` is true
- Local-only store: `LocalStore.store`
  - configured in `AndBible/AndBibleApp.swift:66-89`
  - contains only `Repository` and `Setting`
  - never syncs

`DataMigration.migrateIfNeeded()` repairs older broken layouts before the container is created and restores the canonical `AndBible.store` name if needed: `Sources/BibleCore/Sources/BibleCore/Services/DataMigration.swift:18-72`.

## Relationship Map

```text
Workspace
  1 -> many Window
  1 -> 0/1 TextDisplaySettings (embedded Codable struct)
  1 -> 0/1 WorkspaceSettings (embedded Codable struct)

Window
  many -> 1 Workspace
  1 -> 0/1 PageManager
  1 -> many HistoryItem

BibleBookmark
  1 -> 0/1 BibleBookmarkNotes
  1 -> many BibleBookmarkToLabel

GenericBookmark
  1 -> 0/1 GenericBookmarkNotes
  1 -> many GenericBookmarkToLabel

BibleBookmarkToLabel
  many -> 1 BibleBookmark
  many -> 1 Label

GenericBookmarkToLabel
  many -> 1 GenericBookmark
  many -> 1 Label

Label
  1 -> many StudyPadTextEntry

StudyPadTextEntry
  many -> 1 Label
  1 -> 0/1 StudyPadTextEntryText

ReadingPlan
  1 -> many ReadingPlanDay

ReadingPlanDay
  many -> 1 ReadingPlan

Setting
  standalone key/value record

Repository
  standalone module-source record
```

## Persistence Clusters

### Workspace cluster

The reading UI persists a workspace graph:

- `Workspace` is the top-level study context with stable `id`, user-visible `name`, `orderNumber`, optional `workspaceColor`, optional `maximizedWindowId`, and optional `primaryTargetLinksWindowId`: `Sources/BibleCore/Sources/BibleCore/Models/Workspace.swift:8-53`
- `Workspace.windows` is a cascade relationship, so deleting a workspace deletes all windows below it: `Sources/BibleCore/Sources/BibleCore/Models/Workspace.swift:40-42`
- `Window` holds pane-level flags such as `isSynchronized`, `isPinMode`, `isLinksWindow`, `targetLinksWindowId`, `syncGroup`, and layout metadata: `Sources/BibleCore/Sources/BibleCore/Models/Window.swift:8-67`
- `Window.pageManager` and `Window.historyItems` are both cascade relationships: `Sources/BibleCore/Sources/BibleCore/Models/Window.swift:40-46`
- `PageManager` is the 1:1 durable state for the active document/category in a window and stores separate fields for Bible, commentary, dictionary, general book, map, and EPUB navigation: `Sources/BibleCore/Sources/BibleCore/Models/Window.swift:69-121`
- `HistoryItem` stores back/forward state per window using `document`, `key`, and optional `anchorOrdinal`: `Sources/BibleCore/Sources/BibleCore/Models/Window.swift:123-155`

Operational rules from the store layer:

- Creating a workspace always creates one default Bible window and a matching `PageManager` with the same ID as the window: `Sources/BibleCore/Sources/BibleCore/Database/WorkspaceStore.swift:34-53`
- Adding a window also creates a matching `PageManager`: `Sources/BibleCore/Sources/BibleCore/Database/WorkspaceStore.swift:170-186`
- Cloning a workspace deep-copies windows and current page-manager state, starts every cloned window with empty navigation history, then remaps links-window IDs and maximized-window IDs to the new window UUIDs, matching Android's workspace-clone contract: `Sources/BibleCore/Sources/BibleCore/Database/WorkspaceStore.swift:129-205`

### Display settings inheritance

There are two embedded Codable structs rather than separate tables:

- `WorkspaceSettings`: cross-window behavior flags and StudyPad metadata such as `autoAssignLabels`, `autoAssignPrimaryLabel`, `studyPadCursors`, and `hideCompareDocuments`: `Sources/BibleCore/Sources/BibleCore/Models/Workspace.swift:55-88`
- `TextDisplaySettings`: optional presentation fields that participate in a three-level inheritance chain: `Window.pageManager.textDisplaySettings` -> `Workspace.textDisplaySettings` -> `TextDisplaySettings.appDefaults`: `Sources/BibleCore/Sources/BibleCore/Models/Workspace.swift:101-223`, `Sources/BibleCore/Sources/BibleCore/Models/Window.swift:108-112`

Use `TextDisplaySettings.resolved(...)` or `TextDisplaySettings.fullyResolved(...)` instead of manually stitching these together: `Sources/BibleCore/Sources/BibleCore/Models/Workspace.swift:138-223`.

### Bookmark and label cluster

Bible and non-Bible bookmarks use parallel structures:

- `BibleBookmark`: verse-oriented bookmark with KJVA-facing ordinals, original ordinals, optional book name, optional note, label junctions, and optional text offsets for sub-verse selections: `Sources/BibleCore/Sources/BibleCore/Models/Bookmark.swift:47-130`
- `GenericBookmark`: key-based bookmark for dictionaries, general books, and other non-Bible content: `Sources/BibleCore/Sources/BibleCore/Models/Bookmark.swift:171-243`
- `BibleBookmarkNotes` and `GenericBookmarkNotes`: separated into their own entities for query performance: `Sources/BibleCore/Sources/BibleCore/Models/Bookmark.swift:132-143`, `:245-256`
- `BibleBookmarkToLabel` and `GenericBookmarkToLabel`: many-to-many junctions that also carry StudyPad ordering metadata (`orderNumber`, `indentLevel`, `expandContent`): `Sources/BibleCore/Sources/BibleCore/Models/Bookmark.swift:145-169`, `:258-277`
- `Label`: user highlight/tag entity plus StudyPad container; it stores display style flags, `favourite`, optional type, and optional `customIcon`: `Sources/BibleCore/Sources/BibleCore/Models/Label.swift:14-150`

Important semantics:

- Bible bookmark overlap queries are ordinal-based and optionally book-scoped: `Sources/BibleCore/Sources/BibleCore/Database/BookmarkStore.swift:48-65`
- The service API explicitly warns callers to pass `book` to avoid cross-book ordinal collisions: `Sources/BibleCore/Sources/BibleCore/Services/BookmarkService.swift:84-87`
- The main reader path does exactly that and also stamps `bookmark.book = currentBook` when creating a new bookmark: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift:1538-1558`

### StudyPad cluster

StudyPad persists journal content against labels:

- `StudyPadTextEntry` belongs to a `Label` and stores only the ordering shell (`orderNumber`, `indentLevel`): `Sources/BibleCore/Sources/BibleCore/Models/StudyPad.swift:8-35`
- `StudyPadTextEntryText` stores the actual text separately and links back via `studyPadTextEntryId`: `Sources/BibleCore/Sources/BibleCore/Models/StudyPad.swift:37-53`
- `BookmarkStore.studyPadEntries(labelId:)` sorts by `orderNumber` and currently filters by `label` after fetch: `Sources/BibleCore/Sources/BibleCore/Database/BookmarkStore.swift:166-174`
- `BookmarkStore.upsertStudyPadEntryText(...)` updates or inserts the detached text row: `Sources/BibleCore/Sources/BibleCore/Database/BookmarkStore.swift:197-219`

### Reading plan cluster

Reading plans are simple parent/child records:

- `ReadingPlan` stores `planCode`, `planName`, `startDate`, `currentDay`, `totalDays`, `isActive`, and a cascade `days` relationship: `Sources/BibleCore/Sources/BibleCore/Models/ReadingPlan.swift:7-51`
- `ReadingPlanDay` stores `dayNumber`, `isCompleted`, optional `completedDate`, and `readings`: `Sources/BibleCore/Sources/BibleCore/Models/ReadingPlan.swift:53-85`

### Local-only settings and repository cluster

These two entities intentionally stay out of CloudKit:

- `Setting`: unique `key` plus string `value`, used by `SettingsStore` for app-level durable preferences including `active_workspace_id`: `Sources/BibleCore/Sources/BibleCore/Database/SettingsStore.swift:6-98`
- `Repository`: module source metadata with `name`, `url`, `lastRefreshed`, and `isEnabled`: `Sources/BibleCore/Sources/BibleCore/Database/RepoStore.swift:6-68`

## Field Reference

### `Workspace`

File: `Sources/BibleCore/Sources/BibleCore/Models/Workspace.swift:8-53`

| Field | Type | Notes |
| --- | --- | --- |
| `id` | `UUID` | Unique primary key |
| `name` | `String` | User-visible workspace name |
| `contentsText` | `String?` | Free-form descriptive text |
| `orderNumber` | `Int` | Workspace list ordering |
| `textDisplaySettings` | `TextDisplaySettings?` | Workspace-level presentation defaults |
| `workspaceSettings` | `WorkspaceSettings?` | Workspace behavior metadata |
| `unPinnedWeight` | `Float?` | Layout weight for unpinned windows |
| `maximizedWindowId` | `UUID?` | Tracks fullscreen/maximized pane |
| `primaryTargetLinksWindowId` | `UUID?` | Preferred links target pane |
| `workspaceColor` | `Int?` | Android-style ARGB color payload |
| `windows` | `[Window]?` | Cascade child windows |

### `Window`

File: `Sources/BibleCore/Sources/BibleCore/Models/Window.swift:8-67`

| Field | Type | Notes |
| --- | --- | --- |
| `id` | `UUID` | Unique primary key |
| `workspace` | `Workspace?` | Parent workspace |
| `isSynchronized` | `Bool` | Participates in sync scrolling |
| `isPinMode` | `Bool` | Persists pin state |
| `isLinksWindow` | `Bool` | Marks cross-reference pane |
| `orderNumber` | `Int` | Window ordering within workspace |
| `targetLinksWindowId` | `UUID?` | Explicit links target |
| `syncGroup` | `Int` | Sync group partition |
| `layoutWeight` | `Float` | Split sizing |
| `layoutState` | `String` | Current layout mode string |
| `pageManager` | `PageManager?` | 1:1 durable page state |
| `historyItems` | `[HistoryItem]?` | Back/forward history |

### `PageManager`

File: `Sources/BibleCore/Sources/BibleCore/Models/Window.swift:69-121`

| Field | Type | Notes |
| --- | --- | --- |
| `id` | `UUID` | Unique key, intentionally matches the owning `Window.id` |
| `window` | `Window?` | Parent window |
| `bibleDocument` | `String?` | Bible module initials |
| `bibleVersification` | `String?` | Bible versification ID |
| `bibleBibleBook` | `Int?` | Current book index |
| `bibleChapterNo` | `Int?` | Current chapter |
| `bibleVerseNo` | `Int?` | Current verse |
| `commentaryDocument` | `String?` | Commentary module initials |
| `commentaryAnchorOrdinal` | `Int?` | Commentary anchor position |
| `dictionaryDocument` | `String?` | Dictionary module initials |
| `dictionaryKey` | `String?` | Dictionary key |
| `generalBookDocument` | `String?` | General book module initials |
| `generalBookKey` | `String?` | General book key |
| `mapDocument` | `String?` | Map module initials |
| `mapKey` | `String?` | Map key |
| `epubIdentifier` | `String?` | EPUB identity |
| `epubHref` | `String?` | Current EPUB location |
| `currentCategoryName` | `String` | Active document category |
| `textDisplaySettings` | `TextDisplaySettings?` | Window-level display overrides |
| `jsState` | `String?` | Opaque serialized web-client state |

### `HistoryItem`

File: `Sources/BibleCore/Sources/BibleCore/Models/Window.swift:123-155`

| Field | Type | Notes |
| --- | --- | --- |
| `id` | `UUID` | Primary key |
| `window` | `Window?` | Parent window |
| `createdAt` | `Date` | Creation timestamp |
| `document` | `String` | Module initials |
| `key` | `String` | Durable location key |
| `anchorOrdinal` | `Int?` | Optional scroll anchor |

### `BibleBookmark`

File: `Sources/BibleCore/Sources/BibleCore/Models/Bookmark.swift:47-130`

| Field | Type | Notes |
| --- | --- | --- |
| `id` | `UUID` | Primary key |
| `kjvOrdinalStart` | `Int` | Start ordinal used for sorting/lookup |
| `kjvOrdinalEnd` | `Int` | End ordinal used for sorting/lookup |
| `ordinalStart` | `Int` | Original-module start ordinal |
| `ordinalEnd` | `Int` | Original-module end ordinal |
| `v11n` | `String` | Original module versification identifier |
| `book` | `String?` | Book name snapshot used to disambiguate collisions |
| `playbackSettings` | `PlaybackSettings?` | TTS metadata |
| `createdAt` | `Date` | Creation timestamp |
| `startOffset` | `Int?` | Optional text-selection start offset |
| `endOffset` | `Int?` | Optional text-selection end offset |
| `primaryLabelId` | `UUID?` | Preferred display label |
| `lastUpdatedOn` | `Date` | Mutation timestamp |
| `wholeVerse` | `Bool` | True for whole-verse bookmark, false for sub-selection |
| `type` | `String?` | Special bookmark category |
| `customIcon` | `String?` | Canonical icon name |
| `editAction` | `EditAction?` | Template for note editing |
| `notes` | `BibleBookmarkNotes?` | Detached note row |
| `bookmarkToLabels` | `[BibleBookmarkToLabel]?` | Label junctions |

### `GenericBookmark`

File: `Sources/BibleCore/Sources/BibleCore/Models/Bookmark.swift:171-243`

| Field | Type | Notes |
| --- | --- | --- |
| `id` | `UUID` | Primary key |
| `key` | `String` | Document key |
| `bookInitials` | `String` | Module initials |
| `createdAt` | `Date` | Creation timestamp |
| `ordinalStart` | `Int` | Start ordinal within the document |
| `ordinalEnd` | `Int` | End ordinal within the document |
| `startOffset` | `Int?` | Optional text-selection start offset |
| `endOffset` | `Int?` | Optional text-selection end offset |
| `primaryLabelId` | `UUID?` | Preferred display label |
| `lastUpdatedOn` | `Date` | Mutation timestamp |
| `wholeVerse` | `Bool` | Whole-entry vs sub-selection |
| `playbackSettings` | `PlaybackSettings?` | TTS metadata |
| `customIcon` | `String?` | Canonical icon name |
| `editAction` | `EditAction?` | Template for note editing |
| `notes` | `GenericBookmarkNotes?` | Detached note row |
| `bookmarkToLabels` | `[GenericBookmarkToLabel]?` | Label junctions |

### `BibleBookmarkNotes` and `GenericBookmarkNotes`

File: `Sources/BibleCore/Sources/BibleCore/Models/Bookmark.swift:132-143`, `:245-256`

| Field | Type | Notes |
| --- | --- | --- |
| `bookmarkId` | `UUID` | Unique back-reference key on both note entities |
| `bookmark` | optional parent relationship | Owning bookmark |
| `notes` | `String` | Detached note payload |

### `BibleBookmarkToLabel` and `GenericBookmarkToLabel`

File: `Sources/BibleCore/Sources/BibleCore/Models/Bookmark.swift:145-169`, `:258-277`

| Field | Type | Notes |
| --- | --- | --- |
| `bookmark` | optional parent relationship | Owning bookmark |
| `label` | `Label?` | Joined label |
| `orderNumber` | `Int` | StudyPad ordering |
| `indentLevel` | `Int` | StudyPad nesting |
| `expandContent` | `Bool` | StudyPad expansion state |

### `Label`

File: `Sources/BibleCore/Sources/BibleCore/Models/Label.swift:14-150`

| Field | Type | Notes |
| --- | --- | --- |
| `id` | `UUID` | Primary key |
| `name` | `String` | Display name or reserved system label name |
| `color` | `Int` | Android-style ARGB color payload |
| `markerStyle` | `Bool` | Marker icon style |
| `markerStyleWholeVerse` | `Bool` | Marker applies to whole verse |
| `underlineStyle` | `Bool` | Underline style |
| `underlineStyleWholeVerse` | `Bool` | Underline applies to whole verse |
| `hideStyle` | `Bool` | Hidden/invisible highlight style |
| `hideStyleWholeVerse` | `Bool` | Hidden style applies to whole verse |
| `favourite` | `Bool` | Quick-access label |
| `type` | `String?` | Categorization such as `HIGHLIGHT` |
| `customIcon` | `String?` | Android canonical icon name or SF Symbol fallback |
| `studyPadEntries` | `[StudyPadTextEntry]?` | Attached journal entries |

System-label rules:

- Reserved names: `__SPEAK_LABEL__`, `__UNLABELED__`, `__PARAGRAPH_BREAK_LABEL__`: `Sources/BibleCore/Sources/BibleCore/Models/Label.swift:85-89`
- Deterministic UUIDs are used so CloudKit sync deduplicates these labels across devices: `Sources/BibleCore/Sources/BibleCore/Models/Label.swift:90-93`
- `BookmarkService.ensureSystemLabels()` creates or repairs them at startup: `Sources/BibleCore/Sources/BibleCore/Services/BookmarkService.swift:198-221`

### `StudyPadTextEntry` and `StudyPadTextEntryText`

File: `Sources/BibleCore/Sources/BibleCore/Models/StudyPad.swift:8-53`

| Field | Type | Notes |
| --- | --- | --- |
| `id` | `UUID` | Primary key on `StudyPadTextEntry` |
| `label` | `Label?` | Owning StudyPad label |
| `orderNumber` | `Int` | Display ordering |
| `indentLevel` | `Int` | Nesting level |
| `textEntry` | `StudyPadTextEntryText?` | Detached text row |
| `studyPadTextEntryId` | `UUID` | Unique foreign-key-style ID on text row |
| `entry` | `StudyPadTextEntry?` | Parent StudyPad shell |
| `text` | `String` | Actual note content |

### `ReadingPlan` and `ReadingPlanDay`

File: `Sources/BibleCore/Sources/BibleCore/Models/ReadingPlan.swift:7-85`

| Field | Type | Notes |
| --- | --- | --- |
| `id` | `UUID` | Primary key |
| `planCode` | `String` | Template/import identifier |
| `planName` | `String` | User-visible name |
| `startDate` | `Date` | Plan start date |
| `currentDay` | `Int` | Current plan day |
| `totalDays` | `Int` | Total plan length |
| `isActive` | `Bool` | Active/inactive flag |
| `days` | `[ReadingPlanDay]?` | Cascade child days |
| `dayNumber` | `Int` | Day index on `ReadingPlanDay` |
| `isCompleted` | `Bool` | Completion flag |
| `completedDate` | `Date?` | Completion timestamp |
| `readings` | `String` | Semicolon-separated reading references |

### `Setting`

File: `Sources/BibleCore/Sources/BibleCore/Database/SettingsStore.swift:6-16`

| Field | Type | Notes |
| --- | --- | --- |
| `key` | `String` | Unique setting key |
| `value` | `String` | Persisted string value |

### `Repository`

File: `Sources/BibleCore/Sources/BibleCore/Database/RepoStore.swift:6-26`

| Field | Type | Notes |
| --- | --- | --- |
| `id` | `UUID` | Primary key |
| `name` | `String` | User-visible source name |
| `url` | `String` | Repository URL |
| `lastRefreshed` | `Date?` | Last metadata refresh time |
| `isEnabled` | `Bool` | Whether the source is active |

## Color and Ordinal Conventions

### ARGB colors

The code uses Android-style 32-bit ARGB values stored in Swift `Int`.

Examples:

- `Label.defaultColor = 0xFF91A7FF`: `Sources/BibleCore/Sources/BibleCore/Models/Label.swift:82-83`
- `TextDisplaySettings.appDefaults` uses signed Int32-style values such as `-1` for white and `-16777216` for black: `Sources/BibleCore/Sources/BibleCore/Models/Workspace.swift:172-179`

When adding new colors, preserve the Android payload format because the Vue.js renderer expects it.

### Bible ordinals

Current iOS Bible rendering/bookmark code uses a simplified book-local ordinal formula:

`(chapter - 1) * 40 + verse`

Evidence:

- scroll targeting: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift:1313-1314`
- chapter bookmark range construction: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift:3455-3505`
- explicit doc comment: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift:3259`

Implications:

- ordinals are not globally unique across books
- bookmark lookup APIs should pass `book` where available
- `BibleBookmark.book` is part of the persistence model because the ordinal alone is not enough to disambiguate a verse across the whole canon

This is the behavior to preserve unless the whole bookmark/rendering contract is redesigned together.

## Read Next

- System overview: [architecture.md](architecture.md)
- Bridge contract: [bridge-guide.md](bridge-guide.md)
- Config JSON emitted to Vue.js: [config-reference.md](config-reference.md)
