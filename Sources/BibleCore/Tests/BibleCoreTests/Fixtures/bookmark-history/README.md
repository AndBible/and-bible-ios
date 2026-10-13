# Historical Android bookmark databases

The schema statements in `1.sql` through `12.sql` come from Android Room exports:
`app/schemas/net.bible.android.database.BookmarkDatabase/<version>.json`, at
AndBible/and-bible commit `2e45efb0d814f9a4e43f0e8f382328a61543cc1b`.
Only Room table/index/view placeholders are expanded and statement terminators added.

The appended literal rows are synthetic personal study data, not a user's backup:
a Bible annotation, a general-book annotation where that generation supports it,
notes, two kinds of labels, duplicate historical Speak labels, and StudyPad text.
Versions 1–2 intentionally have no general-book bookmark because Android had not
introduced that table. Version 1 stores note and StudyPad text inline.

`AndroidBookmarkMigrationTests` loads these independently of production migration
SQL, restores into SwiftData, re-exports, and checks content and relationships. It
also re-imports original historical data after local edits to verify that Import
preserves those edits. Migration behavior follows `BookmarkMigrations.kt` and its
`Utilities.kt` sync-trigger wrapper; it does not infer missing columns at runtime.
