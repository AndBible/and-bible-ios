// RemoteSyncBookmarkAndroidBookStore.swift — Local preservation of Android bookmark book columns

import Foundation

/**
 Preserves raw Android `BibleBookmark.book` column values in iOS's local-only settings store.

 Android stores SWORD module initials (or NULL) in the bookmark `book` column, while iOS rewrites
 the same field into a display book name during restore so bookmark rendering works (issue #356).
 This store keeps the original Android value per bookmark so outbound sync snapshots and backup
 exports can round-trip Android's module-initials semantics instead of leaking display names into
 Android's column.

 Data dependencies:
 - `SettingsStore` provides local-only key-value persistence in the `LocalStore`

 Side effects:
 - writes and removes namespaced `Setting` rows in the local SwiftData settings table

 Failure modes:
 - underlying `SettingsStore` writes swallow persistence failures, so callers should treat this
   store as best-effort preservation rather than transactional storage

 Concurrency:
 - this type inherits the confinement requirements of the supplied `SettingsStore`
 */
public final class RemoteSyncBookmarkAndroidBookStore {
    /**
     One preserved Android bookmark book-column value.

     `rawBook == nil` means Android stored SQL NULL. Absence from `snapshotEntries()` means no fidelity
     value was preserved and callers should derive the value from the live bookmark instead.
     */
    struct Entry: Sendable, Equatable {
        /// Bible bookmark that owns the preserved value.
        let bookmarkID: UUID

        /// Exact Android column value, including a distinct `nil` for SQL NULL.
        let rawBook: String?

        /** Creates one decoded fidelity entry without reading or writing persistence. */
        init(bookmarkID: UUID, rawBook: String?) {
            self.bookmarkID = bookmarkID
            self.rawBook = rawBook
        }
    }

    /**
     Sentinel persisted for Android rows whose `book` column was NULL.

     Real SWORD module initials never contain double underscores, so the sentinel cannot collide
     with preserved data values.
     */
    private static let nullSentinel = "__android_null__"

    private let settingsStore: SettingsStore

    private enum Keys {
        static let prefix = "remote_sync.bookmarks.android_book"
    }

    /**
     Creates a local-only store for preserved Android bookmark `book` column values.

     - Parameter settingsStore: Local settings store used for persistence.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /**
     Stores or replaces one preserved raw Android `book` value.

     - Parameters:
       - rawBook: Raw Android column value; `nil` records that Android stored NULL.
       - bookmarkID: Bible bookmark identifier that owns the value.
     - Side effects: writes one namespaced local `Setting` row.
     - Failure modes: persistence failures are swallowed by `SettingsStore`.
     */
    public func setRawBook(_ rawBook: String?, for bookmarkID: UUID) {
        settingsStore.setString(scopedKey(bookmarkID: bookmarkID), value: rawBook ?? Self.nullSentinel)
    }

    /**
     Reads one preserved raw Android `book` value.

     - Parameter bookmarkID: Bible bookmark identifier that owns the value.
     - Returns: `.some(value)` when a value was preserved (`value` itself is `nil` when Android
       stored NULL), or `nil` when this bookmark has no preserved entry.
     - Side effects: none.
     - Failure modes: missing stored keys return `nil`.
     */
    public func rawBook(for bookmarkID: UUID) -> String?? {
        guard let stored = settingsStore.getString(scopedKey(bookmarkID: bookmarkID)),
              !stored.isEmpty else {
            return nil
        }
        return .some(stored == Self.nullSentinel ? nil : stored)
    }

    /**
     Projects one bookmark's Android-facing `book` value for outbound snapshots.

     - Parameters:
       - bookmarkID: Bible bookmark identifier being projected.
       - localBook: Local Android-facing source module initials, or `nil` when unknown.
     - Returns: The preserved raw Android value when one exists, otherwise the local source module
       initials.
     - Side effects: none.
     - Failure modes: none.
     */
    public func androidBookValue(for bookmarkID: UUID, localBook: String?) -> String? {
        if let preserved = rawBook(for: bookmarkID) {
            return preserved
        }
        return localBook
    }

    /**
     Returns every well-formed preserved Android bookmark book-column value.

     This projection lets a complete bookmark snapshot read the fidelity namespace once instead of
     issuing one settings query per Bible bookmark. Malformed keys, noncanonical UUID spellings, and
     empty payloads are skipped, matching exact canonical-key `rawBook(for:)` lookup; the explicit
     NULL sentinel remains a present entry whose `rawBook` value is `nil`.

     - Returns: Entries sorted by bookmark UUID string.
     - Side effects: Reads the local settings table once.
     - Failure modes: Settings fetch failures retain the store's historical empty-result behavior.
     */
    func snapshotEntries() -> [Entry] {
        settingsStore.entries(inExactNamespace: Keys.prefix)
            .compactMap(decodeEntry)
            .sorted { $0.bookmarkID.uuidString < $1.bookmarkID.uuidString }
    }

    /**
     Removes every preserved Android `book` entry.

     - Side effects: deletes all namespaced rows for this store.
     - Failure modes: persistence failures are swallowed by `SettingsStore`.
     */
    public func clearAll() {
        for entry in settingsStore.entries(withPrefix: Keys.prefix) {
            settingsStore.remove(entry.key)
        }
    }

    private func scopedKey(bookmarkID: UUID) -> String {
        "\(Keys.prefix).\(bookmarkID.uuidString.lowercased())"
    }

    private func decodeEntry(_ entry: Setting) -> Entry? {
        let prefix = "\(Keys.prefix)."
        let suffix = String(entry.key.dropFirst(prefix.count))
        guard entry.key.hasPrefix(prefix), !entry.value.isEmpty,
              let bookmarkID = UUID(uuidString: suffix),
              suffix == bookmarkID.uuidString.lowercased() else {
            return nil
        }
        return Entry(
            bookmarkID: bookmarkID,
            rawBook: entry.value == Self.nullSentinel ? nil : entry.value
        )
    }
}
