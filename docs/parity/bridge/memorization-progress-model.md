# iOS Memorization Progress Model

This records the iOS model decision for #77. It is intentionally narrower than
Android's full progress feature: the first iOS slice gives the bridge and
embedded Memorize document local state to read and mutate, while Android
`progress` sync compatibility remains separate #73 work.

## Android Owner References

Android's memorization progress surface is owned by the progress database and
progress controller:

- `../and-bible/app/src/main/java/net/bible/android/database/progress/ProgressEntities.kt`
  defines `MemorizedVerse`, `MemorizationTarget`, and global progress settings.
- `../and-bible/app/src/main/java/net/bible/android/database/progress/ProgressDao.kt`
  owns persistence queries for memorized KJV ordinals and target ranges.
- `../and-bible/app/src/main/java/net/bible/android/database/migrations/ProgressMigrations.kt`
  creates `MemorizationTarget` and progress settings schema.
- `../and-bible/app/src/main/java/net/bible/android/control/progress/ProgressControl.kt`
  normalizes incoming verse ranges to KJVA, mutates memorized verses and
  targets, computes range membership, and emits change events.
- `../and-bible/app/src/main/java/net/bible/android/control/page/ClientPageObjects.kt`
  decorates Bible and Memorize documents with `memorizedOrdinals` and
  `targetOrdinals`.

Android's durable identity is the KJVA ordinal. A memorized verse is one KJVA
ordinal with a timestamp, while a memorization target is an inclusive KJVA
ordinal range.

## iOS Ownership

iOS owns the first local slice in:

- `Sources/BibleCore/Sources/BibleCore/Database/MemorizationProgressStore.swift`
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`

`MemorizationProgressStore` persists a `MemorizationProgressSnapshot` as JSON in
`SettingsStore` under `memorization_progress_state_v1`. The snapshot has two
range lists:

- `memorizedRanges`
- `targetRanges`

Each range stores:

- `bookInitials`
- `startOrdinal`
- `endOrdinal`

The store keeps ranges normalized, sorted, and non-overlapping within a
`bookInitials` scope. Adding a range merges overlapping or adjacent ranges.
Removing a range subtracts intersections and can split an existing target.

This is not a SwiftData model and does not introduce a schema migration. That
is deliberate: the first slice is small enough to test through store behavior,
bridge mutations, and document payloads without porting the full Android
progress database.

## Range Normalization

Android converts incoming ranges to KJVA before persistence. iOS accepts that
as the remote compatibility direction, but the current local model keeps the
embedded reader ordinals plus `bookInitials`.

That choice is intentional for the first slice:

- iOS does not yet have the Android progress database or the full KJVA sync
  mapping needed by #73.
- Scoping local ordinals by `bookInitials` prevents collisions between loaded
  documents while preserving the reader's current ordinal semantics.
- Bridge calls still preserve Android's `endOrdinal < 0` single-verse contract
  before values reach the store.

Future #73 work must make any KJVA migration explicit. It should define how
local `bookInitials`-scoped ranges map to Android `progress` rows, how existing
local JSON state is adopted or rewritten, and how conflicts are reconciled with
remote progress data.

## Document Payload Contract

The embedded Memorize document needs enough state to render a practice session
and enough range identity to show memorized and target indicators:

- `type`: `memorize`
- `texts`: ordered verse keys and text for the selected range
- `state.memorize.mode`: currently `blur`
- `state.memorize.modeConfig`: currently an empty object
- `bookInitials`
- `v11n`: currently `KJVA`
- `osisRef`
- `startOrdinal`
- `endOrdinal`
- `memorizedOrdinals`
- `targetOrdinals`

Normal Bible document payloads also include `memorizedOrdinals` and
`targetOrdinals`. Those arrays are filtered to the loaded document's
`bookInitials` and inclusive ordinal range. They are empty when the local store
is unavailable or has no matching state.

## Follow-Up Boundaries

This model unblocks local memorization bridge behavior and focused regression
coverage, but it does not close the broader progress parity surface.

- Bridge follow-ups can depend on the local store and payload contract without
  adding Android remote sync.
- #73 owns Android `progress` sync compatibility, KJVA persistence mapping,
  remote adoption behavior, and conflict handling.
- #85 and its follow-ups own reading-progress model/settings work. Reading
  progress must stay separate from memorized-verses and memorization-target
  state unless a later compatibility decision explicitly combines them.
