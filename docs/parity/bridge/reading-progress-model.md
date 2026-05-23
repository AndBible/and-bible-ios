# iOS Reading Progress Model

This records the iOS model decision for #85. It is intentionally narrower than
Android's full progress feature: the first iOS slice defines local
chapter-reading state and settings ownership so #86 and #87 can add bridge
behavior without method-name-only stubs. Android `progress` sync compatibility
remains separate #73 work.

## Android Owner References

Android's reading-progress surface is owned by the progress database, progress
controller, and reading-progress web bridge:

- `../and-bible/app/src/main/java/net/bible/android/database/progress/ProgressEntities.kt`
  defines `ChapterReadHistory`, `ReadingSource`, and global progress settings.
- `../and-bible/app/src/main/java/net/bible/android/database/progress/ProgressDao.kt`
  owns read-history persistence, chapter counts, cycle summaries, and settings
  queries.
- `../and-bible/app/src/main/java/net/bible/android/database/migrations/ProgressMigrations.kt`
  creates and migrates chapter-read history and global progress settings.
- `../and-bible/app/src/main/java/net/bible/android/control/progress/ProgressControl.kt`
  normalizes Bible book identity to KJVA, appends read-history rows, computes
  chapter read counts, owns active-cycle behavior, and emits status changes.
- `../and-bible/app/src/main/java/net/bible/android/view/activity/page/BibleJavascriptInterface.kt`
  exposes `recordChapterRead`, `openChapterReadHistory`,
  `openReadingProgress`, `openReadingProgressSettings`, and
  `setReadingProgressSettings`.
- `../and-bible/app/bibleview-js/src/composables/reading-tracker.ts` calls the
  bridge for manual and auto-tracked chapter reads.
- `../and-bible/app/bibleview-js/src/composables/reading-progress-settings.ts`
  owns the JavaScript settings bundle passed to
  `setReadingProgressSettings`.

Android's durable chapter-read identity is `kjvBookOrdinal`, `chapter`, and
`cycle`. Read status is derived from history count greater than zero, not from a
stored boolean flag.

## Android Durable Model

Android stores one append-only `ChapterReadHistory` row per recorded read:

- `id`
- `kjvBookOrdinal`
- `chapter`
- `cycle`
- `readAt`
- `bookInitials`
- `source`

`source` is the enum name `MANUAL`, `AUTO_SCROLL`, or `AUTO_TTS`; unknown bridge
strings fall back to `MANUAL`.

The current cycle is resolved from global progress settings. A stored
`activeCycle` greater than zero wins. Otherwise Android uses the latest cycle
found in read-history rows, defaulting to cycle `1` when no history exists.

Manual chapter marking appends another history row and can raise a chapter's
count above one. Auto-scroll tracking is guarded on the JavaScript side by the
current `chapterReadCount`, so duplicate-prevention is not part of the durable
table itself.

Chapter history, book progress, calendar summaries, and read/unread state are
all derived from rows in the active cycle. Calendar day bucketing is done in
Kotlin against device-local time rather than by a database date function, so a
future iOS UI should apply local calendar semantics at the query/presentation
layer.

## iOS Ownership

The first iOS implementation should own reading progress in BibleCore as a
small local store, tentatively `ReadingProgressStore`, persisted through
`SettingsStore` as JSON under `reading_progress_state_v1`.

This first slice should not introduce a SwiftData schema or remote sync
migration. A JSON snapshot is sufficient for local bridge/UI behavior and keeps
#73 free to design an explicit Android `progress` sync migration later.

The snapshot should contain:

- `history`: append-only chapter-read rows
- `settings`: the local global reading-progress settings snapshot

Each history row should store:

- `id`
- `bookInitials`
- `startOrdinal`
- `kjvBookOrdinal`
- `chapter`
- `cycle`
- `readAt`
- `source`

The primary compatibility key is `kjvBookOrdinal`, `chapter`, and `cycle`.
`bookInitials` and `startOrdinal` are retained as bridge/source-document
provenance because the embedded reader receives module-scoped ordinals. They
are not the cross-platform read-state key once the row has been normalized to a
KJVA book ordinal.

Reading progress is Bible-chapter state only. Generic documents and reading
plans must not write chapter-read rows unless a later parity issue records a
separate compatibility decision.

## Bridge Argument Mapping

Android currently exposes the mutation bridge as `recordChapterRead`, while
earlier iOS parity planning also uses `markChapterRead` and
`unmarkChapterRead` as product-operation names. The iOS contract is:

- `recordChapterRead` or `markChapterRead` appends one chapter-read history row.
- Read state is `chapterReadCount > 0` for the active cycle.
- A chapter's count may be greater than one.
- `unmarkChapterRead` clears read status for the addressed chapter in the
  active cycle by deleting all matching rows for `kjvBookOrdinal`, `chapter`,
  and `cycle`.

Android's row-level deletion is driven by history UI with row IDs. A bridge
unmark call that only carries chapter identity cannot target one Android
history row reliably, so iOS should treat it as "make this chapter unread" for
the current cycle.

For chapter-read mutation and history-open calls:

- `bookInitials` identifies the source module/document.
- `startOrdinal` is resolved against that module's versification to identify
  the Bible book.
- `chapter` is the chapter number from the current document.
- `source` is persisted as the Android enum string, with unknown values mapped
  to `MANUAL`.

The stored row should normalize book identity to KJVA before deriving
`kjvBookOrdinal`, while preserving the original `bookInitials` and
`startOrdinal` for local provenance and future migration.

## Settings Contract

Android has a global reading-progress settings singleton and a narrower
JavaScript settings bundle.

The iOS global settings snapshot should carry:

- `autoTrackReading`, default `false`
- `activeCycle`, default `0`
- `autoMarkMemorized`, default `true`
- `memorizeTypeFullWords`, default `false`
- `memorizeWordVisibility`, default `light`
- `memorizeErrorHeatmap`, default `true`
- `memorizeScrambleHideUsed`, default `false`
- `memorizeIncludeReference`, default `true`

`setReadingProgressSettings(json)` should accept the Android JavaScript bundle
shape and merge only the bundle fields:

- `autoMarkMemorized`
- `memorizeTypeFullWords`
- `memorizeWordVisibility`
- `memorizeErrorHeatmap`
- `memorizeScrambleHideUsed`
- `memorizeIncludeReference`

It should preserve `autoTrackReading` and `activeCycle`, because Android's
current JavaScript bundle does not include those fields. Unknown or malformed
JSON should be handled as invalid bridge input rather than replacing the whole
settings snapshot with defaults.

`memorizeWordVisibility` should accept Android's string values `light`, `dim`,
and `hidden`.

## Document Payload And Events

When #86 adds mutation behavior, normal Bible document payloads should expose
the active chapter's `chapterReadCount` so the embedded reading tracker can
avoid auto-marking an already-read chapter.

When #87 adds UI/settings behavior, iOS should also expose:

- `autoTrackReading` in the document/config path that controls auto-scroll
  tracking
- `readingProgressSettings` using the six-field JavaScript settings bundle
- `update_chapter_read_status` events with `chapter` and `count`
- `update_reading_progress_settings` events after settings changes

All counts and events are scoped to the active cycle and the currently loaded
Bible chapter identity after KJVA normalization.

## Separation From Reading Plans

Reading progress is not reading-plan completion.

The iOS contract must not reuse reading-plan day/completion records for this
state. Android tracks `readingplans` and `progress` as separate sync categories,
and the local iOS model should keep the same product boundary:

- Reading-plan state answers "did the user complete this plan assignment?"
- Reading-progress state answers "how many times was this Bible chapter read in
  this cycle, and from which source?"

## Follow-Up Boundaries

This model unblocks reading-progress bridge work, but it does not implement the
method family itself.

- #86 owns chapter-read mutation, read-history bridge behavior, document
  payload counts, and focused regression coverage.
- #87 owns `openReadingProgress`, `openReadingProgressSettings`, settings
  persistence through `setReadingProgressSettings`, and focused UI/settings
  coverage.
- #73 owns Android `progress` sync compatibility, KJVA persistence migration,
  remote adoption behavior, and conflict handling.
- Reading-plan completion must stay separate unless a later compatibility
  decision explicitly combines the models.
